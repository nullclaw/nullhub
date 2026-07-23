# NullHub

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md)

[NullClaw](https://github.com/nullclaw/nullclaw) をインストール、設定、管理する
最もシンプルな方法です。

NullClaw エコシステムの管理ハブです。

`NullHub` は Svelte Web UI を組み込んだ単一の Zig バイナリで、
エコシステムの各コンポーネント（NullClaw、NullBoiler、NullTickets、NullWatch）を
インストール、設定、監視、更新できます。

## 機能

- **インストールウィザード** -- マニフェスト駆動のガイド付きセットアップ、コンポーネントを認識するフロー、ローカルの `NullTickets -> NullBoiler` 連携
- **プロセス監視** -- 起動、停止、再起動、バックオフを使ったクラッシュ復旧
- **ヘルス監視** -- 定期的な HTTP ヘルスチェックとダッシュボードのステータスカード
- **コンポーネント間連携** -- `NullTickets -> NullBoiler` を自動接続し、ネイティブのトラッカー設定を生成して、1 つの UI からキューとオーケストレーターの状態を確認
- **設定管理** -- `NullClaw`、`NullBoiler`、`NullTickets`、`NullWatch` 用の構造化エディターと、必要に応じて直接編集できる生の JSON
- **ログ表示** -- インスタンスごとの末尾ログ表示とリアルタイム SSE ストリーミング
- **ワンクリック更新** -- ダウンロード、設定移行、失敗時のロールバック
- **マルチインスタンス** -- 同じコンポーネントの複数インスタンスを並行実行
- **Web UI + CLI** -- 人向けのブラウザーダッシュボードと、自動化向けの CLI
- **管理対象インスタンス管理 API** -- 管理対象の NullClaw インストールに対する、インスタンス単位のステータス、設定、モデル、cron、チャンネル、スキルの各ルート
- **NullBoiler UI** -- ワークフローエディター、ポーリング式の実行監視、チェックポイントのフォーク、エンコードされたワークフロー/実行リンク
- **NullTickets ストア** -- NullHub を介して NullTickets にプロキシされるキーバリューストアブラウザー
- **NullWatch フライトレコーダー** -- NullHub プロキシを介したローカル NullWatch の実行概要、スパンタイムライン、評価結果、トークン使用量、コスト、エラーコンテキスト
- **ミッションコントロール** -- ワークフロー実行、役割ベースのエージェント、障害、チェックポイント復旧、永続的なリプレイ保存、ライブテレメトリを 1 画面にまとめた、ローカルファーストのエージェントミッションリプレイ

## クイックスタート

```bash
zig build
./zig-out/bin/nullhub
```

ブラウザーで [http://nullhub.localhost:19800](http://nullhub.localhost:19800) が開きます。
生成されるバイナリにはビルド済みの Web UI が含まれるため、実行時の
`ui/build` ディレクトリには依存しなくなりました。

ローカルアクセスの優先順：

- `http://nullhub.local:19800`
- `http://nullhub.localhost:19800`
- `http://127.0.0.1:19800`

利用できる場合、`nullhub` は `nullhub.local` を `dns-sd`/Bonjour または
`avahi-publish` で公開しようとします。利用できない場合は
`nullhub.localhost`、最後に `127.0.0.1` へフォールバックします。

### 実行時の前提条件

- リリースとバイナリの取得には `curl` が必要です。
- UI モジュールバンドルの展開には `tar` が必要です。

### ビルドの前提条件

- ビルドには `npm` が必要です。これには `zig build` と Svelte UI を組み込むすべてのビルドが含まれます。
- バックエンドのみのテストは、`zig build test -Dembed-ui=false -Dbuild-ui=false` を使えば UI アセットなしで実行できます。

これらのツールがない場合、`nullhub` は利用可能なシステムパッケージマネージャー
（`apt`、`dnf`、`yum`、`pacman`、`zypper`、
`apk`、`brew`、`winget`、`choco`）を使って自動インストールを試みます。

## CLI の使い方

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

インスタンスの指定には、すべての場所で `{component}/{instance-name}` 形式を使用します。

## アーキテクチャ

**Zig バックエンド** -- HTTP サーバー、プロセススーパーバイザー、インストーラー、マニフェストエンジン。
サーバー（HTTP + スーパーバイザースレッド）と CLI（直接呼び出し、標準出力、終了）の 2 つのモードがあります。

**Svelte フロントエンド** -- 静的アダプターを使用した SvelteKit で、`@embedFile` により
バイナリへ組み込まれます。コンポーネント UI モジュール（チャット、モニター）は Svelte 5 の
`mount()` を使って動的に読み込まれます。

**マニフェスト駆動** -- 各コンポーネントは `nullhub-manifest.json` を公開し、
インストール、設定、起動、ヘルスチェック、ウィザードの手順、
UI モジュールを記述します。NullHub はマニフェストを解釈する汎用エンジンです。

**ストレージ** -- すべての状態は `~/.nullhub/` 配下に保存されます（設定、インスタンス、バイナリ、
ログ、キャッシュ済みマニフェスト）。

**NullBoiler プロキシ** -- `/api/nullboiler/*` へのリクエストは、
`NULLBOILER_URL`（例：`http://localhost:8080`）と任意の
`NULLBOILER_TOKEN` を使い、NullBoiler の REST API へリバースプロキシされます。

**NullTickets ストアプロキシ** -- `/api/nulltickets/store/*` へのリクエストは、
`NULLTICKETS_URL` と任意の
`NULLTICKETS_TOKEN` を使って NullTickets へプロキシされます。

**NullWatch プロキシ** -- `/api/nullwatch/*` へのリクエストは、
NullHub にインストールされた管理対象の NullWatch インスタンスへリバースプロキシされます。
`NULLWATCH_URL` で外部 NullWatch インスタンスを引き続き指定でき、
`NULLWATCH_TOKEN` を設定すると管理対象インスタンスのトークンを上書きします。
組み込みの NullWatch ページはこのプロキシを使い、ホスト型サービスへデータを送信せずに
実行概要、スパン、評価、レイテンシ、コスト、障害コンテキストを表示します。

ローカル NullWatch のセットアップ：

1. NullHub を起動します。

   ```bash
   zig build run -- serve --no-open
   ```

2. Web UI で **Install Component** を開き、**NullWatch** を選択し、API ポートを
   `7710` のままにするか設定して、ウィザードを完了します。インストーラーが
   NullWatch インスタンスを起動し、NullWatch プロキシが自動的に検出します。

**ミッションコントロール API** -- `/api/mission-control/*` へのリクエストは、
`/mission-control` ページの決定論的なローカルリプレイシナリオを操作します。
ホスト型インフラやモデルのシークレットは不要で、対応するローカルインスタンスが
利用可能な場合は、実際の NullBoiler ワークフロー証拠と NullWatch トレース詳細を取り込みます。
レスポンスには、スキーマバージョン、シナリオ ID、決定論的リプレイモード、コントロール、
グラフ、タイムライン、テレメトリ、NullWatch 形式の実行/スパン/評価トレース参照、
無効な操作に対する構造化された競合エラーが含まれます。シナリオはバージョン管理された
組み込みリプレイフィクスチャ `src/core/mission_control/code_red.v1.json` にあり、
`zig build test` はフィクスチャのスキーマ、参照、順序、必須フェーズ、グラフリンク、
テレメトリのフェーズ網羅性を検証します。ミッションタイムラインのトレースリンクは
`/nullwatch?run_id=...` へディープリンクします。
管理対象の NullWatch インスタンスが実行中の場合、`/mission-control` は NullWatch
プロキシを介したライブ実行詳細から障害と復旧のトレースパネルを構成し、
選択中の監視対象をトレースリンクに保持します。管理対象の NullBoiler インスタンスに
一致するワークフロー証拠がある場合、ミッションコントロール API は、そのインスタンス名に加えて、
NullBoiler プロキシを通じて解決された実際のワークフロー実行リンクとチェックポイントメタデータを含めます。
`GET /api/mission-control/replay` は現在のスナップショット、ソースフィクスチャ、
復旧済みの実行が完了した後の失敗/復旧リプレイ成果物の横並び比較、
エコシステムのマッピングメタデータを、デバッグとレビューに利用できる
ポータブルな JSON 成果物としてエクスポートします。`POST /api/mission-control/replay/save` は
その成果物を `~/.nullhub/mission-control/replays/` に保存します。`GET
/api/mission-control/replays` は保存済みリプレイレコードを一覧表示し、`GET
/api/mission-control/replays/{id}` は永続化された成果物を読み戻します。

### ミッションコントロールのリプレイ

NullHub をローカルで起動し、`/mission-control` を開きます。

```bash
zig build run -- serve --host 127.0.0.1 --port 19802 --no-open
```

このページには `Replay Mission`、`Reset`、`Launch Mission`、
`Fork From Checkpoint` の各コントロールがあります。`Replay Mission` は 1 回のクリックで、
決定論的なリセット、起動、障害での待機、チェックポイントのフォーク、復旧リプレイを
順に実行します。タイムラインイベントには、リプレイをローカルの NullWatch 形式の
実行 ID、スパン ID、操作、評価キーへ対応付けるトレースチップが含まれます。
このページにはフェーズのマイルストーンと、失敗/復旧リプレイ成果物の比較
パネルもあります。

現在のリプレイ成果物をエクスポートします。

```bash
curl -fsS http://127.0.0.1:19802/api/mission-control/replay \
  -o mission-control-replay.json
```

同じエクスポートはミッションコントロールの `Save Replay` ボタンからも利用でき、
サーバー側へ永続的なコピーも書き込みます。
成果物の形式とエコシステムのマッピングについては `docs/mission-control.md` を参照してください。

起動済みのサーバーに対してライブ API スモークテストを実行します。

```bash
NULLHUB_URL=http://127.0.0.1:19802 ./tests/test_mission_control_smoke.sh
```

## 開発

テスト戦略とロードマップは [TESTING.md](TESTING.md) にあります。

バックエンド：

```bash
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
zig build test-integration -Dembed-ui=false -Dbuild-ui=false --summary all
```

フロントエンド：

```bash
cd ui && npm run dev
```

エンドツーエンド：

```bash
./tests/test_e2e.sh
NULLHUB_URL=http://127.0.0.1:19802 ./tests/test_mission_control_smoke.sh
```

`zig build test-integration` は、一時ホームディレクトリで起動した実際の
`nullhub` プロセスに対して、構造化されたバックエンド HTTP 統合テストを実行します。

## 技術スタック

- Zig 0.16.0
- Svelte 5 + SvelteKit（静的アダプター）
- HTTP/1.1 上の JSON
- インスタンスログのストリーミングに SSE を使用
- `/api/nullboiler/runs/{id}/stream` API を介した、ポーリング方式の NullBoiler 実行更新

## プロジェクト構成

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
