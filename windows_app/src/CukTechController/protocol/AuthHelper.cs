using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using CukTechController.Ble;

namespace CukTechController.Protocol;

/// <summary>
/// 认证流程辅助方法
/// </summary>
internal static class AuthHelper
{
    internal static async Task<byte[]?> WaitNotifyAsync(
        WindowsConnector connector,
        string channel,
        int timeoutSec = 3)
    {
        // 使用 TaskCompletionSource 订阅事件
        var tcs = new TaskCompletionSource<byte[]>();
        CancellationTokenSource? cts = null;

        void Handler(object? sender, (string Channel, byte[] Data) e)
        {
            if (e.Channel == channel && !tcs.Task.IsCompleted)
            {
                tcs.TrySetResult(e.Data);
            }
        }

        connector.ValueReceived += Handler;
        try
        {
            cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSec));
            cts.Token.Register(() =>
            {
                if (!tcs.Task.IsCompleted)
                    tcs.TrySetResult(Array.Empty<byte>()); // 空数组表示超时
            });

            var result = await tcs.Task;
            // 超时返回空数组
            if (result.Length == 0) return null;
            return result;
        }
        finally
        {
            connector.ValueReceived -= Handler;
            cts?.Dispose();
        }
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
