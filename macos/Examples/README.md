# 企业 RuleSet 预设示例

`RuleSetPresets.example.json` 只演示公开 schema，并仅使用保留的 HTTPS 示例域名，不应
写入凭据、私有域名或真实规则地址。该预设目录不声明普通 RuleSet 的本地文件输入能力；
订阅 GEOIP 规则的本地 `file://` 模板在各平台的订阅编辑器中另行配置。

实际构建配置应保存在仓库外或企业私有仓库中，并在构建时通过
`XDIAL_RULE_SET_PRESETS_FILE=/absolute/path/RuleSetPresets.json` 注入。未设置该变量时，
构建脚本只尝试读取被忽略的 `macos/PrivateConfig/RuleSetPresets.json`；两处都不存在时，
应用使用内建的空白预设。
