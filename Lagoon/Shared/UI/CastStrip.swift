import SwiftUI

/// One person in the cast strip, from Jellyfin or from Seerr's TMDB credits.
struct CastCredit: Identifiable, Hashable {
    let id: String
    let name: String
    /// The character for actors, the job for crew.
    let credit: String?
    let imageURL: URL?
}

/// Cast strip. Deliberately **not** focusable and not scrolling on tvOS:
/// there is no person screen to open. Focus moving past it scrolls it into
/// view.
struct CastStrip: View {
    @Environment(\.displayScale) private var displayScale
    private let people: [Person]
    private let credits: [CastCredit]?

    @Environment(\.jellyfinClient) private var client

    init(people: [Person]) {
        self.people = people
        self.credits = nil
    }

    /// A cast already resolved, for titles not in the library.
    init(credits: [CastCredit]) {
        self.people = []
        self.credits = credits
    }

    /// Drops people with no headshot. Server order is kept.
    private var cast: [CastCredit] {
        if let credits {
            return credits.filter { $0.imageURL != nil }
        }
        return people
            .filter { $0.primaryImageTag != nil }
            .map { person in
                CastCredit(
                    id: person.id,
                    name: person.name ?? "",
                    credit: credit(for: person),
                    imageURL: client?.personImageURL(for: person, maxWidth: ArtworkSizing.pixels(for: Metrics.castPortraitSize, displayScale: displayScale))
                )
            }
    }

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cast and Crew")
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)

                #if os(tvOS)
                // Fixed row: eight fit across the screen.
                HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                    ForEach(cast.prefix(Metrics.castCount)) { member in
                        castMember(member)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.top, Metrics.Space.l)
                #else
                // Touch scrolls without focus, so show everyone.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(cast) { member in
                            castMember(member)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.Space.l)
                }
                #endif
            }
        }
    }

    private func credit(for person: Person) -> String? {
        if let role = person.role, !role.isEmpty { return role }
        return person.type
    }

    private func castMember(_ member: CastCredit) -> some View {
        VStack(spacing: Metrics.Space.s) {
            CachedAsyncImage(
                url: member.imageURL,
                maxPixelSize: ArtworkSizing.pixels(for: Metrics.castPortraitSize, displayScale: displayScale)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.artworkPlaceholder
                    Image(systemName: "person.fill")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Metrics.castPortraitSize, height: Metrics.castPortraitSize)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(spacing: Metrics.Space.hair) {
                Text(member.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let credit = member.credit {
                    Text(credit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Metrics.castCaptionWidth)
        }
        .accessibilityElement(children: .combine)
    }
}
