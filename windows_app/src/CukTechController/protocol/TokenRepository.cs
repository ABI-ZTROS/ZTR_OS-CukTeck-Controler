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
    ///
    /// 存储文件：
    ///   - token.enc          → BLE Token（TokenConfig）
    ///   - cloud_cred.enc     → 米家云凭证（CloudCredentials）
    ///
    /// 跨平台导入/导出格式：.cuk 文件（JSON 格式，与 Android 一致）
    /// </summary>
    public class TokenRepository
    {
        private static TokenRepository? _instance;
        private static readonly object _lock = new object();
        private readonly string _tokenPath;
        private readonly string _cloudPath;
        private TokenConfig? _cachedToken;
        private CloudCredentials? _cachedCloud;

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
            // ⚠️ 文件名从 .enc 改为 .json：目前存储裸 JSON 文本，防止用户误以为加密了
            // （Windows 端加 DPAPI 加密可作为后续独立改进项）
            _tokenPath = Path.Combine(configDir, "token.json");
            _cloudPath = Path.Combine(configDir, "cloud_cred.json");

            // 兼容迁移：老用户的 .enc 文件如果存在就改名为 .json
            MigrateLegacy(configDir, "token.enc", _tokenPath);
            MigrateLegacy(configDir, "cloud_cred.enc", _cloudPath);
        }

        private static void MigrateLegacy(string dir, string legacyName, string newPath)
        {
            string old = Path.Combine(dir, legacyName);
            try
            {
                if (File.Exists(old) && !File.Exists(newPath))
                {
                    File.Move(old, newPath);
                    AppLogger.Info($"TokenRepository: migrated {legacyName} → {Path.GetFileName(newPath)}");
                }
            }
            catch (Exception ex)
            {
                AppLogger.Error($"TokenRepository: migrate {legacyName} failed", ex);
            }
        }

        // ============================================================
        //  BLE Token (TokenConfig) — 原有逻辑保留
        // ============================================================

        public async Task<TokenConfig?> GetTokenAsync()
        {
            if (_cachedToken != null) return _cachedToken;

            try
            {
                if (File.Exists(_tokenPath))
                {
                    var json = await File.ReadAllTextAsync(_tokenPath);
                    _cachedToken = JsonSerializer.Deserialize<TokenConfig>(json);
                }
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to load token", ex);
            }

            return _cachedToken;
        }

        public async Task SaveTokenAsync(TokenConfig token)
        {
            _cachedToken = token;
            try
            {
                var json = JsonSerializer.Serialize(token);
                await File.WriteAllTextAsync(_tokenPath, json);
                AppLogger.Info($"Token saved for user: {token.UserId}");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to save token", ex);
            }
        }

        public async Task ClearTokenAsync()
        {
            _cachedToken = null;
            try
            {
                if (File.Exists(_tokenPath)) File.Delete(_tokenPath);
                AppLogger.Info("Token cleared");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to clear token", ex);
            }
        }

        public async Task<bool> HasTokenAsync()
        {
            var token = await GetTokenAsync();
            return token?.IsValid ?? false;
        }

        // ============================================================
        //  🚀 米家云凭证 (CloudCredentials) — 新增
        // ============================================================

        public async Task<CloudCredentials?> GetCloudAsync()
        {
            if (_cachedCloud != null) return _cachedCloud;

            try
            {
                if (File.Exists(_cloudPath))
                {
                    var json = await File.ReadAllTextAsync(_cloudPath);
                    _cachedCloud = JsonSerializer.Deserialize<CloudCredentials>(json);
                }
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to load cloud creds", ex);
            }

            return _cachedCloud;
        }

        public async Task SaveCloudAsync(CloudCredentials cred)
        {
            _cachedCloud = cred;
            try
            {
                var json = JsonSerializer.Serialize(cred);
                await File.WriteAllTextAsync(_cloudPath, json);
                AppLogger.Info($"☁️ Cloud creds saved: user={cred.UserId}, did={cred.Did}");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to save cloud creds", ex);
            }
        }

        public async Task ClearCloudAsync()
        {
            _cachedCloud = null;
            try
            {
                if (File.Exists(_cloudPath)) File.Delete(_cloudPath);
                AppLogger.Info("Cloud creds cleared");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to clear cloud creds", ex);
            }
        }

        public async Task<bool> HasCloudAsync()
        {
            var cred = await GetCloudAsync();
            return cred?.IsValid ?? false;
        }

        // ============================================================
        //  🚀 跨平台 JSON 导入 / 导出
        // ============================================================

        /// <summary>
        /// 导出当前云凭证为 JSON 字符串（可保存为 .cuk 文件发到 Android）
        /// </summary>
        public async Task<string?> ExportCloudToJsonAsync()
        {
            var cred = await GetCloudAsync();
            if (cred == null || !cred.IsValid)
            {
                AppLogger.Warning("No valid cloud creds to export");
                return null;
            }

            var bundle = new CloudExportBundle
            {
                Version = 1,
                ExportedAt = DateTime.UtcNow.ToString("o"),
                XiaomiCloud = cred,
            };

            var json = JsonSerializer.Serialize(bundle, new JsonSerializerOptions { WriteIndented = true });
            AppLogger.Info("📤 Cloud export JSON ready");
            return json;
        }

        /// <summary>
        /// 从 JSON 字符串导入云凭证（Android 发来的 .cuk 文件）
        /// 返回 (bool success, string? errorMessage)
        /// </summary>
        public async Task<(bool, string?)> ImportCloudFromJsonAsync(string json)
        {
            try
            {
                var bundle = JsonSerializer.Deserialize<CloudExportBundle>(json);
                if (bundle == null)
                    return (false, "JSON 解析失败");

                if (bundle.Version != 1)
                    return (false, $"不支持的导出版本: {bundle.Version}");

                var cred = bundle.XiaomiCloud;
                if (cred == null || string.IsNullOrEmpty(cred.Ssecurity) ||
                    string.IsNullOrEmpty(cred.ServiceToken) || string.IsNullOrEmpty(cred.UserId))
                    return (false, "凭证字段不完整");

                await SaveCloudAsync(cred);
                AppLogger.Info($"📥 Cloud import OK: user={cred.UserId}, did={cred.Did}");
                return (true, null);
            }
            catch (Exception ex)
            {
                AppLogger.Error("Import failed", ex);
                return (false, ex.Message);
            }
        }

        /// <summary>
        /// 从 .cuk 文件导入
        /// </summary>
        public async Task<(bool, string?)> ImportCloudFromFileAsync(string filePath)
        {
            try
            {
                if (!File.Exists(filePath))
                    return (false, "文件不存在");

                var json = await File.ReadAllTextAsync(filePath);
                return await ImportCloudFromJsonAsync(json);
            }
            catch (Exception ex)
            {
                return (false, ex.Message);
            }
        }

        /// <summary>
        /// 导出到 .cuk 文件
        /// </summary>
        public async Task<(bool, string?, string?)> ExportCloudToFileAsync(string? filePath = null)
        {
            var json = await ExportCloudToJsonAsync();
            if (json == null)
                return (false, null, "没有可导出的云凭证");

            try
            {
                if (string.IsNullOrEmpty(filePath))
                {
                    var ts = DateTime.Now.ToString("yyyyMMdd_HHmmss");
                    var dir = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                        "CukTechController");
                    Directory.CreateDirectory(dir);
                    filePath = Path.Combine(dir, $"cuk_cloud_{ts}.cuk");
                }

                await File.WriteAllTextAsync(filePath, json);
                return (true, filePath, null);
            }
            catch (Exception ex)
            {
                return (false, null, ex.Message);
            }
        }
    }
}
