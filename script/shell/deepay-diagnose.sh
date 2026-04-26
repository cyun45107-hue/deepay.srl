#!/usr/bin/env bash
# =============================================================
#  Deepay 全自动排错诊断脚本  v1.0
#
#  功能：
#    1. Java 源码静态扫描（import/包名/Bean冲突/注解缺失）
#    2. Maven 构建错误分析（自动提取 ERROR 并给出修复建议）
#    3. 数据库连通性检查（MySQL + MongoDB）
#    4. 后端进程 / 端口健康检查
#    5. 前端依赖 & 构建预检
#    6. 生成带时间戳的报告文件
#
#  用法：
#    bash script/shell/deepay-diagnose.sh          # 全量检查
#    bash script/shell/deepay-diagnose.sh quick    # 快速扫（跳过 Maven 构建）
#    bash script/shell/deepay-diagnose.sh maven    # 只跑 Maven 构建分析
#    bash script/shell/deepay-diagnose.sh db       # 只查 DB 连通性
#    bash script/shell/deepay-diagnose.sh java     # 只做 Java 静态扫描
#
#  环境变量覆盖：
#    DB_PASS=xxx   DB_USER=xxx   MONGO_PORT=27017
# =============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="${1:-all}"
DATE="$(date '+%Y%m%d_%H%M%S')"
REPORT_DIR="$ROOT/.diagnose"
REPORT="$REPORT_DIR/report_${DATE}.txt"
BUILD_LOG="$REPORT_DIR/build_${DATE}.log"
mkdir -p "$REPORT_DIR"

# ━━━ 配置（与 deepay-deploy.sh 保持一致）━━━━━━━━━━━━
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-deepay}"
DB_USER="${DB_USER:-deepay}"
DB_PASS="${DB_PASS:-deepay393163}"
MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
MONGO_PORT="${MONGO_PORT:-27017}"
BACKEND_PORT="${BACKEND_PORT:-48080}"
DEEPAY_SRC="$ROOT/yudao-module-deepay/src/main/java"
MVN="mvn"
command -v mvn  &>/dev/null || MVN="./mvnw"

