# Source migration and diagnostics sampling

Implementation plan for HEL-155 and the diagnostics opt-out follow-up, started
September 11, 2026. The target conventions remain in [Coding standards](../standards.md).

## Work sequence

1. Preserve the starting checkout and its pre-existing diagnostics changes;
   establish iOS/tvOS build and unit-test baselines.
2. Finish diagnostics opt-out: stop periodic renderer sampling while reporting
   is disabled, handle switching back on, and cover the lifecycle with tests.
3. Extract `PlaybackController` without changing the view's ownership, then
   isolate reporting, successor preparation and diagnostic sampling around
   explicit cancellation/resource boundaries. Move playback into its feature.
4. Move app composition, the remaining features and shared infrastructure.
   Extract Seerr request list/detail ownership and Settings category/platform
   composition without changing UI behavior.
5. Consolidate the player UI-test harness, preserving platform defaults and
   fixture failure/skip semantics.
6. Update source paths in tooling and current documentation, verify membership,
   resources, access control and absence of obsolete source folders.
7. Run both platform builds/unit suites and player UI journeys; inspect changed
   screens on both platforms. Record physical lifecycle and performance evidence
   separately from simulator checks.

The primary agent owns playback, integration and validation. Separate agents
own diagnostics, non-playback feature migration and UI-test support. Ownership
handoffs precede moving files another agent is editing. Native artifacts and
target boundaries remain as they are. Structural changes and diagnostic
behavior changes must be distinguishable in review.

## Verification

- Baseline source snapshot: `/tmp/lagoon-hel155-start`, including the starting
  revision and pre-existing working patch. The unchanged native package is
  linked from the workspace; the snapshot is for local comparison, not archival
  reproduction after package changes.
- Build/unit scheme: `Lagoon`, iOS and tvOS simulator destinations.
- UI scheme: `LagoonHardwareRegression`, `PlayerRegressionUITests` on tvOS and
  `TouchPlayerUITests` plus `SettingsUITests` on iPhone/iPad. Settings checks
  cover category bindings, persistence and the largest accessibility text size.
  Required specialized media must actually run; fixture skips do not establish
  coverage.
- Playback invariants: weak engine references, narrow Observation reads,
  ordered reports, two-phase stop, bounded engine retirement, one active cache
  and at most one staged successor, cancellation of obsolete work.
- Hardware acceptance: dismissal/replay, handoff and supported PiP flows; same
  scene/media window/configuration/display path, at least three untouched runs
  per build for the frame-loss comparison. Isolate sampler cost with reporting
  on/off and HUD/decode trace disabled; document any bench-driven metric loads.
  Simulator results cannot establish physical performance parity.

## Progress

- Starting checkout and pre-existing diagnostics changes preserved; both
  baseline unit suites captured, including their shared ledger timing failure.
- Diagnostics opt-out, playback owners, feature migration, Settings/Seerr
  splits, grouped unit tests and shared UI-test support implemented and reviewed
  across four agents. The existing UI-test target now supports both platforms.
- Final migrated unit suites and both unsigned Release device builds passed.
  Move/resource/target audits and release-script syntax checks passed.
- The available simulator checks passed: the tvOS player suite, iPhone/iPad
  touch journeys, and Settings binding/persistence/accessibility journeys.
  Settings screenshots were inspected on tvOS, iPhone and iPad. Fixture skips
  and corrected test-driver failures are recorded with their evidence.
- Apple TV acceptance on 2026-09-11: the same-scene frame-loss comparison
  (three interleaved Release runs per arm), dismissal/replay and episode
  handoff showed no change against the pre-migration build. PiP, the
  suspended-startup dismissal and the sampler on/off cost remain open; the
  UI-test runner cannot launch the app on that device, so the lifecycle checks
  ran through the app's Debug hooks over `devicectl`. See the
  [validation record](../archive/hel-155-source-migration-validation.md).
