// TDD RED-GREEN-REFACTOR #2/3: CryptoEngine AES-CCM 正确性
// RED: 用 BouncyCastle (标准 AESCCM) 生成 ground truth，对比现有的 CryptoEngine
// — 当前 CryptoEngine 用的是 AesGcm(tagLength=4)，**肯定和标准 AESCCM 对不上**。
// 所以测试会失败（RED 阶段）。
//
// 然后 GREEN: 把 CryptoEngine 改成真 AES-CCM 实现（用 BouncyCastle 的算法）
// ——注意非 Windows 平台（测试机 Linux）我们直接引用 BouncyCastle。
// 生产端 Windows 上也装同一个包。

using System;
using System.Linq;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using CukTechController.Protocol;

namespace CukTechController.Tests.Pure;

/// <summary>参考实现 (BouncyCastle AESCCM, tag=4, nonce=12)，等同于 cryptography.AESCCM</summary>
internal static class ReferenceCcm
{
    /// <summary>AES-CCM 加密，tag_size=4, nonce=12, aad=null (和 miot 协议一致)</summary>
    public static byte[] Encrypt(byte[] key, byte[] nonce, byte[] plaintext)
    {
        var cipher = new CcmBlockCipher(new AesEngine());
        var parameters = new AeadParameters(
            key: new KeyParameter(key),
            macSize: 32, // 4 bytes tag = 32 bits
            nonce: nonce,
            associatedText: null!);
        cipher.Init(forEncryption: true, parameters);

        int outputLen = cipher.GetOutputSize(plaintext.Length);
        var output = new byte[outputLen];
        int pos = cipher.ProcessBytes(plaintext, 0, plaintext.Length, output, 0);
        pos += cipher.DoFinal(output, pos);
        // output = ciphertext || tag (4 bytes)
        return output;
    }

