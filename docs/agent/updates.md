# 应用更新与发布

正式元数据地址固定为 `https://saymiao.github.io/xdial-updates/stable.json`，发布仓库为
`saymiao/xdial-updates`。应用归档仍来自 `kafeifei/XDial` 的 GitHub Releases。
客户端不请求 GitHub Releases API，不解析发布页面，也不携带 GitHub 凭据。

## 清单合同

一份不超过 512 KiB 的 JSON 同时提供以下字段，禁止重定向 canonical 地址：

- 顶层：`schemaVersion: 1`、递增整数 `revision`、`channel: "stable"`、ISO 8601 UTC
  `generatedAt`，以及 `release`。
- `release` 为 `null` 表示暂无可用发布；否则必须包含 canonical `tag` 与 `version`、
  `build`、`minimumSystemVersion`、`publishedAt`、非空 Markdown `releaseNotes`、
  `archiveURL`、`archiveSize`、小写 64 位 `archiveSHA256`。
- 正式归档 URL 必须精确匹配
  `https://github.com/kafeifei/XDial/releases/download/<tag>/XDial-<tag>.zip`。
  归档上限 512 MiB；归档重定向只允许现有 GitHub 资产下载边界。

HTTP ETag/304 可以验证持久缓存；成功 HTTP 验证时间与静态 `generatedAt` 分离。
旧 revision 或相同 revision 的不同字节均拒绝。429 根据 `Retry-After` 退避，失败保留
最近成功检查时间；缓存不能单独授权下载或安装。每次下载和安装前重新确认候选身份，
撤回或无法确认则阻止操作。下载核对完整大小与 SHA-256，再验证实际组件版本、build、
Apple 签名和通道身份。用户点击安装前不改变连接。

## 正式发布

1. 完成本次改动的源码验证，合入并推送 `main`，核对本地和远端主线提交；再从 `main`
   上确认的提交创建并推送正式 tag。不得先在功能或验收分支打正式 tag，再补合主线。
   tag workflow 与普通 `make release` 都会重新获取 `origin/main`，要求 tag 指向当前干净
   工作树的 HEAD，并拒绝不属于远端主线 first-parent 历史的 tag 提交。
2. 在该 tag 对应提交上运行 `make release`，或由 tag workflow 生成并保留 draft Release。
   使用正式身份、provisioning profile、签名、公证、staple 与完整归档验证门禁。
3. 先完成该版本要求的验收。明确获得发布授权后，在有操作员 `gh` 登录的签名 Mac 上运行
   `make publish RELEASE_TAG=vX.Y.Z`。脚本先把 `kafeifei/XDial` 的实际 `main` 与 tag 获取到
   临时 bare 仓库，核对 tag 解引用后的提交位于该主线 first-parent 历史，再重新下载并
   验证真实附件；上述任一门禁失败都发生在公开 draft 或派发 Pages workflow 之前。
4. 同一脚本显式派发更新仓库的 `publish.yml`，等待部署并检查 canonical 清单的版本、
   build、摘要及说明。跨仓库派发使用操作员现有登录，不在仓库或客户端保存 PAT。
5. 更新仓库 workflow 串行运行，从公开 Release 与真实归档生成清单、历史和审计记录，
   拒绝旧版本覆盖、同 tag 内容改写与撤回版本重发；先提交完整站点，再部署并 GET 核验。

附件已公开但 Pages 失败时，任务尚未完成；保留现有站点，修复原因后重跑同一发布命令。
不得更换已发布 tag 的归档。撤回通过更新仓库 `publish.yml` 的 `operation=withdraw` 与
对应 `release_tag` 显式执行；清单变为 `release: null`，保留历史与说明，不自动删除资产，
不降级已安装应用。撤回也属于需要明确授权的外部写入。

## 正式身份双包验收

长期本地 Debug 与正式通道独立，不用 Debug 冒充更新验收。提交源码后运行：

```sh
python3 scripts/build-update-acceptance.py \
  --id pages-YYYYMMDD --lower-version 0.8.1 --higher-version 0.8.2 \
  --output /absolute/path/to/new-acceptance-run --notary-profile xdial-notary
```

脚本仅调用正式 `make release` 构建、公证并保存 A/B 两包及 `BUILD-INFO.json`，不安装、
启动或上传。显式 `RELEASE_UPDATE_ACCEPTANCE_ID` 只允许这类没有正式 tag 的本地验收构建
跳过稳定版 tag/main 门禁，`make publish` 与发布脚本仍拒绝验收包。两包签名 Info.plist 的
`XDialUpdateAcceptanceID` 相同，对应固定地址
`https://saymiao.github.io/xdial-updates/acceptance/<ID>/stable.json`，且仅允许从
`saymiao/xdial-updates` 下载同名归档。当前与传入 App 的 acceptance ID 必须完全相同。
测试资产使用该仓库明确标注的 prerelease；正式发布脚本及发布器拒绝非空 acceptance ID。

获得本次运行态授权后，才安装并运行 A，检查版本与完整说明、下载 B、完成校验，点击安装
并重启，验证实际 B、helper、System Extension、连接恢复和真实流量。A/B 使用正式身份，
因此会替换正式 App，重启时可能短暂断开网络；不能在用户正在联网时擅自执行。失败、撤回、
ETag/304 和摘要不符需分别验证；代码测试、包校验与真实 UI/网络验收分开报告。

旧客户端仍使用旧更新逻辑；需要先手动安装新客户端，或经旧通道成功更新一次。
