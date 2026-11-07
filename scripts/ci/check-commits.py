#!/usr/bin/env python3
"""检查提交信息是否符合 docs/agents/git.md 的中文 Conventional Commits 规则。

用 merge commit 或 rebase 合并时，release-please 读分支上的每个提交；squash 合并时读 PR 标题。
CI 两样都查：快速检查查每个提交，pr-title.yml 查 PR 标题。

用法：
  check-commits.py <git 范围>          检查范围内的每个提交，如 origin/main..HEAD
  check-commits.py --message "<标题>"   只检查一条，调试规则用
"""
import re
import subprocess
import sys

TYPES = ("feat", "fix", "perf", "refactor", "docs", "style", "test", "build", "ci", "chore", "revert")
HEADER = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[a-z0-9][a-z0-9/-]*)\))?!?: (?P<subject>\S.*)$")
# GitHub 的合并提交（含「Update branch」按钮生成的）和 git revert 生成的提交：release-please 会忽略或自行处理。
EXEMPT = re.compile(r'^(Merge (pull request|branch|remote-tracking branch) |Revert ")')


def problems(header: str) -> list[str]:
    if EXEMPT.match(header):
        return []
    if header.startswith(("fixup!", "squash!", "amend!")):
        return ["是 fixup/squash 提交：合并前先整理（git rebase -i --autosquash）"]
    m = HEADER.match(header)
    if m is None:
        return ["格式应为 <type>(<scope>): <subject>"]
    if m["type"] not in TYPES:
        return [f"type「{m['type']}」不在允许的列表里：{' '.join(TYPES)}"]
    if re.match(r"(?i)wip\b", m["subject"]):
        return ["WIP 提交：合并前整理成最终形态"]
    return []


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--message":
        commits = [("(message)", sys.argv[2])]
    elif len(sys.argv) == 2:
        out = subprocess.run(
            ["git", "log", "--format=%h%x09%s", sys.argv[1]],
            check=True, capture_output=True, text=True,
        ).stdout
        commits = [tuple(line.split("\t", 1)) for line in out.splitlines() if line]
    else:
        print(__doc__, file=sys.stderr)
        return 2

    failed = 0
    for sha, header in commits:
        for problem in problems(header):
            print(f"✗ {sha} {header}\n    {problem}", file=sys.stderr)
            failed += 1
    if failed:
        print(f"\n{failed} 个提交信息不符合规则，见 docs/agents/git.md「提交信息」", file=sys.stderr)
        return 1
    print(f"检查了 {len(commits)} 个提交")
    return 0


if __name__ == "__main__":
    sys.exit(main())
