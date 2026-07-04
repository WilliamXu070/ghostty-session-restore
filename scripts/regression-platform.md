# Newmux Regression Platform

## Why this exists

Newmux features are high-risk for regression because terminal UX is stateful.  
The regression platform gives every agent a standard way to validate:

1. the current feature’s target behavior
2. the unchanged critical flows from previous work
3. environment-specific/manual tests when available

## Platform pieces

- `scripts/run-regression.sh`  
  Orchestrator for running regression suites.
- `scripts/regression-manifest.tsv`  
  Registry of tests with tags and scope hints.
- Test scripts in `testing/test-*.sh`

## How tests are selected

`run-regression.sh` uses one of these modes:

- `--baseline` (default): runs `critical` and `smoke` tags.
- `--all`: runs every registered, non-manual test.
- `--tags <tag list>`: runs matching tag set.
- `--test <id>`: runs one manifest test.
- `--changed [base]`: maps changed files since base (or `origin/main`) to
  manifest `scope_patterns`.
- `--include-manual`: opt in to `manual` tests.

`exit 77` from a test is treated as skipped (environment-gated tests).

## Manifest format

Each line is:

```text
test_id|tags|script|scope_patterns|notes
```

- `test_id`: unique identifier used by `--test`.
- `tags`: comma-separated tags (`critical`, `smoke`, `ui`, `recovery`, etc).
- `script`: path to a test script.
- `scope_patterns`: colon-separated path globs for changed-file mapping.
- `notes`: short description.

## Golden-flow requirement

Before merging a feature:

1. Identify the affected flows in `AGENTS.md` / task prompt.
2. Add/update regression tests in the manifest.
3. Run:
   - baseline suite
   - feature-tag suite (or feature test ID)
   - all relevant manual tests when environment supports them.

## Current critical golden-flow set (priority 1)

The following flows are required to stay stable on every regression run:

1) `gf-newtab-fresh-clean`
- Command + T opens a new tab that is fresh and clean (no stale recovery window/session reattached).

2) `gf-shift-t-noop-empty`
- Command + Shift + T does nothing when no deleted items exist.
- Must not create/reopen a terminal in this case.

3) `gf-empty-delete-not-recovered`
- Deleting an empty terminal/tab/pane must not place an item into recoverable history.
- A subsequent restore must remain a no-op.

4) `gf-recover-layout-locality`
- Deleted pane recovery restores into the same layout location (same pane_id position).
- Existing pane process state and visible context should remain aligned.

## Suggested CI command

```sh
./scripts/run-regression.sh --all
```

Then track failures against `scripts/run-regression.sh` output.
