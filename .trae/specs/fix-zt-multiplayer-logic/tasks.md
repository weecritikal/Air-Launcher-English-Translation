# Tasks

- [x] Task 1: ZeroTierBridge 事件处理补全
  - [x] SubTask 1.1: 在 `ZeroTierBridge.m` 的 `handleEventData:` 中新增 `ZTS_EVENT_NETWORK_CLIENT_TOO_OLD`（211）分支，调用 `zeroTierNetworkJoinFailed:error:` 通知 delegate（错误信息："ZeroTier 版本过旧，请更新 zt.framework"）
  - [x] SubTask 1.2: 在 `handleEventData:` 中新增 `ZTS_EVENT_NETWORK_UPDATE`（219）分支，清除该网络的 IP 地址缓存（`_ipv4Addresses` / `_ipv6Addresses` 中对应的 key），重新查询 IP 并调用 `zeroTierNetworkReady:ipv4:ipv6:` 通知 delegate
  - [x] SubTask 1.3: 在 `handleEventData:` 中新增 `ZTS_EVENT_PEER_DIRECT`（240）分支，更新内部 peer 连接模式状态为 "直连"，调用新增的 `zeroTierPeerConnectionModeChanged:` delegate 回调
  - [x] SubTask 1.4: 在 `handleEventData:` 中新增 `ZTS_EVENT_PEER_RELAY`（241）分支，更新 peer 连接模式为 "中继"，调用 delegate 回调
  - [x] SubTask 1.5: 在 `handleEventData:` 中新增 `ZTS_EVENT_PEER_UNREACHABLE`（242）分支，更新 peer 连接模式为 "不可达"，调用 delegate 回调
  - [x] SubTask 1.6: 在 `zeroTierEventCallback` C 函数中提取 peer 信息（`msg->peer->peer_id`），封装到 eventData 的 `peerID` 字段中传递到主线程

- [x] Task 2: ZeroTierBridge 新增 Peer 状态追踪和连接模式枚举
  - [x] SubTask 2.1: 在 `ZeroTierBridge.h` 中新增 `ZeroTierPeerConnectionMode` 枚举（Unknown/Direct/Relay/Unreachable）
  - [x] SubTask 2.2: 在 `ZeroTierBridgeDelegate` 协议中新增 `@optional` 方法 `- (void)zeroTierPeerConnectionModeChanged:(ZeroTierPeerConnectionMode)mode forPeer:(uint64_t)peerID;`
  - [x] SubTask 2.3: 在 `ZeroTierBridge` 类扩展中新增 `_peerConnectionModes` 字典（peerID → 连接模式枚举）和对应的 `_lock` 保护
  - [x] SubTask 2.4: 在 `ZeroTierBridge.h` 中新增 `- (ZeroTierPeerConnectionMode)peerConnectionModeForPeer:(uint64_t)peerID;` 查询方法
  - [x] SubTask 2.5: 在 `stopNode` 和 `ZTS_EVENT_NODE_DOWN` 处理中清理 `_peerConnectionModes` 字典

- [x] Task 3: ZeroTierBridge 新增网络详情查询 API
  - [x] SubTask 3.1: 在 `ZeroTierBridge.h` 中声明 `- (nullable NSString *)networkNameForNetwork:(uint64_t)networkID;`，封装 `zts_net_get_name`
  - [x] SubTask 3.2: 在 `ZeroTierBridge.h` 中声明 `- (int)networkMTUForNetwork:(uint64_t)networkID;`，封装 `zts_net_get_mtu`
  - [x] SubTask 3.3: 在 `ZeroTierBridge.h` 中声明 `- (int)networkTypeForNetwork:(uint64_t)networkID;`，封装 `zts_net_get_type`（返回 0=私有，1=公开）
  - [x] SubTask 3.4: 在 `ZeroTierBridge.h` 中声明 `- (uint64_t)macAddressForNetwork:(uint64_t)networkID;`，封装 `zts_net_get_mac`
  - [x] SubTask 3.5: 在 `ZeroTierBridge.m` 中实现上述 4 个方法，每个方法前检查节点是否在线（`zts_node_is_online()`），不在线时返回默认值

