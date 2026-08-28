using System;
using System.Windows;
using System.Windows.Controls;
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
            // 确保 WebView2 初始化完成
            await LoginWebView.EnsureCoreWebView2Async();
            LoginWebView.NavigationCompleted += OnNavigationCompleted;
            LoginWebView.CoreWebView2.NavigationStarting += OnNavigationStarting;
            
            // 导航到米家登录页
            LoginWebView.Source = new Uri("https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=True");
            System.Diagnostics.Debug.WriteLine("[CloudLogin] WebView2 initialized, navigating to login page");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[CloudLogin] WebView2 init failed: {ex.Message}");
            LoginFailed?.Invoke(this, $"WebView2 初始化失败: {ex.Message}");
        }
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        var url = e.Uri;
        System.Diagnostics.Debug.WriteLine($"[CloudLogin] Navigating to: {url}");

        // 检测登录成功的重定向
        if (url.Contains("sts.api.io.mi.com") && !_loginSuccessReported)
        {
            // 登录成功后导航到 sts.api.io.mi.com，延迟提取凭据
            System.Diagnostics.Debug.WriteLine("[CloudLogin] Detected sts.api.io.mi.com redirect (login success)");
        }
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (_loginSuccessReported) return;

        var url = LoginWebView.Source.ToString();
        System.Diagnostics.Debug.WriteLine($"[CloudLogin] Navigated to: {url}");

        try
        {
            if (LoginWebView.CoreWebView2?.CookieManager == null) return;

            string? serviceToken = null;
            string? ssecurity = null;
            string? userId = null;

            // 从多个可能的域名提取凭据
            var domains = new[]
            {
                url, // 当前页面
                "https://account.xiaomi.com",
                "https://sts.api.io.mi.com"
            };

            foreach (var domain in domains)
            {
                var cookies = await LoginWebView.CoreWebView2.CookieManager.GetCookiesAsync(domain);
                foreach (var cookie in cookies)
                {
                    if (cookie.Name == "serviceToken" && serviceToken == null)
                    {
                        serviceToken = cookie.Value;
                        System.Diagnostics.Debug.WriteLine($"[CloudLogin] Found serviceToken in {domain}");
                    }
                    if (cookie.Name == "ssecurity" && ssecurity == null)
                    {
                        ssecurity = cookie.Value;
                        System.Diagnostics.Debug.WriteLine($"[CloudLogin] Found ssecurity in {domain}");
                    }
                    if (cookie.Name == "userId" && userId == null)
                        userId = cookie.Value;
                }

                // 如果已获取全部凭据，提前退出
                if (!string.IsNullOrEmpty(serviceToken) && !string.IsNullOrEmpty(ssecurity))
                    break;
            }

            if (!string.IsNullOrEmpty(serviceToken) && !string.IsNullOrEmpty(ssecurity))
            {
                _loginSuccessReported = true;
                System.Diagnostics.Debug.WriteLine("[CloudLogin] Login SUCCESS!");
                _client.SetCredentials(serviceToken, ssecurity, userId ?? "");
                LoginCompleted?.Invoke(this, new LoginSuccessEventArgs(serviceToken, ssecurity));
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[CloudLogin] Cookie extraction error: {ex.Message}");
        }
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        LoginWebView.Reload();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        Window.GetWindow(this)?.Close();
    }
}
