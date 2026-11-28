# 应用更新与发布

正式元数据地址为 `https://saymiao.github.io/xdial-updates/stable.json`，beta 通道为同目录的
`beta.json`；发布仓库为 `saymiao/xdial-updates`。应用归档来自 `kafeifei/XDial` 的 GitHub Releases。
客户端不请求 GitHub Releases API，不解析发布页面，也不携带 GitHub 凭据。
安装与通道合同见 [ARCHITECTURE.md](../../ARCHITECTURE.md)。

## 清单合同

canonical 地址不接受重定向。一份不超过 512 KiB 的 JSON 提供：

- 顶层：`schemaVersion: 1`、递增整数 `revision`、`channel`（stable.json 为 `"stable"`，
  beta.json 为 `"beta"`，必须与所读地址一致）、ISO 8601 UTC `generatedAt`，以及 `release`。
  两份清单的键与顺序完全相同。
- `release: null` 表示暂无可用发布；否则包含 canonical `tag`（stable 为 `vX.Y.Z`，beta 为
  `vX.Y.Z-beta.N`）与 `version`、`build`、
  `minimumSystemVersion`、`publishedAt`、非空 Markdown `releaseNotes`、`archiveURL`、
  `archiveSize`、小写 64 位 `archiveSHA256`。
- 正式归档 URL 为
  `https://github.com/kafeifei/XDial/releases/download/<tag>/XDial-<tag>.zip`。
  归档上限 512 MiB，重定向仅限 GitHub 资产下载边界。

HTTP ETag/304 验证持久缓存；成功检查时间与清单的 `generatedAt` 分离。客户端拒绝旧
revision 或相同 revision 的不同字节，429 按 `Retry-After` 退避。下载和安装分别重新
确认候选身份，撤回或无法确认会阻止操作；归档另有大小、SHA-256、组件版本、签名与身份
校验。用户点击安装前，更新流程不改变连接。

## 客户端通道

正式身份只有一个 App；beta 不是独立身份，只是多读一份清单。

- 偏好键 `xdial.update.channel`（App 的 UserDefaults），只有值为 `"beta"` 才算开启，默认关闭。
  开关在“通用 › 关于与更新”；每次切换都立即检查一次，包括已有下载好、待安装的更新时：清单
  给出的仍是它就保留，否则丢弃并改为可下载的新候选，检查不出结论时也保留。检查、下载、验证或
  交接期间拒绝切换。
- 关闭时传输层只请求 stable.json，URL、缓存键 `xdial.update.pages-cache.production`、
  修订链与解析规则与此前的客户端一致。开启后同时读 beta.json（缓存命名空间
  `production-beta`），取标签更高的候选。
- 已安装 beta 时不论开关都继续读 beta.json，直到 stable 给出高于已装版本的标签。关闭开关
  不降级：已装的 beta 只接收同一 X.Y.Z 线的修复（beta.N+1），不会被带进下一条 beta 线，界面
  显示“等待正式版”；只有“从正式版进入 beta 线”的候选或已暂存更新会在关闭时丢弃。
- 两份清单各自维护退避、ETag 与修订链。stable 失败时本次检查不给结论；只有 beta 失败时
  以 stable 为结论，beta 的失败只作次要提示。例外：已装 beta 而 stable 没有高于它的版本时，
  beta.json 是它唯一的更新来源，读取失败即本次检查不给结论，不显示为已是最新。下载和安装前，
  候选所在的清单必须重新确认成功，另一份清单的失败不阻挡。
- 标签按 SemVer 比较：先比 X.Y.Z，同号时 beta 低于正式版，beta 之间按 N。候选构建号必须
  高于当前构建号，否则报“构建号没有提高”（`build_not_newer`），不显示为已是最新：
  更低的构建号替换不了已激活的网络扩展。每份清单的构建号倒序都写诊断（NSLog 与 Debug Server
  的 `lastBuildNotNewer`），被另一份清单的候选盖过时也一样；stable 已是最新而 beta 倒序时
  显示为失败。
