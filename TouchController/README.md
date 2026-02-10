# TouchController static library

## Description

### This location is where the static library is stored for communication between this launcher and the TouchController Mod.

#### What is the use of static libraries?

 - Enable direct communication between the launcher and the TouchController Mod through Unix strings to achieve touch control operations

#### What is the difference between static library communication and traditional UDP communication?

 - Reduce latency: from ≤1000ms to ≈2ms (theoretically)
 - Higher performance: Communication with Mods without requiring local UDP proxy
 - More stable
 - . ..

### How to Use

 1. Copy the original iOS static library (libproxy_server_ios.a) to this location
 2. Copy the iOS simulator static library (libproxy_server_ios_simulator.a) to this location (optional)
 3. Normally trigger the Workflow to proceed with the build

---

# TouchController 静态库

## 说明

### 此位置是存储该启动器与 TouchController(触摸控制器) Mod 进行通信用的静态库的位置。

#### 静态库有什么用？

 - 让启动器与 TouchController Mod 通过 Unix 字符串直接通信，实现触控操作
 
#### 静态库通信与传统 UDP 通信有什么区别？

 - 降低延迟：从 ≤1000ms 缩短到 ≈2ms (理论上)
 - 更高性能：无需进行本地 UDP 代理即可与 Mod 通信
 - 更加稳定
 - ...
 
### 如何使用

 1. 将原版 iOS 静态库（libproxy_server_ios.a) 复制到此处
 2. 将 iOS 模拟器静态库（libproxy_server_ios_simulator.a) 复制到此处 (可选)
 3. 正常触发 Workflow 进行构建
