// ═══════════════════════════════════════════════════════════════════════
// 🪟 Win32 Native — 精简 DWM P/Invoke
//   只包含 WindowEffectsService 需要的 DWM 合成 API
// ═══════════════════════════════════════════════════════════════════════
using System.Runtime.InteropServices;

namespace CukTechController.UI.Native;

/// <summary>
/// DwmWindowAttribute — DwmSetWindowAttribute 的属性编号
/// ref: https://learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
/// </summary>
public enum DwmWindowAttribute
{
    UseImmersiveDarkMode = 2,          // Win10 1809+ — 深色标题栏
    UseHostBackdropBrush = 9,          // Win11 22H2+ — Mica 启用必须
    WINDOW_CORNER_PREFERENCE = 33,     // Win11 22H2+ — 窗口圆角
    SYSTEMBACKDROP_TYPE = 38,          // Win11 22H2+ — Mica/Acrylic 类型
}

/// <summary>
/// DWM_SYSTEMBACKDROP_TYPE — Mica/Acrylic 背景类型
/// ref: https://learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type
/// </summary>
public enum SystemBackdropType
{
    Auto = 0,
    None = 1,
    MainWindow = 2,      // Mica（主窗口推荐）
    TransientWindow = 3, // MicaAlt（弹窗/Sidebar 更透明）
    TabbedWindow = 4     // Acrylic
}

/// <summary>
/// WINDOW_CORNER_PREFERENCE — Win11 窗口圆角偏好
/// </summary>
public enum WindowCornerPreference
{
    Default = 0,
    DoNotRound = 1,
    Round = 2,
    RoundSmall = 3   // ColorOS 统一小圆角
}

internal static class NativeMethods
{
    // ───── DWM 合成 ─────

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(
        [In] IntPtr hwnd,
        [In] DwmWindowAttribute dwAttribute,
        [In] ref int pvAttribute,
        [In] int cbAttribute);

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmIsCompositionEnabled(
        [MarshalAs(UnmanagedType.Bool)] out bool pfEnabled);

    // ───── user32 ─────

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowDisplayAffinity(
        [In] IntPtr hWnd,
        [In] uint dwAffinity);
}
