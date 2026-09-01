// ═══════════════════════════════════════════════════════════════════════
// 🧠 MainViewModel + PortStateViewModel
// ═══════════════════════════════════════════════════════════════════════

using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CukTechController.Ble;
using CukTechController.Models;
using CukTechController.Protocol;
using Serilog;

namespace CukTechController.ViewModels;

// ────────────────────────────────────────────────────────────────────────
// 📊 MainViewModel — 主窗口
// ────────────────────────────────────────────────────────────────────────

public partial class MainViewModel : ObservableObject
{
    private readonly WindowsScanner _scanner = WindowsScanner.Instance;
    private readonly WindowsConnector _connector = WindowsConnector.Instance;
    private readonly TokenRepository _tokenRepo = TokenRepository.Instance;
    private readonly PortControl _portCtrl = PortControl.Instance;
    private readonly SettingsService _settingsSvc = SettingsService.Instance;

    private PeriodicTimer? _refreshTimer;
    private CancellationTokenSource? _refreshCts;

    // ─── 源生成属性 ───

    [ObservableProperty] private ObservableCollection<ScanResult> scanResults = new();
    [ObservableProperty] private ScanResult? selectedScanResult;
    [ObservableProperty] private ObservableCollection<PortStateViewModel> ports = new();

    [ObservableProperty] [NotifyCanExecuteChangedFor(nameof(ScanCommand))]
    [NotifyCanExecuteChangedFor(nameof(ConnectCommand))]
    private bool isScanning;

    [ObservableProperty] [NotifyCanExecuteChangedFor(nameof(ScanCommand))]
    [NotifyCanExecuteChangedFor(nameof(ConnectCommand))]
    private bool isConnecting;

    [ObservableProperty] [NotifyCanExecuteChangedFor(nameof(DisconnectCommand))]
    private bool isConnected;

    [ObservableProperty] private string statusMessage = "未连接";
    [ObservableProperty] private string errorMessage = string.Empty;

    // ─── 计算属性 ───

    public HashSet<int> ActivePorts { get; private set; } = new();

    public double TotalPower => Ports.Where(p => p.IsActive).Sum(p =>
        double.TryParse(p.PowerText.Replace('W', '\0').Trim(), out var pw) ? pw : 0);

    public int ActivePortCount => ActivePorts.Count;

    public string C1PortText => GetPortText(1);
    public string C2PortText => GetPortText(2);
    public string C3PortText => GetPortText(3);
    public string APortText => GetPortText(4);

    private string GetPortText(int piid)
    {
        var p = Ports.FirstOrDefault(x => x.Piid == piid);
        if (p == null) return "--";
        if (!p.IsActive) return "idle";
        return $"{p.PowerText} · {p.Protocol}";
    }

    // ─── 事件 ───

    public event EventHandler<int>? OpenControlRequested;
    public event EventHandler? OpenSettingsRequested;
    public event EventHandler? OpenLogRequested;

    // ─── 构造 ───

    public MainViewModel()
    {
        foreach (var piid in new[] { 1, 2, 3, 4 })
            Ports.Add(new PortStateViewModel(piid));

        PortStreamController.Instance.StateChanged += OnPortStateChanged;
    }

    private void OnPortStateChanged(object? sender, PortState e)
    {
        if (e.Piid >= 1 && e.Piid <= 4 && e.Piid <= Ports.Count)
        {
            if (e.Active) ActivePorts.Add(e.Piid); else ActivePorts.Remove(e.Piid);
            Ports[e.Piid - 1].Update(e);
            OnPropertyChanged(nameof(TotalPower));
            OnPropertyChanged(nameof(ActivePortCount));
            OnPropertyChanged(nameof(ActivePorts));
            OnPropertyChanged(nameof(C1PortText));
            OnPropertyChanged(nameof(C2PortText));
            OnPropertyChanged(nameof(C3PortText));
            OnPropertyChanged(nameof(APortText));
        }
    }

    // ─── Scan ───

    private bool CanScan => !IsScanning && !IsConnecting;

