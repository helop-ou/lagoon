# HEL-141 — account privacy validation

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

Date: September 7, 2026. Implements audit findings **A02, A09 and A11**.
Changes are local and uncommitted, alongside the existing HEL-142 changes.
Physical Apple TV shared Home-screen acceptance remains required before closing
the ticket. Simulator UI checks do not establish TVServices' hardware cache behavior.

## Resulting behavior

### Top Shelf ownership and publication

- `TopShelfPublisher` retains/cancels publication work and owns a serial commit
  point. Sources capture server, user, metadata and artwork URLs before suspension.
- Each operation writes into an account-hash/UUID directory. After checking
  cancellation and current ownership, it atomically writes `snapshot-v2.json`,
  removes older artwork generations and notifies TVServices without suspending.
  Late operations can clean only their own directory, even if an uncooperative
  renderer finishes after cancellation.
- Identical item IDs on different servers cannot share artwork. Reuse additionally
  checks title, image URLs and layout version, and copies complete images into
  the replacement generation. Metadata is refreshed with each committed snapshot.
- Entering the picker, switching, removing the active account and signing out
  invalidate publishers and remove the shared snapshot and artwork. A cold launch
  may reuse only the current account's complete snapshot; signed-out launch clears it.
- The extension reads a credential-free local manifest, validates generation-owned
  artwork paths, and rechecks the generation before returning carousel content.
  Both Play and More Info include account owner and publication generation.
  App routing checks these against the current account and manifest before and
  after fetching the item. Old unowned links and replaced-generation links are ignored.
- A successful empty Continue Watching response clears the shelf. A failed
  refresh preserves its last good snapshot. An independent Next Up failure no
  longer masks a successful empty resume response. If every nonempty item's
  artwork fails, the old snapshot is retained.

### Account-local data and linked services

`SessionStore` owns recent searches and Seerr activation. Changes to the active
account synchronously update those stores; isolation no longer depends on a
SwiftUI `onChange` attached to a view that the account picker has unmounted.
`MainTabView` is recreated for a different account so navigation and results
cannot carry across. Debounced searches check account/session identity before
issuing requests and recording terms. Legacy global searches are discarded
because their owner is unknown.

`AccountLocalData` centralizes forgetting:

| Data | Forget/remove/sign-out behavior |
| --- | --- |
| Jellyfin access token | Delete that account's key |
| Linked Seerr cookies | Enumerate Lagoon key names and delete every cookie under the exact account prefix, including old Seerr addresses |
| Libraries, recent searches, subtitle/track/Home preferences | Remove that account's UserDefaults keys |
| Seerr server address | Remove only after its last remembered Jellyfin account is removed |
| Other accounts | Preserve their tokens, cookies, preferences and history |
| Device-wide OpenSubtitles login and device ID (removed under HEL-146; no longer exists) | Preserve |

Switching preserves each remembered account's data. Add Account uses an isolated
draft; cancellation leaves the active account intact. Logout removes local access
before awaiting either service and attempts remote revocation through immutable
client copies. An offline or delayed logout cannot keep the outgoing account
active or clear the next account when it completes.

Seerr disables automatic cookie storage/handling and sends only its explicit
account cookie. Activation invalidates outgoing restore and authentication work,
including a restore task cancelled before it starts. Delayed cookies, users and
automatic sign-in error messages are rejected after an account change. Seerr
disconnect/forget clear locally before awaiting remote logout on a client copy.

### Keychain failure semantics

Account removal persists a cleanup marker before attempting credential deletion.
If enumeration or any deletion fails, access remains removed, the account cannot
restore from retained credentials, and a root-level **Credential Cleanup Incomplete**
alert explains the incomplete deletion and offers Retry. The marker survives
relaunch; startup retries, and re-adding that same identity must complete cleanup
before saving its replacement Jellyfin token.

A failed standalone Seerr cookie deletion also leaves a persistent marker.
Activation ignores that cookie and explains that a new sign-in must replace it.
A successfully saved and read-back-verified replacement clears the marker.
This prevents restoration; it does not claim physical deletion when Keychain
reports failure.

## Automated validation

All fixtures use synthetic accounts and credentials. UI journeys use a loopback
Jellyfin fixture, real simulator account persistence, and disposable simulators
that the runner deletes. No user's server accounts are removed or revoked.

