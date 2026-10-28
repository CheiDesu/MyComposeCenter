#!/usr/bin/env bash
# =============================================================================
# ccenter —— Compose 一键备份 / 恢复中心
#   备份快照 · 查看删除 · 一键恢复 · 配置 · 状态日志 · 校验导出
#   设计稿：compose-backup-center-design.md
#   要求：在 Docker 宿主机上以 root 运行（需要访问 docker 与 /var/lib/docker）
# =============================================================================
set -uo pipefail

VERSION="1.1.0"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# ---------- 颜色 ----------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'; B=$'\033[1m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""; B=""
fi

# ---------- 进度显示 ----------
PB_ON=0; PB_TOTAL=1; PB_CUR=0
list_has() { # $1=逗号分隔列表 $2=值
  local IFS=',' x; for x in $1; do [ "$x" = "$2" ] && return 0; done; return 1
}
progress_begin() { PB_ON=1; PB_CUR=0; PB_TOTAL="${1:-1}"; [ "$PB_TOTAL" -lt 1 ] && PB_TOTAL=1; progress_render "${2:-}"; }
progress_render() { # $1=当前说明
  [ "$PB_ON" = "1" ] || return 0
  local pct=$(( PB_CUR * 100 / PB_TOTAL )) width=20 fill k bar=""
  [ "$pct" -gt 100 ] && pct=100
  fill=$(( pct * width / 100 ))
  for ((k=0;k<width;k++)); do if [ "$k" -lt "$fill" ]; then bar+="█"; else bar+="░"; fi; done
  if [ -t 2 ]; then printf '\r  %s[%s] %3d%%%s  %s\033[K' "$C_B" "$bar" "$pct" "$C_0" "${1:-}" >&2
  else printf '  [%d/%d] %s\n' "$PB_CUR" "$PB_TOTAL" "${1:-}" >&2; fi
}
progress_step() { PB_CUR=$((PB_CUR+1)); progress_render "${1:-}"; }
progress_end() { if [ "$PB_ON" = "1" ]; then PB_ON=0; [ -t 2 ] && printf '\r\033[K' >&2; fi; }

# ---------- 默认配置 ----------
ROOT="${CCENTER_ROOT:-$SCRIPT_DIR}"     # 备份根目录：默认脚本所在文件夹
AUTO_ENABLED=1
AUTO_INTERVAL=12                        # 小时
MAX_SIZE="10G"
MIN_KEEP=2
COMPRESS="zstd"                         # zstd | gzip
CONSISTENCY="online"                  # quiesced | online | ask
INCLUDE_BIND=0
BIND_PROJECTS="dsh-compose"             # 自动备份时即使 include_bind=0 也强制打包 bind 的项目（逗号分隔）
INCLUDE_IMAGES=0
AUTO_PROJECTS="all"                     # all | 逗号分隔项目名
RETENTION="recent"                      # recent | daily
EXPORT_TARGET=""

CONFIG_FILE=""
LOG_DIR=""
LOG_FILE=""
SNAP_DIR=""
INDEX_FILE=""
LOCK_FILE=""

DOCKER_ROOT=""
HOSTNAME_S="$(hostname 2>/dev/null || echo unknown)"
PROG="ccenter"

# =============================================================================
# 基础工具
# =============================================================================
init_paths() {
  CONFIG_FILE="$ROOT/config.ini"
  LOG_DIR="$ROOT/logs"
  SNAP_DIR="$ROOT/snapshots"
  INDEX_FILE="$ROOT/index.json"
  LOCK_FILE="$ROOT/.lock"
  LOG_FILE="$LOG_DIR/$PROG-$(date +%Y%m%d).log"
  mkdir -p "$ROOT" "$LOG_DIR" "$SNAP_DIR" 2>/dev/null
  fix_perms "$ROOT" "$LOG_DIR" "$SNAP_DIR"
}

# 该 NAS 的 btrfs(trimacl) 会让 root 新建文件变成 000，统一补回可预期权限
fix_perms() { local p; for p in "$@"; do [ -e "$p" ] && chmod 755 "$p" 2>/dev/null || true; done; }
fix_files() { local p; for p in "$@"; do [ -e "$p" ] && chmod 644 "$p" 2>/dev/null || true; done; }

log() {  # log <级别> <文本...>
  local lv="$1"; shift
  local msg="$*"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s [%s] %s\n' "$ts" "$lv" "$msg" >>"$LOG_FILE" 2>/dev/null
  case "$lv" in
    ERROR) printf '%s%s%s %s\n' "$C_R" "✗" "$C_0" "$msg" ;;
    WARN)  printf '%s%s%s %s\n' "$C_Y" "!" "$C_0" "$msg" ;;
    OK)    printf '%s%s%s %s\n' "$C_G" "✓" "$C_0" "$msg" ;;
    *)     printf '%s\n' "$msg" ;;
  esac
}

die() { log ERROR "$*"; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || die "需要 root 权限运行（sudo $PROG）"
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "找不到 docker 命令"
  docker info >/dev/null 2>&1 || die "docker 不可用（daemon 没起或当前用户无权限）"
  DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  [ -n "$DOCKER_ROOT" ] || DOCKER_ROOT="/var/lib/docker"
}

# 首次运行前检查依赖，缺什么直接说清楚怎么装
need_tools() {
  local miss=""
  local t
  for t in tar jq flock sha256sum; do
    command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
  done
  case "${COMPRESS:-zstd}" in
    zstd) command -v zstd >/dev/null 2>&1 || miss="$miss zstd";;
    gzip) command -v gzip >/dev/null 2>&1 || miss="$miss gzip";;
    *)    miss="$miss zstd/gzip";;
  esac
  if [ -n "$miss" ]; then
    die "缺少依赖：$miss
 Debian/Ubuntu: sudo apt install tar jq util-linux zstd
 CentOS/OpenWrt/NAS: 一般已自带，缺 zstd 可用 apt/opkg 安装，或把 compress 改成 gzip"
  fi
}

human_size() {  # bytes -> 人类可读
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB",u," "); i=1;
    while (b>=1024 && i<6){b/=1024;i++}
    printf (i==1?"%d %s":"%.1f %s"), b, u[i]
  }'
}

parse_size() {  # 10G -> bytes
  local s="${1:-0}"
  case "$s" in
    *[kK]) echo $(( ${s%[kK]} * 1024 )) ;;
    *[mM]) echo $(( ${s%[mM]} * 1024 * 1024 )) ;;
    *[gG]) echo $(( ${s%[gG]} * 1024 * 1024 * 1024 )) ;;
    *[tT]) echo $(( ${s%[tT]} * 1024 * 1024 * 1024 * 1024 )) ;;
    *) echo "$s" ;;
  esac
}

ask_yes() {  # ask_yes "问题" [默认 y/n]
  local q="$1" def="${2:-n}" ans hint=""
  [ "$def" = "y" ] && hint="[Y/n]" || hint="[y/N]"
  printf '%s %s ' "$q" "$hint"
  read -r ans || ans=""
  [ -z "$ans" ] && ans="$def"
  case "$ans" in y|Y|yes|YES|是) return 0 ;; *) return 1 ;; esac
}

section() { printf '\n%s%s== %s ==%s\n' "$B" "$C_B" "$*" "$C_0"; }

