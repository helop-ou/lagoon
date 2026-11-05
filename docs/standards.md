# Coding standards

Read this before adding a feature or reorganizing code. These are Lagoon
conventions built on Apple and Swift guidance. [Architecture](architecture.md)
maps the current checkout.

## Guidance from Apple and Swift

| Topic | Source | How Lagoon applies it |
| --- | --- | --- |
| Project organization | [Great Developer Habits, WWDC19](https://developer.apple.com/videos/play/wwdc2019/239/) | Group files by feature and mirror folders in Xcode. |
| Folders and groups | [Managing files and folders](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project) | Keep the filesystem-synchronized app group. Check target membership after a move. |
| Model ownership | [Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) | One owner per session or screen model. Views observe it rather than rebuild business state. |
| UI state and dependencies | [Model data](https://developer.apple.com/documentation/swiftui/model-data) | Temporary UI state stays local. Pass values, actions or bindings. Use the environment only for truly shared context. |
| View composition | [Declaring a custom view](https://developer.apple.com/documentation/swiftui/declaring-a-custom-view) | Extract meaningful pieces with small inputs and clear state ownership. |
| Modules | [Organizing code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages) | Add a package only when enforcing a stable boundary is worth its build and API cost. |
| API naming | [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) | `UpperCamelCase` types, `lowerCamelCase` members, meaningful argument labels. |

These support the principles, not Lagoon's exact tree, a `ViewModel` per view,
or any third-party architecture framework.

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
    Downloads/
    Search/
    Settings/
    SyncPlay/                  Watch Together
    Playback/                  Controller, views, session, tracks, subtitles
  Shared/
    UI/                        Components used across features
    Networking/                Shared clients, request/auth/download handling
    Models/                    Shared DTOs and value types
    Persistence/               Credential and account storage
    Diagnostics/               Shared reporting schema, history and transport
  Resources/                   Bundled notices and other resources
  Assets.xcassets/
LagoonTests/                   Unit/integration tests, grouped by subject
LagoonUITests/                 Platform journeys and shared test support
LagoonTopShelf/                Separate extension target
```

[Architecture](architecture.md#project-layout) has the full map. Demux,
decode, render and the byte cache live in the `LagoonEngine` package, not
here.

- Do not create empty folders to match the diagram. Keep small features flat.
- Feature-owned models and helpers stay beside their feature. Move code to
  `Shared` only when independent features need the same contract.
- No `Utils`, `Helpers` or `Common` dumping grounds.
- A small fix follows the feature's existing home. A new feature or deliberate
  extraction follows this layout and updates the architecture map.
- Move one cohesive area at a time, and never keep parallel copies of a type.
  See [refactoring priorities](architecture.md#refactoring-priorities).

## Files and reusable components

- Name a file after its main type. Screens and substantial models get their
  own file, and a small private helper can stay beside its only caller.
- Extract when responsibilities, state lifetime or callers differ. Line count
  is a prompt to review, not a limit.
- Use `Type+Responsibility.swift` for a focused conformance or extension. Do
  not widen private state just to spread one object across files.
- Views render and handle interaction. Stream negotiation, request
  coordination, reporting, persistence and resource lifetime belong to
  explicit owners. A view does not need its own view-model layer by default.
- Reuse [existing components](architecture.md#reusable-components) before
  copying markup. Pass a presentational component a few values, bindings and
  actions, not a whole session.
- Share platform-independent behavior. Keep iOS touch and tvOS focus and
  remote handling platform-specific, with `#if os(...)` at those boundaries.
- Comments explain the reason for a constraint, especially ownership or
  timing. No dead code, commented-out code or session narratives.
- No ticket keys in comments or commit messages. Incident ids, measurement
  runs, attempt counts and dates belong in `docs/` or `docs/reference/`.

## State, concurrency, and boundaries

- Use Observation for new observable state. The owner of a model's lifetime
  stores it in `@State`, and controls that need bindings use `@Bindable`. A
  caller's value is never a second source of truth.
- Respect the default `MainActor` isolation. Mark values that cross isolation
  explicitly. Never use `@unchecked Sendable` or broaden isolation to silence
  the compiler. Document and verify the real synchronization contract.
- Every async operation has an owner, a cancellation behavior and a policy for
  late results. Keep the generation checks on account, query, seek and
  episode changes. UI loading must not cancel itself by replacing the view
  branch that owns its task.
- Networking, credentials and response validation live in shared clients.
  Views never assemble their own authentication.
- Views hold the engine weakly and keep Observation reads narrow. The details
  are in [Playback](playback.md#lifecycle-and-memory).
- Add a protocol or package only for a concrete boundary, test seam or reuse
  need, like `PlayerEngine`. Not for every type.

## Review and verification

- Keep structural moves separate from behavior changes. After a move, check
  target membership, access control, resource paths, and both iOS and tvOS
  builds.
- Run the relevant tests. Add behavioral coverage for new logic or a
  regression, not tests that restate a file move.
- Verify changed UI on both platforms: tvOS focus paths, iOS layout and
  accessibility sizes. Playback changes may also need handoff, dismissal and
  replay, PiP and hardware performance checks.
- No new compiler warnings, and no blanket suppression.

### Pull requests

Work reaches `main` through a pull request from a feature branch. The types
are the commit types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`,
`build`, `chore`, `ci`, `style` and `revert`.

- **Branch:** `<type>/<kebab-case-words>`, such as `fix/home-screen-sections`.
- **Title:** written like a commit subject, `<type>: <lowercase start>`, at
  most 72 characters, no full stop: `fix: show Home Screen Sections rows`.
- **Commits:** a conventional subject line and nothing else: no body, no
  trailers.
- **Description:** a short list and nothing more:

  ```
  Changes:
  - Run the unit tests on tvOS and iOS for every pull request
  - Install the Metal toolchain the runner lacks
  ```

  One plain line per change. Something the reviewer must act on, such as
  "Needs a device check", is one more line. Rationale goes in the guide that
  owns the area, not the description.
- **No Sentry issue ids or Jira keys** in any of them.
- **Related changes that build on each other** go in a GitHub stack
  (`gh stack`), one pull request per theme, merged from the bottom up, such
  as a feature and then its snapshot tests. Unrelated changes are separate
  pull requests, never one stack.
- **Every stack is linked on GitHub**, not left as pull requests that only
  target each other's branches. Open each with `gh pr create` against the
  branch below it, so its title and description pass the checks, then link
  them bottom to top with `gh stack link <bottom> <top>`. A linked stack is
  rebased and merged as one, so a follow-up never lands on a stale base.
- **Rebase a branch that falls behind `main`, never merge `main` into it.**
  `main` takes rebase merges only, which replay each commit and drop merge
  commits, so a conflict resolved in a merge commit comes back on merge and
  GitHub refuses the pull request or its stack while every check is green.
  Rebase the branch, and the ones stacked on it, onto `origin/main`, resolve
  each conflict in the commit that causes it, and push with
  `--force-with-lease` (`gh stack sync` does all of it for a stack).
- **Coverage decides where the tests go.** SonarCloud scores each pull
  request on its own and wants 80 % of new code covered. New code in a file
  that `sonar.coverage.exclusions` does not exclude needs the tests that run
  it in the same pull request, snapshots included. Then the feature and its
  tests are the bottom of the stack, and anything built on them goes above.
  Views and `Lagoon/Shared/UI` are excluded, so their snapshots can still be
  a pull request of their own. Check the changed files against the
  exclusions before splitting.

`.github/workflows/conventions.yml` runs `scripts/check-pull-request.sh` on
every pull request and again when its title or description is edited, and
`main` requires it to pass. The script reads the pull request from the
environment, so it runs locally the same way (usage is at its top).
`.githooks/pre-push` runs its branch and commit checks on every push, before
anything reaches GitHub. Turn it on once per clone with
`git config core.hooksPath .githooks`.
`.github/CODEOWNERS` names the owner of every file, whose review GitHub
requests on each pull request.

### Continuous integration

`.github/workflows/tests.yml` runs the unit suite on tvOS and iOS for every
pull request, the same `xcodebuild test` as a local run, and `main` accepts
only pull requests whose two test jobs passed. It runs again on each merge
to `main`, so SonarCloud's dashboard for `main` stays current. Nothing runs on
a schedule: a run with no new code can only fail because of the runner or a
server. CI is a
backstop, not a replacement: run the tests before pushing, because CI only
reports after the push.

- It uses GitHub's `xcode-27` runner image (a preview) with Xcode 27.2, the
  version Lagoon is developed with. When the local Xcode moves, move
  `DEVELOPER_DIR` in both workflows in the same change, after checking the
  [image's list](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
  has it.
- iOS runs on iPhone 17, as the image has no iPhone 17 Pro. tvOS runs on the
  Apple TV 4K (4th generation), or the 3rd on an image without tvOS 27.2.
  `scripts/pick-simulator.py` chooses a device whose runtime is installed: an
  image update once kept the 3rd generation listed after dropping its
  runtime, and every tvOS job failed with "Unable to find a destination".
- The image lacks the Metal toolchain, a separate Xcode download Lagoon's
  shaders need, so each run installs it first.
- The engine resolves from `Package.resolved` and is cached by its hash, so
  a pin move refetches it once.
- A failed run keeps its `.xcresult` and full log for 14 days, under the
  run's artifacts.
- UI journeys do not run in CI: they need a server and minutes per test. See
  the [regression lane](reference/regression-lane.md). The exception is
  `DuoLayoutUITests`, because a closed iPhone Duo is the only place its bug
  shows and no unit test reaches it. A third job runs it on the image's
  iPhone Duo on its newest iOS, which starts closed, against the public
  demo. It runs on pull requests only and is not a required check.
- Both test jobs collect coverage, and `scripts/coverage-to-sonar.py` turns
  each result bundle into Sonar's format. A third job then runs the SonarCloud
  scan with both reports, using the `SONAR_TOKEN` secret, and SonarCloud's
  app reports the quality gate on the pull request. The scan action is the
  one action from outside GitHub that the repository allows, pinned to a
  commit. Move the pin and its version comment together.
  `sonar-project.properties` says which folders are app code and which are
  tests, and leaves SwiftUI views out of coverage: snapshots and the
  simulator check those. Automatic analysis in SonarCloud must stay off, or
  the two analyses collide. A fork's pull request has no secrets, so it skips
  the scan.

[Design system](design-system.md) owns tokens, controls, focus, artwork and
accessibility, [Jellyfin API](jellyfin-api.md) owns wire contracts, and
[Release](release.md) owns build numbers and release evidence. Update the
guide that owns a contract when you change it.
