// TDD RED-GREEN-REFACTOR #5: ProtocolConstants 常量正确性回归测试
// RED: 任何常量写错都会导致测试失败（先写测试，再跑验证）

using CukTechController.Protocol;

namespace CukTechController.Tests.Pure;

public class ProtocolConstantsTests
{
    // AD1204U Product ID (LE uint16 = 0x660E)
    // ha-cuk-ble/cuktech-ble-server 两个项目都验证过
    [Fact]
    public void ProductId_ShouldBe_0x660E()
    {
        Assert.Equal(0x660E, ProtocolConstants.ProductId);
    }

    [Fact]
    public void UuidFe95_ShouldBe_Standard128Bit_Format()
    {
        // 小米 IoT 16-bit Service UUID = 0xFE95
        // 展开成标准 128-bit Bluetooth GATT UUID
        Assert.Equal(
            expected: "0000fe95-0000-1000-8000-00805f9b34fb",
            actual: ProtocolConstants.UuidFe95);
    }

    [Fact]
    public void SiidCharger_ShouldBe_2()
    {
        // 充电器 SIID: ha-cuk-ble is_ad1204_advertisement = siid=2
        Assert.Equal(2, ProtocolConstants.SiidCharger);
    }

    // 端口位掩码 PIID 16
    [Theory]
    [InlineData("c1", 0)]
    [InlineData("c2", 1)]
    [InlineData("c3", 2)]
    [InlineData("a", 3)]
    public void PortBits_Should_Match(string port, int expectedBit)
    {
        Assert.True(ProtocolConstants.PortBits.TryGetValue(port, out int bit));
        Assert.Equal(expectedBit, bit);
    }

    [Theory]
    [InlineData("c1", 9)]
    [InlineData("c2", 10)]
    [InlineData("c3", 11)]
    [InlineData("a", 12)]
    public void TimerPorts_Should_Match(string port, int expectedPiid)
    {
        Assert.True(ProtocolConstants.TimerPorts.TryGetValue(port, out int piid));
        Assert.Equal(expectedPiid, piid);
    }

    [Fact]
    public void GetPortBit_Index0To3_ShouldReturn_C1C2C3A()
    {
        Assert.Equal(0, ProtocolConstants.GetPortBit(0));
        Assert.Equal(1, ProtocolConstants.GetPortBit(1));
        Assert.Equal(2, ProtocolConstants.GetPortBit(2));
        Assert.Equal(3, ProtocolConstants.GetPortBit(3));
    }

    [Fact]
    public void GetPortBit_Invalid4_ShouldThrow()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ProtocolConstants.GetPortBit(4));
    }

    // 可读 PIID 列表应该包含场景模式(5)/息屏时间(6)/倒计时总(8)/
    // 端口倒计时 9-12 /语言(13) /A口小电流(15) /端口掩码(16) /
    // 空闲息屏(19) /屏幕方向锁(20) /协议开关(21)
    [Fact]
    public void ReadableSettingsPiids_ShouldContain_AllKnown()
    {
        var required = new[] { 5, 6, 8, 9, 10, 11, 12, 13, 15, 16, 19, 20, 21 };
        Assert.All(required, piid => Assert.Contains(piid, ProtocolConstants.ReadableSettingsPiids));
    }

    // 协议开关位：C1 PD=0 PPS=1 UFCS=2 (同 ha-cuk-ble)
    [Fact]
    public void ProtocolSwitchBits_C1_ShouldBe_0_1_2()
    {
        Assert.Equal(0, ProtocolConstants.ProtocolSwitchBits["c1"]["pd"]);
        Assert.Equal(1, ProtocolConstants.ProtocolSwitchBits["c1"]["pps"]);
        Assert.Equal(2, ProtocolConstants.ProtocolSwitchBits["c1"]["ufcs"]);
    }

    [Fact]
    public void ProtocolSwitchBits_C3_ShouldBe_UFCS16_SCP17()
    {
        Assert.Equal(16, ProtocolConstants.ProtocolSwitchBits["c3"]["ufcs"]);
        Assert.Equal(17, ProtocolConstants.ProtocolSwitchBits["c3"]["scp"]);
    }
}
