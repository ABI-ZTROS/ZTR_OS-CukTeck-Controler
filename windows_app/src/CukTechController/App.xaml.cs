// ═══════════════════════════════════════════════════════════════════════
// 🚀 App — 应用入口
//   DI 容器 + Serilog + ColorOS VisualPack (MSMC 同款架构)
// ═══════════════════════════════════════════════════════════════════════

using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using CukTechController.Protocol;
using CukTechController.UI.Native;
using Microsoft.Extensions.DependencyInjection;
using Serilog;

namespace CukTechController;

public partial class App : Application
{
    // ═══ DI 容器（MSMC 同款 Microsoft.Extensions.DependencyInjection）═══
    public static IServiceProvider Services { get; private set; } = null!;

    private readonly WindowEffectsService _windowEffects = new();

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // ─── 1. 配置 Serilog（替代原有简易 Logger）───
        var logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "CukTechController", "logs");
        Directory.CreateDirectory(logDir);

        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Information()
            .WriteTo.File(
                Path.Combine(logDir, "cuktech-.log"),
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 14,
                outputTemplate: "{Timestamp:HH:mm:ss} [{Level:u3}] {Message:lj}{NewLine}{Exception}")
            .Enrich.FromLogContext()
            .CreateLogger();

        Log.Information("[BOOT] CukTechController starting...");

        // ─── 2. 配置 DI 容器 ───
        var services = new ServiceCollection();
        ConfigureServices(services);
        Services = services.BuildServiceProvider();

        // ─── 3. 全局异常防护（三层）───
        SetupGlobalExceptionHandling();

        try
        {
            await Settings.Instance.LoadAsync();
            Log.Information("[BOOT] Settings loaded");
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[BOOT] Settings load failed (using defaults)");
        }

        Log.Information("[BOOT] DI container ready");
    }

    private void ConfigureServices(ServiceCollection services)
    {
        // 注册窗口效果服务（Singleton）
        services.AddSingleton<WindowEffectsService>(_ => _windowEffects);

        // 可以在这里注册其他服务（BLE、协议、网络等）
        // services.AddSingleton<IWindowsScanner, WindowsScanner>();
    }

    private void SetupGlobalExceptionHandling()
    {
        // 第一层：UI 线程未处理异常
        DispatcherUnhandledException += (_, args) =>
        {
            Log.Fatal(args.Exception, "[FATAL] UI 线程未处理异常");
            args.Handled = true;
        };

        // 第二层：非 UI 线程未处理异常
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
                Log.Fatal(ex, "[FATAL] 非 UI 线程异常 (terminating={Terminating})", args.IsTerminating);
        };

        // 第三层：Task 未观察异常
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Warning(args.Exception, "[WARN] Task 未观察异常");
            args.SetObserved();
        };
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Log.Information("[EXIT] Shutting down...");
        Log.CloseAndFlush();
        base.OnExit(e);
    }

    // ═══ 公开方法：供 MainWindow.xaml.cs 调用 ═══

    /// <summary>
    /// 在主窗口 Show() 之后调用，给窗口套上 ColorOS VisualPack
    /// (Mica 背景 + 深色标题栏 + 小圆角)
    /// </summary>
    public void ApplyColorOSToWindow(IntPtr hWnd)
    {
        try
        {
            _windowEffects.ApplyColorOSVisualPack(hWnd, darkTitleBar: true);
            Log.Information("[THEME] ColorOS VisualPack applied to 0x{H:X8}", hWnd.ToInt64());
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[THEME] ColorOS VisualPack 应用失败（不致命，降级默认）");
        }
    }
}
