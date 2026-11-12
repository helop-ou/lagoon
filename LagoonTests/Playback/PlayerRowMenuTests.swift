import Foundation
import LagoonEngine
import Testing
@testable import Lagoon

#if os(tvOS)
import UIKit

/// The system menus behind the tvOS row's Episodes and Sound buttons.
@Suite("Player row menus")
@MainActor
struct PlayerRowMenuTests {
    private func options(
        nightMode: Bool = false,
        dialogueBoost: Bool = false,
        limit: AudioChannelLimit = .off
    ) -> PlayerSoundOptions {
        PlayerSoundOptions(
            shaping: AudioShaping(nightMode: nightMode, dialogueBoost: dialogueBoost, channelLimit: limit.engineLimit),
            setNightMode: { _ in },
            setDialogueBoost: { _ in },
            setChannelLimit: { _ in }
        )
    }

    private func episode(_ id: String, number: Int, name: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"""
        {"Id":"\#(id)","Type":"Episode","SeriesId":"s","SeriesName":"The Rookie","SeasonId":"s4",\#
        "ParentIndexNumber":4,"IndexNumber":\#(number),"Name":"\#(name)"}
        """#.utf8))
    }

    private func season(current index: Int) throws -> PlayerEpisodeList {
        let episodes = [
            try episode("e1", number: 1, name: "Life and Death"),
            try episode("e2", number: 2, name: "Five Minutes"),
        ]
        return try #require(PlayerEpisodeList.season(episodes, current: episodes[index]))
    }

    @Test func theSoundMenuShowsTheTogglesAndTheLimitAsAnInlineChoice() throws {
        let menu = PlayerTVControlRow.soundMenu(options(nightMode: true, limit: .stereo))
        let actions = menu.children.compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == ["Night Mode", "Dialogue Boost"])
        #expect(actions.map(\.state) == [.on, .off])
        let limits = try #require(menu.children.last as? UIMenu)
        #expect(limits.title == "Channel Limit")
        #expect(limits.options.contains(.displayInline))
        let choices = limits.children.compactMap { $0 as? UIAction }
        #expect(choices.map(\.title) == AudioChannelLimit.allCases.map(\.title))
        #expect(choices.filter { $0.state == .on }.map(\.title) == [AudioChannelLimit.stereo.title])
    }

    @Test func theEpisodeMenuChecksThePlayingEpisodeUnderItsHeading() throws {
        let menu = PlayerTVControlRow.episodeMenu(try season(current: 1)) { _ in }
        #expect(menu.title == "The Rookie · Season 4")
        #expect(menu.options.contains(.displayInline))
        let rows = menu.children.compactMap { $0 as? UIAction }
        #expect(rows.map(\.title) == ["S4 E1 · Life and Death", "S4 E2 · Five Minutes"])
        #expect(rows.map(\.state) == [.off, .on])
    }

    /// A presented menu that is replaced redraws, so the key must hold while
    /// nothing it shows changes, and move when anything does.
    @Test func aMenuIsReplacedOnlyWhenWhatItShowsChanges() throws {
        let sound = PlayerTVControlRow.soundMenuKey(options())
        #expect(PlayerTVControlRow.soundMenuKey(options()) == sound)
        #expect(PlayerTVControlRow.soundMenuKey(options(nightMode: true)) != sound)
        #expect(PlayerTVControlRow.soundMenuKey(options(dialogueBoost: true)) != sound)
        #expect(PlayerTVControlRow.soundMenuKey(options(limit: .surround)) != sound)

        let episodes = PlayerTVControlRow.episodeMenuKey(try season(current: 0))
        #expect(PlayerTVControlRow.episodeMenuKey(try season(current: 0)) == episodes)
        #expect(PlayerTVControlRow.episodeMenuKey(try season(current: 1)) != episodes)
    }
}
#endif
