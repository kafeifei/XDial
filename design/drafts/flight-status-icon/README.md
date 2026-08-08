# Flight status icon draft

未启用的货运机状态图标草稿，保留于 2026-08-01。

- 起飞：连接中 / 重连中，机头上仰并循环点亮三颗航线点。
- 平飞：已连接，机身与最近航线点常亮。
- 降落：断开中 / 已断开，机头下俯且整体降至 40% 亮度。
- 坠机：连接错误，机头陡降并在前方显示 `×`。

`FlightStatusIcon.swift` 是完整 Core Graphics 矢量实现，
`FlightStatusIconTests.swift` 保存状态映射测试，`flight-status-preview.png` 是四态预览。
