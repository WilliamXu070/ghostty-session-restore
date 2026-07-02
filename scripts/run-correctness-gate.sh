#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

run_step()
{
	printf '\n==> %s\n' "$*"
	"$@"
}

run_flow()
{
	flow=$1
	run_step python3 scripts/newmux-flow-test.py "$flow"
}

cd "$ROOT"

run_step ./scripts/build-newmux.sh
run_step ./scripts/test-newmux.sh
run_step ./scripts/test-ghostty-config.sh

run_flow tests/flows/delete-clean-hard-dirty-lifo.json
run_flow tests/flows/cmd-w-ui-tab-sync.json
run_flow tests/flows/cmd-shift-t-noop-empty.json
run_flow tests/flows/cmd-shift-t-restore-runtime-lifo.json
run_flow tests/flows/cmd-t-new-tab-same-server.json

printf '\nPASS newmux correctness gate\n'
