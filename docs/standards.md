# Coding standards

Read this before adding a feature or reorganizing code. The folder names, file
rules, and migration sequence are Lagoon conventions built on Apple and Swift
guidance, not an Apple-mandated template. [Architecture](architecture.md)
describes the current checkout.

## Guidance from Apple and Swift

| Topic | Published guidance | How Lagoon applies it |
| --- | --- | --- |
| Project organization | Apple recommends grouping code by functionality and matching it to the filesystem. [Great Developer Habits, WWDC19](https://developer.apple.com/videos/play/wwdc2019/239/) | Keep a feature's related files together and mirror folders in Xcode. |
| Xcode folders and groups | Xcode supports filesystem folders and groups, including groups without a backing folder. [Managing files and folders](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project) | Preserve the existing filesystem-synchronized app group and verify target membership after moves. |
| Model ownership | Apple separates observable model data from views and establishes a source of truth with `@State`. [Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) | One owner per session or screen model. Views observe it instead of recreating business state. |
| UI state and dependencies | SwiftUI distinguishes local state, bindings, observable models, and environment sharing. [Model data](https://developer.apple.com/documentation/swiftui/model-data) | Keep temporary UI state local. Pass values, actions, or bindings, and reserve environment for context that is genuinely shared. |
| View composition | SwiftUI composes custom views from built-in and other custom views. [Declaring a custom view](https://developer.apple.com/documentation/swiftui/declaring-a-custom-view) | Extract meaningful UI pieces with small inputs and clear state ownership. |
| Modules | Apple recommends local Swift packages to isolate suitable code and improve reuse and maintenance. [Organizing code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages) | Establish a stable boundary first. Add a package only when enforcing that boundary is worth its build and API cost. |
| API naming | Swift emphasizes clarity at the call site and consistent type/member naming. [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) | Use descriptive `UpperCamelCase` types and `lowerCamelCase` members with meaningful argument labels. |

The folder recommendation comes from a WWDC19 talk. Current Xcode
documentation describes the folder and group mechanics. These sources support
the principles above, not Lagoon's exact tree, a `ViewModel` for every view,
or a particular third-party architecture framework.

## Folder structure

Code is organized by feature, with explicitly shared infrastructure:

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
    Diagnostics/               Shared reporting schema, history and transport
  Resources/                   Bundled notices and other resources
  Assets.xcassets/
LagoonTests/                    Unit/integration tests, grouped by subject
LagoonUITests/                  Platform journeys and shared test support
LagoonTopShelf/                 Separate extension target
Packages/LagoonFFmpeg/          Existing native package and build provenance
```

Do not create empty folders just to resemble the diagram. Keep small features
flat, and add subfolders only when they improve navigation. Feature-owned
models and helpers stay beside their feature. Move code to `Shared` only when
independent features need the same contract, not just because its name ends in
`Manager`. Avoid generic `Utils`, `Helpers`, or `Common` dumping grounds.

Follow the feature's existing home for a small fix. For a new feature or a
deliberate extraction, follow this convention and update the architecture map.
Move one cohesive area at a time, and do not keep parallel copies of a type.
See [refactoring priorities](architecture.md#refactoring-priorities) for
ownership boundaries and verification requirements.

## Files and reusable components

- Name a file after its main type, such as `PlaybackController.swift`. Give
  independently useful screens and substantial models their own file. A small
  private helper can stay beside its only caller. One type per file is not an
  absolute rule.
- Extract when responsibilities, state lifetime, or callers differ. A large
  line count is a signal to review, not a hard limit, and not a reason to
  split a cohesive implementation into arbitrary extensions.
- Use `Type+Responsibility.swift` for a focused conformance or extension when
  it aids discovery. Do not widen private state just to spread one coupled
  object across files.
- Keep views focused on rendering and interaction. Put stream negotiation,
  request coordination, reporting, persistence, and resource lifetime in
  explicit owners instead. A view does not automatically need its own
  view-model layer.
- Reuse [existing components](architecture.md#reusable-components) before
  copying markup. Extract a shared view when callers share behavior and
  semantics. Pass a few values, bindings, and actions rather than an entire
  session to a presentational component.
- Share platform-independent behavior, but keep iOS touch controls and tvOS
  focus and remote presentation specific to their platform. Keep `#if os(...)`
  concentrated at those boundaries.
- Comment on the reason for a constraint, especially ownership or timing.
  Remove dead code. Git keeps the history. Do not leave session narratives or
  commented-out code in active source files.

## State, concurrency, and boundaries

These are Lagoon implementation rules:

- Use Observation for new observable state. The view or app that owns a
  model's lifetime stores it in `@State`. Use `@Bindable` when controls need
  bindings to that model. A caller's value is never a second source of truth.
- Respect the project's default `MainActor` isolation. Mark values that cross
  isolation boundaries explicitly, and preserve their safety. Do not use
  `@unchecked Sendable` or broaden isolation to shortcut a compiler error.
  Document and verify the actual synchronization contract instead.
- Every asynchronous operation needs an owner, a cancellation behavior, and a
  policy for late results. Preserve the generation checks on account, query,
  seek, and episode changes. UI loading must not cancel itself by replacing
  the view branch that owns its task.
- Keep networking, credential handling, and response validation in shared
  clients and helpers. Views must not assemble their own authentication rules.
- Playback queues and C/AVFoundation resource lifetimes are explicit
  boundaries. Preserve them during extraction. Keep weak engine references in
  views and narrow Observation reads. The detailed invariants live in
  [Playback](playback.md#lifecycle-and-memory).
- Introduce protocols or local packages only for a concrete boundary, test
  seam, or reuse need. The existing `PlayerEngine` abstraction is one example.
  Do not add a protocol, service layer, or package for every type by default.

## Review and verification

Keep structural moves separate from behavior changes. After moving code,
verify target membership, access control, resource paths, and both iOS and
tvOS builds. Run the relevant existing tests, and add behavioral coverage for
new logic or a regression. Do not add tests that just restate a low-impact
file move.

Verify changed UI visually on both relevant platforms, including tvOS focus
paths and iOS layout and accessibility sizes. Playback changes may also need
handoff, dismissal and replay, PiP, and hardware performance checks. Do not
introduce new compiler warnings, and do not hide them with blanket
suppression.

Follow [Design system](design-system.md) for tokens, native controls, focus,
artwork, and accessibility. Follow [Jellyfin API](jellyfin-api.md) for wire
contracts, and [Release](release.md) for build numbers and release evidence.
Update the guide that owns a changed contract. Keep dated results in the
archive instead of creating a second current specification.
