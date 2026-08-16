#!/usr/bin/env bash
# Generate an HTML activity report (commits, PRs, reviews, issues) for a
# GitHub handle across one or more orgs over a date range, using the gh CLI.
#
# Usage: github-fy-report.sh <github-handle> <org-scope> [start-date] [end-date] [output-file]
#   org-scope    one of:
#                  a comma-separated org list, e.g. "nesi,GenomicsAotearoa"
#                  "all" - every org the authenticated user belongs to
#                  "any" - no org filter, includes personal repos
#                Multiple orgs are OR'd. Orgs the token cannot search
#                (e.g. SAML SSO not authorised) are probed, reported, and skipped.
#   start-date   ISO date (YYYY-MM-DD), defaults to the start of the most
#                recently completed Jul-Jun financial year
#   end-date     ISO date (YYYY-MM-DD), defaults to the end of that same FY
#   output-file  defaults to ./github-report-<handle>-<start>_<end>.html
#
# Requires: gh (authenticated), python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/github-fy-report.template.html"

usage() {
  echo "Usage: $(basename "$0") <github-handle> <org-scope> [start-date] [end-date] [output-file]" >&2
  echo "  org-scope  comma-separated org list (e.g. nesi,GenomicsAotearoa)," >&2
  echo "             'all' for every org you belong to, or" >&2
  echo "             'any' for no org filter (includes personal repos)." >&2
  echo "  Dates are ISO (YYYY-MM-DD). Omit start/end to use the most recently" >&2
  echo "  completed Jul-Jun financial year." >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

HANDLE="$1"
ORG_SCOPE="${2:-}"
START="${3:-}"
END="${4:-}"
OUTPUT="${5:-}"

if [ -z "$ORG_SCOPE" ]; then
  echo "Error: org-scope is required." >&2
  usage
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "Error: template not found at $TEMPLATE (expected alongside this script)." >&2
  exit 1
fi

urlenc() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# --- resolve org scope -------------------------------------------------------
# ORGS is the final list of orgs to search; empty means "no org filter".
ORGS=()
if [ "$ORG_SCOPE" = "any" ]; then
  echo "Scope:  any (no org filter, includes personal repos)" >&2
elif [ "$ORG_SCOPE" = "all" ]; then
  echo "Discovering orgs for the authenticated user..." >&2
  while IFS= read -r o; do
    [ -n "$o" ] && ORGS+=("$o")
  done < <(gh api user/orgs --paginate --jq '.[].login')
  if [ ${#ORGS[@]} -eq 0 ]; then
    echo "Error: 'all' found no org memberships for the authenticated account." >&2
    echo "  Note: 'all' reads your own memberships and cannot enumerate another user's" >&2
    echo "  private org memberships. Pass an explicit comma-separated list instead." >&2
    exit 1
  fi
  echo "Found: ${ORGS[*]}" >&2
else
  IFS=',' read -r -a RAW_ORGS <<< "$ORG_SCOPE"
  for o in "${RAW_ORGS[@]}"; do
    o="$(echo "$o" | tr -d '[:space:]')"
    [ -n "$o" ] && ORGS+=("$o")
  done
  if [ ${#ORGS[@]} -eq 0 ]; then
    echo "Error: org-scope '$ORG_SCOPE' contained no usable org names." >&2
    exit 1
  fi
fi

# Probe each org. A single unsearchable org (SAML SSO, deleted, typo) returns
# HTTP 422 and would otherwise fail the whole combined query.
if [ ${#ORGS[@]} -gt 0 ]; then
  echo "Checking org access..." >&2
  REACHABLE=()
  for o in "${ORGS[@]}"; do
    # Issue search is used here rather than commit search: commit search rejects
    # qualifier-only queries ("Search text is required when searching commits").
    if gh api "search/issues?q=$(urlenc "org:$o involves:$HANDLE")&per_page=1" --jq '.total_count' >/dev/null 2>&1; then
      REACHABLE+=("$o")
    else
      echo "  Skipping '$o': not searchable with this token (SAML SSO not authorised, or no such org)." >&2
    fi
  done
  if [ ${#REACHABLE[@]} -eq 0 ]; then
    echo "Error: none of the requested orgs are searchable with this token." >&2
    echo "  For SAML-protected orgs, authorise your token at:" >&2
    echo "  https://github.com/settings/tokens (or re-run 'gh auth login' with SSO)." >&2
    exit 1
  fi
  ORGS=("${REACHABLE[@]}")
fi

# Build the "org:a org:b" search qualifier (empty for 'any').
ORG_Q=""
for o in ${ORGS[@]+"${ORGS[@]}"}; do
  ORG_Q="$ORG_Q org:$o"
done

# Comma-joined list handed to the renderer for prefix stripping and labels.
ORG_LIST="$(IFS=,; echo "${ORGS[*]-}")"

if [ -z "$START" ] || [ -z "$END" ]; then
  read -r DEFAULT_START DEFAULT_END < <(python3 -c "
import datetime
today = datetime.date.today()
y, m = today.year, today.month
if m >= 7:
    start_year, end_year = y - 1, y
else:
    start_year, end_year = y - 2, y - 1
print(f'{start_year}-07-01 {end_year}-06-30')
")
  START="${START:-$DEFAULT_START}"
  END="${END:-$DEFAULT_END}"
fi

if [ -z "$OUTPUT" ]; then
  OUTPUT="./github-report-${HANDLE}-${START}_${END}.html"
fi

echo "Handle: $HANDLE" >&2
echo "Orgs:   ${ORG_LIST:-<none - searching all of GitHub>}" >&2
echo "Period: $START .. $END" >&2

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Fetching commits..." >&2
gh api --paginate "search/commits?q=$(urlenc "author:$HANDLE$ORG_Q committer-date:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: .repository.full_name, date: .commit.committer.date}' \
  > "$WORKDIR/commits.jsonl"

echo "Fetching PRs opened..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:pr author:$HANDLE$ORG_Q created:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, url: .html_url}' \
  > "$WORKDIR/prs.jsonl"

echo "Fetching reviews given..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:pr reviewed-by:$HANDLE -author:$HANDLE$ORG_Q updated:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, url: .html_url}' \
  > "$WORKDIR/reviews.jsonl"

echo "Fetching issues opened..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:issue author:$HANDLE$ORG_Q created:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, state: .state}' \
  > "$WORKDIR/issues_opened.jsonl"

echo "Fetching issues closed..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:issue is:closed involves:$HANDLE$ORG_Q closed:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, closed_at: .closed_at}' \
  > "$WORKDIR/issues_closed.jsonl"

PR_COUNT=$(wc -l < "$WORKDIR/prs.jsonl" | tr -d ' ')
echo "Fetching line-change stats for $PR_COUNT PR(s)..." >&2
: > "$WORKDIR/pr_stats.jsonl"
if [ "$PR_COUNT" -gt 0 ]; then
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        p = json.loads(line)
        print(p["repo"], p["number"])
' "$WORKDIR/prs.jsonl" | while read -r repo number; do
    timeout 10 gh api "repos/$repo/pulls/$number" \
      --jq '{additions, deletions, merged_at}' \
      | python3 -c '
import json, sys
s = json.load(sys.stdin)
s["repo"], s["number"] = sys.argv[1], int(sys.argv[2])
print(json.dumps(s))
' "$repo" "$number" \
      >> "$WORKDIR/pr_stats.jsonl" || true
  done
fi

echo "Aggregating and rendering report..." >&2
python3 "$SCRIPT_DIR/github-fy-report-render.py" \
  "$WORKDIR" "$TEMPLATE" "$OUTPUT" "$HANDLE" "$ORG_LIST" "$START" "$END"

echo "Report written to: $OUTPUT" >&2
