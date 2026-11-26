#!/usr/bin/env python3
"""
Deduplicated GitHub Issue sync for Gemini Web contract drift alerts.

Creates, updates, deduplicates, or auto-closes a single tracking issue labeled
`gemini-contract-drift` using the `gh` CLI (requires `issues: write` only;
never commits code or opens PRs).

Stdlib-only (Python 3.12+). Zero external pip dependencies.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable


DEFAULT_LABEL = "gemini-contract-drift"
DEFAULT_LABEL_COLOR = "D93F0B"
DEFAULT_LABEL_DESCRIPTION = "Automated Gemini web frontend contract drift alert"
FINGERPRINT_PREFIX = "<!-- contract-drift-fingerprint: "
FINGERPRINT_RE = re.compile(r"<!--\s*contract-drift-fingerprint:\s*([0-9a-f]{16,64})\s*-->")
METADATA_PREFIX = "<!-- contract-drift-meta: "
METADATA_RE = re.compile(r"<!--\s*contract-drift-meta:\s*(\{.*?\})\s*-->")


def extract_check_sets(report: dict[str, Any]) -> tuple[list[str], list[str]]:
    checks = report.get("checks", [])
    breaking = sorted(
        str(c["check_id"]) for c in checks if c.get("status") == "BREAKING_DRIFT"
    )
    degraded = sorted(
        str(c["check_id"])
        for c in checks
        if c.get("status") == "DEGRADED_FALLBACK_ACTIVE"
    )
    return breaking, degraded


def compute_fingerprint(report: dict[str, Any]) -> str:
    """Stable SHA-256 fingerprint over (sorted breaking IDs, sorted degraded IDs)."""
    breaking_ids, degraded_ids = extract_check_sets(report)
    canonical = json.dumps(
        {
            "breaking": breaking_ids,
            "degraded": degraded_ids,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def extract_fingerprint(issue_body: str) -> str | None:
    if not issue_body:
        return None
    m = FINGERPRINT_RE.search(issue_body)
    return m.group(1) if m else None


def extract_embedded_metadata(issue_body: str) -> dict[str, Any]:
    if not issue_body:
        return {}
    m = METADATA_RE.search(issue_body)
    if not m:
        return {}
    try:
        parsed = json.loads(m.group(1))
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        return {}


def build_issue_title(report: dict[str, Any]) -> str:
    live_build = str(report.get("live_build_label") or "unknown")
    breaking_ids, degraded_ids = extract_check_sets(report)
    return (
        f"[Contract Drift] {live_build}: "
        f"{len(breaking_ids)} breaking, {len(degraded_ids)} degraded"
    )


def build_issue_body(
    report: dict[str, Any],
    markdown_report: str,
    run_url: str | None = None,
) -> str:
    fp = compute_fingerprint(report)
    breaking_ids, degraded_ids = extract_check_sets(report)
    meta = json.dumps(
        {
            "live_build_label": str(report.get("live_build_label") or "unknown"),
            "breaking": breaking_ids,
            "degraded": degraded_ids,
        },
        sort_keys=True,
        separators=(",", ":"),
    )

    trimmed_md = markdown_report.strip()
    max_md_chars = 58_000
    if len(trimmed_md) > max_md_chars:
        trimmed_md = (
            trimmed_md[:max_md_chars].rstrip()
            + "\n\n_(Report truncated to fit GitHub Issue 65,536-char limit; inspect the workflow artifact for full output.)_"
        )

    parts = [trimmed_md]
    if run_url:
        parts.append(f"---\nWorkflow Run: {run_url}")
    parts.append(
        "_This issue is managed automatically by `.github/workflows/ci-contract-check.yml`. "
        "It will update only when the failure fingerprint changes and close automatically "
        "once all contracts verify `PASS`._"
    )
    parts.append(f"{FINGERPRINT_PREFIX}{fp} -->")
    parts.append(f"{METADATA_PREFIX}{meta} -->")
    return "\n\n".join(parts) + "\n"


def build_diff_comment(
    previous_body: str,
    report: dict[str, Any],
    run_url: str | None = None,
) -> str:
    prev_meta = extract_embedded_metadata(previous_body)
    prev_build = prev_meta.get("live_build_label")
    prev_breaking = set(prev_meta.get("breaking", []))
    prev_degraded = set(prev_meta.get("degraded", []))

    live_build = str(report.get("live_build_label") or "unknown")
    curr_breaking_list, curr_degraded_list = extract_check_sets(report)
    curr_breaking = set(curr_breaking_list)
    curr_degraded = set(curr_degraded_list)

    lines: list[str] = [
        f"### Contract Drift Update (`{live_build}`)",
        "",
        f"- **Current Status**: `{report.get('overall_status')}` "
        f"({len(curr_breaking)} breaking, {len(curr_degraded)} degraded)",
    ]
    if prev_build and prev_build != live_build:
        lines.append(f"- **Build Label Changed**: `{prev_build}` -> `{live_build}`")

    new_breaking = sorted(curr_breaking - prev_breaking)
    fixed_breaking = sorted(prev_breaking - curr_breaking)
    new_degraded = sorted(curr_degraded - prev_degraded)
    fixed_degraded = sorted(prev_degraded - curr_degraded)

    if new_breaking:
        lines.append("- **Newly Breaking**: " + ", ".join(f"`{c}`" for c in new_breaking))
    if fixed_breaking:
        lines.append("- **No Longer Breaking**: " + ", ".join(f"`{c}`" for c in fixed_breaking))
    if new_degraded:
        lines.append("- **Newly Degraded**: " + ", ".join(f"`{c}`" for c in new_degraded))
    if fixed_degraded:
        lines.append("- **No Longer Degraded**: " + ", ".join(f"`{c}`" for c in fixed_degraded))

    if run_url:
        lines.append(f"- **Workflow Run**: {run_url}")

    lines.append("")
    lines.append("The issue description above has been updated with the latest diagnostics.")
    return "\n".join(lines) + "\n"


def build_resolution_comment(report: dict[str, Any], run_url: str | None = None) -> str:
    live_build = str(report.get("live_build_label") or "unknown")
    summary = report.get("summary", {})
    total = summary.get("total", 0)
    passed = summary.get("pass", total)
    lines = [
        f"All contracts verified `PASS` against `{live_build}` ({passed}/{total} checks passing).",
        "",
        "Closing this automated drift alert.",
    ]
    if run_url:
        lines.append(f"\nWorkflow Run: {run_url}")
    return "\n".join(lines) + "\n"


def plan_sync_action(
    report: dict[str, Any],
    markdown_report: str,
    open_issues: list[dict[str, Any]],
    open_on_degraded: bool = True,
    run_url: str | None = None,
) -> dict[str, Any]:
    """
    Pure decision engine returning one of:
      - {"action": "noop", "reason": ...}
      - {"action": "create", "title": ..., "body": ..., "fingerprint": ...}
      - {"action": "update", "issue_number": ..., "title": ..., "body": ..., "comment": ..., "fingerprint": ...}
      - {"action": "close", "issue_numbers": [...], "comment": ...}
    """
    overall = str(report.get("overall_status") or "PASS")
    should_alert = overall == "BREAKING_DRIFT" or (
        overall == "DEGRADED_FALLBACK_ACTIVE" and open_on_degraded
    )
    fingerprint = compute_fingerprint(report)

    if not should_alert:
        if not open_issues:
            return {
                "action": "noop",
                "reason": f"Status is {overall} and no open contract drift issue exists.",
                "fingerprint": fingerprint,
            }
        return {
            "action": "close",
            "issue_numbers": [int(i["number"]) for i in open_issues if "number" in i],
            "comment": build_resolution_comment(report, run_url=run_url),
            "fingerprint": fingerprint,
        }

    title = build_issue_title(report)
    body = build_issue_body(report, markdown_report, run_url=run_url)

    if not open_issues:
        return {
            "action": "create",
            "title": title,
            "body": body,
            "fingerprint": fingerprint,
        }

    # Deduplicate against the oldest/primary open drift issue
    sorted_issues = sorted(open_issues, key=lambda item: int(item.get("number", 0)))
    primary = sorted_issues[0]
    existing_fp = extract_fingerprint(str(primary.get("body") or ""))

    if existing_fp == fingerprint:
        return {
            "action": "noop",
            "issue_number": int(primary["number"]),
            "reason": (
                f"Open issue #{primary['number']} already has identical fingerprint "
                f"{fingerprint[:12]}; skipping update/comment."
            ),
            "fingerprint": fingerprint,
        }

    return {
        "action": "update",
        "issue_number": int(primary["number"]),
        "title": title,
        "body": body,
        "comment": build_diff_comment(str(primary.get("body") or ""), report, run_url=run_url),
        "fingerprint": fingerprint,
    }


def _default_run_gh(args: list[str]) -> str:
    stdin_payload: str | None = None
    exec_args: list[str] = []
    i = 0
    while i < len(args):
        if args[i] == "--body" and i + 1 < len(args) and args[:2] in (
            ["issue", "create"],
            ["issue", "edit"],
            ["issue", "comment"],
        ):
            exec_args.extend(["--body-file", "-"])
            stdin_payload = args[i + 1]
            i += 2
            continue
        exec_args.append(args[i])
        i += 1

    proc = subprocess.run(
        ["gh", *exec_args],
        input=stdin_payload,
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"gh {' '.join(args[:3])} failed (exit {proc.returncode}): {proc.stderr.strip()}"
        )
    return proc.stdout


def sync_contract_issue(
    report: dict[str, Any],
    markdown_report: str,
    label: str = DEFAULT_LABEL,
    open_on_degraded: bool = True,
    dry_run: bool = False,
    repo: str | None = None,
    run_url: str | None = None,
    open_issues_override: list[dict[str, Any]] | None = None,
    gh_runner: Callable[[list[str]], str] = _default_run_gh,
) -> dict[str, Any]:
    repo_args = ["--repo", repo] if repo else []

    if open_issues_override is not None:
        open_issues = open_issues_override
    elif dry_run:
        open_issues = []
    else:
        gh_runner(
            [
                "label",
                "create",
                label,
                "--color",
                DEFAULT_LABEL_COLOR,
                "--description",
                DEFAULT_LABEL_DESCRIPTION,
                "--force",
                *repo_args,
            ]
        )
        raw_list = gh_runner(
            [
                "issue",
                "list",
                "--label",
                label,
                "--state",
                "open",
                "--json",
                "number,title,body",
                "--limit",
                "20",
                *repo_args,
            ]
        )
        parsed = json.loads(raw_list or "[]")
        open_issues = parsed if isinstance(parsed, list) else []

    plan = plan_sync_action(
        report=report,
        markdown_report=markdown_report,
        open_issues=open_issues,
        open_on_degraded=open_on_degraded,
        run_url=run_url,
    )

    if dry_run:
        return {"dry_run": True, **plan}

    action = plan["action"]
    if action == "noop":
        return {"dry_run": False, **plan}

    if action == "create":
        url_out = gh_runner(
            [
                "issue",
                "create",
                "--label",
                label,
                "--title",
                plan["title"],
                "--body",
                plan["body"],
                *repo_args,
            ]
        ).strip()
        return {"dry_run": False, "issue_url": url_out, **plan}

    if action == "update":
        num = str(plan["issue_number"])
        gh_runner(
            [
                "issue",
                "edit",
                num,
                "--title",
                plan["title"],
                "--body",
                plan["body"],
                *repo_args,
            ]
        )
        gh_runner(
            [
                "issue",
                "comment",
                num,
                "--body",
                plan["comment"],
                *repo_args,
            ]
        )
        return {"dry_run": False, **plan}

    if action == "close":
        for issue_num in plan["issue_numbers"]:
            gh_runner(
                [
                    "issue",
                    "close",
                    str(issue_num),
                    "--comment",
                    plan["comment"],
                    *repo_args,
                ]
            )
        return {"dry_run": False, **plan}

    return {"dry_run": False, **plan}


def _parse_bool(raw: str) -> bool:
    low = raw.strip().lower()
    if low in ("1", "true", "yes", "y", "on"):
        return True
    if low in ("0", "false", "no", "n", "off"):
        return False
    raise argparse.ArgumentTypeError(f"Expected boolean value, got {raw!r}")


def _github_run_url_from_env() -> str | None:
    server = os.environ.get("GITHUB_SERVER_URL")
    repo = os.environ.get("GITHUB_REPOSITORY")
    run_id = os.environ.get("GITHUB_RUN_ID")
    if server and repo and run_id:
        return f"{server}/{repo}/actions/runs/{run_id}"
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Create, update, deduplicate, or auto-close Gemini contract drift GitHub Issues."
    )
    parser.add_argument("--report", type=Path, required=True, help="Path to contract-report.json")
    parser.add_argument("--markdown", type=Path, required=True, help="Path to contract-report.md")
    parser.add_argument("--label", default=DEFAULT_LABEL)
    parser.add_argument("--repo", default=None, help="Optional owner/repo override for gh CLI")
    parser.add_argument(
        "--open-on-degraded",
        type=_parse_bool,
        default=True,
        help="Whether DEGRADED_FALLBACK_ACTIVE opens/updates an alert issue (default: true)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Compute action and print JSON plan without invoking gh CLI",
    )
    parser.add_argument(
        "--mock-open-issues",
        type=Path,
        default=None,
        help="Optional JSON file containing simulated open issues (useful with --dry-run)",
    )
    args = parser.parse_args(argv)

    report = json.loads(args.report.read_text(encoding="utf-8"))
    markdown = args.markdown.read_text(encoding="utf-8")

    open_issues_override = None
    if args.mock_open_issues:
        loaded = json.loads(args.mock_open_issues.read_text(encoding="utf-8"))
        if isinstance(loaded, list):
            open_issues_override = loaded

    run_url = _github_run_url_from_env()
    result = sync_contract_issue(
        report=report,
        markdown_report=markdown,
        label=args.label,
        open_on_degraded=args.open_on_degraded,
        dry_run=args.dry_run,
        repo=args.repo,
        run_url=run_url,
        open_issues_override=open_issues_override,
    )

    if args.dry_run:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(
            f"[sync_contract_issue] action={result['action']} "
            f"fingerprint={str(result.get('fingerprint', ''))[:12]}"
            + (f" issue=#{result['issue_number']}" if "issue_number" in result else "")
            + (f" issues={result['issue_numbers']}" if "issue_numbers" in result else "")
            + (f" url={result['issue_url']}" if "issue_url" in result else "")
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
