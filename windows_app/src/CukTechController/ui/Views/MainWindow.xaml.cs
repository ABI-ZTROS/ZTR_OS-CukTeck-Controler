using System.IO;
using System.Windows;
using Microsoft.Win32;
using CukTechController.Controls;
using CukTechController.Protocol;
using CukTechController.ViewModels;

namespace CukTechController.Views;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm;

    public MainWindow()
    {
        InitializeComponent();
        _vm = (MainViewModel)DataContext;

        // 订阅 ViewModel 事件
        _vm.OpenSettingsRequested += (_, _) => Settings_Click(this, RoutedEventArgs.Empty);
        _vm.OpenLogRequested += (_, _) => Log_Click(this, RoutedEventArgs.Empty);
        _vm.OpenControlRequested += (_, piid) =>
        {
            var view = new PortControlView(piid);
            view.ShowDialog();
        };
    }

    private void CloudLogin_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new CloudLoginView();
        dialog.Owner = this;
        dialog.ShowDialog();
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
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
        foreach (var port in _vm.Ports.Where(p => !p.IsActive))
            _vm.OpenControlRequested?.Invoke(this, port.Piid);
    }

    private void AllOff_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.IsConnected) return;
        foreach (var port in _vm.Ports.Where(p => p.IsActive))
            _vm.OpenControlRequested?.Invoke(this, port.Piid);
    }

    private void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        _vm.DisconnectCommand.Execute(null);
    }
}
