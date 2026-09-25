import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import os

/// Owns the lyrics Live Activity lifecycle.
///
/// Important update rule:
///
/// Only ONE ActivityKit update is allowed to be in flight at a time.
///
/// If several lyric states arrive while an update is still being processed,
/// older pending states are discarded and only the newest state is sent.
///
/// This is ideal for synchronized lyrics:
/// once line 24 is current, there is no reason to send an obsolete line 23
/// just because it was queued earlier.
@MainActor
final class LiveActivityController {

    static let endDelay: TimeInterval = 30

    private static let log =
        Logger(
            subsystem: "com.praveetgupta.driveverse",
            category: "activity"
        )

    private var activity:
        Activity<LyricsAttributes>?

    private var policy =
        LiveActivityUpdatePolicy()

    private var endTask:
        Task<Void, Never>?

    private var stateWatcher:
        Task<Void, Never>?

    // MARK: - Serialized ActivityKit updater

    private struct PendingUpdate {
        let activity:
            Activity<LyricsAttributes>

        let content:
            LyricsAttributes.ContentState

        let timestamp:
            Date
    }

    /// At most one unsent state.
    /// A newer state simply replaces the older one.
    private var pendingUpdate:
        PendingUpdate?

    /// There is never more than one update worker.
    private var updateWorker:
        Task<Void, Never>?

    private var lastSentTrackKey:
        String?

    private var lastSentIsPlaying:
        Bool?

    /// Drive Mode's keep-alive only runs while an activity actually exists.
    var isActive: Bool {
        activity != nil
    }

    /// While Drive Mode is enabled, don't destroy the activity just because
    /// playback is temporarily paused.
    var holdWhilePaused = false

    init() {

        // Clean up orphaned activities from a previous app termination.
        Task {

            for stale in
                Activity<LyricsAttributes>.activities {

                await stale.end(
                    nil,
                    dismissalPolicy: .immediate
                )
            }
        }
    }

    // MARK: - Sync

    /// Called by AppModel whenever the playback/lyric position changes.
    func sync(
        state: NowPlayingState?,
        position: LyricsPosition?,
        hasSyncedLyrics: Bool
    ) {

        guard let state else {

            if holdWhilePaused {
                cancelScheduledEnd()
            } else {
                scheduleEnd()
            }

            return
        }

        guard let activity else {

            if state.isPlaying,
               hasSyncedLyrics {

                beginSession(
                    state: state,
                    position: position
                )
            }

            return
        }

        if state.isPlaying || holdWhilePaused {
            cancelScheduledEnd()
        } else {
            scheduleEnd()
        }

        let key =
            Self.key(for: state)

        // The policy remains responsible for making sure ordinary progress
        // ticks don't become ActivityKit updates.
        //
        // Normally an update is produced only when:
        // - lyric line changes
        // - track changes
        // - play/pause changes
        guard policy.shouldUpdate(
            trackKey: key,
            lineIndex: position?.lineIndex,
            isPlaying: state.isPlaying
        ) else {
            return
        }

        lastSentTrackKey = key
        lastSentIsPlaying = state.isPlaying

        let content =
            Self.content(
                state: state,
                position: position
            )

        enqueueLatest(
            content,
            on: activity
        )
    }

    // MARK: - Latest-state-wins queue

    /// Replaces any unsent old lyric with the newest state.
    private func enqueueLatest(
        _ content: LyricsAttributes.ContentState,
        on activity: Activity<LyricsAttributes>
    ) {

        pendingUpdate =
            PendingUpdate(
                activity: activity,
                content: content,
                timestamp: Date()
            )

        startUpdateWorkerIfNeeded()
    }

