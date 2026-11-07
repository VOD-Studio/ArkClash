# 0002 用打补丁的 Go 工具链编译内核

- 状态：已采纳（2026-11-06）

## 背景

鸿蒙的 musl 拒绝加载使用 initial-exec TLS 的 dlopen 库，而 Go 在 linux/arm64 上正是这样存放 g 指针的。官方修复（golang/go#54805，PR #75048）截至 2026-11 尚未合并。

## 考虑过的方案

1. **等官方修复**：时间不可控，项目会一直卡着。
2. **用 `GOOS=android` 编译**：Go 的 Android 路径依赖 bionic（`android/log.h`、TLS 槽位探测），鸿蒙上编译不过、跑不起来。
3. **把 g 放在线程指针后的固定槽位**：在真机上验证失败，系统线程的 TP+8 已被占用（值为 -1）。
4. **把 g 放进 C 定义的线程局部变量，通过 TLSDESC 访问**：musl 支持，补丁只涉及 `load_g`/`save_g` 两个入口。

## 决定

采用方案 4，补丁在 `scripts/go-ohos.patch`，由 `scripts/build-core.sh` 打进 `.toolchain/` 下的 GOROOT 副本，不改开发者机器上的 Go。同一个补丁也处理了 musl 调用 `DT_INIT_ARRAY` 时不传 argc/argv 的问题。

## 后果

- 内核只能用 `build-core.sh` 构建，Go 版本固定在 `.go-version`，升级 Go 要按 platform-pitfalls 第 1 条复查。
- 内核里环境变量为空，配置只能通过 start 的 JSON 参数传入。
- 官方支持 general-dynamic TLS 后删掉补丁。
