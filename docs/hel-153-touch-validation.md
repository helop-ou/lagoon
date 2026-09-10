# HEL-153 touch player continuation — 2026-09-10

Claude's interrupted session left the center controls, double-tap feedback,
iPhone orientation lock, and initial tests uncommitted. The saved Jira response
identified HEL-153 and its acceptance criteria. Live Jira access was unavailable
in the continuation session; no ticket status or comments were changed.

## Changes reviewed and completed

- Center play/pause and ±10-second controls retain weak engine references.
- Double-tap left/right seeks without revealing the transport; feedback totals
  accumulate within the existing 700 ms window.
- iPhone landscape requests invalidate supported orientations before requesting
  geometry. iPad retains its orientation support.
- iOS content ignores changes to the navigation bar's top safe area, preventing
  the center controls from moving upward when the toolbar hides.
- An iOS presentation bridge retains the hosting controller and display surface
  across successful PiP start and restoration. AVKit delegate callbacks deliver
  start/stop/restore directly; teardown clears callbacks and closes playback.
  tvOS still uses a SwiftUI full-screen cover.
- Existing touch rail reuses trickplay and commits drags. Existing Skip and
  Up Next overlays have touch handlers above the surface.
- Audio stays in movie-playback mode by Jaagop's explicit instruction: Silent
  Mode does not silence the video; volume keys remain system controlled.
- Architecture documentation now describes touch and remote grammar together.

## Validation

- iOS: 620 tests in 75 suites passed, including touch seek policy and two PiP
  lifecycle/restoration tests. Log: `/tmp/lagoon-touch-final-ios2.log`.
- tvOS: 641 tests in 76 suites passed. Log: `/tmp/lagoon-touch-tv-complete.log`.
- iPhone 17 Pro simulator: touch journey passed with actual left/right
  double-taps, pause/resume, skip buttons, dragged seeking, accessibility labels,
  landscape geometry and exit. Result: `/tmp/lagoon-touch-clean.xcresult`.
- iPad Pro 11-inch (M5) simulator: touch journey including dragged seeking passed.
  Result: `/tmp/lagoon-touch-ipad-final.xcresult`.
- Screenshots are retained as XCTest attachments. The first test versions used
  a one-point iOS diagnostic probe for coordinates and a zero-sized iPad window;
  both harness defects were corrected. The transient seek glyph is too short
  for XCTest's post-animation wait, so tests assert actual position changes.
- The debug HUD is disabled in the touch journey to avoid repeated animation
  idle waits consuming the transport's four-second visibility window.

## Acceptance still required

Do not close HEL-153 from these results alone. Its saved acceptance criteria
explicitly require hands-on iPhone and iPad checks. Verify PiP start from Close
and Home, restoration of the same position/surface, popup close cleanup,
background captions, rotation on return, volume keys, and VoiceOver speech.
The public fixture used here had trickplay metadata but no intro/recap segments;
actual thumbnail rendering and Skip/Up Next taps need a fixture or hardware
journey with those features. The tests establish accessible button labels,
not a full VoiceOver navigation audit.

The current PiP owner is scoped to the presenting screen. Removing that screen
ends PiP intentionally; keeping PiP across arbitrary browse navigation and
starting another title while PiP is active need further session-level design
and validation. No TestFlight upload, physical-device run, or live Jira write
was performed.

The extended iPad journey also passed the auto-hide regression: the center
button stayed within two points of its visible position until controls became
non-hittable. Result: `/tmp/lagoon-touch-ipad-fade.xcresult`.

The subsequent iPhone auto-hide reruns did not produce a clean result: fixture
resolution elements disappeared between accessibility reads, and XCTest also
reported invalid hit points during fading. The latest result is
`/tmp/lagoon-touch-frame.xcresult` (fixture startup failure, before playback).
At that point the earlier complete iPhone touch pass remained valid, but the
extended iPhone fade journey was not certified. The auto-hide follow-up below
supersedes that limitation. The fixture-resolution helper still needs hardening
against disappearing accessibility elements.

## Auto-hide follow-up — 2026-09-10

The clear-glass styling run reported an auto-hide failure while its screen
recording showed the controls disappearing correctly. XCTest retained the
opacity-hidden buttons and their nonzero frames. Polling `isHittable` also
failed intermittently while the buttons faded because XCTest could not resolve
an activation point. `accessibilityHidden` alone did not remove these elements
from XCTest queries either.

The player now explicitly hides unavailable controls from assistive navigation.
Its four-second timer is unchanged. The existing launch-gated playback probe
reports transport visibility, keeping tick-rate observation in the probe. The
UI journey uses that state for reveal/auto-hide, checks center position from
UI snapshots, verifies native toolbar disappearance, and captures the whole
screen instead of the app's sometimes stale portrait bounds.

The complete journey passed on iPhone 17 Pro and iPad Pro 11-inch (M5): pause
holds the controls beyond four seconds; resume auto-hides them; a surface tap
reveals them and starts another hide cycle; center position remains stable;
double-tap/button seeking, drag scrubbing and exit also pass. Both platforms'
hidden and revealed screenshots were visually inspected.

Result: `/tmp/lagoon-touch-autohide-final.xcresult` (one test on each device,
zero failures or skips). Screenshots: `/tmp/lagoon-touch-autohide-final-images`.
iOS build-for-testing and the final tvOS build also passed. Physical-device
and full VoiceOver acceptance above remain outstanding.
