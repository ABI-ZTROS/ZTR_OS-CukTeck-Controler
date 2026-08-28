# 酷态科（CUKTECH）10号超级电能充 Ultra 控制软件 - Verification Checklist

## 基础设施
- [x] Checkpoint 1: GitHub 仓库结构清晰（`android_app/`、`windows_app/`、`.github/workflows/`、`docs/`），Flutter 工程内按 `ble/`、`protocol/`、`ui/`、`utils/` 四目录拆分
- [x] Checkpoint 2: 所有 Dart/C# 源文件 ≤ 300 行，超过时已拆分为多个文件
- [ ] Checkpoint 3: `.github/workflows/android.yml` 与 `.github/workflows/windows.yml` 能成功构建 APK 与 EXE

## Token 提取（Android）
- [ ] Checkpoint 4: Root 权限检测有效，非 Root 时 UI 明确提示
- [ ] Checkpoint 5: 读取 `miio2.db` 能正确解析 32 位 Token 与 16 位 BLE Key
- [ ] Checkpoint 6: Token 不存在时自动回退米家云 API（RC4 登录 + beaconkey）
- [ ] Checkpoint 7: Token 本地 AES 加密存储，重启后可恢复

## BLE 核心通信
- [ ] Checkpoint 8: Android 端 `flutter_blue_plus` 10 秒内扫描到目标设备
- [ ] Checkpoint 9: Windows 端 `Windows.Devices.Bluetooth` 扫描与连接成功
- [ ] Checkpoint 10: 5 个 GATT 通知通道（dev_info / auth_ctrl / auth_data / cmd_send / cmd_recv）按正确顺序订阅
- [ ] Checkpoint 11: MiOT 认证流程（Phase A + Phase B + 第二轮 challenge-response）完整跑通
- [ ] Checkpoint 12: 会话密钥派生（HKDF-SHA256，info=`mible-login-info`，64 字节）与参考项目一致
- [ ] Checkpoint 13: AES-CCM 加解密（tag_length=4）nonce 拼接与参考项目 bit-exact 一致
- [ ] Checkpoint 14: 设备计数器（`dev_it_hi`/`dev_it_lo`）溢出正确跟踪
- [ ] Checkpoint 15: 实时端口广播（内联帧 0x02、多帧 0x00）解析出电压/电流/功率/协议，刷新率 ≥ 5Hz

## 控制逻辑
- [ ] Checkpoint 16: 单口开关（PIID 16）读取-修改-写回-回读验证全流程正确
- [ ] Checkpoint 17: 协议开关（PIID 21）编码/解码与参考项目 `encode_protocol_extend` bit-exact 一致
- [ ] Checkpoint 18: 倒计时（PIID 8-12）设置后回读值一致，到时物理端口关闭
- [ ] Checkpoint 19: 场景模式/息屏时间/语言/USB-A 小电流/空闲息屏/屏幕方向锁读写正确

## UI
- [ ] Checkpoint 20: Android 主页端口卡片未连接时所有数值显示 `--`，明确 "未连接/搜索中" 状态
- [ ] Checkpoint 21: Android 认证进度分 5 步提示（初始化→密钥交换→HMAC 验证→登录→完成）
- [ ] Checkpoint 22: Android 端口控制页操作后物理端口 LED 与 UI 同步
- [ ] Checkpoint 23: Windows WPF 界面多列布局合理，操作响应 ≤ 300ms
- [ ] Checkpoint 24: Windows 实时功率曲线流畅可缩放
- [x] Checkpoint 25: 双端均禁止 Mock 数据；所有展示数据来自真实 BLE 通知

## 健壮性
- [x] Checkpoint 26: 所有 BLE 读写操作具备 5 秒超时 + 3 次重试机制
- [ ] Checkpoint 27: 3 次重试均失败后 UI 显示具体错误原因（如 "认证失败：Token 无效"）
- [x] Checkpoint 28: 所有 `Future` 有 `catchError` / `try-catch`；所有 `Stream` 在 `dispose` 时正确释放
- [x] Checkpoint 29: 全局 `FlutterError.onError` / `PlatformDispatcher.onError` 捕获未捕获异常
- [x] Checkpoint 30: 日志分级（debug/info/warn/error），支持导出与文件轮转
- [ ] Checkpoint 31: Root shell 命令白名单化，仅允许读取 `miio2.db` 与必要系统命令

## 协议真实性
- [x] Checkpoint 32: 所有协议常量（GATT UUID、Handle、PIID、TLV 格式）与 `kairui1108/cuktech-ble-ha` 源码一致
- [x] Checkpoint 33: 参考项目中未找到的字段均标注 `TODO: 待抓包补充`，未臆造任何字段
- [ ] Checkpoint 34: 加解密、计数器、nonce 拼接与参考项目 Python 实现对同一测试向量结果 bit-exact

## CI/CD
- [x] Checkpoint 35: GitHub Actions 双端 workflow 均触发 `flutter analyze` / `dotnet format --verify-no-changes`
- [ ] Checkpoint 36: Android workflow 成功构建签名 APK（debug keystore）
- [ ] Checkpoint 37: Windows workflow 成功发布 self-contained EXE
- [x] Checkpoint 38: Release tag 自动触发 GitHub Release 并归档产物

## 文档
- [x] Checkpoint 39: README 包含 Root 指引、米家 App 降级说明、Token 提取教程、FAQ
- [ ] Checkpoint 40: 用户能按文档完成首次连接流程
