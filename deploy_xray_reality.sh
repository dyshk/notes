#!/usr/bin/env bash
# ============================================================================
# Xray + VLESS Reality 一键部署脚本（带逐段解释）
# 适用系统：Debian 12 / Ubuntu 22.04 LTS
# 运行方式：以 root 执行  bash deploy_xray_reality.sh
# 功能：安装 Xray → 生成 UUID/x25519 → 写入配置 → 放行防火墙 → 启动服务
# 注意：这不是 Xray 官方脚本，是基于官方二进制和官方配置格式的自动化辅助脚本
# ============================================================================

set -euo pipefail
# set -e  : 任一命令失败即退出，避免错误继续执行
# set -u  : 使用未定义变量时报错，防止拼写错误
# set -o pipefail : 管道中任一命令失败，整个管道返回失败

# ----------------------------------------------------------------------------
# 颜色输出，方便阅读日志
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ----------------------------------------------------------------------------
# Step 1：检查 root 权限
# ----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    error "请以 root 权限运行本脚本：sudo bash $0"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 2：系统初始化 —— 更新软件包、安装依赖、开启 BBR
# ----------------------------------------------------------------------------
info "Step 1/7: 系统初始化..."

# apt update 更新包索引；apt upgrade 升级已安装包，避免 glibc 等依赖过旧
apt update && apt upgrade -y

# 安装必要工具：
# curl/wget 用于下载；socat 用于网络调试；ufw 是防火墙前端；jq 用于解析 JSON
apt install -y curl wget socat ufw jq

# 开启 BBR 拥塞控制，提升高延迟链路吞吐
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    info "BBR 已启用"
else
    info "BBR 已处于启用状态，跳过"
fi

# ----------------------------------------------------------------------------
# Step 3：安装 Xray-core（使用官方安装脚本）
# ----------------------------------------------------------------------------
info "Step 2/7: 安装 Xray-core..."

# 官方安装脚本会自动：
# 1) 下载匹配架构的 xray 二进制
# 2) 创建 /usr/local/etc/xray/ 配置目录
# 3) 创建 /var/log/xray/ 日志目录
# 4) 创建并启用 systemd 服务 /etc/systemd/system/xray.service
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 验证安装
xray version

# ----------------------------------------------------------------------------
# Step 4：生成 UUID 和 x25519 密钥对
# ----------------------------------------------------------------------------
info "Step 3/7: 生成身份凭据..."

# UUID 是 VLESS 的账号标识
UUID=$(xray uuid)

# x25519 生成 Reality 所需的公私钥对
# PrivateKey 放在服务端 config.json
# PublicKey  放在客户端分享链接的 pbk 参数
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Public key:" | awk '{print $3}')

info "UUID: $UUID"
info "PrivateKey: $PRIVATE_KEY"
info "PublicKey:  $PUBLIC_KEY"

# 把凭据保存到 root 家目录，方便用户后续查看
CRED_FILE="/root/xray_credentials.txt"
cat > "$CRED_FILE" <<EOF
Xray VLESS Reality 凭据（请妥善保管）
=====================================
UUID:       $UUID
PrivateKey: $PRIVATE_KEY  （服务端用）
PublicKey:  $PUBLIC_KEY   （客户端 pbk= 用）
EOF
chmod 600 "$CRED_FILE"
warn "凭据已保存到 $CRED_FILE，请妥善保管"

# ----------------------------------------------------------------------------
# Step 5：写入 Xray 配置文件
# ----------------------------------------------------------------------------
info "Step 4/7: 写入 Xray 配置文件..."

# 伪装目标：选择一个真实存在、支持 TLS 1.3、流量大的站点
# 被主动探测时，Xray 会把连接转发给该站点，使其呈现真实证书
DEST="www.microsoft.com:443"
SERVER_NAME="www.microsoft.com"

# 这里的 cat <<EOF 会把纯文本直接写入文件，不进行 shell 变量扩展
# 但因为我们要嵌入 $UUID 和 $PRIVATE_KEY，所以用不带引号的 EOF，允许变量扩展
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$DEST",
        "serverNames": ["$SERVER_NAME"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": [""]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"]
    }
  }],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

# 验证生成的 JSON 是否合法
if python3 -m json.tool /usr/local/etc/xray/config.json > /dev/null 2>&1; then
    info "config.json JSON 格式验证通过"
else
    error "config.json JSON 格式错误，请检查"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 6：放行防火墙
# ----------------------------------------------------------------------------
info "Step 5/7: 配置防火墙..."

# 先放行 SSH，防止把自己锁在外面
# 如果你的 SSH 不是 22，请把下面数字改成实际端口
SSH_PORT=${SSH_CLIENT##* } || true
SSH_PORT=${SSH_PORT:-22}
ufw allow "$SSH_PORT/tcp" || true

# 放行 Xray 的 443 端口
ufw allow 443/tcp

# 如果防火墙未启用，则启用；已启用会保持原状
ufw --force enable
info "防火墙规则："
ufw status numbered

# ----------------------------------------------------------------------------
# Step 7：启动并验证 Xray
# ----------------------------------------------------------------------------
info "Step 6/7: 启动 Xray 服务..."

# 重新加载 systemd 单元文件，识别新安装的服务
systemctl daemon-reload

# 启动并设置开机自启
systemctl restart xray
systemctl enable xray

# 等待 1 秒让服务稳定
sleep 1

# 检查服务状态
if systemctl is-active --quiet xray; then
    info "Xray 服务运行正常"
else
    error "Xray 服务启动失败，最近 30 行日志："
    journalctl -u xray -n 30 --no-pager
    exit 1
fi

# 检查 443 端口是否在监听
if ss -tlnp | grep -q ':443 '; then
    info "443 端口监听正常"
else
    error "443 端口未监听，请检查配置"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 8：输出生成的客户端链接
# ----------------------------------------------------------------------------
info "Step 7/7: 生成客户端分享链接..."

# 获取本机公网 IP（如果 curl 失败，提示用户手动填写）
SERVER_IP=$(curl -sL --max-time 5 https://api.ipify.org || echo "你的服务器IP")

SHARE_LINK="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp#Xray-Reality"

echo ""
echo "=============================================="
echo "          部署完成，客户端链接如下"
echo "=============================================="
echo "$SHARE_LINK"
echo ""
echo "导入 v2rayN / Clash / sing-box / Shadowrocket 即可使用"
echo ""
echo "服务端凭据备份文件：$CRED_FILE"
echo "查看实时日志：journalctl -u xray -f"
echo "=============================================="
