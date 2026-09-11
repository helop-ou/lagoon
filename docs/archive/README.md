# Validation and audit archive

These records retain evidence and unresolved observations from particular
revisions. Their dates, ticket states, commands, and measurements are historical;
an old passing run does not establish current release acceptance. Temporary
artifact paths may no longer exist. Do not append routine session history here.

Use the [current guides](../README.md) for implementation guidance and
[Release](../release.md#public-release) for the maintained release checklist.

| Record | Evidence or context |
| --- | --- |
| [Background fill, HEL-160](hel-160-background-fill-validation.md) | Cushion-paced fill scheduler, failure backoff, shared fetches, and the simulator A/B against the old ceiling |
| [iOS detail-page player dismissal, HEL-162](hel-162-detail-page-player-dismissal.md) | Why a pushed detail page closed the player, what was ruled out, and the tab-root host fix |
| [Source migration, HEL-155](hel-155-source-migration-validation.md) | Feature ownership, diagnostics opt-out, platform tests, and remaining hardware checks |
| [Touch player, HEL-153](hel-153-touch-validation.md) | iPhone/iPad gestures, clear glass, auto-hide, and remaining physical checks |
| [September 8 validation](validation-2026-09-08.md) | Build, test, and transport validation snapshot |
| [Account/privacy, HEL-141](hel-141-account-privacy-validation.md) | Account cleanup, credential boundaries, and Top Shelf |
| [Native TLS, HEL-142](hel-142-native-tls-validation.md) | URLSession transport, certificate handling, disc/session failures |
| [Release preparation, HEL-143](hel-143-release-preparation.md) | Required-reason APIs, data flows, native provenance, licensing, and unresolved release decisions |
| [Download hardening](download-hardening-validation.md) | Image/subtitle bounds, content validation, and cancellation |
| [Server addresses](server-address-validation.md) | Address discovery, scheme/port probing, and proxy paths |
| [Transport spike](transport-spike.md) | Migration away from FFmpeg's native network stack |
| [Player audit](player-audit.md) | Earlier player investigation and regression findings |
| [1.0 readiness audit](1.0-release-readiness-and-app-store-audit.md) | Broad historical code/release assessment and acceptance matrix |
| [Website drafts](website/README.md) | Superseded website brief and privacy/support handoff copy |

For the detailed reasoning behind engine, navigation, and design constraints,
use the engineering notes linked from the [documentation index](../README.md#supporting-material).
