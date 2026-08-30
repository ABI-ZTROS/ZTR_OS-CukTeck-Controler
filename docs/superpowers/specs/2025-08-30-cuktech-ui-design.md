# 酷态科 UI 重设计规格

> **版本**：v1.0 · **日期**：2025-08-30 · **状态**：待审核

## 0. 设计决策速查表

| # | 决策项 | 选择 | 理由 |
|---|--------|------|------|
| D1 | 充电头主视觉 | 2D SVG 手绘（CustomPainter） | 纯代码无资源依赖，动画完全可控 |
| D2 | 主页结构 | 中心辐射型 | 4 口充电器天然适合辐射布局，科技感强 |
| D3 | 动画风格 | 沉稳派（常驻但克制） | 科技感但不花哨，用户长时间看不累 |
| D4 | 设计语言 | ColorOS 15 动画系统 + 深色主题 | OPPO 自研"极光引擎"，柔性回弹 + 物理弹簧 |
| D5 | 功能入口 | 中心辐射 + 4 端口快捷按钮 | 功能多但一步可达 |
| D6 | 端口交互 | 单击开关 + 长按弹出 Bottom Sheet | 高频操作一步到位，低频操作不干扰 |
| D7 | 液态玻璃 | 设置可开关 | 全平台兼容考虑，手搓 BackdropFilter |

---

## 1. 视觉系统

### 1.1 深色主题调色板

```
基础色板（Cool Blue Dark）
├── 背景 #0A0F1E          深夜蓝（主背景）
├── 卡片 #111827          深邃石墨
├── 层级 #1F2937          悬浮层
├── 分割线 #374151         60% 灰度
├── 主文字 #F9FAFB         近白
├── 次文字 #9CA3AF         40% 灰度
└── 禁用 #6B7280          30% 灰度

功能色板
├── 电光蓝 #3B82F6        主色（品牌 + 连接态）
│   └── 渐变 → #1D4ED8     激活态
├── 翡翠绿 #10B981        充电中
│   └── 渐变 → #059669     活跃态
├── 琥珀橙 #F59E0B        协议提示（UFCS/PD）
│   └── 渐变 → #D97706     高功率
├── 霓虹紫 #8B5CF6        C 口（3C 统一用蓝色系区分 A 口）
├── 警示红 #EF4444        错误/过热
└── 能量白 #F3F4F6        功率环高亮
```

### 1.2 ColorOS 15 动画参数（精确）

从 OPPO 极光引擎公开参数 + Flutter Compose 对照换算：

```dart
// === 核心动画曲线 ===

// ColorOS FastOutSlowIn（标准过渡）
// 对应 Material 3 Motion Design "standard"
static const Curve colorosStandard = Cubic(0.4, 0.0, 0.2, 1.0);

// ColorOS LinearOutSlowIn（入场）
static const Curve colorosEnter = Cubic(0.0, 0.0, 0.2, 1.0);

// ColorOS FastOutLinearIn（退场）
static const Curve colorosExit = Cubic(0.4, 0.0, 1.0, 1.0);

// === 物理弹簧参数（ColorOS 柔性回弹）===
// Aurora Engine 的 spring：轻度弹性，不夸张
// Flutter SpringSimulation 近似值：
static const double springDampingRatio = 0.5;   // MediumBouncy 等级
static const double springStiffness = 200.0;     // StiffnessLow 等级
static const Duration springDuration = Duration(milliseconds: 400);

// === 时长规范 ===
// ColorOS 15 设计语言标准时长
static const Duration dInstant = Duration(milliseconds: 100);   // 状态变化
static const Duration dFast = Duration(milliseconds: 200);      // 微交互
static const Duration dNormal = Duration(milliseconds: 300);    // 常规过渡
static const Duration dSlow = Duration(milliseconds: 500);      // 页面切换
static const Duration dEmphasis = Duration(milliseconds: 700);   // 强调动画
```

### 1.3 液态玻璃效果

```
BackdropFilter 方案（手搓轮子，跨平台通用）：
├── 实现：ImageFilter.blur(sigmaX: 15, sigmaY: 15)
│         + 半透明白色叠加 Colors.white.withOpacity(0.08)
│         + 1px 顶部高光 Colors.white.withOpacity(0.15)
├── 前提：平台支持 BackdropFilter
│         Android API 30+ / iOS 9+ / Web 有限支持
├── 设置开关：isGlassEnabled 默认 true，关闭时降级为
│         Colors.black.withOpacity(0.7) + 圆角
├── 性能：blur sigma ≤ 20，避免 GPU 过载
└── 降级：自动检测设备能力，低端机默认关闭
```

