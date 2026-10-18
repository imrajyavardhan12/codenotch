# Codenotch

A macOS menu-bar agent that shows AI-tool usage limits (Claude Code, Codex, Cursor, …) in a notch-style panel on
the screen edge. Swift, SwiftUI over an AppKit `NSPanel`, generated Xcode project (XcodeGen).
How to build and contribute: @CONTRIBUTING.md
Read `ARCHITECTURE.md` before touching providers, `UsageStore` or the notch layout. `TASKS.md` is the full history.

## Checks

- `make test`: regenerates the project and runs the unit tests through `xcodebuild` (~15 s incremental).
  Run it after every change and quote the `** TEST SUCCEEDED **` line, or the failing test names.
- `make build` / `make run`: Debug build; `run` relaunches the app.
- The Makefile sets `DEVELOPER_DIR` to Xcode; with plain `swift`/`xcodebuild`, export
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` yourself.

## Proving a change works

- Provider changes: response shapes are pinned by tests against recorded payloads (`Tests/*UsageTests.swift`).
  Add the payload you saw as a fixture; a provider must degrade to a `ProviderStatus`, never invent a number.
- Layout math (`Sources/Notch/NotchLayout.swift`): check against `docs/design/frame-124-hover-tooltip.png`;
  every constant is quoted from that frame through `Design.px(_:)`.
- Performance claims need numbers from a Release build, idle and with the panel open:
  `top -pid $(pgrep -x Codenotch) -l 4 -s 10 -stats pid,cpu,idlew,power` and `sample $(pgrep -x Codenotch) 10`.
  Report before and after.
- Bug fix: add the test that fails without the fix.
