// ═══════════════════════════════════════════════════════════════════════
// 🛠 SettingsViewModel — 设备设置（CommunityToolkit.Mvvm 源生成器）
//   PIID 5/6/8/13/15/19/20
// ═══════════════════════════════════════════════════════════════════════

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CukTechController.Ble;
using CukTechController.Protocol;
using Serilog;

namespace CukTechController.ViewModels;

public partial class SettingsViewModel : ObservableObject
{
    private readonly WindowsConnector _connector = WindowsConnector.Instance;
    private readonly SettingsService _settings = SettingsService.Instance;

    [ObservableProperty] private int sceneMode;
    [ObservableProperty] private int screenOffTime;
    [ObservableProperty] private int language;
    [ObservableProperty] private bool usbASmallCurrent;
    [ObservableProperty] private bool idleScreenOff;
    [ObservableProperty] private bool screenOrientationLock;
    [ObservableProperty] private int globalTimer;
    [ObservableProperty] private bool isLoading;
    [ObservableProperty] private string errorMessage = string.Empty;

    public IReadOnlyDictionary<int, string> SceneModeOptions => ProtocolConstants.PiidDisplay[5];
    public IReadOnlyDictionary<int, string> ScreenOffOptions => ProtocolConstants.PiidDisplay[6];
    public IReadOnlyDictionary<int, string> LanguageOptions => ProtocolConstants.PiidDisplay[13];

    public SettingsViewModel()
    {
        _ = LoadAsync();
    }

    [RelayCommand]
    private async Task LoadAsync()
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            await Task.WhenAll(
                LoadIntAsync(v => SceneMode = v, 5),
                LoadIntAsync(v => ScreenOffTime = v, 6),
                LoadIntAsync(v => Language = v, 13),
                LoadBoolAsync(v => UsbASmallCurrent = v, 15),
                LoadBoolAsync(v => IdleScreenOff = v, 19),
                LoadBoolAsync(v => ScreenOrientationLock = v, 20),
                LoadIntAsync(v => GlobalTimer = v, 8)
            );
        }
        catch (Exception ex)
        {
            ErrorMessage = $"加载失败: {ex.Message}";
            Log.Error(ex, "SettingsViewModel.Load error");
        }
        finally { IsLoading = false; }
    }

    [RelayCommand]
    private async Task SaveAsync()
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            await Task.WhenAll(
                _settings.SetSceneModeAsync(_connector, SceneMode),
                _settings.SetScreenOffTimeAsync(_connector, ScreenOffTime),
                _settings.SetLanguageAsync(_connector, Language),
                _settings.SetUsbASmallCurrentAsync(_connector, UsbASmallCurrent),
                _settings.SetIdleScreenOffAsync(_connector, IdleScreenOff),
                _settings.SetScreenOrientationLockAsync(_connector, ScreenOrientationLock),
                _settings.SetGlobalTimerAsync(_connector, GlobalTimer)
            );
            Log.Information("Settings saved");
        }
        catch (Exception ex)
        {
            ErrorMessage = $"保存失败: {ex.Message}";
            Log.Error(ex, "SettingsViewModel.Save error");
        }
        finally { IsLoading = false; }
    }

    private async Task LoadIntAsync(Action<int> setter, int piid)
    {
        var val = piid switch
        {
            5 => await _settings.GetSceneModeAsync(_connector),
            6 => await _settings.GetScreenOffTimeAsync(_connector),
            13 => await _settings.GetLanguageAsync(_connector),
            _ => null,
        };
        if (val.HasValue) setter(val.Value);
    }

    private async Task LoadBoolAsync(Action<bool> setter, int piid)
    {
        var val = await LoadIntAsync(piid);
        if (val.HasValue) setter(val.Value != 0);
    }

    private async Task<int?> LoadIntAsync(int piid) => piid switch
    {
        5 => await _settings.GetSceneModeAsync(_connector),
        6 => await _settings.GetScreenOffTimeAsync(_connector),
        13 => await _settings.GetLanguageAsync(_connector),
        _ => null,
    };
}
