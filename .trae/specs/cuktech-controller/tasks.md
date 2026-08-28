# 酷态科（CUKTECH）10号超级电能充 Ultra 控制软件 - The Implementation Plan

## 阶段 0：基础设施与仓库初始化

### [x] Task 0.1：仓库脚手架与目录结构
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 在 GitHub 仓库 `ABI-ZTROS/ZTR_OS-CukTeck-Controler` 初始化 Flutter 工程（Android 端）与 C# WPF 工程（Windows 端）
  - 建立根目录结构：`android_app/`（Flutter）、`windows_app/`（C# WPF）、`.github/workflows/`（CI）、`docs/`
  - Flutter 工程内按 `ble/`、`protocol/`、`ui/`、`utils/` 四目录拆分
  - 添加 `analysis_options.yaml`（strict lint）与 `.gitignore`
  - 添加 `README.md`（工程总览 + 编译指引）
- **Acceptance Criteria Addressed**: AC-11, AC-12
- **Test Requirements**:
  - `programmatic` TR-0.1.1: `flutter analyze` 通过；`dotnet build windows_app/` 成功
  - `human-judgement` TR-0.1.2: 文件结构符合四目录拆分规范，单文件 ≤ 300 行

### [x] Task 0.2：GitHub Actions 构建流水线
- **Priority**: high
- **Depends On**: 0.1
- **Description**:
  - `.github/workflows/android.yml`: `ubuntu-latest` + Java 17 + Flutter stable，构建 `apk/app-release.apk`（使用 debug keystore）
  - `.github/workflows/windows.yml`: `windows-latest` + .NET 8 SDK，`dotnet publish -c Release -r win-x64 --self-contained`
  - `.github/workflows/lint.yml`: `flutter analyze` 与 `dotnet format --verify-no-changes`
  - 使用 `actions/upload-artifact` 归档产物
- **Acceptance Criteria Addressed**: AC-11
- **Test Requirements**:
  - `programmatic` TR-0.2.1: 推送到 `main` 分支后两个 workflow 均成功完成
  - `programmatic` TR-0.2.2: APK 与 EXE 产物可下载、版本号正确

---

## 阶段 1：Token 提取模块（Android 专属）

### [x] Task 1.1：Root 权限检测与 Shell 执行通道
- **Priority**: high
- **Depends On**: 0.1
- **Description**:
  - Kotlin 实现 `RootShell.kt`，通过 `Runtime.getRuntime().exec("su")` 开启 root shell，支持白名单命令（仅允许 `sqlite3`、`cp`、`chmod`）
  - Flutter MethodChannel `root_channel`：`checkRoot`、`runCommand`
  - 权限不足时 UI 显示 "未获取 Root 权限，请先 Root 设备"
- **Acceptance Criteria Addressed**: AC-1
- **Test Requirements**:
  - `programmatic` TR-1.1.1: 在已 Root 设备上 `checkRoot` 返回 `true`；未 Root 时返回 `false`
  - `programmatic` TR-1.1.2: `runCommand` 执行白名单命令成功，非白名单命令被拒绝

### [x] Task 1.2：miio2.db 解析
- **Priority**: high
- **Depends On**: 1.1
- **Description**:
  - Kotlin 实现 `MiiDbReader.kt`：通过 root 执行 `sqlite3 /data/data/com.xiaomi.smarthome/databases/miio2.db "select * from devices;"`
  - 解析 Cursor 提取 `did`、`model`、`token`、`mac` 字段
  - 处理文件不存在、数据库损坏、表结构变化等异常
  - Flutter 侧 `TokenRepository.dart` 在 `protocol/` 目录下定义数据模型
- **Acceptance Criteria Addressed**: AC-1
- **Test Requirements**:
  - `programmatic` TR-1.2.1: 解析出的 Token 为 32 位十六进制字符串
  - `programmatic` TR-1.2.2: 数据库不存在时返回特定错误码 `DB_NOT_FOUND`

### [x] Task 1.3：Token 安全存储与设备选择 UI
- **Priority**: high
- **Depends On**: 1.2
- **Description**:
  - 使用 `flutter_secure_storage` AES-256 加密保存 Token/Key/MAC
  - `ui/token/token_import_page.dart` 展示本地设备列表 + 手动输入
  - 未连接时 UI 显示 `--` 占位；禁止 Mock 数据
- **Acceptance Criteria Addressed**: AC-1, AC-8
- **Test Requirements**:
  - `human-judgement` TR-1.3.1: 导入流程清晰，失败提示具体
  - `programmatic` TR-1.3.2: App 重启后 Token 仍可读取

