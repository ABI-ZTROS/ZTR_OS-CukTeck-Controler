using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble
{
    /// <summary>
    /// 加密命令通道
    /// 负责通过 CMD_SEND / CMD_RECV 通道发送加密命令并接收响应。
    /// 握手: 发送头部(1帧) → RCV_RDY → 发送数据帧 → RCV_OK
    /// </summary>
    public class EncryptedChannel
    {
        public static readonly EncryptedChannel Instance = new EncryptedChannel();

        private readonly CryptoEngine _crypto = CryptoEngine.Instance;

        /// <summary>
        /// 发送加密命令（plaintext）并等待响应
        /// </summary>
        /// <param name="connector">BLE 连接器</param>
        /// <param name="plaintext">明文数据</param>
        /// <param name="timeoutSec">超时秒数</param>
        /// <returns>解析后的响应或 null</returns>
        public async Task<Dictionary<string, object?>?> SendAndReceiveAsync(
            WindowsConnector connector,
            byte[] plaintext,
            int timeoutSec = 8)
        {
            if (!_crypto.HasKeys)
                throw new InvalidOperationException("Session keys not established");

            var encrypted = _crypto.Encrypt(plaintext);

            try
            {
                // 1. 发送头部
                await connector.WriteAsync("cmd_send", new byte[] { 0, 0, 0, 0, 1, 0 });

                // 2. 等 RCV_RDY
                var rcvRdy = await WaitAsync(connector, "cmd_send", timeoutSec);
                if (rcvRdy == null || rcvRdy.Length < 4 ||
                    rcvRdy[2] != 1 || rcvRdy[3] != 1)
                {
                    AppLogger.Warn("EncryptedChannel: no RCV_RDY");
                    return null;
                }

                // 3. 发送数据帧
                var frameData = new byte[2 + encrypted.Length];
                frameData[0] = 1; frameData[1] = 0;
                Array.Copy(encrypted, 0, frameData, 2, encrypted.Length);
                await connector.WriteAsync("cmd_send", frameData);

                // 4. 等 RCV_OK
                var rcvOk = await WaitAsync(connector, "cmd_send", timeoutSec);
                if (rcvOk == null || rcvOk.Length < 4 ||
                    rcvOk[2] != 1 || rcvOk[3] != 0)
                {
                    AppLogger.Warn("EncryptedChannel: no RCV_OK");
                    return null;
                }

                // 5. 等响应
                var resp = await WaitAsync(connector, "cmd_recv", timeoutSec);
                if (resp == null) return null;

                // 解密
                var cipherPart = resp.Skip(2).ToArray();
                var pt = _crypto.Decrypt(cipherPart);
                if (pt == null) return null;

                return MiotTlv.Parse(pt);
            }
            catch (Exception ex)
            {
                AppLogger.Error($"EncryptedChannel: sendAndReceive failed: {ex.Message}", ex);
                return null;
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

        private static async Task<byte[]?> WaitAsync(
            WindowsConnector connector,
            string channel,
            int timeoutSec)
        {
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
                        tcs.TrySetResult(Array.Empty<byte>());
                });

                var result = await tcs.Task;
                if (result.Length == 0) return null;
                return result;
            }
            finally
            {
                connector.ValueReceived -= Handler;
                cts?.Dispose();
            }
        }
    }
}
