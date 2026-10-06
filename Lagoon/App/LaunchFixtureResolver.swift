import Foundation
import LagoonEngine

/// Resolves the frame-loss bench's or a UI regression journey's title from
/// the launch flags, with the signed-in client. The flags are documented in
/// `docs/reference/regression-lane.md`. It is not `#if DEBUG` because the
/// bench runs in Release builds.
struct LaunchFixtureResolver {
    let client: JellyfinClient

    enum Outcome {
        /// No bench or regression launch flags asked for a title.
        case notRequested
        /// `probe` is the `player.regression.resolution` value, `missing:…` or `error:…`.
        case unresolved(probe: String)
        /// `replaysLifecycle`: the title the lifecycle replay benchmark replays.
        case resolved(MediaItem, startFromBeginning: Bool, replaysLifecycle: Bool)
    }

    /// Whether the launch flags ask for a title at all.
    var isRequested: Bool { benchTerm != nil }

    func resolve() async -> Outcome {
        guard let term = benchTerm else { return .notRequested }
        if regressionRun {
            if flag("debug.regressionFindVC1InSeries"), let requestedSeries {
                return await findVC1Episode(inSeries: requestedSeries)
            }
            if flag("debug.regressionFindEpisodeWithSuccessor") {
                return await findEpisodeWithSuccessor()
            }
            if flag("debug.regressionFindDirectStream") {
                return await findDirectStream()
            }
            if flag("debug.regressionFindPlayable") {
                return await findPlayable()
            }
            if flag("debug.regressionFindMultiAudioH264") {
                return await findMultiAudioH264()
            }
            if flag("debug.regressionFindSkippableEpisode"), let requestedSeries {
                return await findSkippableEpisode(inSeries: requestedSeries)
            }
        }
        return await findExactTitle(term)
    }

    private var regressionRun: Bool { flag("debug.playerRegression") }

