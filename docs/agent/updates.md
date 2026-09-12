# 应用更新与发布

正式元数据地址为 `https://saymiao.github.io/xdial-updates/stable.json`，发布仓库为
`saymiao/xdial-updates`。应用归档来自 `kafeifei/XDial` 的 GitHub Releases。
客户端不请求 GitHub Releases API，不解析发布页面，也不携带 GitHub 凭据。
安装与通道合同见 [ARCHITECTURE.md](../../ARCHITECTURE.md)。

## 清单合同

canonical 地址不接受重定向。一份不超过 512 KiB 的 JSON 提供：

- 顶层：`schemaVersion: 1`、递增整数 `revision`、`channel: "stable"`、ISO 8601 UTC
  `generatedAt`，以及 `release`。
- `release: null` 表示暂无可用发布；否则包含 canonical `tag` 与 `version`、`build`、
  `minimumSystemVersion`、`publishedAt`、非空 Markdown `releaseNotes`、`archiveURL`、
  `archiveSize`、小写 64 位 `archiveSHA256`。
- 正式归档 URL 为
  `https://github.com/kafeifei/XDial/releases/download/<tag>/XDial-<tag>.zip`。
  归档上限 512 MiB，重定向仅限 GitHub 资产下载边界。

HTTP ETag/304 验证持久缓存；成功检查时间与清单的 `generatedAt` 分离。客户端拒绝旧
revision 或相同 revision 的不同字节，429 按 `Retry-After` 退避。下载和安装分别重新
确认候选身份，撤回或无法确认会阻止操作；归档另有大小、SHA-256、组件版本、签名与身份
校验。用户点击安装前，更新流程不改变连接。

## 稳定版发布机制

稳定版源码先合入并推送 `main`，再从主线提交创建正式 tag。tag workflow 与普通
`make release` 获取 `origin/main`，要求 tag 指向当前干净工作树的 HEAD，且位于远端
主线的 first-parent 历史。机制入口为 [Makefile](../../Makefile)、
[release.yml](../../.github/workflows/release.yml) 与
[release-contract.sh](../../scripts/release-contract.sh)。

`make release RELEASE_TAG=vX.Y.Z RELEASE_BUILD_NUMBER=<递增整数>` 使用正式身份、
provisioning profiles 与 Developer ID 签名，经公证、staple 和归档校验生成
`build/release/XDial-<tag>.zip` 及 SHA-256。公证使用 `NOTARY_KEYCHAIN_PROFILE`，或
`NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER`。`make release-app` 只生成待公证 App；
tag workflow 将完整归档上传为 draft Release。

`make publish RELEASE_TAG=vX.Y.Z` 调用 [publish-release.py](../../scripts/publish-release.py)。
它使用签名 Mac 上的操作员 `gh` 登录，重新获取源码仓库的 main/tag 并校验主线归属，
下载、校验真实附件，再公开 draft、派发更新仓库的 `publish.yml`，等待 Pages 部署并
读取 canonical 清单核对版本、build、摘要和说明。

Pages 发布器串行生成清单、历史与审计记录，拒绝旧版本覆盖、同 tag 内容改写和撤回版本
重发。附件公开与 Pages 生效是两个阶段；Pages 失败时原站点保留，同一发布命令可重试。
`publish.yml` 的 `operation=withdraw` 与 `release_tag` 撤回指定版本，使清单变为
`release: null`，保留历史和资产，不降级已安装 App。

## 正式身份双包验收

[build-update-acceptance.py](../../scripts/build-update-acceptance.py) 从同一个干净源码提交
构建 A/B，仅改变版本号与递增 build，要求新的输出目录：

```sh
python3 scripts/build-update-acceptance.py \
  --id pages-YYYYMMDD --lower-version 0.8.1 --higher-version 0.8.2 \
  --output /absolute/path/to/new-acceptance-run --notary-profile xdial-notary
```

脚本调用正式 `make release`，保存两份公证包和含 `sourceCommit` 的 `BUILD-INFO.json`，
不安装、启动或上传。`RELEASE_UPDATE_ACCEPTANCE_ID` 使本地验收构建跳过稳定版 tag/main
门禁；稳定版发布脚本仍拒绝验收包。

两包签名 Info.plist 的 `XDialUpdateAcceptanceID` 相同，清单地址固定为
`https://saymiao.github.io/xdial-updates/acceptance/<ID>/stable.json`，资产使用
`saymiao/xdial-updates` 的 prerelease。当前与传入 App 的 acceptance ID 必须相同。
这些包使用正式身份，安装会替换正式 App，重启可能中断当前连接。

同源码 A→B 覆盖该实现的更新机制，不证明旧正式客户端的升级兼容，也不证明修改前后
工作流一致。包签名校验不包含实际 UI、helper、扩展交接、连接恢复或流量结果。
旧客户端仍执行旧更新逻辑，进入新逻辑依赖手动安装或旧通道成功更新。
