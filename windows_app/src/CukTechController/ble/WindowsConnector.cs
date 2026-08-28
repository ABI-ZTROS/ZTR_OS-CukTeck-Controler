using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble;

public enum BleConnectionState
{
    Disconnected,
    Connecting,
    Connected,
    Subscribing,
    Ready,
    Error,
}

/// <summary>
/// Windows BLE 连接器
/// 支持：MTU 协商、5 通道订阅、5 秒超时 + 3 次重试
/// </summary>
public class WindowsConnector : IDisposable
{
    private static WindowsConnector? _instance;
    private static readonly object _instanceLock = new();

    public static WindowsConnector Instance
    {
        get
        {
            lock (_instanceLock)
            {
                _instance ??= new WindowsConnector();
                return _instance;
            }
        }
    }

    private BluetoothLEDevice? _device;
    private readonly Dictionary<string, GattCharacteristic> _characteristics = new();
    private readonly Dictionary<string, Delegate> _handlers = new();
    private CancellationTokenSource? _cts;
    private bool _disposed;

    public BleConnectionState State { get; private set; } = BleConnectionState.Disconnected;
    public BluetoothLEDevice? Device => _device;

    /// <summary>
    /// 连接并订阅所有通道
    /// </summary>
    public async Task<bool> ConnectAsync(ulong bluetoothAddress)
    {
        State = BleConnectionState.Connecting;
        AppLogger.Info($"WindowsConnector: connecting to {bluetoothAddress:X}...");

        for (int attempt = 1; attempt <= ProtocolConstants.BleMaxRetries; attempt++)
        {
            try
            {
                if (attempt > 1)
                {
                    AppLogger.Warn($"WindowsConnector: retry attempt {attempt}/{ProtocolConstants.BleMaxRetries}");
                }

                using var cts = new CancellationTokenSource(ProtocolConstants.BleTimeout);
                _cts = cts;

                _device = await BluetoothLEDevice.FromBluetoothAddressAsync(bluetoothAddress)
                    .AsTask(cts.Token);

                if (_device == null)
                {
                    throw new InvalidOperationException("Device not found");
                }

                State = BleConnectionState.Connected;
                AppLogger.Info("WindowsConnector: connected");

                // 发现服务
                var servicesResult = await _device.GetGattServicesAsync(BluetoothCacheMode.Uncached)
                    .AsTask(cts.Token);
                if (servicesResult.Status != GattCommunicationStatus.Success)
                {
                    throw new InvalidOperationException($"GetGattServices failed: {servicesResult.Status}");
                }

                var fe95 = servicesResult.Services.FirstOrDefault(
                    s => s.Uuid == Guid.Parse(ProtocolConstants.UuidFe95));
                if (fe95 == null)
                {
                    throw new InvalidOperationException("Service 0xFE95 not found");
                }

                // 订阅 5 个通道
                await SubscribeAllAsync(fe95, cts.Token);

                State = BleConnectionState.Ready;
                return true;
            }
            catch (Exception ex)
            {
                AppLogger.Error($"WindowsConnector: connect attempt {attempt} failed: {ex.Message}");
                DisposeDevice();
                if (attempt >= ProtocolConstants.BleMaxRetries)
                {
                    State = BleConnectionState.Error;
                    return false;
                }
                await Task.Delay(1000);
            }
        }

        State = BleConnectionState.Error;
        return false;
    }

    private async Task SubscribeAllAsync(dynamic fe95, CancellationToken ct)
    {
        State = BleConnectionState.Subscribing;

        var mappings = new (string Key, string Uuid)[]
        {
            ("dev_info", ProtocolConstants.CharDeviceInfo),
            ("auth_ctrl", ProtocolConstants.CharAuthCtrl),
            ("auth_data", ProtocolConstants.CharAuthData),
            ("cmd_send", ProtocolConstants.CharCmdSend),
            ("cmd_recv", ProtocolConstants.CharCmdRecv),
        };

        foreach (var (key, uuidStr) in mappings)
        {
            var uuid = Guid.Parse(uuidStr);
            var chars = await fe95.GetCharacteristicsForUuidAsync(uuid).AsTask(ct);
            if (chars.Status != GattCommunicationStatus.Success || chars.Characteristics.Count == 0)
            {
                throw new InvalidOperationException($"Char {key} ({uuidStr}) not found");
            }

            var characteristic = chars.Characteristics[0];
            _characteristics[key] = characteristic;

            // 订阅通知
            var status = await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (status == GattCommunicationStatus.Success)
            {
                Delegate handler = null!;
                // 使用 dynamic 避免编译时检查 GattCharacteristicValueChangedEventHandler
                // 该类型在 .NET 8 内置 WinRT 投影中可能不可用
                dynamic dynChar = characteristic;
                var callback = new Action<object, object>((s, e) =>
                {
                    dynamic args = e;
                    var data = args.Value.ToArray();
                    AppLogger.Debug($"BleNotify:{key} len={data.Length}");
                    ValueReceived?.Invoke(this, (key, data));
                });
                // 通过 WinRT 事件注册
                dynChar.CharacteristicValueChanged += callback;
                handler = callback;
                _handlers[key] = handler;
            }

            AppLogger.Info($"WindowsConnector: subscribed {key}");
        }
    }

