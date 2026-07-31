#!/usr/bin/env bash
# Build a release PR description in the repo PR-template shape by aggregating
# the "Release Notes / Features / How to test / ..." sections of every feature
# PR bundled in a git range or an explicit PR-number list. Used by next-release-branch.yml
# for both:
#   - the final rewrite when a release branch merges to master, and
#   - the incremental sync when a feature PR merges into an open release branch.
#
# Usage:
#   build_release_pr_body.sh <git-range> <overview-line>
#     <git-range>     e.g. "v868.0..HEAD" or "origin/master..HEAD"
#     <overview-line> first line printed under "## Overview" (before the bundle list)
#   build_release_pr_body.sh --pr-list <pr-numbers> <overview-line>
#     <pr-numbers>    space/newline-separated PR numbers (e.g. "3577 3600")
#     <overview-line> first line printed under "## Overview" (before the bundle list)
# Requires: gh authenticated (GH_TOKEN), REPO env set. Prints the body to stdout.
# NOTE: mirrors next-release-branch.yml discovery (split feature+hotfix sources) — keep in sync.

# Text under a heading matched loosely by keyword(s), stopping at the next
# heading or the template footer separator. $1=body $2=lowercased heading regex.
# Untrusted PR bodies only ever pass through awk stdin — never interpolated.
section() {
  printf '%s\n' "$1" | awk -v re="$2" '
    tolower($0) ~ ("^#+[[:space:]]+" re) && !f { f=1; d=0; next }
    f && !d && /^#+[[:space:]]/ { d=1 }
    f && !d && /^----/ { d=1 }
    f && !d { print }' | sed -e '/^[[:space:]]*$/d'
}

