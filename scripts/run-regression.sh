#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="${ROOT}/scripts/regression-manifest.tsv"

MODE="baseline"
TAGS_FILTER=""
TEST_FILTER=""
FOR_CHANGED="${NEWMUX_REGRESSION_CHANGED_BASE:-}"
INCLUDE_MANUAL=0
FAIL_FAST="${NEWMUX_REGRESSION_FAIL_FAST:-1}"
RUNS_DIR="${ROOT}/.local/newmux-regression-runs"
RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_LOG="${RUNS_DIR}/${RUN_ID}.log"

usage()
{
	cat <<'USAGE'
Usage:
  ./scripts/run-regression.sh [options]

Options:
  --all                 Run every registered regression test.
  --baseline            Run baseline critical/smoke tests (default).
  --changed [base]      Run tests mapped to files changed against base.
                        Default base is environment NEWMUX_REGRESSION_CHANGED_BASE
                        if set, otherwise origin/main.
  --tags TAGS           Run tests matching comma-separated tags.
  --test TEST_ID        Run only one test ID from the manifest.
  --include-manual      Include tests marked manual (off by default).
  --list                Print manifest entries and exit.
  --no-fail-fast        Keep running even if a test fails.
  --help                Show this help.

Exit codes:
  0 pass, 1 failed (non-skipped), 2 invalid usage, 3 no tests selected.
USAGE
}

tag_matches()
{
	need=$1
	have=$2

	IFS=','
	set -- $need
	for tag in "$@"; do
		case ",$have," in
			*,"$tag",*)
				return 0
				;;
		esac
	done
	return 1
}

scope_matches_file()
{
	file=$1
	scope=$2

	[ -z "$scope" ] && return 0
	IFS=':'
	set -- $scope
	for pattern in "$@"; do
		[ -z "$pattern" ] && continue
		case "$pattern" in
			-) continue ;;
		esac
		case "$file" in
			$pattern)
				return 0
				;;
		esac
	done
	return 1
}

collect_changed_files()
{
	base=$1
	if [ -z "$base" ]; then
		if git -C "$ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
			base="origin/main"
		elif git -C "$ROOT" rev-parse --verify main >/dev/null 2>&1; then
			base="main"
		else
			base="HEAD~1"
		fi
	fi
	git -C "$ROOT" diff --name-only "${base}...HEAD"
}

is_script_executable()
{
	script=$1
	[ -x "$script" ] || [ -x "$ROOT/$script" ]
}

if [ $# -eq 0 ]; then
	MODE="baseline"
fi

while [ $# -gt 0 ]; do
	case "$1" in
		--all)
			MODE="all"
			;;
		--baseline)
			MODE="baseline"
			;;
		--changed)
			MODE="changed"
			if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then
				FOR_CHANGED="$2"
				shift
			fi
			;;
		--tags)
			if [ $# -lt 2 ]; then
				echo "--tags requires a value" >&2
				exit 2
			fi
			MODE="tag"
			TAGS_FILTER=$2
			shift
			;;
		--test)
			if [ $# -lt 2 ]; then
				echo "--test requires a value" >&2
				exit 2
			fi
			MODE="test"
			TEST_FILTER=$2
			shift
			;;
		--include-manual)
			INCLUDE_MANUAL=1
			;;
		--list)
			while IFS='|' read -r id tags script scope notes; do
				[ -z "$id" ] && continue
				case "$id" in
					\#*) continue ;;
				esac
				printf '%-22s %-28s %s\n' "$id" "[$tags]" "$script"
				printf '  %s\n' "$notes"
			done < "$MANIFEST"
			exit 0
			;;
		--no-fail-fast)
			FAIL_FAST=0
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

if [ ! -r "$MANIFEST" ]; then
	echo "Manifest not found: $MANIFEST" >&2
	exit 2
fi

mkdir -p "$RUNS_DIR"
{
	printf 'newmux regression run: %s\n' "$RUN_ID"
	printf 'root: %s\n' "$ROOT"
	printf 'mode: %s\n' "$MODE"
} > "$RUN_LOG"

CHANGED_FILES=""
if [ "$MODE" = "changed" ]; then
	CHANGED_FILES=$(collect_changed_files "$FOR_CHANGED") || CHANGED_FILES=""
fi

if [ "$MODE" = "changed" ] && [ -n "$CHANGED_FILES" ]; then
	{
		echo "Changed files:"
		echo "$CHANGED_FILES"
	} >> "$RUN_LOG"
fi

