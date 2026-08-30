using System.Windows;
using CukTechController.UI.Native;
using CukTechController.ViewModels;

namespace CukTechController.Views
{
    public partial class SettingsView : Window
    {
        public SettingsView()
        {
            InitializeComponent();
            DataContext = new SettingsViewModel();
            this.AttachColorOSVisualPack();
        }
    }
}
