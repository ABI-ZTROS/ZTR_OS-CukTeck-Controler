using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Parameters;

namespace CukTechController.Protocol;

/// <summary>
/// 米家云 API 加密工具 —— RC4-drop[1024] 加密 + 签名逻辑
/// 严格参照 Python 参考实现 (xiaomi_cloud.py)
/// </summary>
public static class XiaomiCloudCrypto
{
    /// <summary>
    /// RC4-drop[1024] 加密
    /// </summary>
    /// <param name="password">Base64 编码的密钥 (signedNonce)</param>
    /// <param name="payload">待加密的明文字符串</param>
    /// <returns>Base64 编码的加密结果</returns>
    public static string Rc4Encrypt(string password, string payload)
    {
        var key = Convert.FromBase64String(password);
        var engine = new Arc4Engine();
        engine.Init(true, new KeyParameter(key));
        // Drop first 1024 bytes of keystream
        engine.ProcessBlock(new byte[1024], 0, new byte[1024], 0);
        var input = Encoding.UTF8.GetBytes(payload);
        var output = new byte[input.Length];
        if (input.Length > 0)
        {
            engine.ProcessBlock(input, 0, output, 0);
        }
        return Convert.ToBase64String(output);
    }

    /// <summary>
    /// RC4-drop[1024] 解密
    /// </summary>
    /// <param name="password">Base64 编码的密钥 (signedNonce)</param>
    /// <param name="payload">Base64 编码的加密数据</param>
    /// <returns>解密后的明文字符串</returns>
    public static string Rc4Decrypt(string password, string payload)
    {
        var key = Convert.FromBase64String(password);
        var engine = new Arc4Engine();
        engine.Init(true, new KeyParameter(key));
        // Drop first 1024 bytes of keystream
        engine.ProcessBlock(new byte[1024], 0, new byte[1024], 0);
        var input = Convert.FromBase64String(payload);
        var output = new byte[input.Length];
        if (input.Length > 0)
        {
            engine.ProcessBlock(input, 0, output, 0);
        }
        return Encoding.UTF8.GetString(output);
    }

    /// <summary>
    /// 对 ssecurity + nonce 拼接后做 SHA256 签名
    /// </summary>
    /// <param name="ssecurity">Base64 编码的 ssecurity</param>
    /// <param name="nonce">Base64 编码的 nonce</param>
    /// <returns>Base64 编码的 SHA256 签名</returns>
    public static string SignedNonce(string ssecurity, string nonce)
    {
        var s = Convert.FromBase64String(ssecurity);
        var n = Convert.FromBase64String(nonce);
        var combined = new byte[s.Length + n.Length];
        Buffer.BlockCopy(s, 0, combined, 0, s.Length);
        Buffer.BlockCopy(n, 0, combined, s.Length, n.Length);
        using var sha256 = SHA256.Create();
        return Convert.ToBase64String(sha256.ComputeHash(combined));
    }

    /// <summary>
    /// 生成 12 字节 nonce (8 随机 + 4 时间戳大端序)
    /// </summary>
    /// <param name="millis">当前毫秒时间戳</param>
    /// <returns>Base64 编码的 12 字节 nonce</returns>
    public static string GenerateNonce(long millis)
    {
        using var rng = RandomNumberGenerator.Create();
        var rand = new byte[8];
        rng.GetBytes(rand);
        var timestamp = ToBigEndianBytes((int)(millis / 60000));
        var combined = new byte[12];
        Buffer.BlockCopy(rand, 0, combined, 0, 8);
        Buffer.BlockCopy(timestamp, 0, combined, 8, 4);
        return Convert.ToBase64String(combined);
    }

    /// <summary>
    /// 生成加密签名 (SHA1)
    /// </summary>
    /// <param name="url">API 完整 URL</param>
    /// <param name="method">HTTP 方法</param>
    /// <param name="signedNonce">已签名 nonce</param>
    /// <param name="params">请求参数</param>
    /// <returns>Base64 编码的 SHA1 签名</returns>
    public static string GenerateEncSignature(
        string url,
        string method,
        string signedNonce,
        IDictionary<string, string> @params)
    {
        var signatureParams = new List<string>
        {
            method.ToUpperInvariant()
        };

        // 提取路径部分：url.split("com")[1].replace("/app/", "/")
        // 如果 URL 不含 "com"，使用完整 URL 作为 fallback
        var urlParts = url.Split("com");
        if (urlParts.Length > 1)
        {
            signatureParams.Add(urlParts[1].Replace("/app/", "/"));
        }
        else
        {
            // fallback: 提取路径
            try
            {
                var uri = new Uri(url);
                signatureParams.Add(uri.AbsolutePath.Replace("/app/", "/"));
            }
            catch
            {
                signatureParams.Add(url);
            }
        }

        foreach (var kvp in @params.OrderBy(k => k.Key, StringComparer.Ordinal))
        {
            signatureParams.Add($"{kvp.Key}={kvp.Value}");
        }
        signatureParams.Add(signedNonce);
        var signatureString = string.Join("&", signatureParams);
        using var sha1 = SHA1.Create();
        return Convert.ToBase64String(
            sha1.ComputeHash(Encoding.UTF8.GetBytes(signatureString)));
    }

    /// <summary>
    /// 生成加密后的 API 请求参数
    /// </summary>
    /// <param name="url">API 完整 URL</param>
    /// <param name="method">HTTP 方法</param>
    /// <param name="signedNonce">已签名 nonce</param>
    /// <param name="nonce">原始 nonce</param>
    /// <param name="params">明文请求参数</param>
    /// <param name="ssecurity">Base64 编码的 ssecurity</param>
    /// <returns>加密后的参数字典 (含 signature, ssecurity, _nonce)</returns>
    public static Dictionary<string, string> GenerateEncParams(
        string url,
        string method,
        string signedNonce,
        string nonce,
        Dictionary<string, string> @params,
        string ssecurity)
    {
        // 1. 计算 rc4_hash__ 签名 (基于原始参数)
        @params["rc4_hash__"] = GenerateEncSignature(url, method, signedNonce, @params);

        // 2. 将所有值 RC4 加密
        var encrypted = new Dictionary<string, string>();
        foreach (var kvp in @params)
        {
            encrypted[kvp.Key] = Rc4Encrypt(signedNonce, kvp.Value);
        }

        // 3. 基于加密后参数计算 signature
        encrypted["signature"] = GenerateEncSignature(url, method, signedNonce, encrypted);

        // 4. 添加 ssecurity 和 _nonce
        encrypted["ssecurity"] = ssecurity;
        encrypted["_nonce"] = nonce;

        return encrypted;
    }

    /// <summary>
    /// 将 int 转换为 4 字节大端序字节数组
    /// </summary>
    private static byte[] ToBigEndianBytes(int value)
    {
        return new byte[]
        {
            (byte)(value >> 24),
            (byte)(value >> 16),
            (byte)(value >> 8),
            (byte)value
        };
    }
}