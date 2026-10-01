import Foundation
import Combine
import os
#if canImport(ActivityKit)
import ActivityKit
#endif

enum LyricsDisplayState: Equatable {
    case idle       // nothing playing yet
    case loading
    case synced([LRCLine])
    case plain(String)
    case instrumental
    case notFound
    case failed
}

/// Central wiring: sources → coordinator → sync engine → lyrics → UI
/// and Live Activity. (Drive Mode keep-alive is added in Phase 7.)
@MainActor
final class AppModel: ObservableObject {
    /// Single shared instance: the SwiftUI scene and the Drive Mode App
    /// Intents (which can launch the process in the background) must drive
    /// the same pipeline.
    static let shared = AppModel()

    static let pollIntervalKey = "spotifyPollInterval"
    static let sourcePinKey = "sourcePin"

    private static let log = Logger(subsystem: "com.praveetgupta.driveverse", category: "pipeline")

    // MARK: UI state

    @Published private(set) var nowPlaying: NowPlayingState?
    @Published private(set) var lyricsState: LyricsDisplayState = .idle
    @Published private(set) var position: LyricsPosition?
    @Published private(set) var appleMusicAuth: MediaAuthStatus = .unknown
    @Published private(set) var spotifyConnected = false
    @Published private(set) var spotifyNeedsReconnect = false
    @Published var errorMessage: String?

    @Published var driveMode = false {
        didSet {
#if os(iOS)
            liveActivity.holdWhilePaused = driveMode
#if canImport(ActivityKit)
            // Without this Settings toggle the frequent-updates Info.plist
            // key is inert and ActivityKit's standard budget silently
            // freezes the tile after roughly a minute of lyric updates.
            if driveMode, !ActivityAuthorizationInfo().frequentPushesEnabled {
                errorMessage = "For smooth lyrics, turn on Settings → DriveVerse → Live Activities → More Frequent Updates."
            }
#endif
#endif
            syncLiveActivity()
        }
    }

    var sourcePin: SourcePin {
        get { coordinator.pin }
        set {
            objectWillChange.send()
            coordinator.pin = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.sourcePinKey)
        }
    }

    // MARK: Pipeline

    let spotifyAuth: SpotifyAuth
    private let spotifySource: SpotifySource
#if os(iOS)
    private let appleSource: AppleMusicSource
    private let liveActivity = LiveActivityController()
    private let backgroundKeeper = BackgroundKeeper()
#endif
    private let coordinator: NowPlayingCoordinator
    private let syncEngine = SyncEngine()
    private let lyricsService = LyricsService()

    private var cancellables: Set<AnyCancellable> = []
    private var lyricsTask: Task<Void, Never>?
    private var currentSignature: String?

    /// Incremented every time a new lyric request begins.
    /// Results from older tracks are ignored even if their network request
    /// happens to finish after a newer track has already started.
    private var lyricsGeneration = 0

    private var started = false

    init() {
        let auth = SpotifyAuth()
        spotifyAuth = auth
        let spotify = SpotifySource(tokenProvider: auth)
        spotify.activeInterval = {
            let value = UserDefaults.standard.double(forKey: Self.pollIntervalKey)
            return (3...10).contains(value) ? value : SpotifySource.defaultActiveInterval
        }
        spotifySource = spotify

        let applePublisher: AnyPublisher<NowPlayingState?, Never>
#if os(iOS)
        let apple = AppleMusicSource()
        appleSource = apple
        applePublisher = apple.statePublisher
#else
        applePublisher = Just<NowPlayingState?>(nil).eraseToAnyPublisher()
#endif

        let savedPin = UserDefaults.standard.string(forKey: Self.sourcePinKey)
        coordinator = NowPlayingCoordinator(
            applePublisher: applePublisher,
            spotifyPublisher: spotify.statePublisher,
            pin: savedPin.flatMap(SourcePin.init(rawValue:)) ?? .auto
        )

        wire()

#if os(iOS)
        backgroundKeeper.onIssue = { [weak self] message in
            Task { @MainActor in
                self?.errorMessage = message
                self?.driveMode = false
            }
        }
#endif
    }

    func start() {
        guard !started else { return }
        started = true
#if os(iOS)
        appleSource.start()
#endif
        spotifySource.start()
        syncEngine.startTicking()
    }

    /// Called when the scene returns to .active: any background stretch may
    /// have left the lyric index stale (missed notifications, old anchors),
    /// so force-fresh reads from both sources; the sync engine's seek
    /// detection snaps the line immediately.
    func foregroundResync() {
        guard started else { return }
#if os(iOS)
        appleSource.refresh()
#endif
        spotifySource.pollNow()
    }

    /// Entry point for the Start Drive Mode intent. May run with the app
    /// launched straight into the background, where the LiveActivityIntent
    /// grant is the only legal way to request an activity — so one is started
    /// immediately (a placeholder until music plays); everything after that
    /// is a plain background update.
    func startDriveSession() {
#if os(iOS)
        start()
        liveActivity.beginSession(state: nowPlaying, position: position)
        driveMode = true
        foregroundResync()
#endif
    }

    /// Entry point for the Stop Drive Mode intent (leaving the car): stop
    /// holding the session and take the tile down right away.
    func stopDriveSession() {
        driveMode = false
#if os(iOS)
        Task { await liveActivity.endNow() }
#endif
    }

    /// Recreates the Live Activity while a LiveActivityIntent grant is active.
    ///
    /// Used as a recovery action when CarPlay's hosted Live Activity stops
    /// repainting even though the iPhone Live Activity is still correct.
    func refreshCarPlayLyrics() async -> Bool {

    #if os(iOS)

        // Make sure the playback pipeline exists even if the system launched
        // DriveVerse directly into the background for this intent.
        start()

        // Ask the music sources for the newest playback position first.
        foregroundResync()

        // Give MediaPlayer / coordinator a brief opportunity to publish the
        // refreshed state before taking the replacement activity snapshot.
        try? await Task.sleep(
            for: .milliseconds(400)
        )

        return await liveActivity
            .recreateSession(
                state: nowPlaying,
                position: position
            )

    #else

        return false

    #endif
    }

    // MARK: Actions

