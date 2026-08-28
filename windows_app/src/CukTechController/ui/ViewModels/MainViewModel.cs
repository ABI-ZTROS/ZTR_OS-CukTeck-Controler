using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using CukTechController.Ble;
using CukTechController.Models;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController.ViewModels;

/// <summary>
/// 主窗口 ViewModel
/// </summary>
public class MainViewModel : INotifyPropertyChanged
{
    private readonly WindowsScanner _scanner = WindowsScanner.Instance;
    private readonly WindowsConnector _connector = WindowsConnector.Instance;

    private ObservableCollection<ScanResult> _scanResults = new();
    private ScanResult? _selectedScanResult;
    private ObservableCollection<PortStateViewModel> _ports = new();
    private bool _isScanning;
    private bool _isConnecting;
    private bool _isConnected;
    private string _statusMessage = "未连接";
    private string _errorMessage = string.Empty;

    public ObservableCollection<ScanResult> ScanResults
    {
        get => _scanResults;
        set { _scanResults = value; OnPropertyChanged(); }
    }

    public ScanResult? SelectedScanResult
    {
        get => _selectedScanResult;
        set { _selectedScanResult = value; OnPropertyChanged(); }
    }

    public ObservableCollection<PortStateViewModel> Ports
    {
        get => _ports;
        set { _ports = value; OnPropertyChanged(); }
    }

    public bool IsScanning { get => _isScanning; set { _isScanning = value; OnPropertyChanged(); } }
    public bool IsConnecting { get => _isConnecting; set { _isConnecting = value; OnPropertyChanged(); } }
    public bool IsConnected { get => _isConnected; set { _isConnected = value; OnPropertyChanged(); } }

    public string StatusMessage
    {
        get => _statusMessage;
        set { _statusMessage = value; OnPropertyChanged(); }
    }

    public string ErrorMessage
    {
        get => _errorMessage;
        set { _errorMessage = value; OnPropertyChanged(); }
    }

    public ICommand ScanCommand { get; }
    public ICommand ConnectCommand { get; }
    public ICommand DisconnectCommand { get; }
    public ICommand OpenControlCommand { get; }
    public ICommand OpenSettingsCommand { get; }
    public ICommand OpenLogCommand { get; }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler<int>? OpenControlRequested;
    public event EventHandler? OpenSettingsRequested;
    public event EventHandler? OpenLogRequested;

    public MainViewModel()
    {
        ScanCommand = new RelayCommand(async () => await ScanAsync(), () => !IsScanning && !IsConnecting);
        ConnectCommand = new RelayCommand(async () => await ConnectAsync(), () => !IsConnecting && SelectedScanResult != null);
        DisconnectCommand = new RelayCommand(async () => await DisconnectAsync(), () => IsConnected);
        OpenControlCommand = new RelayCommand<int>((piid) => OpenControlRequested?.Invoke(this, piid));
        OpenSettingsCommand = new RelayCommand(() => OpenSettingsRequested?.Invoke(this, EventArgs.Empty));
        OpenLogCommand = new RelayCommand(() => OpenLogRequested?.Invoke(this, EventArgs.Empty));

        // 初始化 4 个端口
        foreach (var piid in new[] { 1, 2, 3, 4 })
        {
            _ports.Add(new PortStateViewModel(piid));
        }

        // 订阅端口流
        PortStreamController.Instance.StateChanged += OnPortStateChanged;
    }

    private void OnPortStateChanged(object? sender, PortState e)
    {
        if (e.Piid >= 1 && e.Piid <= 4 && e.Piid <= _ports.Count)
        {
            _ports[e.Piid - 1].Update(e);
        }
    }

    private async Task ScanAsync()
    {
        IsScanning = true;
        ErrorMessage = string.Empty;
        StatusMessage = "扫描中...";
        try
        {
            var results = await _scanner.StartAsync(timeout: TimeSpan.FromSeconds(10));
            ScanResults = new ObservableCollection<ScanResult>(results);
            IsScanning = false;

            var cuk = results.FirstOrDefault(r => r.IsCuktech);
            if (cuk == null)
            {
                ErrorMessage = "未扫描到酷态科设备";
                StatusMessage = "未连接";
            }
            else
            {
                StatusMessage = $"扫描到 {results.Count} 个设备";
            }
        }
        catch (Exception ex)
        {
            IsScanning = false;
            ErrorMessage = $"扫描失败: {ex.Message}";
            StatusMessage = "错误";
            AppLogger.Error($"Scan failed: {ex.Message}", ex);
        }
    }

    private async Task ConnectAsync()
    {
        if (SelectedScanResult == null) return;
        IsConnecting = true;
        ErrorMessage = string.Empty;
        StatusMessage = $"连接到 {SelectedScanResult.Name}...";
        try
        {
            var ok = await _connector.ConnectAsync(ParseAddress(SelectedScanResult.DeviceId));
            IsConnecting = false;
            IsConnected = ok;
            StatusMessage = ok ? "已连接" : "连接失败";
            if (!ok) ErrorMessage = "连接失败";
            else AppLogger.Info($"Connected to {SelectedScanResult.Name}");
        }
        catch (Exception ex)
        {
            IsConnecting = false;
            ErrorMessage = $"连接异常: {ex.Message}";
            StatusMessage = "错误";
            AppLogger.Error($"Connect exception: {ex.Message}", ex);
        }
    }

