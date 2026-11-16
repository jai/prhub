#!/usr/bin/env python3
"""Claude Code PostToolUse hook (.claude/settings.json): format the file the agent just edited.

Runs the repo's formatter for that one file, with the tool versions pinned in the root Makefile (jai/ci
makefile.template). The git pre-commit hook (make lint) is the check; this hook only saves a round trip, so it never
fails the edit. Files outside the repo, or of a type the repo does not format, are left alone.
"""

import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

# File suffix -> (Makefile tool variable, arguments before the file).
FORMATTERS = {
    ".go": ("GOLANGCI", ["fmt"]),
    ".ts": ("OXFMT", []),
    ".tsx": ("OXFMT", []),
    ".mts": ("OXFMT", []),
    ".cts": ("OXFMT", []),
    ".js": ("OXFMT", []),
    ".jsx": ("OXFMT", []),
    ".mjs": ("OXFMT", []),
    ".cjs": ("OXFMT", []),
    ".py": ("RUFF", ["format"]),
    ".sh": ("SHFMT", ["-w"]),
    ".tf": ("TERRAFORM", ["fmt"]),
    ".swift": ("SWIFTFORMAT", []),
    ".php": ("MAGO", ["fmt"]),
}


def tool(root: Path, name: str) -> list[str]:
    # GNU Make 3.81 (macOS) has no --eval: a second makefile prints the variable.
    with tempfile.NamedTemporaryFile("w", suffix=".mk") as extra:
        extra.write("print-tool: ; @echo $(" + name + ")\n")
        extra.flush()
        out = subprocess.run(
            ["make", "-s", "-C", str(root), "-f", "Makefile", "-f", extra.name, "print-tool"],
            capture_output=True,
            text=True,
            check=False,
        )
    return shlex.split(out.stdout.strip()) if out.returncode == 0 else []


def main() -> int:
    payload = json.load(sys.stdin)
    path = (payload.get("tool_input") or {}).get("file_path") or ""
    root = Path(os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or ".").resolve()
    file = Path(path).resolve()
    if not path or root not in file.parents or not file.is_file():
        return 0
    entry = FORMATTERS.get(file.suffix)
    if entry is None or not (root / "Makefile").is_file():
        return 0
    command = tool(root, entry[0])
    if not command:
        return 0
    result = subprocess.run(command + entry[1] + [str(file)], cwd=root, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(f"format_file: {' '.join(command)} failed on {file.name}: {result.stderr.strip()[:500]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