#if os(iOS)
    func connectSpotify() async {
        do {
            try await spotifyAuth.connect()
            errorMessage = nil
        } catch SpotifyAuthError.missingClientID {
            errorMessage = "No Spotify client ID. Copy Secrets.example.plist to Secrets.plist and fill in your ID."
        } catch {
            errorMessage = "Spotify connection failed. Try again."
        }
    }
#endif

    func disconnectSpotify() {
        spotifyAuth.disconnect()
    }

    func retryLyrics() {
        guard let state = nowPlaying else { return }

        let signature = LyricsMatcher.signature(
            title: state.title,
            artist: state.artist,
            durationMs: state.durationMs
        )

        lyricsGeneration &+= 1
        let generation = lyricsGeneration

        lyricsTask?.cancel()
        lyricsTask = nil

        currentSignature = signature

        // Never leave previously loaded lyrics visible during a retry.
        syncEngine.setLyrics([])
        lyricsState = .loading

        fetchLyrics(
            for: state,
            generation: generation
        )
    }

    func clearLyricsCache() {
        lyricsService.clearCache()
    }

    // MARK: Wiring

    private func wire() {
        coordinator.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handle(state) }
            .store(in: &cancellables)

        syncEngine.positionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                self?.position = position
                self?.syncLiveActivity()
            }
            .store(in: &cancellables)

        spotifyAuth.$isConnected
            .sink { [weak self] in self?.spotifyConnected = $0 }
            .store(in: &cancellables)
        spotifyAuth.$needsReconnect
            .sink { [weak self] in self?.spotifyNeedsReconnect = $0 }
            .store(in: &cancellables)

#if os(iOS)
        appleSource.authStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.appleMusicAuth = $0 }
            .store(in: &cancellables)