### [x] Task 1.4：米家云 API 回退登录
- **Priority**: medium
- **Depends On**: 1.2
- **Description**:
  - Dart 移植 `xiaomi_cloud.py` 核心逻辑：RC4 加解密、签名、QR 码长轮询、账号密码登录
  - `utils/xiaomi_cloud/` 目录：`cloud_client.dart`、`qr_login.dart`、`models.dart`
  - 本地 DB 读取失败时 UI 自动提示 "云端登录" 选项
  - 注意：参考项目未覆盖验证码/滑块；出现时直接报错 `TODO: 待抓包补充`
- **Acceptance Criteria Addressed**: AC-1
- **Test Requirements**:
  - `programmatic` TR-1.4.1: 有效账号密码能通过 RC4 登录获取 serviceToken
  - `programmatic` TR-1.4.2: `blt_get_beaconkey` 返回 32 位 Token

---

## 阶段 2：BLE 核心通信

### [x] Task 2.1：Android BLE 扫描与连接
- **Priority**: high
- **Depends On**: 0.1
- **Description**:
  - `ble/android_scanner.dart` 封装 `flutter_blue_plus` 扫描，按 `0xFE95` 服务 UUID 过滤
  - `ble/android_connector.dart`：连接 + MTU 协商 + 5 个通道订阅
  - 超时 5 秒 + 3 次重试，失败抛出 `BleTimeoutException`
  - 详细 `Logger` 输出到 Logcat
- **Acceptance Criteria Addressed**: AC-2, AC-9
- **Test Requirements**:
  - `programmatic` TR-2.1.1: 10 秒内能扫描到目标设备
  - `programmatic` TR-2.1.2: 3 次重试均失败后 UI 收到错误回调

### [x] Task 2.2：Windows BLE 扫描与连接
- **Priority**: high
- **Depends On**: 0.1
- **Description**:
  - C# `ble/WindowsScanner.cs`：`BluetoothLEDevice.FromBluetoothAddressAsync` + `AdvertisementWatcher`
  - C# `ble/WindowsConnector.cs`：连接 + `GattDeviceService` 发现 + 5 特征订阅
  - 同样的 5 秒超时 + 3 次重试策略，日志输出到 `Debug.WriteLine` + 文件
- **Acceptance Criteria Addressed**: AC-10, AC-9
- **Test Requirements**:
  - `programmatic` TR-2.2.1: Windows 10/11 上可扫描到设备
  - `programmatic` TR-2.2.2: 通道订阅顺序与 Android 对齐

### [x] Task 2.3：协议常量与帧格式定义（Dart + C#）
- **Priority**: high
- **Depends On**: 0.1
- **Description**:
  - Dart `protocol/constants.dart`：GATT UUID、Handle、PIID 映射、端口位掩码、协议枚举（完整移植自 `protocol.py`）
  - C# `protocol/ProtocolConstants.cs`：完全对齐
  - Dart `protocol/miot_tlv.dart`：`buildMiotTlv` / `parseMiotResponse`
  - C# `protocol/MiotTlv.cs`：对等实现
  - 未找到的字段标注 `TODO: 待抓包补充`
- **Acceptance Criteria Addressed**: AC-12
- **Test Requirements**:
  - `programmatic` TR-2.3.1: Dart 与 C# 常量逐项对照一致
  - `programmatic` TR-2.3.2: TLV 编码/解码与参考项目 Python 实现 bit-exact 一致（单元测试用例）

### [x] Task 2.4：MiOT 认证流程（Dart + C#）
- **Priority**: high
- **Depends On**: 2.3
- **Description**:
  - Dart `protocol/authenticator.dart`：完整移植 `_try_authenticate` 逻辑（Phase A + Phase B + 第二轮 challenge-response）
  - C# `protocol/Authenticator.cs`：对等实现（`System.Security.Cryptography.HKDF` + `AesCcm`）
  - 会话密钥派生：HKDF-SHA256，info=`mible-login-info`，64 字节
  - HMAC 双向验证，nonce 拼接规则与参考项目完全一致
  - 状态机清晰（`init`→`keyExch`→`login`→`hmacVerify`→`challenge`→`done`）
- **Acceptance Criteria Addressed**: AC-3
- **Test Requirements**:
  - `programmatic` TR-2.4.1: 有效 Token 下认证成功率 100%（至少 3 次真机验证）
  - `programmatic` TR-2.4.2: 无效 Token 下正确识别并返回 `AUTH_FAILED_TOKEN`
  - `human-judgement` TR-2.4.3: 状态机日志分步骤清晰

### [x] Task 2.5：AES-CCM 加解密通道
- **Priority**: high
- **Depends On**: 2.4
- **Description**:
  - Dart `protocol/crypto.dart`：`encrypt` / `decrypt`，严格对齐参考项目 `_encrypt` / `decrypt`
  - C# `protocol/Crypto.cs`：对等实现，注意 `tag_length=4`
  - 设备计数器 `dev_it_hi` 溢出跟踪
  - `ble/encrypted_channel.dart`：`sendEncrypted` / `waitResponse` + RCV_RDY/RCV_OK 握手
