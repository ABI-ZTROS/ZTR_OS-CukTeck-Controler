using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using CukTechController.Models;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    /// <summary>
    /// Token 仓库 —— 安全存储与读取米家认证 Token
    /// </summary>
    public class TokenRepository
    {
        private static TokenRepository? _instance;
        private static readonly object _lock = new object();
        private readonly string _tokenPath;
        private TokenConfig? _cachedToken;

        public static TokenRepository Instance
        {
            get
            {
                lock (_lock)
                {
                    _instance ??= new TokenRepository();
                    return _instance;
                }
            }
        }

        private TokenRepository()
        {
            string configDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "CukTechController",
                "Secrets");
            Directory.CreateDirectory(configDir);
            _tokenPath = Path.Combine(configDir, "token.enc");
        }

        /// <summary>
        /// 获取当前存储的 Token
        /// </summary>
        public async Task<TokenConfig?> GetTokenAsync()
        {
            if (_cachedToken != null) return _cachedToken;

            try
            {
                if (File.Exists(_tokenPath))
                {
                    var encrypted = await File.ReadAllBytesAsync(_tokenPath);
                    var json = Encoding.UTF8.GetString(encrypted); // TODO: 解密
                    _cachedToken = JsonSerializer.Deserialize<TokenConfig>(json);
                }
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to load token", ex);
            }

            return _cachedToken;
        }

        /// <summary>
        /// 保存 Token
        /// </summary>
        public async Task SaveTokenAsync(TokenConfig token)
        {
            _cachedToken = token;
            try
            {
                var json = JsonSerializer.Serialize(token);
                var encrypted = Encoding.UTF8.GetBytes(json); // TODO: 加密
                await File.WriteAllBytesAsync(_tokenPath, encrypted);
                AppLogger.Info($"Token saved for user: {token.UserId}");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to save token", ex);
            }
        }

        /// <summary>
        /// 清除 Token
        /// </summary>
        public async Task ClearTokenAsync()
        {
            _cachedToken = null;
            try
            {
                if (File.Exists(_tokenPath))
                {
                    File.Delete(_tokenPath);
                }
                AppLogger.Info("Token cleared");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to clear token", ex);
            }
        }

        /// <summary>
        /// 检查 Token 是否存在
        /// </summary>
        public async Task<bool> HasTokenAsync()
        {
            var token = await GetTokenAsync();
            return token?.IsValid ?? false;
        }
    }
}
