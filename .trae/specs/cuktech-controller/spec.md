# 酷态科（CUKTECH）10号超级电能充 Ultra 控制软件 - Product Requirement Document

## Overview
- **Summary**: 开发一套完整的酷态科（CUKTECH）10号超级电能充 Ultra 控制软件，包含 Android 手机 APP（一加手机，通过 Root 权限读取米家 Token）与 Windows 桌面 EXE（C# WPF）双端实现。两端均直连充电器 BLE，完全脱离米家 App，所有 BLE 通讯协议、加密解密、指令帧格式严格参照开源项目 `kairui1108/cuktech-ble-ha` 的 `/src` 源码。
- **Purpose**: 解决用户绕开米家 App 直接控制酷态科 10 号充电器的需求，实现读取实时电压/电流/功率、控制端口开关、协议开关（PD/UFCS/SCP）、倒计时关闭等功能。
- **Target Users**: 拥有酷态科 10 号 GaN Super Charger Ultra（型号 AD1204U）、一加/小米系 Rooted 手机、Windows PC 的高级玩家与开发者。

## Goals
- 在 Android 手机上通过 Root 权限读取 `miio2.db` 获取目标设备 32 位 Token，提取失败时回退米家云 API（RC4 加密登录 + beaconkey 接口）
- 在 Android 端通过 `flutter_blue_plus` 完成 BLE 扫描、连接、MiOT 认证（HKDF+AES-CCM）、实时端口数据订阅、属性读写
- 在 Windows 端通过 C# WPF + `Windows.Devices.Bluetooth` 完成与 Android 对等的 BLE 功能
- 实现充电器完整控制：单口开关（PIID 16 位掩码）、协议控制（PIID 21 位掩码，PD/PPS/UFCS/SCP）、倒计时设置（PIID 8-12）、场景模式（PIID 5）、息屏时间（PIID 6）等
- 代码严格按 `ble/`、`protocol/`、`ui/`、`utils/` 四目录拆分；单文件 ≤ 300 行
- 所有 BLE 读写操作具备 5 秒超时 + 3 次重试机制，输出详细日志
- UI 未连接时显示 "未连接/搜索中"，电压电流等数值初始显示 `--`；禁止使用 Mock 数据
- 通过 GitHub Actions 实现 CI 编译（Android APK + Windows EXE），不依赖本地编译

## Non-Goals (Out of Scope)
- 不实现 iOS 客户端
- 不实现云端/局域网 Web Server 模式（参考项目中的 Home Assistant 集成不在本项目范围内）
- 不实现固件 OTA 升级
- 不实现米家场景自动化联动（Home Assistant 自定义组件）
- 不负责破解或绕过米家账号体系的加密；仅使用官方公开协议
- 不保证酷态科所有型号充电器都兼容（仅支持 10 号 Ultra / AD1204U）

## Background & Context
- **参考项目**: `kairui1108/cuktech-ble-ha`（MIT License），该项目完整实现了 Python 版 BLE 直连控制。本项目将其协议层移植为 Dart（Android）与 C#（Windows）。
- **关键协议细节**（摘自参考项目源码）：
  - GATT Service `0xFE95` 下的特征：`0x001c`（设备信息）、`0x0010`（认证控制）、`0x0019`（认证数据）、`0x001a`（命令发送）、`0x001b`（命令接收）
  - 认证：Phase A `0xa4` 设备初始化 → Phase B `CMD_LOGIN=0x24` + HKDF-SHA256 派生 64 字节会话密钥（`dev_key`/`app_key` 各 16B + `dev_iv`/`app_iv` 各 4B）+ 双向 HMAC 验证 + 第二轮 challenge-response
  - 加解密：AES-CCM（tag_length=4），nonce = `iv(4) + zeros(4) + counter(4)`
  - MiOT TLV：`[tot_len][0x20][seq][0x00][opcode][cnt][siid][piid_LE][tl_LE][value]`
- **技术栈选择**（经用户确认）：
  - Android：Flutter 3.x + `flutter_blue_plus` + Kotlin MethodChannel（Root/shell 执行）
  - Windows：C# WPF（`.NET 8`）+ `Windows.Devices.Bluetooth`
  - CI：GitHub Actions（`ubuntu-latest` 编译 Android，`windows-latest` 编译 Windows）

