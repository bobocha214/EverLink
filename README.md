# EverLink

> 面向现场工控 / 物联网调试工程师的**多协议设备调试与网络诊断工具**，基于 Flutter 跨平台开发。

EverLink（"Ever Connected"）把现场最常用的多种工业通信协议、网络诊断能力和日常小工具集成到一个 App 中，帮助工程师在手机/平板上完成设备联调、报文抓看、网络排查与文件快传，无需随身携带笔记本。

---

## ✨ 功能特性

### 一、多协议设备调试
在「设备」页以卡片形式管理所有调试目标，支持**一键连接/断开**、状态汇总（在线 / 连接中 / 离线 / 异常）、按名称搜索、按协议类型与连接状态筛选、重命名与删除。

目前已内置五种协议调试面板：

| 协议 | 说明 |
| --- | --- |
| **Modbus TCP** | 寄存器/线圈读写、数据类型解析（INT16/UINT16/INT32/UINT32/FLOAT32/BCD）、字节序/字交换切换、定时轮询、原始 Hex 报文查看、日志导出 |
| **MQTT** | 3.1.1 / 5.0、TLS/SSL、用户名密码与证书认证、多主题订阅（`#`/`+` 通配符）、JSON 格式化高亮、消息历史与发布模板 |
| **OPC UA** | Endpoint 发现、安全策略协商（None/Basic256Sha256 等）、节点树浏览、订阅监控、变量读写、原始通信报文查看 |
| **WebSocket** | 基于 TCP 的双向长连接调试 |
| **HTTP** | 自定义请求头 / GET·POST，对接设备 HTTP 接口，调试模式可忽略证书 |

### 二、历史记录
「历史」页集中展示连接与操作流水（时间、协议、设备、操作、成功/失败、错误信息），便于事后复盘。

### 三、工具箱
「工具」页聚合一组零协议依赖、随时可用的独立工具：

- **快传**：同一 WiFi 下，通过网页 / 扫码在设备间互传文件、文字、图片。
- **剪贴板管理**：本地记录本机复制内容（含其他 App 在前台时的复制），可查看、复制与回溯。
- **网络诊断**：对目标主机执行 ICMP Ping，实时查看时延与丢包率。
- **网络调试**：TCP 客户端、端口扫描（含工控常用端口预置）、目标探测、局域网扫描、IP 子网计算。
- **进制工具**：二/八/十/十六进制互转、补码、字节视图、文本⇄Hex、CRC16-Modbus 校验计算。

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
- **本地优先**：会话、历史、剪贴板历史、设置等均持久化于本地（SharedPreferences / 文件系统），无需后端服务。

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
├── services/              # 连接管理、会话、历史、剪贴板、快传、网络等
└── ui/                    # 页面与组件（设备/历史/工具/我的 四大导航）
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

> 说明：`pubspec.yaml` 中的 `publish_to: 'none'` 仅用于阻止 `flutter pub publish` 误传到 pub.dev，不影响本仓库以 MIT 协议开源。
