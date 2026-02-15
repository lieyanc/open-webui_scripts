#!/usr/bin/env bash
# pull-update-script.sh
# 安装/更新 "update_open-webui.sh"；并可自更新本脚本
# 用法（在线安装/更新）：
#   curl -fsSL https://raw.githubusercontent.com/lieyanc/open-webui_scripts/master/pull-update-script.sh | bash -s -- --install
#   curl -fsSL <raw>/pull-update-script.sh | bash -s -- --update --run
# 本地已下载后：
#   ./pull-update-script.sh --update
#   ./pull-update-script.sh --run
#
set -euo pipefail

die() { echo "❌ $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
path_abs() {
  local p="$1"
  if have_cmd realpath; then
    realpath "$p"
    return
  fi
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$p"
    return
  fi
  local dir base
  dir="$(cd "$(dirname "$p")" && pwd -P)"
  base="$(basename "$p")"
  echo "${dir}/${base}"
}

### ===== 可配置项（可通过环境变量覆盖） =====
# GitHub 仓库 Raw 基础前缀（末尾不要带斜杠）
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/lieyanc/open-webui_scripts/master}"

# 两个脚本在仓库中的文件名
PULL_NAME="${PULL_NAME:-pull-update-script.sh}"          # 本脚本文件名（用于自更新）
UPDATE_NAME="${UPDATE_NAME:-update_open-webui.sh}"       # 业务更新脚本文件名

# 安装/放置目录（应与 docker-compose.yml 同级）
DEST_DIR="${DEST_DIR:-$HOME/open-webui}"

# 业务更新脚本安装路径
UPDATE_DST="${UPDATE_DST:-$DEST_DIR/$UPDATE_NAME}"

# 本脚本（自更新）目标路径（一般放同目录）
SELF_DST="${SELF_DST:-$DEST_DIR/$PULL_NAME}"

# 业务脚本安装后是否自动赋权
UPDATE_MODE="${UPDATE_MODE:-0755}"
SELF_MODE="${SELF_MODE:-0755}"

# 业务脚本安装后是否**立即执行更新**（也可通过 --run 开启）
AUTO_RUN_AFTER_UPDATE="${AUTO_RUN_AFTER_UPDATE:-false}"
### =========================================

# 解析参数
DO_INSTALL=false
DO_UPDATE=false
DO_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=true; shift ;;
    --update)  DO_UPDATE=true; shift ;;
    --run)     DO_RUN=true; shift ;;
    -h|--help)
      cat <<'EOF'
用法:
  pull-update-script.sh [--install] [--update] [--run]

说明:
  --install  首次安装：创建目录、拉取两个脚本并赋权（含自更新）
  --update   更新：拉取并替换本脚本与 update_open-webui.sh
  --run      在完成安装/更新后，立即执行 update_open-webui.sh

环境变量(可覆盖默认):
  REPO_RAW_BASE, PULL_NAME, UPDATE_NAME, DEST_DIR, UPDATE_DST, SELF_DST
  UPDATE_MODE, SELF_MODE, AUTO_RUN_AFTER_UPDATE

示例:
  curl -fsSL <RAW>/pull-update-script.sh | bash -s -- --install
  ./pull-update-script.sh --update --run
EOF
      exit 0
      ;;
    *)
      echo "未知参数：$1（使用 --help 查看）"; exit 2 ;;
  esac
done

# 若无参数，默认等价于：--update
if ! $DO_INSTALL && ! $DO_UPDATE; then
  DO_UPDATE=true
fi

# 若同时指定 install + update，安装流程已包含更新，避免重复下载/覆盖
if $DO_INSTALL && $DO_UPDATE; then
  echo "ℹ️ 同时指定 --install 和 --update：安装流程已包含更新，跳过重复更新步骤"
  DO_UPDATE=false
fi

need_bins=(curl install mktemp)
for b in "${need_bins[@]}"; do
  have_cmd "$b" || die "缺少依赖命令：$b"
done

mkdir -p "$DEST_DIR"

# 工具函数：下载 + 原子替换
download_and_install() {
  local url="$1" dst="$2" mode="$3"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"

  install -m "$mode" "$tmp" "$dst"
  rm -f "$tmp"
  echo "✅ 已更新 $(basename "$dst") -> ${dst}"
}

# 自更新：用仓库中的版本覆盖当前脚本目标路径（SELF_DST）
self_update() {
  local self_url="$REPO_RAW_BASE/$PULL_NAME"
  download_and_install "$self_url" "$SELF_DST" "$SELF_MODE"

  # 如果当前执行路径不是目标路径，提示之后从目标路径重新执行更稳妥
  local current current_abs self_abs
  current="${BASH_SOURCE[0]:-$0}"
  if [[ "$current" != /* ]] && have_cmd "$current"; then
    current="$(command -v "$current")"
  fi
  current_abs="$(path_abs "$current")"
  self_abs="$(path_abs "$SELF_DST")"
  if [[ "$self_abs" != "$current_abs" ]]; then
    echo "ℹ️ 提示：当前执行文件不是安装目标（${SELF_DST}），后续请从 ${SELF_DST} 运行。"
  fi
}

# 安装/更新 业务更新脚本
update_business_script() {
  local update_url="$REPO_RAW_BASE/$UPDATE_NAME"
  download_and_install "$update_url" "$UPDATE_DST" "$UPDATE_MODE"
}

# 首次安装
if $DO_INSTALL; then
  echo "== 安装到目录：$DEST_DIR =="
  self_update
  update_business_script
fi

# 常规更新（含自更新 & 业务脚本）
if $DO_UPDATE; then
  echo "== 开始更新 =="
  self_update
  update_business_script
fi

# 需要执行更新脚本？
if $DO_RUN || { [[ "$AUTO_RUN_AFTER_UPDATE" == "true" ]] && ($DO_INSTALL || $DO_UPDATE); }; then
  echo "== 执行业务更新脚本：$UPDATE_DST =="
  exec "$UPDATE_DST"
fi

echo "🎉 完成。脚本在：${SELF_DST}；业务更新脚本在：${UPDATE_DST}"
