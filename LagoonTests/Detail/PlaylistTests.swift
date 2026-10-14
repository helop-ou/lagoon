import Foundation
import Testing
@testable import Lagoon

/// Playlists as Jellyfin 12 returns them: a title listed twice comes back
/// twice with the same ids, and audio playlists sit beside video ones.
@Suite("Playlists")
@MainActor
struct PlaylistTests {
    private func decode(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    @Test func onlyVideoPlaylistsWithSomethingInThemAreShown() throws {
        let video = try decode(#"{"Id":"v","Type":"Playlist","MediaType":"Video","ChildCount":4}"#)
        let audio = try decode(#"{"Id":"a","Type":"Playlist","MediaType":"Audio","ChildCount":3}"#)
        let empty = try decode(#"{"Id":"e","Type":"Playlist","MediaType":"Video","ChildCount":0}"#)
        #expect(video.type == .playlist)
        #expect(JellyfinClient.isVideoPlaylist(video))
        #expect(!JellyfinClient.isVideoPlaylist(audio))
        #expect(!JellyfinClient.isVideoPlaylist(empty))
    }

    @Test func aTitleListedTwicePlaysTwice() throws {
        // As jaflix (Jellyfin 12.2) answered `Playlists/{id}/Items`.
        let entries = try [
            #"{"Id":"cars","Name":"Cars","Type":"Movie","PlaylistItemId":"cars","UserData":{"Played":true}}"#,
            #"{"Id":"ep","Name":"1:23:45","Type":"Episode","PlaylistItemId":"ep","UserData":{"Played":false}}"#,
            #"{"Id":"cars2","Name":"Cars 2","Type":"Movie","PlaylistItemId":"cars2","UserData":{"Played":false}}"#,
            #"{"Id":"cars","Name":"Cars","Type":"Movie","PlaylistItemId":"cars","UserData":{"Played":true}}"#,
        ].map(decode)
        #expect(entries[0].playlistItemId == entries[3].playlistItemId)

        let playback = try #require(ListPlayback(items: entries))
        #expect(playback.title.id == "ep")
        var queue = PlayQueue.list(playback.queue)
        var current = playback.title
        var played = [current.id]
        while played.count < 8, case .entry(let next) = queue.successor(after: current) {
            queue = queue.advanced()
            current = next
            played.append(next.id)
        }
        // The watched Cars at the end still plays: it is the playlist's order.
        #expect(played == ["ep", "cars2", "cars"])
        #expect(playback.fromBeginning?.current.media.id == "cars")
    }
}
