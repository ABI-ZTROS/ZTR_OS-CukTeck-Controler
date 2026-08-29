using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using CukTechController.Protocol;
using Microsoft.Web.WebView2.Core;

namespace CukTechController.Views;

public partial class CloudLoginView : UserControl
{
    private readonly XiaomiCloudClient _client;
    private bool _initialized;
    private bool _loginSuccessReported;

    public event EventHandler<LoginSuccessEventArgs>? LoginCompleted;
    public event EventHandler<string>? LoginFailed;

    public CloudLoginView()
    {
        InitializeComponent();
        _client = new XiaomiCloudClient();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_initialized) return;
        _initialized = true;

        try
        {
            await LoginWebView.EnsureCoreWebView2Async();
            LoginWebView.NavigationCompleted += OnNavigationCompleted;

            LoginWebView.Source = new Uri(
                "https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=True");
        }
        catch (Exception ex)
        {
            LoginFailed?.Invoke(this, $"WebView2 初始化失败: {ex.Message}");
        }
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (_loginSuccessReported) return;

        var url = LoginWebView.Source.ToString();
        try
        {
            if (LoginWebView.CoreWebView2?.CookieManager == null) return;

            string? serviceToken = null;
            string? ssecurity = null;
            string? userId = null;

            var domains = new[]
            {
                url,
                "https://account.xiaomi.com",
                "https://sts.api.io.mi.com"
            };

            foreach (var domain in domains)
            {
                var cookies = await LoginWebView.CoreWebView2.CookieManager.GetCookiesAsync(domain);
                foreach (var cookie in cookies)
                {
                    if (cookie.Name == "serviceToken" && serviceToken == null)
                        serviceToken = cookie.Value;
                    if (cookie.Name == "ssecurity" && ssecurity == null)
                        ssecurity = cookie.Value;
                    if (cookie.Name == "userId" && userId == null)
                        userId = cookie.Value;
                }
                if (!string.IsNullOrEmpty(serviceToken) && !string.IsNullOrEmpty(ssecurity))
                    break;
            }

            if (!string.IsNullOrEmpty(serviceToken) && !string.IsNullOrEmpty(ssecurity))
            {
                _loginSuccessReported = true;
                _client.SetCredentials(serviceToken, ssecurity, userId ?? "");
                LoginCompleted?.Invoke(this,
                    new LoginSuccessEventArgs(serviceToken, ssecurity));
            }
        }
        catch { }
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        LoginWebView.Reload();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        Window.GetWindow(this)?.Close();
    }

    /// <summary>
    /// 🚀 导入 Android 端导出的 .cuk 凭证文件
    /// </summary>
    private async void ImportButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Filter = "酷态科凭证文件 (*.cuk)|*.cuk|所有文件 (*.*)|*.*",
            Title = "选择 Android 导出的凭证文件",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };

        if (dialog.ShowDialog() != true) return;

        var path = dialog.FileName;
        var btn = sender as Button;
        if (btn != null) btn.IsEnabled = false;

        try
        {
            var (ok, err) = await TokenRepository.Instance.ImportCloudFromFileAsync(path);

            if (ok)
            {
                // 拿到导入的凭证，设置到 CloudClient
                var cred = await TokenRepository.Instance.GetCloudAsync();
                if (cred != null)
                {
                    _client.SetCredentials(cred.ServiceToken, cred.Ssecurity, cred.UserId);
                    _loginSuccessReported = true;

                    MessageBox.Show(
                        $"✅ 凭证导入成功！\n\n" +
                        $"用户: {cred.UserId}\n" +
                        $"设备: {cred.Did} ({cred.DeviceName})\n\n" +
                        $"现在可以直接连接充电器了。",
                        "导入成功",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);

                    LoginCompleted?.Invoke(this,
                        new LoginSuccessEventArgs(cred.ServiceToken, cred.Ssecurity));
                }
            }
            else
            {
                MessageBox.Show(
                    $"❌ 导入失败: {err}",
                    "导入失败",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"❌ 导入出错: {ex.Message}",
                "导入错误",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            if (btn != null) btn.IsEnabled = true;
        }
    }
}
