#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSES=${NEWMUX_PERF_PASSES:-3}
TIMEOUT=${NEWMUX_PERF_TIMEOUT:-10}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${NEWMUX_PERF_OUT:-".local/benchmarks/newmux-lifecycle-${STAMP}.json"}

usage()
{
	cat <<'USAGE'
Usage:
  ./scripts/sample-performance.sh [options]

Options:
  --passes N        Benchmark passes. Default: NEWMUX_PERF_PASSES or 3.
  --timeout SEC     Per-wait timeout. Default: NEWMUX_PERF_TIMEOUT or 10.
  --out PATH        Output JSON path. Default: .local/benchmarks/newmux-lifecycle-<timestamp>.json.
  --help            Show this help.

This command records an advisory sample only. It does not fail on latency
thresholds while lifecycle numbers are still stabilizing.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--passes)
			if [ $# -lt 2 ]; then
				echo "--passes requires a value" >&2
				exit 2
			fi
			PASSES=$2
			shift
			;;
		--timeout)
			if [ $# -lt 2 ]; then
				echo "--timeout requires a value" >&2
				exit 2
			fi
			TIMEOUT=$2
			shift
			;;
		--out)
			if [ $# -lt 2 ]; then
				echo "--out requires a value" >&2
				exit 2
			fi
			OUT=$2
			shift
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

cd "$ROOT"

mkdir -p "$(dirname -- "$OUT")"
printf '==> lifecycle performance sample: passes=%s timeout=%s out=%s\n' "$PASSES" "$TIMEOUT" "$OUT"
python3 scripts/benchmark-newmux-lifecycle.py \
	--passes "$PASSES" \
	--timeout "$TIMEOUT" \
	--out "$OUT"
printf 'NOTE: performance thresholds are advisory; inspect %s against the current ticket targets.\n' "$OUT"
