## Symptom

In NEWMUX_GHOSTTY_UI=1, Command-T creates a separate window instead of a tab represented by the Newmux rail.

## Expected behavior

Command-T should create a logical tab in the current window group, with the top native Ghostty tab strip hidden and the Newmux rail showing/selecting the tab.

## Diagnosis

The previous fix conflated hiding native tab chrome with disabling native tab groups. TerminalController.newTab returned newWindow when NewmuxUIFlag.enabled, and TerminalWindow.awakeFromNib set tabbingMode to disallowed. That made Command-T equivalent to Command-N. The rail currently uses NSWindowTabGroup as its backing source, so disabling tab groups removes the data structure the rail needs.

## Plan

Restore native tab grouping for data/model behavior. Hide/suppress native tabbar accessory views only when NewmuxUIFlag.enabled. Keep normal Ghostty behavior when the flag is off.

## Verification

Build Ghostty. Launch with NEWMUX_GHOSTTY_UI=1. Press Command-T: one window remains, rail count increments, top native tab strip is not visible.

## Status

In progress.