    [RelayCommand(CanExecute = nameof(CanScan))]
    private async Task ScanAsync()
    {
        IsScanning = true;
        ErrorMessage = string.Empty;
        StatusMessage = "扫描中...";
        try
        {
            var results = await _scanner.StartAsync(
                timeout: TimeSpan.FromSeconds(Math.Max(3, Settings.Instance.ScanTimeout)));
            ScanResults = new ObservableCollection<ScanResult>(results);
            IsScanning = false;

            var cuk = results.FirstOrDefault(r => r.IsCuktech);
            if (cuk == null)
            {
                ErrorMessage = "未扫描到酷态科 AD1204U 设备（请确认充电器附近蓝牙广播可用）";
                StatusMessage = "未连接";
            }
            else
            {
                StatusMessage = $"扫描到 {results.Count} 个设备，酷态科: {results.Count(r => r.IsCuktech)}";
                SelectedScanResult ??= cuk;
            }
        }
        catch (Exception ex)
        {
            IsScanning = false;
            ErrorMessage = $"扫描失败: {ex.Message}";
            StatusMessage = "错误";
            Log.Error(ex, "Scan failed");
        }
    }

    // ─── Connect + Auth + WireUp + Init + Timer ───

    private bool CanConnect => !IsConnecting && SelectedScanResult != null;

    [RelayCommand(CanExecute = nameof(CanConnect))]
    private async Task ConnectAsync()
    {
        if (SelectedScanResult == null) return;
        IsConnecting = true;
        ErrorMessage = string.Empty;
        StatusMessage = $"连接到 {SelectedScanResult.Name ?? "(匿名设备)"}...";
        try
        {
            var ok = await _connector.ConnectAsync(SelectedScanResult.BluetoothAddress);
            if (!ok) { FailConnect(); return; }

            StatusMessage = "认证中...";
            var tokenCfg = await _tokenRepo.GetTokenAsync();
            if (tokenCfg == null || string.IsNullOrEmpty(tokenCfg.Token))
            {
                IsConnecting = false; IsConnected = false;
                StatusMessage = "未连接";
                ErrorMessage = "未配置 Token：请点「导入凭证」先导入 Android 导出的 .cuk 文件";
                await _connector.DisconnectAsync();
                return;
            }

            var authed = await Authenticator.Instance.AuthenticateAsync(_connector, tokenCfg.Token);
            if (!authed)
            {
                IsConnecting = false; IsConnected = false;
                StatusMessage = "认证失败";
                ErrorMessage = "认证失败：Token 无效或设备无响应";
                await _connector.DisconnectAsync();
                return;
            }

            PortDecoderWiring.WireUp(_connector);
            IsConnecting = false; IsConnected = true;
            StatusMessage = "同步设备状态...";

            // ✅ 初始状态同步：GET 1-4 端口 + 5 场景 6 息屏 7 协议 16 端口掩码 19 息屏空闲 20 屏幕锁 21 协议开关
            await SnapshotAllAsync();

            // ✅ 启动周期轮询定时器（Settings.RefreshInterval 毫秒 → 最小 1s）
            StartRefreshLoop();

            StatusMessage = "已连接";
            Log.Information("Connected to {Device} (addr={Addr})",
                SelectedScanResult.Name, SelectedScanResult.DeviceId);
        }
        catch (Exception ex)
        {
            FailConnect();
            Log.Error(ex, "Connect exception");
        }
    }

    /// <summary>AutoConnect：后台静默扫到第一个酷态科就自动连上</summary>
    public async Task AutoConnectAsync()
    {
        if (IsConnected || IsConnecting || IsScanning) return;
        var results = await _scanner.StartAsync(
            timeout: TimeSpan.FromSeconds(10), filterCuktech: true);
        var first = results.FirstOrDefault(r => r.IsCuktech);
        if (first == null)
        {
            Log.Information("AutoConnect: no device found");
            return;
        }
        SelectedScanResult = first;
        if (ConnectCommand.CanExecute(null))
            await ConnectCommand.ExecuteAsync(null!);
    }

    private async Task SnapshotAllAsync()
    {
        // 端口状态：GET PIID 1-4 让 PortDecoder 解码分发
        for (int piid = 1; piid <= 4; piid++)
        {
            try
            {
                var resp = await EncryptedChannel.Instance.SendGetAsync(
                    _connector, ProtocolConstants.SiidCharger, piid, seq: 0xF0 + piid);
                if (resp != null)
                    PortDecoder.DispatchFromTlvMap(resp);
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Initial Snapshot GET piid={Piid} failed", piid);
            }
        }
        // 设置项：顺便拉一次 5/6/8/16/19/20/21（SettingsView 打开后会自己读）
        try
        {
            await _settingsSvc.GetGlobalTimerAsync(_connector);
            await _portCtrl.ReadStateAsync(_connector);
        }
        catch { /* noop */ }
    }

