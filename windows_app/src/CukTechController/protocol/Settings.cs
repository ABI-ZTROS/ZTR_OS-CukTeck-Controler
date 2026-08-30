using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using CukTechController.Ble;
using CukTechController.Utils;

namespace CukTechController.Protocol
{
    // ============================================================================
    // 应用偏好设置（本地持久化，非设备端 PIID 控制）
    // ============================================================================

    /// <summary>
    /// 应用设置管理
    /// 管理用户偏好设置，如自动连接、日志等级、主题等。
    /// </summary>
    public class Settings
    {
        private static Settings? _instance;
        private static readonly object _lock = new object();
        private readonly string _settingsPath;

        public static Settings Instance
        {
            get
            {
                lock (_lock)
                {
                    _instance ??= new Settings();
                    return _instance;
                }
            }
        }

        private Settings()
        {
            string configDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "CukTechController");
            Directory.CreateDirectory(configDir);
            _settingsPath = Path.Combine(configDir, "settings.json");
        }

        /// <summary>是否自动连接上次设备</summary>
        public bool AutoConnect { get; set; } = true;

        /// <summary>深色模式</summary>
        public bool DarkMode { get; set; } = true;

        /// <summary>日志等级</summary>
        public string LogLevel { get; set; } = "info";

        /// <summary>扫描超时（秒）</summary>
        public int ScanTimeout { get; set; } = 10;

        /// <summary>状态刷新间隔（毫秒）</summary>
        public int RefreshInterval { get; set; } = 500;

        /// <summary>保存设置</summary>
        public async Task SaveAsync()
        {
            try
            {
                var json = JsonSerializer.Serialize(this, new JsonSerializerOptions
                {
                    WriteIndented = true
                });
                await File.WriteAllTextAsync(_settingsPath, json);
                AppLogger.Debug("Settings saved");
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to save settings", ex);
            }
        }

        /// <summary>加载设置</summary>
        public async Task LoadAsync()
        {
            try
            {
                if (File.Exists(_settingsPath))
                {
                    var json = await File.ReadAllTextAsync(_settingsPath).ConfigureAwait(false);
                    var settings = JsonSerializer.Deserialize<Settings>(json);
                    if (settings != null)
                    {
                        AutoConnect = settings.AutoConnect;
                        DarkMode = settings.DarkMode;
                        LogLevel = settings.LogLevel;
                        ScanTimeout = settings.ScanTimeout;
                        RefreshInterval = settings.RefreshInterval;
                    }
                    AppLogger.Debug("Settings loaded");
                }
            }
            catch (Exception ex)
            {
                AppLogger.Error("Failed to load settings", ex);
            }
        }
    }

    // ============================================================================
    // 充电器设备设置封装（PIID 读-改-写-回读）
    // ============================================================================

    /// <summary>
    /// 充电器设置封装（设备端 PIID 控制）
    /// </summary>
    public class SettingsService
    {
        private static readonly SettingsService _instance = new();
        public static SettingsService Instance => _instance;

        private readonly EncryptedChannel _channel = EncryptedChannel.Instance;
        private int _miotSeq = 1;

        private int NextSeq
        {
            get
            {
                int s = _miotSeq;
                _miotSeq = (_miotSeq + 1) & 0xFF;
                return s;
            }
        }

        private async Task<int?> ReadAsync(WindowsConnector c, int piid)
        {
            var resp = await _channel.SendGetAsync(c, ProtocolConstants.SiidCharger, piid, NextSeq);
            return resp?["value"] as int?;
        }

        private async Task<bool> WriteAsync(WindowsConnector c, int piid, int value)
        {
            var resp = await _channel.SendSetAsync(c, ProtocolConstants.SiidCharger, piid, value, NextSeq);
            if (resp == null) return false;
            await Task.Delay(300);
            var rb = await ReadAsync(c, piid);
            bool ok = rb == value;
            AppLogger.Info($"Settings: PIID {piid} wrote={value} read={rb} OK={ok}");
            return ok;
        }

        // ---- 场景模式 PIID 5 ----
        public Task<int?> GetSceneModeAsync(WindowsConnector c) => ReadAsync(c, 5);
        public Task<bool> SetSceneModeAsync(WindowsConnector c, int mode) => WriteAsync(c, 5, mode);

        // ---- 息屏时间 PIID 6 ----
        public Task<int?> GetScreenOffTimeAsync(WindowsConnector c) => ReadAsync(c, 6);
        public Task<bool> SetScreenOffTimeAsync(WindowsConnector c, int time) => WriteAsync(c, 6, time);

        // ---- 总倒计时 PIID 8 ----
        public Task<int?> GetGlobalTimerAsync(WindowsConnector c) => ReadAsync(c, 8);
        public Task<bool> SetGlobalTimerAsync(WindowsConnector c, int minutes) => WriteAsync(c, 8, minutes);

        // ---- 单端口倒计时 PIID 9-12 ----
        public Task<int?> GetPortTimerAsync(WindowsConnector c, string port) =>
            ReadAsync(c, ProtocolConstants.TimerPorts[port]);

        public Task<bool> SetPortTimerAsync(WindowsConnector c, string port, int minutes) =>
            WriteAsync(c, ProtocolConstants.TimerPorts[port], minutes);

        // ---- 语言 PIID 13 ----
        public Task<int?> GetLanguageAsync(WindowsConnector c) => ReadAsync(c, 13);
        public Task<bool> SetLanguageAsync(WindowsConnector c, int lang) => WriteAsync(c, 13, lang);

        // ---- USB-A 小电流 PIID 15 ----
        public Task<bool> SetUsbASmallCurrentAsync(WindowsConnector c, bool on) =>
            WriteAsync(c, 15, on ? 1 : 0);

        // ---- 空闲息屏 PIID 19 ----
        public Task<bool> SetIdleScreenOffAsync(WindowsConnector c, bool on) =>
            WriteAsync(c, 19, on ? 1 : 0);

        // ---- 屏幕方向锁 PIID 20 ----
        public Task<bool> SetScreenOrientationLockAsync(WindowsConnector c, bool on) =>
            WriteAsync(c, 20, on ? 1 : 0);

        // ---- 进入界面 PIID 14 (只写) ----
        public async Task<bool> GotoScreenAsync(WindowsConnector c, int page)
        {
            var resp = await _channel.SendSetAsync(c, ProtocolConstants.SiidCharger, 14, page, NextSeq);
            return resp != null;
        }
    }
}