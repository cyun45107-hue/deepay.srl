#!/usr/bin/env bash
# =============================================================
#  Deepay 全栈一键部署脚本  v4.0
#
#  服务器代码路径: /www/wwwroot/deepaystudio-master
#
#  用法:
#    bash script/shell/deepay-deploy.sh          # 全栈部署（默认）
#    bash script/shell/deepay-deploy.sh all      # 后端 + PWA + H5
#    bash script/shell/deepay-deploy.sh backend  # 仅后端 Spring Boot
#    bash script/shell/deepay-deploy.sh frontend # 仅 PWA 前端
#    bash script/shell/deepay-deploy.sh app      # 仅 uni-app H5
#    bash script/shell/deepay-deploy.sh init     # 首次初始化（含数据库）
#    bash script/shell/deepay-deploy.sh db       # 仅数据库
#    bash script/shell/deepay-deploy.sh mongo    # 仅 MongoDB 检查
#
#  环境变量:
#    SKIP_PULL=true   跳过 git pull
#    SKIP_BUILD=true  跳过 Maven 构建（直接使用现有 jar）
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="${1:-all}"
SKIP_PULL="${SKIP_PULL:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
LOCK_FILE="/tmp/deepay-deploy.lock"
DATE=$(date '+%Y%m%d_%H%M%S')
T0=$(date +%s)

# ── 配置 ─────────────────────────────────────────────────────────────────
# 后端
BACKEND_DIR="$PROJECT_ROOT/run/backend"
BACKEND_JAR="$BACKEND_DIR/app.jar"
BACKEND_PID="$BACKEND_DIR/deepay.pid"
BACKEND_LOG="$BACKEND_DIR/logs/app.log"
BACKEND_PORT=48080
BACKUP_DIR="$BACKEND_DIR/backup"
BACKEND_PROFILE=prod
JAVA_OPTS="-server -Xms512m -Xmx512m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${BACKEND_DIR}/heapDump"

# 前端
PWA_SRC="$PROJECT_ROOT/yudao-ui-deepay"
PWA_DIST="$PWA_SRC/dist"
PWA_DEPLOY="/www/wwwroot/deepay.srl"

# uni-app H5
APP_SRC="$PROJECT_ROOT/yudao-ui-deepay-app"
APP_DIST="$APP_SRC/dist/build/h5"
APP_DEPLOY="/www/wwwroot/deepay.srl/app"

# 数据库
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="deepay"
DB_USER="deepay"
DB_PASS="deepay393163"

# MongoDB
MONGO_HOST="127.0.0.1"
MONGO_PORT="27017"

# 日志
BUILD_LOGS="$PROJECT_ROOT/.build-logs"

# ── 彩色输出 ──────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
info()  { echo -e "${G}[INFO]${N} $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*"; }
err()   { echo -e "${R}${B}[ERR ]${N} $*" >&2; _release_lock; exit 1; }
step()  { echo -e "\n${C}${B}━━━━  $*  ━━━━${N}"; }
ok()    { echo -e "${G}${B}  ✔  $*${N}"; }
hr()    { echo -e "${C}$(printf '━%.0s' {1..60})${N}"; }
elapsed() { echo $(( $(date +%s) - $1 ))s; }
need()  { command -v "$1" &>/dev/null || err "缺少命令: $1，请先安装"; }

mkdir -p "$BACKEND_DIR/logs" "$BACKEND_DIR/heapDump" "$BACKUP_DIR" "$BUILD_LOGS"

# ── 并发锁 ────────────────────────────────────────────────────────────────
_acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local old_pid; old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      warn "另一个部署正在进行 (PID=$old_pid)，等待最多 10 分钟..."
      local waited=0
      while kill -0 "$old_pid" 2>/dev/null && (( waited < 600 )); do
        sleep 5; (( waited += 5 ))
      done
      kill -0 "$old_pid" 2>/dev/null && err "超时：部署进程仍在运行，手动解锁: rm $LOCK_FILE"
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap '_release_lock' EXIT INT TERM
}
_release_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }

# ── git pull ──────────────────────────────────────────────────────────────
do_git_pull() {
  if [ "$SKIP_PULL" = "true" ]; then
    info "SKIP_PULL=true，跳过 git pull"
    return 0
  fi
  step "Git 拉取最新代码"
  cd "$PROJECT_ROOT"
  local branch; branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")
  local before; before=$(git rev-parse --short HEAD 2>/dev/null || echo "?")

  for attempt in 1 2 3; do
    if git fetch origin "$branch" --prune 2>&1 \
       && git reset --hard "origin/$branch" 2>&1; then
      break
    fi
    warn "第 $attempt 次拉取失败，5 秒后重试..."
    sleep 5
    if (( attempt == 3 )); then
      warn "git pull 失败，使用当前本地代码继续部署"
      return 0
    fi
  done

  local after; after=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
  if [ "$before" != "$after" ]; then
    ok "代码已更新: $before → $after"
    git log --oneline "$before..$after" 2>/dev/null | head -5 | sed 's/^/   /' || true
  else
    info "代码已是最新 ($after)"
  fi
}

# ── npm 安装（自动降级）──────────────────────────────────────────────────
_npm_install() {
  info "安装 npm 依赖..."
  if [ -f package-lock.json ]; then
    npm ci --prefer-offline 2>&1 && return 0
    warn "npm ci 失败，尝试 --legacy-peer-deps..."
    npm ci --legacy-peer-deps 2>&1 && return 0
    warn "清除 node_modules 重试..."
    rm -rf node_modules package-lock.json
  fi
  npm install 2>&1 && return 0
  warn "npm install 失败，尝试 --legacy-peer-deps..."
  npm install --legacy-peer-deps 2>&1 || err "npm install 彻底失败，请检查 package.json"
}

# ── Nginx 热重载 ──────────────────────────────────────────────────────────
_nginx_reload() {
  if command -v nginx &>/dev/null && nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    ok "Nginx 已热重载"
  fi
}

# ── rsync 部署 ────────────────────────────────────────────────────────────
_deploy_files() {
  local src="$1" dst="$2" name="$3"
  [ -d "$src" ] || err "[$name] 构建产物目录不存在: $src"
  mkdir -p "$dst"
  if command -v rsync &>/dev/null; then
    rsync -a --delete --exclude='.DS_Store' "$src/" "$dst/"
  else
    rm -rf "${dst:?}/"* && cp -rf "$src/." "$dst/"
  fi
  ok "[$name] 已部署 → $dst"
}

# ── MySQL 数据库 ──────────────────────────────────────────────────────────
do_db() {
  step "MySQL 数据库初始化"
  need mysql

  if ! mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" \
       -e "SELECT 1;" "$DB_NAME" &>/dev/null 2>&1; then
    warn "数据库 '$DB_NAME' 不可连接，尝试用 root 创建..."
    mysql -h "$DB_HOST" -P "$DB_PORT" -u root -p <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    ok "数据库和账号已创建"
  else
    ok "数据库连接正常: $DB_NAME @ $DB_HOST:$DB_PORT"
  fi

  local tbl_count
  tbl_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" \
    -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
    2>/dev/null || echo "0")

  if (( tbl_count < 10 )); then
    info "表数量 $tbl_count，执行初始化 SQL..."
    local sql_dir="$PROJECT_ROOT/sql/mysql"
    for f in "$sql_dir/ruoyi-vue-pro.sql" "$sql_dir/quartz.sql" "$sql_dir/deepay.sql"; do
      if [ -f "$f" ]; then
        info "  → 导入 $(basename "$f")"
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
          < "$f" 2>&1 | grep -iE "^error" || true
        ok "  ✔ $(basename "$f")"
      else
        warn "SQL 文件不存在: $f"
      fi
    done
    ok "数据库初始化完成"
  else
    ok "数据库已初始化（$tbl_count 张表），跳过"
    # 增量 SQL
    local updates_dir="$PROJECT_ROOT/sql/mysql/updates"
    if [ -d "$updates_dir" ]; then
      local applied="$BUILD_LOGS/applied-sql.txt"; touch "$applied"
      while IFS= read -r f; do
        local fname; fname=$(basename "$f")
        if ! grep -qxF "$fname" "$applied" 2>/dev/null; then
          info "增量 SQL: $fname"
          mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
            < "$f" 2>&1 | grep -iE "^error" || true
          echo "$fname" >> "$applied"
          ok "  ✔ $fname"
        fi
      done < <(find "$updates_dir" -maxdepth 1 -name "*.sql" | sort)
    fi
  fi
}

