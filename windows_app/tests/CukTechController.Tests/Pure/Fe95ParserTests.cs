// TDD RED-GREEN-REFACTOR #1: FE95 Service Data 解析（product_id=0x660E）
// 对应 WindowsScanner 的识别逻辑 — 先写测试，验证失败，然后让实现对应它。
// 注意：和 Android 版 android_scanner.dart 完全对齐。

namespace CukTechController.Tests.Pure;

/// <summary>
/// FE95 (Xiaomi IoT) Service Data frame parser
/// 帧结构（小端，和 ha-cuk-ble 项目 fe95.py 完全一致）：
///   bytes 0-1 : frame_control (uint16 LE)
///   bytes 2-3 : product_id    (uint16 LE)  ← AD1204U = 0x660E
///   byte  4   : frame_counter
///   bytes 5-10: MAC (6 bytes, 如果 frame_control bit5 = 1)
///   bytes 11+ : payload
/// </summary>
public static class Fe95FrameParser
{
    public const int AD1204ProductId = 0x660E;

    /// <summary>解析 frame 里的 product_id；返回 null 表示帧过短</summary>
    public static int? ParseProductId(byte[] data)
    {
        if (data == null || data.Length < 5) return null;
        return data[2] | (data[3] << 8); // LE uint16
    }

    /// <summary>true = 这个 Service Data 确实来自 AD1204U (酷态科10号Ultra)</summary>
    public static bool IsAd1204(byte[] data) => ParseProductId(data) == AD1204ProductId;
}

public class Fe95ParserTests
{
    // 最小帧: fc(2) + product_id(2) + fc(1) = 5 bytes
    [Fact]
    public void ParseProductId_Ad1204MinimalFrame_ShouldReturn_0x660E()
    {
        byte[] frame =
        {
            0x40, 0x58,  // frame_control (示例值)
            0x0E, 0x66,  // product_id LE = 0x660E
            0x01,        // frame_counter = 1
        };
        Assert.Equal(0x660E, Fe95FrameParser.ParseProductId(frame));
        Assert.True(Fe95FrameParser.IsAd1204(frame));
    }

    [Fact]
    public void ParseProductId_ShortFrame_ShouldReturnNull()
    {
        byte[] shortFrame = { 0x40, 0x58, 0x0E }; // 只有 3 bytes
        Assert.Null(Fe95FrameParser.ParseProductId(shortFrame));
    }

    [Fact]
    public void ParseProductId_Null_ShouldReturnNull()
    {
        Assert.Null(Fe95FrameParser.ParseProductId(null!));
    }

    [Fact]
    public void IsAd1204_DifferentDevice_ShouldBeFalse()
    {
        // 其他小米设备 (比如 product_id=0x1234)
        byte[] frame =
        {
            0x40, 0x58,
            0x34, 0x12,  // LE 0x1234
            0x01,
        };
        Assert.False(Fe95FrameParser.IsAd1204(frame));
    }

    [Fact]
    public void IsAd1204_FullFrameWithMac_ShouldRecognize()
    {
        // frame_control bit5=1 → contains 6-byte MAC after byte 4
        byte[] longFrame =
        {
            0x40, 0x58,
            0x0E, 0x66,  // product_id = AD1204
            0x01,        // counter
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // MAC
            0x01, 0x02, 0x03, // payload
        };
        Assert.True(Fe95FrameParser.IsAd1204(longFrame));
    }

    // 用户改了蓝牙广播名字的场景：只靠 product_id 就能识别
    [Fact]
    public void IsAd1204_DoesNotDependOn_BluetoothName()
    {
        byte[] frame = { 0x40, 0x58, 0x0E, 0x66, 0x01 };
        // 不管广播名是不是 "njcuk" / "我的酷态科10号" / "老张的充电器"
        // product_id 对就行
        Assert.True(Fe95FrameParser.IsAd1204(frame));
    }
}
