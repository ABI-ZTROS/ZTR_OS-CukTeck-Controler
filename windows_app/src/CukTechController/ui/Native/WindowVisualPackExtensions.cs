// ═══════════════════════════════════════════════════════════════════════
// 🧩 WindowVisualPackExtensions — 给任意 Window 一键套上 ColorOS VisualPack
//   用法: window.AttachColorOSVisualPack()
//   内部会在 SourceInitialized 事件中调 DWM API
// ═══════════════════════════════════════════════════════════════════════

using System.Windows;
using System.Windows.Interop;

namespace CukTechController.UI.Native;

public static class WindowVisualPackExtensions
{
    /// <summary>
    /// 给 Window 附加 ColorOS VisualPack（Mica + 深色标题栏 + 小圆角）
    /// 在 SourceInitialized 自动调 DWM，无需手动管理时机
    /// </summary>
    public static void AttachColorOSVisualPack(this Window window)
    {
        window.SourceInitialized += (s, _) =>
        {
            try
            {
                var hWnd = new WindowInteropHelper(window).EnsureHandle();
                var app = Application.Current as App;
                app?.ApplyColorOSToWindow(hWnd);
            }
            catch
            {
                // VisualPack 是增强效果，失败不影响功能
            }
        };
    }
}
