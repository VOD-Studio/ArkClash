package main

import _ "unsafe" // go:linkname

// 关闭 mihomo 的回环检测（Clash Meta for Android 也是关掉的）：
//   - Go 出站由 core/socket.go 逐 socket 绑定物理网络，避免再次进入 TUN；
//   - 检测 UDP 时要列出本机网卡，鸿蒙不允许应用使用 netlink，会导致 UDP 直连全部失败。
//
// 这个变量在 loopback 包初始化时从环境变量 DISABLE_LOOPBACK_DETECTOR 读取，
// 比我们的代码早，所以只能直接改。检测器在解析配置时才创建，在 start 之前改即可。
//
//go:linkname disableLoopBackDetector github.com/metacubex/mihomo/component/loopback.disableLoopBackDetector
var disableLoopBackDetector bool

func init() {
	disableLoopBackDetector = true
}
