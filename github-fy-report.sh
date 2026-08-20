#!/usr/bin/env bash
# Generate an HTML activity report (commits, PRs/MRs, reviews, issues) for a
# handle across one or more GitHub orgs and, optionally, GitLab groups, over
# a date range.
#
# Usage: github-fy-report.sh <github-handle> <org-scope> [start-date] [end-date] [output-file]
#                             [--gitlab-user USER] [--gitlab-group SCOPE]
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
#   --gitlab-user   GitLab username to report on. Defaults to <github-handle>.
#   --gitlab-group  GitLab group scope: comma-separated group full paths
#                   (subgroups included automatically), "all" (every
#                   top-level group you belong to), or "any" (no group
#                   filter). Omit this flag entirely to skip GitLab.
#   --no-full-scan  Never run the full-org branch scan, even for an
#                    annual-length window the recent-activity index can't
#                    verify. Trades completeness for speed.
#   --full-scan     Allow the full-org branch scan even for a short window
#                   (default: only annual-length windows, >= 300 days, are
#                   eligible — a routine monthly/quarterly report shouldn't
#                   pay that cost automatically).
#
# Requires: gh (authenticated), python3, and glab (authenticated) if
#           --gitlab-group is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/github-fy-report.template.html"
GITLAB_FETCH="$SCRIPT_DIR/github-fy-report-gitlab-fetch.py"

usage() {
  echo "Usage: $(basename "$0") <github-handle> <org-scope> [start-date] [end-date] [output-file]" >&2
  echo "                        [--gitlab-user USER] [--gitlab-group SCOPE]" >&2
  echo "  org-scope       comma-separated org list (e.g. nesi,GenomicsAotearoa)," >&2
  echo "                  'all' for every org you belong to, or" >&2
  echo "                  'any' for no org filter (includes personal repos)." >&2
  echo "  Dates are ISO (YYYY-MM-DD). Omit start/end to use the most recently" >&2
  echo "  completed Jul-Jun financial year." >&2
  echo "  --gitlab-group  comma-separated GitLab group list, 'all', or 'any'." >&2
  echo "                  Omit entirely to produce a GitHub-only report." >&2
  echo "  --gitlab-user   GitLab username, defaults to <github-handle>." >&2
  echo "  --no-full-scan  never run the full-org branch scan, even for an" >&2
  echo "                  annual-length window (see --full-scan)." >&2
  echo "  --full-scan     allow the full-org branch scan for a short window too" >&2
  echo "                  (default: only windows >= 300 days are eligible)." >&2
}

# --- arg parsing: pull the --gitlab-* flags out, leave positionals in place --
GITLAB_USER=""
GITLAB_GROUP=""
NO_FULL_SCAN=false
FORCE_FULL_SCAN=false
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --gitlab-user=*) GITLAB_USER="${1#*=}"; shift ;;
    --gitlab-user) GITLAB_USER="${2:-}"; shift 2 ;;
    --gitlab-group=*) GITLAB_GROUP="${1#*=}"; shift ;;
    --gitlab-group) GITLAB_GROUP="${2:-}"; shift 2 ;;
    --no-full-scan) NO_FULL_SCAN=true; shift ;;
    --full-scan) FORCE_FULL_SCAN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*) echo "Error: unknown flag '$1'" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

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

if [ "$NO_FULL_SCAN" = true ] && [ "$FORCE_FULL_SCAN" = true ]; then
  echo "Error: --no-full-scan and --full-scan contradict each other." >&2
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

# --- resolve GitHub org scope -----------------------------------------------
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

# --- resolve GitLab scope (only if requested) -------------------------------
GITLAB_ENABLED=false
GL_ANY=false
GL_GROUPS=()
GITLAB_UID=""

