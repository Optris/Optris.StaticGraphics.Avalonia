#!/usr/bin/env python3
"""Assert every reusable-workflow call grants what the called workflow's jobs demand.

WHY THIS EXISTS. A called workflow's jobs can never hold more permission than the calling job,
and GitHub enforces that when it LOADS the workflow - before any job runs, regardless of whether
the job needing the permission would have been skipped. Get the union wrong and the run does not
fail: it never starts. No jobs, no logs, and a generic "This run likely failed because of a
workflow file issue".

That is not a hypothetical. The nightly Avalonia watch failed that way every night from the day it
was written, and its predecessor did the same before it - twelve consecutive silent failures,
because a scheduled run that never starts produces nothing for anyone to look at. The caller
granted contents: write; release.yml's publish-nuget job declares id-token: write.

actionlint does not model this, and neither does anything else that runs locally, which is why it
is worth a script of its own.
"""
from __future__ import annotations

import pathlib
import sys

import yaml

RANK = {None: 0, "none": 0, "read": 1, "write": 2}
WORKFLOWS = pathlib.Path(".github/workflows")


def load(path: pathlib.Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def normalise(permissions) -> dict[str, str]:
    """A permissions block in any of its spellings, as a scope -> level mapping."""
    if permissions is None:
        return {}
    # `permissions: write-all` / `read-all` / `{}` are all legal shorthands.
    if isinstance(permissions, str):
        if permissions == "write-all":
            return {"*": "write"}
        if permissions == "read-all":
            return {"*": "read"}
        return {}
    return {scope: level for scope, level in permissions.items()}


def demanded(path: pathlib.Path, seen: set[pathlib.Path]) -> dict[str, str]:
    """The union of every permission any job in this workflow can ask for, transitively.

    Transitive because a called workflow may call another, and the ceiling applies down the whole
    chain rather than one level at a time.
    """
    if path in seen:  # a cycle would be a different bug; do not hang on it
        return {}
    seen = seen | {path}

    document = load(path)
    union: dict[str, str] = dict(normalise(document.get("permissions")))

    for job in (document.get("jobs") or {}).values():
        for scope, level in normalise(job.get("permissions")).items():
            if RANK.get(level, 0) > RANK.get(union.get(scope), 0):
                union[scope] = level

        called = job.get("uses", "")
        if isinstance(called, str) and called.startswith("./"):
            for scope, level in demanded(pathlib.Path(called[2:]), seen).items():
                if RANK.get(level, 0) > RANK.get(union.get(scope), 0):
                    union[scope] = level

    return union


def main() -> int:
    problems: list[str] = []
    checked = 0

    for path in sorted(WORKFLOWS.glob("*.yml")):
        document = load(path)
        workflow_level = normalise(document.get("permissions"))

        for name, job in (document.get("jobs") or {}).items():
            called = job.get("uses", "")
            if not (isinstance(called, str) and called.startswith("./")):
                continue

            checked += 1
            callee = pathlib.Path(called[2:])
            if not callee.exists():
                problems.append(f"{path.name}: job '{name}' calls {called}, which does not exist")
                continue

            granted = normalise(job.get("permissions")) or workflow_level
            if not granted:
                # Falls back to the repository default, which this script cannot see. Not an
                # error, but it means the ceiling is set somewhere no reviewer can read.
                print(
                    f"  NOTE  {path.name}: job '{name}' grants no explicit permissions, so the "
                    f"ceiling for {callee.name} comes from the repository default and cannot be "
                    "checked here."
                )
                continue

            if granted.get("*"):  # write-all / read-all covers everything at that level
                continue

            for scope, level in sorted(demanded(callee, set()).items()):
                if RANK.get(level, 0) > RANK.get(granted.get(scope), 0):
                    problems.append(
                        f"{path.name}: job '{name}' calls {callee.name} but grants "
                        f"{scope}: {granted.get(scope) or '(nothing)'} where a job in that chain "
                        f"declares {scope}: {level}. GitHub rejects this when it LOADS the "
                        "workflow, so the run will not start at all - no jobs, no logs."
                    )

    if problems:
        print(f"\nReusable-workflow permission check FAILED ({len(problems)} problem(s)):\n")
        for problem in problems:
            print(f"  ::error::{problem}")
        print(
            "\nGrant the calling job the UNION of every permission any job in the called chain "
            "declares, even the ones this run would skip."
        )
        return 1

    print(f"\nReusable-workflow permission check passed ({checked} call site(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
