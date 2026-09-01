using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using CukTechController.Ble;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// MiOT BLE 认证流程（完整 6 Phase，从 cuktech-ble-server/controller.py 移植）
    ///
    /// Phase A: 0xa4 初始化 + 协议版本响应
    /// Phase B 前：设备密钥交换 (key exchange)
    /// Phase B 1/2：CMD_LOGIN 0x24 + 本地随机数 + HKDF 派生会话密钥 + HMAC 双向验证
    /// Phase B 2/2：第二轮 challenge-response
    ///   - R: 0x0d challenge(16B) → W: keepalive
    ///   - R: 0x0c response(32B) → W: keepalive → W: ACK
    ///   - R: RCV_RDY → W: second auth response (0x0c + 32B payload)
    /// Phase Final: 0x21 = 登录成功 或 0x11 = 激活成功
    /// </summary>
    public class Authenticator
    {
        public static readonly Authenticator Instance = new Authenticator();

        private readonly CryptoEngine _crypto = CryptoEngine.Instance;

        /// <summary>
        /// 执行完整认证流程（参考 cuktech-ble-server controller._try_authenticate）
        /// </summary>
        public async Task<bool> AuthenticateAsync(WindowsConnector connector, string token)
        {
            try
            {
                AppLogger.Instance.I("Authenticator", "starting MiOT authenticate...");

                // -------- Phase A: 设备初始化 (0xa4) --------
                AppLogger.Instance.I("Authenticator", "[1/6] 设备初始化 (0xa4)...");
                await connector.WriteAsync("auth_ctrl", new byte[] { 0xa4 });
                var initResp = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                if (initResp == null)
                {
                    AppLogger.Instance.W("Authenticator", "no init response");
                    return false;
                }
                var ack = (byte[])initResp.Clone();
                if (ack.Length >= 3) ack[2] = (byte)(ack[2] + 1);
                await connector.WriteAsync("auth_data", ack);

                // -------- 设备密钥交换 --------
                var keyData = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 5);
                if (keyData == null || keyData.Length < 20)
                {
                    AppLogger.Instance.W("Authenticator", "key exchange data invalid");
                    return false;
                }
                int padLen = keyData.Length - 4;
                var placeholder = new byte[4 + padLen];
                placeholder[0] = 0; placeholder[1] = 0; placeholder[2] = 5; placeholder[3] = 1;
                for (int i = 0; i < padLen; i++) placeholder[4 + i] = 0xf2;
                await connector.WriteAsync("auth_data", placeholder);

                // -------- Phase B: CMD_LOGIN (0x24) --------
                AppLogger.Instance.I("Authenticator", "[2/6] 发送登录命令 (CMD_LOGIN=0x24)...");
                await connector.WriteAsync("auth_ctrl", new byte[] { 0x24, 0x00, 0x00, 0x00 });

                // 发送我方随机数前的握手头
                AppLogger.Instance.I("Authenticator", "[3/6] 密钥交换 (HMAC+HKDF)...");
                var randKey = AuthHelper.RandomBytes(16);
                await connector.WriteAsync("auth_data", new byte[] { 0, 0, 0, 0x0b, 1, 0 });

                // 等 RCV_RDY
                var rcvRdy = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                while (rcvRdy != null && !(rcvRdy.Length == 4 && rcvRdy[2] == 1 && rcvRdy[3] == 1))
                    rcvRdy = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);

                // 发送随机数
                var frameHeader = new byte[2 + randKey.Length];
                frameHeader[0] = 1; frameHeader[1] = 0;
                Array.Copy(randKey, 0, frameHeader, 2, randKey.Length);
                await connector.WriteAsync("auth_data", frameHeader);

                // 等 RCV_OK
                var rcvOk = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                if (rcvOk == null || rcvOk.Length < 4 || rcvOk[3] != 0)
                {
                    AppLogger.Instance.W("Authenticator", "no RCV_OK after random send");
                    return false;
                }

                // 接收 dev 随机数(16B) + dev HMAC(32B)
                var devRandom = await AuthHelper.RecvAuthResponseAsync(connector, "auth_data");
                if (devRandom == null || devRandom.Length < 16)
                {
                    AppLogger.Instance.W("Authenticator", "invalid dev random");
                    return false;
                }
                var devKey = devRandom.Take(16).ToArray();

                var devHmacInfo = await AuthHelper.RecvAuthResponseAsync(connector, "auth_data");
                if (devHmacInfo == null || devHmacInfo.Length < 32)
                {
                    AppLogger.Instance.W("Authenticator", "invalid dev HMAC");
                    return false;
                }
                var devHmac = devHmacInfo.Take(32).ToArray();

                // HKDF 派生会话密钥
                var tokenBytes = AuthHelper.HexToBytes(token);
                var salt = new List<byte>(randKey);
                salt.AddRange(devKey);
                var derived = AuthHelper.HkdfSha256(tokenBytes, salt.ToArray(), 64);

                var sDevKey = derived.Take(16).ToArray();
                var sAppKey = derived.Skip(16).Take(16).ToArray();
                var sDevIv = derived.Skip(32).Take(4).ToArray();
                var sAppIv = derived.Skip(36).Take(4).ToArray();
                _crypto.SetSessionKeys(sDevKey, sAppKey, sDevIv, sAppIv);
                AppLogger.Instance.I("Authenticator", "[4/6] 会话密钥派生完成");

                // HMAC 验证设备
                var saltInv = new List<byte>(devKey);
                saltInv.AddRange(randKey);
                var expectedDevHmac = AuthHelper.HmacSha256(sDevKey, saltInv.ToArray());
                if (!AuthHelper.ListEquals(expectedDevHmac, devHmac))
                {
                    AppLogger.Instance.E("Authenticator", "device HMAC verify failed");
                    return false;
                }

                // 发送我方 HMAC
                var ourHmac = AuthHelper.HmacSha256(sAppKey, salt.ToArray());
                await connector.WriteAsync("auth_data", new byte[] { 0, 0, 0, 10, 1, 0 }); // CMD_SEND_INFO
                var rcvRdy2 = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                if (rcvRdy2 == null) return false;

                var ourFrame = new byte[2 + ourHmac.Length];
                ourFrame[0] = 1; ourFrame[1] = 0;
                Array.Copy(ourHmac, 0, ourFrame, 2, ourHmac.Length);
                await connector.WriteAsync("auth_data", ourFrame);
                _ = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);

                // -------- [5/6] 第二轮 challenge-response --------
                AppLogger.Instance.I("Authenticator", "[5/6] 第二轮 challenge-response...");
                try
                {
                    byte[]? challengeData = null;
                    byte[]? responseData = null;
                    var deadline = DateTime.UtcNow.AddSeconds(8);

                    while (DateTime.UtcNow < deadline)
                    {
                        var timeout = (int)Math.Max(1, (deadline - DateTime.UtcNow).TotalSeconds);
                        var data = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: Math.Min(3, timeout));
                        if (data == null) continue;
                        AppLogger.Instance.D("Authenticator", $"phase6 auth_data: {Hex(data)}");

                        // challenge: [00 00] 02 0d [16B]
                        if (data.Length >= 3 && data[2] == 0x0d)
                        {
                            challengeData = data;
                            AppLogger.Instance.D("Authenticator", $"challenge received ({data.Length}B)");
                            await connector.WriteAsync("auth_data", new byte[] { 0x00, 0x00, 0x03, 0x00 }); // keepalive
                        }
                        // response: [00 00] 02 0c [32B]
                        else if (data.Length >= 3 && data[2] == 0x0c)
                        {
                            responseData = data;
                            AppLogger.Instance.D("Authenticator", $"response received ({data.Length}B)");
                            await connector.WriteAsync("auth_data", new byte[] { 0x00, 0x00, 0x03, 0x00 }); // keepalive
                            await connector.WriteAsync("auth_data", new byte[] { 0x00, 0x00, 0x00, 0x0a, 0x01, 0x00 }); // ACK
                        }
                        // RCV_RDY: 00 00 01 01
                        else if (data.Length == 4 && data[2] == 0x01 && data[3] == 0x01)
                        {
                            AppLogger.Instance.D("Authenticator", "RCV_RDY → send second auth response");
                            break;
                        }
                        // RCV_OK: 00 00 01 00
                        else if (data.Length == 4 && data[2] == 0x01 && data[3] == 0x00)
                        {
                            AppLogger.Instance.D("Authenticator", "RCV_OK → skip to auth_ctrl");
                            break;
                        }
                    }

                    if (responseData != null)
                    {
                        byte[] secondResp = new byte[3 + (responseData.Length - 3)];
                        secondResp[0] = 0x01;
                        secondResp[1] = 0x00;
                        secondResp[2] = 0x0c; // opcode 0x0c
                        Array.Copy(responseData, 3, secondResp, 3, responseData.Length - 3);
                        AppLogger.Instance.D("Authenticator", $"sending 2nd auth response ({secondResp.Length}B)");
                        await connector.WriteAsync("auth_data", secondResp);
                        _ = await AuthHelper.WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                    }
                }
                catch (Exception ex)
                {
                    // 有些固件版本可能直接返回 auth_ctrl，不执行第二轮
                    AppLogger.Instance.D("Authenticator", $"phase6 skipped/error: {ex.Message}");
                }

                // -------- [6/6] 等待认证结果 --------
                AppLogger.Instance.I("Authenticator", "[6/6] Waiting login result...");
                var result = await AuthHelper.WaitNotifyAsync(connector, "auth_ctrl", timeoutSec: 5);
                if (result != null && result.Length > 0)
                {
                    byte frm = result[0];
                    switch (frm)
                    {
                        case 0x21:
                            AppLogger.Instance.I("Authenticator", "✅ 登录成功!");
                            return true;
                        case 0x11:
                            AppLogger.Instance.I("Authenticator", "✅ 激活成功!");
                            return true;
                        case 0x23:
                            AppLogger.Instance.E("Authenticator", "❌ 登录失败 (Login Failed)");
                            return false;
                        case 0x12:
                            AppLogger.Instance.E("Authenticator", "❌ 激活失败");
                            return false;
                        default:
                            AppLogger.Instance.E($"Authenticator", $"未知结果: frm=0x{frm:X2}");
                            return false;
                    }
                }
                AppLogger.Instance.W("Authenticator", "未收到认证结果 (auth_ctrl 通知超时)");
                return false;
            }
            catch (Exception ex)
            {
                AppLogger.Instance.E("Authenticator", $"authenticate error: {ex.Message}", ex);
                return false;
            }
        }

        private static string Hex(byte[] data) =>
            BitConverter.ToString(data).Replace("-", "").ToLowerInvariant();
    }
}
