# ZTR_OS CukTeck Controler

酷态科（CUKTECH）10号超级电能充Ultra 的跨平台控制软件。

## 功能

- **Android APP**（Flutter + Kotlin MethodChannel）
  - Root 权限自动提取米家 Token（`/data/data/com.xiaomi.smarthome/databases/miio2.db`）
  - 米家云 API 回退登录（混合模式：先 DB 后云）
  - BLE 直连（Service `0xFE95`），MiOT 协议交互
  - 4 路端口（C1/C2/C3/A）实时电压/电流/功率显示
  - 单口开关、协议开关（PD/UFCS/SCP 等）、倒计时关闭
  - 场景模式、息屏时间、小电流、屏幕方向锁等设置

- **Windows EXE**（C# WPF）
  - 复用 Dart 端协议常量（手动同步）
  - 完整 WPF 界面：主窗口、端口卡片、控制页、设置页、日志页
  - 实时曲线、Hex 日志视图
  - 全局异常捕获

## 架构

```
├── android_app/         # Flutter + Kotlin MethodChannel (Root)
│   ├── lib/
│   │   ├── ble/         # BLE 扫描/连接/加密通道/端口流
│   │   ├── protocol/    # 协议常量/TLV/加解密/认证/解码/控制/设置
│   │   ├── ui/          # 主题/组件/页面
│   │   ├── utils/       # 日志/重试/配置
│   │   └── bootstrap/   # 全局异常
│   └── android/         # Native (Root 通道)
└── windows_app/         # C# WPF
    └── src/CukTechController/
        ├── ble/         # BLE 扫描/连接/加密通道/端口流
        ├── protocol/    # 同 Dart 端的协议实现
        ├── ui/          # WPF Views + ViewModels
        └── utils/       # 日志 + 重试
```

## 开发

### 依赖

- Android: Flutter ≥ 3.22, Android Gradle Plugin 8.x, minSdk 23, targetSdk 34
- Windows: .NET 8.0, WPF
- GitHub Actions 运行所有编译与检查（**本地不编译**，CI 通过后才合并）

### 编译

所有编译与静态分析通过 GitHub Actions 完成：

- `.github/workflows/android.yml` — Android APK 构建
- `.github/workflows/windows.yml` — Windows EXE 构建
- `.github/workflows/lint.yml` — Dart analyze + C# 编译检查
- `.github/workflows/release.yml` — Release 自动打包

```bash
# 本地仅格式化
dart format android_app/lib
```

## 硬约束

1. **禁止臆造协议** — 所有 BLE 协议严格参照 `kairui1108/cuktech-ble-ha/src`，缺失点统一标记 `// 待抓包补充`
2. **强制拆分** — `ble/`、`protocol/`、`ui/`、`utils/` 四目录；单文件 ≤ 300 行
3. **强制健壮性** — 所有 BLE 读写：5 秒超时 + 3 次重试 + 详细日志
4. **禁止假数据** — UI 未连接时显示 `--`，禁止 Mock 数据

## 授权协议

本软件不隶属于任何开源协议😅你们就梦吧😅
