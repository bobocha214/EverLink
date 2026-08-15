# EverLink

> 面向现场工控 / 物联网调试工程师的**多协议设备调试与网络诊断工具**，基于 Flutter 跨平台开发。

EverLink 把现场最常用的多种工业通信协议、网络诊断能力和日常小工具集成到一个 App 中，帮助工程师在手机/平板上完成设备联调、报文抓看、网络排查与文件快传，无需随身携带笔记本。

---

## ✨ 功能特性

### 一、多协议设备调试
在「设备」页以卡片形式管理所有调试目标，支持**一键连接/断开**、状态汇总（在线 / 连接中 / 离线 / 异常）、按名称搜索、按协议类型与连接状态筛选、重命名与删除。

目前已内置五种协议调试面板：

| 协议 | 说明 |
| --- | --- |
| **Modbus TCP** | 寄存器/线圈读写、数据类型解析（INT16/UINT16/INT32/UINT32/FLOAT32/BCD）、字节序/字交换切换、定时轮询、原始 Hex 报文查看、日志导出 |
| **MQTT（客户端）** | 作为**客户端**连接外部 Broker：3.1.1 / 5.0、TLS/SSL、用户名密码与证书认证、多主题订阅（`#`/`+` 通配符）、JSON 格式化高亮、消息历史与发布模板。注意与「工具箱·服务模拟」里的 **MQTT Broker（服务端）** 区分——前者是去连别人的 Broker，后者是让**本机充当** Broker 供其他设备连接 |
| **OPC UA** | Endpoint 发现、安全策略协商（None/Basic256Sha256 等）、节点树浏览、订阅监控、变量读写、原始通信报文查看 |
| **WebSocket** | 基于 TCP 的双向长连接调试 |
| **HTTP** | 自定义请求头 / GET·POST，对接设备 HTTP 接口，调试模式可忽略证书 |

### 二、历史记录
「历史」页集中展示连接与操作流水（时间、协议、设备、操作、成功/失败、错误信息），便于事后复盘。

### 三、工具箱
「工具」页聚合一组零协议依赖、随时可用的独立工具：

- **快传**：同一 WiFi 下，通过网页 / 扫码在设备间互传文件、文字、图片。支持**选择对外 IP**（多网卡时指定具体网卡或「全部接口」），二维码展示界面内可直接切换对外地址；所选 IP 会被记住，下次启动自动应用。
- **服务模拟**：把手机 / 平板当作各类协议服务端，便于现场联调（**退出页面后仍在后台运行**，停止由各页面「停止」按钮触发；运行参数为常驻单例，重新进入自动恢复端口、IP、客户端列表等状态）：
  - **TCP 服务端**：监听指定端口，多客户端并发连接，支持广播或定向转发、HEX / ASCII 收发（HEX / ASCII 偏好持久化，ASCII 可开启 JSON 格式化开关）、附加校验（CRC16-Modbus / 累加和 / 异或）；可指定监听 IP（多网卡时选择）。
  - **OPC UA 服务端**：基于 `mcp_io_opcua` 二进制协议实现，支持**自定义节点与数量**（命名空间索引 / NodeId / 显示名 / 值类型 / 值，编辑后持久化保存），客户端可 Read / Write / Browse；可指定监听 IP。
  - **MQTT Broker**：纯 `dart:io` 实现的最小 MQTT 3.1.1 服务端，支持 CONNECT / SUBSCRIBE / PUBLISH（QoS0/1）、主题通配符（`+` / `#`）、保留消息（Retained）；可指定监听 IP。
  - **MQTT 发布模拟**：基于 `mqtt_client` 连接外部 Broker，按主题模板（支持 `{i}` 占位）/ 数量 / 间隔循环发布模拟数据，验证订阅端消费逻辑。
- **剪贴板管理**：本地记录本机复制内容（含其他 App 在前台时的复制），可查看、复制与回溯。
- **网络诊断**：对目标主机执行 ICMP Ping，实时查看时延与丢包率。
- **网络调试**：TCP 客户端、端口扫描（含工控常用端口预置）、目标探测、局域网扫描、IP 子网计算。
- **进制工具**：二/八/十/十六进制互转、补码、字节视图、文本⇄Hex、CRC16-Modbus 校验计算。