- [x] Task 4: 优化 waitForNodeOnlineWithTimeout: 逻辑
  - [x] SubTask 4.1: 修改 `waitForNodeOnlineWithTimeout:` 方法，区分三种情况：节点从未上线（`!_hasBeenOnline`，严格等待 `zts_node_is_online()==1`）、节点曾上线但当前离线（`_hasBeenOnline==YES && _nodeStatus==Offline`，最多等待 10 秒内恢复 Online）、节点正在启动（`_nodeStatus==Starting`，继续等待直到 Online 或超时）
  - [x] SubTask 4.2: 更新方法注释，删除"因掉线而直接视为可用"的容错逻辑说明，改为新的分类等待策略

- [x] Task 5: 优化 waitForNetworkReady:timeout: 按网络类型区分
  - [x] SubTask 5.1: 修改 `waitForNetworkReady:timeout:` 方法签名不变，但内部逻辑根据当前连接的 Network ID 是否为 Ad-hoc 网络（通过 `MultiplayerManager.isAdhocNetworkId:` 判断或传入 isAdhoc 参数）来决定检查 IPv4 还是 IPv6
  - [x] SubTask 5.2: 标准网络：仅检查 `zts_addr_is_assigned(networkID, ZTS_AF_INET)==1`（不再检查 IPv6）
  - [x] SubTask 5.3: Ad-hoc 网络：仅检查 `zts_addr_is_assigned(networkID, ZTS_AF_INET6)==1`（不再检查 IPv4）
  - [x] SubTask 5.4: 两者都要求 `zts_net_transport_is_ready(networkID)==1`，更新日志输出标注当前检查的是 IPv4 还是 IPv6

- [x] Task 6: MultiplayerManager 新增 peer 连接模式回调
  - [x] SubTask 6.1: 在 `MultiplayerManagerDelegate` 协议中新增 `@optional` 方法 `- (void)multiplayerPeerConnectionModeChanged:(NSString *)modeDescription;`，参数为人类可读的连接模式描述（"直连"/"中继"/"不可达"）
  - [x] SubTask 6.2: 在 `MultiplayerManager` 中实现 `ZeroTierBridgeDelegate` 的新方法 `zeroTierPeerConnectionModeChanged:forPeer:`，转换为 `multiplayerPeerConnectionModeChanged:` 并 dispatch_async 到主线程调用 delegate
  - [x] SubTask 6.3: 在 `MultiplayerManager.h` 中新增只读属性 `@property (nonatomic, copy, readonly, nullable) NSString *currentPeerConnectionMode;`，用于 UI 层查询当前连接模式

- [x] Task 7: MultiplayerManager 处理新增的 ZeroTier 事件回调
  - [x] SubTask 7.1: 实现 `zeroTierNetworkJoinFailed:` 对 `CLIENT_TOO_OLD` 错误的特殊处理：设置 room.status 为 Error，通知 delegate `multiplayerRoom:didFailWithError:` 并附带明确错误信息
  - [x] SubTask 7.2: 实现 `zeroTierNetworkReady:` 对 `NETWORK_UPDATE` 事件触发后的 IP 刷新处理：当 IP 变化时更新 `currentLocalIP` 和 `currentRoom.hostIP`

# 远程更新说明

远程 `feature/network-zt-framework` 分支在本次 spec 编写期间新增了 `PortForwarder.h` / `PortForwarder.m`（本地 TCP 端口转发器，替代 SOCKS5 代理用于 Minecraft Netty 流量）。本优化不修改 PortForwarder 的实现，仅修改 `ZeroTierBridge` 和 `MultiplayerManager` 的事件处理和状态管理逻辑。`MultiplayerManager.m` 中对 PortForwarder 的调用逻辑保持不变。

# Task Dependencies

- Task 2 依赖 Task 1（peer 事件处理需要先有枚举定义）
- Task 6 依赖 Task 2（MultiplayerManager 需要使用 ZeroTierBridge 的新枚举和 delegate 方法）
- Task 7 依赖 Task 1（新增的事件处理在 MultiplayerManager 中已有对应的 delegate 回调）
- Task 4 和 Task 5 可独立进行
- Task 3 可独立进行
