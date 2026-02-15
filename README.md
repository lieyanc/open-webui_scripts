# Open WebUI Scripts

Open WebUI 的自动备份 + 更新脚本。

## 包含脚本

- **`pull-update-script.sh`** - 引导/自更新脚本，负责从仓库拉取最新版本的两个脚本
- **`update_open-webui.sh`** - 业务脚本，执行：备份（数据快照 + Postgres 逻辑备份）→ 拉取新镜像 → 重启 → 健康检查 → 轮转保留最近 N 个备份

## 快速开始

首次安装（一键）：

```bash
curl -fsSL https://raw.githubusercontent.com/lieyanc/open-webui_scripts/master/pull-update-script.sh | bash -s -- --install
```

后续更新脚本并执行：

```bash
./pull-update-script.sh --update --run
```

仅更新脚本、不执行：

```bash
./pull-update-script.sh --update
```

## 依赖

`docker`、`curl`、`rsync`、`zstd`、`flock`

## 配置

两个脚本均支持通过环境变量或 `.env` 文件覆盖默认配置，详见脚本内注释。

## 生产环境建议

1. 明确配置关键变量（尤其是 `DATA_DIR`、`HOST_PORT`、服务名）：

```bash
cat > .env <<'EOF'
DOCKER_COMPOSE_CMD=docker compose
SERVICE_WEBUI=open-webui
SERVICE_DB=postgres
DATA_DIR=/home/lieyan/open-webui/data
HOST_PORT=23995
HEALTH_PATH=/health
RETENTION=7
REQUIRE_DATA_DIR=1
EOF
```

2. 上线前先做预检（不执行更新）：

```bash
./update_open-webui.sh --check
```

3. 启用脚本完整性校验（要求仓库提供 `.sha256` 文件）：

```bash
curl -fsSL https://raw.githubusercontent.com/lieyanc/open-webui_scripts/master/pull-update-script.sh \
  | env REQUIRE_CHECKSUM=true bash -s -- --install
```

4. 修改脚本后同步更新哈希文件：

```bash
shasum -a 256 pull-update-script.sh | awk '{print $1"  pull-update-script.sh"}' > pull-update-script.sh.sha256
shasum -a 256 update_open-webui.sh | awk '{print $1"  update_open-webui.sh"}' > update_open-webui.sh.sha256
```

> 注意：`update_open-webui.sh` 会 `source .env`，请确保 `.env` 仅包含受信任内容。

## 恢复示例

### 恢复数据目录

将某个备份版本的 `data/` 同步回 `DATA_DIR`：

```bash
docker compose stop open-webui
rsync -aH --delete ./_backupsets/backup-YYYYmmdd-HHMMSS/data/ /home/lieyan/open-webui/data/
docker compose up -d open-webui
```

### 恢复 Postgres

建议先停 WebUI 避免写入：

```bash
docker compose stop open-webui

# 解压 dump 并拷进容器
zstd -d -c ./_backupsets/backup-YYYYmmdd-HHMMSS/db/postgres.dump.zst > /tmp/postgres.dump
docker compose cp /tmp/postgres.dump postgres:/tmp/postgres.dump

# 还原（会覆盖同名对象）
docker compose exec -T postgres sh -lc \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists /tmp/postgres.dump'

docker compose up -d open-webui
```

如需还原角色/权限等 globals（有自建角色时）：

```bash
zstd -d -c ./_backupsets/backup-YYYYmmdd-HHMMSS/db/postgres-globals.sql.zst \
  | docker compose exec -T postgres sh -lc 'psql -U "$POSTGRES_USER" -d postgres'
```
