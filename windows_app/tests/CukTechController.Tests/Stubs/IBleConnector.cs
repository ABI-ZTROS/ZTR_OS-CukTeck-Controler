// Test-only stub: 这些文件里的代码在 Linux 上也能跑
// 真实生产代码使用 WindowsConnector（WinRT BLE，仅 Windows）
// 但我们只测纯逻辑类（Crypto/Constants/Tlv/PortStream/ScanParser）
namespace CukTechController.Ble;

/// <summary>
/// 仅供测试引用：生产代码中使用 WindowsConnector (WinRT BLE)
/// 测试项目不需要真实 BLE，仅需编译链接。
/// </summary>
public interface IBleConnector
{
    event EventHandler<(string Channel, byte[] Data)>? ValueReceived;
    Task WriteAsync(string channel, byte[] data);
    Task<byte[]> ReadAsync(string channel);
}
