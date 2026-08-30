// ═══════════════════════════════════════════════════════════════════════
// 🔌 PortControlViewModel — 单端口控制（CommunityToolkit.Mvvm 源生成器）
//   开关 / 倒计时 / 协议切换
// ═══════════════════════════════════════════════════════════════════════

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CukTechController.Ble;
using CukTechController.Protocol;
using Serilog;

namespace CukTechController.ViewModels;

public partial class PortControlViewModel : ObservableObject
{
    private readonly WindowsConnector _connector = WindowsConnector.Instance;
    private readonly PortControl _portCtrl = PortControl.Instance;
    private readonly ProtocolSwitch _protoSwitch = ProtocolSwitch.Instance;
    private readonly SettingsService _settingsSvc = SettingsService.Instance;

    public int Piid { get; }
    public string PortName { get; }
    private readonly string _portKey;

    [ObservableProperty] private bool isOn;
    [ObservableProperty] private int countdownMinutes;
    [ObservableProperty] private bool isLoading;
    [ObservableProperty] private string errorMessage = string.Empty;

    public IEnumerable<string> SupportedProtocols { get; }

    public Dictionary<string, bool> ProtocolStates { get; private set; } = new();

    public PortControlViewModel(int piid)
    {
        Piid = piid;
        (PortName, _portKey) = piid switch
        {
            1 => ("C1", "c1"),
            2 => ("C2", "c2"),
            3 => ("C3", "c3"),
            4 => ("A", "a"),
            _ => ("?", "c1"),
        };
        SupportedProtocols = ProtocolSwitch.GetProtocolsForPort(_portKey);
        _ = LoadStateAsync();
    }

    [RelayCommand]
    private async Task TogglePortAsync()
    {
        IsLoading = true; ErrorMessage = string.Empty;
        try
        {
            var ok = await _portCtrl.SetPortAsync(_connector, _portKey, !IsOn);
            if (ok) IsOn = !IsOn;
            else ErrorMessage = "操作失败";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            Log.Error(ex, "TogglePort error");
        }
        finally { IsLoading = false; }
    }

    [RelayCommand]
    private async Task SaveCountdownAsync()
    {
        IsLoading = true; ErrorMessage = string.Empty;
        try
        {
            await _settingsSvc.SetPortTimerAsync(_connector, _portKey, CountdownMinutes);
            Log.Information("Countdown saved: port={Port} minutes={Min}", _portKey, CountdownMinutes);
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            Log.Error(ex, "SaveCountdown error");
        }
        finally { IsLoading = false; }
    }

    [RelayCommand]
    private async Task ToggleProtocolAsync(string protocol)
    {
        IsLoading = true; ErrorMessage = string.Empty;
        try
        {
            var current = await _protoSwitch.ReadAsync(_connector);
            if (!current.HasValue) { ErrorMessage = "无法读取协议状态"; return; }

            var parsed = _protoSwitch.Parse(current.Value);
            var portDict = parsed.ContainsKey(_portKey) ? parsed[_portKey]! : new Dictionary<string, bool>();
            portDict[protocol] = !portDict.ContainsKey(protocol) || !portDict[protocol];
            parsed[_portKey] = portDict;

            var ok = await _protoSwitch.WriteAsync(_connector, _protoSwitch.Encode(parsed));
            if (ok)
            {
                ProtocolStates = portDict;
                OnPropertyChanged(nameof(ProtocolStates));
            }
            else ErrorMessage = "协议写入失败";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            Log.Error(ex, "ToggleProtocol error");
        }
        finally { IsLoading = false; }
    }

    private async Task LoadStateAsync()
    {
        IsLoading = true;
        try
        {
            var mask = await _portCtrl.ReadStateAsync(_connector);
            if (mask.HasValue)
            {
                var bit = ProtocolConstants.PortBits[_portKey];
                IsOn = (mask.Value & (1 << bit)) != 0;
            }

            var timerPiid = ProtocolConstants.TimerPorts[_portKey];
            if (timerPiid > 0)
            {
                var min = await _settingsSvc.GetPortTimerAsync(_connector, _portKey);
                if (min.HasValue) CountdownMinutes = min.Value;
            }

            var protoVal = await _protoSwitch.ReadAsync(_connector);
            if (protoVal.HasValue)
            {
                var parsed = _protoSwitch.Parse(protoVal.Value);
                ProtocolStates = parsed.ContainsKey(_portKey) ? parsed[_portKey]! : new Dictionary<string, bool>();
                OnPropertyChanged(nameof(ProtocolStates));
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            Log.Error(ex, "PortControlViewModel.LoadState error");
        }
        finally { IsLoading = false; }
    }
}
