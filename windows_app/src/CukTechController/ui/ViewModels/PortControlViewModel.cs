using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using CukTechController.Ble;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.ViewModels;

/// <summary>
/// 端口控制 ViewModel —— 单端口开关/倒计时/协议
/// </summary>
public class PortControlViewModel : INotifyPropertyChanged
{
    private readonly WindowsConnector _connector = WindowsConnector.Instance;
    private readonly PortControl _portCtrl = PortControl.Instance;
    private readonly ProtocolSwitch _protoSwitch = ProtocolSwitch.Instance;
    private readonly SettingsService _settingsSvc = SettingsService.Instance;

    public int Piid { get; }
    public string PortName { get; }
    private readonly string _portKey;

    private bool _isOn;
    private int _countdownMinutes;
    private bool _isLoading;
    private string _errorMessage = string.Empty;

    public bool IsOn { get => _isOn; set { _isOn = value; OnPropertyChanged(); } }
    public int CountdownMinutes { get => _countdownMinutes; set { _countdownMinutes = value; OnPropertyChanged(); } }
    public bool IsLoading { get => _isLoading; set { _isLoading = value; OnPropertyChanged(); } }
    public string ErrorMessage { get => _errorMessage; set { _errorMessage = value; OnPropertyChanged(); } }

    public ICommand TogglePortCommand { get; }
    public ICommand SaveCountdownCommand { get; }
    public ICommand ToggleProtocolCommand { get; }

    /// <summary>当前端口支持的协议列表</summary>
    public IEnumerable<string> SupportedProtocols { get; }

    /// <summary>协议开关状态（协议名 → 启用）</summary>
    public Dictionary<string, bool> ProtocolStates { get; private set; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;

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

        TogglePortCommand = new RelayCommand(async () => await TogglePortAsync());
        SaveCountdownCommand = new RelayCommand(async () => await SaveCountdownAsync());
        ToggleProtocolCommand = new RelayCommand<string>(async (proto) => await ToggleProtocolAsync(proto!));

        _ = LoadStateAsync();
    }

    private async Task LoadStateAsync()
    {
        IsLoading = true;
        try
        {
            // 读取端口开关状态
            var mask = await _portCtrl.ReadStateAsync(_connector);
            if (mask.HasValue)
            {
                var bit = ProtocolConstants.PortBits[_portKey];
                IsOn = (mask.Value & (1 << bit)) != 0;
            }

            // 读取倒计时
            var timerPiid = ProtocolConstants.TimerPorts[_portKey];
            if (timerPiid > 0)
            {
                var min = await _settingsSvc.GetPortTimerAsync(_connector, _portKey);
                if (min.HasValue) CountdownMinutes = min.Value;
            }

            // 读取协议开关
            var protoVal = await _protoSwitch.ReadAsync(_connector);
            if (protoVal.HasValue)
            {
                var parsed = _protoSwitch.Parse(protoVal.Value);
                ProtocolStates = parsed.ContainsKey(_portKey)
                    ? parsed[_portKey]!
                    : new Dictionary<string, bool>();
                OnPropertyChanged(nameof(ProtocolStates));
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            AppLogger.Error($"PortControlViewModel.LoadState error: {ex.Message}", ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    private async Task TogglePortAsync()
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            var ok = await _portCtrl.SetPortAsync(_connector, _portKey, !IsOn);
            IsOn = ok ? !IsOn : IsOn;
            ErrorMessage = ok ? string.Empty : "操作失败";
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            AppLogger.Error($"TogglePort error: {ex.Message}", ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    private async Task SaveCountdownAsync()
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            await _settingsSvc.SetPortTimerAsync(_connector, _portKey, CountdownMinutes);
            AppLogger.Info($"Countdown saved: port={_portKey} minutes={CountdownMinutes}");
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            AppLogger.Error($"SaveCountdown error: {ex.Message}", ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    private async Task ToggleProtocolAsync(string protocol)
    {
        IsLoading = true;
        ErrorMessage = string.Empty;
        try
        {
            var current = await _protoSwitch.ReadAsync(_connector);
            if (!current.HasValue)
            {
                ErrorMessage = "无法读取协议状态";
                return;
            }

            var parsed = _protoSwitch.Parse(current.Value);
            var portDict = parsed.ContainsKey(_portKey) ? parsed[_portKey]! : new Dictionary<string, bool>();
            portDict[protocol] = !portDict.ContainsKey(protocol) || !portDict[protocol];
            parsed[_portKey] = portDict;
            var next = _protoSwitch.Encode(parsed);
            var ok = await _protoSwitch.WriteAsync(_connector, next);

            if (ok)
            {
                ProtocolStates = portDict;
                OnPropertyChanged(nameof(ProtocolStates));
            }
            else
            {
                ErrorMessage = "协议写入失败";
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            AppLogger.Error($"ToggleProtocol error: {ex.Message}", ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}