| Coverage | Evidence |
| --- | --- |
| Delayed artwork across switch/logout; old renderer cleanup; overlapping publishers; same ID on different servers; notification and link rejection; empty vs failure; cold launch | `TopShelfPublisherTests` (5 cases), using controlled suspended operations and temporary directories |
| Picker transitions, active/inactive removal, offline/delayed logout, add/cancel, remove/re-add, Keychain deletion/enumeration errors and retry, cookie quarantine, immutable client capture | `AccountPrivacyTests` |
| Real Keychain query shape and scoped deletion | `systemKeychainEnumerationSupportsScopedRemoval`, creates/removes unique synthetic keys and preserves an adjacent unrelated key |
| Delayed Seerr authentication, delayed disconnect, cancelled restore before start, actual quarantined-cookie activation, late automatic sign-in failure | `SeerrAccountPrivacyTests` (5 cases), including two Jellyfin servers with the same user ID and Seerr endpoint |
| Explicit cookie headers with automatic handling disabled | `SeerrClientTests` |
| Owned deep-link parsing; legacy/incomplete links rejected | `DeepLinkRouterTests` |
| Account-scoped persistence and legacy search behavior | `RecentSearchStoreTests` |
| Authoritative empty resume despite failed Next Up | `ServerSyncTests.emptyResumeClearsEvenWhenNextUpFails` |

Final complete suites pass, including the real Keychain contract check:

| Platform | Swift Testing result | Result bundle |
| --- | --- | --- |
| iOS 26.5 simulator | 521 tests / 58 suites, zero failures | `/private/tmp/lagoon-hel141-complete-ios.xcresult` |
| tvOS 26.5 simulator | 545 tests / 60 suites, zero failures | `/private/tmp/lagoon-hel141-complete-tvos.xcresult` |

These are the runner's reported totals. Two opt-in HEL-142 checks (the external
TLS fixture matrix and native allocation stress) are skipped by ordinary suite
runs; their separately executed evidence is in that ticket's validation record.
Existing native-player concurrency warnings remain; this ticket does not claim
a warning-free build. `git diff --check` passes.

## UI and Release checks

The privacy journey signs in two synthetic accounts, relaunches into the normal
picker, selects A and verifies only A's search, switches via Settings to B and
verifies only B's search, opens Add Account and cancels, then verifies B's search
again. It passes on both platforms. Exported A/B/cancel screenshots were visually
inspected; the TV run uses actual remote focus navigation.

| Check | Result / local evidence |
| --- | --- |
| iOS normal picker and add/cancel | Pass; `/private/tmp/lagoon-hel142-validation/20260907-220443/iOS/Recovery.xcresult` |
| tvOS normal picker and add/cancel | Pass; `/private/tmp/lagoon-hel142-validation/20260907-220419/tvOS/Recovery.xcresult` |
| iOS direct/HLS session recovery | Both cases pass; `/private/tmp/lagoon-hel142-validation/20260907-220831/iOS/Recovery.xcresult` |
| tvOS direct/HLS session recovery | Both cases pass; `/private/tmp/lagoon-hel142-validation/20260907-220831/tvOS/Recovery.xcresult` |
| iOS unsigned device Release | Pass; `/private/tmp/lagoon-hel141-release-ios.log` |
| tvOS unsigned device Release and extension | Pass; `/private/tmp/lagoon-hel141-release-tvos.log` |

Initial UI test failures were navigation-helper assumptions: the iOS search
role collapses other tabs, and the tvOS Settings detail starts on the left-column
back button. The helper now follows those native paths. An older global-history
test was updated for account ownership, and a Seerr header test's missing mock
status response was supplied. The final checks supersede those intermediate runs.

Reproduce the privacy journey with:

```sh
python3 scripts/test-session-recovery.py --account-privacy
```

The same runner without `--account-privacy` covers direct/HLS playback, remote
token revocation, sign-in and resumed playback from HEL-142. Both cases passed
again on both platforms after the shared account-lifecycle changes. The native FFmpeg artifacts
are unchanged by HEL-141; the controlled TLS matrix's separate evidence remains
in [HEL-142 validation](hel-142-native-tls-validation.md).

## Remaining physical Apple TV acceptance

`devicectl list devices` on September 7 lists a paired iPhone and no Apple TV
(`/private/tmp/lagoon-hel141-devices.json`). No physical Top Shelf run was possible.

On a connected Apple TV with Lagoon in the Home screen's top row:

1. Populate A's shelf; delay artwork responses. Switch through the normal picker
   to B, then return to the system Home screen. Finish A's delayed response and
   confirm A's titles, summaries and images do not reappear.
2. Repeat while signing out and forgetting A. Confirm the static fallback replaces
   the shelf and cached outgoing Play/More Info links cannot resolve for B.
3. Use identical item IDs on two servers, overlap refreshes, and confirm the new
   account's images survive late old work.
4. Remove the last Continue Watching item and refresh successfully; confirm the
   shelf clears. Repeat with a failed refresh and confirm the valid shelf remains.
5. Verify same-account cold launch, cache purge recovery and return from the
   background. Check extension/app logs and the visible system shelf together.

The unit tests prove application publication ownership and cleanup ordering.
They do not reproduce the system Home screen's caching and extension scheduling.
The ticket therefore belongs in **In Testing**, pending this hardware acceptance.
