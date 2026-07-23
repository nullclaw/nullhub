# NullHub

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md)

安装、配置和管理
[NullClaw](https://github.com/nullclaw/nullclaw) 的最简单方式。

NullClaw 生态系统的管理中心。

`NullHub` 是一个内嵌 Svelte Web UI 的单体 Zig 二进制文件，用于安装、
配置、监控和更新生态系统组件（NullClaw、NullBoiler、
NullTickets、NullWatch）。

## 功能

- **安装向导** -- 由清单驱动的引导式设置，提供感知组件的流程和本地 `NullTickets -> NullBoiler` 连接
- **进程监管** -- 启动、停止、重启，以及采用退避机制的崩溃恢复
- **健康监控** -- 定期执行 HTTP 健康检查，并通过仪表盘状态卡展示结果
- **跨组件连接** -- 自动连接 `NullTickets -> NullBoiler`、生成原生跟踪器配置，并在一个 UI 中检查队列和编排器状态
- **配置管理** -- 为 `NullClaw`、`NullBoiler`、`NullTickets` 和 `NullWatch` 提供结构化编辑器，并可在需要时直接编辑原始 JSON
- **日志查看** -- 按实例查看日志末尾内容和实时 SSE 流
- **一键更新** -- 下载、迁移配置，并在失败时回滚
- **多实例** -- 并行运行同一组件的多个实例
- **Web UI + CLI** -- 面向用户的浏览器仪表盘，以及用于自动化的 CLI
- **托管实例管理 API** -- 为托管的 NullClaw 安装提供实例级状态、配置、模型、定时任务、频道和技能路由
- **NullBoiler UI** -- 工作流编辑器、基于轮询的运行监控、检查点分叉，以及编码后的工作流和运行链接
- **NullTickets 存储** -- 通过 NullHub 代理到 NullTickets 的键值存储浏览器
- **NullWatch 飞行记录器** -- 通过 NullHub 代理查看本地 NullWatch 运行摘要、跨度时间线、评估结果、令牌用量、成本和错误上下文
- **任务控制中心** -- 在一个界面中提供本地优先的智能体任务重放，包括工作流执行、基于角色的智能体、故障、检查点恢复、持久化重放存储和实时遥测

## 快速开始

```bash
zig build
./zig-out/bin/nullhub
```

浏览器会打开 [http://nullhub.localhost:19800](http://nullhub.localhost:19800)。
生成的二进制文件包含已构建的 Web UI，不再依赖运行时
`ui/build` 目录。

本地访问链：

- `http://nullhub.local:19800`
- `http://nullhub.localhost:19800`
- `http://127.0.0.1:19800`

当相关工具可用时，`nullhub` 会尝试将 `nullhub.local` 通过
`dns-sd`/Bonjour 或 `avahi-publish` 发布；否则会依次回退到
`nullhub.localhost` 和 `127.0.0.1`。

### 运行时依赖

- 获取发布版本和二进制文件需要 `curl`。
- 解压 UI 模块包需要 `tar`。

### 构建依赖

- 构建需要 `npm`，包括执行 `zig build` 以及任何内嵌 Svelte UI 的构建。
- 仅后端测试可以通过 `zig build test -Dembed-ui=false -Dbuild-ui=false` 在没有 UI 资源的情况下运行。

如果缺少这些工具，`nullhub` 会尝试通过可用的系统软件包管理器
（`apt`、`dnf`、`yum`、`pacman`、`zypper`、
`apk`、`brew`、`winget`、`choco`）自动安装。

## CLI 用法

```
nullhub                          # Start server + open browser
nullhub serve [--host H] [--port N]
               [--allowed-origin ORIGIN] ...
                                 # Start server. Repeat --allowed-origin to
                                 # authorize extra CORS origins (e.g. a
                                 # Tailscale domain). Origins may also come
                                 # from NULLHUB_ALLOWED_ORIGINS as a
                                 # comma-separated list.
nullhub version | -v | --version # Print version

nullhub install <component>      # Terminal wizard
nullhub uninstall <c>/<n>        # Remove instance

nullhub start <c>/<n>            # Start instance
nullhub stop <c>/<n>             # Stop instance
nullhub restart <c>/<n>          # Restart instance
nullhub start-all / stop-all     # Bulk start/stop

nullhub status                   # Table of all instances
nullhub status <c>/<n>           # Single instance detail
nullhub logs <c>/<n> [-f]        # Tail logs (-f for follow)

nullhub check-updates            # Check for new versions
nullhub update <c>/<n>           # Update single instance
nullhub update-all               # Update everything

nullhub config <c>/<n> [--edit]  # View/edit config
nullhub api GET /api/instances/nullclaw/<n>/status --pretty
nullhub api GET /api/instances/nullclaw/<n>/cron --pretty
nullhub service install          # Register/start OS service (systemd/launchd)
nullhub service uninstall        # Remove OS service
nullhub service status           # Show OS service status
```

所有位置都使用 `{component}/{instance-name}` 格式来标识实例。

## 架构

**Zig 后端** -- HTTP 服务器、进程监管器、安装程序和清单引擎。
提供两种模式：服务器模式（HTTP + 监管线程）或 CLI 模式（直接调用、标准输出、退出）。

**Svelte 前端** -- 使用静态适配器的 SvelteKit，通过 `@embedFile` 嵌入
二进制文件。组件 UI 模块（聊天、监控）通过 Svelte 5
`mount()` 动态加载。

**清单驱动** -- 每个组件都会发布 `nullhub-manifest.json`，其中
描述安装、配置、启动、健康检查、向导步骤和
UI 模块。NullHub 是负责解释这些清单的通用引擎。

**存储** -- 所有状态都位于 `~/.nullhub/` 下（配置、实例、二进制文件、
日志、缓存的清单）。

**NullBoiler 代理** -- 发送到 `/api/nullboiler/*` 的请求会通过
`NULLBOILER_URL`（例如 `http://localhost:8080`）和可选的
`NULLBOILER_TOKEN` 反向代理到 NullBoiler 的 REST API。

**NullTickets 存储代理** -- 发送到 `/api/nulltickets/store/*` 的请求会通过
`NULLTICKETS_URL` 和可选的
`NULLTICKETS_TOKEN` 代理到 NullTickets。

**NullWatch 代理** -- 发送到 `/api/nullwatch/*` 的请求会反向代理到
安装在 NullHub 中的托管 NullWatch 实例。`NULLWATCH_URL` 仍可
将目标覆盖为外部 NullWatch 实例；设置 `NULLWATCH_TOKEN` 时，
它会覆盖托管实例的令牌。内置 NullWatch 页面使用此代理展示
运行摘要、跨度、评估、延迟、成本和故障上下文，
而不会将数据发送到托管服务。

本地 NullWatch 设置：

1. 启动 NullHub：

   ```bash
   zig build run -- serve --no-open
   ```

2. 在 Web UI 中打开 **Install Component**，选择 **NullWatch**，保留 API 端口或将其
   设置为 `7710`，然后完成向导。安装程序会启动
   NullWatch 实例，NullWatch 代理则会自动发现它。

**任务控制中心 API** -- 发送到 `/api/mission-control/*` 的请求会驱动
`/mission-control` 页面的确定性本地重放场景。它
不需要托管基础设施或模型密钥；当存在匹配的本地
实例时，会载入真实的 NullBoiler 工作流证据和 NullWatch 跟踪详情。
响应包含架构版本、场景 ID、确定性重放模式、控件、图、时间线、遥测、
NullWatch 风格的运行/跨度/评估跟踪引用，以及针对无效操作的
结构化冲突错误。该场景位于带版本的嵌入式重放固定数据
`src/core/mission_control/code_red.v1.json` 中；`zig build test` 会验证
固定数据的架构、引用、顺序、必需阶段、图链接和遥测阶段
覆盖范围。任务时间线中的跟踪链接会深度链接至 `/nullwatch?run_id=...`。
当托管 NullWatch 实例正在运行时，`/mission-control` 会通过 NullWatch
代理使用实时运行详情填充故障和恢复跟踪面板，并在跟踪链接中保留
选中的监控项。当托管 NullBoiler 实例拥有匹配的工作流证据时，
任务控制中心 API 会包含该实例名称，以及通过 NullBoiler 代理解析的
真实工作流运行链接和检查点元数据。
`GET /api/mission-control/replay` 会导出当前快照、源固定数据、恢复运行完成后的
故障与恢复重放产物并排比较，以及生态系统映射元数据，
形成可用于调试和审查的便携式 JSON 产物。`POST /api/mission-control/replay/save`
会将该产物存储在 `~/.nullhub/mission-control/replays/` 下；`GET
/api/mission-control/replays` 列出已保存的重放记录，`GET
/api/mission-control/replays/{id}` 则读回持久化产物。

### 任务控制中心重放

在本地启动 NullHub 并打开 `/mission-control`：

```bash
zig build run -- serve --host 127.0.0.1 --port 19802 --no-open
```

该页面提供 `Replay Mission`、`Reset`、`Launch Mission` 和
`Fork From Checkpoint` 控件。`Replay Mission` 可通过一次点击依次运行确定性重置、
启动、故障暂停、检查点分叉和恢复重放。时间线事件包含跟踪标签，
用于将重放映射回本地 NullWatch 风格的运行 ID、跨度 ID、操作和评估键。
页面还包含阶段里程碑，以及故障与恢复重放产物的对比
面板。

导出当前重放产物：

```bash
curl -fsS http://127.0.0.1:19802/api/mission-control/replay \
  -o mission-control-replay.json
```

任务控制中心的 `Save Replay` 按钮也提供相同的导出功能，
并会在服务器端写入一份持久化副本。
有关产物结构和生态系统映射，请参阅 `docs/mission-control.md`。

对已启动的服务器运行实时 API 冒烟测试：

```bash
NULLHUB_URL=http://127.0.0.1:19802 ./tests/test_mission_control_smoke.sh
```

## 开发

测试策略和路线图位于 [TESTING.md](TESTING.md)。

后端：

```bash
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
zig build test-integration -Dembed-ui=false -Dbuild-ui=false --summary all
```

前端：

```bash
cd ui && npm run dev
```

端到端：

```bash
./tests/test_e2e.sh
NULLHUB_URL=http://127.0.0.1:19802 ./tests/test_mission_control_smoke.sh
```

`zig build test-integration` 会针对在临时主目录中启动的真实 `nullhub`
进程运行结构化后端 HTTP 集成测试。

## 技术栈

- Zig 0.16.0
- Svelte 5 + SvelteKit（静态适配器）
- 基于 HTTP/1.1 的 JSON
- 用于实例日志流的 SSE
- 通过 `/api/nullboiler/runs/{id}/stream` API 轮询 NullBoiler 运行更新

## 项目布局

```
src/
  main.zig              # Entry: CLI dispatch or server start
  cli.zig               # CLI command parser & handlers
  server.zig            # HTTP server (API + static UI)
  auth.zig              # Optional bearer token auth
  api/                  # REST endpoints (components, instances, wizard, ...)
    nullboiler.zig      # Reverse proxy to NullBoiler workflow/run API
    nulltickets.zig     # Reverse proxy to NullTickets store API
    nullwatch.zig       # Reverse proxy to NullWatch tracing/eval API
    mission_control.zig # HTTP adapter for local mission replay commands
  core/                 # Manifest parser, state, platform, paths
    mission_control.zig # Local deterministic agent mission domain model
    mission_control_replay.zig # Typed replay fixture parser and validator
    mission_control/    # Embedded Mission Control replay fixtures
  installer/            # Download, build, UI module fetching
  supervisor/           # Process spawn, health checks, manager
ui/src/
  routes/               # SvelteKit pages
    nullboiler/         # NullBoiler pages (dashboard, workflows, runs)
    nulltickets/        # NullTickets pages (store)
    nullwatch/          # NullWatch Flight Recorder page
    mission-control/    # Local agent mission control room
  lib/components/       # Reusable Svelte components
    nullboiler/         # GraphViewer, StateInspector, RunEventLog, InterruptPanel,
                        # CheckpointTimeline, WorkflowJsonEditor, NodeCard, SendProgressBar
    nulltickets/        # NullTickets store selectors and controls
  lib/api/              # Typed API client
  lib/missionControl/   # Mission Control feature helpers
tests/
  test_e2e.sh           # End-to-end test script
docs/
  mission-control.md    # Mission Control replay and artifact contract
```
