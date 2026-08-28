# 酷态科云登录 - Implementation Plan

## [x] Task 1: RC4-drop[1024] 加密实现 (Dart)
- **Priority**: high
- **Depends On**: None
- **Description**: 
  - 参照 xiaomi_cloud.py `_encrypt_rc4` / `_decrypt_rc4` 实现
  - 使用 pointycastle 的 ARC4 加密
  - RC4-drop[1024]：初始化后丢弃前 1024 字节输出
  - 输出 Base64 编码
- **Acceptance Criteria Addressed**: AC-3
- **Test Requirements**:
  - `programmatic` TR-1.1: 加密 "test" 使用固定 key 输出与 Python 一致
  - `programmatic` TR-1.2: 加密后解密还原原文
  - `programmatic` TR-1.3: 空字符串加密不抛异常

## [x] Task 2: Signed-nonce 与 SHA1 签名实现 (Dart)
- **Priority**: high
- **Depends On**: Task 1
- **Description**:
  - `_signed_nonce`: SHA256(base64Decode(ssecurity) + base64Decode(nonce)) → base64
  - `_generate_enc_signature`: SHA1(method + path + sorted params + signed_nonce) → base64
  - `_generate_enc_params`: RC4 加密每个参数 + 添加 signature/ssecurity/_nonce
- **Acceptance Criteria Addressed**: AC-3, AC-4
- **Test Requirements**:
  - `programmatic` TR-2.1: signed_nonce 输出正确
  - `programmatic` TR-2.2: 空参数签名不抛异常

## [x] Task 3: WebView 登录页实现 (Dart/Android)
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 添加 flutter_inappwebview 依赖
  - 创建 WebView 登录页
  - 打开 `https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true`
  - 拦截 navigation 变化，检测 serviceToken cookie
  - 检测 sts.api.io.mi.com 重定向，提取 serviceToken
- **Acceptance Criteria Addressed**: AC-1, AC-2
- **Test Requirements**:
  - `human-judgement` TR-3.1: WebView 正常加载米家登录页
  - `programmatic` TR-3.2: 登录成功后 serviceToken 非空
  - `programmatic` TR-3.3: ssecurity 非空

## [ ] Task 4: 云 API 调用实现 (Dart/Android)
- **Priority**: high
- **Depends On**: Task 1, Task 2, Task 3
- **Description**:
  - 实现 `_api_call` 方法：RC4 加密 + 签名 + POST
  - 实现 `getBeaconKey(did)` 调用 `/v2/device/blt_get_beaconkey`
  - 实现 `getDeviceList()` 调用 `/v2/home/home_device_list`
  - 所有请求含 5 秒超时 + 3 次重试
- **Acceptance Criteria Addressed**: AC-4
- **Test Requirements**:
  - `programmatic` TR-4.1: getBeaconKey 返回 32 位十六进制字符串
  - `programmatic` TR-4.2: API 错误时返回 descriptive error
  - `programmatic` TR-4.3: 未登录时 getBeaconKey 抛 StateError

## [ ] Task 5: Token 持久化与 UI 集成 (Dart/Android)
- **Priority**: high
- **Depends On**: Task 3, Task 4
- **Description**:
  - 将 serviceToken, ssecurity, did 存入 flutter_secure_storage
  - 更新 TokenImportPage 云登录按钮
  - 登录成功后自动跳转到设备选择
  - 显示加载状态和错误信息
- **Acceptance Criteria Addressed**: AC-2, AC-4
- **Test Requirements**:
  - `human-judgement` TR-5.1: 云登录 UI 流程清晰
  - `programmatic` TR-5.2: Token 保存后可从存储读取

## [ ] Task 6: Windows 端 RC4 + 签名实现 (C#)
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 使用 BouncyCastle 实现 RC4-drop[1024]
  - 实现 Signed-nonce 和 SHA1 签名
  - 实现加密 API 调用方法
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `programmatic` TR-6.1: RC4 加解密正确
  - `programmatic` TR-6.2: 签名算法与 Dart 端一致

## [ ] Task 7: Windows WebView2 登录实现 (C#)
- **Priority**: high
- **Depends On**: Task 6
- **Description**:
  - 添加 Microsoft.Web.WebView2 NuGet 包
  - 创建 WebView2 登录窗口
  - 拦截导航提取 serviceToken
  - 调用 getBeaconKey 获取 BLE Token
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `human-judgement` TR-7.1: WebView2 正常加载登录页
  - `programmatic` TR-7.2: 登录后获取 serviceToken + beaconKey

## [ ] Task 8: CI 构建验证
- **Priority**: high
- **Depends On**: Task 1-7
- **Description**:
  - 确保所有新依赖在 CI 中正确安装
  - flutter_inappwebview 需在 AndroidManifest 添加权限
  - WebView2 NuGet 包在 Windows CI 中还原
  - 触发 CI 并确保全部通过
- **Acceptance Criteria Addressed**: AC-6
- **Test Requirements**:
  - `programmatic` TR-8.1: Android Build SUCCESS
  - `programmatic` TR-8.2: Windows Build SUCCESS
  - `programmatic` TR-8.3: Lint & Analyze SUCCESS
