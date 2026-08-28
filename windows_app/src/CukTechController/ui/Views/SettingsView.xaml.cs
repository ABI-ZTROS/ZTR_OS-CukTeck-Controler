using System.Windows;
using CukTechController.ViewModels;
using CukTechController.Utils;

namespace CukTechController.Views
{
    /// <summary>
    /// SettingsView 的交互逻辑
    /// </summary>
    public partial class SettingsView : Window
    {
        public SettingsView()
        {
            InitializeComponent();
            AppLogger.Debug("SettingsView initialized");
        }
    }
}