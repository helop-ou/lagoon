import SwiftUI

/// A cast or crew member's page: who they are, what in the library credits
/// them and, with Seerr connected, the rest of their TMDB career. Opened
/// from a detail page's cast strip or a Seerr person result.
struct PersonDetailView: View {
    let subject: PersonPageSubject

    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: PersonPageModel

    init(subject: PersonPageSubject) {
        self.subject = subject
        _model = State(initialValue: PersonPageModel(subject: subject))
    }

    private var name: String { model.name }

    var body: some View {
        ZStack {
            ThemePageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Metrics.detailSectionSpacing) {
                    header
                    library
                    tmdbTitles
                    biography
                }
                .padding(.vertical, Metrics.Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        // Seerr can finish connecting after the page opens.
        .task(id: seerr.isConnected) {
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
        let width = ArtworkSizing.pixels(for: Metrics.personPortraitSize, displayScale: displayScale)
        switch subject {
        case .library(let person):
            return session.client.personImageURL(
                id: person.id,
                tag: model.libraryDetails?.imageTags?["Primary"] ?? person.primaryImageTag,
                maxWidth: width
            )
        case .tmdb(let person):
            return SeerrClient.imageURL(path: model.tmdbDetails?.profilePath ?? person.profilePath, width: width)
        }
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
            ForEach(model.lifeFacts(locale: .current), id: \.self) { fact in
                Text(fact)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Library

    /// Absent for a TMDB person the library does not know.
    @ViewBuilder
    private var library: some View {
        let title = String(localized: "In Your Library")
        if let titles = model.titles, !titles.isEmpty {
            MediaRail(title: title, items: titles)
                .accessibilityIdentifier("person.library")
        } else if model.isOutsideLibrary {
            EmptyView()
        } else if let titles = model.titles, titles.isEmpty {
            RailPlaceholder(title: title, minHeight: 0) {
                // Focusable on tvOS: with no titles and no biography this
                // may be the page's only focus target, and without one Menu
                // quits the app.
                placeholderText("Nothing in your library credits \(name).")
                    .accessibilityIdentifier("person.library.empty")
            }
        } else if model.titlesFailed {
            RailPlaceholder(title: title, minHeight: 0) {
                InlineRetryView(message: String(localized: "Couldn't load the titles.")) {
                    model.prepareRetry()
                    Task { await load() }
                }
            }
        } else {
            loadingPlaceholder(title: title)
        }
    }

    // MARK: TMDB

    /// A library person's page shows the rail only when it has titles, so
    /// without Seerr it reads as before. A TMDB person's page always has the
    /// section: it may be all there is to focus.
    @ViewBuilder
    private var tmdbTitles: some View {
        let title = String(localized: "More from TMDB")
        if let titles = model.tmdbTitles, !titles.isEmpty {
            SeerrMediaRail(title: title, items: titles)
                .accessibilityIdentifier("person.tmdb")
        } else if case .tmdb = subject {
            if model.tmdbTitles != nil {
                RailPlaceholder(title: title, minHeight: 0) {
                    placeholderText("TMDB lists nothing else for \(name).")
                        .accessibilityIdentifier("person.tmdb.empty")
                }
            } else if model.tmdbTitlesFailed {
                RailPlaceholder(title: title, minHeight: 0) {
                    InlineRetryView(message: String(localized: "Couldn't load the titles.")) {
                        model.prepareRetry()
                        Task { await load() }
                    }
                }
            } else {
                loadingPlaceholder(title: title)
            }
        }
    }

    private func placeholderText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            #if os(tvOS)
            .focusable()
            #endif
    }

    private func loadingPlaceholder(title: String) -> some View {
        RailPlaceholder(title: title) {
            ProgressView()
                #if os(tvOS)
                // Holds focus until the rail replaces it.
                .focusable()
                #endif
        }
    }

    // MARK: Biography

    @ViewBuilder
    private var biography: some View {
        let paragraphs = PersonDetails.paragraphs(of: model.biography)
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

    private func load() async {
        await model.load(jellyfin: session.client, seerr: seerr.isConnected ? seerr.client : nil)
    }
}

extension PersonDetails {
    /// "Born April 20, 1945 in Pittsburgh, Pennsylvania, USA", then "Died …",
    /// each only as far as it is known.
    func lifeFacts(locale: Locale) -> [String] {
        let place = productionLocations?.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Self.lifeFacts(born: premiereDate, place: place, died: endDate, locale: locale)
    }

    /// The same from any source's wire dates: TMDB's `yyyy-MM-dd` reads like
    /// the start of Jellyfin's timestamp.
    static func lifeFacts(born bornWire: String?, place placeWire: String?, died diedWire: String?, locale: Locale) -> [String] {
        var facts: [String] = []
        let born = displayDate(bornWire, locale: locale)
        let place = placeWire.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
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
        if let died = displayDate(diedWire, locale: locale) {
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