> **⚠️ 容易混淆：MQTT 客户端 vs MQTT Broker（服务端）**
> 本 App 有两处都涉及 MQTT，角色完全不同：
> - **「设备调试 · MQTT（客户端）」**：你是**客户端**，去连车间里现成的 MQTT Broker（如 EMQX、云 MQTT），订阅/发布它的主题。
> - **「工具箱 · 服务模拟 · MQTT Broker（服务端）」**：你让**手机/平板自己当 Broker**，现场没有现成 Broker 时，先用它把局域网消息中枢搭起来，再让其他设备来连。
> - **「工具箱 · 服务模拟 · MQTT 发布模拟」**：又是**客户端**，但它专门用来连某个 Broker（可以是外部 Broker，也可以是上面那条本机 Broker）并按模板循环发数据，方便验证订阅端逻辑。

#### 服务模拟使用场景

**场景 A：现场没有 Broker，临时搭一个**
1. 工具箱 → 服务模拟 → **MQTT Broker**，监听端口默认 1883，监听 IP 选「全部接口」或具体网卡，点「启动」。
2. 画面提示「连接地址：`192.168.1.50:1883`」。把该地址（或扫局域网设备的连接二维码）发给同事的 PLC / 网关 / 上位机，让它们连这个 Broker 发布与订阅。
3. 你再用「设备调试 · MQTT（客户端）」连同一个地址，即可在手机上直接看到现场所有报文，无需额外笔记本。
4. 退出服务模拟页面去干别的，**Broker 仍在后台运行**；回来页面自动显示「监听中」与已连接的客户端列表。

**场景 B：用本机 Broker 做发布/订阅自测**
1. 先按场景 A 启动本机 MQTT Broker。
2. 工具箱 → 服务模拟 → **MQTT 发布模拟**，Broker 地址填 `tcp://192.168.1.50:1883`（即本机 Broker 的地址），主题模板 `factory/sensor/{i}`、数量 5、间隔 1s，点「开始」。
3. 用「设备调试 · MQTT（客户端）」订阅 `factory/sensor/#`，即可实时收到 5 路模拟传感器数据，验证解析与展示逻辑。

**场景 C：把手机当 TCP 调试网关**
1. 工具箱 → 服务模拟 → **TCP 服务端**，监听端口（如 5020），勾选「收到数据转发给其他客户端」。
2. 现场两台设备（如扫码枪 + 上位机）都连 `ip:5020`，其中一台发的数据会被服务端**广播**给其余客户端，实现透明中转。
3. 发送区可选 HEX 或 ASCII（ASCII 开启 JSON 格式化便于查看结构化报文），并附加 CRC16-Modbus / 累加和 / 异或校验。

**场景 D：用 OPC UA 服务端给客户端做离线联调**
1. 工具箱 → 服务模拟 → **OPC UA 服务端**，点「编辑节点」增删节点、设命名空间索引 / NodeId / 类型 / 初始值（如把 `ns=2;s=Temperature` 设成 Double 类型）。节点配置会**持久化保存**。
2. 监听 IP 选合适网卡，点「启动」，把连接地址给上位机或测试脚本。
3. 对方用任意 OPC UA 客户端 Read / Write / Browse 这些自定义节点；你改过的值即便退出页面重进也还在（节点持久化）。

> 以上四类 server（TCP / OPC UA / MQTT Broker / MQTT 发布模拟）均由 `ServerRegistry` 单例常驻，退出页面不停止、重新进入自动恢复，适合「搭好就丢一边」的现场长时间联调。

### 四、个性化
「我的」页支持浅色 / 深色 / 跟随系统主题切换、关于与设置等。

---

## 🧱 技术架构

项目采用分层设计，降低各协议模块之间的耦合：

```
协议层 (Modbus / MQTT / OPC UA / HTTP / TCP·UDP / WebSocket)
   ↓
会话 / 连接管理层 (ConnectionManager · SessionManager)
   ↓
采集与解析层 (数据点位、寄存器解析、JSON 处理)
   ↓
可视化 / 存储层 (趋势曲线、历史记录、本地持久化)
   ↓
工具层 / 配置层 (快传、网络诊断、进制工具、连接模板)
```

