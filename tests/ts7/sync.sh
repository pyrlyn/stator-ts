#!/usr/bin/env bash
# Keeps tests/ts7/upstream at the commit named in tests/ts7/upstream.lock.
#
#   tests/ts7/sync.sh          fetch the pinned commit
#   tests/ts7/sync.sh main     move the pin to a branch, tag or commit, then fetch it
#
# Tests stay out of this tree because upstream's suite is large and changes daily; the
# lock file is what makes a run reproducible.
set -euo pipefail

repo=https://github.com/microsoft/TypeScript.git
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dest=$here/upstream
lock=$here/upstream.lock

if [ $# -gt 0 ]; then
    if [[ $1 =~ ^[0-9a-f]{40}$ ]]; then
        sha=$1
    else
        # The dereferenced tag sorts last, so an annotated tag gives its commit.
        sha=$(git ls-remote "$repo" "refs/heads/$1" "refs/tags/$1" "refs/tags/$1^{}" | tail -n 1 | cut -f1)
    fi
    if [ -z "$sha" ]; then
        echo "no such ref: $1" >&2
        exit 2
    fi
    echo "$sha" > "$lock"
fi
sha=$(tr -d '[:space:]' < "$lock")

if [ ! -d "$dest/.git" ]; then
    git init --quiet "$dest"
    git -C "$dest" remote add origin "$repo"
fi
# Nothing from the checkout may run on this machine, and CRLF in a case is part of the case.
git -C "$dest" config core.hooksPath /dev/null
git -C "$dest" config core.autocrlf false
git -C "$dest" config core.sparseCheckout true
git -C "$dest" config core.sparseCheckoutCone false
cat > "$dest/.git/info/sparse-checkout" <<'PATTERNS'
/tsc/testdata/tests/cases/compiler/
/tsc/testdata/tests/cases/conformance/
/tsc/testdata/tests/lib/
/tsc/testdata/baselines/reference/compiler/*.errors.txt
/tsc/testdata/baselines/reference/conformance/*.errors.txt
/tsc/internal/bundled/libs/
PATTERNS

git -C "$dest" fetch --quiet --depth 1 --filter=blob:none origin "$sha"
git -C "$dest" checkout --quiet --force --detach "$sha"

# Names of all baselines, not only the checked-out ones: they tell which option variants
# upstream ran and which tests it skipped, without fetching gigabytes of `.types`.
git -C "$dest" ls-tree -r --name-only HEAD \
    tsc/testdata/baselines/reference/compiler tsc/testdata/baselines/reference/conformance \
    | sed 's#^tsc/testdata/baselines/reference/##' > "$dest/baselines.txt"

cases=$(find "$dest/tsc/testdata/tests/cases" -type f | wc -l | tr -d ' ')
echo "upstream at $sha: $cases test files, $(wc -l < "$dest/baselines.txt" | tr -d ' ') baselines"
