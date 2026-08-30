// ═══════════════════════════════════════════════════════════════════════
// 🚀 App — 应用入口（MSMC 同款手动 Show + 三层异常防护）
//   去掉 StartupUri，在 OnStartup 里手动 Show 主窗口
//   任何启动阶段异常都会弹窗而不是静默退出
// ═══════════════════════════════════════════════════════════════════════

using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using CukTechController.Protocol;
using CukTechController.UI.Native;
using CukTechController.Views;
using Microsoft.Extensions.DependencyInjection;
using Serilog;

namespace CukTechController;

public partial class App : Application
{
    public static IServiceProvider Services { get; private set; } = null!;

    private readonly WindowEffectsService _windowEffects = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // ─── 0. 异常防护（尽早挂接）───
        SetupGlobalExceptionHandling();

        // ─── 1. 配置 Serilog ───
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

        try
        {
            // ─── 2. DI 容器 ───
            var services = new ServiceCollection();
            services.AddSingleton<WindowEffectsService>(_ => _windowEffects);
            Services = services.BuildServiceProvider();
            AppLogger.Instance.Configure(logDir);
            Log.Information("[BOOT] AppLogger configured");
            Log.Information("[BOOT] DI ready");

            // ─── 3. 加载设置 ───
            try
            {
                Settings.Instance.LoadAsync().GetAwaiter().GetResult();
                Log.Information("[BOOT] Settings loaded");
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "[BOOT] Settings load failed (using defaults)");
            }

            // ─── 4. 手动 Show 主窗口（MSMC 模式）───
            var mainWindow = new MainWindow();
            MainWindow = mainWindow;
            mainWindow.Show();
            Log.Information("[BOOT] MainWindow shown");

            ShutdownMode = ShutdownMode.OnMainWindowClose;
        }
        catch (Exception ex)
        {
            Log.Fatal(ex, "[FATAL] Boot failed");
            MessageBox.Show(
                $"启动失败！\n\n错误: {ex.Message}\n\n{ex.StackTrace}",
                "酷态科控制器 - 启动错误",
                MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(-1);
        }
    }

    private void SetupGlobalExceptionHandling()
    {
        DispatcherUnhandledException += (_, args) =>
        {
            try { Log.Fatal(args.Exception, "[FATAL] UI thread exception"); } catch { }
            args.Handled = true;
            MessageBox.Show(
                $"发生未处理的错误：\n{args.Exception.Message}",
                "错误", MessageBoxButton.OK, MessageBoxImage.Error);
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
            {
                try { Log.Fatal(ex, "[FATAL] Non-UI thread exception"); } catch { }
            }
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            try { Log.Warning(args.Exception, "[WARN] Unobserved task exception"); } catch { }
            args.SetObserved();
        };
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { Log.Information("[EXIT] Shutting down..."); Log.CloseAndFlush(); } catch { }
        base.OnExit(e);
    }

    public void ApplyColorOSToWindow(IntPtr hWnd)
    {
        try
        {
            _windowEffects.ApplyColorOSVisualPack(hWnd, darkTitleBar: true);
            Log.Information("[THEME] ColorOS VisualPack applied");
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[THEME] ColorOS VisualPack failed (non-fatal)");
        }
    }
}