- **Acceptance Criteria Addressed**: AC-3, AC-9
- **Test Requirements**:
  - `programmatic` TR-2.5.1: 加解密与 Python 参考实现对同一明文得到相同密文
  - `programmatic` TR-2.5.2: 计数器溢出（>65535）不丢包

### [x] Task 2.6：实时端口广播解析
- **Priority**: high
- **Depends On**: 2.5
- **Description**:
  - Dart `protocol/port_decoder.dart`：移植 `decode_port`（V2 协议检测引擎，来自 `state_protocol_v2.py`）
  - C# `protocol/PortDecoder.cs`：对等实现
  - 解析 PIID 1-4 广播的电压/电流/功率/协议/PDO 能力
  - `ble/port_stream.dart`：提供 `Stream<PortState>`，按端口分 4 路广播
  - 内联帧（`0x02`）与多帧（`0x00`）处理
- **Acceptance Criteria Addressed**: AC-4
- **Test Requirements**:
  - `programmatic` TR-2.6.1: 有负载时端口数据刷新率 ≥ 5Hz
  - `human-judgement` TR-2.6.2: 电压/电流读数与充电器屏幕一致（±0.1V/±0.1A）

---

## 阶段 3：控制逻辑

### [x] Task 3.1：单口开关控制（PIID 16）
- **Priority**: high
- **Depends On**: 2.5
- **Description**:
  - Dart `protocol/port_control.dart`：`setPort(port, on)` 读-改-写 + 回读验证
  - C# `protocol/PortControl.cs`：对等
  - 使用 `PORT_BITS` 位掩码，支持 `c1`/`c2`/`c3`/`a`/`all`
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `programmatic` TR-3.1.1: 切换后 2 秒内回读状态一致
  - `human-judgement` TR-3.1.2: 物理端口 LED 与 UI 状态同步

### [x] Task 3.2：协议开关控制（PIID 21）
- **Priority**: high
- **Depends On**: 2.5
- **Description**:
  - Dart `protocol/protocol_switch.dart`：`encodeProtocolExtend` / `parseProtocolSwitches`
  - C# 对等实现
  - 位映射对齐参考项目 `PROTOCOL_SWITCH_BITS`：c1[pd=0,pps=1,ufcs=2,reserved=3]、c2[pd=8,pps=9,ufcs=10,reserved=11]、c3[ufcs=16,scp=17]、a[ufcs=24,scp=25]
- **Acceptance Criteria Addressed**: AC-6
- **Test Requirements**:
  - `programmatic` TR-3.2.1: 编码/解码与参考项目 bit-exact 一致
  - `programmatic` TR-3.2.2: 写回后回读一致

### [x] Task 3.3：倒计时与场景/息屏等设置
- **Priority**: medium
- **Depends On**: 2.5
- **Description**:
  - `protocol/settings.dart`：封装 PIID 5/6/8/9-12/13/15/19/20 的读写
  - 所有写操作附带回读验证
  - C# 对等实现
- **Acceptance Criteria Addressed**: AC-7
- **Test Requirements**:
  - `programmatic` TR-3.3.1: 设置 30 分钟倒计时后回读为 30
  - `programmatic` TR-3.3.2: 场景模式四种切换正确

---

## 阶段 4：UI 实现（Android + Windows 双端）

### [x] Task 4.1：Android Flutter 主页与端口卡片
- **Priority**: high
- **Depends On**: 2.6, 3.1
- **Description**:
  - `ui/pages/home_page.dart`：Scaffold + 4 端口卡片组件 `PortCard`
  - `ui/widgets/port_card.dart`：未连接显示 `--` + "未连接" 标签
  - `ui/widgets/status_banner.dart`：连接进度分步骤提示
  - `ui/theme/app_theme.dart`：深色模式优先（对齐参考项目深色素材）
- **Acceptance Criteria Addressed**: AC-4, AC-8
- **Test Requirements**:
  - `human-judgement` TR-4.1.1: 视觉与参考项目 Web UI 风格一致
  - `programmatic` TR-4.1.2: 未连接状态所有动态值为 `--`

### [x] Task 4.2：Android 端口控制与设置页
- **Priority**: high
- **Depends On**: 3.1, 3.2, 3.3
- **Description**:
  - `ui/pages/port_control_page.dart`：单口开关 + 协议开关（复选框）+ 倒计时输入
  - `ui/pages/settings_page.dart`：场景/息屏/语言/USB-A/空闲息屏/屏幕方向
  - `ui/pages/device_info_page.dart`：MAC、固件、型号、Token 管理
  - `ui/pages/log_page.dart`：BLE 报文 Hex 日志查看器