#endif
    }

    private func handle(_ state: NowPlayingState?) {

        let previousState = nowPlaying

        nowPlaying = state

        guard let state else {

            lyricsGeneration &+= 1

            lyricsTask?.cancel()
            lyricsTask = nil

            currentSignature = nil
            lyricsState = .idle

            // Clear old lyrics BEFORE emitting the empty playback state.
            syncEngine.setLyrics([])
            syncEngine.apply(nil)

            syncLiveActivity()
            return
        }

        let signature = LyricsMatcher.signature(
            title: state.title,
            artist: state.artist,
            durationMs: state.durationMs
        )

        let actualTrackChanged: Bool

        if let previousState {
            actualTrackChanged =
                !previousState.isSameTrack(as: state)
        } else {
            actualTrackChanged = true
        }

        let needsNewLyrics =
            actualTrackChanged ||
            signature != currentSignature

        if needsNewLyrics {

            lyricsGeneration &+= 1
            let generation = lyricsGeneration

            lyricsTask?.cancel()
            lyricsTask = nil

            currentSignature = signature

            // VERY IMPORTANT:
            //
            // Clear the previous track's lyrics BEFORE apply(state).
            //
            // apply() immediately emits a LyricsPosition. If we wait until
            // fetchLyrics(), the new song title can temporarily be combined
            // with the previous song's first lyric.
            syncEngine.setLyrics([])
            lyricsState = .loading

            // Only after old lyrics are gone do we let the SyncEngine adopt
            // the new track.
            syncEngine.apply(state)

            fetchLyrics(
                for: state,
                generation: generation
            )

        } else {

            // Same track: normal playback position / play-pause update.
            syncEngine.apply(state)
        }

        syncLiveActivity()
    }

    /// The controller's update policy dedupes the 500 ms ticks — only line
    /// changes and play/pause flips reach ActivityKit.
    private func syncLiveActivity() {
#if os(iOS)
        var hasSyncedLyrics = false
        if case .synced = lyricsState { hasSyncedLyrics = true }
        liveActivity.sync(state: nowPlaying, position: position, hasSyncedLyrics: hasSyncedLyrics)
        updateKeepAlive()
#endif
    }

    /// Deviation from CLAUDE.md §6 (owner's decision): Drive Mode now means
    /// "stay awake until toggled off", not "awake only while an activity is
    /// up" — pauses of any length (parking, calls, coffee stops) must survive
    /// without reopening the app, because a suspended app can neither detect
    /// the resume nor re-request the activity from the background. Battery
    /// cost stays opt-in; the CarPlay automation (README) turns Drive Mode
    /// off when leaving the car.
    private func updateKeepAlive() {
#if os(iOS)
        let shouldRun = driveMode
        if shouldRun && !backgroundKeeper.isRunning {
            do {
                try backgroundKeeper.start()
            } catch {
                driveMode = false
                errorMessage = "Drive Mode needs location access to stay alive in the background. Allow it for DriveVerse in Settings → Privacy → Location Services."
            }
        } else if !shouldRun && backgroundKeeper.isRunning {
            backgroundKeeper.stop()
        }
#endif
    }

    private func fetchLyrics(
        for state: NowPlayingState,
        generation: Int
    ) {

        lyricsTask = Task { [weak self] in

            guard let self else {
                return
            }

            do {

                let result =
                    try await self.lyricsService.lyrics(
                        for: state
                    )

                // Two independent protections:
                //
                // 1. The Task wasn't cancelled.
                // 2. This result still belongs to the newest lyric request.
                guard !Task.isCancelled,
                      generation == self.lyricsGeneration else {
                    return
                }

                switch result {

                case .synced(let raw):

                    let lines =
                        LRCParser.parse(raw).map {

                            LRCLine(
                                timeMs: $0.timeMs,
                                text:
                                    Transliterator
                                        .latinized($0.text)
                            )
                        }

                    // Check again after parsing in case a track change happened
                    // while this task was doing work.
                    guard !Task.isCancelled,
                          generation == self.lyricsGeneration else {
                        return
                    }

                    if lines.isEmpty {

                        self.lyricsState =
                            .notFound

                        self.syncEngine
                            .setLyrics([])

                    } else {

                        self.lyricsState =
                            .synced(lines)

                        self.syncEngine
                            .setLyrics(lines)
                    }

                case .plain(let text):

                    self.lyricsState =
                        .plain(
                            Transliterator
                                .latinized(text)
                        )

                    self.syncEngine
                        .setLyrics([])

                case .instrumental:

                    self.lyricsState =
                        .instrumental

                    self.syncEngine
                        .setLyrics([])

                case .notFound:

                    self.lyricsState =
                        .notFound

                    self.syncEngine
                        .setLyrics([])
                }

            } catch is CancellationError {

                // Superseded by a newer track.

            } catch {

                guard !Task.isCancelled,
                      generation == self.lyricsGeneration else {
                    return
                }

                self.lyricsState =
                    .failed

                self.syncEngine
                    .setLyrics([])

                Self.log.warning(
                    "lyrics fetch failed for \(state.title.prefix(12), privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
