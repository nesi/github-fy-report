#!/usr/bin/env python3
"""Aggregate GitHub activity data fetched by github-fy-report.sh into the HTML template.

Invoked by github-fy-report.sh — not meant to be run standalone.
"""
import json
import sys
from datetime import date, datetime


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


def month_range(start, end):
    y, m = start.year, start.month
    out = []
    while (y, m) <= (end.year, end.month):
        out.append((y, m))
        m += 1
        if m == 13:
            m = 1
            y += 1
    return out


def main():
    workdir, template_path, output_path, handle, org_list, start_s, end_s = sys.argv[1:8]
    start = date.fromisoformat(start_s)
    end = date.fromisoformat(end_s)

    orgs = [o for o in org_list.split(",") if o]

    commits = load_jsonl(f"{workdir}/commits.jsonl")
    prs = load_jsonl(f"{workdir}/prs.jsonl")
    reviews = load_jsonl(f"{workdir}/reviews.jsonl")
    issues_opened = load_jsonl(f"{workdir}/issues_opened.jsonl")
    issues_closed = load_jsonl(f"{workdir}/issues_closed.jsonl")
    pr_stats = load_jsonl(f"{workdir}/pr_stats.jsonl")

    # With a single org the prefix is noise; with several (or none) it is the
    # only thing telling "nesi/docs" and "GenomicsAotearoa/docs" apart.
    single_org_prefix = f"{orgs[0]}/" if len(orgs) == 1 else None

    def strip_org(repo):
        if single_org_prefix and repo.startswith(single_org_prefix):
            return repo[len(single_org_prefix):]
        return repo

    # months
    buckets = {ym: 0 for ym in month_range(start, end)}
    for c in commits:
        d = datetime.fromisoformat(c["date"].replace("Z", "+00:00")).date()
        ym = (d.year, d.month)
        if ym in buckets:
            buckets[ym] += 1
    months = [
        {"label": date(y, m, 1).strftime("%b %y"), "count": buckets[(y, m)]}
        for (y, m) in sorted(buckets)
    ]

    # repos by commit count
    repo_counts = {}
    for c in commits:
        name = strip_org(c["repo"])
        repo_counts[name] = repo_counts.get(name, 0) + 1
    repos = [
        {"name": name, "count": count}
        for name, count in sorted(repo_counts.items(), key=lambda kv: -kv[1])
    ]

    # join PR metadata with stats, keep merged only
    stats_by_key = {(s["repo"], s["number"]): s for s in pr_stats}
    merged_prs = []
    for p in prs:
        key = (p["repo"], p["number"])
        s = stats_by_key.get(key)
        if s and s.get("merged_at"):
            merged_prs.append({
                "repo": strip_org(p["repo"]),
                "number": p["number"],
                "title": p["title"],
                "url": p["url"],
                "merged_at": s["merged_at"],
                "additions": s.get("additions", 0),
                "deletions": s.get("deletions", 0),
            })

    additions_sum = sum(p["additions"] for p in merged_prs)
    deletions_sum = sum(p["deletions"] for p in merged_prs)

    reviews_list = [
        {"repo": strip_org(r["repo"]), "number": r["number"], "title": r["title"], "url": r["url"]}
        for r in reviews
    ]
    issues_opened_list = [
        {
            "repo": strip_org(i.get("repo", "")),
            "number": i["number"],
            "title": i["title"],
            "state": i["state"],
        }
        for i in issues_opened
    ]
    issues_closed_list = [
        {
            "repo": strip_org(i.get("repo", "")),
            "number": i["number"],
            "title": i["title"],
            "date": (i["closed_at"] or "")[:10],
        }
        for i in issues_closed
    ]

    stats = [
        {"label": "Commits", "value": str(len(commits))},
        {"label": "PRs opened", "value": str(len(prs))},
        {"label": "PRs merged", "value": str(len(merged_prs))},
        {"label": "Lines changed", "value": (
            f'<span class="add">+{additions_sum:,}</span> '
            f'<span class="sub">/</span> '
            f'<span class="del">−{deletions_sum:,}</span>'
        )},
        {"label": "Reviews given", "value": str(len(reviews_list))},
        {"label": "Issues closed", "value": str(len(issues_closed_list))},
    ]

    start_label = start.strftime("%-d %b %Y")
    end_label = end.strftime("%-d %b %Y")
    repo_names = sorted({p["repo"] for p in merged_prs})
    merged_subtitle = (
        f"{len(merged_prs)} merged"
        + (f" · {', '.join(repo_names)}" if repo_names else "")
    )

    with open(template_path) as f:
        html = f.read()

    if not orgs:
        org_label = "all of GitHub"
        monthly_label = "Across every repository, including personal ones"
        footer_scope = f"author/committer:{handle} (no org filter)"
    elif len(orgs) == 1:
        org_label = f"{orgs[0]} org"
        monthly_label = f"Across all {orgs[0]} repositories"
        footer_scope = f"org:{orgs[0]}, author/committer:{handle}"
    else:
        org_label = f"{len(orgs)} orgs: {', '.join(orgs)}"
        monthly_label = f"Across {', '.join(orgs)}"
        footer_scope = " ".join(f"org:{o}" for o in orgs) + f", author/committer:{handle}"

    replacements = {
        "__REPORT_TITLE__": f"GitHub Activity — {handle}",
        "__REPORT_SUBTITLE__": f"{handle} · {org_label} · {start_label} – {end_label}",
        "__MONTHLY_SUBTITLE__": monthly_label,
        "__REPO_SUBTITLE__": f"{len(commits)} commits across {len(repos)} repositories",
        "__MERGED_SUBTITLE__": merged_subtitle,
        "__FOOTER_SCOPE__": footer_scope,
        "__MONTHS_JSON__": json.dumps(months),
        "__REPOS_JSON__": json.dumps(repos),
        "__STATS_JSON__": json.dumps(stats),
        "__REVIEWS_JSON__": json.dumps(reviews_list),
        "__ISSUES_OPENED_JSON__": json.dumps(issues_opened_list),
        "__ISSUES_CLOSED_JSON__": json.dumps(issues_closed_list),
        "__PRS_JSON__": json.dumps(merged_prs),
    }
    for key, val in replacements.items():
        html = html.replace(key, val)

    with open(output_path, "w") as f:
        f.write(html)


if __name__ == "__main__":
    main()
