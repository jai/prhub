#!/usr/bin/env python3
"""Claude Code PreToolUse hook (.claude/settings.json): refuse a Bash command that skips the git hooks.
Copied from jai/agent-pager ci/hooks/no_verify.py; change it there first.

Refuses `git commit` or `git push` with --no-verify or -n (alone or in a short-flag group such as -an), and a SKIP=
prefix on either. Hooks are the fast local check; a failing hook gets fixed, not skipped (AGENTS.md). Exit 2 blocks
the call and shows the reason to the agent.
"""

import json
import re
import shlex
import sys

# Global git options that take a value as the next word.
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
# Short commit/push options whose value follows: in `-mn`, n is the message.
SHORT_VALUE_FLAGS = set("mFCctSo")
SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", "\n"}


def words_of(command: str) -> list[str]:
    # A newline ends a command, as in the shell: a heredoc's body is not the arguments of the line that opens it.
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|(){}\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def segments(command: str) -> list[list[str]]:
    try:
        words = words_of(command)
    except ValueError:
        # An unbalanced quote, as an apostrophe in a heredoc's body leaves: read each line on its own.
        words = []
        for line in command.split("\n"):
            try:
                words += words_of(line)
            except ValueError:
                words += line.split()
            words.append("\n")
    out: list[list[str]] = [[]]
    for word in words:
        if word in SEPARATORS or set(word) <= set(";&|\n"):
            out.append([])
        else:
            out[-1].append(word)
    return [s for s in out if s]


def skips_hooks(words: list[str], env: tuple[str, ...] = ()) -> bool:
    words = list(words)
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        env += (words.pop(0),)
    if words and words[0] in ("env", "command", "exec", "sudo"):
        return skips_hooks(words[1:], env)
    if not words or words[0].rsplit("/", 1)[-1] != "git":
        return False
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in GIT_VALUE_OPTIONS else 1
    if i >= len(words) or words[i] not in ("commit", "push"):
        return False
    if any(e.startswith("SKIP=") for e in env):
        return True
    for word in words[i + 1 :]:
        if word == "--" or word.startswith("<<"):
            break
        if word == "--no-verify":
            return True
        if re.match(r"^-[A-Za-z]+$", word):
            for flag in word[1:]:
                if flag == "n":
                    return True
                if flag in SHORT_VALUE_FLAGS:
                    break
    return False


def refused(command: str) -> bool:
    return any(skips_hooks(s) for s in segments(command))


def main() -> int:
    payload = json.load(sys.stdin)
    command = (payload.get("tool_input") or {}).get("command") or ""
    if refused(command):
        print(
            "Refused: git commit/push with --no-verify, -n or SKIP= skips this repo's hooks. "
            "Fix what the hook reports and run the command without it (AGENTS.md).",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