# Self-test mode: --self-test runs before normal flow with no external dependencies.
if [ "${1:-}" = "--self-test" ]; then
  # Test discovery sed: match both squash "(#N)" and merge "Merge pull request #N".
  # First pattern rewrites squash 'Title (#N)' -> N; second handles classic
  # 'Merge pull request #N'. Order matters: first match rewrites the line so the
  # second never double-fires.
  test_squash=$(echo "Some title (#3573)" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  test_merge=$(echo "Merge pull request #3529 from foo/bar" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  test_inner=$(echo "revert #3570 (#3588)" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  test_release=$(echo "Merge branch 'x' from ichigo-inc/releases/v870.0" | grep -v 'from [^ ]*/releases/v' | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')

  assert() {
    if [ "$1" != "$2" ]; then
      echo "FAIL: expected '$2' but got '$1'" >&2
      exit 1
    fi
  }

  assert "$test_squash" "3573"
  assert "$test_merge" "3529"
  assert "$test_inner" "3588"
  assert "$test_release" ""

  # 5. squash release subject: regex DOES match (3538); exclusion is architectural (never in HEAD^1..HEAD^2 range)
  test_squash_release=$(echo "Release releases/v871.0 (#3538)" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  assert "$test_squash_release" "3538"

  # 6. seed commit, no PR number
  test_seed=$(echo "chore: open releases/v872.0 release line" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  assert "$test_seed" ""

  # 7. scoped conventional commit
  test_scoped=$(echo "feat(api): add endpoint (#3600)" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  assert "$test_scoped" "3600"

  # 8. intermediate patch-release merge excluded; regular hotfix kept
  test_patch_merge=$(echo "Merge pull request #3400 from ichigo-inc/releases/v869.1" | grep -v 'from [^ ]*/releases/v' | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  assert "$test_patch_merge" ""
  test_hotfix=$(echo "Merge pull request #3550 from ichigo-inc/fix/something" | grep -v 'from [^ ]*/releases/v' | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p')
  assert "$test_hotfix" "3550"

  # 9. Bundles extraction (squash fallback)
  test_synced_body='## Overview

Release `v870.0` (2026-07-31). Bundles #3577, #3600.

## Features'
  bundles=$(printf '%s\n' "$test_synced_body" | grep '^Release.*Bundles ' | grep -oE '#[0-9]+' | tr -d '#' | sort -un)
  assert "$bundles" "$(printf '3577\n3600')"

  # 10. no Bundles line
  test_draft_body="## Overview

Draft release PR."
  no_bundles=$(printf '%s\n' "$test_draft_body" | grep 'Bundles ' | grep -oE '#[0-9]+' | tr -d '#' | sort -un)
  assert "$no_bundles" ""

  # Test section(): extract text under "## Release Notes" heading, stop at next heading
  test_body="Some intro
## Release Notes
- Fix one
- Fix two

## Other section
- Something else"

  section_result=$(section "$test_body" ".*release.*note")
  if ! echo "$section_result" | grep -q "Fix one"; then
    echo "FAIL: section() should extract 'Fix one'" >&2
    exit 1
  fi
  if echo "$section_result" | grep -q "Other section"; then
    echo "FAIL: section() should not include 'Other section'" >&2
    exit 1
  fi

  # 11. --pr-list mode with two-line input (guards P0 #3: mapfile -t must expand all lines)
  test_pr_list_input="$(printf '3577\n3600')"
  mapfile -t test_prs <<< "$test_pr_list_input"
  if [ "${#test_prs[@]}" -ne 2 ]; then
    echo "FAIL: --pr-list mapfile should parse 2 PRs but got ${#test_prs[@]}" >&2
    exit 1
  fi
  if [ "${test_prs[0]}" != "3577" ] || [ "${test_prs[1]}" != "3600" ]; then
    echo "FAIL: --pr-list PRs should be [3577, 3600] but got [${test_prs[0]}, ${test_prs[1]}]" >&2
    exit 1
  fi

  echo "All self-tests passed" >&2
  exit 0
fi

set -euo pipefail

: "${REPO:?REPO env required}"

# Support two modes:
# 1. <git-range> <overview-line> — discover PRs from git log range (default)
# 2. --pr-list <pr-numbers> <overview-line> — use explicit PR-number list (squash fallback)
if [ "${1:-}" = "--pr-list" ]; then
  mapfile -t prs <<< "$2"
  OVERVIEW_LINE="$3"
else
  RANGE="$1"
  OVERVIEW_LINE="$2"
  # First pattern rewrites squash 'Title (#N)' -> N; second handles classic
  # 'Merge pull request #N'. Order matters: first match rewrites the line so the
  # second never double-fires. --first-parent filters out extraneous merge commits
  # from the release-branch side, keeping only main-line PRs.
  mapfile -t prs < <(
    git log "$RANGE" --first-parent --pretty='%s' \
      | grep -v 'from [^ ]*/releases/v' \
      | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p' \
      | sort -un
  )
fi

feats=""; bugs=""; changes=""; addl=""; test_steps=""; postdeploy=""; links=""
for n in "${prs[@]}"; do
  pr_json=$(gh pr view "$n" --repo "$REPO" --json title,url,body)
  title=$(printf '%s' "$pr_json" | jq -r '.title // empty')
  url=$(printf '%s' "$pr_json" | jq -r '.url // empty')
  body=$(printf '%s' "$pr_json" | jq -r '.body // empty')

  rn=$(section "$body" ".*release.*note")
  headline=""
  if [ -z "$rn" ]; then
    rn="$title"
  else
    headline=$(printf '%s\n' "$rn" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | sed -n '1p')
  fi

  feats="${feats}- **${title}** (#${n})${headline:+ — ${headline}}"$'\n'
  links="${links}#${n}, "

  bullet=$(printf '%s\n' "$rn" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/^/- /')
  case "$title" in
    [Ff]ix:*|[Hh]otfix:*) bugs="${bugs}${bullet}"$'\n' ;;
    *) changes="${changes}${bullet}"$'\n' ;;
  esac

  a=$(section "$body" ".*additional.*change")
  [ -n "$a" ] && addl="${addl}${a}"$'\n'
  t=$(section "$body" ".*how.*to.*test")
  [ -n "$t" ] && test_steps="${test_steps}**${title} (#${n})**"$'\n'"${t}"$'\n\n'
  p=$(section "$body" ".*post.*deploy")
  [ -n "$p" ] && postdeploy="${postdeploy}**${title} (#${n})** — ${url}"$'\n'"${p}"$'\n\n'
done
links="${links%, }"

{
  echo "## Overview"
  echo
  if [ -n "$links" ]; then
    echo "${OVERVIEW_LINE} Bundles ${links}."
  else
    echo "${OVERVIEW_LINE}"
  fi
  echo
  echo "## Features & Fixes"
  echo
  if [ -n "$feats" ]; then printf '%s\n' "$feats"; else echo "_None._"; fi
  echo "## Additional changes"
  echo
  if [ -n "$addl" ]; then printf '%s\n' "$addl"; else echo "_None._"; fi
  echo
  echo "## How to test"
  echo
  if [ -n "$test_steps" ]; then printf '%s\n' "$test_steps"; else echo "_See the bundled PRs._"; fi
  echo "## Post deploy script"
  echo
  if [ -n "$postdeploy" ]; then printf '%s\n' "$postdeploy"; else echo "_None._"; fi
  echo
  echo "## Release Notes"
  echo
  if [ -n "$bugs" ]; then echo "### Bug fixes"; printf '%s\n' "$bugs"; fi
  if [ -n "$changes" ]; then echo "### Changes"; printf '%s\n' "$changes"; fi
  if [ -z "${bugs}${changes}" ]; then echo "_No bundled PRs with release notes found._"; fi
}