    private async Task DisconnectAsync()
    {
        try
        {
            await _connector.DisconnectAsync();
        }
        catch (Exception ex)
        {
            AppLogger.Error($"Disconnect error: {ex.Message}", ex);
        }
        IsConnected = false;
        StatusMessage = "未连接";
        ErrorMessage = string.Empty;
        // 清除端口状态
        foreach (var p in _ports) p.Update(null);
    }

    private static ulong ParseAddress(string id)
    {
        // 支持 "AA:BB:CC:DD:EE:FF" 或 "AABBCCDDEEFF" 或数字
        var clean = id.Replace(":", "").Replace("-", "").Replace(" ", "");
        if (ulong.TryParse(clean, System.Globalization.NumberStyles.HexNumber, null, out var val))
            return val;
        return 0;
    }

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>
/// 端口状态 ViewModel
/// </summary>
public class PortStateViewModel : INotifyPropertyChanged
{
    private double _voltage;
    private double _current;
    private double _power;
    private string _protocol = "--";
    private bool _isActive;

    public int Piid { get; }
    public string Name { get; }

    public string VoltageText { get; private set; } = "--";
    public string CurrentText { get; private set; } = "--";
    public string PowerText { get; private set; } = "--";
    public string Protocol { get => _protocol; set { _protocol = value; OnPropertyChanged(); } }
    public bool IsActive { get => _isActive; set { _isActive = value; OnPropertyChanged(); } }
    public bool IsConnected { get; private set; }

    public ICommand OpenControlCommand { get; }
    public ICommand TogglePortCommand { get; }

    public event EventHandler<int>? OpenControlRequested;
    public event EventHandler<string>? ToggleRequested;

    public PortStateViewModel(int piid)
    {
        Piid = piid;
        Name = piid switch { 1 => "C1", 2 => "C2", 3 => "C3", _ => "A" };

        OpenControlCommand = new RelayCommand(() => OpenControlRequested?.Invoke(this, Piid));
        TogglePortCommand = new RelayCommand(() => ToggleRequested?.Invoke(this, Piid <= 3 ? $"c{Piid}" : "a"));
    }

    public void Update(PortState? state)
    {
        if (state == null)
        {
            VoltageText = "--";
            CurrentText = "--";
            PowerText = "--";
            Protocol = "--";
            IsActive = false;
            IsConnected = false;
        }
        else
        {
            IsConnected = true;
            _voltage = state.Voltage;
            _current = state.Current;
            _power = state.Power;
            VoltageText = state.Active ? _voltage.ToString("F1") : "--";
            CurrentText = state.Active ? _current.ToString("F1") : "--";
            PowerText = state.Active ? _power.ToString("F1") : "--";
            Protocol = state.Active ? state.Protocol : "idle";
            IsActive = state.Active;
        }
        OnPropertyChanged(nameof(VoltageText));
        OnPropertyChanged(nameof(CurrentText));
        OnPropertyChanged(nameof(PowerText));
        OnPropertyChanged(nameof(Protocol));
        OnPropertyChanged(nameof(IsActive));
        OnPropertyChanged(nameof(IsConnected));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>
/// 通用 ICommand 实现（同步 + 异步）
/// </summary>
public class RelayCommand : ICommand
{
    private readonly Func<Task>? _executeAsync;
    private readonly Action? _execute;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Func<Task> executeAsync, Func<bool>? canExecute = null)
    {
        _executeAsync = executeAsync;
        _canExecute = canExecute;
    }

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public async void Execute(object? parameter)
    {
        if (_executeAsync != null) await _executeAsync();
        else _execute?.Invoke();
    }

    public event EventHandler? CanExecuteChanged
    {
        add { CommandManager.RequerySuggested += value; }
        remove { CommandManager.RequerySuggested -= value; }
    }
}

/// <summary>
/// 通用泛型 ICommand 实现
/// </summary>
public class RelayCommand<T> : ICommand
{
    private readonly Func<T, Task>? _executeAsync;
    private readonly Action<T>? _execute;
    private readonly Predicate<T>? _canExecute;

    public RelayCommand(Func<T, Task> executeAsync, Predicate<T>? canExecute = null)
    {
        _executeAsync = executeAsync;
        _canExecute = canExecute;
    }

    public RelayCommand(Action<T> execute, Predicate<T>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke((T)parameter!) ?? true;

    public async void Execute(object? parameter)
    {
        if (_executeAsync != null) await _executeAsync((T)parameter!);
        else _execute?.Invoke((T)parameter!);
    }

    public event EventHandler? CanExecuteChanged
    {
        add { CommandManager.RequerySuggested += value; }
        remove { CommandManager.RequerySuggested -= value; }
    }
}