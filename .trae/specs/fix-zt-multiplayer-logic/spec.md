# ZeroTier 联机功能优化 Spec

## Why

当前 Amethyst-iOS-MyRemastered 的 ZeroTier 联机功能基于 zt.framework（zerotier-sockets-apple-framework）在进程内运行 ZeroTier 节点，配合 SOCKS5Proxy + PortForwarder 将 Minecraft 流量转发到虚拟网络。整体框架正确，但 `ZeroTierBridge` 的事件处理对 ZeroTier 的实际语义覆盖不全：

- 未处理 `ZTS_EVENT_NETWORK_CLIENT_TOO_OLD`（211）、`ZTS_EVENT_NETWORK_UPDATE`（219）、`ZTS_EVENT_PEER_DIRECT/RELAY/UNREACHABLE`（240-242）等关键事件
- 缺失 P2P 连接质量感知——ZeroTier 的核心优势是 P2P 直连，中继回退时延迟显著上升，但当前 UI 无法感知此差异
- `waitForNodeOnlineWithTimeout:` 容错逻辑过于宽泛——节点曾上线后即使当前 Offline 也直接返回 YES，可能导致 PortForwarder 启动后流量无法到达房主
- `waitForNetworkReady:timeout:` 混合 IPv4/IPv6 判断，对 Ad-hoc 网络（仅 IPv6）和标准网络（通常仅 IPv4）处理不精确
- 未暴露 `zts_net_get_name` / `zts_net_get_mtu` / `zts_net_get_type` / `zts_net_get_mac` 网络详情查询接口

优化参考：ShardLauncher-iOS 的事件处理覆盖、zerotier-sockets-apple-framework 官方 API 规范、FCL/ZL2 的联机状态机组织方式。

## What Changes

### 一、ZeroTierBridge 事件处理补全

1. **补全 `ZTS_EVENT_NETWORK_CLIENT_TOO_OLD`（211）**：libzt 版本过旧时立即通知 delegate `zeroTierNetworkJoinFailed:error:` 并附带明确错误信息，避免用户等待 30 秒超时。

2. **补全 `ZTS_EVENT_NETWORK_UPDATE`（219）**：网络配置更新（IP 变更、路由调整）时清除该网络的 IP 地址缓存，重新查询 IP 并通过 `zeroTierNetworkReady:ipv4:ipv6:` 通知 delegate，确保上层不显示过期 IP。

3. **补全 `ZTS_EVENT_PEER_DIRECT`（240）/ `ZTS_EVENT_PEER_RELAY`（241）/ `ZTS_EVENT_PEER_UNREACHABLE`（242）**：追踪到对端节点的连接模式（直连/中继/不可达），通过新增的 `zeroTierPeerConnectionModeChanged:forPeer:` 回调通知上层。ZeroTier P2P 直连与中继在延迟和带宽上差异显著，用户需要感知。

### 二、ZeroTierBridge 新增 Peer 状态追踪

4. **新增 `ZeroTierPeerConnectionMode` 枚举**：Unknown / Direct / Relay / Unreachable。

5. **新增 `_peerConnectionModes` 字典**：peerID → 连接模式枚举，受 `_lock` 保护，避免多线程竞争。`stopNode` 和 `ZTS_EVENT_NODE_DOWN` 时清理。

6. **新增 `peerConnectionModeForPeer:` 查询方法**：供上层查询指定 peer 的当前连接模式。

### 三、ZeroTierBridge 新增网络详情查询 API

7. **封装 `zts_net_get_name`**：`- (nullable NSString *)networkNameForNetwork:(uint64_t)networkID;`

8. **封装 `zts_net_get_mtu`**：`- (int)networkMTUForNetwork:(uint64_t)networkID;`

9. **封装 `zts_net_get_type`**：`- (int)networkTypeForNetwork:(uint64_t)networkID;`（0=私有，1=公开）

10. **封装 `zts_net_get_mac`**：`- (uint64_t)macAddressForNetwork:(uint64_t)networkID;`

### 四、连接等待逻辑优化

11. **优化 `waitForNodeOnlineWithTimeout:`**：
    - 节点从未上线（`!_hasBeenOnline`）：严格等待 `zts_node_is_online()==1`
    - 节点曾上线但当前离线（`_hasBeenOnline==YES && _nodeStatus==Offline`）：最多等待 10 秒内恢复 Online，超时则返回 NO
    - 节点正在启动（`_nodeStatus==Starting`）：继续等待直到 Online 或原始超时

12. **优化 `waitForNetworkReady:timeout:` 按网络类型区分**：
    - 标准网络（networkID 不以 "ff" 开头）：仅检查 `zts_addr_is_assigned(networkID, ZTS_AF_INET)==1`
    - Ad-hoc 网络（networkID 以 "ff" 开头）：仅检查 `zts_addr_is_assigned(networkID, ZTS_AF_INET6)==1`
    - 两者都要求 `zts_net_transport_is_ready(networkID)==1`

### 五、MultiplayerManager 增强

13. **新增 `multiplayerPeerConnectionModeChanged:` delegate 回调**：将 ZeroTierBridge 的 peer 模式变化转发给 ViewController，附带人类可读描述（"直连" / "中继" / "不可达"）。

14. **新增 `currentPeerConnectionMode` 只读属性**：供 UI 层查询当前连接模式。

15. **处理 `CLIENT_TOO_OLD` 错误**：在 `zeroTierNetworkJoinFailed:` 中识别此错误并附带明确信息通知 delegate。

