using System;
using System.Linq;
using System.Threading;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// AES-CCM 加解密工具
    /// 参考: cuktech-ble-server protocol.py controller.py 的 encrypt / decrypt
    ///
    /// 🔑 非包 tag_length=4，nonce 格式: iv(4) + zeros(4) + counter(4)
    /// ⚠️ AES-GCM 不支持 4-byte tag，因此改用 BouncyCastle AES-CCM 实现。
    ///
    /// 发送方向 (app_key + app_iv):
    ///   output = it_lo(2 LE) || ccm_encrypt(plaintext, tag_length=4)
    /// 接收方向 (dev_key + dev_iv):
    ///   input  = it_lo(2 LE) || ciphertext || tag(4)
    ///   counter it = _devItHi(16-bit upper) || it_lo(16-bit lower)，it_lo 溢出时 carry 进 _devItHi。
    /// </summary>
    public class CryptoEngine
    {
        public static readonly CryptoEngine Instance = new();

        private const int TagBytes = 4;  // = 32 bits
        private const int NonceBytes = 12;

        private byte[]? _devKey;
        private byte[]? _appKey;
        private byte[]? _devIv;
        private byte[]? _appIv;

        private int _sendIt;                          // app 发送端 counter（原子递增）
        private int _devItHi;                         // dev 接收端 upper 16 bits
        private int _lastDevItLo;                     // dev 接收端 last lower 16 bits
        private readonly object _decryptLock = new(); // dev 方向 it 溢出 carry 锁

        /// <summary>设置会话密钥</summary>
        public void SetSessionKeys(byte[] devKey, byte[] appKey, byte[] devIv, byte[] appIv)
        {
            _devKey = (byte[])devKey.Clone();
            _appKey = (byte[])appKey.Clone();
            _devIv = (byte[])devIv.Clone();
            _appIv = (byte[])appIv.Clone();
            Volatile.Write(ref _sendIt, 0);
            _devItHi = 0;
            _lastDevItLo = 0;
            AppLogger.Info($"CryptoEngine: session keys set (dev_key={Hex(devKey.AsSpan(0, 4))}...)");
        }

        /// <summary>是否已派生密钥</summary>
        public bool HasKeys =>
            _devKey != null && _appKey != null &&
            _devIv != null && _appIv != null;

        /// <summary>
        /// 加密（发送方向：app_key + app_iv）
        /// 返回: it_lo(2 LE) + ciphertext（含 4 字节 tag）
        /// </summary>
        public byte[] Encrypt(byte[] plaintext)
        {
            if (_appKey == null || _appIv == null)
                throw new InvalidOperationException("Session keys not set");

            // it 起始为 0，每次加密后自增 1
            int it = Interlocked.Add(ref _sendIt, 0);
            Interlocked.Increment(ref _sendIt);
            byte[] nonce = BuildNonce(_appIv, it);
            byte[] ciphertextPlusTag = CcmEncrypt(_appKey, nonce, plaintext);

            // it_lo(2) + ciphertext||tag
            byte[] result = new byte[2 + ciphertextPlusTag.Length];
            result[0] = (byte)(it & 0xFF);
            result[1] = (byte)((it >> 8) & 0xFF);
            Array.Copy(ciphertextPlusTag, 0, result, 2, ciphertextPlusTag.Length);
            return result;
        }

        /// <summary>
        /// 解密（接收方向：dev_key + dev_iv）
        /// 输入: it_lo(2 LE) + ciphertext_with_tag(4)
        /// 返回: plaintext 或 null
        /// </summary>
        public byte[]? Decrypt(byte[] data)
        {
            if (data.Length < 2 + TagBytes) return null;
            if (_devKey == null || _devIv == null) return null;

            int itLo = data[0] | (data[1] << 8);
            int it;

            lock (_decryptLock)
            {
                // it_lo 溢出回绕 → high 进位
                if (itLo < _lastDevItLo && (_lastDevItLo - itLo) > 0x7FFF)
                {
                    _devItHi++;
                }
                _lastDevItLo = itLo;
                it = (_devItHi << 16) | itLo;
            }

            byte[] nonce = BuildNonce(_devIv, it);
            byte[] ciphertext = new byte[data.Length - 2];
            Array.Copy(data, 2, ciphertext, 0, ciphertext.Length);
            try
            {
                return CcmDecrypt(_devKey, nonce, ciphertext);
            }
            catch (Exception ex)
            {
                AppLogger.Error($"CryptoEngine: decrypt failed (it=0x{it:X8}): {ex.Message}", ex);
                return null;
            }
        }

        // ─── 内部工具 ────────────────────────────────────────────────

        private static byte[] BuildNonce(byte[] iv, int it)
        {
            var n = new byte[NonceBytes];
            Array.Copy(iv, 0, n, 0, 4);
            // bytes 4-7: zero-filled
            n[8]  = (byte)(it & 0xFF);
            n[9]  = (byte)((it >> 8)  & 0xFF);
            n[10] = (byte)((it >> 16) & 0xFF);
            n[11] = (byte)((it >> 24) & 0xFF);
            return n;
        }

        private static byte[] CcmEncrypt(byte[] key, byte[] nonce, byte[] plain)
        {
            var cipher = new CcmBlockCipher(new AesEngine());
            cipher.Init(forEncryption: true, new AeadParameters(
                key: new KeyParameter(key),
                macSize: TagBytes * 8, // 32 bits
                nonce: nonce,
                associatedText: null!));

            int outputLen = cipher.GetOutputSize(plain.Length);
            var output = new byte[outputLen];
            int offset = cipher.ProcessBytes(plain, 0, plain.Length, output, 0);
            offset += cipher.DoFinal(output, offset);

            if (offset != outputLen)
            {
                var shrunk = new byte[offset];
                Array.Copy(output, shrunk, offset);
                return shrunk;
            }
            return output;
        }

        private static byte[]? CcmDecrypt(byte[] key, byte[] nonce, byte[] cipherPlusTag)
        {
            var cipher = new CcmBlockCipher(new AesEngine());
            cipher.Init(forEncryption: false, new AeadParameters(
                key: new KeyParameter(key),
                macSize: TagBytes * 8,
                nonce: nonce,
                associatedText: null!));

            int outputLen = cipher.GetOutputSize(cipherPlusTag.Length);
            var output = new byte[outputLen];
            try
            {
                int offset = cipher.ProcessBytes(cipherPlusTag, 0, cipherPlusTag.Length, output, 0);
                offset += cipher.DoFinal(output, offset);
                var plain = new byte[offset];
                Array.Copy(output, plain, offset);
                return plain;
            }
            catch (InvalidCipherTextException)
            {
                // Tag 校验失败 → 返回 null 而不是抛
                return null;
            }
        }

        private static string Hex(ReadOnlySpan<byte> data)
        {
            var sb = new System.Text.StringBuilder(data.Length * 2);
            foreach (var b in data) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }
}
