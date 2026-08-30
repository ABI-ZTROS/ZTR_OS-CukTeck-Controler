using System;
using System.Windows.Shapes;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CukTechController.Controls;

public partial class ChargerVisualControl : UserControl
{
    private readonly Dictionary<int, Ellipse> _leds = new();
    private readonly Dictionary<int, Shape> _ports = new();
    private DoubleAnimation? _pulseAnim;

    public static readonly DependencyProperty ActivePortsProperty =
        DependencyProperty.Register(nameof(ActivePorts), typeof(HashSet<int>),
            typeof(ChargerVisualControl),
            new PropertyMetadata(new HashSet<int>(), OnActivePortsChanged));

    public HashSet<int> ActivePorts
    {
        get => (HashSet<int>)GetValue(ActivePortsProperty);
        set => SetValue(ActivePortsProperty, value);
    }

    public ChargerVisualControl()
    {
        InitializeComponent();
        Loaded += ChargerVisualControl_Loaded;
    }

    private void ChargerVisualControl_Loaded(object sender, RoutedEventArgs e)
    {
        // 建立引用
        _leds[1] = LedC1;
        _leds[2] = LedC2;
        _leds[3] = LedC3;
        _leds[4] = LedA;
        _ports[1] = PortC1;
        _ports[2] = PortC2;
        _ports[3] = PortC3;
        _ports[4] = PortA;

        // 启动 LED 呼吸动画
        StartLedBreathing();
        UpdateActiveVisuals(ActivePorts);
    }

    private void StartLedBreathing()
    {
        _pulseAnim = new DoubleAnimation(0.5, 1.0, TimeSpan.FromMilliseconds(1000))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            Easing = new CubicEase { EasingMode = EasingMode.EaseInOut },
        };
    }

    private static void OnActivePortsChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is ChargerVisualControl c && c.IsLoaded)
            c.UpdateActiveVisuals((HashSet<int>)e.NewValue);
    }

    private void UpdateActiveVisuals(HashSet<int> active)
    {
        foreach (var kv in _leds)
        {
            var led = kv.Value;
            if (active.Contains(kv.Key))
            {
                // 活跃 LED — 翡翠绿 + 呼吸
                led.Fill = (Brush)FindResource("AccentGreen");
                led.BeginAnimation(OpacityProperty, _pulseAnim);
            }
            else
            {
                // 非活跃 — 微弱常亮
                led.Fill = new SolidColorBrush(Color.FromArgb(128, 55, 65, 81));
                led.BeginAnimation(OpacityProperty, null);
                led.Opacity = 0.4;
            }
        }

        // 中心能量点
        var centerActive = active.Count > 0;
        CenterEnergy.Fill = centerActive
            ? (Brush)FindResource("AccentBlue")
            : new SolidColorBrush(Color.FromArgb(80, 255, 255, 255));
        if (centerActive)
        {
            var anim = new DoubleAnimation(0.5, 0.9, TimeSpan.FromMilliseconds(1500))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                Easing = new CubicEase { EasingMode = EasingMode.EaseInOut },
            };
            CenterEnergy.BeginAnimation(OpacityProperty, anim);
        }
        else
        {
            CenterEnergy.BeginAnimation(OpacityProperty, null);
            CenterEnergy.Opacity = 0.15;
        }
    }
}
