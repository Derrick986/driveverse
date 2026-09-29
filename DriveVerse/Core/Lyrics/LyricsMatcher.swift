import Foundation

/// Matches Apple Music / Spotify metadata against LRCLIB candidates
/// and prefers high-quality synced lyrics.
enum LyricsMatcher {

    /// "Song (feat. X) - Remix" → "song"
    static func normalizeTitle(_ raw: String) -> String {
        var s = raw.lowercased()
        s = stripBracketed(s)

        if let dash = s.range(of: " - ") {
            s = String(s[..<dash.lowerBound])
        }

        s = stripFeatClause(s)
        return collapseWhitespace(s)
    }

    /// "Rihanna feat. JAY-Z" → "rihanna"
    static func normalizeArtist(_ raw: String) -> String {
        var s = raw.lowercased()
        s = stripBracketed(s)
        s = stripFeatClause(s)
        return collapseWhitespace(s)
    }

    /// Cache key for a track.
    static func signature(
        title: String,
        artist: String,
        durationMs: Int?
    ) -> String {

        let bucket = durationMs.map {
            Int((Double($0) / 500.0).rounded())
        } ?? -1

        return "\(normalizeTitle(title))|\(normalizeArtist(artist))|\(bucket)"
    }

    // MARK: - Best candidate selection

    static func bestMatch(
        from candidates: [LRCLIBResponse],
        title: String,
        artist: String,
        album: String?,
        durationMs: Int?
    ) -> LRCLIBResponse? {

        let wantedTitle = normalizeTitle(title)
        let wantedArtist = normalizeArtist(artist)

        let eligible = candidates.filter { candidate in

            // Title must match after normalization.
            guard normalizeTitle(candidate.trackName ?? "") == wantedTitle else {
                return false
            }

            // Artist should match exactly or be a collaboration containing
            // the Apple Music artist.
            if !wantedArtist.isEmpty {
                let candidateArtist = normalizeArtist(
                    candidate.artistName ?? ""
                )

                let artistMatches =
                    candidateArtist == wantedArtist ||
                    candidateArtist.contains(wantedArtist) ||
                    wantedArtist.contains(candidateArtist)

                guard artistMatches else {
                    return false
                }
            }

            // Reject obviously different song versions when duration is known.
            if let durationMs,
               let candidateDuration = candidate.duration {

                let difference =
                    abs(candidateDuration * 1000 - Double(durationMs))

                guard difference <= 3500 else {
                    return false
                }
            }

            return true
        }

        guard !eligible.isEmpty else {
            return nil
        }

        // If any candidate actually has lyrics, don't accidentally select
        // an "instrumental" candidate for the same metadata.
        let lyricalCandidates = eligible.filter {
            $0.syncedLyrics?.isEmpty == false ||
            $0.plainLyrics?.isEmpty == false
        }

        let pool = lyricalCandidates.isEmpty
            ? eligible
            : lyricalCandidates

        return pool.max {
            score(
                $0,
                title: title,
                artist: artist,
                album: album,
                durationMs: durationMs
            )
            <
            score(
                $1,
                title: title,
                artist: artist,
                album: album,
                durationMs: durationMs
            )
        }
    }

    // MARK: - Candidate scoring

