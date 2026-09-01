// ═══════════════════════════════════════════════════════════════════════
// 🪟 MainWindow — 主窗口
//   启动时应用 ColorOS VisualPack (Mica/圆角/深色标题栏)
//   使用 AnimationHelper.ColorOS 入场动画
// ═══════════════════════════════════════════════════════════════════════

using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using CukTechController.Ble;
using CukTechController.Protocol;
using CukTechController.UI.Helpers;
using CukTechController.ViewModels;
using Serilog;

namespace CukTechController.Views;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm;
    private bool _visualPackApplied;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = new MainViewModel();
        _vm = (MainViewModel)DataContext;

        SourceInitialized += MainWindow_SourceInitialized;
        Loaded += MainWindow_Loaded;

        _vm.OpenSettingsRequested += (_, _) =>
        {
            var view = new SettingsView { Owner = this };
            view.ShowDialog();
        };
        _vm.OpenLogRequested += (_, _) =>
        {
            var view = new LogView { Owner = this };
            view.ShowDialog();
        };
    }

    private void MainWindow_SourceInitialized(object? sender, EventArgs e)
    {
        try
        {
            var hWnd = new WindowInteropHelper(this).EnsureHandle();
            ((App)Application.Current).ApplyColorOSToWindow(hWnd);
            _visualPackApplied = true;
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[MAIN] ColorOS VisualPack 应用失败");
        }
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        AnimationHelper.PlayPageEntrance(this, durationMs: 400, slideDistance: 24);

        // 自动连接：Settings.AutoConnect=true 且已有 Token 时，启动后台静默扫描+自动连第一个酷态科
        try
        {
            if (Settings.Instance.AutoConnect)
            {
                bool hasToken = await TokenRepository.Instance.HasTokenAsync();
                if (hasToken)
                {
                    Log.Information("[MAIN] AutoConnect enabled — background auto scan+connect");
                    _ = Task.Run(() => _vm.AutoConnectAsync()); // 后台执行，不阻塞 UI
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[MAIN] AutoConnect failed (non-fatal)");
        }
    }

    // 导入凭证 — 改为 async void（WPF Click 事件允许 async void）
    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "酷态科凭证 (*.cuk)|*.cuk|所有文件 (*.*)|*.*",
            Title = "选择 Android 导出的凭证文件"
        };
        if (dlg.ShowDialog() == true)
        {
            try
            {
                var (ok, err) = await TokenRepository.Instance.ImportCloudFromFileAsync(dlg.FileName);
                if (ok)
                {
                    MessageBox.Show("✅ 凭证导入成功！\n现在可以点扫描+连接了。",
                        "导入成功", MessageBoxButton.OK, MessageBoxImage.Information);
                }
                else
                {
                    MessageBox.Show($"❌ 导入失败: {err}", "错误",
                        MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"❌ 导入异常: {ex.Message}", "错误",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var view = new SettingsView { Owner = this };
        view.ShowDialog();
    }

    private void Log_Click(object sender, RoutedEventArgs e)
    {
        var view = new LogView { Owner = this };
        view.ShowDialog();
    }

    // AllOn / AllOff — 调真实 PortControl，不再弹假 MessageBox
    private async void AllOn_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.IsConnected)
        {
            MessageBox.Show("请先连接充电器。", "未连接", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        try
        {
            var ok = await PortControl.Instance.SetPortAsync(
                WindowsConnector.Instance, "all", on: true);
            if (!ok) MessageBox.Show("❌ 全部开启失败，请查看日志。", "错误");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"❌ 异常: {ex.Message}", "错误");
        }
    }

    private async void AllOff_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.IsConnected)
        {
            MessageBox.Show("请先连接充电器。", "未连接", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        try
        {
            var ok = await PortControl.Instance.SetPortAsync(
                WindowsConnector.Instance, "all", on: false);
            if (!ok) MessageBox.Show("❌ 全部关闭失败，请查看日志。", "错误");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"❌ 异常: {ex.Message}", "错误");
        }
    }

    private void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        // 优先走 DisconnectCommand (MVVM)，Click 只是备用
        if (_vm.DisconnectCommand.CanExecute(null))
            _vm.DisconnectCommand.Execute(null);
    }

    // 4 个端口卡片点击 → 打开单口控制窗口
    private void PortCard_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is string tagStr &&
            int.TryParse(tagStr, out int piid))
        {
            if (!_vm.IsConnected)
            {
                MessageBox.Show("请先连接充电器。", "未连接", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            var view = new PortControlView(piid) { Owner = this };
            view.ShowDialog();
        }
    }
}