## Functional Requirements

### FR-1：Token 提取模块（Android）
- **FR-1.1**: Android App 首次启动时检测 Root 权限；无 Root 时提示降级米家 App 版本（需 ≤ 8.7 左右以保留明文 Token）
- **FR-1.2**: 通过 `su` + `sqlite3` 读取 `/data/data/com.xiaomi.smarthome/databases/miio2.db` 的 `devices` 表，展示所有设备列表让用户选择
- **FR-1.3**: 提取目标设备 32 位 Token（12 字节十六进制）与 BLE Key（16 字节十六进制），保存到本地加密存储（SharedPreferences + AES）
- **FR-1.4**: 本地读取失败时（文件不存在/权限不足/版本过高 Token 已加密），自动回退至米家云 API 模式（RC4 加密登录 + `blt_get_beaconkey`）
- **FR-1.5**: 云 API 模式支持二维码扫码登录与账号密码登录两种方式（对齐参考项目 `QrCodeXiaomiCloudClient`）

### FR-2：BLE 核心通信
- **FR-2.1**: 扫描附近 BLE 设备，按名称/UUID 过滤显示酷态科充电器，支持手动输入 MAC 直连
- **FR-2.2**: 连接后自动订阅 5 个 GATT 通知通道，读取设备信息（协议版本、芯片名、固件版本）
- **FR-2.3**: 执行完整 MiOT BLE 认证流程（Phase A 初始化 + Phase B CMD_LOGIN + HKDF 派生 + 双向 HMAC + 第二轮 challenge-response）
- **FR-2.4**: 订阅并解析实时端口广播数据（PIID 1-4，内联帧 `0x02` 与多帧 `0x00`），解密后解析出电压/电流/功率/协议
- **FR-2.5**: 所有 GATT 读写包含 5 秒超时与最多 3 次重试机制，日志输出到 Android Logcat / Windows Debug

### FR-3：控制逻辑
- **FR-3.1**: 单口开关（PIID 16）：读取当前位掩码 → 修改对应位 → 写回 → 验证回读
- **FR-3.2**: 协议控制（PIID 21）：按端口设置 PD/PPS/UFCS/SCP 开关位（对齐参考项目 `PROTOCOL_SWITCH_BITS`）
- **FR-3.3**: 倒计时关闭（PIID 8 总倒计时 / PIID 9-12 各端口倒计时，单位分钟，范围 0-1440）
- **FR-3.4**: 场景模式（PIID 5）：AI/Apple/Single/Balance 四种
- **FR-3.5**: 息屏时间（PIID 6）：5min/10min/30min/常亮/1min
- **FR-3.6**: 协议扩展控制（PIID 21）的编码/解码逻辑完全对齐参考项目 `encode_protocol_extend` / `protocol_switches`

### FR-4：Android UI
- **FR-4.1**: 主页展示 4 个端口（C1/C2/C3/A）实时卡片：V/I/P/协议标签，未连接时显示 `--` 与 "未连接/搜索中" 状态
- **FR-4.2**: 连接/认证进度分步骤提示（初始化 → 密钥交换 → HMAC 验证 → 登录）
- **FR-4.3**: 端口控制界面（单口开关 + 协议勾选 + 倒计时设定）
- **FR-4.4**: 设置界面（场景模式、息屏时间、语言、USB-A 小电流、空闲息屏、屏幕方向锁）
- **FR-4.5**: 设备信息页（MAC、固件、型号、Token 管理）

### FR-5：Windows 桌面 UI
- **FR-5.1**: WPF MVVM 架构，界面结构与 Android 对等但针对桌面优化（多列布局、可拖拽面板）
- **FR-5.2**: 支持保存多个充电器配置（MAC + Token），启动时自动重连上次设备
- **FR-5.3**: 端口数据历史曲线（PowerChart，对齐参考项目 `power_chart.html` 的可视化能力）
- **FR-5.4**: 日志查看器（实时 BLE 报文窗口，支持 Hex 视图）