---

## 2. 充电头 SVG 手绘（CustomPainter）

### 2.1 酷态科 Ad1204 外形还原

```
CustomPainter: CuktechChargerPainter
坐标系：300x300 Canvas，中心 (150,150)

外形：
┌─────────────────────────────────┐
│  ┌───────────────────────────┐  │ ← 圆角矩形外壳
│  │   ●  ●  ●          ●     │  │ ← 3x USB-C + 1x USB-A LED
│  │   C1  C2  C3          A   │  │
│  │                           │  │
│  │    [品牌 LOGO 区域]       │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘

几何参数：
├── 外壳圆角矩形：Rect(30, 60, 270, 240), radius=28
├── C 口（圆形）：中心 (85,120),(150,120),(215,120), r=14
│   └── 内部小圆圈 + 三条 CC 触点线
├── A 口（矩形）：中心 (260,180), size=24x16
│   └── 内部舌片 + 双触点
├── LED 指示灯：中心 (85,85),(150,85),(215,85),(260,85), r=6
│   └── 充电时：圆形渐变光晕
└── 底部 Logo：TextPainter "CUKTECH" @ center(150, 200)
```

### 2.2 充电头动画层（常驻但克制）

```
Layer 1 — LED 呼吸（常驻，沉稳派）：
  └── 每个 USB-C 口上方的 LED，当对应端口 active=true 时
      执行 2Hz 正弦脉冲（opacity 0.6 → 1.0）
      非活跃时 opacity=0.2（微弱常亮）
      曲线：Curves.easeInOut · 时长 500ms

Layer 2 — 中心能量点（常驻）：
  └── 外壳正中心（150,150）的光点
      active 端口数 > 0 时：缓慢脉动 r=8→12，曲线 easeInOut 1500ms
      所有端口空闲时：静止 r=6

Layer 3 — 能量流线条（状态变化触发）：
  └── 当端口从 idle → active 时
      画一条从中心 (150,150) 到对应 LED 的光线
      光线从中心"生长"到端口，时长 400ms（ColorOS Spring）
      完成后淡出（200ms），只留 LED 常亮
      不常驻 — 沉稳派不持续跑能量线
```

### 2.3 CustomPainter 类结构

```dart
// lib/ui/widgets/charger_visual/
// ├── cuktech_charger_painter.dart    纯绘图逻辑（无状态）
// ├── charger_visual_widget.dart      StatefulWidget + AnimationController
// ├── charger_led_layer.dart          4 路 LED 动画组件
// └── energy_flow_layer.dart          能量流线条（状态变化动画）

class CuktechChargerPainter extends CustomPainter {
  final Set<int> activePorts;    // {1,2,3,4}
  final double ledPulse;          // 0.0 ~ 1.0 呼吸值
  final bool glassEnabled;        // 液态玻璃开关
}
```

---

## 3. 主页布局（中心辐射型）

### 3.1 结构总览

```
HomePage 布局（纵向 Scrollable）
┌─────────────────────────────────────┐
│ [Status Banner] 连接状态 / 设备信息   │ ← 顶部固定栏
├─────────────────────────────────────┤
│                                     │
│        ╭─────────────╮              │
│        │   总功率环   │              │ ← 第一屏核心
│        │   220.5 W   │              │
│        │  ╭───────╮  │              │
│        │  │充电头 │  │              │ ← CustomPainter
│        │  │ 动画  │  │              │
│        │  ╰───────╯  │              │
│        ╰─────────────╯              │
│       /    │    \    │              │
│    C1      C2    C3   A             │ ← 辐射快捷按钮
│  [42.3V] [18.1W] [idle] [30.5A]    │
│                                     │
├─────────────────────────────────────┤
│ [今日用电统计卡片]                    │ ← 第二屏（可滚）
│ [快速操作区：全部开/关]               │
│ [日志预览/高级入口]                   │
└─────────────────────────────────────┘
```

### 3.2 总功率环

