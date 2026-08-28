using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using CukTechController.Ble;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// 协议开关（PIID 21）
    /// </summary>
    public class ProtocolSwitch
    {
        private static readonly ProtocolSwitch _instance = new();
        public static ProtocolSwitch Instance => _instance;

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

        private static readonly string[] Ports = { "c1", "c2", "c3", "a" };

        /// <summary>
        /// 按端口查询协议开关状态（从 PIID 21 原始值解析）
        /// </summary>
        public Dictionary<string, Dictionary<string, bool>> Parse(int rawValue)
        {
            var result = new Dictionary<string, Dictionary<string, bool>>();
            foreach (var port in Ports)
            {
                var bits = ProtocolConstants.ProtocolSwitchBits[port];
                var map = new Dictionary<string, bool>();
                foreach (var entry in bits)
                {
                    map[entry.Key] = (rawValue & (1 << entry.Value)) != 0;
                }
                result[port] = map;
            }
            return result;
        }

        /// <summary>
        /// 按端口+协议开关生成 PIID 21 原始值
        /// </summary>
        public int Encode(Dictionary<string, Dictionary<string, bool>> switches)
        {
            int v = 0;
            foreach (var port in Ports)
            {
                var portSwitches = switches.ContainsKey(port) ? switches[port] : new Dictionary<string, bool>();
                var bits = ProtocolConstants.ProtocolSwitchBits[port];
                foreach (var entry in bits)
                {
                    if (portSwitches.ContainsKey(entry.Key) && portSwitches[entry.Key])
                    {
                        v |= (1 << entry.Value);
                    }
                }
                // c1/c2 的 reserved 位保持为 1 (c1: bit3, c2: bit11)
                if (port == "c1" || port == "c2")
                {
                    int reservedBit = bits.ContainsKey("_reserved") ? bits["_reserved"] : 3;
                    v |= (1 << reservedBit);
                }
            }
            return v;
        }

        /// <summary>
        /// 读取当前 PIID 21 值
        /// </summary>
        public async Task<int?> ReadAsync(WindowsConnector connector)
        {
            var resp = await _channel.SendGetAsync(connector, ProtocolConstants.SiidCharger, 21, NextSeq);
            if (resp == null) return null;
            return resp["value"] as int?;
        }

        /// <summary>
        /// 写入 PIID 21 值
        /// </summary>
        public async Task<bool> WriteAsync(WindowsConnector connector, int value)
        {
            var resp = await _channel.SendSetAsync(connector, ProtocolConstants.SiidCharger, 21, value, NextSeq);
            if (resp == null) return false;
            // 回读验证
            await Task.Delay(300);
            var readBack = await ReadAsync(connector);
            bool ok = readBack == value;
            AppLogger.Info($"ProtocolSwitch: Write {value} -> readBack={readBack} OK={ok}");
            return ok;
        }

        /// <summary>
        /// 便捷: 设置某端口某协议开关
        /// </summary>
        public async Task<bool> SetProtocolAsync(
            WindowsConnector connector,
            string port,
            string protocol,
            bool enabled)
        {
            var current = await ReadAsync(connector);
            if (current == null)
            {
                AppLogger.Warn("ProtocolSwitch: Cannot read current state");
                return false;
            }
            var switches = Parse(current.Value);
            if (!switches.ContainsKey(port))
                switches[port] = new Dictionary<string, bool>();
            switches[port][protocol] = enabled;
            int next = Encode(switches);
            return await WriteAsync(connector, next);
        }

        // ---- 静态辅助方法（供 UI 层调用） ----

        /// <summary>
        /// 列出指定端口支持的协议名称
        /// </summary>
        public static IEnumerable<string> GetProtocolsForPort(string port)
        {
            return ProtocolConstants.ProtocolSwitchBits.TryGetValue(port, out var bits)
                ? bits.Keys.Where(k => !k.StartsWith("_"))
                : Enumerable.Empty<string>();
        }

        /// <summary>
        /// 所有端口列表
        /// </summary>
        public static IEnumerable<string> SupportedPorts => ProtocolConstants.ProtocolSwitchBits.Keys;
    }
}