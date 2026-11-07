#!/usr/bin/env python3
"""判断这次 CI 要跑哪些任务，按 GITHUB_OUTPUT 的格式输出到 stdout。

  build=true|false  是否编内核、打 HAP。PR 只改了文档时为 false。
  deps=true|false   Go 依赖或 Go 版本是否变了，决定是否扫描依赖漏洞。

环境变量（由 ci.yml 传入）：EVENT、BASE、HEAD、HEAD_MESSAGE。
本机调试：changes.py --files README.md docs/ci.md
"""
import os
import re
import subprocess
import sys

DEPS = {"core/go.mod", "core/go.sum", ".go-version"}
# 合并发版 PR 产生的提交：release.yml 会从对应的 tag 构建，这里不再重复构建。
RELEASE_MERGE = re.compile(r"^Merge pull request #\d+ from [^/\s]+/release-please--")


def is_docs(path: str) -> bool:
    return (
        path.endswith(".md")
        or path.startswith("docs/")
        or path.startswith(".github/ISSUE_TEMPLATE/")
        or path in {"LICENSE", ".github/CODEOWNERS"}
    )


def decide(files: list[str]) -> dict[str, bool]:
    return {
        "build": not all(is_docs(f) for f in files),
        "deps": any(f in DEPS for f in files),
    }


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--files":
        result = decide(sys.argv[2:])
    else:
        event = os.environ.get("EVENT", "")
        if event == "pull_request":
            out = subprocess.run(
                ["git", "diff", "--name-only", f"{os.environ['BASE']}...{os.environ['HEAD']}"],
                check=True, capture_output=True, text=True,
            ).stdout
            result = decide(out.split())
        elif event == "push" and RELEASE_MERGE.match(os.environ.get("HEAD_MESSAGE", "")):
            result = {"build": False, "deps": False}
        else:
            # main 上的提交、手动触发和机器人触发都完整跑一遍。
            result = {"build": True, "deps": True}
    for key, value in result.items():
        print(f"{key}={'true' if value else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
