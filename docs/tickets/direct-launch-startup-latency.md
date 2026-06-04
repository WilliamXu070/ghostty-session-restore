## Symptom

Opening Newmux tabs in Ghostty can linger on:

```text
exec /Users/williamxu/Desktop/Projects/newmux/scripts/start-newmux-fresh.sh
Last login: ...
```

The first terminal input is delayed, and restore can appear to do nothing
because the new native tab has not attached to Newmux quickly enough.

## Expected Behavior

Newmux Ghostty tabs should start `scripts/start-newmux-fresh.sh` directly,
without a visible shell startup command and without the macOS `/usr/bin/login`
wrapper in the patched development app.

## Diagnosis

The profile regressed from:

```ini
command = direct:/Users/williamxu/Desktop/Projects/newmux/scripts/start-newmux-fresh.sh
```

to:

```ini
command = /bin/zsh
input = raw:exec /Users/williamxu/Desktop/Projects/newmux/scripts/start-newmux-fresh.sh\r
```

That forces every new tab through shell startup and Ghostty startup-input
delivery before Newmux can attach. The process tree confirmed live Newmux
clients parented through `/usr/bin/login` while the slow path was active.

The first verification run also showed the golden UI helper was overriding
the launcher default with `NEWMUX_USE_PATCHED_GHOSTTY=0`, so UI regressions
could keep exercising the unpatched normal Ghostty app even though
`scripts/open-newmux-ghostty.sh` defaults to the patched app when available.

Follow-up regression failures exposed two test harness races after the fast
path was restored:

- `gf-newtab-fresh-clean` could delete a tab before its marker command had
  actually executed.
- `gf-five-tab-restore-order-latency` relied on a temporary `codex` shim in
  `PATH`, but the foreground macOS `open` path was not passing `PATH` into
  Ghostty and the sourced user `.zshrc` could still rewrite the controlled
  test path.

## Plan

1. Restore the direct Ghostty command path.
2. Keep `open-newmux-ghostty.sh` launching the patched Ghostty app with
   `NEWMUX_GHOSTTY_SKIP_LOGIN=1`.
3. Align golden UI tests with the patched-app launcher default.
4. Convert window restore to a two-phase startup claim: `Command+Shift+T`
   writes a restore request and opens a native tab immediately; the new tab
   startup script pops and attaches the latest recoverable window only after
   the tab exists.
5. Add a regression that rejects raw startup `exec` input and fails if the
   Newmux client is parented by `/usr/bin/login`.
6. Add a focused fast-restore regression and keep the flaky five-tab latency
   script manual-only.
7. Pass `PATH` through foreground Ghostty launches, let tests opt out of
   sourcing the user's `.zshrc`, and make the fresh-clean test wait for marker
   output before deleting.
8. Run Ghostty config validation, startup regression, recovery regressions,
   and the full regression platform.

## Verification

- `sh -n scripts/request-newmux-restore-tab.sh scripts/start-newmux-fresh.sh testing/test-newmux-gf-fast-restore-attach.sh`
- `/Applications/Ghostty.app/Contents/MacOS/ghostty +validate-config --config-file=ghostty-config/newmux.config`
- `./scripts/build-newmux.sh`
  - Built `bin/newmux`.
  - Reported `tmux next-3.7-newmux-dev`.
- `testing/test-newmux-gf-fast-restore-attach.sh`
  - Passed with restored window `@1`.
  - Restore attach latency: 247 ms.
- `env NEWMUX_GOLDEN_BACKGROUND_INPUT=0 testing/test-newmux-gf-fast-restore-attach.sh`
  - Passed with real foreground Ghostty keyboard input.
  - Restore attach latency: 558 ms.
  - Screenshot evidence:
    `.local/newmux-golden-runs/gf-fast-restore-attach-88015/04-after-restore.png`
  - Tmux capture/log evidence shows the recovered marker output and an empty
    recently closed stack after restore.
- `./scripts/run-regression.sh --tags recovery --no-fail-fast`
  - Passed 9/9 selected non-manual recovery tests.
  - Run log:
    `.local/newmux-regression-runs/20260603-233829.log`
- `env NEWMUX_GOLDEN_BACKGROUND_INPUT=0 testing/test-newmux-gf-fast-restore-attach.sh`
  with restore tracing enabled by the test.
  - Passed with restored window `@1`.
  - Restore attach latency: 771 ms.
  - Trace evidence:
    `.local/newmux-golden-runs/gf-fast-restore-attach-2541/restore-trace.tsv`
  - Largest measured gaps:
    - 323 ms: foreground test key dispatch before the restore request reached
      Newmux. This is UI automation overhead, not Newmux restore work.
    - 108 ms: sent shortcut to `request-newmux-restore-tab.sh` entry.
    - 92 ms: AppleScript native-tab open request.
    - 19 ms: native tab open returning to `start-newmux-fresh.sh` entry.
    - 15 ms: `newmux-reopen-latest-closed -P`, the live window relink.
  - Conclusion: in the patched direct-launch test, the live Newmux restore is
    already fast. Remaining time is mostly frontend/native-tab dispatch and
    shell-script round trips. If `Last login` is visible in manual use, that is
    a separate unpatched/normal-Ghostty launch path before Newmux gets control.
- `testing/test-newmux-gf-fast-restore-attach.sh` after server-side
  reservation and queued restore tickets.
  - Passed with restored window `@1`.
  - Restore attach latency: 334 ms.
  - Burst restore subcase passed:
    - deleted three recoverable windows
    - reserved all three before any startup claim
    - restored in LIFO order: `@6 @5 @4`
  - Trace evidence:
    `.local/newmux-golden-runs/gf-fast-restore-attach-21170/restore-trace.tsv`
  - New hot path:
    - `newmux-reserve-latest-closed -P` reserves the latest item immediately.
    - startup consumes a queued ticket.
    - `newmux-claim-reserved-closed -P -S <sequence>` restores exactly that
      reserved item.
    - final attach skips the redundant `has-session` probe and execs
      `bin/newmux attach-session` directly.

The manual five-tab latency diagnostic was intentionally not used as pass/fail
evidence for this fix.

## Status

Fixed and verified locally.
