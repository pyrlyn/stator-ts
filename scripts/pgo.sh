#!/usr/bin/env bash
# Builds zig-out/bin/stator-ts-pgo, optimized with a profile of one check of a real project. Zig has
# no PGO of its own, so clang optimizes the bitcode Zig writes before its passes run: after them,
# inlining has been decided without the profile. Clang's LLVM must not be older than Zig's. macOS
# only, for the link line.
#
# usage: mise exec conda:clang@23.1.4 conda:llvm-tools@23.1.4 -- scripts/pgo.sh <check arguments>
#   <check arguments>:          what to train on, as for `stator-ts check`
#   ZIG, CLANG, LLVM_PROFDATA:  tools to use (default: from PATH)
set -euo pipefail

cd "$(dirname "$0")/.."
zig=${ZIG:-zig}
clang=${CLANG:-clang}
profdata=${LLVM_PROFDATA:-llvm-profdata}
if [ $# -eq 0 ]; then
	echo "usage: scripts/pgo.sh <check arguments>" >&2
	exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$zig" build --fetch
coroutines=(zig-pkg/coroutines-*/src/root.zig)

# A fresh cache dir, because Zig writes neither the bitcode nor the link line on a cache hit.
"$zig" build-exe -Ofast --dep coroutines -Mroot=src/main.zig -Ofast -Mcoroutines="${coroutines[0]}" \
	--cache-dir "$tmp/cache" --name stator-ts -femit-bin="$tmp/zig-bin" \
	--verbose-llvm-bc="$tmp/pre.bc" --verbose-link 2>"$tmp/link.txt"
# The JSON parser needs f128 helpers, and only Zig's runtime is sure to have them.
runtime=$(grep -o '[^ ]*libcompiler_rt\.a' "$tmp/link.txt" | head -n 1)
sdk=$(xcrun --show-sdk-path)

opt=(-O3 -mcpu=native -x ir -Wno-override-module)
# Atomic counters: the workers share them, and lost updates would skew the hot paths.
"$clang" "${opt[@]}" -fprofile-generate="$tmp/raw" -fprofile-update=atomic -c "$tmp/pre.bc" -o "$tmp/gen.o"
"$clang" -isysroot "$sdk" -fprofile-generate "$tmp/gen.o" "$runtime" -lSystem -dead_strip -o "$tmp/gen"

# Status 2 only means the project has errors, which is fine to train on. Anything else would leave
# a profile of a failed load.
status=0
"$tmp/gen" check "$@" >/dev/null || status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
	echo "error: the instrumented check exited with status $status" >&2
	exit 1
fi

"$profdata" merge -o "$tmp/app.profdata" "$tmp"/raw/*.profraw
"$clang" "${opt[@]}" -fprofile-use="$tmp/app.profdata" -c "$tmp/pre.bc" -o "$tmp/use.o"
mkdir -p zig-out/bin
"$clang" -isysroot "$sdk" "$tmp/use.o" "$runtime" -lSystem -dead_strip -o zig-out/bin/stator-ts-pgo
