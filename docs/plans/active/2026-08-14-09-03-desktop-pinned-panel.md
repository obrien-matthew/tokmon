# Desktop pinned panel

Status: awaiting approval

## Scope (user-confirmed 2026-08-14)

- Contents: full gauges — same `ProviderSection`s as the menu dropdown.
- Visibility: Settings checkbox **and** a quick toggle in the menu
  dropdown; off by default.
- Interaction: draggable anywhere on its body, otherwise inert.
- Persistence: window origin only, saved in settings.json; clamped back
  onto a visible screen on restore.

## Problem

tokmon's gauges are only visible via the menu bar (two compressed
micro-rows) or by opening the dropdown. A desktop-pinned panel gives
always-visible full gauges without the WidgetKit packaging tax: it
renders live from `AppState`, sits above wallpaper/icons and below
normal windows, and exists exactly as long as the menubar app runs.

## Approach

A borderless `NSPanel` owned by a `@MainActor` controller, hosting the
SwiftUI panel view via `NSHostingView` with
`sizingOptions = [.preferredContentSize]` (content-driven sizing,
macOS 13+; we target 14). SwiftUI scenes can't express desktop-level
windows, so AppKit window management is the boring, correct tool here —
precedent: the app already drops to AppKit for activation policy and
the composed menu bar image.

Window configuration:

- `styleMask: [.borderless, .nonactivatingPanel]`, `isOpaque = false`,
  `backgroundColor = .clear`, content drawn on `.regularMaterial` with
  rounded corners; standard shadow.
- Level: `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)`
  — above wallpaper and desktop icons, far below normal windows (level
  0), so it never covers work and Show Desktop / Mission Control leave
  it in place.
- `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
- `hidesOnDeactivate = false` (NSPanel defaults it to true — without
  this the panel vanishes the first time the accessory app activates
  for Settings and then deactivates) and `isReleasedWhenClosed = false`;
  `show()` uses `orderFrontRegardless()`, `hide()` uses `orderOut(nil)`,
  never `close()`.
- `isMovableByWindowBackground = true` — drag-anywhere on a borderless
  window; no other interaction (no buttons in the panel). Contingency:
  if NSHostingView swallows mouse-downs (known borderless+SwiftUI
  failure mode), subclass it to return `mouseDownCanMoveWindow = true`.
- Never becomes key or main (`.nonactivatingPanel`; borderless windows
  refuse key by default) so clicking it doesn't steal focus.

Position: `NSWindow.didMoveNotification` fires continuously during a
drag, so the controller debounces ~300ms before invoking the persistence
closure, and suppresses it entirely during programmatic positioning
(show-time restore, content resizes) via a flag — otherwise
`preferredContentSize` reflows after snapshots land would silently
rewrite the saved origin. On the hidden→shown transition only, restore
the saved origin clamped **per-screen** (nearest/largest-intersection
`visibleFrame`, never the union — an L-shaped multi-monitor union
contains dead zones belonging to no screen) via a `nonisolated static`
pure `clampedOrigin(_:contentSize:screens:)` (a plain static on a
@MainActor type would be actor-isolated and untestable synchronously).
Re-clamp on `didChangeScreenParametersNotification`. No flipped-
coordinate hazard: NSScreen frames and NSWindow origins share Cocoa
global space and borderless frame == content size. Default placement:
top-right of the main screen, 16pt margin.

## Phases

### Phase 1 — Settings plumbing

- [ ] `AppSettings`: add `showDesktopPanel: Bool = false` and
  `desktopPanelOrigin: PanelOrigin?` (`struct PanelOrigin: Codable,
  Equatable { var x: Double; var y: Double }`), both via
  `decodeIfPresent` in the existing backward-compatible pattern.
- [ ] `SettingsStore`: `setShowDesktopPanel(_:)`,
  `setDesktopPanelOrigin(_:)`.
- [ ] Codable-level tests: `AppSettings` round-trip with the new fields
  and decode of a pre-panel settings.json (the custom CodingKeys +
  `init(from:)` mean a forgotten key silently drops the field). Test
  `AppSettings` directly, not `SettingsStore` — the store reads/writes
  the real settings.json in `init`/`didSet`.

### Phase 2 — Panel window

- [ ] `Sources/tokmon/UI/DesktopPanelController.swift`: `@MainActor`
  final class; `show(state:)/hide()`; owns the NSPanel + NSHostingView;
  debounced move-notification observer persists origin through a
  closure injected from `TokmonApp` (controller stays UI-only, no
  store dependency); programmatic-move suppression flag; screen-change
  re-clamp; hidden→shown restore only.
- [ ] `DesktopPanelView`: `ForEach(state.providers) { ProviderSection }`
  inside `.padding(12).frame(width: 300)` on `.regularMaterial` with
  `RoundedRectangle(cornerRadius: 12)` clip — deliberately the menu
  content minus the button row and minus `engine.menuOpened()` (the
  panel is passive; RefreshEngine's normal cadence feeds it). Empty
  `state.providers` shows a "No providers enabled" caption instead of
  a blank material blob.
- [ ] `nonisolated static clampedOrigin(_ origin: CGPoint, contentSize:
  CGSize, screens: [CGRect]) -> CGPoint` + unit tests: on-screen
  unchanged, off-screen clamped to nearest screen, dead-zone origin in
  an L-shaped two-screen layout lands on a real screen,
  disconnected-display fallback to primary.

### Phase 3 — Wiring and toggles

- [ ] `TokmonApp`: create controller in `init` but defer the initial
  `show()` to the first runloop turn (not inside `App.init`); react to
  changes via a Combine sink on
  `$settings.map(\.showDesktopPanel).removeDuplicates()` — observing
  all of `$settings` would re-enter on every origin save. Sink retained
  by the controller wrapper.
- [ ] `SettingsView`: "Show desktop panel" toggle row.
- [ ] `MenuContentView`: gains the settings store (callsite ripple:
  `TokmonApp` passes `settingsStore` into `MenuContentView`); a compact
  toggle in the bottom button row (icon button matching the refresh
  button style, `.help("Show/hide desktop panel")`).

### Phase 4 — Docs and verification

- [ ] README: feature mention (providers/UI paragraph + architecture
  tree gains the two new UI files).
- [ ] Verify: `swift test` (clamp + settings tests); live smoke — build,
  install, launch; toggle the panel on via menu, `screencapture` +
  image inspection to confirm the panel renders gauges on the desktop;
  drag-persistence via a **real manual drag** (a programmatic move
  fires didMove and would pass even if NSHostingView swallowed
  mouse-downs) — ask the user to drag, then confirm settings.json
  origin updated; relaunch app and confirm restored position.
- [ ] Move plan to `docs/plans/completed/`.

Commit after each phase.

## Risks

- **Window level nuance**: desktop-adjacent levels interact with
  wallpaper/icon layering differently across macOS releases; if
  `.desktopIconWindow + 1` misbehaves on Tahoe the fallback is
  `CGWindowLevelForKey(.backstopMenu)`-style experimentation — isolated
  in one constant.
- **MenuBarExtra + extra windows**: accessory-policy apps showing
  auxiliary windows can trip activation quirks; `.nonactivatingPanel`
  avoids focus stealing, and the panel never needs key status.
- **Settings observation from App struct**: SwiftUI `App` has no
  `onChange` host; the Combine sink lives in the controller and is torn
  down with it. Single-instance guard already prevents duplicate panels
  from duplicate processes.

## Non-goals

- No WidgetKit extension (separately assessed; may come later — the
  panel shares no code that would block it).
- No per-panel metric filtering, resizing, or opacity settings.
- No click-through mode.
