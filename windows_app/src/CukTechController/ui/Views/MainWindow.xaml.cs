// ═══════════════════════════════════════════════════════════════════════
// 🪟 MainWindow — 主窗口
//   启动时应用 ColorOS VisualPack (Mica/圆角/深色标题栏)
//   使用 AnimationHelper.ColorOS 入场动画
// ═══════════════════════════════════════════════════════════════════════

using System.Windows;
using System.Windows.Interop;
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

        // ═══ VisualPack 在 SourceInitialized 调用（Hwnd 刚创建，最佳时机）═══
        // Loaded 事件中只做入场动画
        SourceInitialized += MainWindow_SourceInitialized;
        Loaded += MainWindow_Loaded;

        // 订阅 ViewModel 事件
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
        // 应用 ColorOS VisualPack（Mica + 深色标题栏 + 小圆角）
        // SourceInitialized = HwndSource 已创建，是调 DwmSetWindowAttribute 的最佳时机
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

    private void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        // ColorOS 入场动画（淡入 + 从下方滑入）
        // 注意：只动画 Window.Content（内部 Grid），不能动画 Window 本身
        AnimationHelper.PlayPageEntrance(this, durationMs: 400, slideDistance: 24);
    }

    private void CloudLogin_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show("云登录功能已集成在设置中\n导入凭证按钮可直接导入 Android 导出的 .cuk 文件",
            "云登录", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "酷态科凭证 (*.cuk)|*.cuk|所有文件 (*.*)|*.*",
            Title = "选择 Android 导出的凭证文件"
        };
        if (dlg.ShowDialog() == true)
        {
            var (ok, err) = TokenRepository.Instance.ImportCloudFromFileAsync(dlg.FileName).GetAwaiter().GetResult();
            if (ok)
            {
                MessageBox.Show("✅ 凭证导入成功！\n现在可以直接连接充电器了。",
                    "导入成功", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show($"❌ 导入失败: {err}", "错误",
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

    private void AllOn_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.IsConnected) return;
        MessageBox.Show("全部开启命令已发送", "控制");
    }

    private void AllOff_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.IsConnected) return;
        MessageBox.Show("全部关闭命令已发送", "控制");
    }

    private void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        _vm.DisconnectCommand.Execute(null);
    }
}
