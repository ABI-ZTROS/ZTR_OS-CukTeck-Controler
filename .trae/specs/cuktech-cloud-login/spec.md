# 酷态科云登录 - Product Requirement Document

## Overview
- **Summary**: 为酷态科控制软件开发云登录功能，通过内嵌 WebView 登录米家云端，自动捕获 serviceToken，调用 RC4 加密 API 获取 BLE beaconKey，实现无 Root 权限的 Token 提取。
- **Purpose**: 用户无 Root 权限时，通过云登录获取 BLE Token，绕过 miio2.db 读取限制。
- **Target Users**: 一加手机用户（可能无 Root）、Windows 桌面用户。

## Goals
- Android 端：内嵌 WebView 登录米家云，自动捕获 serviceToken + ssecurity
- Android 端：用捕获的 token 调用 RC4 加密 API 获取 beaconKey
- Windows 端：WebView2 登录，C# HttpClient + RC4 获取 beaconKey
- 两端复用相同的加密逻辑（RC4-drop[1024] + SHA1 签名）

## Non-Goals
- 不实现滑块验证码自动识别（由 WebView 原生处理）
- 不实现 2FA 短信自动填写
- 不实现米家 App 内 token 自动刷新
- 不处理小米账号注销、密码修改等账户管理功能

## Background & Context
- 参照项目：kairui1108/cuktech-ble-ha `ble_server/xiaomi_cloud.py`
- 关键技术：
  - WebView 登录拦截 cookie / serviceToken
  - RC4-drop[1024] 加密（ARC4 + 丢弃前 1024 字节）
  - SHA1 签名（sorted params + signed_nonce）
  - Mi Cloud API：`/v2/device/blt_get_beaconkey`

## Functional Requirements
- **FR-1**: Android 端内嵌 WebView 打开米家账号登录页
- **FR-2**: 登录成功后自动捕获 serviceToken 和 ssecurity
- **FR-3**: 实现 RC4-drop[1024] 加密/解密
- **FR-4**: 实现 signed_nonce 生成和 SHA1 签名
- **FR-5**: 调用 `/v2/device/blt_get_beaconkey` 获取 BLE Token
- **FR-6**: Windows 端使用 WebView2 实现同等功能
- **FR-7**: UI 显示登录状态（加载中/已登录/错误）
- **FR-8**: Token 持久化到本地安全存储

## Non-Functional Requirements
- **NFR-1**: 所有网络操作含 5 秒超时和 3 次重试
- **NFR-2**: 详细日志输出（Android Logcat / Windows Debug）
- **NFR-3**: 代码按 ble/、protocol/、ui/、utils/ 目录拆分
- **NFR-4**: 单文件不超过 300 行
- **NFR-5**: 禁止使用 Mock 数据

## Constraints
- **Technical**: Flutter 3.19+, flutter_inappwebview 6.x, Windows WebView2
- **Security**: serviceToken 和 ssecurity 需安全存储（flutter_secure_storage / DPAPI）
- **Dependencies**: pointycastle (Dart), BouncyCastle (C#), flutter_inappwebview

## Assumptions
- 用户有米家账号且设备已绑定
- WebView 能正常加载 account.xiaomi.com
- beaconKey API 在用户区域可用

## Acceptance Criteria

### AC-1: WebView 登录页加载
- **Given**: 用户在 Token 导入页选择云登录
- **When**: 点击"开始云登录"按钮
- **Then**: WebView 打开米家账号登录页面
- **Verification**: `human-judgment`

### AC-2: ServiceToken 自动捕获
- **Given**: WebView 已打开登录页
- **When**: 用户完成米家账号登录
- **Then**: serviceToken 被自动捕获并显示"登录成功"
- **Verification**: `programmatic`

### AC-3: RC4 加密正确性
- **Given**: 已知 ssecurity 和 nonce
- **When**: 使用 RC4-drop[1024] 加密测试字符串
- **Then**: 加密结果与 Python 参照实现一致
- **Verification**: `programmatic`

### AC-4: 获取 beaconKey
- **Given**: 已登录且有 serviceToken + ssecurity
- **When**: 调用 getBeaconKey(did)
- **Then**: 返回 32 位十六进制 beaconKey
- **Verification**: `programmatic`

### AC-5: Windows 端等效功能
- **Given**: Windows 应用运行中
- **When**: 执行云登录流程
- **Then**: 成功获取 beaconKey
- **Verification**: `programmatic`

### AC-6: CI 通过
- **Given**: 代码推送到 main 分支
- **When**: GitHub Actions 运行
- **Then**: Android Build + Lint + Windows Build 全部 SUCCESS
- **Verification**: `programmatic`

## Open Questions
- [ ] WebView 中滑块验证码是否需要特殊处理？（WebView 原生支持，通常不需要）
- [ ] 二步验证（2FA）流程是否在 WebView 中正常工作？
