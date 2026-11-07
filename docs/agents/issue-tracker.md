# Issue tracker：GitHub

本仓库的 issue 和 spec 都放在 GitHub Issues（`VOD-Studio/ArkClash`），所有操作用 `gh`。`gh` 在仓库目录里会自动从 `git remote` 识别仓库。

标题写成 `[scope] 描述`，正文里不放订阅链接、节点、secret，其余写法见 `docs/agents/git.md`「Issue」。标签见 `docs/agents/triage-labels.md`。

## 常用操作

- **新建**：`gh issue create --title "..." --body "..."`，多行正文用 heredoc。
- **查看**：`gh issue view <编号> --json number,title,body,labels,comments`。
- **列出**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，按需加 `--label`、`--state`。
- **挂为子 issue**：`gh issue create --parent <父编号> ...`，或事后 `gh issue edit <父编号> --add-sub-issue <子编号>`。
- **评论**：`gh issue comment <编号> --body "..."`。
- **加减标签**：`gh issue edit <编号> --add-label "..."` / `--remove-label "..."`。
- **关闭**：`gh issue close <编号> --comment "..."`。

## Pull requests as a triage surface

**PRs as a request surface: no.**（`/triage` 读这个开关。改成 `yes` 时，外部 PR 也当作需求进入分诊。）

为 `yes` 时，PR 和 issue 走同样的标签和状态，用对应的 `gh pr` 命令：

- **查看 PR**：`gh pr view <编号> --comments`，diff 用 `gh pr diff <编号>`。
- **列出待分诊的外部 PR**：`gh api --paginate 'repos/{owner}/{repo}/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`。
- **评论、标签、关闭**：`gh pr comment`、`gh pr edit --add-label` / `--remove-label`、`gh pr close`。

GitHub 的 issue 和 PR 共用一套编号，单独一个 `#42` 可能是任一种：先 `gh pr view 42`，不是再 `gh issue view 42`。

## When a skill says "publish to the issue tracker"

新建一个 GitHub issue。

## When a skill says "fetch the relevant ticket"

按上面「查看」读取。

## Wayfinding operations

`/wayfinder` 用。**地图**是一个 issue，**决策票**是它的子 issue。

- **地图**：一个带 `wayfinder:map` 标签的 issue，正文是 Notes / Decisions so far / 迷雾。`gh issue create --label wayfinder:map`。
- **决策票**：挂在地图下的子 issue（见「挂为子 issue」），标签 `wayfinder:<类型>`（`research` / `prototype` / `grilling` / `task`）。认领后指派给推进地图的人。
- **阻塞关系**：用 GitHub 原生的 issue 依赖，网页上能直接看到。加一条边：`gh api --method POST repos/<owner>/<repo>/issues/<被阻塞>/dependencies/blocked_by -F issue_id=<阻塞方的数据库 id>`。数据库 id 用 `gh api repos/<owner>/<repo>/issues/<编号> --jq .id` 取，不是 `#编号`，也不是 `node_id`。`issue_dependencies_summary.blocked_by` 是还开着的阻塞数。一张票的阻塞方全部关闭后，它就解除阻塞了。
- **前沿查询**：列出地图下开着的子 issue，去掉还有未关闭阻塞（`issue_dependencies_summary.blocked_by > 0`）或已有指派人的，按地图里的顺序取第一张。
- **认领**：`gh issue edit <编号> --add-assignee @me`，这是本次会话的第一个写操作。
- **结案**：`gh issue comment <编号> --body "<结论>"`，再 `gh issue close <编号>`，然后在地图的 Decisions so far 里追加一行要点和链接。
