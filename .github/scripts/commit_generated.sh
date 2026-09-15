#!/usr/bin/env bash
# Commit generated files onto the current tip of origin/main.
#
# usage: commit_generated.sh "<commit message>" <path>...
#
# These files are build output, not authored content: when another run has
# already pushed its own version, the newest one simply wins. Rebasing instead
# produces an unresolvable conflict on the binary screenshots and leaves the
# checkout mid-rebase, which is how this step used to fail.
set -euo pipefail

MESSAGE=$1
shift

# This script rewrites main, so it checks for itself rather than trusting every
# caller to be gated. A build on a feature branch still produces its IPA and
# screenshots; it just does not push generated files onto main.
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
if [ "${GITHUB_REF_TYPE:-}" != "tag" ] && [ "${GITHUB_REF_NAME:-$DEFAULT_BRANCH}" != "$DEFAULT_BRANCH" ]; then
  echo "commit_generated.sh: on '${GITHUB_REF_NAME:-unknown}', not '$DEFAULT_BRANCH' — skipping the push to $DEFAULT_BRANCH"
  exit 0
fi

STAGING=$(mktemp -d)
for path in "$@"; do
  [ -e "$path" ] || continue
  mkdir -p "$STAGING/$(dirname "$path")"
  cp -R "$path" "$STAGING/$(dirname "$path")/"
done

# FETCH_HEAD, not origin/main: actions/checkout configures a narrow refspec,
# so the remote-tracking ref can be stale and resetting to it would silently
# drop a commit another job just pushed.
git fetch -q origin main
git reset -q --hard FETCH_HEAD

for path in "$@"; do
  rm -rf "$path"
  if [ -e "$STAGING/$path" ]; then
    mkdir -p "$(dirname "$path")"
    cp -R "$STAGING/$path" "$(dirname "$path")/"
  fi
done
rm -rf "$STAGING"

git add -A -- "$@"
if git diff --cached --quiet; then
  echo "nothing to commit"
  exit 0
fi
git commit -q -m "$MESSAGE"
git push origin HEAD:main