    private static func score(
        _ candidate: LRCLIBResponse,
        title: String,
        artist: String,
        album: String?,
        durationMs: Int?
    ) -> Int {

        var score = 0

        // Synced lyrics are far more valuable for DriveVerse.
        if candidate.syncedLyrics?.isEmpty == false {
            score += 1000
        } else if candidate.plainLyrics?.isEmpty == false {
            score += 100
        }

        // Exact original title is better than merely normalized equality.
        if simple(candidate.trackName ?? "") == simple(title) {
            score += 180
        }

        // Artist.
        let candidateArtist = normalizeArtist(
            candidate.artistName ?? ""
        )

        let wantedArtist = normalizeArtist(artist)

        if candidateArtist == wantedArtist {
            score += 200
        } else if candidateArtist.contains(wantedArtist)
                    || wantedArtist.contains(candidateArtist) {
            score += 80
        }

        // Album.
        if let album, !album.isEmpty {
            let wantedAlbum = normalizeTitle(album)
            let candidateAlbum = normalizeTitle(
                candidate.albumName ?? ""
            )

            if candidateAlbum == wantedAlbum {
                score += 80
            } else if !candidateAlbum.isEmpty {
                score -= 20
            }
        }

        // Duration is extremely important for synchronized lyrics.
        // A different master / edit / remix can have identical metadata but
        // noticeably different lyric timing.
        if let durationMs,
           let candidateDuration = candidate.duration {

            let difference =
                abs(candidateDuration * 1000 - Double(durationMs))

            switch difference {

            case ...100:
                score += 900

            case ...250:
                score += 800

            case ...500:
                score += 650

            case ...750:
                score += 500

            case ...1000:
                score += 350

            case ...1500:
                score += 200

            case ...2500:
                score += 50

            case ...3500:
                score -= 150

            default:
                score -= 500
            }
        }

        // Evaluate how well the synced lyrics are formatted.
        if let synced = candidate.syncedLyrics,
           !synced.isEmpty {

            score += lyricLayoutScore(
                synced,
                durationMs: durationMs
            )
        }

        return score
    }

    // MARK: - LRC quality

    private static func lyricLayoutScore(
        _ raw: String,
        durationMs: Int?
    ) -> Int {

        let lines = LRCParser.parse(raw)
            .filter {
                !$0.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }

        guard !lines.isEmpty else {
            return -500
        }

        var score = 0

        let lengths = lines.map {
            $0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).count
        }

        let totalCharacters = lengths.reduce(0, +)

        let averageLength =
            Double(totalCharacters) / Double(lengths.count)

        let maximumLength = lengths.max() ?? 0

        // Healthy lyric sheets normally have a reasonable number of
        // timestamped lines.
        score += min(lines.count * 2, 140)

        // Prefer natural sentence / lyric-line lengths.
        switch averageLength {
        case 8...55:
            score += 140

        case 56...75:
            score += 90

        case 76...100:
            score += 20

        case 101...:
            score -= 140

        default:
            break
        }

        // Strongly penalise paragraph-like LRC entries.
        let longLines = lengths.filter { $0 > 100 }.count
        let hugeLines = lengths.filter { $0 > 150 }.count

        score -= longLines * 25
        score -= hugeLines * 70

        if maximumLength > 200 {
            score -= 250
        }

        // Also avoid pathological word-per-line / syllable-per-line files.
        if averageLength < 6 && lines.count > 80 {
            score -= 160
        }

        // Detect suspiciously sparse lyric sheets.
        if let durationMs, durationMs > 0 {

            let durationSeconds =
                Double(durationMs) / 1000.0

            let minimumReasonableLines =
                max(6, Int(durationSeconds / 20.0))

            if lines.count < minimumReasonableLines {
                score -= min(
                    180,
                    (minimumReasonableLines - lines.count) * 20
                )
            }
        }

        return score
    }

    // MARK: - Helpers

    private static func simple(_ raw: String) -> String {
        let folded = raw
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            .lowercased()

        return collapseWhitespace(folded)
    }

    /// Removes every `(…)` and `[…]` segment.
    private static func stripBracketed(_ s: String) -> String {
        var out = ""
        var depth = 0

        for ch in s {
            if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                if depth > 0 {
                    depth -= 1
                }
            } else if depth == 0 {
                out.append(ch)
            }
        }

        return out
    }

    private static let featMarkers = [
        " feat. ",
        " feat ",
        " featuring ",
        " ft. ",
        " ft "
    ]

    private static func stripFeatClause(_ s: String) -> String {
        var s = s

        for marker in featMarkers {
            if let range = s.range(of: marker) {
                s = String(s[..<range.lowerBound])
            }
        }

        return s
    }

    private static func collapseWhitespace(
        _ s: String
    ) -> String {
        s.split(
            whereSeparator: { $0.isWhitespace }
        )
        .joined(separator: " ")
    }
}