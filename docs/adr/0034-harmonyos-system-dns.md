# 0034 从鸿蒙默认网络读取系统 DNS

## 状态

已采纳，待真机验证。

## 背景

「追加系统 DNS」需要保留配置已有的上游，并随默认网络获取可用的系统 DNS。Linux 目标下的 mihomo 默认从 `/etc/resolv.conf` 读取服务地址。鸿蒙的 Network Kit 可按网络查询链路提供的 DNS，也能推送默认网络变化。 [Network Kit 原生接口](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-references/capi-net-connection-h/)

## 决定

开关保存在通用设置里，默认关闭。合并配置原文、脚本和 DNS 覆写后，仅给当前配置的 `dns.nameserver` 补一个 `system://`。手动配置的系统上游继续保留。设置保存走现有热应用事务。 [全局 DNS 覆写](0021-global-dns-overrides.md)

显式 `system://` 在 VPN 进程按需使用 Network Kit 的默认网络和链路 DNS，并沿用 Go 的逐 socket 绑定。平台回调在首次使用时注册，生命周期与 VPN 进程一致。回调只标记网络变化，下次需要向上游发起查询时刷新地址。网络暂时不可用时，后续查询最多每秒尝试读取一次。正常缓存期限沿用 mihomo 的五分钟间隔，所有刷新均由查询触发。 [出站 socket 绑定](0008-bind-core-sockets-to-physical-network.md)

## 后果

切网后，已缓存的 DNS 答案按原 TTL 使用。重新获取上游地址时排除 TUN DNS、回环、未指定和多播地址。

真机复测使用同一台手机、相同配置和代理节点。开启后用不同的未缓存域名验证 Wi‑Fi 与蜂窝切换，检查 DNS 记录里的实际上游。用相同条件测量开关前后的首次连接延迟、冷启动到可操作时间、开代理待机 8 小时耗电和 24 小时内核代次。 [真机测量方法](0017-core-ready-without-vpn.md)
