using System;
using System.Collections.Generic;

namespace CukTechController.Protocol;

/// <summary>
/// 酷态科 BLE 协议常量（C# 移植）
/// 参考: kairui1108/cuktech-ble-ha/src/cuktech_ble/protocol.py
/// 与 Dart 版 constants.dart 完全对齐。
/// </summary>
public static class ProtocolConstants
{
    // ---- GATT Service UUID ----
    public const string UuidFe95 = "0000fe95-0000-1000-8000-00805f9b34fb";

    /// <summary>服务 UUID（Guid 形式，便于 Windows.Devices.Bluetooth API 使用）</summary>
    public static readonly Guid ServiceUuid = Guid.Parse(UuidFe95);

    // ---- GATT Characteristic UUIDs ----
    public const string CharDeviceInfo = "0000001c-0000-1000-8000-00805f9b34fb";
    public const string CharAuthCtrl   = "00000010-0000-1000-8000-00805f9b34fb";
    public const string CharAuthData   = "00000019-0000-1000-8000-00805f9b34fb";
    public const string CharCmdSend    = "0000001a-0000-1000-8000-00805f9b34fb";
    public const string CharCmdRecv    = "0000001b-0000-1000-8000-00805f9b34fb";
    public const string CharFwVersion  = "00000004-0000-1000-8000-00805f9b34fb";

    // ---- GATT Handles ----
    public const int HandleDeviceInfo = 0x001f;
    public const int HandleAuthCtrl   = 0x000d;
    public const int HandleAuthData   = 0x0010;
    public const int HandleCmdSend    = 0x0019;
    public const int HandleCmdRecv    = 0x001c;
    public const int HandleFwVersion  = 0x0008;

    // ---- MiOT ----
    public const int SiidCharger = 2;
    public const int ProductId   = 0x660e;

    // ---- PIID 名称映射（与 Dart 版一致） ----
    public static readonly IReadOnlyDictionary<int, string> PiidNames =
        new Dictionary<int, string>
        {
            [1]  = "C1口数据", [2]  = "C2口数据", [3]  = "C3口数据", [4]  = "A口数据",
            [5]  = "场景模式", [6]  = "息屏时间", [7]  = "协议控制", [8]  = "倒计时设置",
            [9]  = "C1口倒计时", [10] = "C2口倒计时", [11] = "C3口倒计时", [12] = "A口倒计时",
            [13] = "语言", [14] = "进入界面", [15] = "USB-A小电流", [16] = "端口控制",
            [17] = "未知-17", [18] = "未知-18", [19] = "空闲息屏", [20] = "屏幕方向锁",
        };

    // ---- PIID 显示映射（与 Dart 版一致） ----
    public static readonly IReadOnlyDictionary<int, IReadOnlyDictionary<int, string>> PiidDisplay =
        new Dictionary<int, IReadOnlyDictionary<int, string>>
        {
            [5]  = new Dictionary<int, string> { [1] = "AI模式", [2] = "数码生态", [3] = "单口模式", [4] = "均衡模式" },
            [6]  = new Dictionary<int, string> { [1] = "5分钟", [2] = "10分钟", [3] = "30分钟", [4] = "常亮", [5] = "1分钟" },
            [13] = new Dictionary<int, string> { [0] = "English", [1] = "中文" },
            [15] = new Dictionary<int, string> { [0] = "关闭", [1] = "开启" },
            [19] = new Dictionary<int, string> { [0] = "关闭", [1] = "开启" },
            [20] = new Dictionary<int, string> { [0] = "关闭", [1] = "开启" },
        };

    // ---- TLV 命令 / 数据类型常量（供 PortControl / MiotTlv 使用） ----
    public const int TlvCommandGet    = 0x01;
    public const int TlvCommandSet    = 0x02;
    public const int TlvCommandNotify = 0x03;

    public const int TlvTypeUint8  = 0x01;
    public const int TlvTypeUint16 = 0x02;
    public const int TlvTypeUint32 = 0x03;
    public const int TlvTypeString = 0x04;
    public const int TlvTypeBytes  = 0x05;

    // ---- 端口位掩码 (PIID 16) ----
    public static readonly IReadOnlyDictionary<string, int> PortBits =
        new Dictionary<string, int>
        {
            ["c1"] = 0, ["c2"] = 1, ["c3"] = 2, ["a"] = 3,
        };

    /// <summary>
    /// 按端口索引获取位偏移（供 PortControl 等遗留调用方使用）。
    /// </summary>
    public static int GetPortBit(int portIndex)
    {
        return portIndex switch
        {
            0 => PortBits["c1"],
            1 => PortBits["c2"],
            2 => PortBits["c3"],
            3 => PortBits["a"],
            _ => throw new ArgumentOutOfRangeException(nameof(portIndex)),
        };
    }

    // ---- 端口 → 倒计时 PIID 映射 ----
    public static readonly IReadOnlyDictionary<string, int> TimerPorts =
        new Dictionary<string, int>
        {
            ["c1"] = 9, ["c2"] = 10, ["c3"] = 11, ["a"] = 12,
        };

    // ---- 协议开关位 (PIID 21) ----
    // c1Flags: bit0=PD, bit1=PPS, bit2=UFCS, bit3=reserved
    // c2Flags: 同上
    // c3Flags: bit0=UFCS, bit1=SCP
    // aFlags:  bit0=UFCS, bit1=SCP
    public static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, int>> ProtocolSwitchBits =
        new Dictionary<string, IReadOnlyDictionary<string, int>>
        {
            ["c1"] = new Dictionary<string, int> { ["pd"] = 0, ["pps"] = 1, ["ufcs"] = 2, ["_reserved"] = 3 },
            ["c2"] = new Dictionary<string, int> { ["pd"] = 8, ["pps"] = 9, ["ufcs"] = 10, ["_reserved"] = 11 },
            ["c3"] = new Dictionary<string, int> { ["ufcs"] = 16, ["scp"] = 17 },
            ["a"]  = new Dictionary<string, int> { ["ufcs"] = 24, ["scp"] = 25 },
        };

    // ---- 可读 PIID 列表 ----
    public static readonly IReadOnlyList<int> ReadableSettingsPiids =
        new[] { 5, 6, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19, 20, 21 };

    // ---- 超时与重试 ----
    public static readonly TimeSpan BleTimeout = TimeSpan.FromSeconds(5);
    public const int BleMaxRetries = 3;

    /// <summary>设备 MAC 地址占位（运行时获取）</summary>
    public static string DeviceMac = string.Empty;
}