- **配置驱动**：所有协议的连接参数统一抽象为「连接配置模型」，由 `ProtocolRegistry` 注册并复用，新增协议只需在枚举 `ProtocolType` 中追加一项并实现 `DeviceProtocol`。
- **异步优先**：阻塞式协议操作（Socket、TLS 握手、定时轮询）跑在独立 isolate / 后台线程，UI 仅消费流式数据，避免 ANR。
- **本地优先**：会话、历史、剪贴板历史、设置、OPC UA 节点、快传对外 IP 等均持久化于本地（SharedPreferences / 文件系统），无需后端服务。
- **常驻服务**：服务模拟（TCP / OPC UA / MQTT Broker / MQTT 发布器）由 `ServerRegistry` 单例在应用生命周期内持有，页面仅订阅与控制、不在 `dispose` 销毁，因此退出页面后服务继续后台运行；需要时由页面「停止」按钮显式停止。

---

## 📦 主要依赖

| 分类 | 包 |
| --- | --- |
| 框架 | `flutter` / `dart` (SDK `^3.12.1`) |
| Modbus | `modbus_client` · `modbus_client_tcp` |
| MQTT | `mqtt_client` |
| OPC UA | `mcp_io_opcua` |
| 网络信息 | `network_info_plus` |
| 浏览器/网页 | `webview_flutter` · `url_launcher` |
| 文件/媒体 | `file_picker` · `saver_gallery` |
| 二维码 | `qr_flutter` |
| 剪贴板 | `clipboard_watcher` |
| 存储 | `shared_preferences` · `path_provider` |
| 应用信息 | `package_info_plus` |

---

## 🗂️ 目录结构（核心）

```
lib/
├── main.dart              # 应用入口，初始化各 Service
├── models/                # 连接配置、设备会话、各协议数据模型
├── protocols/             # 协议抽象、注册表与各协议实现
├── services/              # 连接管理、会话、历史、剪贴板、快传、网络、服务模拟等
│   ├── server_registry.dart   # 服务模拟常驻单例（TCP/OPC UA/MQTT Broker/发布器）
│   ├── tcp_server.dart        # TCP 服务端
│   ├── opcua_server.dart      # OPC UA 服务端
│   ├── opcua_nodes_store.dart # OPC UA 节点持久化
│   ├── mqtt_broker.dart       # MQTT Broker 服务端
│   ├── mqtt_publisher.dart    # MQTT 发布模拟器
│   └── lan_transfer/          # 快传（HTTP 服务 + 设备发现 + 状态管理）
└── ui/                    # 页面与组件（设备/历史/工具/我的 四大导航）
    └── server_sim_page.dart   # 服务模拟目录页（4 张卡片）
```

---

## 🚀 开始使用 / 构建

### 环境要求
- Flutter SDK（建议与 `pubspec.yaml` 中 `environment.sdk: ^3.12.1` 匹配的稳定版）
- 目标平台工具链：Android SDK / Xcode（iOS）/ 对应桌面或 Web 环境

### 安装与运行
```bash
# 1. 拉取依赖
flutter pub get

# 2. 静态检查（可选）
flutter analyze

# 3. 运行（以 Android 为例）
flutter run

# 4. 构建发布包
flutter build apk        # Android
flutter build ios        # iOS（需在 macOS 执行）
```

> 注：部分第三方插件（如 `clipboard_watcher`）对 `compileSdk` 与 Java/Kotlin 目标版本有特定要求，构建遇到 JVM target 或 compileSdk 报错时，请确认本地 Android SDK platform 版本并按工程根 `build.gradle.kts` 的兜底配置调整。

---

## 📝 设计背景

完整的产品模块拆解与设计说明见 [`docs/industrial_iot_tool_design.md`](docs/industrial_iot_tool_design.md)，涵盖多协议调试、网络诊断、数据记录仪、可视化、局域网快传增强等规划，可作为功能演进路线图参考。

---

## 📄 许可证

本项目采用 **MIT License** 开源授权。

- 版权所有 © 2026 niangao
- 完整条款见仓库根目录的 [`LICENSE`](LICENSE) 文件。
