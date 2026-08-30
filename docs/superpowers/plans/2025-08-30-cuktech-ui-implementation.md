# 酷态科 UI 重设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** 实现 ColorOS 15 动画风格的中心辐射型主页面 + 2D SVG 充电头 + 总功率环 + 液态玻璃 + 端口快捷按钮 + Bottom Sheet

**Architecture:** CustomPainter 绘制充电头，AnimationController 驱动 LED 呼吸和功率环过渡；HomePage 重写为 Stack + Positioned 辐射布局；所有动画使用 ColorOS Spring 参数。

**Tech Stack:** Flutter 3.3+ · Dart · CustomPainter · AnimationController · GestureDetector

---

### Task 1: ColorOS 动画参数常量

**Files:** Create `android_app/lib/ui/theme/coloros_animations.dart`

- [ ] 写入所有常量（见 spec §1.2）
- [ ] Modify `android_app/lib/ui/theme/app_theme.dart` 引入新常量
- [ ] Commit

### Task 2: GlassContainer 液态玻璃组件

**Files:** Create `android_app/lib/ui/widgets/glass_container.dart`

- [ ] 实现带 BackdropFilter + 自动降级的通用容器
- [ ] isGlassEnabled 开关从 Settings 读取

### Task 3: CuktechChargerPainter + ChargerVisualWidget

**Files:** Create `android_app/lib/ui/widgets/charger_visual/` 下 4 个文件

- [ ] cuktech_charger_painter.dart — 纯 CustomPainter，画外壳/4口/LED/LOGO
- [ ] charger_visual_widget.dart — StatefulWidget，管理 AnimationController
- [ ] charger_led_layer.dart — LED 呼吸动画（2Hz 正弦）
- [ ] energy_flow_layer.dart — 状态变化触发的能量流线条

### Task 4: PowerRing 总功率环

**Files:** Create `android_app/lib/ui/widgets/power_ring.dart`

- [ ] CustomPainter 画环，颜色随功率映射（绿→蓝→橙→红）
- [ ] ColorOS Spring 过渡

### Task 5: PortRadialButton 辐射端口按钮

**Files:** Create `android_app/lib/ui/widgets/port_radial_button.dart`

- [ ] 4 个按钮环形分布（角度 -135°/-45°/45°/135°）
- [ ] 单击开/关端口（Spring 弹性缩放）
- [ ] 长按弹出 Bottom Sheet
- [ ] 双击进入详情页

### Task 6: 重写 HomePage

**Files:** Modify `android_app/lib/ui/pages/home_page.dart`

- [ ] Stack + Positioned 中心辐射布局
- [ ] 并行动画入场（充电头 + 环 + 4 按钮 stagger）
- [ ] 连接状态 → 动画过渡

### Task 7: PortControlSheet Bottom Sheet

**Files:** Create `android_app/lib/ui/widgets/port_control_sheet.dart`

- [ ] 协议切换多选
- [ ] 倒计时关闭选择
- [ ] 端口开关 SegmentedControl
- [ ] ColorOS Spring 弹出/关闭

### Task 8: SettingsPage（完整设置）

**Files:** Create `android_app/lib/ui/pages/settings_page.dart`

- [ ] 外观分组：主题/液态玻璃/动画等级
- [ ] 连接分组：自动重连/超时
- [ ] 数据分组：导入/导出凭证

### Task 9: Settings 数据模型 + 持久化

**Files:** Modify `android_app/lib/protocol/settings.dart`

- [ ] 添加 Settings 类：isGlassEnabled / autoReconnect / reconnectInterval / animationLevel
- [ ] SharedPreferences 持久化

### Task 10: 代码审查 + CI 通过

- [ ] 单文件 ≤ 300 行检查
- [ ] 全项目 `dart analyze` 无 error
- [ ] CI Android Build ✅ + Windows Build ✅
- [ ] 移除 port_card.dart（被 port_radial_button 替代）
- [ ] git log 整理 + 最终 commit

