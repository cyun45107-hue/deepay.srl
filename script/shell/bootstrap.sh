#!/usr/bin/env bash
# =============================================================
#  Deepay 空服务器引导脚本  —  一行命令完成拉代码 + 全栈部署
#
#  服务器上执行（只需复制这一行）：
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/deepay999/deepaystudio/main/script/shell/bootstrap.sh)
#
#  或者（已能访问 GitHub 时）：
#
#    curl -fsSL https://raw.githubusercontent.com/deepay999/deepaystudio/main/script/shell/bootstrap.sh | bash
#
#  脚本会自动完成：
#    ① 安装 git（若系统缺少）
#    ② 克隆 / 更新仓库到 /www/wwwroot/deepaystudio-master
#    ③ 解除 webhook.service 的 mask（若已被 mask）
#    ④ 安装并启动 deepay-webhook systemd 服务
#    ⑤ 调用 quickstart.sh 完成全栈部署
#
#  环境变量（全部可选）：
#    REPO          Git 仓库地址（默认 GitHub HTTPS）
#    PROJECT_DIR   本地克隆目录（默认 /www/wwwroot/deepaystudio-master）
#    BRANCH        分支名（默认 main）
#    WEBHOOK_SECRET  GitHub Webhook Secret（默认为空，稍后手动改）
#    SKIP_QUICKSTART 设为 1 时仅克隆 + 装服务，不运行 quickstart.sh
# =============================================================
set -euo pipefail

REPO="${REPO:-https://github.com/deepay999/deepaystudio.git}"
PROJECT_DIR="${PROJECT_DIR:-/www/wwwroot/deepaystudio}"
BRANCH="${BRANCH:-main}"
SKIP_QUICKSTART="${SKIP_QUICKSTART:-0}"

# 自动生成 Webhook Secret（每次引导唯一，保存到文件供查阅）
SECRET_FILE="/root/.deepay_webhook_secret"
if [ -f "$SECRET_FILE" ]; then
  WEBHOOK_SECRET=$(cat "$SECRET_FILE")
else
  WEBHOOK_SECRET=$(openssl rand -hex 32 2>/dev/null \
    || tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48)
  echo "$WEBHOOK_SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

# ── 颜色 ─────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()    { echo -e "${G}  ✓  $*${N}"; }
info()  { echo -e "     $*"; }
warn()  { echo -e "${Y}  ⚠  $*${N}"; }
err()   { echo -e "${R}${B}  ✗  $*${N}" >&2; exit 1; }
title() { echo -e "\n${C}${B}══ $* ══${N}"; }

echo -e "${C}${B}"
cat << 'BANNER'
  ██████╗  ██████╗  ██████╗ ████████╗███████╗████████╗██████╗  █████╗ ██████╗
  ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗
  ██████╔╝██║   ██║██║   ██║   ██║   ███████╗   ██║   ██████╔╝███████║██████╔╝
  ██╔══██╗██║   ██║██║   ██║   ██║   ╚════██║   ██║   ██╔══██╗██╔══██║██╔═══╝
  ██████╔╝╚██████╔╝╚██████╔╝   ██║   ███████║   ██║   ██║  ██║██║  ██║██║
  ╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝
                       空 服 务 器 一 键 引 导 部 署
BANNER
echo -e "${N}"

# ══════════════════════════════════════════════════════════════
# 步骤 1 — 检查 / 安装 git
# ══════════════════════════════════════════════════════════════
title "步骤 1  确认 git 已安装"

if ! command -v git &>/dev/null; then
  info "git 未安装，开始自动安装..."
  if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q && apt-get install -y -q git
  elif command -v yum &>/dev/null; then
    yum install -y git
  elif command -v dnf &>/dev/null; then
    dnf install -y git
  else
    err "无法自动安装 git，请手动执行: apt-get install git 或 yum install git"
  fi
fi
ok "git $(git --version)"

# ══════════════════════════════════════════════════════════════
# 步骤 2 — 克隆 / 更新代码
# ══════════════════════════════════════════════════════════════
title "步骤 2  获取代码 → $PROJECT_DIR"