    private func flag(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    private var benchTerm: String? {
        guard flag("debug.frameLossBench") || regressionRun,
              let term = UserDefaults.standard.string(forKey: "debug.benchSearchTerm")?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else { return nil }
        return term
    }

    private var requestedSeries: String? {
        guard let name = UserDefaults.standard.string(forKey: "debug.regressionSeriesName")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private func findVC1Episode(inSeries requestedSeries: String) async -> Outcome {
        // Keep "no such series" (`missing:`, skips the journey) apart
        // from "request failed" (`error:`, fails it), or a server without
        // the fixture reads as a broken player.
        let episodes: [MediaItem]
        switch await episodesInSeries(named: requestedSeries) {
        case .resolved(let found):
            episodes = found
        case .seriesSearchFailed:
            print("RegressionResolve failed VC-1 series search=\"\(requestedSeries)\"")
            return .unresolved(probe: "error:VC-1 series search failed")
        case .seriesNotFound:
            print("RegressionResolve no VC-1 series named \"\(requestedSeries)\"")
            return .unresolved(probe: "missing:series \(requestedSeries)")
        case .episodeListFailed:
            print("RegressionResolve failed VC-1 episode list for \"\(requestedSeries)\"")
            return .unresolved(probe: "error:VC-1 episode list failed")
        }
        for episode in episodes {
            guard let info = try? await client.playbackInfo(itemId: episode.id),
                  let source = info.mediaSources.first,
                  (source.mediaStreams ?? []).contains(where: {
                      $0.type == "Video" && ["vc1", "vc-1"].contains($0.codec?.lowercased() ?? "")
                  }) else { continue }
            print("RegressionResolve VC-1 series=\"\(requestedSeries)\" title=\"\(episode.name ?? "?")\" id=\(episode.id)")
            return .resolved(episode, startFromBeginning: true, replaysLifecycle: true)
        }
        print("RegressionResolve no VC-1 episode series=\"\(requestedSeries)\"")
        return .unresolved(probe: "missing:VC-1 episode")
    }

    private func findEpisodeWithSuccessor() async -> Outcome {
        let episodeItems: [MediaItem]
        if let requestedSeries {
            guard case .resolved(let episodes) = await episodesInSeries(named: requestedSeries) else {
                print("RegressionResolve failed handoff series=\"\(requestedSeries)\"")
                return .unresolved(probe: "missing:requested handoff series")
            }
            episodeItems = episodes
        } else {
            guard let page = try? await client.items(
                includeTypes: [.episode],
                sortBy: "SeriesSortName,ParentIndexNumber,IndexNumber",
                limit: 100
            ) else {
                print("RegressionResolve failed episode handoff library scan")
                return .unresolved(probe: "error:episode handoff library scan failed")
            }
            episodeItems = page.items
        }
        // Pick the earliest episode of any series with two or more.
        // Calling `episodeAfter` per item was slow enough to trip the
        // XCTest watchdog on the demo server.
        let candidates = Dictionary(
            grouping: episodeItems.filter { $0.seriesId != nil },
            by: { $0.seriesId! }
        ).values.compactMap { episodes -> MediaItem? in
            guard episodes.count > 1 else { return nil }
            return episodes.min { lhs, rhs in
                let lhsSeason = lhs.parentIndexNumber ?? Int.max
                let rhsSeason = rhs.parentIndexNumber ?? Int.max
                if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
                return (lhs.indexNumber ?? Int.max) < (rhs.indexNumber ?? Int.max)
            }
        }
        let requireDirectH264 = flag("debug.regressionRequireDirectH264Successor")
        for episode in candidates.prefix(20) {
            guard let info = try? await client.playbackInfo(itemId: episode.id),
                  let source = info.mediaSources.first,
                  (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }) else {
                continue
            }
            if requireDirectH264 {
                let isDirectH264 = source.supportsDirectPlay == true
                    && (source.mediaStreams ?? []).contains {
                        $0.type == "Video" && $0.codec?.lowercased() == "h264"
                    }
                guard isDirectH264 else { continue }
            }
            print("RegressionResolve handoff title=\"\(episode.name ?? "?")\" id=\(episode.id)")
            return .resolved(episode, startFromBeginning: true, replaysLifecycle: true)
        }
        print("RegressionResolve no playable episode with a successor")
        return .unresolved(probe: "missing:playable episode with successor")
    }

    private func findDirectStream() async -> Outcome {
        guard let page = try? await client.items(
            includeTypes: [.movie, .episode],
            limit: 100
        ) else {
            print("RegressionResolve failed direct-stream library scan")
            return .unresolved(probe: "error:direct-stream library scan failed")
        }
        for item in page.items {
            guard let info = try? await client.playbackInfo(itemId: item.id),
                  let source = info.mediaSources.first,
                  source.supportsDirectPlay != true,
                  source.supportsDirectStream == true,
                  (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }) else {
                continue
            }
            print("RegressionResolve direct-stream title=\"\(item.name ?? "?")\" id=\(item.id)")
            return .resolved(item, startFromBeginning: true, replaysLifecycle: true)
        }
        print("RegressionResolve no direct-stream item")
        return .unresolved(probe: "missing:direct-stream item")
    }