    public static byte[]? Decrypt(byte[] key, byte[] nonce, byte[] ciphertextPlusTag)
    {
        try
        {
            var cipher = new CcmBlockCipher(new AesEngine());
            var parameters = new AeadParameters(
                key: new KeyParameter(key),
                macSize: 32, // 4 bytes tag = 32 bits
                nonce: nonce,
                associatedText: null!);
            cipher.Init(forEncryption: false, parameters);

            int outputLen = cipher.GetOutputSize(ciphertextPlusTag.Length);
            var output = new byte[outputLen];
            int pos = cipher.ProcessBytes(ciphertextPlusTag, 0, ciphertextPlusTag.Length, output, 0);
            pos += cipher.DoFinal(output, pos);
            var plain = new byte[pos];
            Array.Copy(output, plain, pos);
            return plain;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 小米会话 nonce 构造 (C# 版 Crypto.Encrypt / Decrypt 协议要求)：
    /// nonce[0..3]  = iv (4 bytes, appIv/devIv)
    /// nonce[4..7]  = zero-filled
    /// nonce[8..11] = it (4 bytes LE, 32-bit 计数器)
    /// </summary>
    public static byte[] BuildMiioNonce(byte[] iv, int it)
    {
        var n = new byte[12];
        Array.Copy(iv, 0, n, 0, 4);
        // bytes 4-7: already 0
        n[8]  = (byte)(it & 0xFF);
        n[9]  = (byte)((it >> 8)  & 0xFF);
        n[10] = (byte)((it >> 16) & 0xFF);
        n[11] = (byte)((it >> 24) & 0xFF);
        return n;
    }
}

public class CryptoEngineCcmTests
{
    private static CryptoEngine Fresh(out byte[] appIv, out byte[] devIv,
                                      out byte[] appKey, out byte[] devKey)
    {
        // 固定密钥便于测试 repeatable
        appKey = new byte[16]; devKey = new byte[16]; appIv = new byte[4]; devIv = new byte[4];
        for (int i = 0; i < 16; i++) { appKey[i] = (byte)(i + 1); devKey[i] = (byte)(i + 32); }
        for (int i = 0; i < 4; i++)  { appIv[i]  = (byte)(i + 5); devIv[i]  = (byte)(i + 9);  }
        var engine = new CryptoEngine();
        engine.SetSessionKeys(devKey, appKey, devIv, appIv);
        return engine;
    }

    // ======= RED: 用 BouncyCastle 作为 ground truth，验证 App→Dev 方向第一个包 =======
    [Fact]
    public void Encrypt_It0_ShouldMatch_ReferenceCcm()
    {
        var engine = Fresh(out byte[] appIv, out _, out byte[] appKey, out _);
        byte[] plaintext = { 0x01, 0x02, 0x03, 0x04, 0x05 };
        var got = engine.Encrypt(plaintext);

        byte[] nonce = ReferenceCcm.BuildMiioNonce(appIv, 0);
        byte[] expectedCcm = ReferenceCcm.Encrypt(appKey, nonce, plaintext);
        // 引擎返回 it_lo(2) + (ciphertext || tag(4))
        Assert.Equal(2 + expectedCcm.Length, got.Length);
        // it_lo(2) = LE of it = 0
        Assert.Equal(0x00, got[0]); Assert.Equal(0x00, got[1]);
        byte[] gotBlob = got.Skip(2).ToArray();
        Assert.Equal(Hex(expectedCcm), Hex(gotBlob));
    }

    [Fact]
    public void Decrypt_AfterEncrypt_ShouldRoundTrip()
    {
        var engine = Fresh(out _, out _, out _, out _);
        byte[] plaintext = { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 };
        var packet = engine.Encrypt(plaintext);

        // 用 BouncyCastle 参考实现解加密出来的包 — 保证加密的正确性
        Assert.True(packet.Length >= 2 + 4, "packet too short");
        int it = packet[0] | (packet[1] << 8);
        byte[] appKey = new byte[16];
        for (int i = 0; i < 16; i++) appKey[i] = (byte)(i + 1);
        byte[] appIv = new byte[4];
        for (int i = 0; i < 4; i++) appIv[i] = (byte)(i + 5);
        byte[] nonce = ReferenceCcm.BuildMiioNonce(appIv, it);
        byte[] cipherBlob = packet.Skip(2).ToArray();
        var plain1 = ReferenceCcm.Decrypt(appKey, nonce, cipherBlob);
        Assert.Equal(Hex(plaintext), Hex(plain1 ?? Array.Empty<byte>()));

        // 再解回原设备：走 Decrypt
        // 加密用的 appKey / appIv (发送方向)，解密应该用 devKey / devIv 才行
        // RoundTrip 测试 = 直接让引擎自己也能解密它自己加密出来的同包
        // 但引擎解密用 dev，加密用 app，所以我们需要用 dev 端伪造一个它能解的包
        byte[] devKey = new byte[16];
        for (int i = 0; i < 16; i++) devKey[i] = (byte)(i + 32);
        byte[] devIv = new byte[4];
        for (int i = 0; i < 4; i++) devIv[i] = (byte)(i + 9);
        byte[] devNonce = ReferenceCcm.BuildMiioNonce(devIv, it: 0);
        byte[] devEnc = ReferenceCcm.Encrypt(devKey, devNonce, plaintext);
        byte[] devPacket = new byte[2 + devEnc.Length];
        devPacket[0] = 0x00; devPacket[1] = 0x00;
        Array.Copy(devEnc, 0, devPacket, 2, devEnc.Length);
        var dec = engine.Decrypt(devPacket);
        Assert.Equal(Hex(plaintext), Hex(dec ?? Array.Empty<byte>()));
    }

    // 设备推过来的方向：dev_key + dev_nonce(it)
    [Fact]
    public void Decrypt_DeviceSend_ShouldMatch_ReferenceCcm()
    {
        var engine = Fresh(out _, out byte[] devIv, out _, out byte[] devKey);
        byte[] plaintext = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
        // 设备 it_lo = 0
        byte[] nonce = ReferenceCcm.BuildMiioNonce(devIv, it: 0);
        byte[] encrypted = ReferenceCcm.Encrypt(devKey, nonce, plaintext);
        byte[] packet = new byte[2 + encrypted.Length];
        packet[0] = 0x00; packet[1] = 0x00; // it_lo LE=0
        Array.Copy(encrypted, 0, packet, 2, encrypted.Length);

        var got = engine.Decrypt(packet);
        Assert.Equal(Hex(plaintext), Hex(got ?? Array.Empty<byte>()));
    }

    // ======= GREEN 之后：递增计数器（it）每次 +1，非原子 =======
    [Fact]
    public void Encrypt_3Times_ItShouldIncrement()
    {
        var engine = Fresh(out byte[] appIv, out _, out byte[] appKey, out _);
        byte[] p1 = { 1 }, p2 = { 2 }, p3 = { 3 };
        _ = engine.Encrypt(p1); // it=0
        var got2 = engine.Encrypt(p2); // it=1
        _ = engine.Encrypt(p3); // it=2

        // 单独算 it=1 的标准值
        byte[] nonce1 = ReferenceCcm.BuildMiioNonce(appIv, 1);
        byte[] expected2 = ReferenceCcm.Encrypt(appKey, nonce1, p2);
        byte[] gotBlob2 = got2.Skip(2).ToArray();
        Assert.Equal(0x01, got2[0]); Assert.Equal(0x00, got2[1]);
        Assert.Equal(Hex(expected2), Hex(gotBlob2));
    }

    // ======= 线程安全（RED 目前应失败）=======
    [Fact]
    public void Encrypt_Concurrent_ShouldNotLoseCounts()
    {
        var engine = Fresh(out _, out _, out _, out _);
        const int threads = 8;
        const int perThread = 1000;
        var tasks = new Task[threads];
        var seen = new HashSet<ushort>();
        var locker = new object();
        for (int t = 0; t < threads; t++)
        {
            tasks[t] = Task.Run(() =>
            {
                for (int i = 0; i < perThread; i++)
                {
                    var b = engine.Encrypt(new byte[] { (byte)i });
                    ushort itLo = (ushort)(b[0] | (b[1] << 8));
                    lock (locker) seen.Add(itLo);
                }
            });
        }
        Task.WaitAll(tasks);
        int expected = threads * perThread;
        // 非原子 _sendIt++ 会导致冲突，seen.Count < expected
        Assert.Equal(expected, seen.Count);
    }

    // ======= Decrypt itLo 溢出后 itHi 递增 =======
    [Fact]
    public void Decrypt_CounterOverflow_ShouldAdvance_HighBits()
    {
        var engine = Fresh(out _, out byte[] devIv, out _, out byte[] devKey);
        // 强制把 dev 端计数推到接近 0xFFFF
        // 方法：用 it=0x0000FFFF 和 it=0x00010000 各发一包
        byte[] p1 = { 1, 2, 3 }, p2 = { 4, 5, 6 };
        byte[] nonceLow  = ReferenceCcm.BuildMiioNonce(devIv, it: 0x0000FFFF);
        byte[] nonceHigh = ReferenceCcm.BuildMiioNonce(devIv, it: 0x00010000);

        byte[] encLow = ReferenceCcm.Encrypt(devKey, nonceLow, p1);
        byte[] encHigh = ReferenceCcm.Encrypt(devKey, nonceHigh, p2);

        byte[] pktLow = new byte[2 + encLow.Length];
        pktLow[0] = 0xFF; pktLow[1] = 0xFF; // it_lo = 0xFFFF
        Array.Copy(encLow, 0, pktLow, 2, encLow.Length);

        byte[] pktHigh = new byte[2 + encHigh.Length];
        pktHigh[0] = 0x00; pktHigh[1] = 0x00; // it_lo 溢出归 0
        Array.Copy(encHigh, 0, pktHigh, 2, encHigh.Length);

        var d1 = engine.Decrypt(pktLow);
        var d2 = engine.Decrypt(pktHigh); // 这里会触发 high 进位

        Assert.Equal(Hex(p1), Hex(d1 ?? Array.Empty<byte>()));
        Assert.Equal(Hex(p2), Hex(d2 ?? Array.Empty<byte>()));
    }

    private static string Hex(byte[] data) =>
        BitConverter.ToString(data).Replace("-", "").ToLowerInvariant();
}
