# github-fy-report

Generates a self-contained HTML report of one person's activity across one or
more GitHub orgs — and, optionally, GitLab groups — over a date range: commits
over time (bucketed by day, week, or month, whichever fits the period), commits
per repo, merged PRs/MRs with line counts, reviews given, and issues opened/closed.

## Requirements

- [`gh`](https://cli.github.com/) — authenticated (`gh auth login`)
- `python3` — stdlib only, no pip installs
- [`glab`](https://gitlab.com/gitlab-org/cli) — authenticated (`glab auth login`) —
  **only** if you pass `--gitlab-group`

No `jq` needed. JSON filtering uses `gh --jq` (built into the `gh` binary) on the
GitHub side; `glab api` has no `--jq` equivalent, so the GitLab side pipes through
`github-fy-report-gitlab-fetch.py` instead. Everything else is plain Python.

## Usage

```
./github-fy-report.sh <github-handle> <org-scope> [start-date] [end-date] [output-file]
                       [--gitlab-user USER] [--gitlab-group SCOPE]
                       [--full-scan | --no-full-scan]
```

The five GitHub arguments are **positional** — to set a later one you must supply
all earlier ones. The flags are optional and can go anywhere on the command line;
omit `--gitlab-group` entirely for a GitHub-only report (the original, unchanged
behaviour).

| Arg | Required | Default |
|-----|----------|---------|
| `github-handle` | yes | — |
| `org-scope` | yes | — |
| `start-date` | no | 1 Jul of the most recently completed Jul–Jun financial year |
| `end-date` | no | 30 Jun of that same FY |
| `output-file` | no | `./github-report-<handle>-<start>_<end>.html` |
| `--gitlab-user` | no | same as `github-handle` |
| `--gitlab-group` | no | GitLab is skipped entirely if omitted |
| `--full-scan` | no | forces the full-org branch scan even for a window under 300 days |
| `--no-full-scan` | no | forces the full-org branch scan off even for an annual-length window |

Neither flag is needed for the common cases: a routine monthly or quarterly
report never pays for the full-org scan, and the once-a-year FY report gets it
automatically. They exist for the exceptions — forcing it on to double-check a
short window, or off to keep a slow org fast when you don't need that level of
completeness this time.

Dates are ISO `YYYY-MM-DD`. The date range is inclusive.

### Org scope

`org-scope` takes three forms:

| Value | Meaning |
|-------|---------|
| `nesi` | one org |
| `nesi,GenomicsAotearoa` | several orgs, OR'd into one merged report |
| `all` | every org the **authenticated** user belongs to, discovered automatically |
| `any` | no org filter at all — includes personal repos |

With a single org the repo list drops the org prefix (`training-environment`).
With several orgs, or `any`, it keeps the full name (`nesi/training-environment`)
so same-named repos stay distinguishable.

Before searching, each org is probed and any the token cannot reach is reported
and skipped, rather than failing the whole run:

```
Checking org access...
  Skipping 'AgResearch': not searchable with this token (SAML SSO not authorised, or no such org).
```

For a SAML-protected org, authorise your token at
<https://github.com/settings/tokens> and re-run.

### GitLab scope

Pass `--gitlab-group` to add GitLab data alongside GitHub. `--gitlab-group` takes
the same three forms as `org-scope`, but for GitLab **groups** (GitLab's rough
equivalent of a GitHub org):

| Value | Meaning |
|-------|---------|
| `nesi1` | one group — subgroups are included automatically |
| `nesi1,other-group` | several groups, queried independently and merged |
| `all` | every **top-level** group you belong to, discovered automatically (subgroups of those are covered for free, so they're not queried again separately) |
| `any` | no group filter at all — every project the token can see |

`--gitlab-user` defaults to `github-handle` — set it explicitly if your GitLab
username differs from your GitHub one.

Like GitHub orgs, each requested group is probed and skipped with a warning if
the token can't reach it:

```
Checking GitLab group access...
  Skipping 'some-group': not accessible with this token (no such group, or no access).
```

When GitLab is included, the report becomes platform-unified rather than two
separate reports stitched together: one "Commits" stat, one monthly chart (GitHub
and GitLab stacked as two colours, with a legend), one ranked repo list (GitLab
rows tagged `[GitLab]`), and one merged PRs/MRs table with a Platform column.
GitLab issues/MRs use `!`/`#` the way GitLab itself does, not GitHub's `#` for
everything.

### Examples

Last completed financial year, default output filename:

```bash
./github-fy-report.sh USER_NAME nesi
```

Explicit FY 2025/26:

```bash
./github-fy-report.sh USER_NAME nesi 2025-07-01 2026-06-30
```

Calendar year instead of financial year:

```bash
./github-fy-report.sh USER_NAME nesi 2025-01-01 2025-12-31
```

Single quarter, custom output path:

```bash
./github-fy-report.sh USER_NAME nesi 2026-01-01 2026-03-31 ~/reports/q3-fy26.html
```

Someone else on your team:

```bash
./github-fy-report.sh OTHER_USER_NAME nesi 2025-07-01 2026-06-30 ./other-fy26.html
```

Different org:

```bash
./github-fy-report.sh USER_NAME kubernetes 2025-07-01 2026-06-30
```

Several orgs in one merged report:

```bash
./github-fy-report.sh USER_NAME nesi,GenomicsAotearoa
```

Every org you belong to, auto-discovered:

```bash
./github-fy-report.sh USER_NAME all
```

Everything, personal repos included:

```bash
./github-fy-report.sh USER_NAME any
```

Batch a whole team into one directory:

```bash
mkdir -p reports
for user in USER_NAME_1 USER_NAME_2 USER_NAME_3; do
  ./github-fy-report.sh "$user" nesi 2025-07-01 2026-06-30 "reports/$user-fy26.html"
done
```

Roll five financial years for one person:

```bash
for y in 2021 2022 2023 2024 2025; do
  ./github-fy-report.sh USER_NAME nesi "$y-07-01" "$((y+1))-06-30" "fy$((y+1)).html"
done
```

GitHub + GitLab combined, one group:

```bash
./github-fy-report.sh USER_NAME nesi 2025-07-01 2026-06-30 --gitlab-group nesi1
```

GitHub + GitLab, different username on GitLab, several groups:

```bash
./github-fy-report.sh USER_NAME nesi --gitlab-user gitlab-handle --gitlab-group nesi1,other-group
```

GitHub + every GitLab group you belong to:

```bash
./github-fy-report.sh USER_NAME nesi --gitlab-group all
```

Run from anywhere — the script locates its own template:

```bash
~/Code/github-fy-report/github-fy-report.sh USER_NAME nesi
```

Open the result:

```bash
xdg-open ./github-report-USER_NAME-2025-07-01_2026-06-30.html   # Linux
open ...                                                          # macOS
explorer.exe ...                                                  # WSL
```

## Output

One standalone HTML file. No external assets, no network calls when viewed —
safe to email to a **pencil pusher** or attach to a performance review.

Sections:

- **Stat row** — commits, PRs/MRs opened, PRs/MRs merged, lines changed (+/−), reviews given, issues closed, active days
- **Commits by day/week/month** — bar chart across the range, bucketed to fit the
  period (stacked GitHub/GitLab when GitLab is included) — see below
- **Commits by repository** — ranked, org prefix stripped (GitLab rows tagged `[GitLab]` when included)
- **Active days** — distinct days each kind of activity happened on
- **Merged PRs/MRs** — title, repo, link, additions/deletions, platform (when GitLab is included)
- **Reviews given** — PRs/MRs you reviewed that you did not author
- **Issues** — opened and closed

### Commits chart granularity

"Commits by month" is only a useful chart over several months — a monthly or
weekly report would show one or two bars and call it a day. The chart's bucket
size adapts to the requested period instead:

| Period length | Bucket | Label example |
|---|---|---|
| ≤ 14 days | day | `Mon 17` |
| 15–60 days | week (7-day chunks from the start date, not calendar-aligned) | `03 Aug` (week starting) |
| \> 60 days | month (unchanged from before) | `Aug 26` |

The card title and table column header follow the chosen bucket ("Commits by
day" / "by week" / "by month"). There's no flag for this — it's purely a
function of `start-date`/`end-date`.

### Active days

Counts distinct UTC calendar days on which something happened, per category, plus
a headline total that counts each day **once** even if several things happened on it:

```
Active days: 48 out of 365 days in the period (13%)

  Commits        37
  Issues opened  13
  Issues closed  11
  PRs opened      7
  PRs merged      6
  Reviews given   2
```

The total sits between the largest single category and the sum of all of them —
here 37 ≤ 48 ≤ 76.

When GitLab is included, `Commits`, `PRs opened`, and `PRs merged` fold in GitLab
activity too (relabelled `PRs/MRs opened` / `PRs/MRs merged`) rather than getting
their own separate rows — a day with a GitHub commit and a GitLab commit still
counts once for `Commits`.

## Progress output

Everything the script prints goes to stderr, so you can watch it and still redirect
the report path cleanly. The PR line-count and branch-scanning stages are the slow
ones — roughly one API call per PR, and one per live branch per known repo.

```
Checking org access...
Handle: USER_NAME
Orgs:   nesi
Period: 2025-07-01 .. 2026-06-30
Fetching commits...
Fetching PRs opened...
Fetching reviews given...
Fetching issues opened...
Fetching issues closed...
Fetching line-change stats for 42 PR(s)...
Checking recent-activity index coverage...
  Window exceeds what the recent-activity index can verify — scanning every repo in nesi for complete coverage. This can take a while.
Scanning all branches in 284 known repo(s) for additional commits...
Fetching commits from PR branches (covers deleted or squash-merged branches)...
Merging and deduplicating discovered commits...
Aggregating and rendering report...
Report written to: ./github-report-USER_NAME-2025-07-01_2026-06-30.html
```

The scan only runs at all when the window is annual-length (>= 300 days,
overridable with `--full-scan`/`--no-full-scan`) *and* the index can't prove
coverage on its own — a routine monthly or quarterly report stays fast
either way, and the "Checking recent-activity index coverage..." line just
won't be followed by a "scanning every repo" line for those.

With `--gitlab-group`, a second block of GitLab-side steps runs after the GitHub
fetches, and its own line-change stage at the end:

```
Resolving GitLab user 'USER_NAME'...
Checking GitLab group access...
Resolving GitLab project scope...
Fetching GitLab push events...
Resolving GitLab project paths for push events...
Fetching GitLab MRs opened...
Fetching GitLab reviews given...
Fetching GitLab issues opened...
Fetching GitLab issues closed...
Fetching line-change stats for 5 GitLab MR(s)...
```

## Caveats

- **`all` only works for yourself.** It reads `gh api user/orgs`, which covers the
  authenticated account's private memberships. `gh api users/<someone>/orgs` returns
  only *publicly listed* memberships — often empty — so for a colleague you must
  name their orgs explicitly.
- **SAML-protected orgs need an authorised token**, otherwise they are skipped and
  their activity is silently absent from the totals. Watch the "Checking org access"
  lines.
- **`any` includes personal repos**, which usually inflates the numbers well past
  what a work report should claim.
- **Private repos** only appear if your `gh` token can see them.
- **Commits are found several ways, merged and deduped by SHA**, because
  GitHub's commit search only indexes each repo's *default branch* (confirmed
  against a live repo — a commit sitting only on an open, closed-unmerged, or
  squash-merged-away branch is invisible to it, otherwise):
  1. `search/commits` on the default branch.
  2. Every live branch of every repo the report already knows this handle
     touched (via commits/PRs/reviews/issues), filtered server-side by author
     and date.
  3. Every PR's own commit list, which GitHub keeps even after its branch is
     deleted.
  4. `/users/<handle>/events`, capped at 90 days or 300 events (whichever
     comes first) — used both as a bonus discovery signal and, if it
     *provably* covers the whole requested window (the oldest event returned
     is on or before the start date, and the 300-event cap wasn't hit), as
     proof that steps 1–3 already found every repo worth scanning.
  5. If step 4 can't prove full coverage, **and the requested window is at
     least 300 days** (an FY report, not a routine monthly/quarterly one —
     see `--full-scan`/`--no-full-scan` above), every repo in the org(s) in
     scope gets scanned too — otherwise a repo touched *only* via a
     still-live branch with no PR ever opened, more than ~90 days ago, would
     never be discovered at all. This is the slow step: expect an eligible
     window to add many minutes for an org with hundreds of repos, and it
     isn't possible at all with `any` org-scope (there's no concrete repo
     list to enumerate) regardless of window length.

  This is already noticeably slower than the other fetches even without step
  5 — expect it to add a minute or more for someone with lots of history —
  and it can raise the commit count substantially versus counting the default
  branch alone, especially in a repo that squash-merges small PRs (each PR's
  individual commits are counted once via its PR commit list, even though
  only one squashed commit ever lands on the default branch).
  - A repo with more than 200 live branches has the rest skipped, logged as
    `capping at 200 (skipping N)` — this is a soft cap, not silent truncation.
  - **The one case still unrecoverable, even with the full-org scan:** a
    commit on a branch that never had a PR opened and has since been deleted.
    Nothing in the API retains a trace of it once that happens.
  - Dates are still *committer date*, not author date — rebases and
    cherry-picks land in the month they were replayed.
- **Reviews** are found with `updated:` on the PR, not the date of the review
  itself. A PR reviewed in June but touched again in August can fall outside
  or inside the window unexpectedly.
- **Lines changed** counts merged PRs only. Direct-to-main commits contribute
  to the commit count but not the +/− totals.
- **PR stat fetches time out after 10s each** and failures are skipped silently,
  so a flaky network quietly undercounts lines changed.
- **Search API caps at 1000 results per query.** A very busy year in a very
  busy org will truncate. Because multiple orgs are merged into one query rather
  than queried separately, adding orgs brings you closer to that cap.
- **Active days use UTC**, not your local timezone. Late-evening NZ work lands on
  the next UTC day, so a stretch of consecutive evenings can read as more days
  than it felt like.
- **Active days are a floor, not a full picture.** They cover only what the report
  already fetches — commits, PRs opened/merged, reviews, issues. Days spent purely
  on GitHub Actions runs, comments, discussions, or releases do not register.
- **"Reviews given" days** inherit the `updated:` caveat above: the day is the PR's
  last-updated day, not the day the review was actually written.
- **Rate limits**: search is 30 req/min authenticated. Large batches may pause
  or fail — space them out.

### GitLab-specific caveats

GitLab's API shape is different enough from GitHub's search API that the GitLab
side works, but with some real gaps worth knowing about:

- **Commits come from the Events API, not a commit search.** GitLab has no
  cross-project "search commits by author + date" endpoint. Each push event
  carries a *commit count* for that push (`push_data.commit_count`), attributed
  to the push's timestamp — not the commit's own date. A force-push or a
  multi-commit push lands as one bucketed count on one day, not several. This
  is the same *kind* of imprecision as GitHub's committer-date caveat above, just
  coarser.
- **`--gitlab-group` scoping only restricts commits/pushes; MRs and issues are
  restricted at the API level** by querying `groups/:id/merge_requests` and
  `groups/:id/issues` directly (which already cover subgroups), so those are
  exact. Push events have no group-scoped endpoint, so they're fetched
  unfiltered per-user and then filtered locally against the group's project
  list — an extra resolution step, not a precision loss.
- **GitLab issue "closed" search ignores `closed_after`/`closed_before`.**
  Those query parameters are silently no-ops server-side (confirmed against a
  live instance, not assumed from docs). The fetch is bounded by
  `updated_after`/`updated_before` instead — a reasonable proxy, since an
  issue's `updated_at` matches its `closed_at` unless it was touched again
  later — and the renderer re-checks the exact `closed_at` date client-side.
  An issue closed in-window but edited again after the window could still be
  missed if that later edit falls outside the `updated_after`/`before` bound
  used for the fetch.
- **"Issues closed" covers authored-by-you or assigned-to-you issues**, queried
  separately and merged — GitLab's issues API has no single filter equivalent
  to GitHub's `involves:` (which also catches issues you only commented on).
- **Lines changed for GitLab MRs come from counting diff lines**, not a
  ready-made stat. GitLab's merge request list/show endpoints don't return
  additions/deletions the way GitHub's PR object does, so each merged MR gets
  an extra `/merge_requests/:iid/changes` call, and `+`/`-` lines in the
  returned unified diff are counted directly. Binary file changes contribute
  nothing (no text lines to count).
- **A GitLab group query call is needed per group**, unlike GitHub's `org:a
  org:b` OR'd into one search. `all` collapses to top-level groups specifically
  to keep this from multiplying — a group and all its subgroups cost one call
  each fetch type, not one per subgroup.
- **`reviewer_username` reflects GitLab's "reviewer" assignment feature**, not
  free-text review comments. If your team doesn't use formal MR reviewer
  assignment, "reviews given" on the GitLab side will under-count relative to
  what actually happened in the MR discussion.

## Files

| File | Purpose |
|------|---------|
| `github-fy-report.sh` | Entry point — arg parsing, FY defaults, `gh` and `glab` queries |
| `github-fy-report-gitlab-fetch.py` | JSON glue for the GitLab side (`glab api` has no `--jq`) |
| `github-fy-report-render.py` | Merges GitHub + GitLab data and fills in the template |
| `github-fy-report.template.html` | Self-contained HTML/CSS/JS with `__PLACEHOLDER__` tokens |

The two Python scripts are invoked by the shell script and expect a scratch
workdir — not meant to be run standalone.
