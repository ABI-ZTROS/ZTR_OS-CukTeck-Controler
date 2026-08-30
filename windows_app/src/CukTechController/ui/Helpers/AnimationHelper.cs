// ═══════════════════════════════════════════════════════════════════════
// 🎬 AnimationHelper — ColorOS 风格入场动画工具
//   提供: 页面入场 / 元素错落入场 / CrossFade
//   所有动画使用 AnimationSettings.Standard (FastOutSlowIn)
//   来源: MSMC AnimationHelper（精简移植）
// ═══════════════════════════════════════════════════════════════════════

using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace CukTechController.UI.Helpers;

public static class AnimationHelper
{
    // ──────────────────────────────────────────────────────────────────
    // 📄 页面入场
    // ──────────────────────────────────────────────────────────────────

    /// <summary>
    /// 页面淡入 + 从下方滑入（ColorOS 标准入场）
    /// </summary>
    /// <param name="slideDistance">滑动距离(px)，默认 20</param>
    public static void PlayPageEntrance(
        FrameworkElement page,
        int durationMs = 350,
        double slideDistance = 20)
    {
        page.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            FadeAndSlideIn(page, durationMs, slideDistance);
        });
    }

    // ──────────────────────────────────────────────────────────────────
    // 🎯 单元素动画
    // ──────────────────────────────────────────────────────────────────

    /// <summary>淡入 + 从下方滑入</summary>
    public static void FadeAndSlideIn(UIElement element, int durationMs, double slideDistance = 20)
    {
        if (!AnimationSettings.AnimationsEnabled || durationMs <= 0)
        {
            element.Opacity = 1;
            if (element.RenderTransform is TranslateTransform t) t.Y = 0;
            return;
        }

        element.Opacity = 0;
        var translate = new TranslateTransform(0, slideDistance);
        element.RenderTransform = translate;

        var duration = TimeSpan.FromMilliseconds(durationMs);

        var opacityAnim = new DoubleAnimation(1, duration)
        {
            EasingFunction = AnimationSettings.Standard
        };
        var yAnim = new DoubleAnimation(0, duration)
        {
            EasingFunction = AnimationSettings.Standard
        };

        // 动画结束后清理引用，释放资源
        yAnim.Completed += (_, _) =>
        {
            translate.Y = 0;
            translate.BeginAnimation(TranslateTransform.YProperty, null);
        };
        opacityAnim.Completed += (_, _) =>
        {
            element.Opacity = 1;
            element.BeginAnimation(UIElement.OpacityProperty, null);
        };

        element.BeginAnimation(UIElement.OpacityProperty, opacityAnim, HandoffBehavior.SnapshotAndReplace);
        translate.BeginAnimation(TranslateTransform.YProperty, yAnim, HandoffBehavior.SnapshotAndReplace);
    }

    /// <summary>淡入 + 从左侧滑入</summary>
    public static void FadeAndSlideInFromLeft(UIElement element, int durationMs, double slideDistance = 20)
    {
        if (!AnimationSettings.AnimationsEnabled || durationMs <= 0)
        {
            element.Opacity = 1;
            if (element.RenderTransform is TranslateTransform t) t.X = 0;
            return;
        }

        element.Opacity = 0;
        var translate = new TranslateTransform(slideDistance, 0);
        element.RenderTransform = translate;

        var duration = TimeSpan.FromMilliseconds(durationMs);

        var opacityAnim = new DoubleAnimation(1, duration)
        {
            EasingFunction = AnimationSettings.Standard
        };
        var xAnim = new DoubleAnimation(0, duration)
        {
            EasingFunction = AnimationSettings.Standard
        };

        xAnim.Completed += (_, _) =>
        {
            translate.X = 0;
            translate.BeginAnimation(TranslateTransform.XProperty, null);
        };
        opacityAnim.Completed += (_, _) =>
        {
            element.Opacity = 1;
            element.BeginAnimation(UIElement.OpacityProperty, null);
        };

        element.BeginAnimation(UIElement.OpacityProperty, opacityAnim, HandoffBehavior.SnapshotAndReplace);
        translate.BeginAnimation(TranslateTransform.XProperty, xAnim, HandoffBehavior.SnapshotAndReplace);
    }

    /// <summary>纯淡入</summary>
    public static void FadeIn(UIElement element, int durationMs)
    {
        if (!AnimationSettings.AnimationsEnabled || durationMs <= 0)
        {
            element.Opacity = 1;
            return;
        }

        element.Opacity = 0;
        var anim = new DoubleAnimation(1, TimeSpan.FromMilliseconds(durationMs))
        {
            EasingFunction = AnimationSettings.Standard
        };
        anim.Completed += (_, _) =>
        {
            element.Opacity = 1;
            element.BeginAnimation(UIElement.OpacityProperty, null);
        };
        element.BeginAnimation(UIElement.OpacityProperty, anim, HandoffBehavior.SnapshotAndReplace);
    }

    /// <summary>淡入 + 滑入（带延迟，用于列表错落入场）</summary>
    public static void FadeAndSlideInWithDelay(
        UIElement element, int durationMs, int delayMs, double slideDistance = 16)
    {
        if (!AnimationSettings.AnimationsEnabled || (durationMs <= 0 && delayMs <= 0))
        {
            element.Opacity = 1;
            if (element.RenderTransform is TranslateTransform t) t.Y = 0;
            return;
        }

        element.Opacity = 0;
        var translate = new TranslateTransform(0, slideDistance);
        element.RenderTransform = translate;

        var duration = TimeSpan.FromMilliseconds(durationMs);
        var beginTime = TimeSpan.FromMilliseconds(delayMs);

        var opacityAnim = new DoubleAnimation(1, duration)
        {
            BeginTime = beginTime,
            EasingFunction = AnimationSettings.Standard
        };
        var yAnim = new DoubleAnimation(0, duration)
        {
            BeginTime = beginTime,
            EasingFunction = AnimationSettings.Standard
        };

        yAnim.Completed += (_, _) =>
        {
            translate.Y = 0;
            translate.BeginAnimation(TranslateTransform.YProperty, null);
        };
        opacityAnim.Completed += (_, _) =>
        {
            element.Opacity = 1;
            element.BeginAnimation(UIElement.OpacityProperty, null);
        };

        element.BeginAnimation(UIElement.OpacityProperty, opacityAnim, HandoffBehavior.SnapshotAndReplace);
        translate.BeginAnimation(TranslateTransform.YProperty, yAnim, HandoffBehavior.SnapshotAndReplace);
    }

    /// <summary>CrossFade 交叉淡入淡出（前半淡出旧元素，后半淡入新元素）</summary>
    public static void CrossFade(UIElement? oldElement, UIElement? newElement, int durationMs)
    {
        if (!AnimationSettings.AnimationsEnabled || durationMs <= 0)
        {
            if (oldElement != null) oldElement.Opacity = 0;
            if (newElement != null) newElement.Opacity = 1;
            return;
        }

        var halfMs = durationMs / 2;

        if (oldElement != null)
        {
            var fadeOut = new DoubleAnimation(0, TimeSpan.FromMilliseconds(halfMs))
            {
                EasingFunction = AnimationSettings.Standard,
                FillBehavior = FillBehavior.Stop
            };
            fadeOut.Completed += (_, _) => oldElement.Opacity = 0;
            oldElement.BeginAnimation(UIElement.OpacityProperty, fadeOut, HandoffBehavior.SnapshotAndReplace);
        }

        if (newElement != null)
        {
            newElement.Opacity = 0;
            var fadeIn = new DoubleAnimation(1, TimeSpan.FromMilliseconds(halfMs))
            {
                BeginTime = TimeSpan.FromMilliseconds(halfMs),
                EasingFunction = AnimationSettings.Standard,
                FillBehavior = FillBehavior.Stop
            };
            fadeIn.Completed += (_, _) => newElement.Opacity = 1;
            newElement.BeginAnimation(UIElement.OpacityProperty, fadeIn, HandoffBehavior.SnapshotAndReplace);
        }
    }
}
