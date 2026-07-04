## Symptom

After deleting a Newmux window, pressing `Command + Shift + T` appears to do nothing. The deleted window remains in the recovery stack and does not reattach as a native Ghostty tab.

## Expected Behavior

One `Command + Shift + T` should restore exactly one deleted Newmux window by opening a Ghostty native tab whose startup script claims the pending restore marker and runs `newmux-reopen-latest-closed`.

## Diagnosis

The tmux-side recovery command works. A controlled headless reproduction proved:

- `newmux-soft-delete-window` pushes one deleted window.
- `newmux-reopen-latest-closed` restores that window directly.
- `request-newmux-restore-tab.sh` plus `start-newmux-fresh.sh` restores the window when the startup router is invoked explicitly.

The live failing state is different:

- The deleted windows are still present in `newmux-list-recently-closed`.
- A restore marker exists at `/var/folders/.../newmux-restore-tab-501-newmux-dev`.
- No startup router claimed that marker.
- Two Ghostty app processes are running: the patched dev Ghostty and normal `/Applications/Ghostty.app`.

The restore helper currently writes a marker, then uses AppleScript:

```sh
tell application "Ghostty" to activate
tell application "System Events" to keystroke "t" using command down
```

That is nondeterministic when multiple Ghostty app instances exist. The new native tab may be opened in the wrong Ghostty process/profile, or not through the Newmux startup profile at all. Then the marker remains unclaimed, and future restore attempts exit because they see the existing marker.

## Plan

1. Stop using AppleScript `Command+T` inside `request-newmux-restore-tab.sh`.
2. Open the known patched Ghostty app/profile directly, using the same launcher path as `open-newmux-ghostty.sh`.
3. Pass an explicit restore env flag or marker payload so `start-newmux-fresh.sh` knows the new surface is for restore.
4. Add stale marker expiration so an unclaimed marker older than a small TTL cannot block future restores forever.
5. Add a regression test that starts both normal Ghostty and patched Ghostty, deletes a Newmux window, triggers restore, and proves the marker is claimed by the patched profile and the stack drops by one.

## Verification

Pending. Current diagnosis only.

## Status

Open.
