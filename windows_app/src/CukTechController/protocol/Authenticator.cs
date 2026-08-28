using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using CukTechController.Ble;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// MiOT BLE 认证流程
    /// 参考: controller.py _try_authenticate
    /// Phase A (0xa4 初始化) → Phase B (CMD_LOGIN 0x24 + HKDF + HMAC) → 第二轮 challenge-response
    /// </summary>
    public class Authenticator
    {
        public static readonly Authenticator Instance = new Authenticator();

        private readonly CryptoEngine _crypto = CryptoEngine.Instance;

        /// <summary>
        /// 执行完整认证流程
        /// </summary>
        /// <param name="connector">BLE 连接器</param>
        /// <param name="token">32 位十六进制字符串</param>
        /// <returns>是否认证成功</returns>
        public async Task<bool> AuthenticateAsync(WindowsConnector connector, string token)
        {
            try
            {
                AppLogger.Info("Authenticator: starting MiOT authenticate...");

                // Phase A: 设备初始化
                AppLogger.Info("Authenticator: [1/5] Device init (0xa4)...");
                await connector.WriteAsync("auth_ctrl", new byte[] { 0xa4 });
                var initResp = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                if (initResp == null)
                {
                    AppLogger.Warn("Authenticator: no init response");
                    return false;
                }
                // 协议协商回传: byte[2] + 1
                var ack = (byte[])initResp.Clone();
                if (ack.Length >= 3) ack[2] = (byte)(ack[2] + 1);
                await connector.WriteAsync("auth_data", ack);

                // Phase B 开始前读取设备密钥交换数据
                var keyData = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 5);
                if (keyData == null || keyData.Length < 20)
                {
                    AppLogger.Warn("Authenticator: key exchange data invalid");
                    return false;
                }
                // 回传占位数据
                int padLen = keyData.Length - 4;
                var placeholder = new byte[4 + padLen];
                placeholder[0] = 0; placeholder[1] = 0; placeholder[2] = 5; placeholder[3] = 1;
                for (int i = 0; i < padLen; i++) placeholder[4 + i] = 0xf2;
                await connector.WriteAsync("auth_data", placeholder);

                // Phase B: CMD_LOGIN
                AppLogger.Info("Authenticator: [2/5] Sending CMD_LOGIN=0x24...");
                await connector.WriteAsync("auth_ctrl", new byte[] { 0x24, 0x00, 0x00, 0x00 });

                // 发送我方随机密钥
                AppLogger.Info("Authenticator: [3/5] Sending random key...");
                var randKey = RandomBytes(16);
                await connector.WriteAsync("auth_data", new byte[] { 0, 0, 0, 0x0b, 1, 0 });

                // 等待 RCV_RDY
                var rcvRdy = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                // 跳过残留数据
                while (rcvRdy != null && !(rcvRdy.Length == 4 && rcvRdy[2] == 1 && rcvRdy[3] == 1))
                {
                    rcvRdy = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                }

                // 发送随机密钥（帧头 0100）
                var frameHeader = new byte[2 + randKey.Length];
                frameHeader[0] = 1; frameHeader[1] = 0;
                Array.Copy(randKey, 0, frameHeader, 2, randKey.Length);
                await connector.WriteAsync("auth_data", frameHeader);

                // 等待 RCV_OK
                var rcvOk = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                if (rcvOk == null || rcvOk.Length < 4 || rcvOk[3] != 0)
                {
                    AppLogger.Warn("Authenticator: no RCV_OK");
                    return false;
                }

                // 接收设备随机密钥 (16B) + HMAC (32B)
                var devRandom = await RecvAuthResponseAsync(connector, "auth_data");
                if (devRandom == null || devRandom.Length < 16)
                {
                    AppLogger.Warn("Authenticator: invalid dev random");
                    return false;
                }
                var devKey = devRandom.Take(16).ToArray();

                var devHmacInfo = await RecvAuthResponseAsync(connector, "auth_data");
                if (devHmacInfo == null || devHmacInfo.Length < 32)
                {
                    AppLogger.Warn("Authenticator: invalid dev HMAC");
                    return false;
                }
                var devHmac = devHmacInfo.Take(32).ToArray();

                // HKDF 派生会话密钥
                var tokenBytes = HexToBytes(token);
                var salt = new List<byte>();
                salt.AddRange(randKey);
                salt.AddRange(devKey);
                var derived = HkdfSha256(tokenBytes, salt.ToArray(), 64);

                var devKey_ = derived.Take(16).ToArray();
                var appKey_ = derived.Skip(16).Take(16).ToArray();
                var devIv = derived.Skip(32).Take(4).ToArray();
                var appIv = derived.Skip(36).Take(4).ToArray();

                _crypto.SetSessionKeys(devKey_, appKey_, devIv, appIv);
                AppLogger.Info("Authenticator: session keys derived");

                // HMAC 验证设备
                var saltInv = new List<byte>();
                saltInv.AddRange(devKey);
                saltInv.AddRange(randKey);
                var expectedDevHmac = HmacSha256(devKey_, saltInv.ToArray());
                if (!ListEquals(expectedDevHmac, devHmac))
                {
                    AppLogger.Error("Authenticator: device HMAC verify failed");
                    return false;
                }
                AppLogger.Info("Authenticator: [4/5] Device HMAC verified");

                // 发送我方 HMAC
                var ourHmac = HmacSha256(appKey_, salt.ToArray());
                await connector.WriteAsync("auth_data", new byte[] { 0, 0, 0, 10, 1, 0 }); // CMD_SEND_INFO
                var rcvRdy2 = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);
                if (rcvRdy2 == null) return false;

                var ourFrame = new byte[2 + ourHmac.Length];
                ourFrame[0] = 1; ourFrame[1] = 0;
                Array.Copy(ourHmac, 0, ourFrame, 2, ourHmac.Length);
                await connector.WriteAsync("auth_data", ourFrame);
                var rcvOk2 = await WaitNotifyAsync(connector, "auth_data", timeoutSec: 3);

                // 第二轮 challenge-response
                // TODO: 待抓包补充完整 challenge-response 细节；当前简化跳过
                // 直接等待 auth_ctrl 登录结果
                AppLogger.Info("Authenticator: [5/5] Waiting login result...");
                var result = await WaitNotifyAsync(connector, "auth_ctrl", timeoutSec: 5);
                if (result != null && result.Length > 0)
                {
                    byte frm = result[0];
                    if (frm == 0x21)
                    {
                        AppLogger.Info("Authenticator: login OK");
                        return true;
                    }
                    else if (frm == 0x11)
                    {
                        AppLogger.Info("Authenticator: activate OK");
                        return true;
                    }
                    else
                    {
                        AppLogger.Error($"Authenticator: login failed: frm=0x{frm:X2}");
                        return false;
                    }
                }
                AppLogger.Warn("Authenticator: no login result");
                return false;
            }
            catch (Exception ex)
            {
                AppLogger.Error($"Authenticator: authenticate error: {ex.Message}", ex);
                return false;
            }
        }

        private static async Task<byte[]?> WaitNotifyAsync(
            WindowsConnector connector,
            string channel,
            int timeoutSec = 3)
        {
            // 使用 TaskCompletionSource 订阅事件
            var tcs = new TaskCompletionSource<byte[]>();
            CancellationTokenSource? cts = null;

            void Handler(object? sender, (string Channel, byte[] Data) e)
            {
                if (e.Channel == channel && !tcs.Task.IsCompleted)
                {
                    tcs.TrySetResult(e.Data);
                }
            }

            connector.ValueReceived += Handler;
            try
            {
                cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSec));
                cts.Token.Register(() =>
                {
                    if (!tcs.Task.IsCompleted)
                        tcs.TrySetResult(Array.Empty<byte>()); // 空数组表示超时
                });

                var result = await tcs.Task;
                // 超时返回空数组
                if (result.Length == 0) return null;
                return result;
            }
            finally
            {
                connector.ValueReceived -= Handler;
                cts?.Dispose();
            }
        }

        private static async Task<byte[]?> RecvAuthResponseAsync(
            WindowsConnector connector,
            string channel)
        {
            var data = await WaitNotifyAsync(connector, channel, 3);
            if (data == null || data.Length < 4) return null;

            if (data[2] == 0x02)
            {
                // 内联
                await connector.WriteAsync(channel, new byte[] { 0, 0, 3, 0 });
                return data.Skip(4).ToArray();
            }

            if (data[2] == 0x00 && data.Length >= 6)
            {
                // 多帧
                int count = data[4] | (data[5] << 8);
                await connector.WriteAsync(channel, new byte[] { 0, 0, 1, 1 });
                var received = new List<byte>();
                for (int i = 0; i < count; i++)
                {
                    var f = await WaitNotifyAsync(connector, channel, 3);
                    if (f == null) return null;
                    received.AddRange(f.Skip(2));
                }
                await connector.WriteAsync(channel, new byte[] { 0, 0, 1, 0 });
                return received.ToArray();
            }

            return null;
        }

        private static byte[] RandomBytes(int n)
        {
            using var rng = RandomNumberGenerator.Create();
            var result = new byte[n];
            rng.GetBytes(result);
            return result;
        }

        private static byte[] HexToBytes(string hex)
        {
            hex = hex.Replace(" ", "");
            var result = new byte[hex.Length / 2];
            for (int i = 0; i < result.Length; i++)
            {
                result[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            }
            return result;
        }

        private static byte[] HkdfSha256(byte[] ikm, byte[] salt, int length)
        {
            // HKDF-SHA256 manual implementation
            // Step 1: Extract PRK = HMAC-SHA256(salt, ikm)
            using (var hmac = new HMACSHA256(salt))
            {
                var prk = hmac.ComputeHash(ikm);
                
                // Step 2: Expand
                var result = new byte[length];
                byte[] t = Array.Empty<byte>();
                int offset = 0;
                byte counter = 1;
                
                using (var expandHmac = new HMACSHA256(prk))
                {
                    while (offset < length)
                    {
                        // T(i) = HMAC-SHA256(PRK, T(i-1) || counter)
                        var input = new byte[t.Length + 1];
                        Array.Copy(t, 0, input, 0, t.Length);
                        input[t.Length] = counter;
                        t = expandHmac.ComputeHash(input);
                        
                        int copyLen = Math.Min(t.Length, length - offset);
                        Array.Copy(t, 0, result, offset, copyLen);
                        offset += copyLen;
                        counter++;
                    }
                }
                
                return result;
            }
        }

        private static byte[] HmacSha256(byte[] key, byte[] data)
        {
            using var hmac = new HMACSHA256(key);
            return hmac.ComputeHash(data);
        }

        private static bool ListEquals(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++)
            {
                if (a[i] != b[i]) return false;
            }
            return true;
        }
    }
}
