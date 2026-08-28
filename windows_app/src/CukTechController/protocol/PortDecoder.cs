using System;
using System.Collections.Generic;
using CukTechController.Ble;
using CukTechController.Models;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// 端口类型
    /// </summary>
    public enum PortType
    {
        C1C2, // C1/C2: Type-C 全系列 PD
        C3,   // C3: 混合口 PD+QC
        A,    // A 口: USB-A+QC
    }

    /// <summary>
    /// 原始端口数据
    /// </summary>
    public class RawPortData
    {
        public RawPortData(int statusRaw, int code, int currentRaw, int voltageRaw)
        {
            StatusRaw = statusRaw;
            Code = code;
            CurrentRaw = currentRaw;
            VoltageRaw = voltageRaw;
        }

        public int StatusRaw { get; }
        public int Code { get; }
        public int CurrentRaw { get; }
        public int VoltageRaw { get; }

        public bool InUse => StatusRaw != 0;
        public double Current => CurrentRaw / 10.0; // mA → A
        public double Voltage => VoltageRaw / 10.0; // 10mV → V
        public double Power => Math.Round(Voltage * Current, 1);

        /// <summary>
        /// 从 MiOT 属性 payload（plaintext）解析
        /// </summary>
        public static RawPortData? FromPayload(byte[] payload)
        {
            if (payload.Length < 12) return null;
            // 最后 4 字节: [status, code, current, voltage]
            int offset = payload.Length - 4;
            return new RawPortData(
                payload[offset],
                payload[offset + 1],
                payload[offset + 2],
                payload[offset + 3]
            );
        }
    }

    /// <summary>
    /// 米家协议号 → 协议名
    /// </summary>
    public static class MijiaProtocols
    {
        public static readonly IReadOnlyDictionary<int, string> Map =
            new Dictionary<int, string>
            {
                [0] = "idle", [1] = "5V", [2] = "5V", [3] = "QC", [4] = "AFC",
                [5] = "FCP", [6] = "SCP", [7] = "PD", [8] = "PPS", [9] = "PPS", [10] = "UFCS",
            };

        public static string GetName(int protoNum) =>
            Map.TryGetValue(protoNum, out var name)
                ? name
                : $"Unknown (0x{protoNum:X2})";
    }

    /// <summary>
    /// 协议号估算（与 Python V2 / Dart 版对齐的启发式算法）
    /// </summary>
    public static class ProtocolEstimator
    {
        public static int EstimateProtocolNumber(int piid, RawPortData raw)
        {
            double voltage = raw.Voltage;
            int code = raw.Code;

            // 未使用或 code=0 → idle
            if (!raw.InUse || code == 0) return 0;

            // PD 固定档位
            double[] pdFixed = { 5.0, 9.0, 12.0, 15.0, 20.0 };

            if (piid == 4)
            {
                // A 口
                if (voltage <= 5.5) return 1; // 5V
                if (voltage <= 12.5) return 3; // QC
                return 3;
            }

            // C 口（C1/C2/C3）
            if (voltage <= 5.5) return 1; // 5V
            if (voltage <= 9.5) return 5; // FCP
            if (voltage <= 12.5)
            {
                // QC 或 PPS
                if (code >= 3 && code <= 5) return 3; // QC
                return 8; // PPS
            }
            if (voltage <= 15.5) return 7; // PD Fixed
            if (voltage <= 20.5) return 7; // PD
            return 10; // UFCS
        }
    }

    /// <summary>
    /// 端口解码器 —— 完整移植 V2 协议检测引擎
    /// </summary>
    public class PortDecoder
    {
        private static readonly PortDecoder _instance = new();
        public static PortDecoder Instance => _instance;

        /// <summary>
        /// 端口类型
        /// </summary>
        public static PortType GetPortType(int piid)
        {
            if (piid == 1 || piid == 2) return PortType.C1C2;
            if (piid == 3) return PortType.C3;
            if (piid == 4) return PortType.A;
            throw new ArgumentException($"Invalid PIID: {piid}");
        }

        /// <summary>
        /// 解码端口 TLV 推送数据
        /// </summary>
        /// <param name="piid">端口 PIID (1-4)</param>
        /// <param name="payload">MiOT plaintext payload（已解密）</param>
        /// <returns>PortState 或 null</returns>
        public static PortState? Decode(int piid, byte[] payload)
        {
            var raw = RawPortData.FromPayload(payload);
            if (raw == null) return null;

            int protoNum = ProtocolEstimator.EstimateProtocolNumber(piid, raw);
            var state = new PortState
            {
                Piid = piid,
                Voltage = raw.Voltage,
                Current = raw.Current,
                Power = raw.Power,
                Protocol = MijiaProtocols.GetName(protoNum),
                Active = raw.InUse,
            };

            PortStreamController.Instance.Publish(state);
            AppLogger.Debug(
                $"PortDecoder: Port {piid}: {state.Voltage:F1}V {state.Current:F1}A {state.Power:F1}W {state.Protocol}");
            return state;
        }

        /// <summary>
        /// 从解析好的 TLV map（包含 B4=0x02 推送）批量解码
        /// </summary>
        public static void DispatchFromTlvMap(Dictionary<string, object?> tlv)
        {
            int? b4 = tlv["opcode"] as int?;
            int? siid = tlv["siid"] as int?;
            int? piid = tlv["piid"] as int?;
            byte[]? frame = tlv["frame"] as byte[];

            if (b4 != 0x02 || siid != 2 || piid == null || frame == null) return;
            if (piid < 1 || piid > 4) return;

            // frame 结构: [tot_len][0x20][seq][0][opcode=02][cnt=1][siid=2][piid_lo][piid_hi][tl_lo][tl_hi][value...]
            int tl = frame[9] | (frame[10] << 8);
            int valueLen = tl & 0xFFF;
            // 跳过 value 的前几个字节（type+len），获取原始 payload
            int payloadStart = 11 + 2; // type_id(1) + len(1)
            if (frame.Length >= payloadStart + valueLen)
            {
                byte[] payload = new byte[valueLen];
                Array.Copy(frame, payloadStart, payload, 0, valueLen);
                Decode(piid.Value, payload);
            }
        }
    }
}