# 设置通用页的版本信息与更新入口

## 目标

在设置窗口「通用」页展示当前已安装版本，并提供一个打开更新窗口的入口。更新能力本身
（`AppUpdateChecker` + 更新窗口 + 菜单栏提示）在 `9eb0784` 已经完整存在，本主题只补入口，
不重做更新机制。

## 已拍板

- 通用页只展示**静态的已安装版本号**和一个「检查更新」按钮，按钮只负责打开更新窗口。
- 通用页**不得**显示候选版本、下载进度、更新说明或任何 update candidate 状态。理由：
  `DESIGN.md` §6.2 规定 update candidate 必须由菜单栏圆点、标题栏 `v<latest>` 胶囊、
  右键菜单和更新窗口消费同一份状态，设置页不进这个名单；已安装版本号是静态标识，
  不构成 §9 所说的重复状态。
- 版本号如实读取运行中包的 `CFBundleShortVersionString` 与 `CFBundleVersion`，读不到显示
  `?`，不美化成预期版本号。Debug 构建因此会显示 `v0.0.0 (build <timestamp>)`。

## 已完成

- `macos/Sources/XDial/SettingsView.swift`：`GeneralTab` 在「安装与卸载」之后新增版本卡片。
- `DESIGN.md` §5.1：新增两条约束，对应上面两项拍板。
- 验证：`make app` 编译通过无新警告；`make restart` 装机后经 Debug Server `/ax` 确认三个
  元素已渲染（静态文本「版本」、静态文本 `v0.0.0 (build 1788111026)`、按钮「检查更新」）。

## 待办

1. **本 worktree 落后 main 三个提交**，main 已在准备 v0.7.2：`417f5b6`、`5f6baaa`、`f32a90d`。
   本主题的改动尚未 rebase 到 main。
2. **本 worktree 的构建不含定位权限修复**。main 的 `5f6baaa` 补了 `NSLocationUsageDescription`
   与 `com.apple.security.personal-information.location` entitlement；缺这两项时 macOS 根本不弹
   权限框，`requestWhenInUseAuthorization()` 调用无效果。v0.7.1 及本 worktree 的构建仍有此问题。
3. **Debug 构建会被判定为可自动更新**。`ApplicationRelocator.permitsAutomaticUpdates` 只检查
   安装位置和 bundle identifier，不检查版本号；Debug 的 `0.0.0` 比任何正式 tag 都旧，装进
   `/Applications` 后菜单栏会持续显示「新版本可用」（本机 `/ax` 已实测到）。建议在该 gate 上
   追加「当前版本号必须能解析成正式发布版本」，可复用 `VersionUpdatePolicy.stableVersion`。
   属于净增加固，与本主题无关，应单独提交。
4. **`make restart` 验收连续两次失败**在 `connection recovered only after a failed attempt`，
   `MAKE_EXIT=2`。App 本身安装并启动成功，但门禁未通过，根因未查。
5. **`claude/version-display-update-cleanup-ff536c` 分支与本主题同名同题**，目前停在 `f32a90d`
   无独立提交。动手前需确认归属，避免两边重复实现。
