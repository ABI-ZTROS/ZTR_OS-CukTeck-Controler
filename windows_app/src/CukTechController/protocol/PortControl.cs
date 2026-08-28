using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using CukTechController.Ble;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// 单口控制（PIID 16）
    /// </summary>
    public class PortControl
    {
        private static readonly PortControl _instance = new();
        public static PortControl Instance => _instance;

        private readonly EncryptedChannel _channel = EncryptedChannel.Instance;
        private int _miotSeq = 1;

        private int NextSeq
        {
            get
            {
                int s = _miotSeq;
                _miotSeq = (_miotSeq + 1) & 0xFF;
                return s;
            }
        }

        /// <summary>
        /// 查询端口状态（当前位掩码）
        /// </summary>
        public async Task<int?> ReadStateAsync(WindowsConnector connector)
        {
            var resp = await _channel.SendGetAsync(connector, ProtocolConstants.SiidCharger, 16, NextSeq);
            if (resp == null) return null;
            return resp["value"] as int?;
        }

        /// <summary>
        /// 设置端口位掩码
        /// </summary>
        public async Task<Dictionary<string, object?>?> WriteMaskAsync(
            WindowsConnector connector,
            int mask)
        {
            return await _channel.SendSetAsync(connector, ProtocolConstants.SiidCharger, 16, mask, NextSeq);
        }

        /// <summary>
        /// 便捷: 切换单口开关
        /// </summary>
        /// <param name="port">'c1'/'c2'/'c3'/'a'/'all'</param>
        /// <param name="on">true 开 / false 关</param>
        public async Task<bool> SetPortAsync(WindowsConnector connector, string port, bool on)
        {
            var current = await ReadStateAsync(connector);
            int mask;
            if (current == null)
            {
                AppLogger.Warn("PortControl: Cannot read current state");
                return false;
            }
            mask = current.Value;

            if (port == "all")
            {
                mask = on ? 0x0F : 0x00;
            }
            else
            {
                if (!ProtocolConstants.PortBits.TryGetValue(port, out int bit))
                {
                    AppLogger.Error($"PortControl: Unknown port: {port}");
                    return false;
                }
                if (on)
                {
                    mask = mask | (1 << bit);
                }
                else
                {
                    mask = mask & ~(1 << bit);
                }
            }

            if (mask == current)
            {
                AppLogger.Info($"PortControl: Port {port} already {(on ? "on" : "off")}");
                return true;
            }

            var resp = await WriteMaskAsync(connector, mask);
            if (resp == null)
            {
                AppLogger.Error("PortControl: Write failed");
                return false;
            }

            // 回读验证
            await Task.Delay(300);
            var readBack = await ReadStateAsync(connector);
            bool ok = readBack == mask;
            AppLogger.Info(
                $"PortControl: Set {port}={(on ? "on" : "off")} -> mask={mask} readBack={readBack} OK={ok}");
            return ok;
        }
    }
}