import Foundation
import Observation

/// Who a person page is about.
nonisolated enum PersonPageSubject: Hashable {
    /// Someone in a library title's cast.
    case library(Person)
    /// Someone from Seerr's cast or search, who may not be in the library.
    case tmdb(SeerrPerson)
}

/// A person page's data. A library person reaches TMDB through their
/// provider id; a TMDB person reaches the library through a name search
/// checked against that id. A failed refresh keeps what is on screen, and
/// only the latest load commits. Outside the view so it can be tested.
@Observable
final class PersonPageModel {
    let subject: PersonPageSubject
    /// The library person: the subject's own, or a TMDB subject's match.
    private(set) var libraryDetails: PersonDetails?
    /// Seerr's biography, loaded only for a TMDB subject.
    private(set) var tmdbDetails: SeerrPersonDetails?
    /// Nil until the first answer, so loading and an empty library differ.
    private(set) var titles: [MediaItem]?
    private(set) var titlesFailed = false
    /// A TMDB subject the library does not know: no library rail at all.
    private(set) var isOutsideLibrary = false
    /// Their TMDB titles not in the library. Nil until known, and while
    /// Seerr is not connected or the person has no TMDB id.
    private(set) var tmdbTitles: [SeerrDiscoverResult]?
    private(set) var tmdbTitlesFailed = false
    private var loadGeneration = 0

    init(subject: PersonPageSubject) {
        self.subject = subject
    }

    var name: String {
        switch subject {
        case .library(let person):
            libraryDetails?.name ?? person.name ?? ""
        case .tmdb(let person):
            tmdbDetails?.name ?? person.name
        }
    }

    var biography: String? {
        switch subject {
        case .library: libraryDetails?.overview
        case .tmdb: tmdbDetails?.biography
        }
    }

    func lifeFacts(locale: Locale) -> [String] {
        switch subject {
        case .library:
            libraryDetails?.lifeFacts(locale: locale) ?? []
        case .tmdb:
            tmdbDetails.map {
                PersonDetails.lifeFacts(born: $0.birthday, place: $0.placeOfBirth, died: $0.deathday, locale: locale)
            } ?? []
        }
    }

    /// `seerr` is nil while Seerr is not connected.
    func load(jellyfin: JellyfinClient, seerr: SeerrClient?) async {
        loadGeneration += 1
        let generation = loadGeneration
        var isCurrent: Bool { generation == loadGeneration && !Task.isCancelled }

        switch subject {
        case .library(let person):
            async let fetchedDetails = try? jellyfin.person(id: person.id)
            async let fetchedTitles = try? jellyfin.itemsCrediting(personId: person.id)
            let (newDetails, newTitles) = await (fetchedDetails, fetchedTitles)
            guard isCurrent else { return }
            if let newDetails { libraryDetails = newDetails }
            commitTitles(newTitles)

            guard let seerr, let tmdbID = libraryDetails?.tmdbID else {
                tmdbTitles = nil
                tmdbTitlesFailed = false
                return
            }
            let credits = try? await seerr.personCredits(id: tmdbID)
            guard isCurrent else { return }
            commitCredits(credits)

        case .tmdb(let person):
            async let fetchedDetails = try? seerr?.person(id: person.id)
            async let fetchedCredits = try? seerr?.personCredits(id: person.id)
            async let lookup = Self.lookUpLibraryPerson(person, jellyfin: jellyfin)
            let (newDetails, newCredits, newLookup) = await (fetchedDetails, fetchedCredits, lookup)
            guard isCurrent else { return }
            if let newDetails { tmdbDetails = newDetails }
            switch newLookup {
            case .found(let details, let newTitles):
                libraryDetails = details
                isOutsideLibrary = false
                commitTitles(newTitles)
            case .notFound:
                isOutsideLibrary = true
                titles = []
                titlesFailed = false
            case .failed:
                commitTitles(nil)
            }
            if seerr == nil {
                tmdbTitles = []
                tmdbTitlesFailed = false
            } else {
                commitCredits(newCredits)
            }
        }
    }

    /// Back to loading, so a retry shows progress rather than the failure.
    func prepareRetry() {
        titlesFailed = false
        tmdbTitlesFailed = false
    }

    private func commitTitles(_ newTitles: [MediaItem]?) {
        if let newTitles {
            titles = newTitles
            titlesFailed = false
        } else if titles == nil {
            titlesFailed = true
        }
    }

    private func commitCredits(_ credits: SeerrPersonCredits?) {
        if let credits {
            let libraryKeys = Set((titles ?? []).compactMap(SeerrPersonCredits.key))
            tmdbTitles = credits.filmography(excluding: libraryKeys)
            tmdbTitlesFailed = false
        } else if tmdbTitles == nil {
            tmdbTitlesFailed = true
        }
    }

    private enum LibraryLookup {
        /// The person, and their titles if those loaded.
        case found(PersonDetails, [MediaItem]?)
        case notFound
        case failed
    }

    private static func lookUpLibraryPerson(_ person: SeerrPerson, jellyfin: JellyfinClient) async -> LibraryLookup {
        do {
            guard let match = try await jellyfin.person(tmdbID: person.id, name: person.name) else { return .notFound }
            return .found(match, try? await jellyfin.itemsCrediting(personId: match.id))
        } catch {
            return .failed
        }
    }
}
