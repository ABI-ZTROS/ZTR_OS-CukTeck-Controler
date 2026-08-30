using System.Windows;
using System.Windows.Controls;

namespace CukTechController.Controls;

public partial class GlassBorder : UserControl
{
    public static readonly DependencyProperty RadiusProperty =
        DependencyProperty.Register(nameof(Radius), typeof(double), typeof(GlassBorder),
            new PropertyMetadata(16.0));

    public double Radius
    {
        get => (double)GetValue(RadiusProperty);
        set => SetValue(RadiusProperty, value);
    }

    public static readonly DependencyProperty PaddingProperty =
        DependencyProperty.Register(nameof(Padding), typeof(Thickness), typeof(GlassBorder),
            new PropertyMetadata(new Thickness(12)));

    public Thickness Padding
    {
        get => (Thickness)GetValue(PaddingProperty);
        set => SetValue(PaddingProperty, value);
    }

    public GlassBorder() { InitializeComponent(); }
}
