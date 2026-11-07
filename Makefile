# ArkClash 构建入口：本地开发和 CI 都只调用这里的目标。
.DEFAULT_GOAL := help
MODE ?= debug
CHECKS ?= all

help: ## 列出所有目标
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

core: ## 交叉编译 mihomo 内核到 entry/libs/（补丁版 Go 工具链）
	scripts/build-core.sh

geodata: ## 按 geodata.lock 下载 Geo 数据到 rawfile/geo/，随 HAP 打包
	scripts/fetch-geodata.sh

geodata-update: ## 把上游最新 Geo 数据镜像到 Release 并更新 geodata.lock（需要写权限，平时由每周任务做）
	scripts/update-geodata.sh

hap: ## 打包 HAP 到 dist/（MODE=debug|release）
	scripts/build-hap.sh $(MODE)

install: ## 把当前版本的签名包装到已连接的设备（MODE=debug|release）
	scripts/device.sh install $(MODE)

run: install ## 安装并启动
	scripts/device.sh start

log: ## 跟踪内核与 VPN 进程日志
	scripts/device.sh log

lint: ## 代码检查（CHECKS=all|go|shell|arch|arkts，可多个）
	scripts/lint.sh $(CHECKS)

clean: ## 清理构建产物（保留 .toolchain/ 里的补丁工具链）
	rm -rf entry/build entry/.cxx .hvigor dist entry/libs

.PHONY: help core geodata geodata-update hap install run log lint clean
