# 本机 Codex → GitHub → 用户更新

## 仓库与分支

公开仓库：`https://github.com/duoduocats/codex-buddy`。
只提交当前项目根目录，绝不提交父级工作区、auth.json、本机登录信息或日志。
许可证：GPL-3.0-only；应用标识：`com.duoduocat.codexbuddy`。

`main` 保存可发布代码。日常工作使用 `feat/…` 或 `fix/…` 分支，经 PR、CI 通过后合并。
建议在 GitHub Ruleset 要求 PR 和 CI；个人紧急修复也至少本地测试后再发布。

## 本机开发

先按 [安装包构建说明](install/README.md) 建立 Python 环境，安装测试和打包所需的构建依赖；它们不会进入应用。

```sh
git switch -c fix/short-description
bash scripts/test.sh
BUILD_DIR="$(mktemp -d /private/tmp/codex-buddy-dev.XXXXXX)" bash build.sh
git add Sources Tests scripts Info.plist
git commit -m "fix: describe the change"
git push -u origin HEAD
```

让 Codex 基于明确需求实现、检查差异、测试，并创建 PR。签名密钥、GitHub token 不进入对话或源码；使用系统凭据存储。

## 准备版本

版本使用 `MAJOR.MINOR.PATCH`，对应 `vMAJOR.MINOR.PATCH` Git tag。

```sh
python3 scripts/prepare-release.py 1.2.1
# 编辑 releases/v1.2.1.md，写真实变更说明
bash scripts/test.sh
```

发布模式由维护者明确指定，默认 `none`。使用 `--mode none|notify|silent` 准备版本；配置保存到 `releases/vX.Y.Z.json`，作为 `update-policy.json` 随 Release 上传，不写入更新说明。

- `none`：不自动提醒或安装，用户主动检查后可安装。
- `notify`：展开面板的设置按钮旁显示圆形下载按钮，不自动弹窗；说明在设置中查看，不再提供忽略版本入口。
- `silent`：发现版本后自动下载、校验、替换并后台重启，无需再次确认。

客户端验证元数据所属仓库、版本和 SHA-256。未知模式、缺失或损坏的元数据不会触发自动安装；没有元数据的旧版仍识别原有的重要更新标记。后台检查尊重用户已忽略的版本。

从 2.1 起，`notify` 元数据使用 `schemaVersion: 2`，表示面板内下载提示。旧客户端不认识此结构，因此后台不会触发旧式弹窗；用户主动在旧客户端检查更新时仍遵循旧客户端行为。其余模式继续使用结构版本 1。新客户端同时接受结构版本 1 和版本 2 的 `notify`。

## 发布

版本 PR 合并 main 后：

```sh
git switch main
git pull --ff-only
git tag -a v1.2.1 -m "Codex Buddy 1.2.1"
git push origin v1.2.1
```

Actions 在 macos-26 ARM runner 测试并构建，上传 DMG 与 SHA-256，然后创建 **Draft Release**。
维护者查看更新说明和资产后点击 Publish release；这一步才使用户可见。
也可在 Actions 手动运行 Release，选择已存在 tag，`update_mode` 默认 `none`。
重复发布同 tag 会失败，避免覆盖已经发布的二进制；修复用新版本。

每个 Release 必须包含：
- `Codex-Buddy-X.Y.Z-arm64.dmg`
- 同名 `.sha256`
- `update-policy.json`
- 更新说明（GitHub 自动附带该 tag 的源代码 ZIP/TAR，满足对应源码可获取）。

将正式发布设置为 Latest。草稿与预发布不进入更新通道。

## 客户端行为

| 场景 | 行为 |
|---|---|
| 启动/每 6 小时 | 后台查 latest；按维护者元数据选择不提醒、提醒或静默安装 |
| 点击“检查更新” | 立即查询并显示当前状态，可下载并更新 |
| `notify` 版本 | 设置按钮旁显示圆形下载按钮；更新说明位于设置，不自动弹窗 |
| `silent` 版本 | 自动下载、校验并后台替换重启；失败不弹窗，保留当前版本 |
| 旧版忽略记录 | 为兼容已保存记录仍保留；新版界面不提供忽略更新入口 |
| 点击“下载并更新” | 原生 URLSession 下载 GitHub DMG、校验、替换和重新启动 |
| 下载/校验失败 | 保留当前版本并在设置中显示错误 |
| 替换失败 | 尝试还原旧版并重新打开 |

发布策略仅作用于 latest 正式版本。旧客户端需要先安装支持元数据的版本，才能执行这些模式。

## 自动安装细节

不需要用户登录 GitHub，不读取 GitHub token。更新源固定为本仓库的公开 HTTPS Releases。
下载链接校验仓库、tag、文件名；重定向只允许 GitHub 官方资产主机。
使用 GitHub Release asset 的 SHA-256 digest，校验包大小、应用标识、版本、最低系统版本、代码签名。
在安装目录旁建立私有临时目录，旧进程退出后将旧 app 移为备份，再将已校验新 app 移到原位置。
更新需要安装目录可写；不弹管理员密码框。请安装到有写入权限的 Applications 目录。
旧版备份在同目录 `.codex-buddy-update-UUID.noindex/previous.app`，可手动恢复；不显示为正常搜索结果。

当前使用 ad hoc 签名和 GitHub HTTPS 发布链路，SHA-256 校验保证下载内容与 GitHub 记录一致，不等同于独立发行者签名。公开长期分发建议后续接入 Developer ID + notarization；证书仅放 GitHub Secrets。

## 首次接入

1. 创建公开仓库并使用 GPL-3.0-only。
2. 提交、推送这个项目目录；CI 测试通过。
3. 发布 v1.2.0（普通静默版本），先检查草稿资产再发布。
4. 用户手动安装一次 v1.2.0，后续版本可应用内更新。
5. 本机应用标识已更换，需要重新选择是否开机启动。

官方参考：
- https://docs.github.com/en/rest/releases/releases
- https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
