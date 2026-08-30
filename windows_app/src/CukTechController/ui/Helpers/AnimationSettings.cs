// ═══════════════════════════════════════════════════════════════════════
// 🎬 AnimationSettings — ColorOS 缓动曲线定义
//   标准 Material Design 3 缓动（FastOutSlowIn / Emphasized）
// ═══════════════════════════════════════════════════════════════════════

using System.Windows.Media.Animation;

namespace CukTechController.UI.Helpers;

/// <summary>
/// ColorOS 风格缓动曲线配置
/// 基于 Material Design 3 Motion 规范
/// </summary>
public static class AnimationSettings
{
    // CubicEase = Material Standard (FastOutSlowIn)
    private static readonly CubicEase StandardEase = new() { EasingMode = EasingMode.EaseOut };

    // QuarticEase = Emphasized (更有张力)
    private static readonly QuarticEase EmphasizedEase = new() { EasingMode = EasingMode.EaseOut };
    private static readonly QuarticEase EmphasizedEaseIn = new() { EasingMode = EasingMode.EaseIn };

    static AnimationSettings()
    {
        StandardEase.Freeze();
        EmphasizedEase.Freeze();
        EmphasizedEaseIn.Freeze();
    }

    /// <summary>Standard = FastOutSlowIn (ColorOS 默认入场曲线)</summary>
    public static IEasingFunction Standard => StandardEase;

    /// <summary>Emphasized = 更有弹力的退场/强调效果</summary>
    public static IEasingFunction Emphasized => EmphasizedEase;

    /// <summary>EmphasizedIn = 强调进入（用于退出动画的反向）</summary>
    public static IEasingFunction EmphasizedIn => EmphasizedEaseIn;

    /// <summary>总开关（可在设置页关闭动画）</summary>
    public static bool AnimationsEnabled { get; set; } = true;
}
