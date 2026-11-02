#!/usr/bin/env bash
# Compares stator-ts diagnostics with the real tsc, by (file, line, code). The column only feeds
# the stricter "exact" count: tsc anchors some errors differently without the error being wrong.
#
# usage: tests/differential.sh [-v] [project-dir...]
#   no directories: every fixture in tests/fixtures
#   -v:             list each false positive and miss
#   TSC:            tsc to compare with (default: tests/node_modules/.bin/tsc)
#   STATOR_TS:      binary to test (default: build zig-out/bin/stator-ts)
# Exit status: 1 when any project has a false positive, because that breaks the checker's rule
# that an error must be a real error. Misses only count.
set -u

here=$(cd "$(dirname "$0")" && pwd)
verbose=0
if [ "${1:-}" = "-v" ]; then
	verbose=1
	shift
fi

tsc=${TSC:-$here/node_modules/.bin/tsc}
if [ ! -x "$tsc" ]; then
	echo "error: no tsc at $tsc: run 'npm ci --ignore-scripts' in tests/, or set TSC" >&2
	exit 1
fi
if [ -z "${STATOR_TS:-}" ]; then
	(cd "$here/.." && zig build) || exit 1
	STATOR_TS=$here/../zig-out/bin/stator-ts
fi
# Both compilers must read the same lib.*.d.ts, or lib differences show up as checker differences.
# The default tsc needs no help: stator-ts finds it as it would in a user's project, which keeps
# that lookup under test.
if [ -n "${TSC:-}" ] && [ -z "${STATOR_TS_LIB:-}" ]; then
	STATOR_TS_LIB=$(node -e '
		const fs = require("fs"), path = require("path");
		const pkg = path.dirname(path.dirname(fs.realpathSync(process.argv[1])));
		const js = path.join(pkg, "lib");
		if (fs.existsSync(path.join(js, "lib.d.ts"))) {
			console.log(js);
		} else {
			const native = `@typescript/typescript-${process.platform}-${process.arch}/package.json`;
			const load = require("module").createRequire(pkg + path.sep);
			console.log(path.join(path.dirname(load.resolve(native)), "lib"));
		}
	' "$tsc") || exit 1
	export STATOR_TS_LIB
fi

if [ $# -eq 0 ]; then
	set -- "$here"/fixtures/*/
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

keys() {
	sed -nE 's/^([^ ].*)\(([0-9]+),([0-9]+)\): error (TS[0-9]+):.*/\1 \2 \4 \3/p' | sort -u
}

printf '%-30s %6s %6s %6s %6s %6s\n' project tsc ours match fp miss
total_tsc=0 total_ours=0 total_match=0 total_fp=0 total_miss=0 total_exact=0 total_crash=0
for dir in "$@"; do
	name=$(basename "$dir")
	(cd "$dir" && "$STATOR_TS" check >"$work/ours.out" 2>&1)
	# 0 and 2 are the verdicts; anything else means no verdict, not "no errors".
	status=$?
	if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
		echo "$name: stator-ts exited with status $status" >&2
		total_crash=$((total_crash + 1))
	fi
	keys <"$work/ours.out" >"$work/ours.col"
	(cd "$dir" && "$tsc" -p . --noEmit 2>&1) | keys >"$work/tsc.col"
	cut -d' ' -f1-3 "$work/ours.col" | sort -u >"$work/ours"
	cut -d' ' -f1-3 "$work/tsc.col" | sort -u >"$work/tsc"
	comm -23 "$work/ours" "$work/tsc" >"$work/fp"
	comm -13 "$work/ours" "$work/tsc" >"$work/miss"
	n_tsc=$(wc -l <"$work/tsc" | tr -d ' ')
	n_ours=$(wc -l <"$work/ours" | tr -d ' ')
	n_match=$(comm -12 "$work/ours" "$work/tsc" | wc -l | tr -d ' ')
	n_fp=$(wc -l <"$work/fp" | tr -d ' ')
	n_miss=$(wc -l <"$work/miss" | tr -d ' ')
	n_exact=$(comm -12 "$work/ours.col" "$work/tsc.col" | cut -d' ' -f1-3 | sort -u | wc -l | tr -d ' ')
	printf '%-30s %6d %6d %6d %6d %6d\n' "$name" "$n_tsc" "$n_ours" "$n_match" "$n_fp" "$n_miss"
	if [ "$verbose" = 1 ]; then
		sed 's/^/  fp   /' "$work/fp"
		sed 's/^/  miss /' "$work/miss"
	fi
	total_tsc=$((total_tsc + n_tsc))
	total_ours=$((total_ours + n_ours))
	total_match=$((total_match + n_match))
	total_fp=$((total_fp + n_fp))
	total_miss=$((total_miss + n_miss))
	total_exact=$((total_exact + n_exact))
done
printf '%-30s %6d %6d %6d %6d %6d\n' overall "$total_tsc" "$total_ours" "$total_match" "$total_fp" "$total_miss"
echo "exact column on $total_exact of $total_match matches"
[ "$total_fp" -eq 0 ] && [ "$total_crash" -eq 0 ]
