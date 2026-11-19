#!/usr/bin/env python3
"""Claude Code PostToolUse hook (.claude/settings.json): run `make fix` on the file the agent just edited.

The same fixes the pre-commit hook makes (docs/workflow.md, "Hooks"), one round trip sooner. The pre-commit lint is
the check, so this hook never fails the edit. Files outside the repo, and files `make fix` has no tool for, are left
alone.
"""

import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    payload = json.load(sys.stdin)
    path = (payload.get("tool_input") or {}).get("file_path") or ""
    root = Path(os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or ".").resolve()
    file = Path(path).resolve()
    if not path or root not in file.parents or not file.is_file():
        return 0
    relative = file.relative_to(root).as_posix()
    result = subprocess.run(
        ["make", "-s", "fix", f"FILES={relative}"], cwd=root, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        print(f"make fix failed on {relative}: {result.stderr.strip()[:500]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