# =============================================================================
# 配置读写
# =============================================================================
load_config() {
  init_paths
  if [ ! -f "$CONFIG_FILE" ]; then
    save_config
    log INFO "首次运行：已生成带注释的配置 $CONFIG_FILE（不改也能直接用）"
  fi
  if [ -f "$CONFIG_FILE" ]; then
    chmod 644 "$CONFIG_FILE" 2>/dev/null || true
    while IFS='=' read -r k v; do
      [ -z "$k" ] && continue
      case "$k" in \#*) continue ;; esac
      v="${v%$'\r'}"
      case "$k" in
        root) ROOT="$v";;
        auto_enabled) AUTO_ENABLED="$v";;
        auto_interval) AUTO_INTERVAL="$v";;
        max_size) MAX_SIZE="$v";;
        min_keep) MIN_KEEP="$v";;
        compress) COMPRESS="$v";;
        consistency) CONSISTENCY="$v";;
        include_bind) INCLUDE_BIND="$v";;
        bind_projects) BIND_PROJECTS="$v";;
        include_images) INCLUDE_IMAGES="$v";;
        auto_projects) AUTO_PROJECTS="$v";;
        retention) RETENTION="$v";;
        export_target) EXPORT_TARGET="$v";;
      esac
    done <"$CONFIG_FILE"
    # 老配置文件缺少新键时自动补一行（不动用户已有值）
    if ! grep -q '^[[:space:]]*bind_projects=' "$CONFIG_FILE" 2>/dev/null; then
      printf '\n# 自动备份时，即使 include_bind=0，也强制打包 bind 的项目（逗号分隔，如 dsh-compose）。\nbind_projects=%s\n' "$BIND_PROJECTS" >>"$CONFIG_FILE"
    fi
  fi
  init_paths
  export CCENTER_ROOT="$ROOT"
}

save_config() {
  init_paths
  {
    echo "# ============================================================================="
    echo "# ccenter 配置文件（自动生成）。改完保存即可，下次运行时生效。"
    echo "# 格式：键=值；以 # 开头的是注释，可以整行删除。"
    echo "# ============================================================================="
    echo
    echo "# 备份根目录：快照、日志、索引都放在这里。默认 = 脚本所在目录；也可换成独立磁盘路径。"
    echo "root=$ROOT"
    echo
    echo "# 自动备份开关：1=开启，0=关闭（仅影响定时任务，手动备份不受影响）。"
    echo "auto_enabled=$AUTO_ENABLED"
    echo
    echo "# 自动备份间隔（小时）。例如 12 = 每 12 小时一次。"
    echo "auto_interval=$AUTO_INTERVAL"
    echo
    echo "# 快照总容量上限，支持 K/M/G/T（如 10G）。超过后从最旧的开始删，但至少保留 min_keep 份。"
    echo "max_size=$MAX_SIZE"
    echo
    echo "# 至少保留的快照份数（无论容量是否超限）。"
    echo "min_keep=$MIN_KEEP"
    echo
    echo "# 压缩方式：zstd（快、体积小，推荐）| gzip（无 zstd 时用）。"
    echo "compress=$COMPRESS"
    echo
    echo "# 一致性模式：online=不停容器直接打包（快，但可能抓到写了一半的文件）"
    echo "#             quiesced=备份前短暂 stop 容器、备份后 start（一致性好，会中断几秒）"
    echo "#             ask=每次手动备份时询问"
    echo "consistency=$CONSISTENCY"
    echo
    echo "# 是否把 bind mount 的本地目录一起打进快照：0=不（默认），1=是（整机还原必需，例如 DSH 的会话历史在 bind 目录里）。"
    echo "include_bind=$INCLUDE_BIND"
    echo
    echo "# 自动备份时，即使 include_bind=0，也强制把 bind 目录打包的项目（逗号分隔，如 dsh-compose）。"
    echo "bind_projects=$BIND_PROJECTS"
    echo
    echo "# 是否用 docker save 把镜像也存进快照：0=不（推荐），1=是（每份多几百 MB~GB）。"
    echo "include_images=$INCLUDE_IMAGES"
    echo
    echo "# 自动备份包含哪些项目：all=全部 compose 项目；也可写逗号分隔的项目名（如 blog,db）。"
    echo "auto_projects=$AUTO_PROJECTS"
    echo
    echo "# 保留策略：recent=超限时删最旧的；daily=每个项目每天只保留最新一份。"
    echo "retention=$RETENTION"
    echo
    echo "# 「校验/导出」的默认导出目录；留空 = <root>/export。"
    echo "export_target=$EXPORT_TARGET"
  } >"$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" && chmod 644 "$CONFIG_FILE" 2>/dev/null
}

# ---------- 全局锁 ----------
acquire_lock() {
  exec 9>"$LOCK_FILE" || die "无法创建锁文件 $LOCK_FILE"
  if ! flock -n 9; then
    die "另一个备份/恢复任务正在运行（锁：$LOCK_FILE）"
  fi
  echo "$$" >"$LOCK_FILE.pid" 2>/dev/null
}

release_lock() {
  rm -f "$LOCK_FILE.pid" 2>/dev/null
  flock -u 9 2>/dev/null
}

# =============================================================================
# 项目发现
# =============================================================================
discover_projects() {  # 输出 TSV：name|status|config_files|working_dir
  local tmp; tmp="$(mktemp)"
  docker compose ls -a --format json 2>/dev/null \
    | jq -r '.[] | [.Name, .Status, (.ConfigFiles // "")] | @tsv' >"$tmp" 2>/dev/null
  while IFS=$'\t' read -r name status files; do
    [ -z "$name" ] && continue
    local wd
    wd="$(docker ps -a --filter "label=com.docker.compose.project=$name" --format '{{.ID}}' 2>/dev/null | head -1 \
      | xargs -r docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
    [ -z "$wd" ] && wd="$(dirname "${files%%,*}")"
    local firstfile="${files%%,*}"
    if [ -n "$firstfile" ] && [ ! -f "$firstfile" ]; then
      if [ -f "$wd/docker-compose.yml" ]; then files="$wd/docker-compose.yml"
      elif [ -f "$wd/compose.yaml" ]; then files="$wd/compose.yaml"
      elif [ -f "$wd/compose.yml" ]; then files="$wd/compose.yml"; fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$files" "$wd"
  done <"$tmp"
  rm -f "$tmp"
}

project_containers() { docker ps -a --filter "label=com.docker.compose.project=$1" --format '{{.Names}}' 2>/dev/null; }

project_est_size() {  # 粗略估计：命名卷 + bind（受限 200MB 采样）
  local name="$1" total=0
  local vols; vols="$(docker volume ls --filter "label=com.docker.compose.project=$name" --format '{{.Name}}' 2>/dev/null)"
  local v
  for v in $vols; do
    local d="$DOCKER_ROOT/volumes/$v/_data"
    [ -d "$d" ] && total=$(( total + $(du -sb "$d" 2>/dev/null | awk '{print $1}') ))
  done
  echo "$total"
}

project_mode() { # 输出 "容器名 状态"
  docker ps -a --filter "label=com.docker.compose.project=$1" --format '{{.Names}}|{{.Status}}' 2>/dev/null
}

# =============================================================================
# 快照索引
# =============================================================================
index_init() { [ -f "$INDEX_FILE" ] || echo '{"schema":1,"snapshots":[]}' >"$INDEX_FILE"; }

index_add() { # $1 = json record
  index_init
  local tmp; tmp="$(mktemp)"
  jq --argjson rec "$1" '.snapshots += [$rec]' "$INDEX_FILE" >"$tmp" && mv "$tmp" "$INDEX_FILE"
}

index_del() { # $1 = id
  index_init
  local tmp; tmp="$(mktemp)"
  jq --arg id "$1" '.snapshots |= map(select(.id != $id))' "$INDEX_FILE" >"$tmp" && mv "$tmp" "$INDEX_FILE"
}

index_list() { # 输出 TSV: id|project|created|mode|size|file|status
  index_init
  jq -r '.snapshots | sort_by(.created) | reverse | .[] | [.id,.project,.created,.mode,(.size|tostring),.file,(.integrity // "ok")] | @tsv' "$INDEX_FILE" 2>/dev/null
}

index_count() { index_init; jq '.snapshots | length' "$INDEX_FILE" 2>/dev/null; }

snapshot_record() { # $1=id -> json
  index_init
  jq --arg id "$1" '.snapshots[] | select(.id == $id)' "$INDEX_FILE" 2>/dev/null
}

