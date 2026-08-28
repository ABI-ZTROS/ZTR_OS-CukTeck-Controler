using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble;

/// <summary>
/// 扫描结果
/// </summary>
public record ScanResult(
    string DeviceId,
    string Name,
    int Rssi,
    bool IsCuktech);

/// <summary>
/// Windows BLE 扫描器（基于 Windows.Devices.Bluetooth.Advertisement）
/// 支持：UUID 过滤、名称过滤、超时停止
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
    /// <param name="timeout">扫描超时</param>
    /// <param name="filterCuktech">仅显示酷态科设备</param>
    public async Task<IReadOnlyList<ScanResult>> StartAsync(
        TimeSpan? timeout = null,
        bool filterCuktech = true)
    {
        timeout ??= TimeSpan.FromSeconds(10);
        _results.Clear();

        _watcher = new BluetoothLEAdvertisementWatcher
        {
            ScanningMode = BluetoothLEScanningMode.Active,
        };

        // 按 0xFE95 Service UUID 过滤
        var filter = new BluetoothLEAdvertisementFilter();
        filter.Advertisement.ServiceUuids.Add(Guid.Parse(ProtocolConstants.UuidFe95));
        _watcher.AdvertisementFilter = filter;

        _watcher.Received += (sender, args) =>
        {
            try
            {
                var name = args.Advertisement.LocalName ?? string.Empty;
                var isCuktech = name.ToLowerInvariant().Contains("njcuk");

                // 可选：仅保留酷态科命名设备
                if (filterCuktech && !isCuktech)
                {
                    return;
                }

                var result = new ScanResult(
                    args.BluetoothAddress.ToString("X"),
                    name,
                    args.RawSignalStrengthInDBm,
                    isCuktech);

                lock (_lock) _results.Add(result);
                DeviceFound?.Invoke(this, result);
                AppLogger.Debug($"WindowsScanner: found {result.DeviceId} rssi={result.Rssi} name={name}");
            }
            catch (Exception ex)
            {
                AppLogger.Error($"WindowsScanner: Received callback error: {ex.Message}");
            }
        };

        _watcher.Start();
        AppLogger.Info($"WindowsScanner: scanning started (timeout={timeout.Value.TotalSeconds}s)");

        try
        {
            await Task.Delay(timeout.Value);
        }
        finally
        {
            Stop();
        }

        var snapshot = Results;
        AppLogger.Info($"WindowsScanner: scan complete, {snapshot.Count} devices");
        return snapshot;
    }

    public void Stop()
    {
        if (_watcher != null && _watcher.Status == BluetoothLEAdvertisementWatcherStatus.Started)
        {
            _watcher.Stop();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        Stop();
        _watcher = null;
        _disposed = true;
    }
}
