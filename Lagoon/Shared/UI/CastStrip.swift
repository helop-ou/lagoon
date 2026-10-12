import SwiftUI

/// One person in the cast strip, from Jellyfin or from Seerr's TMDB credits.
struct CastCredit: Identifiable, Hashable {
    let id: String
    let name: String
    /// The character for actors, the job for crew.
    let credit: String?
    let imageURL: URL?
    /// The library person the card opens. Nil for Seerr's TMDB credits,
    /// which have no Jellyfin person behind them.
    var person: Person? = nil
}

/// Cast and crew. Library people are a rail of round cards that open the
/// person's page. Seerr's credits open nothing, so on tvOS they stay a
/// fixed, unfocusable row that focus moving past scrolls into view.
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

    /// Server order is kept. Library people without a headshot keep their
    /// place behind a placeholder; Seerr's are dropped.
    private var cast: [CastCredit] {
        if let credits {
            return credits.filter { $0.imageURL != nil }
        }
        let portraitWidth = ArtworkSizing.pixels(for: Metrics.castPortraitSize, displayScale: displayScale)
        return people.enumerated().map { offset, person in
            CastCredit(
                // One person can hold several credits, director and writer.
                id: "\(offset).\(person.id)",
                name: person.name ?? "",
                credit: Self.caption(role: person.role, type: person.type),
                imageURL: client?.personImageURL(for: person, maxWidth: portraitWidth),
                person: person
            )
        }
    }

    var body: some View {
        if !cast.isEmpty {
            #if os(tvOS)
            if credits == nil {
                rail
            } else {
                fixedRow
            }
            #else
            rail
            #endif
        }
    }

    private var rail: some View {
        RailShelf(title: String(localized: "Cast and Crew"), alignment: .top) {
            ForEach(cast) { member in
                castMember(member)
            }
        }
        .accessibilityIdentifier("detail.cast")
    }

    #if os(tvOS)
    private var fixedRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cast and Crew")
                .font(.headline)
                .padding(.leading, Metrics.screenGutter)

            HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                ForEach(cast.prefix(Metrics.castCount)) { member in
                    castMember(member)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.top, Metrics.Space.l)
        }
    }
    #endif

    /// The character for an actor, the job for crew, else the kind of
    /// credit in words ("GuestStar" reads "Guest Star").
    static func caption(role: String?, type: String?) -> String? {
        if let role = role?.trimmingCharacters(in: .whitespaces), !role.isEmpty {
            return role
        }
        guard let type, !type.isEmpty else { return nil }
        var words = ""
        for character in type {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        return words
    }

    @ViewBuilder
    private func castMember(_ member: CastCredit) -> some View {
        if let person = member.person {
            #if os(tvOS)
            // Only the portrait is the button, as in the profile picker: the
            // card lift follows the circle and the name stays put beneath.
            VStack(spacing: Metrics.Space.l) {
                NavigationLink(value: ContentNavigationRoute.person(person)) {
                    portrait(member)
                }
                .cardButtonStyle()
                .buttonBorderShape(.circle)
                .accessibilityLabel(accessibilityLabel(member))
                .accessibilityIdentifier("cast.member.\(person.id)")

                caption(member)
                    .accessibilityHidden(true)
            }
            #else
            NavigationLink(value: ContentNavigationRoute.person(person)) {
                VStack(spacing: Metrics.Space.s) {
                    portrait(member)
                    caption(member)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cast.member.\(person.id)")
            #endif
        } else {
            VStack(spacing: Metrics.Space.s) {
                portrait(member)
                caption(member)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func accessibilityLabel(_ member: CastCredit) -> String {
        guard let credit = member.credit else { return member.name }
        return "\(member.name), \(credit)"
    }

    private func portrait(_ member: CastCredit) -> some View {
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
    }

    private func caption(_ member: CastCredit) -> some View {
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
}
