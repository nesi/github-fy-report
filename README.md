# github-fy-report

I got bored and got Claude to create this thing, mainly because doing it myself did not give me joy.
So if you need to provide metrics for pencil pushers, here ya go.

Generates a self-contained HTML report of one GitHub user's activity across one or
more orgs over a date range: commits per month, commits per repo, merged PRs with
line counts, reviews given, and issues opened/closed.

## Requirements

- [`gh`](https://cli.github.com/) — authenticated (`gh auth login`)
- `python3` — stdlib only, no pip installs

No `jq` needed. JSON filtering uses `gh --jq` (built into the `gh` binary);
everything else is plain Python.

## Usage

```
./github-fy-report.sh <github-handle> <org-scope> [start-date] [end-date] [output-file]
```

Arguments are **positional** — to set a later one you must supply all earlier ones.

| Arg | Required | Default |
|-----|----------|---------|
| `github-handle` | yes | — |
| `org-scope` | yes | — |
| `start-date` | no | 1 Jul of the most recently completed Jul–Jun financial year |
| `end-date` | no | 30 Jun of that same FY |
| `output-file` | no | `./github-report-<handle>-<start>_<end>.html` |

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

- **Stat row** — commits, PRs opened, PRs merged, lines changed (+/−), reviews given, issues closed
- **Commits by month** — bar chart across the range
- **Commits by repository** — ranked, org prefix stripped
- **Merged PRs** — title, repo, link, additions/deletions
- **Reviews given** — PRs you reviewed that you did not author
- **Issues** — opened and closed

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
- **Rate limits**: search is 30 req/min authenticated. Large batches may pause
  or fail — space them out.

## Files

| File | Purpose |
|------|---------|
| `github-fy-report.sh` | Entry point — arg parsing, FY defaults, `gh` queries |
| `github-fy-report-render.py` | Aggregates the fetched JSONL into the template |
| `github-fy-report.template.html` | Self-contained HTML/CSS/JS with `__PLACEHOLDER__` tokens |

The Python renderer is invoked by the shell script and expects a scratch workdir —
not meant to be run standalone.