    private func startUpdateWorkerIfNeeded() {

        guard updateWorker == nil else {
            return
        }

        updateWorker =
            Task { [weak self] in

                guard let self else {
                    return
                }

                while !Task.isCancelled {

                    guard let update =
                        self.pendingUpdate else {
                        break
                    }

                    // Take the newest state.
                    self.pendingUpdate = nil

                    // iOS 26 provides the timestamp-aware local ActivityKit
                    // update API. If an older update somehow arrives after a
                    // newer one, the system can reject the stale update.
                    if #available(iOS 26.0, *) {

                        await update.activity.update(
                            ActivityContent(
                                state: update.content,
                                staleDate: nil
                            ),
                            alertConfiguration: nil,
                            timestamp: update.timestamp
                        )

                    } else {

                        await update.activity.update(
                            ActivityContent(
                                state: update.content,
                                staleDate: nil
                            )
                        )
                    }

                    // While the await above was running, sync() may have
                    // replaced pendingUpdate several times.
                    //
                    // The loop therefore sends only the newest pending state.
                }

                self.updateWorker = nil

                // Safety check in case new state arrived as the worker was
                // finishing.
                if self.pendingUpdate != nil {
                    self.startUpdateWorkerIfNeeded()
                }
            }
    }

    private func cancelUpdateWorker() {

        updateWorker?.cancel()
        updateWorker = nil

        pendingUpdate = nil
    }

    // MARK: - Start session

    /// Requests the listening session's Live Activity.
    ///
    /// Normal background code cannot reliably create a fresh Activity.
    /// Start Drive Mode's LiveActivityIntent is the supported background
    /// entry point.
    func beginSession(
        state: NowPlayingState?,
        position: LyricsPosition?
    ) {

        guard activity == nil,
              ActivityAuthorizationInfo()
                .areActivitiesEnabled else {
            return
        }

        let content =
            state.map {

                Self.content(
                    state: $0,
                    position: position
                )

            } ?? LyricsAttributes.ContentState(
                title: "DriveVerse",
                artist: "",
                sourceName: "",
                currentLine:
                    "♪ Waiting for music…",
                nextLine: "",
                progress: 0,
                isPlaying: false
            )

        do {

            let requested =
                try Activity.request(
                    attributes:
                        LyricsAttributes(),
                    content:
                        ActivityContent(
                            state: content,
                            staleDate: nil
                        )
                )

            activity = requested

            watch(requested)

            if let state {

                let trackKey =
                    Self.key(for: state)

                lastSentTrackKey =
                    trackKey

                lastSentIsPlaying =
                    state.isPlaying

                policy.seed(
                    trackKey: trackKey,
                    lineIndex:
                        position?.lineIndex,
                    isPlaying:
                        state.isPlaying
                )

            } else {

                lastSentTrackKey = nil
                lastSentIsPlaying = nil

                policy.reset()
            }

        } catch {

            Self.log.error(
                "Activity.request failed: \(error.localizedDescription, privacy: .public)"
            )

            activity = nil
        }
    }

    // MARK: - Activity state watcher

    /// iOS can end or dismiss a Live Activity independently of DriveVerse.
    private func watch(
        _ requested:
            Activity<LyricsAttributes>
    ) {

        stateWatcher?.cancel()

        stateWatcher =
            Task { [weak self] in

                for await state in
                    requested.activityStateUpdates {

                    guard let self,
                          state == .ended
                            || state == .dismissed else {
                        continue
                    }

                    if self.activity?.id
                        == requested.id {

                        self.activity = nil

                        self.policy.reset()

                        self.cancelUpdateWorker()

                        Self.log.warning(
                            "activity ended outside the app — background restart impossible; reopen the app or rerun the CarPlay automation"
                        )
                    }
                }
            }
    }

    // MARK: - End

    func endNow() async {

        endTask?.cancel()
        endTask = nil

        stateWatcher?.cancel()
        stateWatcher = nil

        cancelUpdateWorker()

        guard let activity else {
            return
        }

        self.activity = nil

        policy.reset()

        await activity.end(
            nil,
            dismissalPolicy: .immediate
        )
    }

    private func scheduleEnd() {

        guard endTask == nil,
              activity != nil else {
            return
        }

        endTask =
            Task { [weak self] in

                try? await Task.sleep(
                    for:
                        .seconds(
                            Self.endDelay
                        )
                )

                guard !Task.isCancelled else {
                    return
                }

                await self?.endNow()
            }
    }

    private func cancelScheduledEnd() {

        endTask?.cancel()
        endTask = nil
    }

    // MARK: - Content

    private static func key(
        for state: NowPlayingState
    ) -> String {

        "\(state.title)|\(state.artist)|\(state.source.rawValue)"
    }

    private static func content(
        state: NowPlayingState,
        position: LyricsPosition?
    ) -> LyricsAttributes.ContentState {

        LyricsAttributes.ContentState(
            title: state.title,
            artist: state.artist,
            sourceName:
                state.source.displayName,
            currentLine:
                position?.currentLine
                ?? "♪ \(state.title)",
            nextLine:
                position?.nextLine
                ?? "",
            progress:
                position?.trackProgress
                ?? 0,
            isPlaying:
                state.isPlaying
        )
    }
}
#endif