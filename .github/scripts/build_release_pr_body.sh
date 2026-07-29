#!/usr/bin/env bash
# Build a release PR description in the repo PR-template shape by aggregating
# the "Release Notes / Features / How to test / ..." sections of every feature
# PR bundled in a git range. Used by next-release-branch.yml for both:
#   - the final rewrite when a release branch merges to master, and
#   - the incremental sync when a feature PR merges into an open release branch.
#
# Usage: build_release_pr_body.sh <git-range> <overview-line>
#   <git-range>     e.g. "v868.0..HEAD" or "origin/master..HEAD"
#   <overview-line> first line printed under "## Overview" (before the bundle list)
# Requires: gh authenticated (GH_TOKEN), REPO env set. Prints the body to stdout.
set -euo pipefail

RANGE="$1"
OVERVIEW_LINE="$2"
: "${REPO:?REPO env required}"

# Text under a heading matched loosely by keyword(s), stopping at the next
# heading or the template footer separator. $1=body $2=lowercased heading regex.
# Untrusted PR bodies only ever pass through awk stdin — never interpolated.
section() {
  printf '%s\n' "$1" | awk -v re="$2" '
    tolower($0) ~ ("^#+[[:space:]]+" re) && !f { f = 1; next }
    f && /^#+[[:space:]]/ { exit }
    f && /^----/ { exit }
    f { print }' | sed -e '/^[[:space:]]*$/d'
}

mapfile -t prs < <(
  git log "$RANGE" --pretty=%s \
    | grep -v 'from [^ ]*/releases/v' \
    | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p; s/^Merge pull request #([0-9]+).*/\1/p' \
    | sort -un
)

feats=""; bugs=""; changes=""; addl=""; test_steps=""; postdeploy=""; links=""
for n in "${prs[@]}"; do
  pr_json=$(gh pr view "$n" --repo "$REPO" --json title,url,body)
  title=$(printf '%s' "$pr_json" | jq -r '.title')
  url=$(printf '%s' "$pr_json" | jq -r '.url')
  body=$(printf '%s' "$pr_json" | jq -r '.body')

  rn=$(section "$body" ".*release.*note")
  headline=""
  if [ -z "$rn" ]; then
    rn="$title"
  else
    headline=$(printf '%s\n' "$rn" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | head -1)
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
