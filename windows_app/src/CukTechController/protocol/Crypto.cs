using System;
using System.Linq;
using System.Security.Cryptography;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// AES-CCM 加解密工具（C# 移植）
    /// 参考: controller.py _encrypt / decrypt
    /// 非包 tag_length=4，nonce 格式: iv(4) + zeros(4) + counter(4)
    /// </summary>
    public class CryptoEngine
    {
        public static readonly CryptoEngine Instance = new CryptoEngine();

        private byte[]? _devKey;
        private byte[]? _appKey;
        private byte[]? _devIv;
        private byte[]? _appIv;

        private int _sendIt;
        private int _devItHi;
        private int _lastDevItLo;

        /// <summary>
        /// 设置会话密钥
        /// </summary>
        public void SetSessionKeys(byte[] devKey, byte[] appKey, byte[] devIv, byte[] appIv)
        {
            _devKey = (byte[])devKey.Clone();
            _appKey = (byte[])appKey.Clone();
            _devIv = (byte[])devIv.Clone();
            _appIv = (byte[])appIv.Clone();
            _sendIt = 0;
            _devItHi = 0;
            _lastDevItLo = 0;
            AppLogger.Info($"CryptoEngine: session keys set (dev_key={Hex(devKey)}...)");
        }

        /// <summary>
        /// 是否已派生密钥
        /// </summary>
        public bool HasKeys =>
            _devKey != null && _appKey != null &&
            _devIv != null && _appIv != null;

        /// <summary>
        /// 加密（发送方向：app_key + app_iv）
        /// 返回: it_lo(2) + ciphertext（含 4 字节 tag）
        /// </summary>
        public byte[] Encrypt(byte[] plaintext)
        {
            if (_appKey == null || _appIv == null)
                throw new InvalidOperationException("Session keys not set");

            int it = _sendIt;
            byte[] nonce = new byte[12];
            Array.Copy(_appIv, 0, nonce, 0, 4);
            // bytes 4-7 are already zero (zeros)
            nonce[8] = (byte)(it & 0xFF);
            nonce[9] = (byte)((it >> 8) & 0xFF);
            nonce[10] = (byte)((it >> 16) & 0xFF);
            nonce[11] = (byte)((it >> 24) & 0xFF);

            byte[] ciphertext = AesCcmEncrypt(_appKey, nonce, plaintext);
            _sendIt++;

            // it_lo(2) + ciphertext
            byte[] result = new byte[2 + ciphertext.Length];
            result[0] = (byte)(it & 0xFF);
            result[1] = (byte)((it >> 8) & 0xFF);
            Array.Copy(ciphertext, 0, result, 2, ciphertext.Length);
            return result;
        }

        /// <summary>
        /// 解密（接收方向：dev_key + dev_iv）
        /// 输入: it_lo(2) + ciphertext
        /// 返回: plaintext 或 null
        /// </summary>
        public byte[]? Decrypt(byte[] data)
        {
            if (data.Length < 6) return null;
            if (_devKey == null || _devIv == null) return null;

            int itLo = data[0] | (data[1] << 8);
            // 溢出跟踪
            if (itLo < _lastDevItLo && (_lastDevItLo - itLo) > 32768)
            {
                _devItHi++;
            }
            _lastDevItLo = itLo;
            int it = (_devItHi << 16) | itLo;

            byte[] nonce = new byte[12];
            Array.Copy(_devIv, 0, nonce, 0, 4);
            // bytes 4-7 are already zero
            nonce[8] = (byte)(it & 0xFF);
            nonce[9] = (byte)((it >> 8) & 0xFF);
            nonce[10] = (byte)((it >> 16) & 0xFF);
            nonce[11] = (byte)((it >> 24) & 0xFF);

            byte[] ciphertext = data.Skip(2).ToArray();
            try
            {
                return AesCcmDecrypt(_devKey, nonce, ciphertext);
            }
            catch (Exception ex)
            {
                AppLogger.Error($"CryptoEngine: decrypt failed: {ex.Message}", ex);
                return null;
            }
        }

        /// <summary>
        /// AES-CCM 加密（tag_length=4）
        /// 使用 AesGcm 带 4 字节 tag 近似实现
        /// </summary>
        private byte[] AesCcmEncrypt(byte[] key, byte[] nonce, byte[] plain)
        {
            // TODO: 严格意义上的 CCM 需手写；当前使用 AesGcm(tagLength=4) 近似
            using var aes = new AesGcm(key, 4);
            byte[] cipher = new byte[plain.Length];
            byte[] tag = new byte[4];
            aes.Encrypt(nonce, plain, cipher, tag);

            // ciphertext + tag
            byte[] result = new byte[cipher.Length + tag.Length];
            Array.Copy(cipher, 0, result, 0, cipher.Length);
            Array.Copy(tag, 0, result, cipher.Length, tag.Length);
            return result;
        }

        /// <summary>
        /// AES-CCM 解密
        /// </summary>
        private byte[] AesCcmDecrypt(byte[] key, byte[] nonce, byte[] cipher)
        {
            using var aes = new AesGcm(key, 4);

            // 最后 4 字节是 tag
            byte[] cipherText = cipher.SkipLast(4).ToArray();
            byte[] tag = cipher.TakeLast(4).ToArray();

            byte[] plain = new byte[cipherText.Length];
            aes.Decrypt(nonce, cipherText, tag, plain);
            return plain;
        }

        private static string Hex(byte[] data) =>
            BitConverter.ToString(data).Replace("-", "").ToLowerInvariant();
    }
}
