using System.Windows;
using CukTechController.ViewModels;

namespace CukTechController.Views
{
    public partial class PortControlView : Window
    {
        public PortControlView() : this(1) { }

        public PortControlView(int piid)
        {
            InitializeComponent();
            DataContext = new PortControlViewModel(piid);
        }
    }
}
