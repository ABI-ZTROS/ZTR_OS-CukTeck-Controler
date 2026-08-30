using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace CukTechController.Controls;

public partial class PowerRingControl : UserControl
{
    public static readonly DependencyProperty TotalPowerProperty =
        DependencyProperty.Register(nameof(TotalPower), typeof(double),
            typeof(PowerRingControl), new PropertyMetadata(0.0, OnPowerChanged));

    public double TotalPower
    {
        get => (double)GetValue(TotalPowerProperty);
        set => SetValue(TotalPowerProperty, value);
    }

    public static readonly DependencyProperty MaxPowerProperty =
        DependencyProperty.Register(nameof(MaxPower), typeof(double),
            typeof(PowerRingControl), new PropertyMetadata(240.0));

    public double MaxPower
    {
        get => (double)GetValue(MaxPowerProperty);
        set => SetValue(MaxPowerProperty, value);
    }

    public static readonly DependencyProperty ActiveCountProperty =
        DependencyProperty.Register(nameof(ActiveCount), typeof(int),
            typeof(PowerRingControl), new PropertyMetadata(0, OnActiveCountChanged));

    public int ActiveCount
    {
        get => (int)GetValue(ActiveCountProperty);
        set => SetValue(ActiveCountProperty, value);
    }

    private double _ringProgress = 0.0;
    private readonly PathFigure _bgFigure = new();
    private readonly PathFigure _progressFigure = new();
    private readonly ArcSegment _bgArc = new();
    private readonly ArcSegment _progressArc = new();

    public PowerRingControl()
    {
        InitializeComponent();
        Loaded += PowerRingControl_Loaded;
    }

    private void PowerRingControl_Loaded(object sender, RoutedEventArgs e)
    {
        // 构建完整圆路径（背景环）
        var bgPath = new Path { Stroke = Brushes.White, Opacity = 0.05, StrokeThickness = 10 };
        _bgFigure.StartPoint = new Point(120, 20);
        _bgArc.Point = new Point(120, 20); // 临时，Update 会设置
        _bgArc.Size = new Size(100, 100);
        _bgArc.IsLargeArc = true;
        _bgArc.SweepDirection = SweepDirection.Clockwise;
        _bgFigure.Segments.Add(_bgArc);
        // 第二个 arc 形成完整圆
        var bgArc2 = new ArcSegment
        {
            Point = new Point(120, 220),
            Size = new Size(100, 100),
            IsLargeArc = true,
            SweepDirection = SweepDirection.Clockwise,
        };
        _bgFigure.Segments.Add(bgArc2);
        var bgPathGeo = new PathGeometry(new[] { _bgFigure });
        bgPath.Data = bgPathGeo;
        (Content as Grid)?.Children.Insert(0, bgPath);

        // 进度环
        var progPath = new Path { Stroke = (Brush)FindResource("AccentGreen"), StrokeThickness = 10, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
        _progressFigure.StartPoint = new Point(120, 20);
        _progressArc.Size = new Size(100, 100);
        _progressArc.SweepDirection = SweepDirection.Clockwise;
        var progPathGeo = new PathGeometry(new[] { _progressFigure });
        progPath.Data = progPathGeo;
        (Content as Grid)?.Children.Insert(1, progPath);

        UpdateRing(TotalPower, MaxPower);
        UpdateText();
    }

    private static void OnPowerChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is PowerRingControl c && c.IsLoaded)
        {
            c.UpdateRing((double)e.NewValue, c.MaxPower);
            c.UpdateText();
        }
    }

    private static void OnActiveCountChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is PowerRingControl c && c.IsLoaded) c.UpdateText();
    }

    private void UpdateRing(double power, double max)
    {
        var progress = Math.Clamp(power / max, 0.0, 1.0);
        var sweepAngle = progress * 360;
        var rad = sweepAngle * Math.PI / 180;

        // ColorOS Spring 弹性过渡
        var anim = new DoubleAnimation(_ringProgress, progress, TimeSpan.FromMilliseconds(400))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        _ringProgress = progress;

        // 根据功率选择颜色
        Color ringColor;
        if (power <= 60) ringColor = Color.FromRgb(0x10, 0xB9, 0x81);   // 翡翠绿
        else if (power <= 120) ringColor = Color.FromRgb(0x3B, 0x82, 0xF6); // 电光蓝
        else if (power <= 180) ringColor = Color.FromRgb(0xF5, 0x9E, 0x0B); // 琥珀橙
        else ringColor = Color.FromRgb(0xEF, 0x44, 0x44);                  // 警示红

        var progPath = ((Grid)Content).Children[1] as Path;
        if (progPath != null)
        {
            progPath.Stroke = new SolidColorBrush(ringColor);
        }

        // 更新弧（简化：只画一个 arc，小于 180° 用 IsLargeArc=false）
        var endX = 120 + 100 * Math.Sin(rad);
        var endY = 20 + 100 * (1 - Math.Cos(rad));
        _progressFigure.StartPoint = new Point(120, 20);
        _progressArc.Point = new Point(endX, endY);
        _progressArc.IsLargeArc = sweepAngle > 180;
    }

    private void UpdateText()
    {
        PowerText.Text = $"{TotalPower:F1} W";
        SubText.Text = $"{ActiveCount}/4 口活跃";
    }
}
