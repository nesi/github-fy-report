#!/usr/bin/env bash
# Generate an HTML activity report (commits, PRs, reviews, issues) for a
# GitHub handle within an org over a date range, using the gh CLI.
#
# Usage: github-fy-report.sh <github-handle> [org] [start-date] [end-date] [output-file]
#   org          defaults to "nesi"
#   start-date   ISO date (YYYY-MM-DD), defaults to the start of the most
#                recently completed Jul-Jun financial year
#   end-date     ISO date (YYYY-MM-DD), defaults to the end of that same FY
#   output-file  defaults to ./github-report-<handle>-<start>_<end>.html
#
# Requires: gh (authenticated), jq, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/github-fy-report.template.html"

usage() {
  echo "Usage: $(basename "$0") <github-handle> [org] [start-date] [end-date] [output-file]" >&2
  echo "  Dates are ISO (YYYY-MM-DD). Omit start/end to use the most recently" >&2
  echo "  completed Jul-Jun financial year." >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

HANDLE="$1"
ORG="${2:-}"
START="${3:-}"
END="${4:-}"
OUTPUT="${5:-}"

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
echo "Org:    $ORG" >&2
echo "Period: $START .. $END" >&2

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

echo "Fetching commits..." >&2
gh api --paginate "search/commits?q=$(urlenc "author:$HANDLE org:$ORG committer-date:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: .repository.full_name, date: .commit.committer.date}' \
  > "$WORKDIR/commits.jsonl"

echo "Fetching PRs opened..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:pr author:$HANDLE org:$ORG created:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, url: .html_url}' \
  > "$WORKDIR/prs.jsonl"

echo "Fetching reviews given..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:pr reviewed-by:$HANDLE -author:$HANDLE org:$ORG updated:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, url: .html_url}' \
  > "$WORKDIR/reviews.jsonl"

echo "Fetching issues opened..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:issue author:$HANDLE org:$ORG created:$START..$END")&per_page=100" \
  --jq '.items[] | {number: .number, title: .title, state: .state}' \
  > "$WORKDIR/issues_opened.jsonl"

echo "Fetching issues closed..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:issue is:closed involves:$HANDLE org:$ORG closed:$START..$END")&per_page=100" \
  --jq '.items[] | {number: .number, title: .title, closed_at: .closed_at}' \
  > "$WORKDIR/issues_closed.jsonl"

PR_COUNT=$(wc -l < "$WORKDIR/prs.jsonl" | tr -d ' ')
echo "Fetching line-change stats for $PR_COUNT PR(s)..." >&2
: > "$WORKDIR/pr_stats.jsonl"
if [ "$PR_COUNT" -gt 0 ]; then
  jq -c '{repo, number}' "$WORKDIR/prs.jsonl" | while IFS= read -r item; do
    repo=$(echo "$item" | jq -r '.repo')
    number=$(echo "$item" | jq -r '.number')
    timeout 10 gh api "repos/$repo/pulls/$number" \
      | jq -c --arg repo "$repo" --argjson number "$number" \
        '{repo: $repo, number: $number, additions, deletions, merged_at}' \
      >> "$WORKDIR/pr_stats.jsonl" || true
  done
fi

echo "Aggregating and rendering report..." >&2
python3 "$SCRIPT_DIR/github-fy-report-render.py" \
  "$WORKDIR" "$TEMPLATE" "$OUTPUT" "$HANDLE" "$ORG" "$START" "$END"

echo "Report written to: $OUTPUT" >&2
