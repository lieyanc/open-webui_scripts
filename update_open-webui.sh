#!/usr/bin/env bash
# update_openwebui_v2.sh
# 备份(数据快照+Postgres逻辑备份) -> 拉取新镜像 -> 重启 -> 健康检查 -> 仅保留最近3个版本
set -euo pipefail

cd "$(dirname "$0")"

log() { echo "[$(date +'%F %T')] $*"; }

# 防止并发执行（flock）
LOCK_FILE="${LOCK_FILE:-/tmp/update_open-webui.lock}"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "❌ 另一个实例正在运行（锁文件：${LOCK_FILE}），退出"
  exit 1
fi

need_bins=(docker curl rsync zstd)
for b in "${need_bins[@]}"; do
  command -v "$b" >/dev/null 2>&1 || { echo "缺少依赖：$b"; exit 1; }
done

# 自动加载 .env（如果存在）
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

### ===== 可配置项（都可用环境变量覆盖）=====
DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker compose}"

SERVICE_WEBUI="${SERVICE_WEBUI:-open-webui}"
SERVICE_DB="${SERVICE_DB:-postgres}"

HOST_PORT="${HOST_PORT:-23995}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

# 你的宿主机数据目录（按你 compose 里的 volumes）
DATA_DIR="${DATA_DIR:-/home/lieyan/open-webui/data}"

# （可选）rsync 排除文件（例如排除缓存、临时文件），不需要就留空
EXCLUDES_FILE="${EXCLUDES_FILE:-}"

# 备份根目录（脚本同目录下）
BACKUP_ROOT="${BACKUP_ROOT:-./_backupsets}"
RETENTION="${RETENTION:-3}"          # 只保留最近 N 个版本
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"        # zstd 压缩等级：1更快更小CPU；3折中；10更小更慢
PULL_DB="${PULL_DB:-0}"              # 1=也更新 postgres 镜像；0=只更新 open-webui
PRUNE_IMAGES="${PRUNE_IMAGES:-0}"    # 1=成功后 prune；0=不 prune（更利于回滚）
### ==========================================

TS="$(date +'%Y%m%d-%H%M%S')"
SET_DIR="${BACKUP_ROOT}/backup-${TS}"
BACKUP_COMPLETE=false

# 中断时清理不完整的备份目录
cleanup() {
  if ! $BACKUP_COMPLETE && [[ -d "${SET_DIR}" ]]; then
    log "⚠️ 中断，清理不完整的备份目录：${SET_DIR}"
    rm -rf "${SET_DIR}"
  fi
}
trap cleanup EXIT

# 先找上一个备份版本（用于硬链接增量），必须在创建新目录之前
LAST_SET="$(ls -1dt "${BACKUP_ROOT}"/backup-* 2>/dev/null | head -n1 || true)"

mkdir -p "${SET_DIR}/"{data,db,meta}

log "=== 开始：备份 + 更新 Open WebUI ==="
log "备份目录：${SET_DIR}"

# 0) 确保 DB 服务在（pg_dump 需要容器可用）
log "确保数据库服务已启动：${SERVICE_DB}"
$DOCKER_COMPOSE up -d "${SERVICE_DB}" >/dev/null

# 1) 数据目录：rsync 硬链接快照（增量、易恢复）
if [[ -d "${DATA_DIR}" ]]; then
  log "备份数据目录快照：${DATA_DIR} -> ${SET_DIR}/data"
  rsync_opts=(-aH --numeric-ids)

  if [[ -n "${EXCLUDES_FILE}" && -f "${EXCLUDES_FILE}" ]]; then
    rsync_opts+=(--exclude-from="${EXCLUDES_FILE}")
    log "使用排除规则：${EXCLUDES_FILE}"
  fi

  if [[ -n "${LAST_SET}" && -d "${LAST_SET}/data" ]]; then
    # 用绝对路径，避免 rsync link-dest 路径坑
    link_dest="$(realpath "${LAST_SET}/data")"
    rsync_opts+=(--link-dest="${link_dest}")
    log "启用增量硬链接（link-dest）：${link_dest}"
  else
    log "未找到上一版本快照，本次为全量快照"
  fi

  # 复制“内容”（注意尾部 /）
  rsync "${rsync_opts[@]}" "${DATA_DIR}/" "${SET_DIR}/data/"
else
  log "⚠️ 警告：未发现 DATA_DIR=${DATA_DIR}，跳过数据目录备份"
fi

# 2) Postgres：逻辑备份（推荐，比直接打包 pgdata 更一致）
log "备份 Postgres（pg_dump 自定义格式 + zstd 压缩）"
DB_DUMP="${SET_DIR}/db/postgres.dump.zst"
# 在容器内用环境变量 POSTGRES_USER/POSTGRES_DB，避免你在宿主机再配一遍
$DOCKER_COMPOSE exec -T "${SERVICE_DB}" sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  | zstd -T0 -"${ZSTD_LEVEL}" -o "${DB_DUMP}"

