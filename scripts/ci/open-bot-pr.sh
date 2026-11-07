#!/usr/bin/env bash
# 把工作区里指定文件的改动提交到机器人分支，开（或更新）PR，再手动触发 CI。
# 用法：open-bot-pr.sh <分支> <提交信息> <PR 正文> <文件...>，GH_TOKEN 需要 contents、pull-requests、actions 写权限。
#
# GITHUB_TOKEN 开的 PR 不会触发 pull_request 事件，但 workflow_dispatch 例外：
# 手动触发后「CI 通过」检查挂在 PR 的最新提交上，满足 main 的合并规则，不需要个人 token。
set -euo pipefail

BRANCH="$1"
MESSAGE="$2"
BODY="$3"
shift 3

if git diff --quiet -- "$@"; then
  echo "没有变化，不开 PR"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch -C "$BRANCH"
git add -- "$@"
git commit -q -m "$MESSAGE"
git push --force origin "$BRANCH"

if [[ -z "$(gh pr list --head "$BRANCH" --state open --json number --jq '.[].number')" ]]; then
  gh pr create --base main --head "$BRANCH" --title "$MESSAGE" --body "$BODY"
else
  gh pr edit "$BRANCH" --title "$MESSAGE" --body "$BODY"
fi
gh workflow run ci.yml --ref "$BRANCH"