    private void StartRefreshLoop()
    {
        StopRefreshLoop();
        int intervalMs = Math.Clamp(Settings.Instance.RefreshInterval, 1000, 30000);
        var per = TimeSpan.FromMilliseconds(intervalMs);
        _refreshTimer = new PeriodicTimer(per);
        _refreshCts = new CancellationTokenSource();

        _ = Task.Run(async () =>
        {
            try
            {
                while (await _refreshTimer.WaitForNextTickAsync(_refreshCts.Token))
                {
                    try
                    {
                        if (!IsConnected) break;
                        for (int piid = 1; piid <= 4; piid++)
                        {
                            var resp = await EncryptedChannel.Instance.SendGetAsync(
                                _connector, ProtocolConstants.SiidCharger, piid,
                                seq: (int)(0xE000 + (piid)) & 0xFF);
                            if (resp != null)
                                PortDecoder.DispatchFromTlvMap(resp);
                        }
                    }
                    catch (Exception ex)
                    {
                        Log.Warning(ex, "Periodic refresh tick failed");
                    }
                }
            }
            catch (OperationCanceledException) { /* expected */ }
            catch (Exception ex)
            {
                Log.Error(ex, "Refresh loop crashed");
            }
        });
    }

    private void StopRefreshLoop()
    {
        try { _refreshCts?.Cancel(); } catch { }
        try { _refreshTimer?.Dispose(); } catch { }
        _refreshTimer = null; _refreshCts = null;
    }

    private void FailConnect()
    {
        IsConnecting = false; IsConnected = false;
        StatusMessage = "连接失败"; ErrorMessage = "连接或认证失败（请查看日志）";
        StopRefreshLoop();
    }

    // ─── Disconnect ───

    private bool CanDisconnect => IsConnected;

    [RelayCommand(CanExecute = nameof(CanDisconnect))]
    private async Task DisconnectAsync()
    {
        StopRefreshLoop();
        PortDecoderWiring.TearDown(_connector);
        try { await _connector.DisconnectAsync(); }
        catch (Exception ex) { Log.Warning(ex, "Disconnect error"); }
        IsConnected = false;
        StatusMessage = "未连接";
        ErrorMessage = string.Empty;
        foreach (var p in Ports) p.Update(null);
        ActivePorts.Clear();
        OnPropertyChanged(nameof(ActivePortCount));
        OnPropertyChanged(nameof(TotalPower));
    }

    // ─── 事件触发命令 ───

    public void RaiseOpenSettings() => OpenSettingsRequested?.Invoke(this, EventArgs.Empty);
    public void RaiseOpenLog() => OpenLogRequested?.Invoke(this, EventArgs.Empty);
}

// ────────────────────────────────────────────────────────────────────────
// 🔌 PortStateViewModel — 单个端口状态
// ────────────────────────────────────────────────────────────────────────

public partial class PortStateViewModel : ObservableObject
{
    public int Piid { get; }
    public string Name { get; }

    [ObservableProperty] private string voltageText = "--";
    [ObservableProperty] private string currentText = "--";
    [ObservableProperty] private string powerText = "--";
    [ObservableProperty] private string protocol = "--";
    [ObservableProperty] private bool isActive;
    [ObservableProperty] private bool isConnected;

    public event EventHandler<int>? OpenControlRequested;
    public event EventHandler<string>? ToggleRequested;

    public PortStateViewModel(int piid)
    {
        Piid = piid;
        Name = piid switch { 1 => "C1", 2 => "C2", 3 => "C3", _ => "A" };
    }

    [RelayCommand]
    private void OpenControl() => OpenControlRequested?.Invoke(this, Piid);

    [RelayCommand]
    private void TogglePort() => ToggleRequested?.Invoke(this, Piid <= 3 ? $"c{Piid}" : "a");

    public void Update(PortState? state)
    {
        if (state == null)
        {
            VoltageText = CurrentText = PowerText = Protocol = "--";
            IsActive = false; IsConnected = false;
        }
        else
        {
            IsConnected = true;
            VoltageText = state.Active ? state.Voltage.ToString("F1") : "--";
            CurrentText = state.Active ? state.Current.ToString("F1") : "--";
            PowerText = state.Active ? state.Power.ToString("F1") : "--";
            Protocol = state.Active ? state.Protocol : "idle";
            IsActive = state.Active;
        }
    }
}