mkdir -p /www/wwwroot

if [ -d "$PROJECT_DIR/.git" ]; then
  info "目录已存在，拉取最新代码..."
  cd "$PROJECT_DIR"
  git fetch origin "$BRANCH" --prune
  git reset --hard "origin/$BRANCH"
  ok "代码已更新到最新 ($(git rev-parse --short HEAD))"
else
  info "克隆仓库: $REPO → $PROJECT_DIR"
  # 若目录已存在但不是 git 仓库，先备份
  if [ -d "$PROJECT_DIR" ]; then
    mv "$PROJECT_DIR" "${PROJECT_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    warn "原目录已备份"
  fi
  git clone --branch "$BRANCH" "$REPO" "$PROJECT_DIR"
  ok "代码克隆完成 ($(cd "$PROJECT_DIR" && git rev-parse --short HEAD))"
fi

# ══════════════════════════════════════════════════════════════
# 步骤 3 — 安装 deepay-webhook systemd 服务
# ══════════════════════════════════════════════════════════════
title "步骤 3  安装 deepay-webhook 服务"

SERVICE_SRC="$PROJECT_DIR/script/shell/webhook.service"
SERVICE_DST="/etc/systemd/system/deepay-webhook.service"

[ -f "$SERVICE_SRC" ] || err "找不到 webhook.service: $SERVICE_SRC"

# 解除 mask（若已被 mask）
if systemctl list-unit-files deepay-webhook.service 2>/dev/null | grep -q "masked"; then
  warn "检测到 deepay-webhook.service 已被 mask，正在解除..."
  systemctl unmask deepay-webhook.service 2>/dev/null || rm -f "$SERVICE_DST"
  ok "mask 已解除"
fi

# 替换路径 + Secret，写到 systemd 目录
sed \
  -e "s|/www/wwwroot/deepay.srl|${PROJECT_DIR}|g" \
  -e "s|change-me-to-your-github-webhook-secret|${WEBHOOK_SECRET}|g" \
  "$SERVICE_SRC" > "$SERVICE_DST"

ok "服务文件已写入: $SERVICE_DST"

systemctl daemon-reload
systemctl enable deepay-webhook
systemctl restart deepay-webhook
sleep 2
systemctl is-active --quiet deepay-webhook \
  && ok "deepay-webhook 服务已启动并设为开机自启" \
  || warn "服务启动异常，查看: journalctl -u deepay-webhook -n 30"

SERVER_IP=$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null \
  || hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_SERVER_IP")

echo ""
echo -e "${C}${B}━━━━  GitHub Webhook 配置信息（复制粘贴到 GitHub）  ━━━━${N}"
echo -e "  Payload URL  :  ${B}http://${SERVER_IP}:9000/webhook${N}"
echo -e "  Content type :  application/json"
echo -e "  Secret       :  ${B}$(cat "$SECRET_FILE")${N}"
echo -e "  Events       :  Just the push event"
echo -e "  Secret 保存于:  $SECRET_FILE"
echo ""

# ══════════════════════════════════════════════════════════════
# 步骤 4 — 调用 quickstart.sh 完成全栈部署
# ══════════════════════════════════════════════════════════════
if [ "$SKIP_QUICKSTART" = "1" ]; then
  warn "SKIP_QUICKSTART=1，跳过 quickstart.sh"
  echo ""
  ok "引导完成！代码已就绪于 $PROJECT_DIR"
  info "如需继续全栈部署，请手动执行："
  info "  PROJECT=$PROJECT_DIR bash $PROJECT_DIR/script/shell/quickstart.sh"
  exit 0
fi

title "步骤 4  全栈部署（quickstart.sh）"
QUICKSTART="$PROJECT_DIR/script/shell/quickstart.sh"
[ -f "$QUICKSTART" ] || err "找不到 quickstart.sh: $QUICKSTART"
chmod +x "$QUICKSTART"

# 以正确的 PROJECT 路径执行 quickstart.sh
PROJECT="$PROJECT_DIR" bash "$QUICKSTART"