SELECTED_COUNT=0
while IFS='|' read -r id tags script scope notes; do
	[ -z "$id" ] && continue
	case "$id" in
		\#*) continue ;;
	esac

	pass=0
	case "$MODE" in
		all)
			pass=1
			;;
		baseline)
			if tag_matches "critical" "$tags" || tag_matches "smoke" "$tags"; then
				pass=1
			fi
			;;
		tag)
			if tag_matches "$TAGS_FILTER" "$tags"; then
				pass=1
			fi
			;;
		test)
			if [ "$id" = "$TEST_FILTER" ]; then
				pass=1
			fi
			;;
		changed)
			if [ -n "$CHANGED_FILES" ]; then
				for changed_file in $CHANGED_FILES; do
					if scope_matches_file "$changed_file" "$scope"; then
						pass=1
						break
					fi
				done
			elif tag_matches "critical" "$tags" || tag_matches "smoke" "$tags"; then
				pass=1
			fi
			;;
	esac

	if [ "$INCLUDE_MANUAL" -eq 0 ] && tag_matches "manual" "$tags"; then
		pass=0
	fi

	if [ "$pass" -eq 1 ]; then
		SELECTED_COUNT=$((SELECTED_COUNT + 1))
	{
		printf '%s|%s|%s|%s\n' "$id" "$tags" "$script" "$notes"
	} >> "${RUNS_DIR}/${RUN_ID}.selected"
	fi
done < "$MANIFEST"

if [ "$SELECTED_COUNT" -eq 0 ]; then
	if [ "$MODE" = "changed" ] && [ -n "$CHANGED_FILES" ]; then
		echo "No scope match for changed-file mode; falling back to baseline tests." >> "$RUN_LOG"
		MODE="baseline"
		CHANGED_FILES=""
		while IFS='|' read -r id tags script scope notes; do
			[ -z "$id" ] && continue
			case "$id" in
				\#*) continue ;;
			esac
			pass=0
			if tag_matches "critical" "$tags" || tag_matches "smoke" "$tags"; then
				pass=1
			fi
			if [ "$INCLUDE_MANUAL" -eq 0 ] && tag_matches "manual" "$tags"; then
				pass=0
			fi
			if [ "$pass" -eq 1 ]; then
				SELECTED_COUNT=$((SELECTED_COUNT + 1))
				{
					printf '%s|%s|%s|%s\n' "$id" "$tags" "$script" "$notes"
				} >> "${RUNS_DIR}/${RUN_ID}.selected"
			fi
		done < "$MANIFEST"
	fi
fi

if [ "$SELECTED_COUNT" -eq 0 ]; then
	echo "No tests matched current selection." >&2
	exit 3
fi

TOTAL=0
PASS=0
FAIL=0
SKIP=0

{
	echo "Selected tests:"
	while IFS='|' read -r sid _; do
		echo "- $sid"
	done < "${RUNS_DIR}/${RUN_ID}.selected"
	echo
} >> "$RUN_LOG"

trap 'rm -f "${RUNS_DIR}/${RUN_ID}.selected"' EXIT

while IFS='|' read -r id tags script notes; do
	TOTAL=$((TOTAL + 1))
	cmd="${ROOT}/${script}"
	log_path="${RUNS_DIR}/${RUN_ID}-${id}.log"

	echo "===== RUN $TOTAL: $id ($script) ====="
	printf '[%s] RUN %s %s\n' "$(date +%H:%M:%S)" "$id" "$script" >> "$RUN_LOG"

	if ! is_script_executable "$script"; then
		echo "  [FAIL] $script missing or not executable"
		printf 'FAIL %s missing_or_not_executable\n' "$id" >> "$RUN_LOG"
		FAIL=$((FAIL + 1))
		if [ "$FAIL_FAST" -eq 1 ]; then
			exit 1
		fi
		continue
	fi

	set +e
	"$cmd" > "$log_path" 2>&1
	rc=$?
	set -e

	case "$rc" in
		0)
			echo "  [PASS] $id"
			printf 'PASS %s\n' "$id" >> "$RUN_LOG"
			PASS=$((PASS + 1))
			;;
		77)
			echo "  [SKIP] $id (environment gate)"
			printf 'SKIP %s\n' "$id" >> "$RUN_LOG"
			SKIP=$((SKIP + 1))
			;;
		*)
			echo "  [FAIL] $id (exit=$rc)"
			printf 'FAIL %s exit=%s\n' "$id" "$rc" >> "$RUN_LOG"
			printf '%s\n' "---- $log_path log ----" >> "$RUN_LOG"
			cat "$log_path" >> "$RUN_LOG"
			FAIL=$((FAIL + 1))
			if [ "$FAIL_FAST" -eq 1 ]; then
				echo "Full log: $RUN_LOG" >&2
				exit 1
			fi
			;;
	esac
done < "${RUNS_DIR}/${RUN_ID}.selected"

{
	echo "newmux regression summary: total=$TOTAL pass=$PASS fail=$FAIL skip=$SKIP"
	echo "run log: $RUN_LOG"
} >> "$RUN_LOG"

if [ "$FAIL" -ne 0 ]; then
	echo "FAILED: $FAIL tests failed" >&2
	echo "Full log: $RUN_LOG" >&2
	exit 1
fi

echo "PASS: all selected tests passed (with $SKIP skipped)."
echo "run log: $RUN_LOG"
