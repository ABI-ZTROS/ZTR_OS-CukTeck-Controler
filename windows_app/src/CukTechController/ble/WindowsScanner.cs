using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth;
using Windows.Storage.Streams;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble;

/// <summary>扫描结果</summary>
public record ScanResult(
    string DeviceId,
    ulong BluetoothAddress,
    string Name,
    int Rssi,
    bool IsCuktech,
    int? ProductId = null,
    string? ServiceDataHex = null);

/// <summary>
/// Windows BLE 扫描器（基于 Windows.Devices.Bluetooth.Advertisement）
///
/// 🔑 识别策略（已对齐 ha-cuk-ble / cuktech-ble-server 参照项目 & Android 版）：
///   1. **硬件层**: 扫全量 —— 不使用 AdvertisementFilter.ServiceUuids
///      ❌ BluetoothLEAdvertisementFilter.ServiceUuids 只匹配 AD 0x02/0x03
///         (Complete/Incomplete List of Service UUIDs)，而小米 IoT 设备把 FE95
///         放在 AD 0x16 (Service Data) 里 —— 硬件过滤直接把充电器挡掉
///   2. **Dart/C# 层**: 检查 args.Advertisement.DataSections 中 AD Type == 0x16
///      的 Service Data，按 16-bit UUID = 0xFE95 定位帧内容
///   3. **进阶验证**: 解析 FE95 service-data frame 里的 product_id 是否
///      等于 0x660E (AD1204U) — 避免误识别其他小米台灯/净化器
///
/// ⚠️ 为什么不靠名字？因为米家可以远程改设备蓝牙广播名。
///    FE95 广播帧的 product_id 是协议层硬编码字段，改名不影响它。
/// </summary>
public class WindowsScanner : IDisposable
{
    private static WindowsScanner? _instance;
    private static readonly object _instanceLock = new();

    public static WindowsScanner Instance
    {
        get
        {
            lock (_instanceLock)
            {
                _instance ??= new WindowsScanner();
                return _instance;
            }
        }
    }

    // FE95 Service UUID 的 16-bit 短形式（AD 0x16 的前 2 字节 LE）
    private const ushort Uuid16Fe95 = 0xFE95;
    private const byte AdTypeServiceData16Bit = 0x16;
    private const int Ad1204ProductId = 0x660E;

    private BluetoothLEAdvertisementWatcher? _watcher;
    private readonly List<ScanResult> _results = new();
    private readonly object _lock = new();
    private bool _disposed;

    public IReadOnlyList<ScanResult> Results
    {
        get { lock (_lock) return _results.ToList(); }
    }

    public event EventHandler<ScanResult>? DeviceFound;

    /// <summary>
    /// 开始扫描
    /// </summary>
    /// <param name="timeout">扫描超时（默认 10 秒）</param>
    /// <param name="filterCuktech">仅保留 AD1204U 酷态科设备</param>
    public async Task<IReadOnlyList<ScanResult>> StartAsync(
        TimeSpan? timeout = null,
        bool filterCuktech = true)
    {
        timeout ??= TimeSpan.FromSeconds(10);
        lock (_lock) _results.Clear();

        // ❌ 不再使用 AdvertisementFilter：小米把 FE95 放在 AD 0x16 (Service Data)，
        //    而 Windows 广告过滤器的 ServiceUuids 只看 AD 0x02/0x03（Service UUID List）。
        _watcher = new BluetoothLEAdvertisementWatcher
        {
            ScanningMode = BluetoothLEScanningMode.Active,
        };

        _watcher.Received += (sender, args) => OnAdvertisementReceived(args, filterCuktech);

        var cts = new CancellationTokenSource(timeout.Value);
        using var reg = cts.Token.Register(() =>
        {
            try { Stop(); } catch { /* noop */ }
        });

        _watcher.Stopped += (s, e) =>
        {
            AppLogger.Debug($"WindowsScanner: watcher stopped (Error={e.Error})");
        };

        try
        {
            _watcher.Start();
            AppLogger.Info(
                $"WindowsScanner: scanning (timeout={timeout.Value.TotalSeconds:F0}s, " +
                $"filterCuktech={filterCuktech})");

            // 等待 watcher 自己停下（超时触发 Stop()）或手动 Stop()
            // BLE watcher 是事件驱动，需要等事件循环。
            try
            {
                await Task.Delay(timeout.Value, cts.Token);
            }
            catch (OperationCanceledException) { /* expected */ }
            finally { Stop(); }

            var snapshot = Results;
            AppLogger.Info(
                $"WindowsScanner: scan complete, {snapshot.Count} device(s) found");
            return snapshot;
        }
        catch (Exception ex)
        {
            AppLogger.Error($"WindowsScanner: scan failed: {ex.Message}");
            Stop();
            throw;
        }
        finally
        {
            cts.Dispose();
        }
    }

