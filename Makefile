# ArkClash 构建入口：本地开发和 CI 都只调用这里的目标。
.DEFAULT_GOAL := help
MODE ?= debug
ABI ?= arm64-v8a
export ABI
CHECKS ?= all

help: ## 列出所有目标
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

core: ## 交叉编译 mihomo 内核到 entry/libs/（ABI=arm64-v8a|x86_64，默认 ARM64）
	scripts/build-core.sh

core-smoke: ## 在设备上验证已构建内核（ABI=arm64-v8a|x86_64，可指定 HDC_TARGET）
	bash scripts/smoke-core.sh

core-codeql: ## 使用标准 Go 和补丁依赖构建 CodeQL 分析产物，不用于装机
	scripts/ci/build-codeql.sh

geodata: ## 按 geodata.lock 下载 Geo 数据到 rawfile/geo/，随 HAP 打包
	scripts/fetch-geodata.sh

geodata-update: ## 把上游最新 Geo 数据镜像到 Release 并更新 geodata.lock（需要写权限，平时由每周任务做）
	scripts/update-geodata.sh

hap: ## 打包 HAP 到 dist/（MODE=debug|release，ABI=arm64-v8a|x86_64）
	scripts/build-hap.sh $(MODE)

install: ## 安装当前版本签名包（MODE=debug|release，ABI=arm64-v8a|x86_64）
	scripts/device.sh install $(MODE)

run: install ## 安装并启动
	scripts/device.sh start

log: ## 跟踪内核与 VPN 进程日志
	scripts/device.sh log

lint: ## 代码检查（CHECKS=all|go|shell|arch|arkts|actions|commits|vuln，可多个）
	scripts/lint.sh $(CHECKS)

test: ## 宿主回归（默认全部，可用 TESTS=contracts|core|go|local 或选模块），不操作设备
	scripts/test.sh $(TESTS)

bench: ## 真机启动、VPN 接入与新连接基准（BENCH_ARGS=--help 查看用法）
	@bash scripts/bench.sh $(BENCH_ARGS)

site-dev: ## 启动官网与文档站点本地预览（Bun + Astro）
	bun run --cwd website dev

site-build: ## 构建官网与文档站点静态产物到 website/dist/
	bun run --cwd website build

site-check: ## 检查官网与文档站点类型及内容契约
	bun run --cwd website check

clean: ## 清理构建产物（保留 .toolchain/ 里的补丁工具链）
	rm -rf entry/build entry/.cxx .hvigor dist entry/libs website/dist website/.astro

.PHONY: help core core-smoke core-codeql geodata geodata-update hap install run log lint test bench site-dev site-build site-check clean