### FR-6：健壮性与工程规范
- **FR-6.1**: 代码按 `ble/`、`protocol/`、`ui/`、`utils/` 四目录拆分；单文件 > 300 行自动拆分
- **FR-6.2**: 所有 Future/Task 必须通过 `.catchError` / `try-catch` 处理；Stream 必须在 dispose 时调用 `.cancel()` 或 `.close()`
- **FR-6.3**: 日志分级（debug/info/warn/error），Android 用 `Logger` → Logcat，Windows 用 `Debug.WriteLine` + 文件日志
- **FR-6.4**: 协议解析完全参照参考项目源码；未找到的协议字段留空并注释 `// TODO: 待抓包补充`，严禁臆造
- **FR-6.5**: UI 不得使用 Mock 数据；未连接时所有动态数值显示 `--`
- **FR-6.6**: GitHub Actions CI：Android 构建 `apk/arm64-v8a`、Windows 构建 `net8-windows-self-contained.exe`，双端均触发 `flutter analyze` / `dotnet format --verify-no-changes`

## Non-Functional Requirements

### NFR-1：性能
- Android BLE 事件延迟 < 300ms（从通知到达至 UI 刷新）
- Windows BLE 事件延迟 < 200ms
- 端口数据刷新频率 ≥ 5Hz（受设备广播限制）

### NFR-2：安全
- Token 本地 AES-256 加密存储
- Root 执行命令白名单化（仅允许读取 `miio2.db`，禁止执行其他 shell）
- 云 API 密码使用后立即从内存清除

### NFR-3：兼容性
- Android 最低 API 23（Android 6.0），目标 API 34（Android 14）
- Windows 10 1809+（支持 BLE）
- 目标设备：OnePlus 系列（ColorOS/OxygenOS），支持 Root（Magisk 推荐）

### NFR-4：可维护性
- 协议解析层（`protocol/`）必须与 UI 解耦，可独立单元测试
- 关键协议常量集中定义，便于对照参考项目审查

### NFR-5：可观测性
- 双端支持导出日志到文件（Android 导出 `/sdcard/Documents/cuktech/logs/`，Windows 导出 `%APPDATA%/Cuktech/logs/`）
- 日志文件自动轮转（单文件 ≤ 5MB，保留 5 个）

## Constraints

### 技术约束
- **Android BLE 库**: 必须使用 `flutter_blue_plus`（基于 native Android BLE stack）
- **Windows BLE 库**: 必须使用 `Windows.Devices.Bluetooth`（通过 C# `BluetoothLEDevice` / `GattDeviceService`）
- **加密**: Dart 端使用 `pointycastle` / `cryptography` 包实现 HKDF-SHA256 与 AES-CCM；C# 端使用 `System.Security.Cryptography`
- **禁止本地编译**: 所有构建通过 GitHub Actions 完成
- **协议真实性**: 严格对齐 `kairui1108/cuktech-ble-ha` 源码，未实现的字段标注 `TODO: 待抓包补充`

### 业务约束
- 开发周期分 4 阶段按顺序执行
- 用户提供的 GitHub Token 仅限仓库创建用途，后续 CI 使用内置 `GITHUB_TOKEN`

### 依赖
- `flutter_blue_plus: ^1.32`
- `flutter_blue_plus_windows: 不可用，Windows 改用 C#`
- `pointycastle: ^1.0`
- `cryptography: ^2.7`
- `shared_preferences: ^2.2`
- `flutter_secure_storage: ^9.0`（Token 安全存储）
- `sqlite3_flutter_libs: ^0.5`（如需在 App 内二次解析 db）
- C#：`Microsoft.Windows.SDK.Contracts`、`System.Security.Cryptography`、`Newtonsoft.Json`

## Assumptions
- 用户的一加手机已通过 Magisk Root，可执行 `su` 命令
- 米家 App 版本 ≤ 8.7，`miio2.db` 中 `devices` 表仍包含明文 Token（否则云 API 作为回退）
- 酷态科 10 号 Ultra（AD1204U）固件版本 ≤ 参考项目所支持的版本（若后续固件升级改协议，需重新抓包）
- 用户 Windows 10/11 电脑蓝牙适配器正常工作
- 参考项目的 HKDF 派生密钥参数（`info=b"mible-login-info"`，SHA256，64 字节）与目标设备一致

## Acceptance Criteria