    /// <summary>
    /// 处理单条广播包：解析 Service Data 0x16 FE95 + product_id
    /// </summary>
    private void OnAdvertisementReceived(
        BluetoothLEAdvertisementReceivedEventArgs args,
        bool filterCuktech)
    {
        try
        {
            byte[]? fe95Data = null;
            foreach (var section in args.Advertisement.DataSections)
            {
                if (section.DataType != AdTypeServiceData16Bit) continue;
                var reader = DataReader.FromBuffer(section.Data);
                if (reader.UnconsumedBufferLength < 2) continue;
                byte[] raw = new byte[reader.UnconsumedBufferLength];
                reader.ReadBytes(raw);
                ushort shortUuid = (ushort)(raw[0] | (raw[1] << 8)); // LE uint16
                if (shortUuid == Uuid16Fe95)
                {
                    // 后面才是真正的 FE95 帧
                    fe95Data = raw.Length > 2 ? raw.AsSpan(2).ToArray() : Array.Empty<byte>();
                    break;
                }
            }

            // ✅ 判断 1：FE95 Service Data 存在
            bool hasFe95 = fe95Data != null && fe95Data.Length > 0;

            // ✅ 判断 2：product_id == AD1204U (0x660E)
            int? productId = null;
            if (fe95Data != null && fe95Data.Length >= 5)
            {
                productId = fe95Data[2] | (fe95Data[3] << 8); // LE uint16
            }
            bool isExactAd1204 = productId == Ad1204ProductId;

            if (filterCuktech && !isExactAd1204)
            {
                return;
            }

            ulong addr = args.BluetoothAddress;
            string deviceId = addr.ToString("X12");
            string name = args.Advertisement.LocalName ?? string.Empty;

            var result = new ScanResult(
                DeviceId: deviceId,
                BluetoothAddress: addr,
                Name: name,
                Rssi: args.RawSignalStrengthInDBm,
                IsCuktech: isExactAd1204,
                ProductId: productId,
                ServiceDataHex: hasFe95 ? Hex(fe95Data!) : null);

            lock (_lock) _results.Add(result);
            DeviceFound?.Invoke(this, result);

            AppLogger.Instance.D(
                "WindowsScanner",
                $"📡 Found {deviceId} rssi={result.Rssi} name=\"{name}\" " +
                $"fe95={(hasFe95 ? "yes" : "no")} " +
                $"pid=0x{productId:X4} exact={isExactAd1204}");
        }
        catch (Exception ex)
        {
            AppLogger.Instance.E("WindowsScanner", $"Received callback error: {ex.Message}");
        }
    }

    public void Stop()
    {
        if (_watcher != null && _watcher.Status == BluetoothLEAdvertisementWatcherStatus.Started)
        {
            try { _watcher.Stop(); } catch { /* noop */ }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        Stop();
        _watcher = null;
        _disposed = true;
    }

    private static string Hex(byte[] data)
    {
        var sb = new System.Text.StringBuilder(data.Length * 2);
        foreach (var b in data) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }
}
