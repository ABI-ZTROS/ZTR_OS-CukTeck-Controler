using System;
using System.Collections.Generic;
using System.Linq;

namespace CukTechController.Protocol
{
    /// <summary>
    /// MiOT TLV 编码/解码器（C# 移植）
    /// 与 Dart 版 miot_tlv.dart 对齐
    /// </summary>
    public static class MiotTlv
    {
        /// <summary>
        /// 构建 SET/GET 命令 TLV
        /// </summary>
        /// <param name="seq">序列号</param>
        /// <param name="siid">服务 ID</param>
        /// <param name="piid">属性 ID</param>
        /// <param name="value">要设置的值；null 时为 GET 命令</param>
        public static byte[] Build(int seq, int siid, int piid, int? value = null)
        {
            bool isSet = value.HasValue;
            int opcode = isSet ? 0x00 : 0x02;

            int typeId;
            byte[] valueBytes;

            if (isSet)
            {
                int v = value!.Value;
                if (v <= 0xFF)
                {
                    typeId = 1; // UINT8
                    valueBytes = new byte[] { (byte)v };
                }
                else
                {
                    typeId = 5; // UINT32
                    valueBytes = new byte[4];
                    valueBytes[0] = (byte)(v & 0xFF);
                    valueBytes[1] = (byte)((v >> 8) & 0xFF);
                    valueBytes[2] = (byte)((v >> 16) & 0xFF);
                    valueBytes[3] = (byte)((v >> 24) & 0xFF);
                }
            }
            else
            {
                typeId = 1;
                valueBytes = new byte[] { 0 };
            }

            int byteLen = valueBytes.Length;
            int tl = (typeId << 12) | byteLen;
            int totalLen = 11 + byteLen;

            var frame = new byte[totalLen];
            frame[0] = (byte)(totalLen & 0xFF);
            frame[1] = 0x20;
            frame[2] = (byte)(seq & 0xFF);
            frame[3] = 0x00;
            frame[4] = (byte)opcode;
            frame[5] = 0x01; // cnt
            frame[6] = (byte)(siid & 0xFF);
            frame[7] = (byte)(piid & 0xFF);
            frame[8] = (byte)((piid >> 8) & 0xFF);
            frame[9] = (byte)(tl & 0xFF);
            frame[10] = (byte)((tl >> 8) & 0xFF);
            Array.Copy(valueBytes, 0, frame, 11, byteLen);

            return frame;
        }

        /// <summary>
        /// 解析响应帧（已解密的 plaintext）
        /// </summary>
        /// <returns>Dictionary 包含 opcode, siid, piid, value, frame; null 表示失败</returns>
        public static Dictionary<string, object?>? Parse(byte[] pt)
        {
            if (pt.Length < 8) return null;

            int b4 = pt[4];
            int siid = pt[6];
            int piid = pt[7];

            int? value = null;
            if (pt.Length >= 12)
            {
                int vlen = pt[11];
                if (vlen >= 4 && pt.Length >= 15)
                {
                    value = pt[11] |
                            (pt[12] << 8) |
                            (pt[13] << 16) |
                            (pt[14] << 24);
                }
                else if (pt.Length > 13)
                {
                    value = pt[13];
                }
            }

            return new Dictionary<string, object?>
            {
                ["opcode"] = b4,
                ["siid"] = siid,
                ["piid"] = piid,
                ["value"] = value,
                ["frame"] = pt,
            };
        }

        /// <summary>响应 opcode 常量</summary>
        public static class OpCodes
        {
            public const int SetAck = 0x01;
            public const int SetRes = 0x04;
            public const int GetRes = 0x03;
            public const int PortPush = 0x02;
        }
    }
}
