# 安装、更新与卸载

## 环境

构建需要 macOS 26 SDK（Xcode 26 或带相应 SDK 的命令行工具）、Node.js 22.12+、pnpm 10.19+。
目标最低系统为 macOS 14，但首轮验证只覆盖当前维护者的 Apple Silicon / macOS 26 设备。
macOS 14/15、Intel 和不同 Codex 客户端版本不是已完成的兼容承诺。

检查 `xcrun --sdk macosx --show-sdk-version`，应至少为 26。不需要注册开发者账号即可本地编译；面向普通用户发布签名、公证下载包另需 Developer ID 条件。

## 从源码构建

1. 按首页下载源码、运行 `npm ci` 和 `npm test`。
2. 运行 `npm run build`。场景依赖按锁文件安装，原生程序从 Swift/Objective-C 编译。
3. 输出为 `.build/release/Rootnote Resonance.app`。脚本不覆盖已有构建；再次构建可指定 `OUTPUT_ROOT="$PWD/.build/release-2" npm run build`。
4. 运行 `zsh scripts/install.sh`，复制到当前用户的 Applications，不需要管理员权限。
5. 用 Finder 手动打开应用。菜单栏可打开任务、性能和额度面板。

应用采用本机临时签名，**不是 Apple 公证包**。遇到安全拦截时先核对来源和构建步骤，不建议关闭 Gatekeeper、SIP 或执行全局安全绕过命令。

## 宠物

运行 `zsh scripts/install-pet.sh` 会把仓库内素材复制到 `~/.codex/pets/rootnote-resonance`。
已存在同名目录时停止，不覆盖。
请使用支持该自定义宠物格式的 Codex 客户端选择 Rootnote；选择入口与可用性取决于客户端版本。
Rootnote 只跟随可检测到的宠物窗口，不能强行使不兼容客户端显示宠物。

## 权限与同步

- 不要求提供密码或访问令牌，不读取或修改认证文件。
- 额度读取优先使用标准安装路径中的 Codex CLI；找不到或未登录时显示明确状态。
- 不支持的客户端位置及接口版本请提交脱敏复现，不要复制认证文件到本项目。
- macOS 的窗口信息权限或客户端窗口结构可能影响宠物锚点；不可检测时不猜位置，使用菜单栏入口。
- 侧栏周额度需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Rootnote，并让兼容客户端的侧栏可见。这里只读定位，不向客户端发送辅助功能点击。
- 侧栏与宠物显示相互独立；胶囊开关的是现有额度页，不会召唤宠物。外观与面板深浅分别处理，详情见[侧栏额度](侧栏额度.md)。
- 默认不添加登录项。需要自动运行时，可由用户在 macOS 登录项中自行添加应用。

## 更新

1. 从菜单退出 Rootnote；不要退出或重启 Codex。
2. 备份旧 `.app` 和 `~/Library/Application Support/Rootnote`。
3. 在新的输出目录构建，确认测试后由用户手动替换旧应用。
4. 保留备份直到新版本验收通过；出现问题时退出新版本，恢复旧应用和需要恢复的数据。

本仓库不携带维护者机器上的旧 LaunchAgent 或自动覆盖脚本。
应用使用既有 Bundle ID 以兼容已安装版本，因此不要同时运行两个 Rootnote 副本。

## 卸载

从菜单退出 Rootnote，将 `~/Applications/Rootnote Resonance.app` 移到废纸篓。
如果自行设置了登录项，从系统设置移除。账号记录可先在 Rootnote 设置中清除。
需要完全清理时，手动移除 `~/Library/Application Support/Rootnote` 及仅本项目的宠物目录；不要删除整个 `~/.codex`。