total_usage() {
  local total=0 f
  for f in "$SNAP_DIR"/*.tar.* ; do
    [ -f "$f" ] && total=$(( total + $(stat -c %s "$f" 2>/dev/null) ))
  done
  echo "$total"
}

# =============================================================================
# 备份
# =============================================================================
make_snapshot_name() { # $1=project $2=mode
  printf '%s_%s_%s' "$1" "$(date +%Y%m%d-%H%M%S)" "$2"
}

collect_compose_files() { # $1=project -> 换行分隔的绝对路径
  local name="$1"
  local files
  files="$(docker compose ls -a --format json 2>/dev/null | jq -r --arg n "$name" '.[] | select(.Name==$n) | .ConfigFiles // ""' 2>/dev/null)"
  if [ -z "$files" ]; then
    files="$(docker ps -a --filter "label=com.docker.compose.project=$name" --format '{{.ID}}' 2>/dev/null | head -1 \
      | xargs -r docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)"
  fi
  echo "$files" | tr ',' '\n' | sed '/^$/d'
}

volume_path() { echo "$DOCKER_ROOT/volumes/$1/_data"; }

tar_to_zst() { # $1=源目录 $2=输出文件
  local src="$1" out="$2"
  case "$COMPRESS" in
    gzip) tar --xattrs --acls --numeric-owner -C "$src" -cf - . 2>/dev/null | gzip -6 >"$out.part" ;;
    *)    if command -v zstd >/dev/null 2>&1; then
            tar --xattrs --acls --numeric-owner -C "$src" -cf - . 2>/dev/null | zstd -19 -T0 -q >"$out.part"
          else
            tar --xattrs --acls --numeric-owner -C "$src" -cf - . 2>/dev/null | gzip -6 >"$out.part"
          fi ;;
  esac
  mv "$out.part" "$out"
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

backup_project() { # $1=project $2=mode(online|quiesced) $3=include_bind(0/1) $4=include_images(0/1) $5=auto(0/1)
  local name="$1" mode="$2" inc_bind="${3:-0}" inc_img="${4:-0}" auto="${5:-0}"
  local sid; sid="$(make_snapshot_name "$name" "$mode")"
  local stage; stage="$(mktemp -d /tmp/ccenter-stage.XXXXXX)"
  local tarfile="$SNAP_DIR/$sid.tar.$( [ "$COMPRESS" = "gzip" ] && echo gz || echo zst )"
  local sidecar="$SNAP_DIR/$sid.manifest.json"
  local started; started="$(date +%s)"

  log INFO "开始备份项目 [$name]（模式：$([ "$mode" = "quiesced" ] && echo 静止 || echo 在线)）"

  # 1) compose 文件
  local files; files="$(collect_compose_files "$name")"
  if [ -z "$files" ]; then log ERROR "找不到项目 [$name] 的 compose 文件，跳过"; rm -rf "$stage"; return 1; fi
  mkdir -p "$stage/compose"
  local f wd=""
  local -a file_arr=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    file_arr+=("$f")
    [ -d "$f" ] && f="$f/docker-compose.yml"
    [ -f "$f" ] || { log WARN "compose 文件不存在：$f"; continue; }
    [ -z "$wd" ] && wd="$(dirname "$f")"
    cp -a "$f" "$stage/compose/$(basename "$f")"
    for extra in .env docker-compose.override.yml compose.override.yaml; do
      [ -f "$(dirname "$f")/$extra" ] && cp -a "$(dirname "$f")/$extra" "$stage/compose/$extra"
    done
  done <<<"$files"
  log OK "已收集 compose 文件 ${#file_arr[@]} 个（工作目录：$wd）"

  # 自动备份：命中 bind_projects 的项目强制打包 bind（保证整机可还原，如 DSH 的会话历史在 bind 目录）
  if [ "$auto" = "1" ] && list_has "$BIND_PROJECTS" "$name"; then inc_bind=1; fi

  # 预先枚举卷与 bind 挂载（用于进度条）
  local _vols; _vols="$(docker volume ls --filter "label=com.docker.compose.project=$name" --format '{{.Name}}' 2>/dev/null)"
  if [ -z "$_vols" ]; then
    _vols="$(docker compose -p "$name" -f "$(echo "$files" | head -1)" config --format json 2>/dev/null | jq -r '.volumes // {} | keys[]' 2>/dev/null)"
  fi
  local _mounts=""
  if [ "$inc_bind" = "1" ]; then
    _mounts="$(for c in $(project_containers "$name"); do
        docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$c" 2>/dev/null
      done | sort -u)"
  fi
  local _nvol=0 _nb=0 _x
  for _x in $_vols; do [ -d "$(volume_path "$_x")" ] && _nvol=$((_nvol+1)); done
  while IFS= read -r _x; do
    case "$_x" in ""|/dev*|/proc*|/sys*|/run*|/tmp*) continue ;; esac
    [ -d "$_x" ] && _nb=$((_nb+1))
  done <<<"$_mounts"
  progress_begin $(( 4 + _nvol + _nb )) "备份 $name"

  # 2) 一致性：静止模式先停
  if [ "$mode" = "quiesced" ]; then
    log INFO "静止模式：停止项目容器…"
    docker compose -p "$name" -f "$(echo "$files" | head -1)" stop >>"$LOG_FILE" 2>&1 \
      || log WARN "停止容器失败（继续尝试备份）"
  fi

  # 3) 容器元数据
  mkdir -p "$stage/meta"
  local c
  for c in $(project_containers "$name"); do
    docker inspect "$c" >"$stage/meta/inspect-$c.json" 2>/dev/null || true
  done
  progress_step "容器元数据"

  # 4) 镜像清单
  local images=""
  images="$(docker ps -a --filter "label=com.docker.compose.project=$name" --format '{{.Image}}' 2>/dev/null | sort -u)"
  printf '%s\n' "$images" | sed '/^$/d' >"$stage/meta/images.txt"

  # 5) 命名卷
  mkdir -p "$stage/volumes"
  local vols="$_vols"
  local v vcount=0
  for v in $vols; do
    local vp; vp="$(volume_path "$v")"
    [ -d "$vp" ] || continue
    log INFO "打包卷 $v …"
    tar_to_zst "$vp" "$stage/volumes/$v.tar.$([ "$COMPRESS" = "gzip" ] && echo gz || echo zst)"
    vcount=$((vcount+1))
    progress_step "卷 $v"
  done
  log OK "已打包命名卷 $vcount 个"

  # 6) bind 目录（可选）
  mkdir -p "$stage/bind"
  local bind_count=0
  if [ "$inc_bind" = "1" ]; then
    local mounts="$_mounts"
    local m idx=0
    for m in $mounts; do
      case "$m" in /dev*|/proc*|/sys*|/run*|/tmp*) continue ;; esac
      [ -d "$m" ] || continue
      idx=$((idx+1))
      local bn; bn="$(echo "$m" | sed 's#^/##; s#/#_#g')"
      log INFO "打包 bind 目录 $m …"
      tar -C "$(dirname "$m")" --xattrs --acls --numeric-owner -cf - "$(basename "$m")" 2>/dev/null \
        | { if [ "$COMPRESS" = "gzip" ]; then gzip -6; else zstd -19 -T0 -q; fi; } >"$stage/bind/bind-$idx-$bn.tar.$([ "$COMPRESS" = "gzip" ] && echo gz || echo zst)"
      printf '%s\n' "$m" >>"$stage/bind/paths.txt"
      bind_count=$((bind_count+1))
      progress_step "bind $(basename "$m")"
    done
  fi

  # 7) 镜像本体（可选）
  mkdir -p "$stage/images"
  if [ "$inc_img" = "1" ] && [ -n "$images" ]; then
    log INFO "导出镜像（docker save）…"
    docker save $images 2>/dev/null | { if [ "$COMPRESS" = "gzip" ]; then gzip -6; else zstd -19 -T0 -q; fi; } \
      >"$stage/images/images.tar.$([ "$COMPRESS" = "gzip" ] && echo gz || echo zst)"
  fi
  progress_step "镜像"

  # 8) manifest
  local entries_json="[]"
  local e
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    local rel="${e#$stage/}"
    entries_json="$(jq --arg p "$rel" --arg s "$(sha256_of "$e")" --argjson z "$(stat -c %s "$e" 2>/dev/null || echo 0)" \
      '. + [{path:$p, sha256:$s, size:$z}]' <<<"$entries_json")"
  done < <(find "$stage" -type f | sort)

  local finished; finished="$(date +%s)"
  jq -n \
    --arg schema "1" --arg tool "$PROG $VERSION" --arg project "$name" --arg host "$HOSTNAME_S" \
    --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
    --arg created "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg mode "$mode" \
    --arg wd "$wd" --argjson entries "$entries_json" --arg images "$(printf '%s' "$images" | tr '\n' ' ')" \
    '{schema:($schema|tonumber), tool:$tool, project:$project, host:$host, docker:$docker,
      created:$created, mode:$mode, working_dir:$wd,
      entries:$entries, images:($images|split(" ")|map(select(length>0)))}' >"$stage/manifest.json"
  progress_step "清单"

  # 9) 打包 + 校验 + 原子改名
  log INFO "生成快照包（$COMPRESS）…"
  progress_step "打包快照"
  if [ "$COMPRESS" = "gzip" ]; then
    tar --xattrs --acls --numeric-owner -C "$stage" -cf - . 2>/dev/null | gzip -6 >"$tarfile.part"
  else
    tar --xattrs --acls --numeric-owner -C "$stage" -cf - . 2>/dev/null | zstd -19 -T0 -q >"$tarfile.part"
  fi
  mv "$tarfile.part" "$tarfile"; fix_files "$tarfile"
  tar -tf "$tarfile" >/dev/null 2>&1 || { log ERROR "快照包不可读：$tarfile"; return 1; }
  cp -a "$stage/manifest.json" "$sidecar"; fix_files "$sidecar"

  local size sha rec
  size="$(stat -c %s "$tarfile")"
  sha="$(sha256_of "$tarfile")"
  printf '%s  %s\n' "$sha" "$(basename "$tarfile")" >"$tarfile.sha256"; fix_files "$tarfile.sha256"

  # 10) 恢复容器（静止模式）
  if [ "$mode" = "quiesced" ]; then
    log INFO "静止模式：恢复项目容器…"
    docker compose -p "$name" -f "$(echo "$files" | head -1)" start >>"$LOG_FILE" 2>&1 || log WARN "启动容器失败"
  fi

  rec="$(jq -n --arg id "$sid" --arg project "$name" --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg mode "$mode" --argjson size "$size" --arg file "$(basename "$tarfile")" --arg sha "$sha" \
    --argjson dur "$((finished-started))" \
    '{id:$id, project:$project, created:$created, mode:$mode, size:$size, file:$file, sha256:$sha,
      duration_sec:$dur, integrity:"ok"}')"
  index_add "$rec"
  rm -rf "$stage"
  log OK "备份完成：$(basename "$tarfile")（$(human_size "$size")，耗时 $((finished-started)) 秒）"
  progress_end

  if [ "$auto" = "1" ]; then echo "$(date '+%F %T') 自动备份 $name -> $(basename "$tarfile") $(human_size "$size")" >>"$LOG_DIR/auto.log"; fi
}

# ---------- 容量策略 ----------
prune_snapshots() {
  local limit; limit="$(parse_size "$MAX_SIZE")"
  local total; total="$(total_usage)"
  [ "$limit" -le 0 ] && { log INFO "未设置容量上限，跳过清理"; return 0; }
  if [ "$total" -le "$limit" ]; then return 0; fi
  log WARN "已用 $(human_size "$total") 超过上限 $(human_size "$limit")，开始清理最旧快照…"
  local target=$(( limit * 90 / 100 ))
  local count; count="$(index_count)"
  local ids; ids="$(index_list | sort -t$'\t' -k3 | cut -f1)"
  local id
  for id in $ids; do
    [ "$count" -le "$MIN_KEEP" ] && break
    [ "$total" -le "$target" ] && break
    local f; f="$(snapshot_record "$id" | jq -r '.file')"
    [ -z "$f" ] || [ "$f" = "null" ] && continue
    local sz; sz="$(stat -c %s "$SNAP_DIR/$f" 2>/dev/null || echo 0)"
    rm -f "$SNAP_DIR/$f" "$SNAP_DIR/${f%.tar.*}.manifest.json" "$SNAP_DIR/$f.sha256"
    index_del "$id"
    total=$(( total - sz ))
    count=$(( count - 1 ))
    log INFO "已删除旧快照 $f（释放 $(human_size "$sz")）"
  done
  log OK "清理完成，当前占用 $(human_size "$(total_usage)")"
}

# =============================================================================
# 恢复
# =============================================================================
# 只保留最近一份 .pre-restore 备份，避免每次恢复都堆一份
prune_pre_restore() { # $1=原路径
  local n=0 x list
  list="$(ls -1dt "$1".pre-restore.* 2>/dev/null || true)"
  [ -z "$list" ] && return 0
  while IFS= read -r x; do
    n=$((n+1)); [ "$n" -gt 1 ] && rm -rf "$x"
  done <<<"$list"
}

restore_snapshot() { # $1=id $2=skip_pre(0/1)
  local id="$1" skip_pre="${2:-0}"
  local rec; rec="$(snapshot_record "$id")"
  [ -z "$rec" ] || [ "$rec" = "null" ] && { log ERROR "找不到快照 $id"; return 1; }
  local project file sha
  project="$(jq -r '.project' <<<"$rec")"
  file="$(jq -r '.file' <<<"$rec")"
  sha="$(jq -r '.sha256' <<<"$rec")"
  local tarfile="$SNAP_DIR/$file"
  [ -f "$tarfile" ] || { log ERROR "快照文件不存在：$tarfile"; return 1; }

  section "恢复预检：$project  ←  $file"
  local size; size="$(stat -c %s "$tarfile")"
  local need=$(( size * 2 / 1 ))
  local avail; avail="$(df -Pk "$ROOT" | awk 'NR==2{printf "%.0f", $4*1024}')"
  printf '  快照大小：%s\n  预计需要：%s\n  可用空间：%s\n' "$(human_size "$size")" "$(human_size "$need")" "$(human_size "$avail")"
  [ "$avail" -lt "$need" ] && { log ERROR "磁盘空间不足"; return 1; }

  local cur_sha; cur_sha="$(sha256_of "$tarfile")"
  if [ -n "$sha" ] && [ "$cur_sha" != "$sha" ]; then
    log ERROR "sha256 不匹配（文件可能损坏）：$file"
    return 1
  fi
  log OK "快照完整性校验通过"

  # 解包
  local work; work="$(mktemp -d /tmp/ccenter-restore.XXXXXX)"
  if [[ "$file" == *.zst ]]; then tar --xattrs --acls -xf "$tarfile" -C "$work" 2>/dev/null || { log ERROR "解包失败"; return 1; }
  else tar --xattrs --acls -xzf "$tarfile" -C "$work" 2>/dev/null || { log ERROR "解包失败"; return 1; }; fi
  local manifest="$work/manifest.json"
  [ -f "$manifest" ] || { log ERROR "快照里没有 manifest.json"; return 1; }

  # 进度条：统计要做的活
  local _nv; _nv="$(ls -1 "$work"/volumes/*.tar.* 2>/dev/null | wc -l)"
  local _nb=0
  [ -f "$work/bind/paths.txt" ] && _nb="$(wc -l <"$work/bind/paths.txt" | tr -d ' ')"
  local _nimgs=0
  ls -1 "$work"/images/*.tar.* >/dev/null 2>&1 && _nimgs=1
  progress_begin $(( 4 + _nv + _nb + _nimgs )) "恢复 $project"
  if [ ! -f "$work/bind/paths.txt" ]; then
    log WARN "该快照不含 bind 目录：若项目有 bind 挂载（如 DSH 的 /root/.dsh 会话历史），恢复后这些内容不会被还原。"
  fi

  # 逐条校验
  local bad=0
  while IFS=$'\t' read -r rel esha; do
    local p="$work/$rel"
    [ -f "$p" ] || { log WARN "缺少文件：$rel"; bad=1; continue; }
    [ "$(sha256_of "$p")" = "$esha" ] || { log ERROR "校验失败：$rel"; bad=1; }
  done < <(jq -r '.entries[] | [.path,.sha256] | @tsv' "$manifest")
  [ "$bad" = "1" ] && { log ERROR "条目校验未通过，中止恢复"; return 1; }
  log OK "全部条目校验通过"
  progress_step "条目校验"

  # 恢复前快照
  if [ "$skip_pre" = "0" ]; then
    if ask_yes "恢复前自动打一份当前状态快照？" y; then
      backup_project "$project" quiesced 0 0 0 || log WARN "恢复前快照失败（继续恢复）"
    fi
  fi

  # 停项目
  local wd; wd="$(jq -r '.working_dir' "$manifest")"
  local mainfile; mainfile="$(find "$work/compose" -maxdepth 1 -type f \( -name 'docker-compose*.yml' -o -name 'compose*.yaml' \) | head -1)"
  [ -n "$mainfile" ] || { log ERROR "快照里没有 compose 主文件"; return 1; }

  if docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Names}}' | grep -q .; then
    log INFO "停止项目容器…"
    docker compose -p "$project" -f "$mainfile" stop >>"$LOG_FILE" 2>&1 || log WARN "stop 返回非零"
  fi

  # 还原 compose 文件
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local cf
  for cf in "$work"/compose/*; do
    [ -f "$cf" ] || continue
    local target="$wd/$(basename "$cf")"
    [ -f "$target" ] && cp -a "$target" "$target.pre-restore.$ts"
    mkdir -p "$wd"
    cp -a "$cf" "$target"
    log OK "已还原 $target"
    prune_pre_restore "$target"
  done
  progress_step "compose 文件"

  # 用还原后的真实路径启动（避免容器 label 指向临时目录）
  local restored_main="$wd/$(basename "$mainfile")"
  [ -f "$restored_main" ] && mainfile="$restored_main"

  # 还原命名卷
  local vf
  for vf in "$work"/volumes/*.tar.*; do
    [ -f "$vf" ] || continue
    local vname; vname="$(basename "$vf")"; vname="${vname%.tar.*}"
    local target; target="$(volume_path "$vname")"
    if [ ! -d "$target" ]; then
      log WARN "卷 $vname 不存在，先创建"
      docker volume create "$vname" >/dev/null 2>&1 || { log ERROR "创建卷失败：$vname"; continue; }
    fi
    log INFO "还原卷 $vname …"
    find "$target" -mindepth 1 -delete 2>/dev/null || true
    if [[ "$vf" == *.zst ]]; then zstd -dcq "$vf" | tar --xattrs --acls --numeric-owner -xpf - -C "$target" 2>/dev/null
    else gzip -dc "$vf" | tar --xattrs --acls --numeric-owner -xpf - -C "$target" 2>/dev/null; fi
    log OK "卷 $vname 已还原"
    progress_step "卷 $vname"
  done

  # 还原 bind
  if [ -f "$work/bind/paths.txt" ]; then
    local i=0 path
    while IFS= read -r path; do
      i=$((i+1))
      local bf; bf="$(ls "$work"/bind/bind-$i-*.tar.* 2>/dev/null | head -1)"
      [ -f "$bf" ] || continue
      local parent; parent="$(dirname "$path")"; mkdir -p "$parent"
      [ -d "$path" ] && mv "$path" "$path.pre-restore.$ts"
      mkdir -p "$path"
      [ -f "$path.pre-restore.$ts/.ccenter-keep" ] && true
      if [[ "$bf" == *.zst ]]; then zstd -dcq "$bf" | tar --xattrs --acls --numeric-owner -xpf - -C "$parent" 2>/dev/null
      else gzip -dc "$bf" | tar --xattrs --acls --numeric-owner -xpf - -C "$parent" 2>/dev/null; fi
      log OK "已还原 bind 目录 $path"
      prune_pre_restore "$path"
      progress_step "bind $(basename "$path")"
    done <"$work/bind/paths.txt"
  fi

  # 镜像（如果快照里带了）
  if [ -f "$work"/images/images.tar.* ]; then
    local imf; imf="$(ls "$work"/images/images.tar.* 2>/dev/null | head -1)"
    if [ -n "$imf" ]; then
      log INFO "导入镜像…"
      if [[ "$imf" == *.zst ]]; then zstd -dcq "$imf" | docker load >>"$LOG_FILE" 2>&1 || log WARN "docker load 失败"
      else gzip -dc "$imf" | docker load >>"$LOG_FILE" 2>&1 || log WARN "docker load 失败"; fi
      progress_step "镜像"
    fi
  fi

  # 启动
  log INFO "启动项目容器…"
  docker compose -p "$project" -f "$mainfile" up -d --remove-orphans --force-recreate >>"$LOG_FILE" 2>&1 || log WARN "up -d 返回非零"
  progress_step "启动容器"

  # 健康检查
  local waited=0 ok=0
  while [ "$waited" -lt 120 ]; do
    local running total
    running="$(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Status}}' | grep -c '^Up' )"
    total="$(project_containers "$project" | wc -l)"
    if [ "$total" -gt 0 ] && [ "$running" -ge "$total" ]; then ok=1; break; fi
    sleep 2; waited=$((waited+2))
  done
  if [ "$ok" = "1" ]; then log OK "恢复完成：$project（健康检查通过，用时 ${waited}s）"; else log WARN "容器已启动但健康检查超时（${waited}s），请手动确认"; fi
  progress_step "健康检查"
  progress_end

  echo "$(date '+%F %T') restore $project from $id" >>"$LOG_DIR/restore.log"
  rm -rf "$work"
  return 0
}

# =============================================================================
# 校验 / 导出
# =============================================================================
verify_snapshot() { # $1=id
  local rec; rec="$(snapshot_record "$1")"
  [ -z "$rec" ] || [ "$rec" = "null" ] && { echo "  ✗ 找不到 $1"; return 1; }
  local f sha file; file="$(jq -r '.file' <<<"$rec")"; sha="$(jq -r '.sha256' <<<"$rec")"
  f="$SNAP_DIR/$file"
  local cur; cur="$(sha256_of "$f")"
  if [ -n "$sha" ] && [ "$cur" = "$sha" ]; then
    if tar -tf "$f" >/dev/null 2>&1; then echo "  ✓ $file  sha256 正确，可读"; return 0
    else echo "  ✗ $file  sha256 正确但归档不可读"; return 1; fi
  else
    echo "  ✗ $file  sha256 不匹配（$cur）"; return 1
  fi
}

export_snapshot() { # $1=id $2=dest
  local rec; rec="$(snapshot_record "$1")"
  local file; file="$(jq -r '.file' <<<"$rec")"
  local dest="${2:-$EXPORT_TARGET}"
  [ -z "$dest" ] && { log ERROR "没有指定导出目标"; return 1; }
  mkdir -p "$dest" || { log ERROR "目标不可写：$dest"; return 1; }
  cp -a "$SNAP_DIR/$file" "$dest/" && cp -a "$SNAP_DIR/${file%.tar.*}.manifest.json" "$dest/" 2>/dev/null
  fix_files "$dest/$file" "$dest/${file%.tar.*}.manifest.json" "$dest/${file%.tar.*}.tar" 2>/dev/null || true
  log OK "已导出到 $dest/$file"
}

# =============================================================================
# 扫描与列表展示
# =============================================================================
show_projects() { # 输出项目表，回显编号
  local i=0 name status files wd size
  printf '%s%-4s %-22s %-10s %-6s %-52s %-12s %s%s\n' "$B" "编号" "项目名" "状态" "服务" "compose 文件" "数据量估" "最近改动" "$C_0"
  while IFS=$'\t' read -r name status files wd; do
    [ -z "$name" ] && continue
    i=$((i+1))
    local svc; svc="$(project_containers "$name" | wc -l)"
    size="$(human_size "$(project_est_size "$name")")"
    local mtime; mtime="$(stat -c %y "$wd" 2>/dev/null | cut -c1-16)"
    printf '%-4s %-22s %-10s %-6s %-52s %-12s %s\n' "$i" "${name:0:22}" "${status:0:10}" "$svc" "${files:0:52}" "$size" "$mtime"
  done < <(discover_projects)
}

proj_count() { discover_projects | awk -F'\t' 'NF&&$1!=""' | wc -l; }
proj_name_by_index() { discover_projects | awk -F'\t' -v n="$1" 'NF&&$1!=""{i++; if(i==n){print $1; exit}}'; }

select_indexes() { # $1=最大编号 -> 输出逗号分隔编号
  local maxn="$1" ans
  printf '选择编号（如 1 或 1,3 或 1-3，回车取消）：' >&2
  read -r ans || ans=""
  ans="$(echo "$ans" | tr -d ' ')"
  [ -z "$ans" ] && return 1
  local out="" part a b n
  IFS=',' read -ra parts <<<"$ans"
  for part in "${parts[@]}"; do
    case "$part" in
      *-*) a="${part%-*}"; b="${part#*-}"
           [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || continue
           for ((n=a; n<=b; n++)); do [ "$n" -ge 1 ] && [ "$n" -le "$maxn" ] && out="$out,$n"; done ;;
      *)   [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "$maxn" ] && out="$out,$part" ;;
    esac
  done
  out="${out#,}"
  [ -z "$out" ] && return 1
  echo "$out"
}

# 按「显示宽度」补齐空格（中文/全角按 2 列算），用于终端表格对齐。
# 逐字节扫描 UTF-8：首字节 >=0xC0 计 2 列，续字节 0x80-0xBF 忽略。
vispad() { # $1=字符串 $2=目标显示宽度
  local s="$1" target="${2:-0}" w=0 i c
  local LC_ALL=C
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [$'\xc0'-$'\xff']) w=$((w+2)) ;;
      [$'\x80'-$'\xbf']) ;;
      *) w=$((w+1)) ;;
    esac
  done
  printf '%s' "$s"
  while [ "$w" -lt "$target" ]; do printf ' '; w=$((w+1)); done
}

show_snapshots() {
  local i=0 id project created mode size file status side bind img
  printf '%s\n' "${B}$(vispad 编号 4) $(vispad 项目 22) $(vispad 时间 20) $(vispad 模式 6) $(vispad 大小 10) $(vispad bind 6) $(vispad 镜像 6) 文件${C_0}"
  while IFS=$'\t' read -r id project created mode size file status; do
    [ -z "$id" ] && continue
    i=$((i+1))
    side="${SNAP_DIR}/${file%.tar.*}.manifest.json"
    bind="0"; img="0"
    if [ -f "$side" ]; then
      bind="$(jq -r '[.entries[] | select(.path | startswith("bind/bind-"))] | length' "$side" 2>/dev/null || echo 0)"
      img="$(jq -r '(.images // []) | length' "$side" 2>/dev/null || echo 0)"
      [ -z "$bind" ] && bind="0"
      [ -z "$img" ] && img="0"
    fi
    printf '%s %s %s %s %s %s %s %s\n' \
      "$(vispad "$i" 4)" \
      "$(vispad "${project:0:20}" 22)" \
      "$(vispad "$created" 20)" \
      "$(vispad "$([ "$mode" = quiesced ] && echo 静止 || echo 在线)" 6)" \
      "$(vispad "$(human_size "$size")" 10)" \
      "$(vispad "$bind" 6)" \
      "$(vispad "$img" 6)" \
      "$file"
  done < <(index_list)
  [ "$i" = "0" ] && echo "（还没有任何快照）"
}

# =============================================================================
# 交互界面
# =============================================================================
snap_id_by_index() { index_list | awk -F'\t' -v n="$1" 'NR==n{print $1; exit}'; }
snap_count() { index_count; }

banner() {
  printf '%s' "$C_B"
  cat <<'EOF'
   ______   ______   ______  ______  ______  ______
  / ____/  / ____/  / ____/ /_  __/ / ____/ / __  /
 / /      / /      / /       / /   / __/   / /_/ /
/ /___   / /___   / /___    / /   / /___  / _, _/
\____/   \____/   \____/   /_/   /_____/ /_/ |_|
EOF
  printf '%s' "$C_0"
  printf '  Compose 一键备份 / 恢复中心  %sv%s%s   备份根：%s\n' "$C_D" "$VERSION" "$C_0" "$ROOT"
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    banner
    local total count
    total="$(total_usage)"; count="$(index_count)"
    local last_auto="-"
    [ -f "$LOG_DIR/auto.log" ] && last_auto="$(tail -1 "$LOG_DIR/auto.log" | cut -c1-16)"
    printf '  %s自动备份:%s %s · 每 %s 小时 · 上次 %s\n' "$C_D" "$C_0" "$([ "$AUTO_ENABLED" = "1" ] && echo 开 || echo 关)" "$AUTO_INTERVAL" "$last_auto"
    printf '  %s占用:%s %s / %s · 共 %s 份\n\n' "$C_D" "$C_0" "$(human_size "$total")" "$MAX_SIZE" "$count"
    printf '  %s1)%s 备份快照          %s2)%s 查看 / 删除备份\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s3)%s 一键恢复          %s4)%s 配置\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s5)%s 状态与日志        %s6)%s 校验 / 导出\n\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %sq)%s 退出\n' "$C_D" "$C_0"
    printf '\n选择：'
    local c; read -r c || c="q"
    case "$c" in
      1) menu_backup ;;
      2) menu_list ;;
      3) menu_restore ;;
      4) menu_config ;;
      5) menu_status ;;
      6) menu_verify ;;
      q|Q) printf '\n再见。\n'; exit 0 ;;
      *) ;;
    esac
  done
}

menu_backup() {
  clear 2>/dev/null || true; section "备份快照"
  show_projects
  local maxn; maxn="$(proj_count)"
  [ "$maxn" = "0" ] && { echo "没发现 compose 项目"; read -r _; return; }
  local sel; sel="$(select_indexes "$maxn")" || { echo "已取消"; sleep 1; return; }

  printf '\n一致性模式：%s1)%s 在线（不停机，快）  %s2)%s 静止（停机打包，推荐有状态项目）\n' "$C_B" "$C_0" "$C_B" "$C_0"
  printf '选择 [默认 1]：'; local m; read -r m || m=""
  local mode="online"; [ "$m" = "2" ] && mode="quiesced"

  local inc_bind=0 inc_img=0
  ask_yes "包含 bind 挂载目录？（体积可能很大）" n && inc_bind=1
  ask_yes "包含镜像本体（docker save，体积大）？" n && inc_img=1

  local idx
  IFS=',' read -ra idxs <<<"$sel"
  for idx in "${idxs[@]}"; do
    local pn; pn="$(proj_name_by_index "$idx")"
    [ -z "$pn" ] && { log WARN "编号 $idx 无效，跳过"; continue; }
    backup_project "$pn" "$mode" "$inc_bind" "$inc_img" 0
  done
  prune_snapshots
  printf '\n按回车返回…'; read -r _ || true
}

menu_list() {
  while true; do
    clear 2>/dev/null || true; section "查看 / 删除备份"
    show_snapshots
    printf '\n输入编号看详情 / 删除；%sd%s 编号 删除；%sq%s 返回\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '选择：'; local c; read -r c || return
    case "$c" in
      q|Q) return ;;
      d|D)
        printf '要删除的编号：'; local s; read -r s || continue
        local n; n="$(echo "$s" | tr -d ' ')"
        local idx="$(snap_id_by_index "$n")"
        [ -z "$idx" ] && { echo "无效编号"; sleep 1; continue; }
        do_delete "$idx" ;;
      *)
        local nidx="$(snap_id_by_index "$c")"
        [ -z "$nidx" ] && { echo "无效编号"; sleep 1; continue; }
        show_snapshot_detail "$nidx" ;;
    esac
  done
}

show_snapshot_detail() {
  print_snapshot_detail "$1"
  printf '\n按回车返回…'; read -r _ || true
}

print_snapshot_detail() {
  local rec; rec="$(snapshot_record "$1")"
  local file; file="$(jq -r '.file' <<<"$rec")"
  local sidecar="${SNAP_DIR}/${file%.tar.*}.manifest.json"
  section "快照详情"
  local _sz; _sz="$(human_size "$(jq -r '.size' <<<"$rec")")"
  jq -r '"  项目：\(.project)\n  时间：\(.created)\n  模式：\(if .mode=="quiesced" then "静止" else "在线" end)\n  文件：\(.file)\n  sha256：\(.sha256)"' <<<"$rec"
  echo "  大小：$_sz"
  if [ -f "$sidecar" ]; then
    echo "  compose：$(jq -r '[.entries[] | select(.path|startswith("compose/"))] | length' "$sidecar") 个文件"
    echo "  命名卷：$(jq -r '[.entries[] | select(.path|startswith("volumes/"))] | length' "$sidecar") 个"
    echo "  bind 目录：$(jq -r '[.entries[] | select(.path|startswith("bind/bind-"))] | length' "$sidecar") 个"
    echo "  镜像：$(jq -r '.images | join(", ")' "$sidecar")"
  fi
}

do_delete() {
  local id="$1"
  local rec; rec="$(snapshot_record "$id")"
  local file size project created
  file="$(jq -r '.file' <<<"$rec")"; size="$(jq -r '.size' <<<"$rec")"
  project="$(jq -r '.project' <<<"$rec")"; created="$(jq -r '.created' <<<"$rec")"
  # 最新一份保护
  local newest; newest="$(index_list | head -1 | cut -f1)"
  if [ "$id" = "$newest" ]; then
    log WARN "这是最新一份快照（$file），默认受保护。"
    printf '确定要删除？请输入 DELETE 确认：'; local w; read -r w || w=""
    [ "$w" = "DELETE" ] || { echo "已取消"; return; }
  fi
  printf '将删除 %s（%s，%s），释放 %s。确认？' "$file" "$project" "$created" "$(human_size "$size")"
  read -r a || a=""
  case "$a" in y|Y) ;;
    *) echo "已取消"; return ;;
  esac
  rm -f "$SNAP_DIR/$file" "$SNAP_DIR/${file%.tar.*}.manifest.json" "$SNAP_DIR/$file.sha256"
  index_del "$id"
  log OK "已删除快照 $file"
  printf '按回车继续…'; read -r _ || true
}

menu_restore() {
  clear 2>/dev/null || true; section "一键恢复"
  show_snapshots
  local maxn="$(snap_count)"
  [ "$maxn" = "0" ] && { echo "没有可用快照"; read -r _; return; }
  printf '\n选择要恢复的编号：'; local n; read -r n || return
  local id="$(snap_id_by_index "$n")"
  [ -z "$id" ] && { echo "无效编号"; sleep 1; return; }
  print_snapshot_detail "$id"

  # 自己恢复自己：提示并后台执行
  local project; project="$(snapshot_record "$id" | jq -r '.project')"
  local self_proj="${CCENTER_SELF_PROJECT:-}"
  if [ -n "$self_proj" ] && [ "$project" = "$self_proj" ]; then
    log WARN "恢复 $project 会中断当前 DSH 会话（自己恢复自己），将转入后台执行。"
    local logf="$LOG_DIR/restore-$project-$(date +%Y%m%d-%H%M%S).log"
    setsid nohup bash -c "\"$SCRIPT_PATH\" restore --id '$id' --skip-pre --yes >>'$logf' 2>&1" >/dev/null 2>&1 &
    log OK "已在后台启动恢复，日志：$logf；恢复完成后刷新页面。"
    sleep 2; return
  fi

  printf '\n即将恢复：%s\n' "$project"
  printf '  将还原：compose 文件、命名卷、bind 目录（以快照内实际内容为准）\n'
  printf '  输入 y 后回车 = 确认恢复；直接回车 = 取消。\n'
  ask_yes "确认恢复？" n || { echo "已取消（未做任何修改）"; return; }
  restore_snapshot "$id" 0
  printf '\n按回车返回…'; read -r _ || true
}

menu_config() {
  while true; do
    clear 2>/dev/null || true; section "配置"
    printf '  [1] 备份根目录            %s\n' "$ROOT"
    printf '  [2] 自动备份开关          %s\n' "$([ "$AUTO_ENABLED" = "1" ] && echo 开 || echo 关)"
    printf '  [3] 自动备份间隔          %s 小时\n' "$AUTO_INTERVAL"
    printf '  [4] 备份总容量上限        %s\n' "$MAX_SIZE"
    printf '  [5] 保留份数下限          %s\n' "$MIN_KEEP"
    printf '  [6] 压缩方式              %s\n' "$COMPRESS"
    printf '  [7] 一致性默认模式        %s\n' "$CONSISTENCY"
    printf '  [8] 自动备份包含 bind     %s\n' "$([ "$INCLUDE_BIND" = "1" ] && echo 是 || echo 否)"
    printf '  [9] 自动备份镜像          %s\n' "$([ "$INCLUDE_IMAGES" = "1" ] && echo 是 || echo 否)"
    printf '  [10] 自动备份项目范围     %s\n' "$AUTO_PROJECTS"
    printf '  [11] 保留策略             %s\n' "$RETENTION"
    printf '  [12] 导出目标（异地）     %s\n' "${EXPORT_TARGET:-无}"
    printf '  [13] 安装自动备份定时器   %s\n' "$([ -f /etc/systemd/system/ccenter-backup.timer ] && echo 已安装 || echo 未安装)"
    printf '  [14] 卸载自动备份定时器\n'
    printf '  [0] 返回\n\n选择：'
    local c; read -r c || return
    case "$c" in
      0) return ;;
      1) printf '新路径：'; read -r v; [ -n "$v" ] && { ROOT="$v"; init_paths; mkdir -p "$ROOT" "$SNAP_DIR" "$LOG_DIR"; mv "$CONFIG_FILE" "$ROOT/" 2>/dev/null; save_config; } ;;
      2) [ "$AUTO_ENABLED" = "1" ] && AUTO_ENABLED=0 || AUTO_ENABLED=1 ;;
      3) printf '间隔（1/3/6/12/24/48/168）：'; read -r v; [[ "$v" =~ ^[0-9]+$ ]] && AUTO_INTERVAL="$v" ;;
      4) printf '上限（如 500M/10G/1T）：'; read -r v; [ -n "$v" ] && MAX_SIZE="$v" ;;
      5) printf '最少保留份数：'; read -r v; [[ "$v" =~ ^[0-9]+$ ]] && MIN_KEEP="$v" ;;
      6) printf '压缩（zstd/gzip）：'; read -r v; [ "$v" = "gzip" ] || [ "$v" = "zstd" ] && COMPRESS="$v" ;;
      7) printf '一致性（quiesced/online/ask）：'; read -r v; case "$v" in quiesced|online|ask) CONSISTENCY="$v" ;; esac ;;
      8) [ "$INCLUDE_BIND" = "1" ] && INCLUDE_BIND=0 || INCLUDE_BIND=1 ;;
      9) [ "$INCLUDE_IMAGES" = "1" ] && INCLUDE_IMAGES=0 || INCLUDE_IMAGES=1 ;;
      10) printf '项目范围（all 或逗号分隔）：'; read -r v; [ -n "$v" ] && AUTO_PROJECTS="$v" ;;
      11) printf '保留策略（recent/daily）：'; read -r v; [ -n "$v" ] && RETENTION="$v" ;;
      12) printf '导出目标路径（空=无）：'; read -r v; EXPORT_TARGET="$v" ;;
      13) install_timer ;;
      14) uninstall_timer ;;
    esac
    save_config
  done
}

menu_status() {
  clear 2>/dev/null || true; section "状态与日志"
  local total; total="$(total_usage)"
  printf '  备份根：%s\n' "$ROOT"
  printf '  占用：%s / %s（%s 份）\n' "$(human_size "$total")" "$MAX_SIZE" "$(index_count)"
  printf '  磁盘可用：%s\n' "$(human_size "$(df -Pk "$ROOT" | awk 'NR==2{printf "%.0f", $4*1024}')")"
  printf '  Docker：%s  数据根：%s\n' "$(docker version --format '{{.Server.Version}}')" "$DOCKER_ROOT"
  printf '  自动备份：%s  每 %s 小时  上次：%s\n' "$([ "$AUTO_ENABLED" = "1" ] && echo 开 || echo 关)" "$AUTO_INTERVAL" "$(tail -1 "$LOG_DIR/auto.log" 2>/dev/null | cut -c1-30 || echo -)"
  printf '  定时器：%s\n' "$([ -f /etc/systemd/system/ccenter-backup.timer ] && systemctl is-active ccenter-backup.timer 2>/dev/null || echo 未安装)"
  printf '\n  最近 20 条日志：\n'
  tail -20 "$LOG_DIR/auto.log" 2>/dev/null || tail -20 "$LOG_FILE" 2>/dev/null
  printf '\n  [1] 手动运行一次自动备份  [2] 查看完整日志  [3] 清理临时文件  [q] 返回\n选择：'
  local c; read -r c || return
  case "$c" in
    1) run_auto_backup ;;
    2) less "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE" ;;
    3) rm -rf /tmp/ccenter-stage.* /tmp/ccenter-restore.* 2>/dev/null; echo 已清理 ;;
  esac
}

menu_verify() {
  clear 2>/dev/null || true; section "校验 / 导出"
  show_snapshots
  local maxn="$(snap_count)"
  [ "$maxn" = "0" ] && { read -r _; return; }
  printf '\n输入编号校验（直接回车 = 全部校验）：'; local n; read -r n
  if [ -z "$n" ]; then
    local i
    for ((i=1;i<=maxn;i++)); do verify_snapshot "$(snap_id_by_index "$i")"; done
  else
    local id="$(snap_id_by_index "$n")"; [ -n "$id" ] && verify_snapshot "$id"
    printf '\n要把这份导出到别处吗？输入目标路径（空=否）：'; local d; read -r d
    if [ -n "$d" ]; then export_snapshot "$id" "$d"; fi
  fi
  printf '\n按回车返回…'; read -r _ || true
}

# ---------- 自动备份 ----------
run_auto_backup() {
  log INFO "=== 自动备份开始 ==="
  local mode="online"
  case "$CONSISTENCY" in quiesced) mode="quiesced" ;; online) mode="online" ;; ask) mode="online" ;; esac
  local names=""
  if [ "$AUTO_PROJECTS" = "all" ]; then
    names="$(discover_projects | cut -f1)"
  else
    names="$(echo "$AUTO_PROJECTS" | tr ',' ' ')"
  fi
  local n
  for n in $names; do
    backup_project "$n" "$mode" "$INCLUDE_BIND" "$INCLUDE_IMAGES" 1 || log WARN "自动备份项目 $n 失败"
  done
  prune_snapshots
  log INFO "=== 自动备份结束 ==="
}

install_timer() {
  cat >/etc/systemd/system/ccenter-backup.service <<EOF
[Unit]
Description=ccenter compose 自动备份
[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH auto-backup
EOF
  cat >/etc/systemd/system/ccenter-backup.timer <<EOF
[Unit]
Description=ccenter 定时备份（每 $AUTO_INTERVAL 小时）
[Timer]
OnBootSec=10min
OnUnitActiveSec=${AUTO_INTERVAL}h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now ccenter-backup.timer && log OK "定时器已安装" || log ERROR "安装失败"
}

uninstall_timer() {
  systemctl disable --now ccenter-backup.timer 2>/dev/null
  rm -f /etc/systemd/system/ccenter-backup.service /etc/systemd/system/ccenter-backup.timer
  systemctl daemon-reload 2>/dev/null
  log OK "定时器已卸载"
}

# =============================================================================
# 非交互 CLI
# =============================================================================
cli_usage() {
  cat <<EOF
用法：$PROG <命令> [选项]
  list                        列出快照
  projects                    列出发现的 compose 项目
  backup <项目> [--quiesce] [--bind] [--images]
  restore --id <id> [--skip-pre] [--yes]
  delete <id> [--yes]
  prune                       按容量策略清理
  verify [<id>]               校验（省略则全部）
  export <id> <目标目录>
  status [--json]
  auto-backup                 自动备份（供定时器调用）
  config [--json]
EOF
}

cli_main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    projects)
      discover_projects ;;
    list)
      init_paths; show_snapshots ;;
    status)
      if [ "${1:-}" = "--json" ]; then
        jq -n --arg root "$ROOT" --argjson usage "$(total_usage)" --arg max "$MAX_SIZE" \
          --argjson count "$(index_count)" --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
          '{root:$root, usage_bytes:$usage, max_size:$max, snapshots:$count, docker:$docker}'
      else
        echo "根目录：$ROOT"; echo "占用：$(human_size "$(total_usage)") / $MAX_SIZE"; echo "快照数：$(index_count)"
      fi ;;
    verify)
      init_paths; local id="${1:-}"
      if [ -n "$id" ]; then verify_snapshot "$id"; else
        while IFS= read -r id; do verify_snapshot "$id"; done < <(index_list | cut -f1); fi ;;
    backup)
      init_paths; need_docker; acquire_lock
      local proj="${1:-}"; shift || true
      local mode="online" bind=0 img=0
      for a in "$@"; do case "$a" in --quiesce) mode="quiesced";; --bind) bind=1;; --images) img=1;; esac; done
      [ -z "$proj" ] && die "缺少项目名"
      backup_project "$proj" "$mode" "$bind" "$img" 0
      release_lock ;;
    restore)
      init_paths; need_docker; acquire_lock
      local id="" skip=0 yes=0
      while [ $# -gt 0 ]; do case "$1" in --id) id="$2"; shift;; --skip-pre) skip=1;; --yes) yes=1;; esac; shift; done
      [ -z "$id" ] && die "缺少 --id"
      if [ "$yes" = "1" ]; then restore_snapshot "$id" "$skip"; else
        if ask_yes "确认恢复 $id？" n; then restore_snapshot "$id" "$skip"; fi; fi
      release_lock ;;
    delete)
      init_paths; acquire_lock
      local id="${1:-}"; [ -z "$id" ] && die "缺少 id"
      local rec; rec="$(snapshot_record "$id")"; [ -z "$rec" ] && die "找不到 $id"
      local f; f="$(jq -r '.file' <<<"$rec")"
      rm -f "$SNAP_DIR/$f" "$SNAP_DIR/${f%.tar.*}.manifest.json" "$SNAP_DIR/$f.sha256"
      index_del "$id"; log OK "已删除 $f"; release_lock ;;
    export)
      init_paths
      if [ "${1:-}" = "--id" ]; then
        if [ "${3:-}" = "--dest" ]; then export_snapshot "${2:-}" "${4:-}"; else export_snapshot "${2:-}" "${3:-}"; fi
      else export_snapshot "${1:-}" "${2:-}"; fi ;;
    prune)
      init_paths; acquire_lock; prune_snapshots; release_lock ;;
    auto|auto-backup)
      init_paths; need_docker; acquire_lock; run_auto_backup; release_lock ;;
    config)
      if [ "${1:-}" = "--json" ]; then
        jq -n --arg root "$ROOT" --arg auto "$AUTO_ENABLED" --arg iv "$AUTO_INTERVAL" --arg max "$MAX_SIZE" \
          --arg mk "$MIN_KEEP" --arg cmp "$COMPRESS" --arg con "$CONSISTENCY" --arg ib "$INCLUDE_BIND" \
          --arg bp "$BIND_PROJECTS" --arg ii "$INCLUDE_IMAGES" --arg ap "$AUTO_PROJECTS" \
          --arg ret "$RETENTION" --arg et "$EXPORT_TARGET" \
          '{root:$root, auto_enabled:$auto, auto_interval:$iv, max_size:$max, min_keep:$mk,
            compress:$cmp, consistency:$con, include_bind:$ib, bind_projects:$bp,
            include_images:$ii, auto_projects:$ap, retention:$ret, export_target:$et}'
      else cat "$CONFIG_FILE" 2>/dev/null; fi ;;
    "") main_menu ;;
    *) cli_usage; exit 1 ;;
  esac
}

# =============================================================================
main() {
  need_root
  load_config
  need_docker
  need_tools
  index_init
  case "${1:-}" in
    "") load_config; main_menu ;;
    *)  local cmd="$1"; shift; load_config; cli_main "$cmd" "$@" ;;
  esac
}

main "$@"
