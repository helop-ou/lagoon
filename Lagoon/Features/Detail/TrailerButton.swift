import SwiftUI

/// Which trailer a detail page offers, and where it opens.
///
/// Jellyfin lists provider trailers as web links, nearly all YouTube. tvOS
/// has no browser, so there only a YouTube link counts, opened in the
/// YouTube app through its own `youtube://watch/<id>` link. On iOS the web
/// link opens the YouTube app when it is installed, the browser otherwise.
nonisolated enum TrailerLink {
    /// An official trailer before any trailer, before other clips, before
    /// teasers; otherwise the server's order.
    static func preferred(_ trailers: [RemoteTrailer]) -> RemoteTrailer? {
        trailers.enumerated()
            .filter { destination(for: $0.element) != nil }
            .min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?
            .element
    }

    static func destination(for trailer: RemoteTrailer) -> URL? {
        #if os(tvOS)
        return youTubeID(in: trailer.url).flatMap { URL(string: "youtube://watch/\($0)") }
        #else
        if let id = youTubeID(in: trailer.url) {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        return ["http", "https"].contains(trailer.url.scheme?.lowercased()) ? trailer.url : nil
        #endif
    }

    /// The video id from any common YouTube address: `watch?v=`,
    /// `youtu.be/`, `/embed/`, `/shorts/` or `/v/`.
    static func youTubeID(in url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com"
                    || host.hasSuffix(".youtube-nocookie.com") {
            if path.first == "watch" {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            } else if let first = path.first, ["embed", "shorts", "v"].contains(first), path.count > 1 {
                candidate = path[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let candidate, isVideoID(candidate) else { return nil }
        return candidate
    }

    private static func isVideoID(_ value: String) -> Bool {
        value.count >= 6 && value.count <= 32
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && value.allSatisfy(\.isASCII)
    }

    private static func rank(_ trailer: RemoteTrailer) -> Int {
        let name = trailer.name?.lowercased() ?? ""
        if name.contains("official") && name.contains("trailer") { return 0 }
        if name.contains("trailer") { return 1 }
        if name.contains("teaser") { return 3 }
        return 2
    }
}

/// A detail page's Trailer action. Absent when the item has no trailer this
/// device can open.
struct TrailerButton: View {
    let trailers: [RemoteTrailer]?

    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showsMissingApp = false

    private var destination: URL? {
        TrailerLink.preferred(trailers ?? []).flatMap(TrailerLink.destination(for:))
    }

    var body: some View {
        if let destination {
            button(opening: destination)
                .accessibilityLabel("Trailer")
                .accessibilityIdentifier("detail.trailer")
                .alert(Self.failureTitle, isPresented: $showsMissingApp) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(Self.failureMessage)
                }
        }
    }

    /// A pill on TV and wide iPad, a circle on a phone, like From Beginning.
    @ViewBuilder
    private func button(opening destination: URL) -> some View {
        #if os(iOS)
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) {
            pill(opening: destination)
        } else {
            DetailCircleButton {
                open(destination)
            } label: {
                Image(systemName: "film")
            }
        }
        #else
        pill(opening: destination)
        #endif
    }

    private func pill(opening destination: URL) -> some View {
        Button {
            open(destination)
        } label: {
            Label("Trailer", systemImage: "film")
        }
        .buttonStyle(.glass)
    }

    #if os(tvOS)
    private static let failureTitle: LocalizedStringKey = "YouTube Isn't Installed"
    private static let failureMessage: LocalizedStringKey = "Trailers open in the YouTube app. Install it from the App Store to watch them."
    #else
    private static let failureTitle: LocalizedStringKey = "Couldn't Open the Trailer"
    private static let failureMessage: LocalizedStringKey = "No app on this device could open it."
    #endif

    private func open(_ destination: URL) {
        openURL(destination) { accepted in
            if !accepted { showsMissingApp = true }
        }
    }
}
