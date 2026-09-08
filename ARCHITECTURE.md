# Codenotch — Architecture

Two pages for the new contributor. Full history lives in `TASKS.md`; the
pixel-level contract lives in `docs/specs/2026-08-28-usage-notch-design.md`
with the frame at `docs/design/frame-124-hover-tooltip.png`.

## The pipeline

```
Provider adapters → UsageStore → NotchViewModel → NotchRootView → NotchPanel
(Sources/Providers) (Model)      (Notch)          (Notch)          (AppKit)
```

Data flows one way, on `@MainActor`, published through `ObservableObject`.
Concurrency lives inside the providers; the store and the view model only
ever see finished values.

## Providers: borrowed credentials, honest numbers

Every source of numbers implements `UsageProvider`
(`Sources/Providers/UsageProvider.swift`): an `id`, a `displayName`, a
`glyph`, and `fetchSnapshot()`. Nothing signs in anywhere — each adapter
reads a credential or session a tool on the Mac already holds (Claude Code's
keychain token, Cursor's SQLite state, Codex's app server, …).

Two rules govern every adapter:

1. **Declare a `Fidelity`** (`.official` / `.derived` / `.manual`). The UI
   prefixes anything self-computed with `~` and never presents a guess as a
   vendor figure.
2. **Degrade, don't invent.** Every failure maps to a `ProviderStatus`
   (`.stale` / `.needsAuth` / `.accessDenied` / `.unsupported` / `.error`).
   `UsageStore.degraded` re-shows the last good reading dimmed, or an empty
   cell — never a fabricated percentage. `supersedesHistory` decides which:
   a signed-out account drops its remembered reading, a rate limit keeps it.

Response shapes are pinned by tests against recorded payloads
(`Tests/UsageResponseTests.swift`, `Tests/*UsageTests.swift`). When a vendor
changes an endpoint, those tests fail first — that is their job.

Keychain-held credentials go through `CredentialCache`: read once, served
from memory, re-read only when the keychain item's modification date moves.

## The store: polling with a conscience

`UsageStore` (`Sources/Model/UsageStore.swift`) owns the refresh loop:

- **60s while an agent is busy, 5 min idle** (`shouldRefresh` is pure and
  tested). Usage can't move while nothing runs, so idle polling only spends
  rate-limit budget.
- **Concurrent fetches with a per-provider timeout** (default 15s). A hung
  endpoint degrades to its last good reading instead of holding every other
  ring hostage. Order is restored afterwards so rings never swap places.
- **One ring, one refresh.** `refresh(providerID:)` refetches a single
  provider so a manual retry doesn't spend everyone else's budget.
- **The last good reading survives relaunch** via `UsageArchive`
  (restored as `.stale`, dated). Rate-limit back-off deadlines persist too,
  so a restart during a penalty waits instead of spending an attempt.

Switching a provider off (`disconnected`) stops its credential being read
*at all* — filtering happens before the fetch, and the archived reading is
forgotten. Signing out additionally discards the in-memory reading.

`Notifier` (`Sources/Notifications/`) watches the same two streams as the
notch — snapshots and sessions — and posts a local notification when the
headline number crosses 80%/90% or an agent starts waiting. Only vendor
numbers count, only changes ping (first sight seeds silently), and delivery
sits behind a seam so tests never touch the real notification center.

## Activity: "is it still working?"

Separate from usage numbers. One `AgentActivityMonitor` per provider
(`Sources/Sessions/`) tails local session files (Claude JSONL, Cursor
SQLite, Codex rollout log) and publishes `[AgentSession]` (busy / waiting /
done). `ActivitySummary` folds them into the ring's spinner or amber pulse.
Monitors also drive `store.isBusy`, which is what drops polling to the idle
rate when nothing runs.

## The notch: stack space, then pixels

The notch works in one-dimensional **stack space** (`along` / `across`) and
only `NotchPlacement` maps that onto screen coordinates for the current
`NotchEdge`:

- `NotchLayout` — every measurement, quoted from the design frame via
  `Design.px(_:)`. Pure math, heavily tested.
- `NotchPlacement` — stack space ↔ panel rect for the current edge.
- `NotchGeometry` — which screen, and the panel frame against its
  (usable) bounds. Follows the Dock; merges with the hardware notch on top.
- `NotchViewModel` — snapshots + sessions + hover/expand state. Geometry
  helpers on it must stay thin projections over `NotchLayout`.
- `NotchWindowController` — the AppKit side: `NSPanel`, cursor polling,
  hover grace periods, context menu, clock ticks. No layout math here.
- `NotchPanel` is click-through outside its drawn path; the tooltip's empty
  margin is *not* clickable (a plain container view would turn that hole
  into a wall — see TASKS.md, "The window that shrank itself to nothing").

Hover state is driven by a cursor monitor, not `NSTrackingArea` — the panel
ignores mouse events until the cursor is over it, so tracking areas never
see the crossing that would switch event handling on.

## App composition

`AppDelegate` wires it all: profiles → providers → store → controller, plus
monitors, preferences bindings, settings, updater, status item. Keep it as
wiring only; logic belongs in the objects it connects.

Settings persist in `Preferences` (`UserDefaults`); "off" is stored as the
*disconnected* set so providers added later default to on.

## Conventions

- Comments explain **why** (hidden constraints, worked-around bugs,
  decisions that would look arbitrary). No what-comments.
- No premature abstraction — three similar lines beat an early helper.
- `make run` / `make test` need no signing identity. `make release`
  (archive → notarize → Sparkle appcast) is the maintainer's job.
- `CODENOTCH_DEMO=1` runs the notch on fixed sample data for screenshots
  and layout eyeballing.