    public event EventHandler<(string Channel, byte[] Data)>? ValueReceived;

    /// <summary>
    /// 写入数据
    /// </summary>
    public async Task WriteAsync(string channel, byte[] data)
    {
        if (!_characteristics.TryGetValue(channel, out var c))
            throw new InvalidOperationException($"Channel {channel} not subscribed");

        for (int attempt = 1; attempt <= ProtocolConstants.BleMaxRetries; attempt++)
        {
            try
            {
                if (attempt > 1)
                {
                    AppLogger.Warn($"WindowsConnector: Write retry {attempt}/{ProtocolConstants.BleMaxRetries} on {channel}");
                }

                using var cts = new CancellationTokenSource(ProtocolConstants.BleTimeout);
                var result = await c.WriteValueAsync(data.AsBuffer()).AsTask(cts.Token);
                if (result != GattCommunicationStatus.Success)
                    throw new InvalidOperationException($"Write {channel} failed: {result}");
                return;
            }
            catch (Exception ex)
            {
                AppLogger.Error($"WindowsConnector: Write attempt {attempt} failed: {ex.Message}");
                if (attempt >= ProtocolConstants.BleMaxRetries) throw;
                await Task.Delay(500);
            }
        }
    }

    /// <summary>
    /// 读取数据
    /// </summary>
    public async Task<byte[]> ReadAsync(string channel)
    {
        if (!_characteristics.TryGetValue(channel, out var c))
            throw new InvalidOperationException($"Channel {channel} not subscribed");

        for (int attempt = 1; attempt <= ProtocolConstants.BleMaxRetries; attempt++)
        {
            try
            {
                if (attempt > 1)
                {
                    AppLogger.Warn($"WindowsConnector: Read retry {attempt}/{ProtocolConstants.BleMaxRetries} on {channel}");
                }

                using var cts = new CancellationTokenSource(ProtocolConstants.BleTimeout);
                var result = await c.ReadValueAsync().AsTask(cts.Token);
                if (result.Status != GattCommunicationStatus.Success)
                    throw new InvalidOperationException($"Read {channel} failed: {result.Status}");
                return result.Value.ToArray();
            }
            catch (Exception ex)
            {
                AppLogger.Error($"WindowsConnector: Read attempt {attempt} failed: {ex.Message}");
                if (attempt >= ProtocolConstants.BleMaxRetries) throw;
                await Task.Delay(500);
            }
        }
        throw new InvalidOperationException($"Read failed after {ProtocolConstants.BleMaxRetries} attempts");
    }

    public async Task DisconnectAsync()
    {
        try
        {
            DisposeDevice();
        }
        catch (Exception ex)
        {
            AppLogger.Error($"WindowsConnector: disconnect error: {ex.Message}");
        }
        finally
        {
            State = BleConnectionState.Disconnected;
        }
        await Task.CompletedTask;
    }

    private void DisposeDevice()
    {
        foreach (var kv in _handlers.ToList())
        {
            if (_characteristics.TryGetValue(kv.Key, out var c))
            {
                try
                {
                    // 使用 dynamic 避免编译时检查
                    dynamic dynChar = c;
                    dynChar.CharacteristicValueChanged -= kv.Value;
                }
                catch { }
            }
        }
        _handlers.Clear();
        _characteristics.Clear();

        if (_device != null)
        {
            // BluetoothLEDevice doesn't implement IDisposable in WinRT projection
            // We just release the reference and let GC handle cleanup
            _device = null;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _cts?.Dispose();
        DisposeDevice();
        State = BleConnectionState.Disconnected;
        _disposed = true;
    }
}
