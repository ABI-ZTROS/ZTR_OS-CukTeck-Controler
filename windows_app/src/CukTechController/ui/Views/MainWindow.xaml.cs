using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using CukTechController.ViewModels;
using CukTechController.Utils;

namespace CukTechController.Views
{
    /// <summary>
    /// MainWindow 的交互逻辑
    /// </summary>
    public partial class MainWindow : Window
    {
        private MainViewModel? _vm;

        public MainWindow()
        {
            InitializeComponent();
            _vm = (MainViewModel?)DataContext;
            if (_vm != null)
            {
                _vm.OpenControlRequested += OnOpenControlRequested;
                _vm.OpenSettingsRequested += OnOpenSettingsRequested;
                _vm.OpenLogRequested += OnOpenLogRequested;
            }
            AppLogger.Debug("MainWindow initialized");
        }

        protected override void OnClosed(EventArgs e)
        {
            if (_vm != null)
            {
                _vm.OpenControlRequested -= OnOpenControlRequested;
                _vm.OpenSettingsRequested -= OnOpenSettingsRequested;
                _vm.OpenLogRequested -= OnOpenLogRequested;
            }
            base.OnClosed(e);
        }

        private void OnOpenControlRequested(object? sender, int piid)
        {
            var vm = new PortControlViewModel(piid);
            var window = new PortControlView { DataContext = vm };
            window.Show();
        }

        private void OnOpenSettingsRequested(object? sender, EventArgs e)
        {
            var vm = new SettingsViewModel();
            var window = new SettingsView { DataContext = vm };
            window.Show();
        }

        private void OnOpenLogRequested(object? sender, EventArgs e)
        {
            var window = new LogView();
            window.Show();
        }
    }

    // ========================================================================
    // 值转换器
    // ========================================================================

    /// <summary>
    /// 布尔取反转换器
    /// </summary>
    public class InvertBoolConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value is bool b) return !b;
            return true;
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value is bool b) return !b;
            return true;
        }
    }

    /// <summary>
    /// 字符串 → 可见性转换器（空字符串折叠）
    /// </summary>
    public class StringToVisibilityConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            var str = value as string;
            return string.IsNullOrEmpty(str) ? Visibility.Collapsed : Visibility.Visible;
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            throw new NotSupportedException();
        }
    }

    /// <summary>
    /// 布尔 → 连接状态文本转换器
    /// </summary>
    public class BoolToConnTextConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value is bool b) return b ? "已连接" : "未连接";
            return "未知";
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            throw new NotSupportedException();
        }
    }

    /// <summary>
    /// 布尔 → 开启/关闭文本转换器
    /// </summary>
    public class BoolToOnOffConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value is bool b) return b ? "关闭" : "开启";
            return "开启";
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            throw new NotSupportedException();
        }
    }
}