```
RingProgress（中心充电头外围）
├── 环宽：12px
├── 半径：140px（充电头 150 + 35 余量）
├── 颜色映射（总功率 → 颜色渐变）：
│   0-60W:   翡翠绿 #10B981
│   60-120W: 电光蓝 #3B82F6
│   120-180W: 琥珀橙 #F59E0B
│   180W+:   警示红 #EF4444
├── 动画：ColorOS Spring，当功率变化时 400ms 弹性过渡
│         曲线：spring(dampingRatio: 0.5, stiffness: 200)
├── 中心文字：
│   ├── 大号："{totalPower.toStringAsFixed(1)} W"
│   └── 小号："总功率 · {activeCount}/4 口活跃"
└── 脉冲效果：功率稳定后环缓慢扩散（opacity 1→0）每 3s
    曲线：easeOut · 时长 1200ms
```

### 3.3 辐射快捷按钮（4 端口）

```
PortRadialButton（环形分布在充电头周围）

位置计算（以充电头中心 (150,150) 为原点，半径 200）：
  C1 (piid=1): angle = -135°   → (x,y) = (150+200cos(-135°), 150+200sin(-135°))
  C2 (piid=2): angle = -45°    → 右侧偏上
  C3 (piid=3): angle = 45°     → 右侧偏下
  A  (piid=4): angle = 135°    → 左侧偏下

每个按钮：
├── 尺寸：80x80 Card
├── 视觉：
│   ├── idle：深灰 #1F2937，LED 圆点 opacity=0.2
│   └── active：翡翠绿渐变 + LED 呼吸 + 外圈能量环
├── 内容：
│   ├── 顶部：端口名 (C1/C2/C3/A) + 协议标签 (PD3.1/UFCS/idle)
│   ├── 中部：大号功率 "{W.toStringAsFixed(1)}"
│   └── 底部：迷你 V/A 数值 "28.5V  3.2A"
├── 交互（ColorOS 风格）：
│   ├── 单击 → 开/关端口（Spring 400ms 弹性缩放）
│   ├── 长按 → 弹出 Bottom Sheet（协议切换 + 倒计时）
│   └── 双击 → 进入端口详情页（V/A/W 曲线历史）
├── 触觉（HapticFeedback）：
│   ├── 单击：lightImpact
│   └── 长按：mediumImpact
└── 动画过渡：
    ├── 按下：scale 1.0 → 0.95（100ms easeOut）
    ├── 松开：scale 0.95 → 1.0（400ms ColorOS Spring）
    └── 开关状态切换：ColorOS Standard 300ms
```

### 3.4 页面进入动画

```
HomePage 首次加载（ColorOS 极光引擎风格 — 并行动画）：

并行执行（非串行排队）：
├── 充电头：scale 0.3→1.0 + opacity 0→1（600ms Spring dampingRatio=0.4）
├── 功率环：stagger 100ms → sweep 0→full（500ms LinearOutSlowIn）
├── 4 个端口按钮：stagger 50ms 依次 fadeSlideUp
│   每个：translateY 20→0 + opacity 0→1（300ms ColorOS Enter）
└── StatusBanner：stagger 400ms → fadeSlideDown（300ms）

连接成功（从 disconnected → connected）：
├── 充电头外壳：ColorOS Spring 轻微放大（scale 1.0→1.02→1.0）
├── 中心能量点：闪烁（opacity 0→1→0，300ms easeOut）
└── 所有 LED：同时从 opacity 0.2 淡入到活跃值（300ms ColorOS Enter）
```

---

## 4. Bottom Sheet（端口长按弹出）

```
PortControlSheet（showModalBottomSheet）

结构：
┌─────────────────────────┐
│ 📍 C1 端口               │
│  PD 3.1 · 28.5V · 3.2A  │ ← 顶部概览
├─────────────────────────┤
│                         │
│ ▶ 当前协议开关（多选）    │ ← Checkbox 列表
│   ☑ PD 3.1              │
│   ☑ UFCS                │
│   ☐ QC 3+               │
│   ☑ PPS                 │
│                         │
│ ▶ 倒计时关闭             │ ← Row
│   [15m [30m [60] 分钟   │
│   [自定义输入]           │
│                         │
│ ▶ 端口开关 Toggle        │
│   [● 关闭]   [○ 开启]   │ ← 大号 SegmentedControl
│                         │
├─────────────────────────┤
│  [立即关闭]   [保存设置] │ ← 底部操作栏
└─────────────────────────┘

动画（ColorOS 风格）：
├── 弹出：SlideUp 从 80% 高度 → 全展开（400ms Spring dampingRatio=0.4）
├── 关闭：同 Spring 反向（不做简单 fadeOut）
└── 协议切换：Checkbox 勾选带 Spring 弹性缩放反馈
```

---

## 5. 设置页 & 液态玻璃开关

