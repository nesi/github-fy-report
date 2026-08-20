#!/usr/bin/env python3
"""Aggregate GitHub (+ optional GitLab) activity data fetched by
github-fy-report.sh into the HTML template.

Invoked by github-fy-report.sh — not meant to be run standalone.
"""
import calendar
import json
import sys
from datetime import date, datetime, timedelta


def load_jsonl(path):
    items = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    items.append(json.loads(line))
    except FileNotFoundError:
        pass
    return items


def load_ids(path):
    ids = set()
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    ids.add(int(line))
    except FileNotFoundError:
        pass
    return ids


def day_of(ts):
    """UTC calendar day from an ISO timestamp, or None if absent/unparseable."""
    if not ts:
        return None
    return ts[:10] if len(ts) >= 10 else None


def choose_granularity(period_days):
    """"Commits by month" is only a useful chart when the period spans
    several months; a monthly or weekly report needs finer buckets to show
    any shape at all."""
    if period_days <= 14:
        return "day"
    if period_days <= 60:
        return "week"
    return "month"


def build_buckets(start, end, granularity):
    """Contiguous, labelled date-range buckets spanning [start, end]."""
    buckets = []
    if granularity == "month":
        y, m = start.year, start.month
        while (y, m) <= (end.year, end.month):
            b_start = date(y, m, 1)
            b_end = date(y, m, calendar.monthrange(y, m)[1])
            buckets.append({"label": b_start.strftime("%b %y"), "start": b_start, "end": b_end})
            m += 1
            if m == 13:
                m = 1
                y += 1
    elif granularity == "week":
        cur = start
        while cur <= end:
            b_end = min(cur + timedelta(days=6), end)
            buckets.append({"label": cur.strftime("%d %b"), "start": cur, "end": b_end})
            cur += timedelta(days=7)
    else:
        cur = start
        while cur <= end:
            buckets.append({"label": cur.strftime("%a %d"), "start": cur, "end": cur})
            cur += timedelta(days=1)
    return buckets


def date_to_bucket_index(buckets):
    index = {}
    for i, b in enumerate(buckets):
        d = b["start"]
        while d <= b["end"]:
            index[d] = i
            d += timedelta(days=1)
    return index


def repo_path_from_web_url(url):
    """'https://gitlab.com/group/sub/project/-/merge_requests/3' -> 'group/sub/project'."""
    without_scheme = url.split("://", 1)[-1]
    without_host = without_scheme.split("/", 1)[-1]
    return without_host.split("/-/", 1)[0]


def dedupe(rows, key):
    seen = set()
    out = []
    for r in rows:
        k = key(r)
        if k not in seen:
            seen.add(k)
            out.append(r)
    return out