- 代价：beta 线开放期间发 stable 热修复后，beta.json 当前条目的构建号不高于这个热修复。装了
  热修复又开着 beta 的用户每次检查都会看到 `build_not_newer`，直到发出包含该热修复的
  beta.N+1 或撤回 beta 条目。所以每次发 stable 后，都要尽快重发或撤回 beta.json 中构建号
  不高于新 stable 的条目；`make publish` 发 stable 前会检查，见[beta 发布机制](#beta-发布机制)。
- 包内 `XDialReleaseTag` 取自构建设置 `XDIAL_RELEASE_TAG`，默认为空；`make release` 把
  发布标签写进它，正式版和 beta 都写，此前构建的正式包为空。它是判断“已装 beta”的唯一
  依据：只有它能解析为 beta、且 X.Y.Z 等于短版本时才算已装 beta，其余一律视为正式版
  `v<短版本>`。因此它决定已装版本属于哪条线、新旧比较（同号正式版能否算作更新），以及
  是否额外读取 beta.json。它只能让客户端多读 beta.json，不能替换或锁定 stable.json，也不
  参与签名包授权；`make test-macos-transaction` 有静态门禁。beta 包的 `XDialReleaseTag`
  必须等于它的标签（发布合约与 release.yml 都检查）：留空的 beta 会被当作正式版
  `v<短版本>`，同号正式版发布时判为不更新、也不再读 beta.json，用户会停在这个 beta 上，
  直到下一个 X.Y.Z 发布。
- 重启意图为 schema 2，带 `targetBuild`；读取时接受 ≤ 当前 schema 的意图，schema 1（v0.9.x
  写出）只比对版本。
- 构建号降级（例如手动安装旧版或同号预置配置包覆盖 beta）有两道门禁，提示相同：先在 App 内
  卸载（不勾选删除数据），再安装这个版本。
  - 安装期：App 从“应用程序”之外启动并自行安装（含自动更新的暂存包）和 `--install-only`，
    都在安装锁内比较来源与“应用程序”中同身份 App 的 CFBundleVersion，来源更低就拒绝替换。
  - 扩展检查：用 Finder 把旧版拖进“应用程序”覆盖时，宿主在 XDial 运行前已被替换，安装期
    门禁拦不住。之后安装或连接检查网络扩展时，若系统中仍登记着更高构建号的同一扩展（不在
    卸载中），就不再提交激活（系统不会用更低构建号替换它），直接报告这个构建号。
  - 范围：两道门禁都由被装进来的那个更旧的 App 执行：安装期门禁在被启动的来源 App 里，扩展
    检查在替换后的宿主里。所以只有带这两道门禁的构建才会拦截降级。装回不带门禁的构建（目前
    已发布的 v0.9.6 及更早的全部正式版，以及用同样旧源码打的预置配置包）不受保护：宿主照样
    被替换，扩展仍是更高的构建号，两者失配，只能先卸载（不勾选删除数据）再安装。
- 验收包的清单地址为 `acceptance/<ID>/<channel>.json`，beta 缓存命名空间为
  `acceptance-<ID>.beta`。

beta 的构建与发布见[beta 发布机制](#beta-发布机制)。带开关的客户端发布前，清单仓库要先部署
`release: null` 的 beta.json 占位；否则开启 beta 的用户会看到 beta 清单的次要提示。

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

`release-contract.sh verify-app` 是正式版、预置配置包和验收包共用的分发门禁：宿主、Settings UI、
System Extension 与 helper 都须带 hardened runtime 和安全时间戳，且没有 `get-task-allow`；宿主
`Contents/MacOS` 下的文件不得含 `DebugServer:`（Debug 配置把宿主代码放在 `*.debug.dylib`）；helper
不得带 `main.buildFlavor`。`-trimpath` 构建的 `go version -m` 不记录 `-ldflags`，所以 helper 的
`version` 输出会写出 flavor，由合约的 `xdial <tag>` 逐字比对拒绝。读 helper 的构建信息要用 `go`，
所以运行 `verify-app` / `verify-archive` 的机器（含执行 `make publish` 的 publish job 和操作员 Mac）都须装 Go。只在 tag
workflow 里，[verify-release-helper-source.sh](../../scripts/verify-release-helper-source.sh) 还要求
helper 的 `vcs.revision` 等于 tag 所在提交且 `vcs.modified=false`。Go 只把目录形式的 `.git` 当作仓库根：
在链接 worktree 里构建，会记下外层普通检出的修订；不在任何检出内时不记录 vcs。这项因此只在普通
checkout 中成立；`release-app` 先编译 helper，再运行会重写已跟踪 `.icns` 的图标目标。

draft 生成后，release.yml 的 `publish` job 在 main 的检出上执行 `make publish RELEASE_PAGES=follow`，
所以推送 tag 就是发布。`make publish RELEASE_TAG=vX.Y.Z` 调用
[publish-release.py](../../scripts/publish-release.py)：重新获取源码仓库的 main/tag 并校验主线归属，
下载、校验真实附件，再公开 draft，最后读取 canonical 清单核对版本、build、摘要和说明。
清单由更新仓库自己部署，XDial 不保存更新仓库的任何凭据：

- `RELEASE_PAGES=follow`（release.yml）：只用 workflow 自己的令牌公开 Release。更新仓库的
  `follow.yml` 每 10 分钟查一次公开的 Release，派发 `publish.yml`；这边最多等
  `RELEASE_PAGES_TIMEOUT`（默认 3600 秒）读到新清单，等不到就失败并指向 follow.yml。
- `RELEASE_PAGES=dispatch`（默认，本机）：用操作员的 `gh` 登录直接派发 `publish.yml` 并等它结束，
  用于重跑，以及需要 `RELEASE_BETA_FOLLOWUP` 的发布（publish job 遇到这种情况会停在公开之前）。

publish job 在公开之前失败时，修好后只重跑这个 job；等不到清单时，在本机执行同一个
`make publish`（dispatch 模式自己派发）。已经公开的 Release 会被复用。

Pages 发布器串行生成清单、历史与审计记录，拒绝旧版本覆盖、同 tag 内容改写和撤回版本
重发。附件公开与 Pages 生效是两个阶段；Pages 失败时原站点保留，同一发布命令可重试。
`publish.yml` 的 `operation=withdraw` 与 `release_tag` 撤回指定版本，使清单变为
`release: null`，保留历史和资产，不降级已安装 App。

两个通道的 `make publish` 在公开 Release 之前，先做 Pages 发布器公开之后才会做的检查，
不让它会拒绝的包先公开：

- 构建号：新包的构建号必须大于所有“X.Y.Z 不高于新包”的已公开包。数据是 GitHub
  Releases 列表（含 prerelease，不含 draft），以及更新仓库 main 上两个通道的 ledger 与
  history（含已撤回的包，构建号取自首次发布该标签的 history 记录）；清单没有记录的公开
  Release 下载归档读取构建号。X.Y.Z 更高的包不构成约束，所以 beta 线开放期间发 X.Y.Z
  更低的 stable 热修复，不要求高于 beta 的构建号。
- 同一通道只能前进；撤回过的标签不能再发。
- dispatch 模式下，更新仓库里有排队或运行中的 `publish.yml` 时，先在 draft 公开之前等它结束，派发前再确认
  一次。两次等待各有一份 `--pages-timeout`（默认 900 秒）；这次运行的计时从派发开始，也是
  一份完整的 `--pages-timeout`，等待前一个运行不占用它。运行须成功结束；读回清单时，除
  `revision`、`generatedAt` 和 `release` 的值以外，字节必须与既有格式一致，`release` 的
  标签、build、SHA-256 和说明必须与这次发布一致。stable 的派发参数与此前相同，不传
  `channel`。

## beta 发布机制

beta 与正式版走同一条流水线：同一 Release 配置、签名、公证和发布合约，都构建正式身份。
通道（Makefile 的 `RELEASE_CHANNEL`，合约的 `XDIAL_RELEASE_CHANNEL`，默认 stable）只决定
下表中的差异。

| | stable | beta |
|---|---|---|
| 标签 | `vX.Y.Z` | `vX.Y.Z-beta.N`：N 从 1 起、无前导零；X.Y.Z 取下一个正式版号 |
| 标签所在提交 | `main` 的 first-parent 上 | `xdial-beta` 的 first-parent 上，包含最新的 `vX.Y.Z` 标签，且 X.Y.Z 高于它 |
| 说明文件 | `RELEASE_NOTES.md` | `BETA_RELEASE_NOTES.md`（只在 `xdial-beta` 上），标题 `# XDial vX.Y.Z-beta.N` |
| GitHub Release | draft，公开时标为 Latest | draft prerelease，公开时 `--latest=false` |
| 清单 | stable.json | beta.json |
| 包内 `XDialReleaseTag` | 等于标签；共享合约也接受空值（预置配置包） | 必须等于标签 |
| `SeedProfile`、`RuleSetPresets.json` | release.yml 拒绝；共享合约不查（预置配置包带有） | 合约与 release.yml 都拒绝 |

**构建。** beta 只在 CI 构建：本机构建会按 project.yml 回退嵌入 `macos/PrivateConfig`，beta
合约拒绝这样的包。推送 `vX.Y.Z-beta.N` 后，release.yml（`tags: v*` 同样匹配 beta 标签）按
标签形态选通道和说明文件，取 `origin/xdial-beta` 做合约检查，取 `origin/main` 做下文的
共享格式门禁，执行 `make release RELEASE_CHANNEL=beta`，再核对归档的 `XDialReleaseTag` 和
私有载荷，上传为 draft prerelease。beta 的 `release-inputs` 刷新 `origin/xdial-beta` 和 `v*`
标签后检查标签；带 `RELEASE_UPDATE_ACCEPTANCE_ID` 的验收构建跳过这项分支门禁，包仍须通过
beta 合约，`make publish` 和 release.yml 都拒绝验收包。本机只构建验收用的 beta 包，并且在只含
已跟踪文件的临时 worktree 里构建，见[三包验收](#三包--beta)。

**公开。** release.yml 的 publish job（或本机的
`make publish RELEASE_CHANNEL=beta RELEASE_TAG=vX.Y.Z-beta.N`）重新从源码仓库获取
`xdial-beta`、`main`、这个标签和最新正式标签，核对 first-parent、包含关系和版本，并对这个
标签跑共享格式门禁；要求 Release 是 prerelease，归档的 `XDialReleaseTag` 等于标签、不含
私有载荷；X.Y.Z 必须高于所有公开过的正式版（GitHub Releases、`releases/latest` 和 stable
ledger，含已撤回的）；更新仓库必须已有 beta.json；再做上面的构建号检查。通过后以
`--prerelease --latest=false` 公开 draft，复查 `releases/latest` 仍是原来的正式标签，再由更新仓库
发布 beta.json（follow.yml 派发，或 dispatch 模式下由这边派发 `channel=beta` 的 `publish.yml`）并读回。
beta 标签的 release.yml 取自 `xdial-beta`，它合入带 publish job 的 main 之后，beta 才会自动公开。

**与更新仓库的接口。**

```sh
gh workflow run publish.yml -R saymiao/xdial-updates -f operation=<publish|withdraw|restore> \
  -f channel=<stable|beta> -f release_tag=<tag> -f history_revision=<revision> -f request_id=<id>
```

- `channel` 缺省为 stable。publish 与 withdraw 要 `release_tag`、不要 `history_revision`；
  restore 相反，`history_revision` 是该通道 history 中的 revision。
- 运行名为 `<operation> <channel> <标签或 revision> [<request_id>]`，按 `request_id` 找运行。
- 两个通道的所有操作共用一个并发组，同组最多一个运行中、一个排队，再派发会取消排队中的
  那个。所以派发下一次前必须等上一次运行结束（`gh run watch --exit-status`），stable 热修复
  与 beta.N+1 同批时也逐个派发；被取消的运行按失败处理，要重新派发。更新仓库的 follow.yml 和
  `make publish` 的 dispatch 模式都会先等。
- beta 有独立的 revision 链、ledger（`state/beta/ledger.json`）、history
  （`state/beta/history/`）和审计；beta.json 与 stable.json 的键和顺序相同，`channel` 为
  `"beta"`。
- 每次部署上传整个 `site/`：某个通道部署失败后，先用同一命令重跑，或对该通道 withdraw /
  restore，再运行另一个通道。

**发布顺序。**

1. 首次发 beta 前：更新仓库已部署 `release: null` 的 beta.json 占位，且带 beta 开关的正式版
   已经发出。
2. `xdial-beta` 合入最新 main（含最新正式标签），写 `BETA_RELEASE_NOTES.md`，推送
   `vX.Y.Z-beta.N`。
3. CI 生成 draft prerelease 后，release.yml 的 publish job 把它公开，更新仓库的 follow.yml 随后
   写入 beta.json。
4. 核对：`releases/latest` 仍是正式标签；stable.json 的 revision 和 SHA-256 不变；beta.json
   是新标签和新构建号。

同批发 stable 和 beta 时先发 stable：beta.N+1 要包含新的正式标签、构建号也要更高，所以在
正式标签之后打标签、构建；前一个 Pages 运行结束后再派发下一个。

**撤回与 restore。**

- 撤回 beta：`gh workflow run publish.yml -R saymiao/xdial-updates -f channel=beta
  -f operation=withdraw -f release_tag=<当前 beta 标签> -f request_id=<id>`。beta.json 变为
  `release: null`，Release 和资产保留，已装的 beta 不降级。撤回的标签不能再发，也不能被
  restore。坏 beta 只能往前修：先撤回，挡住新用户进入，再尽快发 beta.N+1；已经装上的用户
  只能等修复版，或走卸载事务。
- restore：`-f channel=<stable|beta> -f operation=restore -f history_revision=<revision>`
  （不带 `release_tag`）把该通道 history 中的一份内容以更高的 revision 重新发布。客户端拒绝
  revision 倒退，所以清单出错时只能这样回退。被替换的 release 在 ledger 中仍是 published，
  选错 revision 可以再 restore 回去；细节见更新仓库的 README。

**stable 热修复后的 beta。** beta 线开放期间发 X.Y.Z 更低的 stable 热修复后，beta.json 的
条目标签比热修复新、构建号却不高于它（客户端要求构建号严格更高，相等也报错），装了热修复
又开着 beta 的用户每次检查都报 `build_not_newer`。`make publish`（stable）在公开之前读取
更新仓库的 beta.json，发现这样的条目就停下，要求用 `RELEASE_BETA_FOLLOWUP=republish` 或
`withdraw`（脚本参数 `--beta-followup`）确认同批的后续动作，发布完成后打印下一步命令。release.yml
的 publish job 不带这个确认，会在公开之前失败；确认后在本机执行
`make publish RELEASE_TAG=vX.Y.Z RELEASE_BETA_FOLLOWUP=<republish|withdraw>`：

- republish：`xdial-beta` 合入含热修复标签的 main，打 beta.N+1，CI 构建并公开；
- withdraw：等 Pages 运行结束后撤回这个 beta 条目。

beta 条目的标签不高于这次 stable 时（例如 stable 追上了这条 beta 线），它只是被取代，不需要
后续动作。

**共享格式门禁。** 持久格式、跨进程协议和依赖版本只经 main 演进，beta 专属数据只能放在
独立文件或 `xdial.beta.*` 键。[check-beta-shared-formats.sh](../../scripts/check-beta-shared-formats.sh)
维护文件清单：依赖版本（`go.mod`、`go.sum`、`third_party`）、`patches/` 下对 sing-box、
tailscale、sslcon 的全部本地补丁与组装它们的 `prepare-patched-go-mod.sh`、配置库模型与 schema
所在文件，以及这个脚本本身。相对它与 main 的合并基点，beta 一侧不得改动其中任何文件；main
自己的改动不算。三处运行同一个脚本：

- CI：`xdial-beta` 的 push 和以它为目标的 PR（[ci.yml](../../.github/workflows/ci.yml) 的
  `beta-shared-formats`）。`xdial-beta` 没有分支保护，这一项只是提示，拦不住已经推上去的提交。
- release.yml：beta 标签构建前检查标签所在提交，不通过就不构建。
- `make publish RELEASE_CHANNEL=beta`：公开前检查远端标签。它用检出里的脚本，所以要在 main 的
  检出上运行（publish job 检出的就是 main）；前两处的脚本取自 `xdial-beta` 自身。

## 正式身份更新验收

> **验收包是正式身份（`com.kafeifei.xdial.app`）的公证包，安装会替换本机的正式 App
> `/Applications/XDial.app`，重启可能中断当前连接。构建、上传、安装和每一步核对都由作者执行。**
> 验收包收不到正式更新，验收结束或中途放弃后都要按[结束验收](#结束验收)手动回到正式版。
> 脚本只产出本地文件：不安装、不启动、不上传，也不改清单仓库。

[build-update-acceptance.py](../../scripts/build-update-acceptance.py) 对每个包调用正式
`make release`（签名、公证、归档校验），要求干净的源码提交和新的输出目录。输出目录里每个包
一个子目录（App、`XDial-<tag>.zip` 与 `.sha256`、公证记录、说明文件、`build.log`），另有
`BUILD-INFO.json`。`RELEASE_UPDATE_ACCEPTANCE_ID` 使验收构建跳过 tag 与分支门禁（stable 的
main、beta 的 `xdial-beta`）；`make publish` 和 release.yml 拒绝验收包。`--lower-ref` 与
`--beta` 在临时 git worktree 里构建，成功和失败时都会删除。

停止构建：`make release` 在自己的会话里运行，终端的 Ctrl-C 和关闭终端只送到脚本。脚本收到
Ctrl-C、`kill`（SIGTERM）或关闭终端（SIGHUP）时，像终端 Ctrl-C 那样对 `make` 的进程组发
SIGINT：xcodebuild 据此取消它放在独立进程组里的构建任务，等任务结束才退出（SIGTERM 会让
xcodebuild 立即退出，任务留下继续写 worktree 里的 `build/`）。进程组 30 秒内没退出再发
SIGTERM，5 秒后发 SIGKILL；等进程组全部退出才删除 worktree，停止和清理期间再收到的停止信号
等它们做完再生效。只有 SIGINT 没停下 `make` 时，xcodebuild 的构建任务可能留下并在 worktree
删除后重新写出目录，脚本这时会提示，结束后检查 `$TMPDIR` 下的 `xdial-acceptance-*`。用 `nohup`
启动时，关闭终端既不停脚本也不停 `make`。`kill -9` 跳过这一切：`make` 继续签名、公证，
worktree 也留下。这时 `pgrep -f 'make release RELEASE_TAG='` 列出的 PID 就是进程组号，
`kill -INT -<进程组号>` 停掉构建，再对 `git worktree list` 里 `xdial-acceptance-*` 下的
worktree 执行 `git worktree remove --force`。

所有包签名 Info.plist 的 `XDialUpdateAcceptanceID` 相同，客户端只读
`https://saymiao.github.io/xdial-updates/acceptance/<ID>/<channel>.json`（清单仓库的
`site/acceptance/<ID>/`），归档只接受 `saymiao/xdial-updates` 的 Release 资产
`releases/download/<tag>/XDial-<tag>.zip`。当前与传入 App 的 acceptance ID 必须相同。
清单仓库已有的 Release 标签不能再用，每次验收选新的版本号和新的 ID。

### 双包

```sh
python3 scripts/build-update-acceptance.py \
  --id pages-YYYYMMDD --lower-version 0.8.1 --higher-version 0.8.2 \
  --output /absolute/path/to/new-acceptance-run --notary-profile xdial-notary
```

在当前检出从同一个源码提交构建 stable A/B，仅改变版本号与递增 build；`BUILD-INFO.json`
含 `sourceCommit`，清单由作者按[清单合同](#清单合同)手写，按[部署验收清单](#部署验收清单)
部署。验收后本机停在 B，按[结束验收](#结束验收)回到正式版。

同源码 A→B 覆盖该实现的更新机制，不证明旧正式客户端的升级兼容，也不证明修改前后
工作流一致。包签名校验不包含实际 UI、helper、扩展交接、连接恢复或流量结果。
旧客户端仍执行旧更新逻辑，进入新逻辑依赖手动安装或旧通道成功更新。

### 跨版本（`--lower-ref`）

`--lower-ref <ref>` 从该 ref（例如当前正式标签 `v0.9.6`）构建 A，从 HEAD 构建高版本包，
各在一个临时 git worktree 里。同一 HEAD 的两个包测不出跨版本问题，例如 v0.9.x 写出的
schema 1 重启意图能否被新版本接受。要覆盖 schema 2 → schema 2，A 取第一个含客户端 beta
通道的正式标签，确认它写出的重启意图（带 `targetBuild`）被高版本接受、暂存继任通过、
原场景恢复连接。

- ref 必须能解析为本地提交（先 fetch 标签），它的 Makefile 必须已有
  `RELEASE_UPDATE_ACCEPTANCE_ID` 和 `RELEASE_NOTES_FILE`；否则开始前报错。
- 只传该 ref 的 Makefile 声明过的变量：没有 `RELEASE_CHANNEL` 的旧 Makefile 只构建 stable，
  不传通道。旧 ref 不写 `XDialReleaseTag`，客户端把这样的包当作 `v<短版本>`。
- 两边都只有已跟踪文件，本机被忽略的 `macos/PrivateConfig` 不进任何一个包，A 与高版本包
  只差源码 ref。设置了 `XDIAL_RULE_SET_PRESETS_FILE`、`XDIAL_SEED_PROFILE_FILE`（v0.9.2 之前
  的 ref 不读后者，两边会不一致），或任一边跟踪了 `macos/PrivateConfig` 下的文件时，脚本在
  构建前报错。要验带预置配置包的更新，用双包。
- `BUILD-INFO.json` 为每个包写 `sourceRef` 和 `sourceCommit`。
- 验收后本机停在高版本包，按[结束验收](#结束验收)回到正式版。

### 三包（`--beta`）

```sh
python3 scripts/build-update-acceptance.py --beta \
  --id pages-beta-YYYYMMDD --lower-version 0.9.7 --higher-version 0.9.8 \
  --output /absolute/path/to/new-acceptance-run --notary-profile xdial-notary
```

用同一个 acceptance ID 构建三个包。L、H 是两个版本参数，n 是开始构建时的 Unix 秒：

| 包 | 标签 | 通道 | 短版本 | 构建号 | 归档 | 说明文件与标题 |
|---|---|---|---|---|---|---|
| A | `vL` | stable | L | n | `XDial-vL.zip` | `RELEASE_NOTES.md`，`# XDial vL` |
| B | `vH-beta.1` | beta | H | n+1 | `XDial-vH-beta.1.zip` | `BETA_RELEASE_NOTES.md`，`# XDial vH-beta.1` |
| C | `vH` | stable | H | n+2 | `XDial-vH.zip` | `RELEASE_NOTES.md`，`# XDial vH` |

- B 以 `RELEASE_CHANNEL=beta` 构建，须满足 beta 合约：`XDialReleaseTag` 等于标签，不含
  `SeedProfile` 与 `RuleSetPresets.json`。所以三个包都在 HEAD 的临时 worktree 里构建：它只有
  已跟踪文件，本机被忽略的 `macos/PrivateConfig` 进不了包。设置了
  `XDIAL_RULE_SET_PRESETS_FILE`、`XDIAL_SEED_PROFILE_FILE`，或 HEAD（合用 `--lower-ref` 时还有
  该 ref）跟踪了 `macos/PrivateConfig` 下的文件时，脚本在构建前报错，不会等到 B 被合约拒绝。
- 可与 `--lower-ref` 合用：A 从该 ref 构建，B、C 仍从 HEAD。该 ref 必须已有“接收 beta 版本”
  开关（`xdial.update.channel`），否则第 1 步无从开始，脚本在构建前报错。
- `BUILD-INFO.json` 为每个包写明 `tag`、`channel`、`version`、`build`、`archiveName`、
  `archiveSHA256`、`notesTitle`、`sourceRef`、`sourceCommit`，`feeds` 列出每一步的清单文件。

三个包都构建成功后，脚本在 `feeds/` 下生成每一步的 `acceptance/<ID>/stable.json` 与
`beta.json`：键、顺序和格式与正式清单相同（2 空格缩进的 UTF-8 JSON，末尾换行），归档 URL
指向清单仓库的 Release。`revision` 取生成时刻的毫秒数，同一 ID 重跑也不会让客户端缓存的
修订号倒退；`generatedAt` 与 `publishedAt` 取生成时刻。

| 目录 | stable.json | beta.json | 用于 |
|---|---|---|---|
| `feeds/step-1/acceptance/<ID>/` | A | B | 第 1、2 步 |
| `feeds/step-3/acceptance/<ID>/` | C，revision 加 1 | B，与 step-1 逐字节相同 | 第 3 步 |

作者执行：

0. 在 `saymiao/xdial-updates` 为 A、B、C 各建一个以标签命名的 prerelease，上传
   `XDial-<tag>.zip` 与 `.sha256`；把 step-1 的两个文件放进清单仓库的 `site/acceptance/<ID>/`，
   按[部署验收清单](#部署验收清单)部署。从 A 的 zip 手动安装 A，保持 beta 关闭检查更新：只读
   stable.json，应显示已是最新。
1. A 开启“接收 beta 版本”：立即检查，应提供 B 并升级到 B。
2. B 关闭开关：应停留在 B，显示“等待正式版”。B 仍读 beta.json，但不降级。
3. 用 step-3 的两个文件替换同一目录并同样部署，即发布 C：确认线上已是 step-3 的文件后，B
   检查应升级到 C。
4. 每一步完成后核对 host、settings、extension、daemon 的版本和构建号，应与
   `BUILD-INFO.json` 中这一步应装的包一致（命令见下）。
5. 验收结束后本机停在 C，按[结束验收](#结束验收)回到正式版。

```sh
app=/Applications/XDial.app
for bundle in "$app" "$app/Contents/Helpers/XDial Settings UI.app" \
  "$app/Contents/Library/SystemExtensions/com.kafeifei.xdial.app.transparent-proxy.systemextension"; do
  echo "$bundle: $(plutil -extract CFBundleShortVersionString raw "$bundle/Contents/Info.plist")" \
    "$(plutil -extract CFBundleVersion raw "$bundle/Contents/Info.plist")"
done
plutil -extract XDialReleaseTag raw "$app/Contents/Info.plist"
systemextensionsctl list | grep -F com.kafeifei.xdial.app.transparent-proxy
python3 -c 'import json, socket
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect("/tmp/xdial.sock")
s.sendall(b"{\"id\":\"acceptance\",\"cmd\":\"daemon-info\"}\n")
print(next(r["data"] for r in map(json.loads, s.makefile()) if r.get("id") == "acceptance"))'
shasum -a 256 "$app/Contents/MacOS/xdial-daemon"
```

`XDialReleaseTag` 在 B 上是 beta 标签。`systemextensionsctl list` 显示已激活扩展的
`(版本/构建号)`。daemon 没有构建号：`daemon-info` 给出运行中 daemon 的版本（即发布标签）、
PID 与二进制 SHA-256，版本应等于这一步的标签，SHA-256 应等于包内 `xdial-daemon`。

### 部署验收清单

清单仓库的 Pages 只由 `publish.yml` 部署（`workflow_dispatch`，每次上传整个 `site/`），推送到
main 不会部署。每一步把清单文件提交并推送到清单仓库 main 后，对 stable.json 当前的标签派发
一次 publish：标签相同，发布器判为 noop，stable.json 不变，只追加一条审计记录，部署时把
`site/acceptance/` 一起带上。`channel` 缺省为 stable，不用传；stable.json 为 `release: null`
时改用 `operation=withdraw` 和最近撤回的标签，同样是 noop。这次运行与正式发布共用并发组
`stable-feed-publisher`：先确认没有排队或运行中的 `publish.yml`，正式发布期间不要派发。

```sh
id=<ID> step=step-1   # 第 3 步用 step-3；在验收输出目录里运行
request="acceptance-$id-$step"
tag=$(curl -fsS https://saymiao.github.io/xdial-updates/stable.json |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["release"]["tag"])')
gh workflow run publish.yml -R saymiao/xdial-updates \
  -f operation=publish -f release_tag="$tag" -f request_id="$request"
run=
while [ -z "$run" ]; do
  sleep 3
  run=$(gh run list -R saymiao/xdial-updates --workflow publish.yml --limit 20 \
    --json databaseId,displayTitle \
    --jq "map(select(.displayTitle | contains(\"[$request]\")))[0].databaseId // empty")
done
gh run watch "$run" -R saymiao/xdial-updates --exit-status
for channel in stable beta; do
  curl -fsS "https://saymiao.github.io/xdial-updates/acceptance/$id/$channel.json" |
    cmp - "feeds/$step/acceptance/$id/$channel.json" && echo "$channel.json deployed"
done
```

运行成功、线上两份文件与这一步的文件逐字节相同之后，才让客户端检查；不同就稍等再比，仍不同
就查这次运行。双包只有手写的 stable.json，比对它即可。

### 结束验收

验收包只读 `acceptance/<ID>/` 下的清单，自动更新还要求新旧包的 acceptance ID 相同，所以装着
验收包的本机（三包第 3 步后的 C、双包和跨版本的高版本包，或中途停下时装着的那个包）永远收不到
正式更新，要手动回到正式版。验收包与正式版的构建号都是构建时的 Unix 秒，所以验收包高于此前
构建的所有正式版，包括当前正式版。

- 等构建号更高的正式版（验收之后才构建的都是）发布后手动安装它：下载 zip 后从“应用程序”之外
  启动，或用 Finder 覆盖。宿主与扩展都正常替换。
- 立即回到当前正式版：先在 App 内卸载（不勾选删除数据），再安装。不要直接覆盖或让它自行安装，
  这是[构建号降级](#客户端通道)：v0.9.6 及更早的正式版没有降级门禁，宿主被替换而扩展仍是验收包
  的构建号，两者失配；带门禁的正式版也只会报错，提示先卸载。