    private func findPlayable() async -> Outcome {
        guard let page = try? await client.items(
            includeTypes: [.movie, .episode],
            limit: 100
        ) else {
            print("RegressionResolve failed playable library scan")
            return .unresolved(probe: "error:playable library scan failed")
        }
        // Journeys that need direct play ask for it, so a server whose
        // first title transcodes yields a skip, not a timeout.
        let requireDirectPlay = flag("debug.regressionRequireDirectPlay")
        let requireAudio = flag("debug.regressionRequireAudio")
        for item in page.items {
            guard let info = try? await client.playbackInfo(itemId: item.id),
                  let source = info.mediaSources.first,
                  (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }),
                  !requireDirectPlay || source.supportsDirectPlay == true,
                  !requireAudio || (source.mediaStreams ?? []).contains(where: { $0.type == "Audio" }) else {
                continue
            }
            print("RegressionResolve playable title=\"\(item.name ?? "?")\" id=\(item.id)")
            return .resolved(item, startFromBeginning: true, replaysLifecycle: true)
        }
        print("RegressionResolve no playable item (directPlay=\(requireDirectPlay), audio=\(requireAudio))")
        return .unresolved(probe: requireDirectPlay ? "missing:direct-play playable item" : "missing:playable item")
    }

    private func findMultiAudioH264() async -> Outcome {
        guard let page = try? await client.items(
            includeTypes: [.movie, .episode],
            limit: 100
        ) else {
            print("RegressionResolve failed multi-audio library scan")
            return .unresolved(probe: "error:multi-audio library scan failed")
        }
        // Direct play keeps every embedded audio stream; asking the
        // server avoids hard-coding a private-library title.
        for item in page.items {
            guard let info = try? await client.playbackInfo(itemId: item.id),
                  let source = info.mediaSources.first(where: { $0.supportsDirectPlay == true }) else {
                continue
            }
            let streams = source.mediaStreams ?? []
            let isH264 = streams.contains {
                $0.type == "Video" && $0.codec?.lowercased() == "h264"
            }
            let audioCount = streams.count { $0.type == "Audio" }
            if isH264, audioCount > 1 {
                print("RegressionResolve multi-audio title=\"\(item.name ?? "?")\" id=\(item.id)")
                return .resolved(item, startFromBeginning: true, replaysLifecycle: false)
            }
        }
        print("RegressionResolve no direct-play H.264 multi-audio item")
        return .unresolved(probe: "missing:direct-play H.264 multi-audio item")
    }

    private func findSkippableEpisode(inSeries requestedSeries: String) async -> Outcome {
        guard case .resolved(let episodes) = await episodesInSeries(named: requestedSeries) else {
            print("RegressionResolve failed series=\"\(requestedSeries)\"")
            return .unresolved(probe: "missing:requested skippable series")
        }
        for episode in episodes {
            let segments = await client.mediaSegments(itemId: episode.id)
            if segments.contains(where: { $0.kind.isSkippable }) {
                print("RegressionResolve skippable series=\"\(requestedSeries)\" title=\"\(episode.name ?? "?")\" id=\(episode.id)")
                return .resolved(episode, startFromBeginning: true, replaysLifecycle: false)
            }
        }
        print("RegressionResolve no skippable episode series=\"\(requestedSeries)\"")
        return .unresolved(probe: "missing:skippable episode")
    }

    private func findExactTitle(_ term: String) async -> Outcome {
        guard let page = try? await client.items(
            includeTypes: regressionRun ? [.movie, .episode] : [.movie],
            searchTerm: term,
            limit: regressionRun ? 100 : 20
        ) else {
            print("BenchResolve failed term=\"\(term)\"")
            return .unresolved(probe: "error:item lookup failed")
        }
        let requestedYear = UserDefaults.standard.integer(forKey: "debug.benchProductionYear")
        let candidates = page.items.filter { item in
            item.name?.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (requestedSeries.map {
                    item.seriesName?.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                } ?? true)
        }
        let item = candidates.first(where: { requestedYear <= 0 || $0.productionYear == requestedYear })
            ?? candidates.first
        guard let item else {
            print("BenchResolve no exact match term=\"\(term)\" year=\(requestedYear)")
            return .unresolved(probe: "missing:exact media fixture")
        }
        print("BenchResolve title=\"\(item.name ?? term)\" year=\(item.productionYear ?? 0) id=\(item.id)")
        return .resolved(item, startFromBeginning: regressionRun, replaysLifecycle: false)
    }

    /// The shared "series by name, then its episodes" lookup. Callers
    /// distinguish the failure modes because they report different probe
    /// values: a search failure is a broken server (`error:`), a missing
    /// series is a missing fixture (`missing:`).
    private enum SeriesEpisodesLookup {
        case resolved([MediaItem])
        case seriesSearchFailed
        case seriesNotFound
        case episodeListFailed
    }

    private func episodesInSeries(named name: String) async -> SeriesEpisodesLookup {
        guard let seriesPage = try? await client.items(
            includeTypes: [.series],
            searchTerm: name,
            limit: 20
        ) else {
            return .seriesSearchFailed
        }
        guard let series = seriesPage.items.first(where: {
            $0.name?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            return .seriesNotFound
        }
        guard let episodes = try? await client.episodes(seriesId: series.id, seasonId: nil) else {
            return .episodeListFailed
        }
        return .resolved(episodes)
    }
}
