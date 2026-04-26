#!/bin/bash
# =============================================================
#  Deepay Webhook 自动部署 — 一键安装脚本  v1.0
#
#  用法：
#    bash script/shell/setup-webhook.sh
#
#  功能：
#    ① 自动生成安全的 Webhook Secret
#    ② 创建 systemd 服务（开机自启）
#    ③ 启动 webhook 服务
#    ④ 输出 GitHub Webhook 配置信息
#
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEBHOOK_SCRIPT="$SCRIPT_DIR/webhook.py"
WEBHOOK_PORT="${WEBHOOK_PORT:-9000}"
WEBHOOK_BRANCH="${WEBHOOK_BRANCH:-main}"
WEBHOOK_MODE="${WEBHOOK_MODE:-all}"
SERVICE_FILE="/etc/systemd/system/deepay-webhook.service"

# ── 颜色输出 ──────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'
C='\033[0;36m'; B='\033[1m'; N='\033[0m'
info()  { echo -e "${G}[INFO ]${N} $*"; }
warn()  { echo -e "${Y}[WARN ]${N} $*"; }
err()   { echo -e "${R}[ERROR]${N} $*"; exit 1; }
title() { echo -e "\n${C}${B}━━━━━━  $*  ━━━━━━${N}"; }
ok()    { echo -e "${G}${B}  ✔  $*${N}"; }
hr()    { echo -e "${C}$(printf '━%.0s' {1..60})${N}"; }

# ── 环境检查 ──────────────────────────────────────────────────
title "环境检查"

# 检查 Python3
if ! command -v python3 &>/dev/null; then
  err "未找到 python3，请先安装: apt-get install -y python3"
fi
info "Python: $(python3 --version)"

# 检查 webhook.py 是否存在
if [ ! -f "$WEBHOOK_SCRIPT" ]; then
  err "webhook.py 不存在: $WEBHOOK_SCRIPT"
fi
ok "webhook.py 已找到"

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
  err "必须以 root 身份运行此脚本（sudo bash script/shell/setup-webhook.sh）"
fi
ok "以 root 身份运行"

# ── 生成 Webhook Secret ────────────────────────────────────────
title "生成 Webhook Secret"

WEBHOOK_SECRET=$(openssl rand -hex 32)
ok "已生成 Secret: $WEBHOOK_SECRET"

# ── 获取服务器 IP ─────────────────────────────────────────────
title "检测服务器 IP"

# 优先获取外网 IP
SERVER_IP=$(curl -s -m 5 https://api.ipify.org || echo "")

# 如果无法获取外网 IP，则使用本地 IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I | awk '{print $1}')
fi

[ -z "$SERVER_IP" ] && SERVER_IP="your.server.ip"
info "服务器 IP: $SERVER_IP"

# ── 创建 systemd 服务 ──────────────────────────────────────────
title "创建 systemd 服务"

cat > "$SERVICE_FILE" << UNIT
[Unit]
Description=Deepay Webhook Auto Deploy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PROJECT_ROOT
Environment="WEBHOOK_SECRET=$WEBHOOK_SECRET"
Environment="WEBHOOK_PORT=$WEBHOOK_PORT"
Environment="WEBHOOK_BRANCH=$WEBHOOK_BRANCH"
Environment="WEBHOOK_MODE=$WEBHOOK_MODE"
Environment="PROJECT_ROOT=$PROJECT_ROOT"
ExecStart=/usr/bin/python3 $WEBHOOK_SCRIPT run
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

ok "服务文件已创建: $SERVICE_FILE"

# ── 启用并启动服务 ────────────────────────────────────────────
title "启动 webhook 服务"

systemctl daemon-reload
info "systemd 已重新加载"

systemctl enable deepay-webhook
ok "开机自启已启用"

systemctl start deepay-webhook
sleep 2

if systemctl is-active --quiet deepay-webhook; then
  ok "deepay-webhook 服务已启动"
else
  warn "服务启动失败，查看日志:"
  journalctl -u deepay-webhook -n 20
  err "请检查上面的错误日志"
fi

# ── 等待服务就绪 ────────────────────────────────────────────
info "等待 webhook 服务就绪（最多 10 秒）..."
for i in $(seq 1 10); do
  if curl -s http://127.0.0.1:$WEBHOOK_PORT/health &>/dev/null; then
    ok "Webhook 服务已就绪"
    break
  fi
  printf "."
  sleep 1
done
echo ""

# ── 输出配置信息 ──────────────────────────────────────────────
hr
echo -e "${G}${B}"
echo "  ╔════════════════════════════════════════════════════════════╗"
echo "  ║                 🎉 Webhook 安装完成！                      ║"
echo "  ╚════════════════════════════════════════════════════════════╝"
echo -e "${N}"

echo ""
echo -e "${C}${B}📋 GitHub Webhook 配置（下一步）${N}"
echo "   访问: https://github.com/cyun45107-hue/deepay.srl/settings/hooks"
echo ""
echo -e "   ${B}Payload URL:${N}"
echo "      http://$SERVER_IP:$WEBHOOK_PORT/webhook"
echo ""
echo -e "   ${B}Content type:${N}"
echo "      application/json"
echo ""
echo -e "   ${B}Secret:${N}"
echo "      $WEBHOOK_SECRET"
echo ""
echo -e "   ${B}Events:${N}"
echo "      Just the push event"
echo ""
echo -e "   ${B}Active:${N}"
echo "      ✔ 勾选"
echo ""

hr
echo -e "${C}${B}🔍 服务管理命令${N}"
echo ""
echo "   查看状态："
echo "      systemctl status deepay-webhook"
echo ""
echo "   查看实时日志："
echo "      journalctl -u deepay-webhook -f"
echo ""
echo "   查看最近100行日志："
echo "      journalctl -u deepay-webhook -n 100"
echo ""
echo "   测试连接："
echo "      curl http://127.0.0.1:$WEBHOOK_PORT/health"
echo ""
echo "   重启服务："
echo "      systemctl restart deepay-webhook"
echo ""
echo "   查看部署日志："
echo "      tail -f $PROJECT_ROOT/.build-logs/webhook.log"
echo ""

hr
echo -e "${C}${B}⚡ 快速验证${N}"
echo ""
echo "   1️⃣  检查服务状态："
systemctl status deepay-webhook --no-pager | head -5
echo ""
echo "   2️⃣  测试 webhook 连接："
if curl -s http://127.0.0.1:$WEBHOOK_PORT/health; then
  echo ""
  ok "✓ Webhook 服务正常"
else
  warn "✘ 无法连接 webhook 服务"
fi
echo ""

hr
echo -e "${Y}${B}⚠️  重要提示${N}"
echo ""
echo "   • 需要在宝塔面板放行 $WEBHOOK_PORT 端口"
echo "   • GitHub Webhook 配置完成后会自动发送 ping"
echo "   • 可以在 GitHub Webhook 页面的 Recent Deliveries 查看测试结果"
echo "   • 第一次 git push 后会自动部署"
echo ""

hr

