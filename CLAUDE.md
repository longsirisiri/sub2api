# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在本仓库中工作时提供指导。

## 交流语言

与用户交流一律使用中文（代码注释除外，代码注释按代码库惯例处理，通常为英文）。

## Fork 背景

本仓库是一个 fork，有两个远程仓库：

- `origin` —— 本项目自己的 GitHub 仓库（功能开发推送到这里）
- `upstream` → `https://github.com/Wei-Shaw/sub2api.git`（原始开源项目）

在本仓库工作时的目标：落地项目自身的定制改动，同时不要偏离上游太远，以免日后同步 `upstream/main` 时冲突过多。具体做法：

- 尽量把定制内容隔离出来（新增文件、增量配置、feature flag），而不是就地重写上游共享逻辑——这样下次同步 `upstream/main` 时冲突最少。
- 同步上游：`git fetch upstream && git rebase upstream/main`（或 `merge`，视当前分支策略而定）——完整流程和已知坑点见 `DEV_GUIDE.md`。
- `DEV_GUIDE.md`（仓库根目录）持续记录本 fork 运行/扩展过程中的环境配置、CI 坑点和问题复盘——排查环境问题前先看这个文档，发现新坑点也要补充进去。
- Go module 路径和 import 前缀在 fork 中仍然是 `github.com/Wei-Shaw/sub2api`，不要随意改名——否则会导致每个上游文件都产生合并冲突。

## 常用命令

### 后端（`backend/`，Go 1.25.7）

```bash
go run ./cmd/server                # 开发服务器（需要 config.yaml，见 README「Build from Source」）
go build -tags embed -o sub2api ./cmd/server   # 生产构建，内嵌前端

go test ./...                      # 全部测试 + vet
go test -tags=unit ./...           # 仅单元测试
go test -tags=integration ./...    # 集成测试（需要 Postgres/Redis，见 docker compose）
go test -tags=e2e -v -timeout=300s ./internal/integration/...  # 本地 e2e
./scripts/e2e-test.sh              # 脚本化 e2e

golangci-lint run ./...            # 需 v2.7 版本，与 CI 保持一致，见 backend/.golangci.yml

# 运行单个测试
go test -tags=unit ./internal/service/ -run TestGatewayServiceXxx -v
```

根目录 `Makefile` 封装了以上命令：`make build`、`make test`（前后端）、`make test-backend`。

### Ent schema 与 Wire DI（改动后需重新生成）

```bash
cd backend
go generate ./ent           # 修改 ent/schema/*.go 后执行
go generate ./cmd/server    # 修改 wire.go 中的 provider set 后执行
```

`ent/` 和 `cmd/server/wire_gen.go` 都是生成代码且已提交入库——修改 schema/wire 后要一并重新生成并提交，禁止手动编辑生成文件。

### 数据库迁移（`backend/migrations/`）

- 顺序编号的 SQL 文件：`NNN_description.sql`，由自研 runner（`internal/repository/migrations_runner.go`）在事务中执行。
- 涉及 `CREATE/DROP INDEX CONCURRENTLY` 时文件名必须加 `_notx.sql` 后缀——这类文件不在事务内执行，按语句逐条执行，且只能包含幂等的（`IF [NOT] EXISTS`）并发索引语句，不能混入其他内容。
- **不可变原则**：迁移一旦在任意环境执行过，禁止再修改——校验和记录在 `schema_migrations` 表中。有新需求就新增一个迁移文件。
- 没有 down 迁移；runner 不解析 Up/Down 分段。

### 前端（`frontend/`，Vue 3 + Vite，**只用 pnpm** —— `.npmrc`/lockfile 不一致会导致 CI 失败）

```bash
pnpm install
pnpm dev                # 热重载开发
pnpm run build           # vue-tsc -b && vite build；产物输出到 ../backend/internal/web/dist/
pnpm run lint:check       # eslint，不自动修复（CI 用）
pnpm run typecheck        # vue-tsc --noEmit
pnpm test:run             # vitest run
```

## 架构

### 分层由 lint 强制约束，而非仅靠约定

`backend/.golangci.yml` 中的 `depguard` 规则会让违反分层规则直接构建失败，而不只是风格提示：

- `internal/service/**` 禁止 import `internal/repository`、`gorm.io/gorm`、`redis/go-redis`（少数 `ops_*` 文件例外）。
- `internal/handler/**` 禁止 import `internal/repository`。

依赖方向和包名给人的直觉是相反的：`service` 定义自己需要的 repository 接口，`internal/repository` 反过来 import `internal/service` 去实现这些接口。所有部件通过 [google/wire](https://github.com/google/wire) 在 `backend/cmd/server/wire.go` 中组装（provider set 包括：`config`、`repository`、`service`、`securityaudit`、`payment`、`middleware`、`handler`、`server`）。给 service 新增数据访问依赖时，应在 `service` 包里定义接口，由 `repository` 去实现——不要在 service 里直接使用 `ent`/gorm/redis。

### 网关（Gateway）是核心业务逻辑

Sub2API 的核心工作是：接收多种协议格式（Anthropic Messages、OpenAI Chat Completions/Responses、Gemini）的 API 请求，从账号池中挑选一个可用的上游账号，转发/转换请求，计费 token 用量，并把响应流式返回给客户端。这部分逻辑几乎全部集中在 `internal/service` 和 `internal/handler` 里，靠文件名前缀而非子包来组织：

- `gateway_*.go` —— Anthropic/Claude 格式的入口和透传（`/v1/messages`，含 Bedrock/Vertex 变体）
- `openai_gateway_*.go` —— OpenAI 兼容入口（Chat Completions、Responses、Codex CLI WebSocket 桥接、Grok/xAI 转换）
- `antigravity_gateway_*.go` —— Antigravity 专属的 Claude/Gemini 端点及混合调度

各上游协议相关的辅助逻辑（OAuth、请求/响应转换、TLS/客户端指纹）放在 `internal/pkg/{claude,gemini,geminicli,openai,xai,antigravity,googleapi,anthropicfp}` 下。路由注册在 `internal/server/routes/` 中做了同样的划分（`gateway.go`、`admin.go`、`auth.go`、`payment.go`、`user.go`、`model_plaza.go`）。

由于账号选择、故障转移、计费、流式处理这些逻辑大多不是按子包边界划分的，在 `internal/service` 中定位代码时，优先按文件名前缀检索（`gateway_*`、`openai_gateway_*`、`account_*`、`admin_*`），而不是靠翻目录。

### 其他结构性说明

- `RUN_MODE=simple` 会去掉 SaaS/计费相关的界面和流程，用于单人部署场景；新功能如果涉及计费或多租户假设，要考虑这个模式的兼容性。
- 前端 `pnpm run build` 的产物通过 `embed` build tag 内嵌进 Go 二进制，从 `backend/internal/web/dist/` 提供服务；前端改动在重新执行这个构建步骤之前，不会体现在内嵌构建产物里。
- `openspec/` 存放规格驱动（spec-driven）的变更提案（proposal → design → spec → tasks → verification）,用于较大的功能改动；如果所涉及的领域已有对应目录，可参考 `openspec/changes/*/README.md` 中的文档链路。
