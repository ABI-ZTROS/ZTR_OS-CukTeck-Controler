using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Foundation;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.Ble;

public enum BleConnectionState
{
    Disconnected, Connecting, Connected, Subscribing, Ready, Error,
}

/// <summary>
/// Windows BLE 连接器 — 强类型 WinRT 重写（避免 dynamic 导致的运行时类型错误）。
/// 支持 MTU、5 通道订阅、5 秒超时 + 3 次重试。
///
/// ⚠️ 改动说明：之前用 dynamic + WinRT 事件委托的反射模式注册/注销，很容易错。
/// 这里全部用编译期强类型：
///   - fe95 是 GattDeviceService（不是 IGattService，WinRT 用 GattDeviceService）
///   - 通道对象是 GattCharacteristic
///   - 通知事件: TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>
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
    // 强类型：保存每个 key 的 TypedEventHandler<,> 委托实例，便于注销
    private readonly Dictionary<string, object> _valueChangedHandlers = new();
    private CancellationTokenSource? _cts;
    private bool _disposed;

    public BleConnectionState State { get; private set; } = BleConnectionState.Disconnected;
    public BluetoothLEDevice? Device => _device;

    public event EventHandler<(string Channel, byte[] Data)>? ValueReceived;

    /// <summary>连接并订阅所有通道</summary>
    public async Task<bool> ConnectAsync(ulong bluetoothAddress)
    {
        State = BleConnectionState.Connecting;
        AppLogger.Instance.I("WindowsConnector", $"connecting to {bluetoothAddress:X}...");

        for (int attempt = 1; attempt <= ProtocolConstants.BleMaxRetries; attempt++)
        {
            try
            {
                if (attempt > 1)
                    AppLogger.Instance.W("WindowsConnector", $"retry attempt {attempt}/{ProtocolConstants.BleMaxRetries}");

                using var cts = new CancellationTokenSource(ProtocolConstants.BleTimeout);
                _cts = cts;

                _device = await BluetoothLEDevice.FromBluetoothAddressAsync(bluetoothAddress)
                    .AsTask(cts.Token);
                if (_device == null)
                    throw new InvalidOperationException("Device not found");

                State = BleConnectionState.Connected;
                AppLogger.Instance.I("WindowsConnector", "connected");

                var servicesResult = await _device.GetGattServicesAsync(BluetoothCacheMode.Uncached)
                    .AsTask(cts.Token);
                if (servicesResult.Status != GattCommunicationStatus.Success)
                    throw new InvalidOperationException($"GetGattServices failed: {servicesResult.Status}");

                var fe95 = servicesResult.Services.FirstOrDefault(
                    s => s.Uuid == Guid.Parse(ProtocolConstants.UuidFe95));
                if (fe95 == null)
                    throw new InvalidOperationException("Service 0xFE95 not found");

                await SubscribeAllAsync(fe95, cts.Token);
                State = BleConnectionState.Ready;
                return true;
            }
            catch (Exception ex)
            {
                AppLogger.Instance.E("WindowsConnector", $"connect attempt {attempt} failed: {ex.Message}");
                DisposeDevice();
                if (attempt >= ProtocolConstants.BleMaxRetries) { State = BleConnectionState.Error; return false; }
                await Task.Delay(1000);
            }
        }
        State = BleConnectionState.Error;
        return false;
    }

    private async Task SubscribeAllAsync(GattDeviceService fe95, CancellationToken ct)
    {
        State = BleConnectionState.Subscribing;

        var mappings = new (string Key, string Uuid)[]
        {
            ("dev_info",  ProtocolConstants.CharDeviceInfo),
            ("auth_ctrl", ProtocolConstants.CharAuthCtrl),
            ("auth_data", ProtocolConstants.CharAuthData),
            ("cmd_send",  ProtocolConstants.CharCmdSend),
            ("cmd_recv",  ProtocolConstants.CharCmdRecv),
        };

        foreach (var (key, uuidStr) in mappings)
        {
            var uuid = Guid.Parse(uuidStr);
            var chars = await fe95.GetCharacteristicsForUuidAsync(uuid).AsTask(ct);
            if (chars.Status != GattCommunicationStatus.Success || chars.Characteristics.Count == 0)
                throw new InvalidOperationException($"Char {key} ({uuidStr}) not found");

            var characteristic = chars.Characteristics[0];
            _characteristics[key] = characteristic;

            // 强类型订阅 TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>
            TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> handler =
                (s, e) =>
                {
                    byte[] data = e.CharacteristicValue.ToArray();
                    AppLogger.Instance.D("WindowsConnector", $"Notify:{key} len={data.Length}");
                    ValueReceived?.Invoke(this, (key, data));
                };
            characteristic.ValueChanged += handler;
            _valueChangedHandlers[key] = handler;

            var status = await characteristic
                .WriteClientCharacteristicConfigurationDescriptorAsync(
                    GattClientCharacteristicConfigurationDescriptorValue.Notify).AsTask(ct);
            if (status != GattCommunicationStatus.Success)
                throw new InvalidOperationException($"CCCD Write failed on {key}: {status}");

            AppLogger.Instance.I("WindowsConnector", $"subscribed {key}");
        }
    }

    public async Task WriteAsync(string channel, byte[] data)
    {
        if (!_characteristics.TryGetValue(channel, out var c))
            throw new InvalidOperationException($"Channel {channel} not subscribed");

        for (int attempt = 1; attempt <= ProtocolConstants.BleMaxRetries; attempt++)
        {
            try
            {
                if (attempt > 1)
                    AppLogger.Instance.W("WindowsConnector", $"Write retry {attempt}/{ProtocolConstants.BleMaxRetries} on {channel}");
                using var cts = new CancellationTokenSource(ProtocolConstants.BleTimeout);
                var result = await c.WriteValueAsync(data.AsBuffer()).AsTask(cts.Token);
                if (result != GattCommunicationStatus.Success)
                    throw new InvalidOperationException($"Write {channel} failed: {result}");
                return;
            }
            catch (Exception ex)
            {
                AppLogger.Instance.E("WindowsConnector", $"Write attempt {attempt} failed: {ex.Message}");
                if (attempt >= ProtocolConstants.BleMaxRetries) throw;
                await Task.Delay(500);
            }
        }
    }

    public async Task<byte[]> ReadAsync(string channel)
    {
        if (!_characteristics.TryGetValue(channel, out var c))
            throw new InvalidOperationException($"Channel {channel} not subscribed");

        for (int attempt = 1; attempt <= ProtocolConstants.BleMaxRetries; attempt++)
        {
            try
            {
                if (attempt > 1)
                    AppLogger.Instance.W("WindowsConnector", $"Read retry {attempt}/{ProtocolConstants.BleMaxRetries} on {channel}");
                using var cts = new CancellationTokenSource(ProtocolConstants.BleTimeout);
                var result = await c.ReadValueAsync().AsTask(cts.Token);
                if (result.Status != GattCommunicationStatus.Success)
                    throw new InvalidOperationException($"Read {channel} failed: {result.Status}");
                return result.Value.ToArray();
            }
            catch (Exception ex)
            {
                AppLogger.Instance.E("WindowsConnector", $"Read attempt {attempt} failed: {ex.Message}");
                if (attempt >= ProtocolConstants.BleMaxRetries) throw;
                await Task.Delay(500);
            }
        }
        throw new InvalidOperationException($"Read failed after {ProtocolConstants.BleMaxRetries} attempts");
    }

    public async Task DisconnectAsync()
    {
        try { DisposeDevice(); }
        catch (Exception ex) { AppLogger.Instance.E("WindowsConnector", $"disconnect error: {ex.Message}"); }
        finally { State = BleConnectionState.Disconnected; }
        await Task.CompletedTask;
    }

    private void DisposeDevice()
    {
        // 先注销所有强类型事件委托
        foreach (var kv in _valueChangedHandlers.ToList())
        {
            if (_characteristics.TryGetValue(kv.Key, out var c) &&
                kv.Value is TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> handler)
            {
                try { c.ValueChanged -= handler; }
                catch { /* ignore */ }
            }
        }
        _valueChangedHandlers.Clear();
        _characteristics.Clear();

        if (_device != null)
        {
            // BluetoothLEDevice 没有 Dispose() — 丢引用即可
            try { _device.Dispose(); } catch { }
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
