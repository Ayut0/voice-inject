# Issue #42: Main window polished redesign (2a) — design

## Context

Parent: #29 (Swift app skeleton), #31 (History tab) — both merged, unblocked.
Related: #44 (daemon manual start/stop) merged 2026-07-17, *after* this
issue's spec summary was written — it added `.stopping`/`.stopped` to
`AppModel.DaemonStatus`, which the issue's 4-state banner spec (running/
starting/restarting/failed) doesn't mention. This design closes that gap
(see §2).

The issue body's "Spec summary" plus the Agent Brief comment are the
authoritative source of truth for exact colors/radii/spacing/typography —
this document does not restate every token. It records the *implementation*
design: how those values map onto the existing SwiftUI structure, the
architecture changes needed to support them (config hoisting, tab
persistence), and the two decisions the spec doesn't cover.

## Goals

- Match the issue's banner/tab-bar/Settings/History spec using native
  SwiftUI controls, semantic colors, and system typography.
- All 6 `DaemonStatus` cases (including `.stopping`/`.stopped` from #44)
  render as full-width tinted banners consistent with the 4 the issue
  specifies.
- No regressions: config save round-trips to the daemon socket, history
  toggle/clear/copy still function, tab switching preserves in-progress
  Settings edits.
- Light and dark mode both correct.

## Non-goals

- The Setup/first-run tab and model downloader (#32).
- Any change to daemon protocol, socket transport, config persistence, or
  history JSONL format.
- The recording HUD panel (`HUDView.swift`, done in #41).
- Final manual acceptance against a live daemon — human-only, per the issue.

## Design

### 1. AppModel: config hoisting

Config ownership moves from `SettingsView` into `AppModel`, since the
status banner subline needs it too and two independently-loaded copies of
the same daemon config would drift.

`AppModel` gains:
- `private(set) var config: DaemonConfig?`
- `func loadConfig() async` — calls `client.getConfig()`, sets `config`
- `func saveConfig(_ patch: ConfigPatch) async throws` — calls
  `client.setConfig(patch)`, then re-derives `config` from the patch
  applied to the current value (avoids a redundant round-trip) before
  returning

This replaces the existing private `maxRecordMs: Int64` scalar and
`refreshMaxRecordMs()` — the HUD path (`hudInput`) reads
`config?.maxRecordMs` instead. `client.onPhaseChange`'s `.idle` branch
calls `loadConfig()` instead of `refreshMaxRecordMs()`.

`SettingsView` keeps a **local draft**: `@State private var draft:
DaemonConfig?`, seeded from `model.config` in `.task`, mutated by the
pickers/steppers (as `cfg`/`config` already are today), and only pushed
to `model.saveConfig(_:)` on Save. This is deliberate — it's what keeps
in-progress edits from leaking into the shared model (and thus the
banner subline) before Save succeeds, and it's also the mechanism that
answers §3's "don't lose unsaved edits on tab switch": the draft lives in
`SettingsView`'s own `@State`, and §3 keeps `SettingsView` itself
permanently mounted, so the `@State` is never torn down.

### 2. MainWindow: status banner

One `statusBanner` `@ViewBuilder` switching on all 6 `DaemonStatus`
cases, each producing the same shape (full-width bar, tint of status
color @ 16% alpha background, 3pt solid leading rule, 9pt dot with soft
glow, label row, monospaced config subline row hidden when not
applicable):

| Status | Color | Subline shown | Trailing control |
|---|---|---|---|
| `.running` | green | yes | "Stop Daemon" button |
| `.starting` | orange | yes | none |
| `.restarting` | orange | yes | none |
| `.stopping` | orange | yes | none |
| `.stopped` | gray | yes | "Start Daemon" button |
| `.failed` | red | no | stderr scroll box + "Restart Daemon" button |

Rationale for extending stopping/stopped into the same tinted-bar
language rather than leaving them plain (per the earlier discussion):
the banner is one visual system now: 6 mutually-exclusive states of one
component, not "4 spec'd states plus 2 leftover ones." Gray reads
correctly as a genuinely neutral/idle state distinct from the warning
orange of the transitional states.

Subline format (new small helper next to `modelDisplayName`, e.g.
`configSubline(_ cfg: DaemonConfig) -> String`):
`"\(modelDisplayName(cfg.model)) · max \(cfg.maxRecordMs / 1000)s · silence \(cfg.silenceTimeoutMs / 1000)s"`
— language is already folded into `modelDisplayName`'s "(English)" suffix
for `.en` models today, so it isn't duplicated separately; for `ja` models
`modelDisplayName` returns the bare name, which is fine since Japanese
isn't marked with a suffix either. Reads `model.config`; `nil` while
still loading renders no subline row (same visual effect as the failed
state's suppression, reusing one conditional).

### 3. MainWindow: tab bar + persistence

`TabView`/`.tabItem` is replaced by a custom centered segmented control:
an `HStack` of two tappable labels (`slider.horizontal.3` / `clock`),
active = weight 600 text on a raised chip (`.background` + subtle
`.shadow`), inactive = weight 500 secondary text, transparent background.
`@State private var activeTab: Tab` (`enum Tab { case settings, history }`)
drives both the chip styling and content visibility.

Both `SettingsView()` and `HistoryView()` are instantiated once, stacked
(`ZStack`), and switched via `.opacity(activeTab == .settings ? 1 : 0)`
+ `.allowsHitTesting(activeTab == .settings)` (and the inverse) rather
than conditional `if`/`switch` — this is what keeps `SettingsView`'s
`@State private var draft` alive across a tab switch, per §1. The
non-visible tab's `List`/`Form` stays laid out off-screen at zero
opacity, which is a standard SwiftUI pattern for this and has no
functional downside here (small, static-ish view trees, no expensive
rendering).

### 4. SettingsView: grouped card

Same four rows and `SaveState` enum, restyled:
- Wrapped in a grouped `Form` styled as a card: control-background,
  hairline-divided rows, 10pt corner radius, under an uppercase
  "CONFIGURATION" section header (`Section("CONFIGURATION")` with
  `.textCase(.uppercase)` — SwiftUI defaults section headers to
  uppercase on macOS already, but making it explicit matches the spec's
  intent regardless of that default).
- Language: `Picker(selection:)` gains `.pickerStyle(.segmented)` (2-option).
- Model row unchanged structurally (`LabeledContent` + "Change Model…").
- Steppers: label text gains a `.monospacedDigit()` / tabular-nums
  numeral run for the readout (`Text("\(n)s").monospacedDigit()`
  composed into the label).
- Footer: `HStack` right-aligned (`Spacer()` before the Save button
  instead of after), Save button + state text unchanged in structure.

`SaveState.saved` gains a timed auto-revert to `.idle` after 1.6s,
mirroring the `Task.sleep` + "still the same state" guard
`HistoryView.copy(_:)` already uses for its 1.5s copy flash — same
pattern, different duration, applied in `save(_:)`'s success branch.

`save(_:)` now calls `model.saveConfig(patch)` (§1) instead of
`model.client.setConfig(patch)` directly; error handling (`saveState =
.failed(...)`) unchanged.

### 5. HistoryView: hover-lift rows + ghost copy button

Header row and both empty-state copy variants are unchanged visually —
they already match the spec. One behavioral tweak is in scope though:
today Clear is only `.disabled(history.entries.isEmpty)`, but the
issue's acceptance criteria explicitly calls for "disabled when
recording is off *or* the list is empty," so this becomes
`.disabled(!history.recordingEnabled || history.entries.isEmpty)`.

Rows: add `@State private var hoveredID: HistoryEntry.ID?` and
`.onHover { isHovered in hoveredID = isHovered ? entry.id : nil }` per
row, with `.listRowBackground(hoveredID == entry.id ?
Color.primary.opacity(0.04) : Color.clear)` for the lift effect (8pt
row radius via a `RoundedRectangle` clip on the background shape, since
`.listRowBackground` accepts any `View`). Copy control changes from a
borderless icon button to a ghost text button: `Button("Copy") { copy(entry) }`
styled with reduced-emphasis text, flipping to `Text("Copied ✓")` in
green for the same 1.5s window the existing `copiedID` timer already
provides — only the label/styling changes, not the timing mechanism.

### 6. Tokens

Per the issue: prefer macOS semantic colors (`.primary`, `.secondary`,
`Color(nsColor: .controlBackgroundColor)`, `.separator`, `.accentColor`,
system `.green`/`.orange`/`.red`) over hardcoded hex anywhere in these
three files — unlike `HUDView.swift` (#41), which intentionally forces a
dark-glass appearance and hex colors because it's an always-dark overlay
panel; `MainWindow`/`SettingsView`/`HistoryView` are regular in-window
content and must follow the system appearance, so that precedent doesn't
carry over here. Radii: 11pt window corner (if settable at this layer —
otherwise N/A, window chrome is system-owned) / 10pt card / 8pt history
row / 7pt Save button and tab chip / 6–7pt small buttons.

## Testing / verification

- `AppModelTests`: add coverage for `loadConfig()`/`saveConfig(_:)`
  against the existing script-based fake-daemon harness (or a minimal
  fake `DaemonClient`/`DaemonTransport` if the socket round-trip is
  awkward to script) — assert `config` populates after `loadConfig()`
  and reflects a patch after `saveConfig(_:)`.
- `SettingsViewTests` (pure `modelDisplayName` tests) unchanged, still pass.
- `swift build` and `swift test` from `app/` as the automated gate.
- Manual verification per the issue's acceptance criteria: all 6 banner
  states (light + dark), tab switching with an unsaved Settings edit
  (must survive the switch), Save idle→saving→saved(auto-revert)→error
  cycle, History empty states (off vs. empty), hover-lift, copy→"Copied ✓",
  Clear disabled logic. Inducing a real failed daemon state and a real
  save error against a live daemon is explicitly human-only per the issue.

## Files touched

- `app/Sources/VoiceInject/AppModel.swift` — config hoisting (§1).
- `app/Sources/VoiceInject/MainWindow.swift` — banner (§2), tab bar (§3).
- `app/Sources/VoiceInject/SettingsView.swift` — grouped card, draft
  state, save-state timer (§4).
- `app/Sources/VoiceInject/HistoryView.swift` — hover-lift, ghost copy
  button, Clear-disabled fix (§5).
- `app/Tests/VoiceInjectTests/AppModelTests.swift` — new config tests.