```
SettingsPage

分组：
├── 外观
│   ├── 🎨 主题：深色 / 跟随系统
│   ├── 💎 液态玻璃：开/关（带说明文字，默认开）
│   │   └── 说明："关闭可提升低端设备性能"
│   └── 🌈 动画等级：完整 / 精简
│       └── 精简 = 关闭常驻 LED 呼吸和中心能量点脉动
│
├── 连接
│   ├── ⚙️ 自动重连：开/关
│   ├── 🔄 重连间隔：10s / 30s / 60s
│   └── 📡 扫描超时：10s / 20s / 30s
│
├── 数据
│   ├── 📥 导出凭证 .cuk → 调用 SecureTokenStore.exportAndShare
│   ├── 📤 导入凭证 .cuk → Navigator 到 TokenImportPage
│   └── 🗑️ 清除本地数据（二次确认对话框）
│
└── 关于
    ├── 版本号
    ├── GitHub 仓库链接
    └── 开源许可

液态玻璃实现（isGlassEnabled=false 降级）：
  Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(...),  // 纯色渐变替代玻璃
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
    ),
    // 无 BackdropFilter → 零 GPU 开销
  )
```

---

## 6. 文件结构

```
lib/ui/
├── theme/
│   ├── app_theme.dart              现有 → 扩展 ColorScheme + AnimationSpec
│   └── coloros_animations.dart     新增 → ColorOS 动画参数常量
│
├── widgets/
│   ├── charger_visual/             新增目录
│   │   ├── cuktech_charger_painter.dart   CustomPainter 核心绘图
│   │   ├── charger_visual_widget.dart     StatefulWidget + AnimationController
│   │   ├── charger_led_layer.dart         LED 呼吸动画
│   │   └── energy_flow_layer.dart         能量流线条（状态变化）
│   │
│   ├── power_ring.dart             新增 → 总功率环（CustomPainter）
│   ├── port_radial_button.dart     新增 → 辐射端口快捷按钮
│   ├── glass_container.dart        新增 → 液态玻璃容器（自动降级）
│   │
│   ├── port_card.dart              现有 → 可删除（被 port_radial_button 替代）
│   ├── status_banner.dart          现有 → 优化动画
│   ├── scan_widgets.dart           现有 → 保留
│   └── manual_token_form.dart      现有 → 保留
│
└── pages/
    ├── home_page.dart              重写 → 中心辐射 + ColorOS 动画
    ├── port_control_page.dart      重写 → 精简为 Bottom Sheet 入口
    ├── settings_page.dart          新增 → 完整设置页
    ├── port_detail_page.dart       新增 → V/A/W 曲线历史
    ├── device_info_page.dart       现有 → 保留
    ├── log_page.dart               现有 → 保留
    ├── token_import_page.dart      现有 → 保留
    └── webview_login_page.dart     现有 → 保留
```

---

## 7. 验收标准

| AC | 描述 | 验证方式 |
|----|------|----------|
| UI-1 | 首页渲染酷态科 4 口充电头（2D SVG） | 目视检查外形 + LED 位置 |
| UI-2 | 4 端口环形分布在充电头周围 | 端口与中心成 45° 间隔 |
| UI-3 | 总功率环颜色随功率变化（绿→蓝→橙→红） | 人为模拟不同功率 |
| UI-4 | ColorOS 柔性回弹动画（不是线性/急变） | 观察开关端口/弹出 Sheet |
| UI-5 | 液态玻璃在设置中可开关 | 切换后视觉立即变化 |
| UI-6 | 深色主题 + 电光大功率色板 | 无亮色/白色突兀元素 |
| UI-7 | 单文件 ≤ 300 行 | `find . -name "*.dart" | xargs wc -l | sort -rn | head` |
| UI-8 | HomePage 首次加载动画 < 1s | 目视感觉流畅无卡顿 |
| UI-9 | 长按端口按钮弹出 Bottom Sheet | GestureDetector onLongPress |
| UI-10 | 全部功能入口 ≤ 2 步可达 | 设置/日志/导入导出 ≥ 1 次点击 |

---

## 8. 不在本次设计范围（YAGNI）

- 3D 充电头模型（Flutter 生态无成熟跨平台 3D）
- 物理 USB 动画（闪电跑马灯 — 太花哨，沉稳派不做）
- 自定义字体（用系统默认更稳）
- 桌面端适配（先 Android 再 Windows）
- 云端历史数据（目前只有本地 BLE 广播）
