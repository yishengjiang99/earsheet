# Fixer rules (earsheet, AI Music Radar iOS, repo yishengjiang99/earsheet)
Context: round two of Audit→Fix→Verify→TestFlight. Read /workspace/earsheet-audit/{flows.md,stream-plan.md,issue-map.md,product-tracker.md}, /workspace/app-store-playbook/audit-fix-verify-testflight-loop.md and repo AGENTS.md (token-efficiency rules). Issues #7-#45 on the repo hold the bug detail.
User (Yisheng) pre-authorized: fix PRs, squash-merge reviewed PRs, one manual main sim run, TestFlight. Never block on the human: decide, record in /workspace/earsheet-audit/decisions.md (append a dated line), move on.
Rules:
- Own clone: `git clone` or `git worktree` at /workspace/earsheet-<stream>; base on latest main. Linux box has no Xcode: you cannot run tests locally; write careful Swift, reason about compile errors, and re-read your diffs.
- One PR per root cause (or per tightly coupled issue pair). Real PR body: what/why/test. Use "Fixes #N" only when fully fixed, else "Refs #N". Add a regression test using the planned test class names already in the ios-sim.yml -only-testing allowlist (see stream-plan.md). Project uses Xcode synchronized folders: new files need no pbxproj edits. Do NOT edit ios-sim.yml allowlist or TODO.md.
- No feature flags. Analytics anonymous (no PII). Keep core recognition engine untouched. Never touch App Store Connect, asc-* workflows, APP_IDENTITY.md, secrets.
- ios-sim.yml is workflow_dispatch-only. You may run `gh workflow run ios-sim.yml --ref <branch>` once on your stack head before merging (macOS runner, ~20 min; fix real failures). Never dispatch more than one run at a time per stream. Cancel stale runs.
- Never use --delete-branch on a branch that other PRs are stacked on. Use `gh pr merge N --squash` (add --match-head-commit <sha> when merging).
- Merge order across streams: A first, then B and C, then D. Do not merge before your stream's turn unless your instructions say so. Rebase promptly onto main when others merge.
- Final report: PR numbers merged/open, issue numbers fixed (verify each acceptance check from the issue by reading code), anything unfixable and why, risks.
