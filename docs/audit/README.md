# EarSheet audit pack

Docs from the Audit → Fix → Verify → TestFlight loop run on 2026-10-17. Docs only; no code changes.

## Outcome

- **39 issues fixed** (issues #7–#45; see `issue-map.md`, `issues/`, `traceability.md`).
- **Simulator test suite green:** 159 tests, run [39090468266](https://github.com/yishengjiang99/earsheet/actions/runs/39090468266).
- **TestFlight build 21 VALID:** run [39090979311](https://github.com/yishengjiang99/earsheet/actions/runs/39090979311).
- **Open follow-up #86:** no automated coverage of a real StoreKit purchase (headless purchases are not possible in CI).

## Contents

| File | Purpose |
|---|---|
| `flows.md` | User-flow inventory and audit checklist |
| `overview.mmd` / `overview.png` | App flow overview diagram (Mermaid source and render) |
| `issues/` | Per-issue write-ups (`index.json`, `filed.json` map them to GitHub issues) |
| `issue-map.md` | Issue-to-flow map |
| `stream-plan.md` | Fix work-stream plan |
| `product-review.md` / `product-tracker.md` | Product and App Store review, and its tracker |
| `FIXER-RULES.md` | Rules given to the fixer agents |
| `decisions.md` | Decision log |
| `traceability.md` | Issue → fix → verification traceability |
