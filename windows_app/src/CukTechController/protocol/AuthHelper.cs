using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using CukTechController.Ble;

namespace CukTechController.Protocol;

/// <summary>
/// 认证流程辅助方法
///
/// ⚠️ 并发安全重写（2026-09）：
/// 老版本直接订阅 ValueReceived → 多线程同通道会出现竞态（A 的响应被 B 偷走）
/// 且"等待请求先到、通知后到"的老通知全部丢。
///
/// 新设计：每个通道建立一个无限大小的 ConcurrentQueue 作为缓冲，
/// 用 Lazy+lock 保证第一次调用时注册全局侦听；之后每个 WaitNotifyAsync
/// 从 queue 取数据（有就直接拿，没有就 SemaphoreSlim 等待下一条到）。
/// </summary>
internal static class AuthHelper
{
    private static readonly object _initLock = new();
    private static WindowsConnector? _registeredConnector;

    // 通道 → 数据缓冲队列
    private static readonly ConcurrentDictionary<string, ConcurrentQueue<byte[]>> _channelQueues = new();
    // 通道 → 有新数据到达时的唤醒信号
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> _channelSignals = new();

    /// <summary>确保全局事件监听已注册（懒加载）</summary>
    private static void EnsurePipelines(WindowsConnector connector)
    {
        if (ReferenceEquals(_registeredConnector, connector)) return;
        lock (_initLock)
        {
            if (ReferenceEquals(_registeredConnector, connector)) return;
            connector.ValueReceived -= DispatchNotification; // 防御：避免重复挂
            connector.ValueReceived += DispatchNotification;
            _registeredConnector = connector;
        }
    }

    private static void DispatchNotification(object? sender, (string Channel, byte[] Data) e)
    {
        var q = _channelQueues.GetOrAdd(e.Channel, _ => new ConcurrentQueue<byte[]>());
        q.Enqueue(e.Data);
        var signal = _channelSignals.GetOrAdd(e.Channel, _ => new SemaphoreSlim(0, int.MaxValue));
        signal.Release();
    }

    internal static async Task<byte[]?> WaitNotifyAsync(
        WindowsConnector connector,
        string channel,
        int timeoutSec = 3)
    {
        EnsurePipelines(connector);

        var q = _channelQueues.GetOrAdd(channel, _ => new ConcurrentQueue<byte[]>());
        var signal = _channelSignals.GetOrAdd(channel, _ => new SemaphoreSlim(0, int.MaxValue));

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSec));

        while (!cts.IsCancellationRequested)
        {
            // 先看缓冲里有没有老通知（在我们开始等之前到的）
            if (q.TryDequeue(out var buffered))
                return buffered;

            try { await signal.WaitAsync(cts.Token); }
            catch (OperationCanceledException) { return null; } // timeout
        }
        return null;
    }

    internal static async Task<byte[]?> RecvAuthResponseAsync(
        WindowsConnector connector,
        string channel)
    {
        var data = await WaitNotifyAsync(connector, channel, 3);
        if (data == null || data.Length < 4) return null;

        if (data[2] == 0x02)
        {
            // 内联
            await connector.WriteAsync(channel, new byte[] { 0, 0, 3, 0 });
            return data.Skip(4).ToArray();
        }

        if (data[2] == 0x00 && data.Length >= 6)
        {
            // 多帧
            int count = data[4] | (data[5] << 8);
            await connector.WriteAsync(channel, new byte[] { 0, 0, 1, 1 });
            var received = new List<byte>();
            for (int i = 0; i < count; i++)
            {
                var f = await WaitNotifyAsync(connector, channel, 3);
                if (f == null) return null;
                received.AddRange(f.Skip(2));
            }
            await connector.WriteAsync(channel, new byte[] { 0, 0, 1, 0 });
            return received.ToArray();
        }

        return null;
    }

    internal static byte[] RandomBytes(int n)
    {
        using var rng = RandomNumberGenerator.Create();
        var result = new byte[n];
        rng.GetBytes(result);
        return result;
    }

    internal static byte[] HexToBytes(string hex)
    {
        hex = hex.Replace(" ", "");
        var result = new byte[hex.Length / 2];
        for (int i = 0; i < result.Length; i++)
        {
            result[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        }
        return result;
    }

    internal static byte[] HkdfSha256(byte[] ikm, byte[] salt, int length)
    {
        // HKDF-SHA256 manual implementation
        // Step 1: Extract PRK = HMAC-SHA256(salt, ikm)
        using (var hmac = new HMACSHA256(salt))
        {
            var prk = hmac.ComputeHash(ikm);

            // Step 2: Expand
            var result = new byte[length];
            byte[] t = Array.Empty<byte>();
            int offset = 0;
            byte counter = 1;

            using (var expandHmac = new HMACSHA256(prk))
            {
                while (offset < length)
                {
                    // T(i) = HMAC-SHA256(PRK, T(i-1) || counter)
                    var input = new byte[t.Length + 1];
                    Array.Copy(t, 0, input, 0, t.Length);
                    input[t.Length] = counter;
                    t = expandHmac.ComputeHash(input);

                    int copyLen = Math.Min(t.Length, length - offset);
                    Array.Copy(t, 0, result, offset, copyLen);
                    offset += copyLen;
                    counter++;
                }
            }

            return result;
        }
    }

    internal static byte[] HmacSha256(byte[] key, byte[] data)
    {
        using var hmac = new HMACSHA256(key);
        return hmac.ComputeHash(data);
    }

    internal static bool ListEquals(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++)
        {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