16. **处理 `NETWORK_UPDATE` 触发后的 IP 刷新**：当 IP 变化时更新 `currentLocalIP` 和 `currentRoom.hostIP`。

## Impact

- 受影响规格：ZeroTier 联机功能
- 受影响代码：
  - [ZeroTierBridge.h](file:///d:/git/Airs/Amethyst-iOS-MyRemastered/Natives/ZeroTierBridge.h) — 新增枚举、delegate 方法、网络详情查询 API 声明
  - [ZeroTierBridge.m](file:///d:/git/Airs/Amethyst-iOS-MyRemastered/Natives/ZeroTierBridge.m) — 补全事件处理、实现新 API、优化等待逻辑
  - [MultiplayerManager.h](file:///d:/git/Airs/Amethyst-iOS-MyRemastered/Natives/MultiplayerManager.h) — 新增 delegate 方法、peer 连接模式属性
  - [MultiplayerManager.m](file:///d:/git/Airs/Amethyst-iOS-MyRemastered/Natives/MultiplayerManager.m) — 实现 peer 回调转发、错误处理、IP 刷新

## ADDED Requirements

### Requirement: P2P 连接模式感知

系统 SHALL 追踪当前 ZeroTier 虚拟网络中到对端节点的连接模式（直连 / 中继 / 不可达），并通过代理回调通知上层。

#### Scenario: P2P 直连建立
- **WHEN** ZeroTier 节点收到 `ZTS_EVENT_PEER_DIRECT` 事件
- **THEN** ZeroTierBridge 更新内部 peer 状态为 Direct，MultiplayerManager 通过 `multiplayerPeerConnectionModeChanged:` 回调通知 delegate（描述为"直连"）

#### Scenario: 回退到中继
- **WHEN** ZeroTier 节点收到 `ZTS_EVENT_PEER_RELAY` 事件
- **THEN** ZeroTierBridge 更新 peer 状态为 Relay，MultiplayerManager 通知 delegate 连接模式变为"中继"

#### Scenario: 对端不可达
- **WHEN** ZeroTier 节点收到 `ZTS_EVENT_PEER_UNREACHABLE` 事件
- **THEN** ZeroTierBridge 更新 peer 状态为 Unreachable，MultiplayerManager 通知 delegate 并提示可能需要检查 NAT/防火墙设置

### Requirement: 网络详情查询

系统 SHALL 提供查询当前已加入网络的详细信息（名称、MAC 地址、MTU、网络类型）的能力。

#### Scenario: 查询网络名称
- **WHEN** UI 层请求当前网络的名称
- **THEN** MultiplayerManager 通过 ZeroTierBridge 调用 `zts_net_get_name` 返回网络名称字符串

#### Scenario: 查询网络类型
- **WHEN** UI 层请求当前网络的类型（公开/私有）
- **THEN** MultiplayerManager 通过 ZeroTierBridge 调用 `zts_net_get_type` 返回网络类型（0=私有，1=公开）

### Requirement: 版本不兼容错误处理

系统 SHALL 在 ZeroTier 客户端版本过旧导致无法加入网络时，立即通知用户并提供明确的错误信息。

#### Scenario: 客户端版本过旧
- **WHEN** ZeroTierBridge 收到 `ZTS_EVENT_NETWORK_CLIENT_TOO_OLD` 事件
- **THEN** 立即通过 `zeroTierNetworkJoinFailed:error:` 通知 delegate，错误信息为"ZeroTier 版本过旧，请更新 zt.framework"

### Requirement: 网络配置更新处理

系统 SHALL 在收到 ZeroTier 网络配置更新事件时，刷新内部缓存的 IP 地址和网络状态。

#### Scenario: 网络配置更新
- **WHEN** ZeroTierBridge 收到 `ZTS_EVENT_NETWORK_UPDATE` 事件
- **THEN** 清除该网络的 IP 地址缓存，重新查询并通知 delegate `zeroTierNetworkReady:ipv4:ipv6:`

## MODIFIED Requirements

### Requirement: 节点上线等待逻辑

当前实现的 `waitForNodeOnlineWithTimeout:` 在 `_hasBeenOnline=YES` 且节点状态非 Stopped/Error 时直接返回 YES，即使节点当前处于 Offline 状态也视为可用。此逻辑过于宽泛：在节点真正离线期间继续后续流程（如启动 PortForwarder），端口转发启动后流量无法到达房主。

修改后：
- 节点首次上线（从未上线到上线）：严格等待 `zts_node_is_online() == 1`
- 节点掉线后自动重连（曾上线过）：允许在 Offline 状态最多等待 10 秒，若 10 秒内未恢复 Online 则返回失败
- 节点处于 Starting 状态（刚调用 zts_node_start）：继续等待直到 Online 或超时

### Requirement: 网络就绪等待逻辑

当前 `waitForNetworkReady:timeout:` 同时检查 IPv4 和 IPv6 地址分配（任一满足即认为就绪）。对于标准 ZeroTier 网络（通常只分配 IPv4），此逻辑正确；但对于 Ad-hoc 网络（只有 IPv6），检查 IPv4 是否分配是多余的且可能造成混淆。

修改后：
- 标准网络（networkID 不以 "ff" 开头）：仅检查 IPv4 地址分配（`zts_addr_is_assigned(netID, ZTS_AF_INET)`）
- Ad-hoc 网络（networkID 以 "ff" 开头）：仅检查 IPv6 地址分配（`zts_addr_is_assigned(netID, ZTS_AF_INET6)`）
- 两者都要求 `zts_net_transport_is_ready(netID) == 1`
