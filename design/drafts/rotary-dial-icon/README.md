# Rotary dial icon draft

未启用的老式脉冲电话拨号盘方案，保留于 2026-08-01。

- 十个真实负形拨号孔、中心轮毂和右下方机械挡针。
- 灰度仅使用 40% / 70% / 100% 三档亮度。
- 空闲态整体 40%；拨号态顺时针转至挡针、停顿后回弹；已连接时挡针常亮。
- 菜单栏使用无底板模板图，App 图标使用 `#1F1E1E` 底板。

`RotaryDialIcon.swift` 是完整 Core Graphics 矢量实现，
`RotaryDialIconTests.swift` 保存状态、机械运动和亮度约束测试。

![App 图标预览](app-icon-preview.png)

![菜单栏预览](menu-bar-preview.png)