# ── MongoDB ───────────────────────────────────────────────────────────────
do_mongo() {
  step "MongoDB 检查"
  if systemctl is-active --quiet mongod 2>/dev/null; then
    ok "MongoDB 运行中（systemd）"
  elif command -v docker &>/dev/null \
       && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "mongo"; then
    ok "MongoDB 运行在 Docker 容器中"
  elif command -v mongod &>/dev/null; then
    warn "MongoDB 未运行，尝试启动..."
    systemctl start mongod 2>/dev/null \
      || mongod --fork --logpath /var/log/mongod.log --dbpath /var/lib/mongo 2>/dev/null \
      || warn "请手动执行: systemctl start mongod"
    sleep 2
  else
    warn "未检测到 MongoDB，AI 功能暂不可用"
    warn "安装: apt-get install -y mongodb-org && systemctl start mongod"
  fi
}

# ── 后端 Spring Boot ──────────────────────────────────────────────────────
_stop_backend() {
  if [ -f "$BACKEND_PID" ]; then
    local pid; pid=$(cat "$BACKEND_PID" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      info "停止旧进程 PID=$pid ..."
      kill -15 "$pid" 2>/dev/null || true
      local i=0
      while kill -0 "$pid" 2>/dev/null && (( i < 30 )); do
        sleep 1; printf "."; (( i++ ))
      done
      echo ""
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      ok "旧进程已停止"
    fi
    rm -f "$BACKEND_PID"
  else
    # 按端口兜底查找
    local port_pid
    port_pid=$(ss -lntp 2>/dev/null | grep ":${BACKEND_PORT} " \
      | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [ -n "$port_pid" ]; then
      warn "端口 $BACKEND_PORT 被 PID=$port_pid 占用，强制停止"
      kill -9 "$port_pid" 2>/dev/null || true
    fi
  fi
}

do_backend() {
  step "后端 Spring Boot 构建部署"
  need java
  info "Java: $(java -version 2>&1 | head -1)"

  if [ "$SKIP_BUILD" = "true" ] && [ -f "$BACKEND_JAR" ]; then
    info "SKIP_BUILD=true，使用现有 jar: $BACKEND_JAR"
  else
    need mvn
    info "Maven: $(mvn -version 2>&1 | head -1)"
    local build_log="$BUILD_LOGS/backend-$DATE.log"
    info "Maven 构建中，日志: $build_log"
    cd "$PROJECT_ROOT"

    # 先安装本地 BOM（SNAPSHOT 版本，远程仓库没有）
    mvn install -f yudao-dependencies/pom.xml -DskipTests -q --no-transfer-progress \
      >> "$build_log" 2>&1 || err "yudao-dependencies 安装失败，查看: $build_log"

    mvn clean package -DskipTests --batch-mode \
      -pl yudao-server -am \
      --no-transfer-progress \
      2>&1 | tee -a "$build_log" | grep -E "BUILD|ERROR|yudao-server" || true

    local jar_file
    jar_file=$(find "$PROJECT_ROOT/yudao-server/target" -maxdepth 1 \
      -name "*.jar" ! -name "*sources*" ! -name "*javadoc*" 2>/dev/null | head -1)
    [ -f "$jar_file" ] || err "构建失败，未找到 jar！查看: $build_log"
    ok "构建成功: $jar_file"

    # 备份旧 jar
    if [ -f "$BACKEND_JAR" ]; then
      cp -f "$BACKEND_JAR" "$BACKUP_DIR/app-$DATE.jar"
      ls -1t "$BACKUP_DIR"/app-*.jar 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
      ok "旧 jar 已备份"
    fi
    cp -f "$jar_file" "$BACKEND_JAR"
    ok "新 jar → $BACKEND_JAR"
  fi

  _stop_backend

  cd "$BACKEND_DIR"
  # shellcheck disable=SC2086
  nohup java $JAVA_OPTS \
    -jar "$BACKEND_JAR" \
    --spring.profiles.active="$BACKEND_PROFILE" \
    --spring.config.additional-location=file:./config/ \
    >> "$BACKEND_LOG" 2>&1 &
  echo $! > "$BACKEND_PID"
  ok "后端已启动  PID=$(cat "$BACKEND_PID")  日志→ $BACKEND_LOG"

  # 健康检查（最多等 120s）
  info "等待后端就绪..."
  local status="000"
  for i in $(seq 1 120); do
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://127.0.0.1:${BACKEND_PORT}/actuator/health" 2>/dev/null || echo "000")
    [ "$status" = "200" ] && break
    printf "."; sleep 1
  done
  echo ""
  if [ "$status" = "200" ]; then
    ok "后端健康检查通过 ✔"
  else
    warn "120s 内未就绪（HTTP $status），查看日志: tail -50 $BACKEND_LOG"
  fi
}

# ── PWA 前端 ──────────────────────────────────────────────────────────────
do_frontend() {
  step "PWA 前端构建部署（Vue3 + Vite）"
  need node; need npm
  info "Node: $(node -v)  npm: $(npm -v)"
  local build_log="$BUILD_LOGS/pwa-$DATE.log"
  cd "$PWA_SRC"
  _npm_install 2>&1 | tee -a "$build_log" | tail -3
  npm run build 2>&1 | tee "$build_log" | tail -5
  [ -d "$PWA_DIST" ] || err "PWA 构建失败，未找到产物目录: $PWA_DIST\n查看: $build_log"
  ok "PWA 构建完成 → $PWA_DIST"
  _deploy_files "$PWA_DIST" "$PWA_DEPLOY" "PWA"
  _nginx_reload
}

# ── uni-app H5 ────────────────────────────────────────────────────────────
do_app() {
  step "uni-app H5 构建部署"
  need node; need npm
  local build_log="$BUILD_LOGS/h5-$DATE.log"
  cd "$APP_SRC"
  _npm_install 2>&1 | tee -a "$build_log" | tail -3
  npm run build:h5 2>&1 | tee "$build_log" | tail -5
  [ -d "$APP_DIST" ] || err "H5 构建失败，未找到产物目录: $APP_DIST\n查看: $build_log"
  ok "H5 构建完成 → $APP_DIST"
  _deploy_files "$APP_DIST" "$APP_DEPLOY" "H5"
  _nginx_reload
}

# ── 主流程 ────────────────────────────────────────────────────────────────
_acquire_lock

hr
echo -e "${C}${B}  Deepay Auto Deploy  v4.0${N}"
info "模式    : $MODE"
info "时间    : $(date '+%Y-%m-%d %H:%M:%S')"
info "代码根  : $PROJECT_ROOT"
hr

do_git_pull

case "$MODE" in
  init)
    do_db
    do_mongo
    do_backend
    do_frontend
    do_app
    ;;
  all|"")
    do_backend
    do_frontend
    do_app
    ;;
  backend)  do_backend  ;;
  frontend) do_frontend ;;
  app)      do_app      ;;
  db)       do_db       ;;
  mongo)    do_mongo    ;;
  *)
    err "未知模式: $MODE\n用法: $0 [init|all|backend|frontend|app|db|mongo]"
    ;;
esac

hr
ok "全部完成 🎉  总耗时: $(elapsed $T0)"
echo ""
echo "  访问地址："
echo "    🌐  https://deepay.srl          主站 PWA"
echo "    📱  https://deepay.srl/app      H5 应用"
echo "    🔌  http://127.0.0.1:$BACKEND_PORT  Spring Boot API"
echo ""
echo "  日志位置："
echo "    后端日志 : $BACKEND_LOG"
echo "    构建日志 : $BUILD_LOGS/"
hr
