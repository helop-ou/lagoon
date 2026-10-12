import SwiftUI

/// A cast or crew member's page: who they are, and what in the library
/// credits them. Opened from a detail page's cast strip.
struct PersonDetailView: View {
    let person: Person

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var details: PersonDetails?
    /// Nil until the first answer, so loading and an empty library differ.
    @State private var titles: [MediaItem]?
    @State private var titlesFailed = false

    private var name: String { details?.name ?? person.name ?? "" }

    var body: some View {
        ZStack {
            ThemePageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Metrics.detailSectionSpacing) {
                    header
                    library
                    biography
                }
                .padding(.vertical, Metrics.Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .task(id: person.id) {
            await load()
        }
        .onChange(of: serverSync.generation) { _, _ in
            Task { await load() }
        }
        .accessibilityIdentifier("person.page")
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Metrics.Space.l) {
                    portrait
                    identity
                }
            } else {
                HStack(alignment: .center, spacing: Metrics.Space.xl) {
                    portrait
                    identity
                }
            }
        }
        .padding(.horizontal, Metrics.screenGutter)
    }

    private var portraitURL: URL? {
        session.client.personImageURL(
            id: person.id,
            tag: details?.imageTags?["Primary"] ?? person.primaryImageTag,
            maxWidth: ArtworkSizing.pixels(for: Metrics.personPortraitSize, displayScale: displayScale)
        )
    }

    private var portrait: some View {
        CachedAsyncImage(
            url: portraitURL,
            maxPixelSize: ArtworkSizing.pixels(for: Metrics.personPortraitSize, displayScale: displayScale)
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.artworkPlaceholder
                Image(systemName: "person.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Metrics.personPortraitSize, height: Metrics.personPortraitSize)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(name)
                #if os(tvOS)
                .font(.largeTitle.bold())
                #else
                .font(.title.bold())
                #endif
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("person.name")
            ForEach(details?.lifeFacts(locale: .current) ?? [], id: \.self) { fact in
                Text(fact)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Library

    @ViewBuilder
    private var library: some View {
        let title = String(localized: "In Your Library")
        if let titles, !titles.isEmpty {
            MediaRail(title: title, items: titles)
                .accessibilityIdentifier("person.library")
        } else if let titles, titles.isEmpty {
            RailPlaceholder(title: title, minHeight: 0) {
                // Focusable on tvOS: with no titles and no biography this
                // may be the page's only focus target, and without one Menu
                // quits the app.
                Text("Nothing in your library credits \(name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(tvOS)
                    .focusable()
                    #endif
                    .accessibilityIdentifier("person.library.empty")
            }
        } else if titlesFailed {
            RailPlaceholder(title: title, minHeight: 0) {
                InlineRetryView(message: String(localized: "Couldn't load the titles.")) {
                    titlesFailed = false
                    Task { await load() }
                }
            }
        } else {
            RailPlaceholder(title: title) {
                ProgressView()
                    #if os(tvOS)
                    // Holds focus until the rail replaces it.
                    .focusable()
                    #endif
            }
        }
    }

    // MARK: Biography

    @ViewBuilder
    private var biography: some View {
        let paragraphs = PersonDetails.paragraphs(of: details?.overview)
        if !paragraphs.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                Text("Biography")
                    .font(.headline)
                // Focusable so tvOS can scroll it: Down walks the text.
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Metrics.detailOverviewWidth, alignment: .leading)
                        #if os(tvOS)
                        .focusable()
                        #endif
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
            .accessibilityIdentifier("person.biography")
        }
    }

    // MARK: Loading

    /// A failed refresh keeps what is on screen.
    private func load() async {
        let generation = serverSync.generation
        async let fetchedDetails = try? session.client.person(id: person.id)
        async let fetchedTitles = try? session.client.itemsCrediting(personId: person.id)
        let (newDetails, newTitles) = await (fetchedDetails, fetchedTitles)
        guard generation == serverSync.generation, !Task.isCancelled else { return }
        if let newDetails { details = newDetails }
        if let newTitles {
            titles = newTitles
            titlesFailed = false
        } else if titles == nil {
            titlesFailed = true
        }
    }
}

extension PersonDetails {
    /// "Born April 20, 1945 in Pittsburgh, Pennsylvania, USA", then "Died …",
    /// each only as far as it is known.
    func lifeFacts(locale: Locale) -> [String] {
        var facts: [String] = []
        let born = Self.displayDate(premiereDate, locale: locale)
        let place = productionLocations?
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        switch (born, place) {
        case let (born?, place?):
            facts.append(String(localized: "Born \(born) in \(place)", locale: locale))
        case let (born?, nil):
            facts.append(String(localized: "Born \(born)", locale: locale))
        case let (nil, place?):
            facts.append(String(localized: "Born in \(place)", locale: locale))
        case (nil, nil):
            break
        }
        if let died = Self.displayDate(endDate, locale: locale) {
            facts.append(String(localized: "Died \(died)", locale: locale))
        }
        return facts
    }

    /// The calendar date at the start of Jellyfin's timestamp, written out
    /// for `locale`. Read from the digits, not decoded as a `Date`, so no
    /// time zone can move a birthday by a day.
    static func displayDate(_ wire: String?, locale: Locale) -> String? {
        guard let wire else { return nil }
        let parts = wire.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        return date.formatted(
            Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: .gmt)
        )
    }

    /// The biography split at its line breaks, blank lines dropped.
    static func paragraphs(of overview: String?) -> [String] {
        (overview ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
