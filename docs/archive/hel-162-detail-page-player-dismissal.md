# HEL-162 iOS player dismissed itself from detail pages — 2026-09-11

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

## Report

Build 96 on an iPhone 16 Pro Max: tap Play on a title, the player opens,
rotates to landscape, and "crashes" back to the browse screen on every asset;
the diagnostic reporting (HEL-159) sends nothing. Later narrowed by Jaagop to
some titles, with "Grand Theft Auto VI: An Extended Look" on fixture as a
reliable case, and reproduced in the iOS simulator.

## What it was

Not a crash. The console showed the player open, report a stop at 0.0 s, and
close, with no fatal error, exception, or signal, and the phone had no crash
report. Diagnostics stayed silent because nothing failed: the player closed
through its ordinary teardown path.

`PlayerPresentationBridge` (the iOS `UIViewControllerRepresentable` that hosts
the player) lived in every screen that could start playback, so a detail page
pushed on a `NavigationStack` presented the player from a controller embedded
in its own content. With logging on the bridge, the session store, the
navigation paths and the detail page's appearance, the sequence on a pushed
page was:

1. `bridge presenting` — the host is presented from inside the pushed page.
2. About 0.3–0.5 s later the stack's root (`LibraryView`) fires `onAppear`
   while the path still holds the detail route.
3. Against fixture the root disappears again ~0.85 s later and the detail
   survives. Against the public demo (Jellyfin 12) a view update lands in that
   window, `destination onDisappear` fires with the path unchanged, the bridge
   is dismantled, its coordinator closes the host, and the player is gone
   ~1.4 s after presenting.

The title dependence was really a path dependence: Home and Continue Watching
present from a screen that is not pushed, so they never hit it; Library, Search
and Discover always go through a pushed detail page. Whether a given title
survived on fixture depended on what updated during the window.

A second, independent trigger was found on the way. The host used
`.fullScreen`, which removes the presenting hierarchy from the window when the
transition ends; SwiftUI answers by re-running the `.task`s underneath. In the
regression lane that re-ran `RootView`'s demo bootstrap, which drove the session
to `needsSignIn` and back, rebuilt `MainTabView`, and closed the player. That
path does not exist outside the lane but made the first simulator repro look
like a session expiry.

## Ruled out with evidence

- A process crash: no signal, no `.ips`, clean lifecycle log to `controller-destroyed`.
- The codec: the same HEVC Main 10 4K title played 70 s hands-off in the
  simulator with hardware decode and zero drops when started from the tab root.
- Resume: From Beginning failed identically.
- The 401/session-expiry path: a log line on the client's 401 branch never fired.
- Rotation: the forced landscape lock disabled, and a simulator already in
  landscape, both still failed.
- Size class: iPhone 17 Pro (compact) and 17 Pro Max (regular in landscape)
  behaved the same.

## Fix

- iOS screens only request playback through `playerPresentation`; the single
  `playerPresentationHost` at the tab root (`PlayerPresentationHub`, mounted in
  `MainTabView` outside every `NavigationStack`) presents it and hands
  `onDismiss` back to the requesting screen. tvOS keeps its `fullScreenCover`.
- The host is presented `.overFullScreen`.
- `TouchPlayerUITests.testPlayerStartedFromDetailPageStaysOpen` drives
  Library → detail → Play on the public demo and asserts the player is still
  advancing six seconds after it becomes ready. It failed on the old code
  against the demo on both simulators and passes with the fix.

## Also done from the same report

- The forced rotation to landscape is gone (Jaagop's call, superseding the
  HEL-153 scope): the player follows the device, and a title opened in
  portrait plays letterboxed. `PlayerOrientationLock` and the app delegate
  that existed for it were removed; the touch journeys pass in portrait.

## Still open from the same report

- Info button reachability on the phone and a swipe-down to open the panel.
  In the simulator Close and Info show with the transport in both
  orientations; iOS never had a swipe gesture for the panel, the "Swipe down
  for Info" hint is tvOS-only. Needs Jaagop's description of what he sees.
