using System;
using System.Linq;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble
{
    /// <summary>
    /// 将 BLE cmd_recv 通知连接到 PortDecoder
    /// 在认证成功后调用 WireUp() 启动端口数据解码
    /// </summary>
    public static class PortDecoderWiring
    {
        private static EventHandler<(string Channel, byte[] Data)>? _handler;

        /// <summary>
        /// 启动端口数据解码订阅
        /// </summary>
        public static void WireUp(WindowsConnector connector)
        {
            if (_handler != null)
            {
                connector.ValueReceived -= _handler;
            }

            _handler = (sender, e) =>
            {
                if (e.Channel != "cmd_recv") return;
                try
                {
                    var data = e.Data;
                    if (data.Length < 3) return;

                    var crypto = CryptoEngine.Instance;
                    if (!crypto.HasKeys)
                    {
                        AppLogger.Warn("PortDecoderWiring: No session keys, cannot decrypt");
                        return;
                    }

                    var ciphertext = data.Skip(2).ToArray();
                    var plaintext = crypto.Decrypt(ciphertext);
                    if (plaintext == null || plaintext.Length == 0)
                    {
                        AppLogger.Warn("PortDecoderWiring: Decrypt failed");
                        return;
                    }

                    var tlv = MiotTlv.Parse(plaintext);
                    if (tlv == null) return;

                    // 如果是端口推送 (opcode=0x02, siid=2)
                    PortDecoder.DispatchFromTlvMap(tlv);
                }
                catch (Exception ex)
                {
                    AppLogger.Error("PortDecoderWiring", $"Decode error: {ex.Message}", ex);
                }
            };

            connector.ValueReceived += _handler;
            AppLogger.Info("PortDecoderWiring", "Port decoder wired up on cmd_recv");
        }

        /// <summary>
        /// 停止端口数据解码订阅
        /// </summary>
        public static void TearDown(WindowsConnector connector)
        {
            if (_handler != null)
            {
                connector.ValueReceived -= _handler;
                _handler = null;
                AppLogger.Info("PortDecoderWiring", "Port decoder torn down");
            }
        }
    }
}
