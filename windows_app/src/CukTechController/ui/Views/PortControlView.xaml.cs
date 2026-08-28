using System.Windows;
using CukTechController.ViewModels;
using CukTechController.Utils;

namespace CukTechController.Views
{
    /// <summary>
    /// PortControlView 的交互逻辑
    /// </summary>
    public partial class PortControlView : Window
    {
        public PortControlView()
        {
            InitializeComponent();
            AppLogger.Instance.Debug("PortControlView initialized");
        }
    }
}