using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using CukTechController.Ble;
using CukTechController.Utils;

namespace CukTechController.Views
{
    /// <summary>
    /// LogView 的交互逻辑 —— Hex 日志显示
    /// </summary>
    public partial class LogView : Window
    {
        public LogView()
        {
            InitializeComponent();
            Loaded += OnLoaded;
            AppLogger.Instance.D("LogView", "initialized");
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            RefreshLog();
            // 订阅 BLE 通知
            WindowsConnector.Instance.ValueReceived += OnValueReceived;
        }

        protected override void OnClosed(EventArgs e)
        {
            WindowsConnector.Instance.ValueReceived -= OnValueReceived;
            base.OnClosed(e);
        }

        private void OnValueReceived(object? sender, (string Channel, byte[] Data) e)
        {
            var hex = BitConverter.ToString(e.Data).Replace('-', ' ');
            var line = $"[{DateTime.Now:HH:mm:ss.fff}] BLE<{e.Channel}> ({e.Data.Length}字节): {hex}";
            AppendLog(line);
        }

        private void RefreshButton_Click(object sender, RoutedEventArgs e)
        {
            RefreshLog();
        }

        private void ClearButton_Click(object sender, RoutedEventArgs e)
        {
            LogTextBox.Clear();
            StatusTextBlock.Text = "日志已清空";
        }

        private void RefreshLog()
        {
            try
            {
                var logDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "CukTechController", "logs");

                if (!Directory.Exists(logDir))
                {
                    LogTextBox.Text = "日志目录不存在";
                    StatusTextBlock.Text = "无日志";
                    return;
                }

                var logPath = Path.Combine(logDir, "cuktech.log");
                if (!File.Exists(logPath))
                {
                    LogTextBox.Text = "暂无日志文件";
                    StatusTextBlock.Text = "就绪";
                    return;
                }

                // 读取主日志文件 + 所有滚动文件，按时间顺序合并
                var sb = new StringBuilder();
                var files = Directory.GetFiles(logDir, "cuktech.log*")
                    .OrderBy(f => f.EndsWith(".log") ? 0 : int.TryParse(Path.GetExtension(f).TrimStart('.'), out var n) ? n : 999);

                foreach (var file in files)
                {
                    if (File.Exists(file))
                    {
                        var content = File.ReadAllText(file);
                        if (!string.IsNullOrWhiteSpace(content))
                        {
                            sb.AppendLine($"--- {Path.GetFileName(file)} ---");
                            sb.AppendLine(content);
                        }
                    }
                }

                LogTextBox.Text = sb.Length > 0 ? sb.ToString() : "暂无日志内容";
                LogTextBox.SearchStart = LogTextBox.Text.Length; // scroll to end
                StatusTextBlock.Text = $"已加载 {files.Count()} 个日志文件";
            }
            catch (Exception ex)
            {
                StatusTextBlock.Text = $"加载失败: {ex.Message}";
                AppLogger.Instance.E("LogView", $"Refresh error: {ex.Message}", ex);
            }
        }

        private void AppendLog(string line)
        {
            try
            {
                if (!Dispatcher.CheckAccess())
                {
                    Dispatcher.Invoke(() => AppendLog(line));
                    return;
                }
                LogTextBox.AppendText(line + Environment.NewLine);
                LogTextBox.SearchStart = LogTextBox.Text.Length;
            }
            catch { }
        }
    }
}