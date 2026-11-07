#!/usr/bin/env bash
# 为机器人 PR 手动触发 CI，并删掉 GitHub 自动生成的重复运行。
# 用法：dispatch-bot-ci.sh <仓库> <分支>，GH_TOKEN 需要 actions: write。
#
# 用 GITHUB_TOKEN 推送的提交只会生成一个停在「需要批准」的 pull_request 运行。手动触发
# workflow_dispatch 不需要批准，「CI 通过」照样挂在 PR 的最新提交上。那个等待批准的运行
# 和这次重复，有人点了批准就会再跑一遍，所以删掉。
set -euo pipefail

REPO="$1"
BRANCH="$2"

gh workflow run ci.yml -R "$REPO" --ref "$BRANCH"
# 推送或开 PR 之后，GitHub 可能要过几秒才生成那个等待批准的运行。
sleep 10
gh run list -R "$REPO" --branch "$BRANCH" --event pull_request --status action_required \
  --json databaseId --jq '.[].databaseId' |
  while read -r id; do
    gh api -X DELETE "repos/$REPO/actions/runs/$id"
    echo "已删除等待批准的重复运行 $id"
  done
