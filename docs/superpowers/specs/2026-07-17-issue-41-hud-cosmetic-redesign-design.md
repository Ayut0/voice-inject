# Issue #41: HUD cosmetic redesign — design

## Context

Parent: #30 (Recording HUD panel — implementation, closed).

The HUD pill (`HUDView.swift`) currently renders correct-but-unstyled
content for each `HUDDisplay` state. Issue #41 asks for a cosmetic-only
restyle to match an inline design spec (colors, sizes, animation curves —
see the issue body, which is the authoritative source of truth for exact
values). This document records the *implementation* design: how those
values map onto the existing SwiftUI/AppKit structure, and the one place
(`HUDPanelController.position()`) where non-cosmetic code must change to
accommodate a shadow that the current panel-sizing strategy would
otherwise clip.

`HUDState.swift` (the pure state machine) is unchanged. `HUDStateTests.swift`
needs no changes.

## Goals

- Match the issue's pill geometry, per-state content, and motion spec.
- Shadow renders uncropped without moving the pill's on-screen position.
- No regressions to click-through / non-activating / always-on-top /
  fade timing behavior.

## Non-goals

- Any change to `HUDState.swift` or the daemon-facing phase logic.
- Pixel-perfect CSS porting — SwiftUI-native recreation only, per the
  issue's explicit instruction.

## Design

### 1. Color helper

No `Color(hex:)` helper exists in the codebase today. Add one (small,
private to `HUDView.swift` is enough — nothing else needs it) to express
`#ff453a` (recording dot) and `#ffd60a` (warning/error) directly from the
spec's hex values instead of hand-picked SwiftUI system colors.

### 2. Pill chrome

`RoundedRectangle(cornerRadius: 14, style: .continuous)` background,
`.ultraThinMaterial`, with:
- 1px hairline border: `white @ 13%` opacity (`.strokeBorder`).
- Inset top highlight: a second, thinner top-aligned stroke or gradient
  at `white @ 8%` to read as a light catching the pill's upper edge.
- Padding: 16pt horizontal / 11pt vertical (spec value; current code has
  16h/10v — updating vertical to 11 to match).
- Shadow: `.shadow(color: .black.opacity(0.48), radius: 34, x: 0, y: 12)`.

Border tints to `#ffd60a @ 28%` specifically in the `.errorFlash` state
(replacing, not layering on top of, the default hairline border).

### 3. Shadow-inset accommodation (the one non-cosmetic change)

**Problem**: `HUDPanelController` sets `panel.hasShadow = false` and calls
`hosting.fittingSize` to size the panel exactly to its content
(`position()`, `HUDPanelController.swift:54-64`). A SwiftUI `.shadow()`
drawn on a view sized exactly to its content gets clipped at that view's
bounds — there's no room for the shadow to bleed outward.

**Fix**: `HUDView` wraps the actual pill in a fixed transparent inset —
a `static let shadowInset: CGFloat = 48` (covers 34pt blur + 12pt y-offset
with a few points of margin), applied as uniform padding *outside* the
pill's background/shadow modifiers. This makes `hosting.fittingSize`
equal to `pill size + 2 * shadowInset`.

`HUDPanelController.position()` currently centers the panel frame (i.e.
the fitting size) on screen. If fitting size now includes the inset
padding, centering it directly would still visually center the *pill*
correctly (padding is symmetric), **except** for the vertical anchor:
today's `y: frame.minY + 80` positions the bottom edge of the fitting
frame 80pt above the dock, which — once the frame grows by
`2 * shadowInset` — would push the pill's visible bottom edge up by
`shadowInset` extra points versus today.

To keep the pill's on-screen position unchanged (required by the
acceptance criteria), `position()` adds `HUDView.shadowInset` to the y
origin (shifting the whole padded frame down by that amount) so the pill
itself — not the invisible padding — ends up 80pt above the dock, matching
current behavior. This is the only permitted change to panel
sizing/positioning code, per the issue.

`HUDView` exposes `shadowInset` as a `static let` so both files reference
the same constant rather than duplicating a magic number.

### 4. Recording state

- `PulsingDot`: 9pt circle, fill `#ff453a`, `.shadow(color: #ff453a, radius: 4)`
  for the glow, animating scale 1 → 0.78 and opacity 1 → 0.3 over 1.4s
  ease-in-out, repeating forever, autoreversing.
- Label + timer split into two `Text` runs (issue explicitly calls out
  `HUDView.swift:28`, where they're currently one combined string):
  - "Recording" — SF Pro 14pt medium, `white @ 92%`.
  - `%.1fs` — SF Mono 14pt medium (`.system(.body, design: .monospaced)`
    at the right size/weight), `white @ 55%`.
- Progress underline replaces the current `ProgressView`: a 2pt-tall bar
  along the pill's bottom edge, glowing (small `.shadow`), width fraction
  = `elapsed / (maxRecordMs / 1000)` — same formula as today, just
  re-skinned. `maxRecordMs` continues to come from `AppModel`'s config
  plumbing (`HUDView` already takes it as a parameter) — not hardcoded.

### 5. Transcribing state

New `BreathingBars` view (chosen over the spinner fallback): 3 vertical
bars, 3pt wide, heights 11/16/11pt, `white @ 85%` fill, each animating
opacity 0.4 ↔ 0.85 over a 1s loop, staggered 0.15s apart (via per-bar
`.animation(...).delay(...)`, repeating forever, autoreversing). Paired
with "Transcribing…" label, 13pt medium, `white @ 88%`.

### 6. Error flash state

- Icon: `exclamationmark.triangle.fill`, `#ffd60a`.
- Message: SF Pro 12pt medium, `white @ 90%`, `.lineSpacing` tuned for
  ~1.35 line-height, `.lineLimit(2)`, `.frame(maxWidth: 260)` on the pill.
- Border: per §2, tints to `#ffd60a @ 28%` while this state is active.
- 2s auto-dismiss: unchanged (`HUDState.errorFlashDuration` / `HUDPanelController.scheduleErrorExpiry`
  are untouched).

### 7. Motion

Fade in (0.15s ease-out) / fade out (0.25s ease-in) on state transitions
are already implemented in `HUDPanelController.fadeIn()/fadeOut()` and
are not being changed — verify only that they still read correctly
against the restyled pill.

## Testing / verification

`HUDState.swift` is untouched, so `HUDStateTests.swift` needs no changes
and continues to pass as-is. `HUDView` and `HUDPanelController` have no
existing unit tests — consistent with the rest of the codebase not
testing SwiftUI view/AppKit glue code — so no new automated tests are
planned for the restyle itself.

Verification is manual, against the issue's acceptance criteria:
- Build (`go build ./...` doesn't apply here; use the Swift package build
  under `app/`) and run the daemon.
- Trigger a real dictation and visually check the recording pill (dot
  pulse, label/timer split, underline tracking `elapsed / maxRecordMs`).
- Let a transcription run and check the breathing-bars state.
- Induce an error (e.g. a too-short/empty transcript) and check the
  error-flash styling, wrap, max-width, border tint, and 2s auto-dismiss.
- Confirm the pill's on-screen vertical position is unchanged versus
  before the shadow-inset change, and that the shadow itself renders
  uncropped.
- Confirm click-through / non-activating / always-on-top behavior is
  unaffected (no interaction-related code is touched).

## Files touched

- `app/Sources/VoiceInject/HUDView.swift` — full restyle.
- `app/Sources/VoiceInject/HUDPanelController.swift` — `position()` y-origin
  adjustment only, per §3.