- **Acceptance Criteria Addressed**: AC-5, AC-6, AC-7
- **Test Requirements**:
  - `human-judgement` TR-4.2.1: 所有控件交互流畅
  - `programmatic` TR-4.2.2: 每次操作触发 BLE 命令均有日志

### [x] Task 4.3：Windows WPF 主窗口
- **Priority**: high
- **Depends On**: 2.2, 2.6, 3.1
- **Description**:
  - `windows_app/MainWindow.xaml`：MVVM + 多列布局 + 4 端口卡片
  - `windows_app/ViewModels/MainViewModel.cs`：端口数据 + 命令
  - `windows_app/Views/PortControlView.xaml`、`SettingsView.xaml`、`LogView.xaml`
  - 支持保存多个充电器配置，启动自动重连
- **Acceptance Criteria Addressed**: AC-10
- **Test Requirements**:
  - `human-judgement` TR-4.3.1: 界面布局合理
  - `programmatic` TR-4.3.2: 操作响应 ≤ 300ms

### [x] Task 4.4：Windows 实时曲线与日志
- **Priority**: medium
- **Depends On**: 4.3
- **Description**:
  - 嵌入 `OxyPlot` 或 LiveCharts 实现 PowerChart（对齐参考项目 `power_chart.html`）
  - `LogView` 实时显示 BLE 报文（Hex 视图，可保存导出）
- **Acceptance Criteria Addressed**: AC-10, NFR-5
- **Test Requirements**:
  - `human-judgement` TR-4.4.1: 曲线流畅、缩放可用

---

## 阶段 5：健壮性与自检

### [x] Task 5.1：全局错误处理与日志系统
- **Priority**: high
- **Depends On**: 2.1-2.6
- **Description**:
  - Dart `utils/logger/logger.dart`：封装 `Logger`，输出到 Logcat + 文件
  - C# `utils/Logger.cs`：封装 `Debug.WriteLine` + 文件轮转
  - 全局 `FlutterError.onError` / `PlatformDispatcher.onError` 捕获未捕获异常
  - 所有 Stream 在 `dispose` 时 `.cancel()`
- **Acceptance Criteria Addressed**: AC-12, NFR-5
- **Test Requirements**:
  - `programmatic` TR-5.1.1: 模拟异常不崩溃、有日志记录
  - `programmatic` TR-5.1.2: 退出时所有 Stream 正确释放（无 warning）

### [x] Task 5.2：仓库 README 与用户文档
- **Priority**: low
- **Depends On**: 0.1
- **Description**:
  - 安装指引：Root、米家 App 降级、Windows 蓝牙要求
  - Token 提取教程 + 截图
  - 常见问题（FAQ）
- **Acceptance Criteria Addressed**: AC-11
- **Test Requirements**:
  - `human-judgement` TR-5.2.1: 新手能按文档完成首次连接

### [x] Task 5.3：CI 静态分析与产物发布
- **Priority**: high
- **Depends On**: 0.2, 5.1
- **Description**:
  - `flutter analyze` / `dotnet format --verify-no-changes` / `dotnet test`
  - 产物归档：APK + EXE + 符号表
  - Release tag 自动触发 GitHub Release
- **Acceptance Criteria Addressed**: AC-11
- **Test Requirements**:
  - `programmatic` TR-5.3.1: `main` 分支每次推送均构建成功
  - `programmatic` TR-5.3.2: Release 页面产物齐全

---

## 任务优先级与依赖拓扑

```
0.1 ─► 0.2
  │      │
  ├──► 1.1 (Root) ─► 1.2 (DB) ─► 1.3 (UI) / 1.4 (云回退)
  │
  ├──► 2.1 (Android BLE) ─► 2.3 (协议常量) ─► 2.4 (认证) ─► 2.5 (加密通道) ─► 2.6 (端口广播)
  │                                                                                              │
  ├──► 2.2 (Windows BLE) ─► 2.3 ─► 2.4 ─► 2.5 ─► 2.6                                          │
  │                                                                                              │
  └──► 3.1 (单口开关) / 3.2 (协议开关) / 3.3 (设置) ◄─────────────────────────────────────────────┘
                │
                ├──► 4.1 (主页) ─► 4.2 (控制页)
                │
                └──► 4.3 (Win 主窗) ─► 4.4 (Win 曲线)
                                       │
                                       └──► 5.1 (日志) ─► 5.2 (文档) ─► 5.3 (CI)
```

**执行顺序**：0.1 → 0.2 → 1.1 → 1.2 → 1.3 → 1.4 → 2.1 → 2.2 → 2.3 → 2.4 → 2.5 → 2.6 → 3.1 → 3.2 → 3.3 → 4.1 → 4.2 → 4.3 → 4.4 → 5.1 → 5.2 → 5.3

Android 与 Windows 的 BLE 实现（2.1/2.2）可并行开发；协议常量（2.3）必须先于两端的认证实现。
