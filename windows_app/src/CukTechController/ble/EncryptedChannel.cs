using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble
{
    /// <summary>
    /// 加密命令通道
    /// 负责通过 CMD_SEND / CMD_RECV 通道发送加密命令并接收响应。
    /// 握手: 发送头部(1帧) → RCV_RDY → 发送数据帧 → RCV_OK
    ///
    /// ⚠️ 并发安全重写（2026-09）：
    ///  - 所有 Send* 进入全局 SendRequestLock，避免 A 请求的 RCV_RDY 被 B 线程偷走。
    ///  - WaitAsync 改为 AuthHelper.WaitNotifyAsync → 走队列通路，不会丢失早到的通知。
    /// </summary>
    public class EncryptedChannel
    {
        public static readonly EncryptedChannel Instance = new EncryptedChannel();

        private readonly CryptoEngine _crypto = CryptoEngine.Instance;
        private readonly SemaphoreSlim _sendLock = new(1, 1);

        /// <summary>
        /// 发送加密命令（plaintext）并等待响应
        /// </summary>
        public async Task<Dictionary<string, object?>?> SendAndReceiveAsync(
            WindowsConnector connector,
            byte[] plaintext,
            int timeoutSec = 5)
        {
            if (!_crypto.HasKeys)
                throw new InvalidOperationException("Session keys not established");

            // ⚠️ 全局一次只能有一个 Send 流程：否则 A→头部，B→头部；然后 A 等 RCV_RDY
            //    时拿到"设备给 B 的 RCV_RDY"，后续流程全部错位。
            await _sendLock.WaitAsync().ConfigureAwait(false);
            try
            {
                for (int attempt = 1; attempt <= 3; attempt++)
                {
                    try
                    {
                        if (attempt > 1)
                            AppLogger.Warn($"EncryptedChannel: retry attempt {attempt}/3");

                        var encrypted = _crypto.Encrypt(plaintext);

                        // 1. 发送头部
                        await connector.WriteAsync("cmd_send", new byte[] { 0, 0, 0, 0, 1, 0 });

                        // 2. 等 RCV_RDY
                        var rcvRdy = await AuthHelper.WaitNotifyAsync(connector, "cmd_send", timeoutSec);
                        if (rcvRdy == null || rcvRdy.Length < 4 ||
                            rcvRdy[2] != 1 || rcvRdy[3] != 1)
                        {
                            AppLogger.Warn($"EncryptedChannel: no RCV_RDY (attempt {attempt})");
                            if (attempt >= 3) return null;
                            continue;
                        }

                        // 3. 发送数据帧
                        var frameData = new byte[2 + encrypted.Length];
                        frameData[0] = 1; frameData[1] = 0;
                        Array.Copy(encrypted, 0, frameData, 2, encrypted.Length);
                        await connector.WriteAsync("cmd_send", frameData);

                        // 4. 等 RCV_OK
                        var rcvOk = await AuthHelper.WaitNotifyAsync(connector, "cmd_send", timeoutSec);
                        if (rcvOk == null || rcvOk.Length < 4 ||
                            rcvOk[2] != 1 || rcvOk[3] != 0)
                        {
                            AppLogger.Warn($"EncryptedChannel: no RCV_OK (attempt {attempt})");
                            if (attempt >= 3) return null;
                            continue;
                        }

                        // 5. 等响应
                        var resp = await AuthHelper.WaitNotifyAsync(connector, "cmd_recv", timeoutSec);
                        if (resp == null)
                        {
                            AppLogger.Warn($"EncryptedChannel: no response (attempt {attempt})");
                            if (attempt >= 3) return null;
                            continue;
                        }

                        // 解密
                        var cipherPart = resp.Skip(2).ToArray();
                        var pt = _crypto.Decrypt(cipherPart);
                        if (pt == null)
                        {
                            AppLogger.Warn($"EncryptedChannel: decrypt failed (attempt {attempt})");
                            if (attempt >= 3) return null;
                            continue;
                        }

                        return MiotTlv.Parse(pt);
                    }
                    catch (Exception ex)
                    {
                        AppLogger.Error($"EncryptedChannel: sendAndReceive attempt {attempt} failed: {ex.Message}");
                        if (attempt >= 3) return null;
                        await Task.Delay(500);
                    }
                }
                return null;
            }
            finally
            {
                _sendLock.Release();
            }
        }

        /// <summary>
        /// 发送 MiOT SET 命令（便捷）
        /// </summary>
        public async Task<Dictionary<string, object?>?> SendSetAsync(
            WindowsConnector connector,
            int siid,
            int piid,
            int value,
            int seq = 0)
        {
            var tlvs = MiotTlv.Build(seq, siid, piid, value);
            return await SendAndReceiveAsync(connector, tlvs);
        }

        /// <summary>
        /// 发送 MiOT GET 命令（便捷）
        /// </summary>
        public async Task<Dictionary<string, object?>?> SendGetAsync(
            WindowsConnector connector,
            int siid,
            int piid,
            int seq = 0)
        {
            var tlvs = MiotTlv.Build(seq, siid, piid);
            return await SendAndReceiveAsync(connector, tlvs);
        }
    }
}
