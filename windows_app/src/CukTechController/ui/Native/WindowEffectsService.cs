// ═══════════════════════════════════════════════════════════════════════
// 🎨 WindowEffectsService — ColorOS VisualPack 窗口效果服务
//   基于 DWM / Win32 P/Invoke 实现 Mica 背景 + 深色标题栏 + 圆角
//   来源: MSMC WindowEffectsService（精简移植）
// ═══════════════════════════════════════════════════════════════════════

using System.Runtime.Versioning;
using CukTechController.UI.Native;

namespace CukTechController.UI.Native;

/// <summary>
/// ColorOS VisualPack 窗口效果服务
/// 一键应用: Mica背景 + 深色标题栏 + 小圆角
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowEffectsService
{
    // 记录哪些 hWnd 已经 ApplyColorOSVisualPack 过
    private readonly HashSet<IntPtr> _appliedHandles = new();
    private readonly object _lock = new();

    public bool IsCompositionEnabled
    {
        get
        {
            try
            {
                var hr = NativeMethods.DwmIsCompositionEnabled(out var enabled);
                return hr == 0 && enabled;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>Win11 22H2+ = build 22621</summary>
    public bool SupportsMica => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621);

    /// <summary>Win10 1809+ = build 17763</summary>
    public bool SupportsDarkTitleBar => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763);

    // ──────────────────────────────────────────────────────────────────

    public bool ApplySystemBackdrop(IntPtr hWnd, SystemBackdropType type)
    {
        if (hWnd == IntPtr.Zero || !SupportsMica || !IsCompositionEnabled) return false;
        try
        {
            int backdrop = (int)type;
            var hr = NativeMethods.DwmSetWindowAttribute(
                hWnd, DwmWindowAttribute.SYSTEMBACKDROP_TYPE,
                ref backdrop, sizeof(int));

            // Mica 还需要 HostBackdropBrush=1
            if (type != SystemBackdropType.None)
            {
                int enable = 1;
                NativeMethods.DwmSetWindowAttribute(
                    hWnd, DwmWindowAttribute.UseHostBackdropBrush,
                    ref enable, sizeof(int));
            }
            return hr == 0;
        }
        catch
        {
            return false;
        }
    }

    public bool ApplyDarkTitleBar(IntPtr hWnd, bool darkMode = true)
    {
        if (hWnd == IntPtr.Zero || !SupportsDarkTitleBar) return false;
        try
        {
            int value = darkMode ? 1 : 0;
            var hr = NativeMethods.DwmSetWindowAttribute(
                hWnd, DwmWindowAttribute.UseImmersiveDarkMode,
                ref value, sizeof(int));
            return hr == 0;
        }
        catch
        {
            return false;
        }
    }

    public bool ApplyCornerPreference(IntPtr hWnd, WindowCornerPreference corner)
    {
        if (hWnd == IntPtr.Zero || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) return false;
        try
        {
            int value = (int)corner;
            var hr = NativeMethods.DwmSetWindowAttribute(
                hWnd, DwmWindowAttribute.WINDOW_CORNER_PREFERENCE,
                ref value, sizeof(int));
            return hr == 0;
        }
        catch
        {
            return false;
        }
    }

    // ──────────────────────────────────────────────────────────────────

    /// <summary>
    /// 一键套上 ColorOS 美学：深色标题栏 + 小圆角 + Mica 背景
    /// </summary>
    public void ApplyColorOSVisualPack(IntPtr hWnd, bool darkTitleBar = true)
    {
        if (hWnd == IntPtr.Zero) return;

        ApplyDarkTitleBar(hWnd, darkTitleBar);
        ApplyCornerPreference(hWnd, WindowCornerPreference.RoundSmall);

        if (SupportsMica && IsCompositionEnabled)
            ApplySystemBackdrop(hWnd, SystemBackdropType.MainWindow);

        lock (_lock)
        {
            _appliedHandles.Add(hWnd);
        }
    }

    public bool IsApplied(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        lock (_lock) return _appliedHandles.Contains(hWnd);
    }
}
