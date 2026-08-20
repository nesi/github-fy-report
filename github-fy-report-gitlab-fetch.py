#!/usr/bin/env python3
"""Small stdin/stdout JSON helpers for the GitLab side of github-fy-report.sh.

`glab api` has no `--jq` (unlike `gh api`), so this fills the same role the
inline `python3 -c` snippets already play for the GitHub PR-stats step:
read raw JSON from `glab api`, print the fields the shell script needs.

Invoked by github-fy-report.sh — not meant to be run standalone.
"""
import json
import sys


def read_ndjson(stream):
    for line in stream:
        line = line.strip()
        if line:
            yield json.loads(line)


def cmd_user_id():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return
    if data:
        print(data[0]["id"])


def cmd_top_level_groups():
    for g in read_ndjson(sys.stdin):
        if g.get("parent_id") is None:
            print(g["full_path"])


def cmd_project_ids():
    for p in read_ndjson(sys.stdin):
        print(p["id"])


def cmd_project_path():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return
    path = data.get("path_with_namespace")
    if path:
        print(path)


def cmd_pushes():
    for e in read_ndjson(sys.stdin):
        pd = e.get("push_data")
        if pd and pd.get("commit_count"):
            print(json.dumps({
                "project_id": e["project_id"],
                "date": e["created_at"],
                "count": pd["commit_count"],
                # A brand-new branch has no "before" state to diff against
                # (commit_from is null), so GitLab's commit_count for it can
                # reflect the branch's whole reachable history rather than
                # just the commits this push actually introduced — wildly
                # overcounting when the branch's base has drifted from the
                # server's current history. action/ref let the shell script
                # cross-check these specifically against the matching MR's
                # own (reliable) commit list.
                "action": pd.get("action"),
                "ref": pd.get("ref"),
            }))


def cmd_mr():
    for m in read_ndjson(sys.stdin):
        print(json.dumps({
            "project_id": m["project_id"],
            "iid": m["iid"],
            "title": m["title"],
            "web_url": m["web_url"],
            "created_at": m["created_at"],
            "merged_at": m.get("merged_at"),
            "state": m["state"],
            "author": (m.get("author") or {}).get("username"),
            "source_branch": m.get("source_branch"),
        }))


def cmd_issue():
    for i in read_ndjson(sys.stdin):
        print(json.dumps({
            "project_id": i["project_id"],
            "iid": i["iid"],
            "title": i["title"],
            "web_url": i["web_url"],
            "state": i["state"],
            "created_at": i.get("created_at"),
            "updated_at": i.get("updated_at"),
            "closed_at": i.get("closed_at"),
        }))


def cmd_mr_commit_count(project_id, iid):
    """Ground truth for a "created"-branch push: how many commits this MR
    actually contains, per GitLab's own merge-base-aware commit list —
    unaffected by the push-event commit_count quirk above."""
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return
    print(json.dumps({
        "project_id": int(project_id),
        "iid": int(iid),
        "count": len(data) if isinstance(data, list) else 0,
    }))


def cmd_diffstat(project_id, iid):
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return
    additions = deletions = 0
    for ch in data.get("changes", []):
        for line in (ch.get("diff") or "").splitlines():
            if line.startswith("+") and not line.startswith("+++"):
                additions += 1
            elif line.startswith("-") and not line.startswith("---"):
                deletions += 1
    print(json.dumps({
        "project_id": int(project_id),
        "iid": int(iid),
        "additions": additions,
        "deletions": deletions,
    }))


COMMANDS = {
    "user-id": lambda args: cmd_user_id(),
    "top-level-groups": lambda args: cmd_top_level_groups(),
    "project-ids": lambda args: cmd_project_ids(),
    "project-path": lambda args: cmd_project_path(),
    "pushes": lambda args: cmd_pushes(),
    "mr": lambda args: cmd_mr(),
    "issue": lambda args: cmd_issue(),
    "mr-commit-count": lambda args: cmd_mr_commit_count(*args),
    "diffstat": lambda args: cmd_diffstat(*args),
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: {sys.argv[0]} <{'|'.join(COMMANDS)}> [args...]", file=sys.stderr)
        sys.exit(1)
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
