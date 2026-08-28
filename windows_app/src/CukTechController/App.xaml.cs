using System;
using System.Windows;
using System.Windows.Threading;
using CukTechController.Protocol;
using CukTechController.Utils;

namespace CukTechController;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // 配置日志
        var logDir = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "CukTechController", "logs");
        AppLogger.Instance.Configure(logDir);

        // 注册全局异常处理器
        // 1. Dispatcher 级（UI 线程未捕获异常）
        DispatcherUnhandledException += (_, args) =>
        {
            AppLogger.Instance.E("App", "DispatcherUnhandledException", args.Exception);
            args.Handled = true;
        };

        // 2. AppDomain 级（非 UI 线程未捕获异常）
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            AppLogger.Instance.E("App", $"UnhandledException({args.IsTerminating})",
                args.ExceptionObject as Exception);
        };

        // 3. TaskScheduler 级（Task 未观察异常）
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            AppLogger.Instance.E("App", "UnobservedTaskException", args.Exception);
            args.SetObserved();
        };

        AppLogger.Instance.I("App", "CukTechController started");

        try
        {
            // 加载设置
            await SettingsService.Instance.LoadAsync();

            // 初始化其他服务
            // TODO: 初始化 BLE 管理器等
        }
        catch (System.Exception ex)
        {
            AppLogger.Instance.E("App", "Failed to initialize", ex);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        AppLogger.Instance.I("App", "CukTechController exiting...");
        base.OnExit(e);
    }
}