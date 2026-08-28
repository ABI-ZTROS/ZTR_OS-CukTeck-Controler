using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using CukTechController.Ble;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.ViewModels;

/// <summary>
/// 设备设置 ViewModel —— PIID 5/6/13/15/19/20
/// </summary>
public class SettingsViewModel : INotifyPropertyChanged
{
    private readonly WindowsConnector _connector = WindowsConnector.Instance;
    private readonly SettingsService _settings = SettingsService.Instance;

    // ---- PIID 5: 场景模式 ----
    private int _sceneMode;
    public int SceneMode { get => _sceneMode; set { _sceneMode = value; OnPropertyChanged(); } }

    public IReadOnlyDictionary<int, string> SceneModeOptions { get; } =
        ProtocolConstants.PiidDisplay[5];

    // ---- PIID 6: 息屏时间 ----
    private int _screenOffTime;
    public int ScreenOffTime { get => _screenOffTime; set { _screenOffTime = value; OnPropertyChanged(); } }

    public IReadOnlyDictionary<int, string> ScreenOffOptions { get; } =
        ProtocolConstants.PiidDisplay[6];

    // ---- PIID 13: 语言 ----
    private int _language;
    public int Language { get => _language; set { _language = value; OnPropertyChanged(); } }

    public IReadOnlyDictionary<int, string> LanguageOptions { get; } =
        ProtocolConstants.PiidDisplay[13];

    // ---- PIID 15: USB-A 小电流 ----
    private bool _usbASmallCurrent;
    public bool UsbASmallCurrent { get => _usbASmallCurrent; set { _usbASmallCurrent = value; OnPropertyChanged(); } }

    // ---- PIID 19: 空闲息屏 ----
    private bool _idleScreenOff;
    public bool IdleScreenOff { get => _idleScreenOff; set { _idleScreenOff = value; OnPropertyChanged(); } }

    // ---- PIID 20: 屏幕方向锁 ----
    private bool _screenOrientationLock;
    public bool ScreenOrientationLock { get => _screenOrientationLock; set { _screenOrientationLock = value; OnPropertyChanged(); } }

    // ---- 状态 ----
    private bool _isLoading;
    private string _errorMessage = string.Empty;

    public bool IsLoading { get => _isLoading; set { _isLoading = value; OnPropertyChanged(); } }
    public string ErrorMessage { get => _errorMessage; set { _errorMessage = value; OnPropertyChanged(); } }

    public ICommand LoadCommand { get; }
    public ICommand SaveCommand { get; }

    public event PropertyChangedEventHandler? PropertyChanged;

    public SettingsViewModel()
    {
        LoadCommand = new RelayCommand(async () => await LoadAsync());
        SaveCommand = new RelayCommand(async () => await SaveAsync());

        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            var tasks = new[]
            {
                LoadIntAsync(v => SceneMode = v, 5),
                LoadIntAsync(v => ScreenOffTime = v, 6),
                LoadIntAsync(v => Language = v, 13),
                LoadBoolAsync(v => UsbASmallCurrent = v, 15),
                LoadBoolAsync(v => IdleScreenOff = v, 19),
                LoadBoolAsync(v => ScreenOrientationLock = v, 20),
            };
            await Task.WhenAll(tasks);
        }
        catch (Exception ex)
        {
            ErrorMessage = $"加载失败: {ex.Message}";
            AppLogger.Error($"SettingsViewModel.Load error: {ex.Message}", ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    private async Task LoadIntAsync(Action<int> setter, int piid)
    {
        var val = await ReadPiidIntAsync(piid);
        if (val.HasValue) setter(val.Value);
    }

    private async Task LoadBoolAsync(Action<bool> setter, int piid)
    {
        var val = await ReadPiidIntAsync(piid);
        if (val.HasValue) setter(val.Value != 0);
    }

    private async Task<int?> ReadPiidIntAsync(int piid)
    {
        // 使用 SettingsService 的公开方法
        return piid switch
        {
            5 => await _settings.GetSceneModeAsync(_connector),
            6 => await _settings.GetScreenOffTimeAsync(_connector),
            13 => await _settings.GetLanguageAsync(_connector),
            _ => null,
        };
    }

    private async Task SaveAsync()
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            var tasks = new List<Task>
            {
                _settings.SetSceneModeAsync(_connector, SceneMode),
                _settings.SetScreenOffTimeAsync(_connector, ScreenOffTime),
                _settings.SetLanguageAsync(_connector, Language),
                _settings.SetUsbASmallCurrentAsync(_connector, UsbASmallCurrent),
                _settings.SetIdleScreenOffAsync(_connector, IdleScreenOff),
                _settings.SetScreenOrientationLockAsync(_connector, ScreenOrientationLock),
            };
            await Task.WhenAll(tasks);
            AppLogger.Info("Settings saved successfully");
        }
        catch (Exception ex)
        {
            ErrorMessage = $"保存失败: {ex.Message}";
            AppLogger.Error($"SettingsViewModel.Save error: {ex.Message}", ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}