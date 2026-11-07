# 分支、提交、PR 与 issue

## 分支

每个新任务都先从 `main` 拉分支，在分支上完成。

格式：`<type>/<scope>-<简述>`，全小写，用 `/` 分段、`-` 连词，简述用英文或拼音。

- type 对齐 Conventional Commits：`feat` / `fix` / `chore` / `docs` / `refactor` / `style` / `test` / `perf` / `build`（构建脚本、Makefile）/ `ci`（GitHub Actions）。
- scope 是最内层的模块：`core`、`bridge`（NAPI）、`vpn`、`ui`、`toolchain`、`geodata`、`scripts`、`deps`、`readme`、`release`。改动跨模块、说不出一个时可以省略。
- 例：`fix/core-device-startup`、`feat/ui-proxy-groups`、`perf/vpn-cold-start`、`chore/deps-mihomo`。

PRD 和 issue 拆分是 feature 分支的前几个提交，不单独开文档分支。只有跨 feature 的流程文档（比如这份规范）才考虑独立的 `docs/` 分支。

## 提交步骤

每完成一个任务就提交，一个任务可以有多个 commit。默认只在本地提交，等用户要求再推送。

1. **先分组再暂存**。列出每组的目的、文件、前置提交和验证方式，按下面的职责边界分组，再按依赖排序。
2. **逐组暂存**。用明确的文件路径；同一个文件里有不同目的的改动时，分别准备中间版本再暂存（环境不支持交互式 `git add -p`）。别人的改动和本机专属的改动（签名配置）留在工作区。
3. **核对暂存内容**。每组只有一个逻辑变更，以及它需要的测试、文档。
4. **验证每个提交**。每个提交加上它的前置提交，都要能构建：动了 `core/` 跑 `scripts/build-core.sh`，动了 `entry/` 跑 hvigor。最后的工作区能构建，不代表中间状态也能。
5. **逐组提交**，交付时列出每个 commit 和它的验证结果。纯流程规范的修改单独提交。

## 原子性

一个 commit 是一个逻辑变更，不是一个需求、一次会话或整个工作区。用三个问题判断：

1. 按依赖倒序撤回之后，构建还能通过吗？
2. 三个月后只看标题，能知道做了什么吗？
3. 这些改动服务于同一个目的吗？

同一个职责内的完整行为放在一起，不按文件或技术层切碎。开发中允许 WIP 提交，交付前整理成原子提交；整理范围只限于本任务、还没推送过的历史。

### 职责边界

| 改动 | 提交方式 |
|---|---|
| `core/` 的 C API 与 ArkTS 调用方 | 能力提供方（Go + `arkclash.h` + NAPI 桥）先提交，调用方（ArkTS）后提交 |
| 工具链补丁（`scripts/go-ohos.patch`、依赖补丁）与业务代码 | 分开提交，每个补丁连同它的构建脚本改动一起 |
| UI 进程与 VPN 进程 | 同一个行为跨两个进程时一起提交；无关的分开 |
| 依赖升级（Go、mihomo、gVisor） | 单独提交，正文写复查结果（见 `platform-pitfalls.md`） |
| 无关修复、格式化、流程文档 | 和功能分开 |

## 提交信息

- 中文 Conventional Commits：`<type>(<scope>): <subject>`。纯文档或流程用 `docs`。
- scope 写最小的改动单元，比如 `fix(vpn): ...`，不写 `fix(entry/vpn): ...`。
- subject 只概括一个主要变更，用祈使句，50 字以内。想用 `+` 或 `、` 连接多件事，说明该拆成多个提交。
- body 用列表写改动事实，以及现象和原因（比如崩溃日志里的关键一行）。

## Issue

- 标题：`[scope] 描述`，例：`[vpn] 冷启动时 TUN 创建失败`。标题只写一件事。
- 标签按 `docs/agents/triage-labels.md`：分诊过的 issue 带一个类别（`bug` / `enhancement`）和一个状态。
- 内容里不放订阅链接、节点、secret（见 AGENTS.md「安全」）。

## PR

- base 是 `main`。
- assignees、reviewers、labels 默认都不设，需要时由人工在网页上加。
- 有对应 issue 时在正文写 `Closes #N`；只是相关、不关闭 issue 的，用普通链接。
- 正文写改动摘要、真机验证结果（设备型号、系统版本、验证了什么），以及对四个产品指标的影响。

## 合并

- 由人工审核后在网页上手动合并，不开 auto-merge。
- 用 merge commit 保留分支的原子提交（`gh pr merge --merge --delete-branch`）。前提是分支上每个提交都已整理成最终形态，没有 WIP 或回退提交。