if [ -n "$GITLAB_GROUP" ]; then
  GITLAB_ENABLED=true
  GITLAB_USER="${GITLAB_USER:-$HANDLE}"

  if ! command -v glab >/dev/null 2>&1; then
    echo "Error: --gitlab-group given but the glab CLI was not found." >&2
    exit 1
  fi
  if ! glab auth status >/dev/null 2>&1; then
    echo "Error: glab is not authenticated. Run 'glab auth login' first." >&2
    exit 1
  fi

  echo "Resolving GitLab user '$GITLAB_USER'..." >&2
  GITLAB_UID="$(glab api "users?username=$(urlenc "$GITLAB_USER")" 2>/dev/null | python3 "$GITLAB_FETCH" user-id)"
  if [ -z "$GITLAB_UID" ]; then
    echo "Error: no GitLab user found for username '$GITLAB_USER'." >&2
    exit 1
  fi

  if [ "$GITLAB_GROUP" = "any" ]; then
    GL_ANY=true
    echo "GitLab scope: any (no group filter)" >&2
  elif [ "$GITLAB_GROUP" = "all" ]; then
    echo "Discovering top-level GitLab groups for $GITLAB_USER..." >&2
    while IFS= read -r g; do
      [ -n "$g" ] && GL_GROUPS+=("$g")
    done < <(glab api "groups?per_page=100" --paginate --output ndjson 2>/dev/null | python3 "$GITLAB_FETCH" top-level-groups)
    if [ ${#GL_GROUPS[@]} -eq 0 ]; then
      echo "Error: 'all' found no top-level GitLab group memberships." >&2
      exit 1
    fi
    echo "Found: ${GL_GROUPS[*]}" >&2
  else
    IFS=',' read -r -a RAW_GROUPS <<< "$GITLAB_GROUP"
    for g in "${RAW_GROUPS[@]}"; do
      g="$(echo "$g" | tr -d '[:space:]')"
      [ -n "$g" ] && GL_GROUPS+=("$g")
    done
    if [ ${#GL_GROUPS[@]} -eq 0 ]; then
      echo "Error: --gitlab-group '$GITLAB_GROUP' contained no usable group paths." >&2
      exit 1
    fi
  fi

  if [ "$GL_ANY" = false ]; then
    echo "Checking GitLab group access..." >&2
    GL_REACHABLE=()
    for g in "${GL_GROUPS[@]}"; do
      if glab api "groups/$(urlenc "$g")" >/dev/null 2>&1; then
        GL_REACHABLE+=("$g")
      else
        echo "  Skipping '$g': not accessible with this token (no such group, or no access)." >&2
      fi
    done
    if [ ${#GL_REACHABLE[@]} -eq 0 ]; then
      echo "Error: none of the requested GitLab groups are accessible with this token." >&2
      exit 1
    fi
    GL_GROUPS=("${GL_REACHABLE[@]}")
  fi
fi

GL_GROUP_LIST="$(IFS=,; echo "${GL_GROUPS[*]-}")"

# --- date range ---------------------------------------------------------------
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

# Full-org branch scanning is only worth its cost for an annual-length
# window (the recurring FY report) — a routine monthly/quarterly report
# shouldn't pay ~35x the API calls just because the recent-activity index
# can't formally prove 90+ day coverage. 300 days comfortably separates
# "basically a year" from "half a year or less"; --full-scan/--no-full-scan
# override this in either direction.
PERIOD_DAYS=$(python3 -c "
from datetime import date
print((date.fromisoformat('$END') - date.fromisoformat('$START')).days + 1)
")
FULL_SCAN_MIN_DAYS=300
if [ "$FORCE_FULL_SCAN" = true ]; then
  FULL_SCAN_ELIGIBLE=true
elif [ "$NO_FULL_SCAN" = true ]; then
  FULL_SCAN_ELIGIBLE=false
elif [ "$PERIOD_DAYS" -ge "$FULL_SCAN_MIN_DAYS" ]; then
  FULL_SCAN_ELIGIBLE=true
else
  FULL_SCAN_ELIGIBLE=false
fi

echo "Handle: $HANDLE" >&2
echo "Orgs:   ${ORG_LIST:-<none - searching all of GitHub>}" >&2
if [ "$GITLAB_ENABLED" = true ]; then
  if [ "$GL_ANY" = true ]; then
    echo "GitLab: $GITLAB_USER, all of GitLab" >&2
  else
    echo "GitLab: $GITLAB_USER, groups: $GL_GROUP_LIST" >&2
  fi
fi
echo "Period: $START .. $END" >&2

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- GitHub fetches -----------------------------------------------------------
echo "Fetching commits..." >&2
gh api --paginate "search/commits?q=$(urlenc "author:$HANDLE$ORG_Q committer-date:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: .repository.full_name, sha: .sha, date: .commit.committer.date}' \
  > "$WORKDIR/commits.jsonl"

echo "Fetching PRs opened..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:pr author:$HANDLE$ORG_Q created:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, url: .html_url, created_at: .created_at}' \
  > "$WORKDIR/prs.jsonl"

echo "Fetching reviews given..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:pr reviewed-by:$HANDLE -author:$HANDLE$ORG_Q updated:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, url: .html_url, updated_at: .updated_at}' \
  > "$WORKDIR/reviews.jsonl"

echo "Fetching issues opened..." >&2
gh api --paginate "search/issues?q=$(urlenc "is:issue author:$HANDLE$ORG_Q created:$START..$END")&per_page=100" \
  --jq '.items[] | {repo: (.repository_url | split("/")[-2:] | join("/")), number: .number, title: .title, state: .state, created_at: .created_at}' \
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

# --- fill the default-branch-only gap in commit search ------------------------
# search/commits only indexes each repo's default branch (confirmed against a
# live repo, not assumed from docs): a commit sitting on a still-open PR branch,
# a closed-but-unmerged branch, or squashed away at merge time is invisible to
# it. Two extra passes close that, for every repo this handle is already known
# to have touched (via the commits/PRs/reviews/issues already fetched above):
#   1. Every branch still on the repo, filtered by author + date server-side.
#   2. Every PR's own commit list, which GitHub keeps even after the PR's
#      branch is deleted (catches deleted branches that branch-listing can't).
# A commit with no PR ever opened on a branch that's since been deleted is the
# one case genuinely unrecoverable via the API — see README caveats.
CANDIDATE_REPOS_FILE="$WORKDIR/candidate_repos.txt"
python3 -c '
import json, sys
seen = set()
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    seen.add(json.loads(line)["repo"])
    except FileNotFoundError:
        pass
for r in sorted(seen):
    print(r)
' "$WORKDIR/commits.jsonl" "$WORKDIR/prs.jsonl" "$WORKDIR/reviews.jsonl" \
  "$WORKDIR/issues_opened.jsonl" "$WORKDIR/issues_closed.jsonl" \
  > "$CANDIDATE_REPOS_FILE"

# The above still can't discover a repo where this handle's *only* footprint
# is a live, no-PR-ever branch — closing that means knowing about the repo at
# all, which means either a short enough window that GitHub's own per-user
# recent-activity index (/users/:handle/events) is provably complete for it,
# or checking every repo in the org(s) outright. The index is capped at 90
# days OR 300 events, whichever comes first, so "provably complete" is
# checked against the actual data returned, not assumed from the date alone.
echo "Checking recent-activity index coverage..." >&2
gh api "users/$HANDLE/events?per_page=100" --paginate > "$WORKDIR/gh_events_raw.json" 2>/dev/null || echo "[]" > "$WORKDIR/gh_events_raw.json"
EVENTS_REPOS_FILE="$WORKDIR/events_repos.txt"
COVERAGE="$(python3 -c '
import json, sys, datetime

events_path, start_s, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
start = datetime.date.fromisoformat(start_s)
today = datetime.date.today()
retention_floor = today - datetime.timedelta(days=90)

try:
    with open(events_path) as f:
        events = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    events = []

repos = sorted({e["repo"]["name"] for e in events if e.get("repo", {}).get("name")})
with open(out_path, "w") as f:
    for r in repos:
        f.write(r + "\n")

if not events:
    covered = start >= retention_floor
else:
    oldest = min(
        datetime.datetime.fromisoformat(e["created_at"].replace("Z", "+00:00")).date()
        for e in events
    )
    truncated = len(events) >= 300
    covered = (oldest <= start) and not truncated

print("covered" if covered else "not_covered")
' "$WORKDIR/gh_events_raw.json" "$START" "$EVENTS_REPOS_FILE")"
cat "$EVENTS_REPOS_FILE" >> "$CANDIDATE_REPOS_FILE"

if [ "$COVERAGE" = "not_covered" ]; then
  if [ "$FULL_SCAN_ELIGIBLE" = false ]; then
    if [ "$NO_FULL_SCAN" = true ]; then
      echo "  Window exceeds what the recent-activity index can verify (90 days / 300 events), and --no-full-scan was given — skipping the full-org scan. A repo touched only via a still-live, no-PR-ever branch outside that window may be missed." >&2
    else
      echo "  Window exceeds what the recent-activity index can verify, but is only $PERIOD_DAYS day(s) — short of the $FULL_SCAN_MIN_DAYS-day annual-report threshold, so skipping the full-org scan automatically. Pass --full-scan to run it anyway. A repo touched only via a still-live, no-PR-ever branch outside the index window may be missed." >&2
    fi
  elif [ ${#ORGS[@]} -eq 0 ]; then
    echo "  Window exceeds what the recent-activity index can verify, and org-scope is 'any' — there's no concrete repo list to scan. A repo touched only via a still-live, no-PR-ever branch outside the index window may be missed." >&2
  else
    echo "  Window exceeds what the recent-activity index can verify — scanning every repo in ${ORGS[*]} for complete coverage. This can take a while." >&2
    for o in "${ORGS[@]}"; do
      gh api "orgs/$o/repos?per_page=100" --paginate --jq '.[].full_name' 2>/dev/null || true
    done >> "$CANDIDATE_REPOS_FILE"
  fi
fi
sort -u "$CANDIDATE_REPOS_FILE" -o "$CANDIDATE_REPOS_FILE"

REPO_COUNT=$(wc -l < "$CANDIDATE_REPOS_FILE" | tr -d ' ')
echo "Scanning all branches in $REPO_COUNT known repo(s) for additional commits..." >&2
: > "$WORKDIR/commits_all_branches.jsonl"
MAX_BRANCHES_PER_REPO=200
if [ "$REPO_COUNT" -gt 0 ]; then
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    BRANCHES=()
    while IFS= read -r b; do
      [ -n "$b" ] && BRANCHES+=("$b")
    done < <(gh api "repos/$repo/branches?per_page=100" --paginate --jq '.[].name' 2>/dev/null || true)
    TOTAL_BRANCHES=${#BRANCHES[@]}
    if [ "$TOTAL_BRANCHES" -gt "$MAX_BRANCHES_PER_REPO" ]; then
      echo "  $repo: $TOTAL_BRANCHES branches, capping at $MAX_BRANCHES_PER_REPO (skipping $((TOTAL_BRANCHES - MAX_BRANCHES_PER_REPO)))." >&2
      BRANCHES=("${BRANCHES[@]:0:$MAX_BRANCHES_PER_REPO}")
    fi
    for b in ${BRANCHES[@]+"${BRANCHES[@]}"}; do
      gh api --paginate "repos/$repo/commits?sha=$(urlenc "$b")&author=$(urlenc "$HANDLE")&since=${START}T00:00:00Z&until=${END}T23:59:59Z&per_page=100" \
        --jq '.[] | {repo: "'"$repo"'", sha: .sha, date: .commit.committer.date}' 2>/dev/null \
        >> "$WORKDIR/commits_all_branches.jsonl" || true
    done
  done < "$CANDIDATE_REPOS_FILE"
fi

echo "Fetching commits from PR branches (covers deleted or squash-merged branches)..." >&2
if [ "$PR_COUNT" -gt 0 ]; then
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        p = json.loads(line)
        print(p["repo"], p["number"])
' "$WORKDIR/prs.jsonl" | while read -r repo number; do
    timeout 10 gh api --paginate "repos/$repo/pulls/$number/commits" \
      --jq '.[] | {repo: "'"$repo"'", sha: .sha, date: .commit.committer.date}' 2>/dev/null \
      >> "$WORKDIR/commits_all_branches.jsonl" || true
  done
fi

echo "Merging and deduplicating discovered commits..." >&2
python3 -c '
import json, sys
seen = set()
out = []
for path in sys.argv[1:-1]:
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                c = json.loads(line)
                key = (c["repo"], c["sha"])
                if key not in seen:
                    seen.add(key)
                    out.append({"repo": c["repo"], "date": c["date"]})
    except FileNotFoundError:
        pass
with open(sys.argv[-1], "w") as f:
    for c in out:
        f.write(json.dumps(c) + "\n")
' "$WORKDIR/commits.jsonl" "$WORKDIR/commits_all_branches.jsonl" "$WORKDIR/commits_merged.jsonl"
mv "$WORKDIR/commits_merged.jsonl" "$WORKDIR/commits.jsonl"

# --- GitLab fetches (only if requested) ---------------------------------------
: > "$WORKDIR/gitlab_pushes_raw.jsonl"
: > "$WORKDIR/gitlab_project_paths.jsonl"
: > "$WORKDIR/gitlab_mrs_raw.jsonl"
: > "$WORKDIR/gitlab_reviews_raw.jsonl"
: > "$WORKDIR/gitlab_issues_opened_raw.jsonl"
: > "$WORKDIR/gitlab_issues_closed_raw.jsonl"
: > "$WORKDIR/gitlab_mr_stats.jsonl"

if [ "$GITLAB_ENABLED" = true ]; then
  if [ "$GL_ANY" = false ]; then
    echo "Resolving GitLab project scope..." >&2
    : > "$WORKDIR/gitlab_allowed_ids.txt"
    for g in "${GL_GROUPS[@]}"; do
      glab api "groups/$(urlenc "$g")/projects?include_subgroups=true&simple=true&per_page=100" \
          --paginate --output ndjson 2>/dev/null \
        | python3 "$GITLAB_FETCH" project-ids >> "$WORKDIR/gitlab_allowed_ids.txt" || true
    done
  fi

  echo "Fetching GitLab push events..." >&2
  glab api "users/$GITLAB_UID/events?after=$START&before=$END&per_page=100" --paginate --output ndjson 2>/dev/null \
    | python3 "$GITLAB_FETCH" pushes > "$WORKDIR/gitlab_pushes_raw.jsonl" || true

  echo "Resolving GitLab project paths for push events..." >&2
  if [ -s "$WORKDIR/gitlab_pushes_raw.jsonl" ]; then
    python3 -c '
import json, sys
seen = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        seen.add(json.loads(line)["project_id"])
for pid in sorted(seen):
    print(pid)
' "$WORKDIR/gitlab_pushes_raw.jsonl" | while read -r pid; do
      timeout 10 glab api "projects/$pid" 2>/dev/null \
        | python3 "$GITLAB_FETCH" project-path \
        | python3 -c 'import json, sys; path = sys.stdin.read().strip(); path and print(json.dumps({"project_id": int(sys.argv[1]), "path": path}))' "$pid" \
        >> "$WORKDIR/gitlab_project_paths.jsonl" || true
    done
  fi

  if [ "$GL_ANY" = true ]; then
    BASES=("")
  else
    BASES=()
    for g in "${GL_GROUPS[@]}"; do BASES+=("groups/$(urlenc "$g")/"); done
  fi

  echo "Fetching GitLab MRs opened..." >&2
  for base in "${BASES[@]}"; do
    glab api "${base}merge_requests?author_username=$(urlenc "$GITLAB_USER")&scope=all&state=all&created_after=$START&created_before=$END&per_page=100" \
        --paginate --output ndjson 2>/dev/null \
      | python3 "$GITLAB_FETCH" mr >> "$WORKDIR/gitlab_mrs_raw.jsonl" || true
  done

  echo "Fetching GitLab reviews given..." >&2
  for base in "${BASES[@]}"; do
    glab api "${base}merge_requests?reviewer_username=$(urlenc "$GITLAB_USER")&scope=all&state=all&updated_after=$START&updated_before=$END&per_page=100" \
        --paginate --output ndjson 2>/dev/null \
      | python3 "$GITLAB_FETCH" mr >> "$WORKDIR/gitlab_reviews_raw.jsonl" || true
  done

  echo "Fetching GitLab issues opened..." >&2
  for base in "${BASES[@]}"; do
    glab api "${base}issues?author_username=$(urlenc "$GITLAB_USER")&created_after=$START&created_before=$END&per_page=100" \
        --paginate --output ndjson 2>/dev/null \
      | python3 "$GITLAB_FETCH" issue >> "$WORKDIR/gitlab_issues_opened_raw.jsonl" || true
  done

  echo "Fetching GitLab issues closed..." >&2
  for base in "${BASES[@]}"; do
    glab api "${base}issues?author_username=$(urlenc "$GITLAB_USER")&state=closed&updated_after=$START&updated_before=$END&per_page=100" \
        --paginate --output ndjson 2>/dev/null \
      | python3 "$GITLAB_FETCH" issue >> "$WORKDIR/gitlab_issues_closed_raw.jsonl" || true
    glab api "${base}issues?assignee_username=$(urlenc "$GITLAB_USER")&state=closed&updated_after=$START&updated_before=$END&per_page=100" \
        --paginate --output ndjson 2>/dev/null \
      | python3 "$GITLAB_FETCH" issue >> "$WORKDIR/gitlab_issues_closed_raw.jsonl" || true
  done

  MR_COUNT=$(wc -l < "$WORKDIR/gitlab_mrs_raw.jsonl" | tr -d ' ')
  echo "Fetching line-change stats for $MR_COUNT GitLab MR(s)..." >&2
  if [ "$MR_COUNT" -gt 0 ]; then
    python3 -c '
import json, sys
seen = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    m = json.loads(line)
    if m.get("merged_at"):
        seen.add((m["project_id"], m["iid"]))
for pid, iid in sorted(seen):
    print(pid, iid)
' "$WORKDIR/gitlab_mrs_raw.jsonl" | while read -r pid iid; do
      timeout 10 glab api "projects/$pid/merge_requests/$iid/changes" 2>/dev/null \
        | python3 "$GITLAB_FETCH" diffstat "$pid" "$iid" \
        >> "$WORKDIR/gitlab_mr_stats.jsonl" || true
    done
  fi
fi

echo "Aggregating and rendering report..." >&2
python3 "$SCRIPT_DIR/github-fy-report-render.py" \
  "$WORKDIR" "$TEMPLATE" "$OUTPUT" "$HANDLE" "$ORG_LIST" "$START" "$END" \
  "$GITLAB_ENABLED" "$GITLAB_USER" "$GL_GROUP_LIST" "$GL_ANY"

echo "Report written to: $OUTPUT" >&2
