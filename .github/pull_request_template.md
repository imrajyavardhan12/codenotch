## What
<!-- One line: what does this change, and why? Link the issue if there is one. -->

## Checks
- [ ] `make test` passes.
- [ ] New behavior has a test (`Tests/` mirrors `Sources/` by concern — find the
      closest existing test class before adding a new file).
- [ ] If this touches `Sources/Notch/NotchLayout.swift`, the constants were
      checked against `docs/design/frame-124-hover-tooltip.png`.
- [ ] If this adds or changes a provider adapter, the failure paths still degrade
      to a visible `ProviderStatus` (never an invented number) and the response
      shape is pinned by a test.

## Notes for the reviewer
<!-- Anything surprising, anything you deliberately did not do. -->
