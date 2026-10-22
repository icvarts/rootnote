# 开发指南

- `Sources/`：AppKit 外壳、系统玻璃、窗口锚点、性能采集、只读账号接口与活动解析。
- `Resources/guard/`：面板内容层及图标依赖。
- `scene/src/`：可编辑 Three.js 场景；生命周期直接接入源码，不再替换压缩 bundle 的字符串。
- `scene/public/`：场景素材及暂停/恢复控制。
- `pets/`：客户端使用的宠物清单和精灵图。
- `scripts/`：构建、拒绝覆盖的安装、离线原生测试。
- `tests/`：合成状态模型、浏览器布局与场景生命周期测试。

执行 `npm ci` 安装测试依赖；场景使用自身 pnpm 锁文件。
执行 `pnpm --dir scene install --frozen-lockfile` 后可用 `pnpm --dir scene dev` 调试。

本机启动场景预览不读取账号或会话；桌面模式才由原生程序注入活动状态。
场景测试自行启动并关闭临时本地服务，不留下常驻进程。
先执行 `pnpm --dir scene install --frozen-lockfile`；`npm run test:scene` 会构建场景后检查桌面/移动视口、画布非空与运动、图片加载、状态切换、暂停/恢复，不连接真实客户端。

浏览器测试默认使用 Playwright Chromium；先运行 `npx playwright install chromium`。
也可显式使用已安装的 Chrome：`PLAYWRIGHT_CHANNEL=chrome npm run test:browser`，场景测试同样支持此选项。
截图与回执写入忽略目录 `qa-output/`，不会进入发布源码。

`npm test` 同时检查模型与 npm/lockfile/原生 bundle 的版本一致性。
`npm run test:browser` 包含现有面板和侧栏组件；侧栏冻结样式位于 `tests/fixtures/sidebar-quota-approved.css`，不引用外部工作台。

正文中的位置示意可用 `node scripts/render-sidebar-previews.cjs` 重建（同样支持 `PLAYWRIGHT_CHANNEL=chrome`）。它仅打开 `docs/previews/sidebar-context.html` 合成页面与实际胶囊组件，阻止外部请求，检查 52 pt 导航条、居中、36×116 pt 底色及 12 pt 头像间隔；不采集客户端或真实账号。图片写入 `docs/images/`，验证报告写入忽略目录 `qa-output/sidebar-context/`。

原生离线测试使用独立输出与状态目录，不运行常驻 AppDelegate。
需要测试原生玻璃布局时，可在有桌面会话的 macOS 26 上使用
`npm run test:native:ui`（先运行 `npm run test:native` 构建测试程序）。
GUI 用例按顺序运行，覆盖性能圈、共享面板、侧栏几何/穿透/稳定层级以及合成账号同步；不启动正常常驻流程或读取真实账号/目标辅助功能树。
该测试不能替代原生合成画面的人工视觉验收。

## 兼容性风险

会话数据库当前适配 `state_5.sqlite`，宠物定位依赖客户端窗口及本地设置字段。
这些不是稳定公开的跨版本契约。变化时必须显示未知、缺失或不可用，不能假装正常。
额度使用短时 `app-server --stdio` 的只读账号方法，不加入真实任务或接管审批。

侧栏依赖辅助功能中的 `app-shell-sidebar`、应用导航及账号按钮结构；外观适配只读桌面模式和当前主题 `surface`，未知格式停显。
原生独立点击窗口只覆盖中部点击区，显示窗口自身穿透；两窗使用受前台/遮挡/睡眠策略约束的浮动层级。
主要几何、外观配置解析与账号有效期在纯模型回归中测试，真实窗口行为在显式 GUI 回归中验证。宿主原生宠物横条不属于可独立改色的 Rootnote 控件。

不要把 Codex 的安装文件、签名补丁、账号令牌或私有原始日志纳入仓库。
不要通过修改 `RootnoteNativeControlsEnabled` 宣称直接发送或审批已可用。
