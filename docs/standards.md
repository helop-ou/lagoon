# Coding standards

Read this before adding a feature or reorganizing code. The Apple/Swift
guidance below was checked on September 10, 2026. The concrete folder names,
file rules, and migration sequence are Lagoon conventions adopted from those
principles; they are not an Apple-mandated template or an already-completed
reorganization. [Architecture](architecture.md) describes the current checkout.

## Guidance from Apple and Swift

| Topic | Published guidance | How Lagoon applies it |
| --- | --- | --- |
| Project organization | Apple recommends grouping code by functionality and matching project organization to the filesystem. [Great Developer Habits, WWDC19](https://developer.apple.com/videos/play/wwdc2019/239/) | Keep a feature's related files together; mirror physical folders in Xcode. |
| Xcode folders and groups | Xcode supports both filesystem folders and groups, including groups without backing folders. [Managing files and folders](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project) | Preserve the existing filesystem-synchronized app group and verify target membership after moves. |
| Model ownership | Apple separates observable model data from views and establishes a source of truth with `@State`. [Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) | One owner per session/screen model; views observe it instead of recreating business state. |
| UI state and dependencies | SwiftUI distinguishes local state, bindings, observable models, and environment sharing. [Model data](https://developer.apple.com/documentation/swiftui/model-data) | Keep temporary UI state local; pass values/actions or bindings, and use environment for genuinely shared context. |
| View composition | SwiftUI composes custom views from built-in and other custom views. [Declaring a custom view](https://developer.apple.com/documentation/swiftui/declaring-a-custom-view) | Extract meaningful UI pieces with small inputs and clear state ownership. |
| Modules | Apple recommends local Swift packages to isolate suitable code and improve reuse and maintenance. [Organizing code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages) | Establish a stable boundary first; use a package when enforcing that boundary is worth its build/API cost. |
| API naming | Swift emphasizes clarity at the call site and consistent type/member naming. [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) | Use descriptive `UpperCamelCase` types and `lowerCamelCase` members with meaningful argument labels. |

The folder recommendation comes from a WWDC19 talk; current Xcode documentation
describes the folder/group mechanics. These sources support the principles
above. They do not prescribe Lagoon's exact tree, a `ViewModel` for every view,
or a particular third-party architecture framework.

## Folder structure

The target convention is organization by feature, with explicitly shared
infrastructure. This is a migration destination, not a claim about today's tree:

```text
Lagoon/
  App/                         Entry, root composition, app navigation
  Features/
    Accounts/                  Connection, sign-in, account selection
    Home/
    Library/
    Discovery/                 Seerr browse, requests, and details
    Detail/                    Jellyfin item, series, and collection details
    Search/
    Settings/
    Playback/
      PlaybackController.swift
      Views/                   Surface, controls, overlays, presentation
      Engine/                  Demux/decode/render pipeline
      Transport/               Playback byte sources and cache
      Subtitles/               Parsing, decoding, and selection work
      Diagnostics/             Playback traces and benchmarks
  Shared/
    UI/                        Components used across features
    Networking/                Shared clients, request/auth/download handling
    Models/                    Shared DTOs and value types
    Persistence/               Credential and account storage infrastructure
  Resources/                   Bundled notices and other resources
  Assets.xcassets/
LagoonTests/                    Unit/integration tests, grouped by subject
LagoonUITests/                  Platform journeys and shared test support
LagoonTopShelf/                 Separate extension target
Packages/LagoonFFmpeg/          Existing native package and build provenance
```

Do not create empty folders to resemble the diagram. Keep small features flat;
add subfolders only when they improve navigation. Feature-owned models and
helpers stay beside their feature. Move code to `Shared` when independent
features need the same contract, not simply because its name ends in `Manager`.
Avoid generic `Utils`, `Helpers`, or `Common` dumping grounds.

The existing `Views/<Feature>`, `ViewModels`, `Models`, and `Networking`
locations remain valid while migration is incomplete. Follow a feature's
current location when making a small fix. For a new feature or a deliberate
extraction, follow the target convention and update the current architecture
map. Move one cohesive area at a time; do not maintain parallel copies of a
type in both layouts. The [refactoring sequence](architecture.md#refactoring-priorities)
starts with the player.

## Files and reusable components

- Name a file after its main type, such as `PlaybackController.swift`.
  Give independently useful screens and substantial models their own files.
  Small private helpers may remain beside their only caller; one type per file
  is not an absolute rule.
- Extract when responsibilities, state lifetime, or callers differ. A large
  line count is a review signal, not a numeric failure or a reason to split a
  cohesive implementation into arbitrary extensions.
- Use `Type+Responsibility.swift` for a focused conformance or extension when
  it improves discovery. Do not widen private state simply to spread one
  coupled object across files.
- Keep views focused on rendering and interaction. Put stream negotiation,
  request coordination, reporting, persistence, and resource lifetime in
  explicit owners. A view does not automatically need a new view-model layer.
- Reuse the [existing components](architecture.md#reusable-components) before
  copying markup. Extract a shared view when callers share behavior and
  semantics. Prefer a few value inputs, bindings, and actions over passing an
  entire session to a presentational component.
- Share platform-independent behavior while keeping iOS touch controls and
  tvOS focus/remote presentation appropriate to their platforms. Keep
  `#if os(...)` concentrated near those platform boundaries.
- Comment on the reason for a constraint, especially ownership or timing.
  Remove dead code; Git retains history. Do not retain session narratives or
  commented-out implementations in active source files.

## State, concurrency, and boundaries

These are Lagoon implementation rules:

- Use Observation for new observable state. The view/app that owns a model's
  lifetime stores it in `@State`; use `@Bindable` when controls need bindings
  to that model. A caller's value is not a second source of truth.
- Respect the project's default `MainActor` isolation. Mark values that cross
  isolation boundaries explicitly and preserve their safety. Do not use
  `@unchecked Sendable` or broaden isolation as a shortcut around a compiler
  error; document and verify the actual synchronization contract.
- Every asynchronous operation needs an owner, cancellation behavior, and a
  policy for late results. Preserve generation checks on account, query,
  seek, and episode changes. UI loading must not cancel itself by replacing
  the view branch that owns its task.
- Keep networking, credential handling, and response validation in shared
  clients/helpers. Views must not assemble their own authentication rules.
- Playback queues and C/AVFoundation resource lifetimes are explicit
  boundaries. Preserve them during extraction. In particular, retain weak
  engine references in views and narrow Observation reads; the detailed
  invariants live in [Playback](playback.md#lifecycle-and-memory).
- Introduce protocols or local packages where there is a concrete boundary,
  test seam, or reuse need. The existing `PlayerEngine` abstraction is one.
  Do not add a protocol, service layer, or package for every type by default.

## Review and verification

Keep structural moves separate from behavior changes. Verify target membership,
access control, resource paths, and both iOS/tvOS builds after moving code.
Run the relevant existing tests; add behavioral coverage for new logic or a
regression, not tests that merely restate a low-impact file move.

Verify changed UI visually on both relevant platforms, including tvOS focus
paths and iOS layout/accessibility sizes. Playback changes may additionally
require handoff, dismissal/replay, PiP, and hardware performance checks.
Do not introduce new compiler warnings or hide them with blanket suppression.

Follow [Design system](design-system.md) for tokens, native controls, focus,
artwork, and accessibility; [Jellyfin API](jellyfin-api.md) for wire contracts;
and [Release](release.md) for build numbers and release evidence. Update the
guide that owns a changed contract. Keep dated results in the archive instead
of creating a second current specification.
