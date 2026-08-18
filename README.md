# github-fy-report

Generates a self-contained HTML report of one person's activity across one or
more GitHub orgs — and, optionally, GitLab groups — over a date range: commits
per month, commits per repo, merged PRs/MRs with line counts, reviews given,
and issues opened/closed.

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
```

The five GitHub arguments are **positional** — to set a later one you must supply
all earlier ones. The two `--gitlab-*` flags are optional and can go anywhere on
the command line; omit `--gitlab-group` entirely for a GitHub-only report (the
original, unchanged behaviour).

| Arg | Required | Default |
|-----|----------|---------|
| `github-handle` | yes | — |
| `org-scope` | yes | — |
| `start-date` | no | 1 Jul of the most recently completed Jul–Jun financial year |
| `end-date` | no | 30 Jun of that same FY |
| `output-file` | no | `./github-report-<handle>-<start>_<end>.html` |
| `--gitlab-user` | no | same as `github-handle` |
| `--gitlab-group` | no | GitLab is skipped entirely if omitted |

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
- **Commits by month** — bar chart across the range (stacked GitHub/GitLab when GitLab is included)
- **Commits by repository** — ranked, org prefix stripped (GitLab rows tagged `[GitLab]` when included)
- **Active days** — distinct days each kind of activity happened on
- **Merged PRs/MRs** — title, repo, link, additions/deletions, platform (when GitLab is included)
- **Reviews given** — PRs/MRs you reviewed that you did not author
- **Issues** — opened and closed

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
the report path cleanly. The PR line-count stage is the slow one — one API call per PR.

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
Aggregating and rendering report...
Report written to: ./github-report-USER_NAME-2025-07-01_2026-06-30.html
```

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
- **Commits** are matched on *committer date*, not author date — rebases and
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