def main():
    (workdir, template_path, output_path, handle, org_list, start_s, end_s,
     gitlab_enabled_s, gitlab_user, gl_group_list, gl_any_s) = sys.argv[1:12]

    start = date.fromisoformat(start_s)
    end = date.fromisoformat(end_s)
    gitlab_enabled = gitlab_enabled_s == "true"
    gl_any = gl_any_s == "true"

    orgs = [o for o in org_list.split(",") if o]
    gl_groups = [g for g in gl_group_list.split(",") if g]

    # --- load GitHub data -----------------------------------------------------
    commits = load_jsonl(f"{workdir}/commits.jsonl")
    prs = load_jsonl(f"{workdir}/prs.jsonl")
    reviews = load_jsonl(f"{workdir}/reviews.jsonl")
    issues_opened = load_jsonl(f"{workdir}/issues_opened.jsonl")
    issues_closed = load_jsonl(f"{workdir}/issues_closed.jsonl")
    pr_stats = load_jsonl(f"{workdir}/pr_stats.jsonl")

    single_org_prefix = f"{orgs[0]}/" if len(orgs) == 1 else None

    def strip_org(repo):
        if single_org_prefix and repo.startswith(single_org_prefix):
            return repo[len(single_org_prefix):]
        return repo

    # unified commit-like rows: {platform, repo, date, count}
    commit_rows = [
        {"platform": "github", "repo": strip_org(c["repo"]), "date": c["date"], "count": 1}
        for c in commits
    ]

    # join GitHub PR metadata with stats, keep merged only
    stats_by_key = {(s["repo"], s["number"]): s for s in pr_stats}
    merged_items = []
    for p in prs:
        key = (p["repo"], p["number"])
        s = stats_by_key.get(key)
        if s and s.get("merged_at"):
            merged_items.append({
                "platform": "github",
                "repo": strip_org(p["repo"]),
                "number": p["number"],
                "ref_prefix": "#",
                "title": p["title"],
                "url": p["url"],
                "merged_at": s["merged_at"],
                "additions": s.get("additions", 0),
                "deletions": s.get("deletions", 0),
            })

    review_items = [
        {"platform": "github", "repo": strip_org(r["repo"]), "number": r["number"],
         "ref_prefix": "#", "title": r["title"], "url": r["url"],
         "updated_at": r.get("updated_at")}
        for r in reviews
    ]
    issues_opened_items = [
        {"platform": "github", "repo": strip_org(i.get("repo", "")), "number": i["number"],
         "ref_prefix": "#", "title": i["title"], "state": i["state"],
         "created_at": i.get("created_at")}
        for i in issues_opened
    ]
    issues_closed_items = [
        {"platform": "github", "repo": strip_org(i.get("repo", "")), "number": i["number"],
         "ref_prefix": "#", "title": i["title"], "closed_at": i.get("closed_at")}
        for i in issues_closed
    ]

    # --- load + fold in GitLab data --------------------------------------------
    if gitlab_enabled:
        allowed_ids = load_ids(f"{workdir}/gitlab_allowed_ids.txt")
        project_paths = {
            p["project_id"]: p["path"] for p in load_jsonl(f"{workdir}/gitlab_project_paths.jsonl")
        }
        pushes = load_jsonl(f"{workdir}/gitlab_pushes_raw.jsonl")
        if not gl_any:
            pushes = [p for p in pushes if p["project_id"] in allowed_ids]
        for p in pushes:
            repo = project_paths.get(p["project_id"], f"project {p['project_id']}")
            commit_rows.append({
                "platform": "gitlab", "repo": repo, "date": p["date"], "count": p["count"],
            })

        gl_mrs = dedupe(load_jsonl(f"{workdir}/gitlab_mrs_raw.jsonl"),
                        key=lambda m: (m["project_id"], m["iid"]))
        gl_reviews = dedupe(load_jsonl(f"{workdir}/gitlab_reviews_raw.jsonl"),
                            key=lambda m: (m["project_id"], m["iid"]))
        gl_issues_opened = dedupe(load_jsonl(f"{workdir}/gitlab_issues_opened_raw.jsonl"),
                                  key=lambda i: (i["project_id"], i["iid"]))
        gl_issues_closed = dedupe(load_jsonl(f"{workdir}/gitlab_issues_closed_raw.jsonl"),
                                  key=lambda i: (i["project_id"], i["iid"]))
        gl_mr_stats = {
            (s["project_id"], s["iid"]): s for s in load_jsonl(f"{workdir}/gitlab_mr_stats.jsonl")
        }

        gl_reviews = [m for m in gl_reviews if m.get("author") != gitlab_user]

        for m in gl_mrs:
            if not m.get("merged_at"):
                continue
            s = gl_mr_stats.get((m["project_id"], m["iid"]), {})
            merged_items.append({
                "platform": "gitlab",
                "repo": repo_path_from_web_url(m["web_url"]),
                "number": m["iid"],
                "ref_prefix": "!",
                "title": m["title"],
                "url": m["web_url"],
                "merged_at": m["merged_at"],
                "additions": s.get("additions", 0),
                "deletions": s.get("deletions", 0),
            })

        for m in gl_reviews:
            review_items.append({
                "platform": "gitlab",
                "repo": repo_path_from_web_url(m["web_url"]),
                "number": m["iid"],
                "ref_prefix": "!",
                "title": m["title"],
                "url": m["web_url"],
                "updated_at": m.get("created_at"),
            })

        for i in gl_issues_opened:
            issues_opened_items.append({
                "platform": "gitlab",
                "repo": repo_path_from_web_url(i["web_url"]),
                "number": i["iid"],
                "ref_prefix": "#",
                "title": i["title"],
                "state": "open" if i["state"] == "opened" else i["state"],
                "created_at": i.get("created_at"),
            })

        for i in gl_issues_closed:
            issues_closed_items.append({
                "platform": "gitlab",
                "repo": repo_path_from_web_url(i["web_url"]),
                "number": i["iid"],
                "ref_prefix": "#",
                "title": i["title"],
                "closed_at": i.get("closed_at"),
            })

        # closed_after/closed_before aren't honoured server-side by GitLab's
        # issues API, so the fetch is bounded by updated_after/before instead
        # and the exact [start, end] window on closed_at is enforced here.
        issues_closed_items = [
            i for i in issues_closed_items
            if i["platform"] != "gitlab" or (start_s <= (day_of(i.get("closed_at")) or "") <= end_s)
        ]
        issues_closed_items = dedupe(issues_closed_items, key=lambda i: (i["platform"], i["repo"], i["number"]))

    # --- commit buckets (day/week/month, per-platform, for the stacked chart) --
    # "Commits by month" only reads as a chart over a span of several months;
    # a shorter report gets finer buckets so there's still a shape to see.
    period_days = (end - start).days + 1
    granularity = choose_granularity(period_days)
    bucket_defs = build_buckets(start, end, granularity)
    bucket_index = date_to_bucket_index(bucket_defs)
    bucket_counts = [{"github": 0, "gitlab": 0} for _ in bucket_defs]
    for c in commit_rows:
        d = datetime.fromisoformat(c["date"].replace("Z", "+00:00")).date()
        i = bucket_index.get(d)
        if i is not None:
            bucket_counts[i][c["platform"]] += c["count"]
    commit_buckets = [
        {"label": b["label"], "github": counts["github"], "gitlab": counts["gitlab"]}
        for b, counts in zip(bucket_defs, bucket_counts)
    ]
    commits_card_title = f"Commits by {granularity}"
    commits_table_col = granularity.capitalize()

    # --- repos by commit count --------------------------------------------------
    repo_counts = {}
    for c in commit_rows:
        name = f"[{'GitLab' if c['platform'] == 'gitlab' else 'GitHub'}] {c['repo']}" if gitlab_enabled else c["repo"]
        repo_counts[name] = repo_counts.get(name, 0) + c["count"]
    repos = [
        {"name": name, "count": count}
        for name, count in sorted(repo_counts.items(), key=lambda kv: -kv[1])
    ]

    total_commits = sum(c["count"] for c in commit_rows)
    additions_sum = sum(p["additions"] for p in merged_items)
    deletions_sum = sum(p["deletions"] for p in merged_items)

    # --- active days -------------------------------------------------------------
    # Distinct UTC calendar days on which each kind of activity happened, unioned
    # across platforms per category, then unioned across categories for the total.
    day_sets = {
        "Commits": {day_of(c.get("date")) for c in commit_rows},
        ("PRs/MRs opened" if gitlab_enabled else "PRs opened"):
            {day_of(p.get("created_at")) for p in prs} |
            ({day_of(m.get("created_at")) for m in gl_mrs} if gitlab_enabled else set()),
        ("PRs/MRs merged" if gitlab_enabled else "PRs merged"):
            {day_of(p["merged_at"]) for p in merged_items},
        "Reviews given": {day_of(r.get("updated_at")) for r in review_items},
        "Issues opened": {day_of(i.get("created_at")) for i in issues_opened_items},
        "Issues closed": {day_of(i.get("closed_at")) for i in issues_closed_items},
    }
    day_sets = {k: {d for d in v if d} for k, v in day_sets.items()}

    all_active_days = set()
    for v in day_sets.values():
        all_active_days |= v
    active_days = len(all_active_days)

    WORKING_DAYS_PER_YEAR = (52 - 4) * 5 - 11
    working_days = round(period_days * WORKING_DAYS_PER_YEAR / 365) if period_days else 0
    active_pct = round(100 * active_days / working_days) if working_days else 0

    active_day_rows = [
        {"name": label, "count": len(days)}
        for label, days in sorted(day_sets.items(), key=lambda kv: -len(kv[1]))
    ]

    pr_label = "PRs/MRs" if gitlab_enabled else "PRs"
    stats = [
        {"label": "Commits", "value": str(total_commits)},
        {"label": f"{pr_label} opened", "value": str(len(prs) + (len(gl_mrs) if gitlab_enabled else 0))},
        {"label": f"{pr_label} merged", "value": str(len(merged_items))},
        {"label": "Lines changed", "value": (
            f'<span class="add">+{additions_sum:,}</span> '
            f'<span class="sub">/</span> '
            f'<span class="del">−{deletions_sum:,}</span>'
        )},
        {"label": "Reviews given", "value": str(len(review_items))},
        {"label": "Issues closed", "value": str(len(issues_closed_items))},
        {"label": "Active days", "value": str(active_days)},
    ]

    start_label = start.strftime("%-d %b %Y")
    end_label = end.strftime("%-d %b %Y")
    repo_names = sorted({p["repo"] for p in merged_items})
    merged_subtitle = (
        f"{len(merged_items)} merged"
        + (f" · {', '.join(repo_names)}" if repo_names else "")
    )

    with open(template_path) as f:
        html = f.read()

    if not orgs:
        gh_org_label = "all of GitHub"
        monthly_label = "Across every repository, including personal ones"
        footer_scope = f"author/committer:{handle} (no org filter)"
    elif len(orgs) == 1:
        gh_org_label = f"{orgs[0]} org"
        monthly_label = f"Across all {orgs[0]} repositories"
        footer_scope = f"org:{orgs[0]}, author/committer:{handle}"
    else:
        gh_org_label = f"{len(orgs)} orgs: {', '.join(orgs)}"
        monthly_label = f"Across {', '.join(orgs)}"
        footer_scope = " ".join(f"org:{o}" for o in orgs) + f", author/committer:{handle}"

    if gitlab_enabled:
        report_title = f"Activity — {handle}"
        gl_scope_label = "all of GitLab" if gl_any else ', '.join(gl_groups)
        report_subtitle = (
            f"{handle} · GitHub: {gh_org_label} · GitLab: {gitlab_user}, {gl_scope_label} "
            f"· {start_label} – {end_label}"
        )
        monthly_label += " and GitLab"
        merged_card_title = "Merged PRs / MRs"
        footer_text = (
            f"Generated from the GitHub search &amp; REST APIs (<code>gh</code> CLI) scoped to "
            f"{footer_scope}, and the GitLab REST API (<code>glab</code> CLI) scoped to "
            f"gitlab user:{gitlab_user}, groups:{gl_scope_label}. Commit and PR/MR counts reflect "
            f"only activity visible to the authenticated accounts' token scopes."
        )
    else:
        report_title = f"GitHub Activity — {handle}"
        report_subtitle = f"{handle} · {gh_org_label} · {start_label} – {end_label}"
        merged_card_title = "Merged pull requests"
        footer_text = (
            f"Generated from the GitHub search &amp; REST APIs (<code>gh</code> CLI) scoped to "
            f"{footer_scope}. Commit and PR counts reflect only activity visible to the "
            f"authenticated account's token scopes."
        )

    replacements = {
        "__REPORT_TITLE__": report_title,
        "__REPORT_SUBTITLE__": report_subtitle,
        "__MONTHLY_SUBTITLE__": monthly_label,
        "__COMMITS_CARD_TITLE__": commits_card_title,
        "__REPO_SUBTITLE__": f"{total_commits} commits across {len(repos)} repositories",
        "__MERGED_CARD_TITLE__": merged_card_title,
        "__MERGED_SUBTITLE__": merged_subtitle,
        "__ACTIVE_DAYS_SUBTITLE__": (
            f"{active_days} distinct days with recorded activity, "
            f"out of {working_days} working days in the period ({active_pct}%). "
            f"Working days assume 5 days/week, less 4 weeks annual leave and "
            f"11 statutory holidays ({WORKING_DAYS_PER_YEAR} days/year). "
            f"Categories overlap; the total counts each day once."
        ),
        "__FOOTER_TEXT__": footer_text,
        "__GITLAB_ENABLED__": "true" if gitlab_enabled else "false",
        "__COMMIT_BUCKETS_JSON__": json.dumps(commit_buckets),
        "__COMMITS_TABLE_COL_JSON__": json.dumps(commits_table_col),
        "__REPOS_JSON__": json.dumps(repos),
        "__STATS_JSON__": json.dumps(stats),
        "__REVIEWS_JSON__": json.dumps(review_items),
        "__ISSUES_OPENED_JSON__": json.dumps(issues_opened_items),
        "__ISSUES_CLOSED_JSON__": json.dumps(issues_closed_items),
        "__PRS_JSON__": json.dumps(merged_items),
        "__ACTIVE_DAYS_JSON__": json.dumps(active_day_rows),
    }
    for key, val in replacements.items():
        html = html.replace(key, val)

    with open(output_path, "w") as f:
        f.write(html)


if __name__ == "__main__":
    main()