### AC-1：Token 提取成功
- **Given**: 用户已 Root 且米家 App 已登录酷态科设备
- **When**: 用户在 Android App 点击 "扫描米家设备"
- **Then**: App 成功读取 `miio2.db`，展示设备列表，用户选中后获得 32 位 Token 与 16 位 BLE Key，保存到本地加密存储
- **Verification**: `programmatic`
- **Notes**: 可通过日志验证 Token/Key 长度；失败时（文件不存在/权限不足）自动进入云 API 模式

### AC-2：BLE 扫描与连接
- **Given**: 充电器已通电并处于可发现状态
- **When**: 用户点击 "开始扫描"
- **Then**: App 在 10 秒内扫描到目标设备并显示 MAC、RSSI、名称，点击后 5 秒内完成连接与通知通道订阅
- **Verification**: `programmatic`

### AC-3：MiOT 认证
- **Given**: 已连接且 Token/Key 有效
- **When**: 认证流程启动
- **Then**: 依次完成 Phase A 初始化、Phase B CMD_LOGIN、HKDF 派生密钥、双向 HMAC 验证、登录成功回调；失败时在 UI 显示 "认证失败：Token 无效" 等具体原因
- **Verification**: `programmatic`

### AC-4：实时端口数据
- **Given**: 已认证且充电器有设备接入
- **When**: 端口有负载变化
- **Then**: UI 在 300ms 内显示更新后的电压（0.1V 分辨率）、电流（0.1A 分辨率）、功率（0.1W 分辨率）与协议标签
- **Verification**: `human-judgment`

### AC-5：单口开关控制
- **Given**: 已认证
- **When**: 用户切换 C1 端口开关
- **Then**: 设备在 2 秒内响应，回读状态与 UI 一致；断电后物理端口 LED 跟随变化
- **Verification**: `programmatic`

### AC-6：协议开关控制
- **Given**: 已认证
- **When**: 用户勾选/取消 PD/UFCS/SCP 协议
- **Then**: PIID 21 对应位正确置位，回读一致；充电器重新插拔线缆后协议握手符合预期
- **Verification**: `programmatic`

### AC-7：倒计时关闭
- **Given**: 已认证，C1 口倒计时设为 30 分钟
- **When**: 用户点击 "开始倒计时"
- **Then**: 充电器在 30 分钟后自动关闭 C1 端口；UI 实时显示剩余分钟数
- **Verification**: `programmatic`

### AC-8：UI 未连接状态
- **Given**: App 刚启动或已断开
- **When**: 用户查看主页
- **Then**: 所有 V/I/P 显示为 `--`，端口卡片显示 "未连接" 标签，扫描按钮可点击
- **Verification**: `human-judgment`

### AC-9：超时与重试
- **Given**: 充电器响应延迟或临时断开
- **When**: 任何 GATT 读写操作执行
- **Then**: 单次操作 5 秒超时，自动重试最多 3 次；3 次均失败后 UI 显示 "通信失败，请重试"
- **Verification**: `programmatic`

### AC-10：Windows 对等功能
- **Given**: Windows 10/11 电脑蓝牙可用，Token 已导入
- **When**: 用户在 Windows EXE 执行与 Android 相同的控制操作
- **Then**: 行为与 Android 对等（扫描、连接、认证、读写一致）
- **Verification**: `programmatic`

### AC-11：GitHub Actions CI
- **Given**: 代码推送到 `main` 分支
- **When**: GitHub Actions 触发
- **Then**: Android workflow 成功构建签名 APK（debug keystore），Windows workflow 成功发布 self-contained EXE，两个 workflow 均通过静态分析
- **Verification**: `programmatic`

### AC-12：代码结构规范
- **Given**: 代码仓库任意目录
- **When**: 审查文件结构
- **Then**: 四目录拆分清晰，单文件 ≤ 300 行，所有 `async` 方法有 `try-catch`，所有 Stream 有释放逻辑
- **Verification**: `human-judgment`

## Open Questions
- [ ] 酷态科 10 号 Ultra 不同固件版本的认证协议是否完全一致？（需真机验证：如出现 ECDH 变体则需抓包补充）
- [ ] 云 API 模式是否需要处理滑块/图形验证码？（参考项目未覆盖）
- [ ] Windows 端是否需要 USB 数据线同步固件升级能力？（当前不考虑，可后续扩展）
- [ ] 是否支持多充电器同时连接？（首版不支持，后续扩展）
