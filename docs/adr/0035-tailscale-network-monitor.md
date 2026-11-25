# 0035 Tailscale 出站使用鸿蒙默认网络

## 背景

ArkClash 的 mihomo 内核以 Linux 为构建目标。Tailscale 出站首次拨号或解析 DNS 时启动 tsnet，其网络监视器需要读取网卡和默认路由。鸿蒙应用沙箱限制 Linux netlink，而代理配置校验只创建适配器，无法验证这一步。[平台约束](../agents/platform-pitfalls.md)

## 决定

VPN 进程通过 Network Kit 获取默认物理网络的网卡名称、地址和 MTU，并把默认路由与网卡快照提供给 Tailscale 的网络监视器。控制连接和 UDP 数据包继续走 mihomo 的物理网络 socket 绑定。[出站 socket 绑定](0008-bind-core-sockets-to-physical-network.md)

首次启动监视器时订阅系统默认网络变化。多个活跃的监视器共用一份系统订阅，回调只唤醒监视器，由其合并事件并重读快照。最后一个监视器关闭时注销。未使用 Tailscale 的配置不注册该回调。

## 验证

宿主回归覆盖离线启动、模拟 Wi-Fi 与蜂窝切换、多个监视器共享回调及注销失败后的恢复。2026-11-25 在 macOS 上用项目锁定的 mihomo v1.19.34 连接临时 tailnet，通过了 `ts://节点名` 的 A 记录查询、按 IP 和域名访问同伴，以及通过指定出口节点转发 HTTP。测试端收到两次同伴访问和一次出口访问，整组用例耗时 3.31 秒。

同日在 HBP-AL00（API 26）上通过系统浏览器完成了无 `auth-key` 首次授权。重启应用后复用了原授权。启用系统 VPN 后，同伴 HTTP、MagicDNS、经 Tailscale 转发的独立 UDP DNS 查询，以及指定出口节点的 HTTPS 均已验证。公网用例只转发到 `www.google.com:443`，`robots.txt` 返回 200，`generate_204` 返回 204。

两个 tailnet 可以把同一 IP 分给名称不同的同伴。先用域名访问第一个同伴，再热切到第二个 tailnet，mihomo 可能仍保留旧域名供规则匹配。Tailscale 的 TCP 出站在此时使用报文里的真实目标 IP。修复前，按规则访问该 IP 连续两次返回 503；修复后同一真机两次均收到新同伴的响应，分别耗时 19 和 20 ms，直接使用新域名也成功。

通过 USB 连接的测试 DERP 中继预热后，用设备内核连续向同伴发起 20 次 HTTP 请求，每次新建 TCP 连接，端到端耗时中位数为 7 ms，P95 为 13 ms。热切换测试期间系统三次回收 VPN 进程，`hidumper -e --list com.vodstudio.arkclash:vpn` 的原因均为 `SwapFull`，安装测试包前也有同类记录。8 小时耗电和 24 小时稳定性仍待同机对照测量。