# （可选但推荐）备份全局对象（角色/权限等）。如果你只用默认单用户也能省略，但放着更稳。
log "备份 Postgres globals（角色/权限等）"
GLOBALS_DUMP="${SET_DIR}/db/postgres-globals.sql.zst"
# pg_dumpall --globals-only 输出 SQL，方便恢复
$DOCKER_COMPOSE exec -T "${SERVICE_DB}" sh -lc \
  'pg_dumpall -U "$POSTGRES_USER" --globals-only' \
  | zstd -T0 -"${ZSTD_LEVEL}" -o "${GLOBALS_DUMP}" || \
  log "⚠️ globals 备份失败（不影响主库 dump），如你没自建角色一般也没事"

# 3) 记录元信息（便于回滚排查）
{
  echo "timestamp=${TS}"
  echo "service_webui=${SERVICE_WEBUI}"
  echo "service_db=${SERVICE_DB}"
  echo "host_port=${HOST_PORT}"
  echo "data_dir=${DATA_DIR}"
  echo "webui_image=$($DOCKER_COMPOSE images "${SERVICE_WEBUI}" 2>/dev/null | tail -n +2 || true)"
  echo "db_image=$($DOCKER_COMPOSE images "${SERVICE_DB}" 2>/dev/null | tail -n +2 || true)"
  echo "container_webui_image=$(docker ps --filter "name=${SERVICE_WEBUI}" --format '{{.Image}}' || true)"
  echo "container_db_image=$(docker ps --filter "name=${SERVICE_DB}" --format '{{.Image}}' || true)"
} > "${SET_DIR}/meta/info.txt"

log "✅ 备份完成："
log " - 数据快照：${SET_DIR}/data"
log " - DB dump： ${DB_DUMP}"
log " - Globals： ${GLOBALS_DUMP}"
BACKUP_COMPLETE=true

# 4) 轮转：只保留最近 RETENTION 个版本
log "轮转备份：仅保留最近 ${RETENTION} 个版本"
if [[ -d "${BACKUP_ROOT}" ]]; then
  # 按时间倒序，删除第 RETENTION+1 之后的
  mapfile -t all_sets < <(ls -1dt "${BACKUP_ROOT}"/backup-* 2>/dev/null || true)
  if (( ${#all_sets[@]} > RETENTION )); then
    for old in "${all_sets[@]:RETENTION}"; do
      log "删除旧备份：${old}"
      rm -rf "${old}"
    done
  fi
fi

# 5) 拉取新镜像
log "拉取新镜像：${SERVICE_WEBUI}"
$DOCKER_COMPOSE pull "${SERVICE_WEBUI}"

if [[ "${PULL_DB}" == "1" ]]; then
  log "同时拉取数据库镜像：${SERVICE_DB}"
  $DOCKER_COMPOSE pull "${SERVICE_DB}"
fi

# 6) 滚动更新/重启 WebUI
log "启动/更新服务：${SERVICE_WEBUI}"
$DOCKER_COMPOSE up -d "${SERVICE_WEBUI}"

# 7) 健康检查
log "健康检查（最多等待 ${HEALTH_TIMEOUT}s）：http://127.0.0.1:${HOST_PORT}${HEALTH_PATH}"
HEALTH_OK=0
DEADLINE=$(( $(date +%s) + HEALTH_TIMEOUT ))

while [[ $(date +%s) -lt $DEADLINE ]]; do
  if curl -fsS "http://127.0.0.1:${HOST_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
    HEALTH_OK=1; break
  fi
  if [[ "${HEALTH_PATH}" != "/" ]] && curl -fsS "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
    HEALTH_OK=1; break
  fi
  sleep 3
done

if [[ "${HEALTH_OK}" -ne 1 ]]; then
  log "❌ 健康检查失败！输出最近日志："
  $DOCKER_COMPOSE logs --tail=200 "${SERVICE_WEBUI}" || true
  log ""
  log "你已经有可用备份（${SET_DIR}）。建议回滚方式："
  log "1) 先停止：  $DOCKER_COMPOSE down"
  log "2) 用备份恢复数据+数据库（见 README.md 中的「恢复示例」）"
  exit 1
fi

log "✅ 健康检查通过"

# 8) 可选清理镜像（默认不做，方便回滚）
if [[ "${PRUNE_IMAGES}" == "1" ]]; then
  log "清理无用镜像（image prune）"
  docker image prune -f || true
else
  log "跳过 image prune（如需开启：PRUNE_IMAGES=1）"
fi

log "=== 完成：Open WebUI 已更新，备份已保留最近 ${RETENTION} 个版本 ==="