# ━━━ 颜色 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'
C='\033[0;36m'; B='\033[1m'; N='\033[0m'
OK='\033[0;32m✔\033[0m'; FAIL='\033[0;31m✘\033[0m'; WARN='\033[0;33m!\033[0m'
info()  { echo -e "${G}[INFO ]${N} $*" | tee -a "$REPORT"; }
warn()  { echo -e "${Y}[WARN ]${N} $*" | tee -a "$REPORT"; }
error() { echo -e "${R}[ERROR]${N} $*" | tee -a "$REPORT"; }
step()  { echo -e "\n${C}${B}══ $* ══${N}" | tee -a "$REPORT"; }
ok()    { echo -e "  ${OK} $*" | tee -a "$REPORT"; }
bad()   { echo -e "  ${FAIL} $*" | tee -a "$REPORT"; ISSUE_COUNT=$((ISSUE_COUNT+1)); }
hint()  { echo -e "     ${Y}▶ 修复建议: $*${N}" | tee -a "$REPORT"; }
hr()    { echo -e "${C}$(printf '─%.0s' {1..60})${N}" | tee -a "$REPORT"; }
ISSUE_COUNT=0
DIAG_START=$(date +%s)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §1  Java 源码静态扫描
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_java() {
  step "§1 Java 源码静态扫描（deepay module）"

  [ -d "$DEEPAY_SRC" ] || { bad "源码目录不存在: $DEEPAY_SRC"; return; }

  local java_files
  mapfile -t java_files < <(find "$DEEPAY_SRC" -name "*.java" | sort)
  info "扫描文件数: ${#java_files[@]}"

  # ── 1a: 重复 class 名检测（Spring Bean 冲突）──────────────
  info "1a. 检查 Spring Bean 名称冲突..."
  local -A class_files=()
  local conflicts=0
  for f in "${java_files[@]}"; do
    local pkg class fqn
    pkg=$(grep -m1 '^package ' "$f" 2>/dev/null | sed 's/package //;s/;//;s/ //g') || continue
    class=$(grep -oP '(?<=^(public\s|abstract\s|final\s)*)(class|interface|enum)\s+\K\w+' "$f" \
            2>/dev/null | head -1) || continue
    [ -z "$class" ] && continue
    fqn="${pkg}.${class}"
    if [[ -v "class_files[$class]" ]] && [[ "${class_files[$class]}" != "$f" ]]; then
      bad "Bean 冲突: '$class' 同时存在于:"
      hint "删除旧版/重命名其中一个，或给 @Service 加 name 参数区分"
      echo "         ${class_files[$class]}" | tee -a "$REPORT"
      echo "         $f" | tee -a "$REPORT"
      conflicts=$((conflicts+1))
    else
      class_files[$class]="$f"
    fi
  done
  [ $conflicts -eq 0 ] && ok "Bean 名称冲突: 无"

  # ── 1b: 包声明 vs 目录 ────────────────────────────────────
  info "1b. 检查 package 声明与目录是否一致..."
  local mismatch=0
  for f in "${java_files[@]}"; do
    local pkg dir_pkg
    pkg=$(grep -m1 '^package ' "$f" 2>/dev/null | sed 's/package //;s/;//;s/ //g') || continue
    dir_pkg=$(echo "$f" | grep -oP '(?<=main/java/).*' | sed 's|/[^/]*$||;s|/|.|g')
    if [ "$pkg" != "$dir_pkg" ]; then
      bad "包名与目录不符: $f"
      hint "将 package $pkg 修改为 package $dir_pkg"
      mismatch=$((mismatch+1))
    fi
  done
  [ $mismatch -eq 0 ] && ok "包名与目录: 全部一致"

  # ── 1c: public class 名 vs 文件名 ────────────────────────
  info "1c. 检查 public class 名与文件名..."
  local name_mismatch=0
  for f in "${java_files[@]}"; do
    local stem cls
    stem=$(basename "$f" .java)
    cls=$(grep -oP '(?<=^public\s(abstract\s|final\s)*)(class|interface|enum)\s+\K\w+' \
          "$f" 2>/dev/null | head -1) || continue
    [ -z "$cls" ] && continue
    if [ "$cls" != "$stem" ]; then
      bad "文件名不符: $f → public class '$cls' ≠ '$stem'"
      hint "将文件重命名为 ${cls}.java 或修改 public class 名"
      name_mismatch=$((name_mismatch+1))
    fi
  done
  [ $name_mismatch -eq 0 ] && ok "public class 名 vs 文件名: 全部一致"

  # ── 1d: @Repository 缺失 ─────────────────────────────────
  info "1d. 检查 MongoDB Repository 是否缺少 @Repository..."
  local repo_missing=0
  for f in "${java_files[@]}"; do
    local base
    base=$(basename "$f" .java)
    grep -q 'MongoRepository\|CrudRepository\|PagingAndSortingRepository' "$f" 2>/dev/null || continue
    grep -q '@Repository' "$f" 2>/dev/null && continue
    bad "缺少 @Repository: $f"
    hint "在接口声明前加 @Repository"
    repo_missing=$((repo_missing+1))
  done
  [ $repo_missing -eq 0 ] && ok "@Repository 注解: 全部到位"

  # ── 1e: @Mapper 缺失 ─────────────────────────────────────
  info "1e. 检查 MyBatis Mapper 是否缺少 @Mapper..."
  local mapper_missing=0
  for f in "${java_files[@]}"; do
    local base
    base=$(basename "$f" .java)
    [[ "$base" == *Mapper ]] || continue
    grep -q 'extends BaseMapper\|extends BaseMapperX' "$f" 2>/dev/null || continue
    grep -q '@Mapper' "$f" 2>/dev/null && continue
    [[ "$base" == "BaseMapperX" ]] && continue
    bad "缺少 @Mapper: $f"
    hint "在接口声明前加 @Mapper"
    mapper_missing=$((mapper_missing+1))
  done
  [ $mapper_missing -eq 0 ] && ok "@Mapper 注解: 全部到位"

  # ── 1f: void endpoint 检查 ───────────────────────────────
  info "1f. 检查 Controller endpoint 方法返回 void..."
  local void_count=0
  for f in "${java_files[@]}"; do
    [[ "$f" == *Controller* ]] || continue
    # 找 @XxxMapping 后紧跟 public void 的情况
    python3 - "$f" << 'PYEOF' 2>/dev/null
import re, sys
lines = open(sys.argv[1]).read().split('\n')
for i,l in enumerate(lines):
    if re.search(r'@(Get|Post|Put|Delete|Patch|Request)Mapping', l):
        for j in range(i+1, min(i+5, len(lines))):
            if re.match(r'\s+public\s+void\s+\w+\s*\(', lines[j]):
                print(f"  ✘  void endpoint: {sys.argv[1]}:{j+1}: {lines[j].strip()[:70]}")
                break
            if re.match(r'\s+public\s+', lines[j]): break
PYEOF
    void_count=$(( void_count + $(python3 - "$f" 2>/dev/null << 'PYEOF'
import re, sys
c=0
lines = open(sys.argv[1]).read().split('\n')
for i,l in enumerate(lines):
    if re.search(r'@(Get|Post|Put|Delete|Patch|Request)Mapping', l):
        for j in range(i+1, min(i+5, len(lines))):
            if re.match(r'\s+public\s+void\s+\w+\s*\(', lines[j]): c+=1; break
            if re.match(r'\s+public\s+', lines[j]): break
print(c)
PYEOF
) ))
  done
  if [ $void_count -gt 0 ]; then
    bad "共 $void_count 个 endpoint 返回 void"
    hint "改为返回 CommonResult<Boolean> 并 return CommonResult.success(true)"
    ISSUE_COUNT=$((ISSUE_COUNT+void_count))
  else
    ok "endpoint 返回类型: 全部正常"
  fi

  # ── 1g: TODO/FIXME 统计 ───────────────────────────────────
  info "1g. 统计 TODO / FIXME 占位..."
  local todos
  todos=$(grep -rn 'TODO\|FIXME\|HACK\|NotImplemented' "$DEEPAY_SRC" \
          --include="*.java" 2>/dev/null | grep -v '//' | wc -l || true)
  # with // comments
  todos=$(grep -rn '//.*\(TODO\|FIXME\|HACK\)' "$DEEPAY_SRC" \
          --include="*.java" 2>/dev/null | wc -l || true)
  if [ "$todos" -gt 0 ]; then
    warn "发现 $todos 处 TODO/FIXME（需后续补全）:"
    grep -rn '//.*\(TODO\|FIXME\|HACK\)' "$DEEPAY_SRC" \
      --include="*.java" 2>/dev/null \
      | sed 's|'"$ROOT/"'||' \
      | awk -F: '{printf "     %s:%s  %s\n",$1,$2,$3}' \
      | head -20 | tee -a "$REPORT"
  else
    ok "TODO/FIXME: 无"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §2  Maven 构建错误分析
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_maven() {
  step "§2 Maven 构建分析"

  cd "$ROOT" || return

  # 检查 Java 环境
  if ! command -v java &>/dev/null; then
    bad "未找到 java 命令"
    hint "安装 JDK 17: apt install openjdk-17-jdk 或 yum install java-17-openjdk-devel"
    return
  fi
  local java_ver
  java_ver=$(java -version 2>&1 | head -1)
  info "Java: $java_ver"

  if ! command -v "$MVN" &>/dev/null; then
    bad "未找到 mvn 命令"
    hint "安装 Maven: apt install maven 或下载 https://maven.apache.org/download.cgi"
    return
  fi
  info "Maven: $($MVN -v 2>/dev/null | head -1)"

  # 检查 pom.xml 中 yudao-dependencies 是否可解析（本地 vs 远程）
  info "检查 yudao-dependencies 本地仓库..."
  local dep_rev
  dep_rev=$(grep -oP '(?<=<revision>)[^<]+' "$ROOT/pom.xml" 2>/dev/null | head -1)
  info "项目版本 (revision): ${dep_rev:-未知}"

  local m2_dep
  m2_dep="$HOME/.m2/repository/cn/iocoder/boot/yudao-dependencies/${dep_rev}/yudao-dependencies-${dep_rev}.pom"
  if [ -n "$dep_rev" ] && [ ! -f "$m2_dep" ]; then
    warn "yudao-dependencies-${dep_rev}.pom 不在本地 Maven 仓库"
    hint "先在项目根目录执行: mvn install -pl yudao-dependencies -N -DskipTests"
    hint "或: mvn install -pl . -N -DskipTests  （安装父 pom）"
  else
    ok "yudao-dependencies 本地缓存: 存在"
  fi

  # 执行编译并捕获错误
  info "执行 mvn clean compile -DskipTests -e ... (输出到 $BUILD_LOG)"
  local mvn_exit=0
  {
    "$MVN" clean compile \
      -DskipTests \
      -pl yudao-module-deepay \
      -am \
      --no-transfer-progress \
      -e 2>&1
  } > "$BUILD_LOG" || mvn_exit=$?

  if [ $mvn_exit -eq 0 ]; then
    ok "Maven 编译: 成功 ✔"
    return
  fi

  bad "Maven 编译失败 (exit=$mvn_exit)"

  # ── 自动分析错误类型 ─────────────────────────────────────
  info "自动分析构建错误..."
  local errors_found=0

  # 1. package does not exist
  while IFS= read -r line; do
    local pkg
    pkg=$(echo "$line" | grep -oP '(?<=package )[^ ]+(?= does not exist)')
    if [ -n "$pkg" ]; then
      local src_file
      src_file=$(echo "$line" | grep -oP '[^ ]+\.java' | head -1)
      bad "缺少包: $pkg"
      hint "检查 $src_file 的 import 是否正确，或对应服务类是否已创建"
      errors_found=$((errors_found+1))
    fi
  done < <(grep 'does not exist' "$BUILD_LOG" 2>/dev/null)

  # 2. cannot find symbol
  while IFS= read -r line; do
    bad "找不到符号: $line"
    hint "检查类名拼写、import 是否缺失，或对应类是否已编译"
    errors_found=$((errors_found+1))
  done < <(grep 'cannot find symbol' "$BUILD_LOG" 2>/dev/null | head -10)

  # 3. incompatible types
  while IFS= read -r line; do
    bad "类型不兼容: $line"
    hint "检查方法返回类型或赋值类型是否匹配"
    errors_found=$((errors_found+1))
  done < <(grep 'incompatible types' "$BUILD_LOG" 2>/dev/null | head -5)

  # 4. Non-resolvable import POM
  while IFS= read -r line; do
    local pom_art
    pom_art=$(echo "$line" | grep -oP '(?<=Non-resolvable import POM: )[^:]+:[^:]+:[^:]+(?=:pom)')
    if [ -n "$pom_art" ]; then
      bad "父 POM 无法解析: $pom_art"
      hint "执行: cd $ROOT && mvn install -N -DskipTests  先安装父 pom"
    fi
    errors_found=$((errors_found+1))
  done < <(grep 'Non-resolvable import POM' "$BUILD_LOG" 2>/dev/null | head -3)

  # 5. missing version
  while IFS= read -r line; do
    local dep
    dep=$(echo "$line" | grep -oP "(?<='dependencies.dependency.version' for )[^ ]+")
    if [ -n "$dep" ]; then
      bad "依赖版本缺失: $dep"
      hint "确认 yudao-dependencies 已正确安装到本地仓库 (mvn install -pl yudao-dependencies -N)"
    fi
    errors_found=$((errors_found+1))
  done < <(grep "missing" "$BUILD_LOG" 2>/dev/null | grep "version" | head -10)

  # 6. duplicate class
  while IFS= read -r line; do
    bad "重复 class: $line"
    hint "同一包下存在同名类，删除重复文件"
    errors_found=$((errors_found+1))
  done < <(grep 'duplicate class' "$BUILD_LOG" 2>/dev/null | head -5)

  # 7. 通用 ERROR 行（兜底）
  if [ $errors_found -eq 0 ]; then
    info "通用 ERROR 行提取（前20条）:"
    grep '^\[ERROR\]' "$BUILD_LOG" 2>/dev/null | grep -v '^\[ERROR\] $' | head -20 \
      | while IFS= read -r l; do bad "$l"; done
  fi

  info "完整构建日志: $BUILD_LOG"
  hint "手动查看: tail -200 $BUILD_LOG"
  hint "或: grep '\\[ERROR\\]' $BUILD_LOG | head -50"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §3  数据库连通性检查
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_db() {
  step "§3 数据库连通性检查"

  # ── MySQL ────────────────────────────────────────────────
  info "MySQL: ${DB_HOST}:${DB_PORT} / ${DB_NAME}"
  if command -v mysql &>/dev/null; then
    local my_out
    my_out=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" \
             -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
             2>&1 || true)
    if echo "$my_out" | grep -qE '^[0-9]+'; then
      local tbl_count
      tbl_count=$(echo "$my_out" | grep -E '^[0-9]+' | tail -1 | tr -d ' ')
      ok "MySQL 连接成功，${DB_NAME} 库中有 ${tbl_count} 张表"
      if [ "$tbl_count" -lt 10 ]; then
        warn "表数量偏少（${tbl_count}），可能未执行初始化 SQL"
        hint "执行: mysql -u${DB_USER} -p${DB_PASS} ${DB_NAME} < $ROOT/sql/mysql.sql"
      fi
    elif echo "$my_out" | grep -qi 'access denied'; then
      bad "MySQL 认证失败 (Access Denied)"
      hint "检查 DB_USER=${DB_USER} / DB_PASS 是否正确"
    elif echo "$my_out" | grep -qi 'can.*t connect\|refused\|unknown host'; then
      bad "MySQL 无法连接 (${DB_HOST}:${DB_PORT})"
      hint "检查 MySQL 是否已启动: systemctl status mysql  或  ss -tlnp | grep 3306"
    else
      bad "MySQL 检查异常: $my_out"
    fi
  else
    warn "mysql 命令不存在，跳过 MySQL 连通检查"
    hint "安装: apt install mysql-client 或 yum install mysql"
    # 尝试 TCP 端口连接
    if command -v nc &>/dev/null; then
      nc -z -w3 "$DB_HOST" "$DB_PORT" 2>/dev/null \
        && ok "MySQL 端口 $DB_PORT 可达" \
        || bad "MySQL 端口 $DB_PORT 不可达"
    fi
  fi

  # ── MongoDB ───────────────────────────────────────────────
  info "MongoDB: ${MONGO_HOST}:${MONGO_PORT}"
  if command -v mongosh &>/dev/null || command -v mongo &>/dev/null; then
    local mcmd; command -v mongosh &>/dev/null && mcmd="mongosh" || mcmd="mongo"
    local mg_out
    mg_out=$("$mcmd" --host "$MONGO_HOST" --port "$MONGO_PORT" --quiet \
             --eval "db.adminCommand('ping').ok" 2>&1 || true)
    if echo "$mg_out" | grep -q '^1$'; then
      ok "MongoDB 连接成功 (ping OK)"
    else
      bad "MongoDB 连接失败"
      hint "检查 MongoDB 是否运行: systemctl status mongod  或  ss -tlnp | grep 27017"
      hint "如需副本集: 参考 docker-compose.mongodb-rs.yml"
    fi
  else
    warn "mongosh/mongo 命令不存在，用端口检查"
    if command -v nc &>/dev/null; then
      nc -z -w3 "$MONGO_HOST" "$MONGO_PORT" 2>/dev/null \
        && ok "MongoDB 端口 $MONGO_PORT 可达" \
        || bad "MongoDB 端口 $MONGO_PORT 不可达"
    else
      warn "nc 命令不存在，跳过 MongoDB 端口检查"
    fi
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §4  后端进程 & 端口健康检查
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_backend() {
  step "§4 后端进程 & 端口"

  local pid_file="$ROOT/run/backend/deepay.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      ok "Spring Boot 进程运行中 (PID=$pid)"
    else
      bad "PID 文件存在但进程已停止 (PID=$pid)"
      hint "重启: bash $ROOT/script/shell/deepay-deploy.sh backend"
    fi
  else
    # 无 pid 文件，直接查端口
    local java_pid
    java_pid=$(ss -tlnp 2>/dev/null | grep ":${BACKEND_PORT}" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [ -n "$java_pid" ]; then
      ok "端口 $BACKEND_PORT 已监听 (PID=$java_pid)"
    else
      bad "端口 $BACKEND_PORT 无进程监听"
      hint "启动后端: bash $ROOT/script/shell/deepay-deploy.sh backend"
    fi
  fi

  # 检查 API 健康端点
  if command -v curl &>/dev/null; then
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
                --connect-timeout 3 \
                "http://127.0.0.1:${BACKEND_PORT}/actuator/health" 2>/dev/null || echo "000")
    case "$http_code" in
      200) ok "健康检查 /actuator/health: HTTP 200 ✔" ;;
      000) warn "健康检查无响应（服务可能未启动）" ;;
      *)   warn "健康检查返回 HTTP $http_code" ;;
    esac
  fi

  # 检查 JAR 文件
  local jar="$ROOT/run/backend/app.jar"
  if [ -f "$jar" ]; then
    local jar_date
    jar_date=$(date -r "$jar" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$jar" 2>/dev/null | cut -d. -f1)
    ok "JAR 文件存在: $jar  (修改时间: $jar_date)"
  else
    bad "JAR 文件不存在: $jar"
    hint "构建: cd $ROOT/yudao-module-deepay && mvn clean package -DskipTests"
    hint "或全栈构建: bash $ROOT/script/shell/deepay-deploy.sh backend"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §5  前端依赖 & 环境预检
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_frontend() {
  step "§5 前端环境预检"

  # Node / npm 版本
  if command -v node &>/dev/null; then
    local nv
    nv=$(node -v)
    local nmajor
    nmajor="${nv//v/}"; nmajor="${nmajor%%.*}"
    if (( nmajor >= 18 && nmajor <= 24 )); then
      ok "Node $nv ✔"
    else
      bad "Node $nv 不在推荐范围 18~24"
      hint "使用 nvm: nvm install 20 && nvm use 20"
    fi
    info "npm  : $(npm -v 2>/dev/null || echo N/A)"
  else
    bad "Node.js 未安装"
    hint "安装: curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install nodejs"
  fi

  # PWA 前端
  local pwa_dir="$ROOT/yudao-ui-deepay"
  if [ -d "$pwa_dir" ]; then
    info "PWA 前端目录: $pwa_dir"
    if [ ! -d "$pwa_dir/node_modules" ]; then
      bad "PWA 依赖未安装 (node_modules 不存在)"
      hint "cd $pwa_dir && npm install"
    else
      ok "PWA node_modules: 已安装"
    fi
    if [ -f "$pwa_dir/dist/index.html" ]; then
      ok "PWA dist: 已构建"
    else
      warn "PWA dist/index.html 不存在，尚未构建"
      hint "cd $pwa_dir && npm run build"
    fi
  else
    warn "PWA 前端目录不存在: $pwa_dir"
  fi

  # uni-app H5
  local app_dir="$ROOT/yudao-ui-deepay-app"
  if [ -d "$app_dir" ]; then
    info "uni-app 目录: $app_dir"
    if [ ! -d "$app_dir/node_modules" ]; then
      bad "uni-app 依赖未安装"
      hint "cd $app_dir && npm install"
    else
      ok "uni-app node_modules: 已安装"
    fi
    if [ -f "$app_dir/dist/build/h5/index.html" ]; then
      ok "uni-app H5 dist: 已构建"
    else
      warn "uni-app H5 未构建"
      hint "cd $app_dir && npm run build:h5"
    fi
  else
    warn "uni-app 目录不存在: $app_dir"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §6  Nginx 配置检查
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_nginx() {
  step "§6 Nginx 检查"
  if ! command -v nginx &>/dev/null; then
    warn "nginx 命令不存在，跳过"
    return
  fi
  local nginx_test
  nginx_test=$(nginx -t 2>&1 || true)
  if echo "$nginx_test" | grep -q 'successful'; then
    ok "nginx -t: 配置语法正常"
  else
    bad "nginx -t: 配置有错误"
    echo "$nginx_test" | tee -a "$REPORT"
    hint "修复 nginx 配置后执行: nginx -s reload"
  fi
  if pgrep -x nginx &>/dev/null; then
    ok "Nginx 进程: 运行中"
  else
    bad "Nginx 未运行"
    hint "启动: systemctl start nginx 或 nginx"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  §7  磁盘 & 内存 & Java 堆
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
scan_system() {
  step "§7 系统资源"
  # 磁盘
  local free_mb
  free_mb=$(df -BM "$ROOT" 2>/dev/null | awk 'NR==2{gsub("M","",$4); print $4}' || echo 0)
  if (( free_mb < 500 )); then
    bad "磁盘剩余 ${free_mb}MB（< 500MB），构建或运行可能失败"
    hint "清理: rm -rf $ROOT/yudao-module-deepay/target  rm -rf ~/.m2/repository/.m2-lock*"
  else
    ok "磁盘剩余: ${free_mb}MB ✔"
  fi
  # 内存
  if command -v free &>/dev/null; then
    local free_ram
    free_ram=$(free -m 2>/dev/null | awk '/Mem:/{print $7}' || echo 0)
    if (( free_ram < 256 )); then
      bad "可用内存 ${free_ram}MB（< 256MB），Spring Boot 启动可能 OOM"
      hint "减小堆: 编辑 JAVA_OPTS 改为 -Xms256m -Xmx256m"
    else
      ok "可用内存: ${free_ram}MB ✔"
    fi
  fi
  # Maven 本地仓库大小
  local m2_size
  m2_size=$(du -sh "$HOME/.m2/repository" 2>/dev/null | awk '{print $1}' || echo "未知")
  info "Maven 本地仓库大小: $m2_size"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  主入口
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
  echo ""
  hr
  echo -e "${C}${B}  Deepay 自动诊断报告  $(date '+%Y-%m-%d %H:%M:%S')${N}"
  hr
} | tee "$REPORT"

case "$MODE" in
  java)
    scan_java
    ;;
  maven)
    scan_maven
    ;;
  db)
    scan_db
    ;;
  quick)
    scan_java
    scan_backend
    scan_frontend
    scan_db
    scan_nginx
    scan_system
    ;;
  all|*)
    scan_java
    scan_maven
    scan_db
    scan_backend
    scan_frontend
    scan_nginx
    scan_system
    ;;
esac

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  最终汇总
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ELAPSED=$(( $(date +%s) - DIAG_START ))
{
  hr
  if [ "$ISSUE_COUNT" -eq 0 ]; then
    echo -e "${G}${B}✔  诊断完成，未发现严重问题。耗时 ${ELAPSED}s${N}"
  else
    echo -e "${R}${B}✘  诊断完成，发现 ${ISSUE_COUNT} 个严重问题，请按上方修复建议处理。耗时 ${ELAPSED}s${N}"
  fi
  echo ""
  echo "  报告文件: $REPORT"
  [ -f "$BUILD_LOG" ] && echo "  构建日志: $BUILD_LOG"
  hr
} | tee -a "$REPORT"

exit $([ "$ISSUE_COUNT" -eq 0 ] && echo 0 || echo 1)
