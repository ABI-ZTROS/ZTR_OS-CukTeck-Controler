using System.Windows;
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

    private void CloudLogin_Click(object sender, RoutedEventArgs e)
    {
        // CloudLoginView 是 UserControl，简化处理
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
