# Xray + VLESS Reality 生产部署完整检查清单

---

## 一、原配置存在的 4 个直接问题

| 问题          | 说明                                                    | 修正方式                                          |
| ----------- | ----------------------------------------------------- | --------------------------------------------- |
| JSON 里含注释   | 标准 JSON 不支持 `//` 注释；Xray 使用 Go 标准 json 库，**带注释会启动失败** | 删除所有 `// ...` 注释，或用 `python3 -m json.tool` 验证 |
| UUID/私钥是占位符 | `"YOUR-UUID-HERE"`、 `"YOUR-PRIVATE-KEY-HERE"` 不是有效值   | 用 `xray uuid` 和 `xray x25519` 生成              |
| 没有日志配置      | 默认无日志，出错时无法排查                                         | 加 `log` 字段                                    |
| 端口未说明防火墙    | 只写 `"port": 443`，但防火墙/云安全组没放行则外部连不上                   | 放行 `443/tcp`                                  |

---

## 二、部署前准备

- 一台 Linux VPS，建议 **Debian 12** 或 **Ubuntu 22.04 LTS**，KVM 虚拟化
- 云厂商安全组已放行 **TCP 443**（以及你的 SSH 端口）
- 已通过 SSH 登录到 root（或具有 sudo 权限的用户）

---

## 三、完整部署流程（按顺序执行）

### Step 1 — 系统初始化

```bash
# 更新系统软件包，避免安装旧版依赖
apt update && apt upgrade -y

# 安装后续要用到的工具
# curl/wget：下载脚本；socat：网络调试；ufw：防火墙；vim：编辑配置
apt install -y curl wget socat ufw vim

# 开启 BBR 拥塞控制算法
# BBR 能显著改善高延迟、有丢包的链路的吞吐和稳定性
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# 让内核参数立即生效
sysctl -p

# 验证 BBR 是否已启用，输出应包含 "bbr"
sysctl net.ipv4.tcp_congestion_control
```

**解释**：

- `apt upgrade` 避免 Xray 依赖的 glibc 等库版本过旧。
- BBR 是 Google 提出的拥塞控制算法，对代理场景收益很大。

---

### Step 2 — 安装 Xray-core

```bash
# 官方安装脚本：自动下载对应架构的二进制、创建 systemd 服务、创建配置目录
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 验证安装成功
xray version

# 查看 systemd 服务状态，应显示 active (running)
systemctl status xray
```

**解释**：

- 官方脚本会创建：
  - 二进制：`/usr/local/bin/xray`
  - 配置目录：`/usr/local/etc/xray/`
  - 日志目录：`/var/log/xray/`
  - systemd 服务：`/etc/systemd/system/xray.service`
- 如果手动安装，以上四项都要自己准备，容易遗漏。

---

### Step 3 — 生成身份凭据

```bash
# 生成用户 UUID，客户端“用户 ID”填这个
xray uuid
# 示例输出：a1b2c3d4-e5f6-7890-abcd-ef1234567890

# 生成 x25519 密钥对
xray x25519
# 示例输出：
# Private key: AAAA...（服务端 config.json 里填这个）
# Public key:  BBBB...（客户端链接里 pbk= 后面填这个）
```

**解释**：

- `uuid` 是 VLESS 协议的身份标识，相当于账号。
- `x25519` 是 Reality 握手需要的非对称密钥对；**私钥放在服务端，公钥放在客户端**，两者必须来自同一对，否则 Reality 握手失败。

---

### Step 4 — 写入生产配置

把下面内容保存到 `/usr/local/etc/xray/config.json`，**替换占位符**。

```json
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
          "id": "YOUR-UUID-HERE",
          "flow": "xtls-rprx-vision"
        }
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "YOUR-PRIVATE-KEY-HERE",
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
```

**逐字段解释**：

| 字段                                 | 含义                                                 |
| ---------------------------------- | -------------------------------------------------- |
| `log.access/error`                 | 访问日志和错误日志路径，排查问题必备                                 |
| `log.loglevel`                     | `warning` 只记录警告和错误；调试时可改为 `debug`                  |
| `inbounds[0].port`                 | 服务端监听端口，Reality 推荐 443                             |
| `protocol: "vless"`                | 入站协议为 VLESS                                        |
| `clients[0].id`                    | 你的 UUID，客户端凭证                                      |
| `clients[0].flow`                  | `xtls-rprx-vision`：XTLS Vision 流控，降低 TLS 指纹特征      |
| `decryption: "none"`               | VLESS 本身不加密，安全由外层 TLS/Reality 提供                   |
| `network: "tcp"`                   | Reality 当前最成熟的是 TCP 模式                             |
| `security: "reality"`              | 启用 Reality 伪装                                      |
| `realitySettings.dest`             | 被探测时 Xray 会把连接转发给该真实站点，探测器看到的是真实证书                 |
| `realitySettings.serverNames`      | 客户端 SNI 必须匹配这里，否则被当作普通流量转发                         |
| `realitySettings.privateKey`       | 服务端私钥，由 `xray x25519` 生成                           |
| `realitySettings.shortIds`         | `""` 表示接受任意 shortId；生产建议用随机两位十六进制，如 `["a1", "3f"]` |
| `sniffing`                         | 让 Xray 识别流量目标域名，用于分流和日志                            |
| `outbounds[0].protocol: "freedom"` | 直连出站，不做二次转发                                        |

**写入命令**（用 heredoc，避免转义问题）：

```bash
cat > /usr/local/etc/xray/config.json <<'EOF'
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
          "id": "YOUR-UUID-HERE",
          "flow": "xtls-rprx-vision"
        }
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "YOUR-PRIVATE-KEY-HERE",
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
```

> **注意**：`<<'EOF'` 里的单引号表示不展开变量、不转义，适合直接写入 JSON。

---

### Step 5 — 放行防火墙

```bash
# 放行 SSH，防止把自己锁在服务器外（如果你的 SSH 不是 22，请改数字）
ufw allow 22/tcp

# 放行 Xray 监听端口
ufw allow 443/tcp

# 启用防火墙并查看规则
ufw enable
ufw status
```

**解释**：

- 很多新手只改了 ufw，但忘了云厂商的“安全组/网络 ACL”，两者都要放行 443。
- 如果你先启用了 ufw 但没放行 SSH，会立刻断开连接。

---

### Step 6 — 启动服务

```bash
# 重新加载 systemd，识别新安装的服务
systemctl daemon-reload

# 重启 Xray 并读取新配置
systemctl restart xray

# 设置开机自启
systemctl enable xray

# 查看运行状态
systemctl status xray

# 实时查看日志，确认无报错
journalctl -u xray -f
```

**解释**：

- `restart` 会重新读取 `config.json`。
- 如果状态是 `failed`，优先看 `journalctl -u xray -n 50` 或 `/var/log/xray/error.log`。

---

### Step 7 — 生成客户端分享链接

```text
vless://YOUR-UUID-HERE@你的服务器IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=YOUR-PUBLIC-KEY-HERE&sid=&type=tcp#我的Reality节点
```

**参数解释**：

| 参数                         | 含义         | 必须和哪里一致                  |
| -------------------------- | ---------- | ------------------------ |
| `YOUR-UUID-HERE`           | 用户 UUID    | 服务端 `clients[0].id`      |
| `你的服务器IP`                  | VPS 公网 IP  | —                        |
| `flow=xtls-rprx-vision`    | 流控         | 服务端 `clients[0].flow`    |
| `security=reality`         | 安全层        | 服务端 `security`           |
| `sni=www.microsoft.com`    | TLS SNI    | 服务端 `serverNames[0]`     |
| `fp=chrome`                | 客户端 TLS 指纹 | 建议 chrome/firefox/safari |
| `pbk=YOUR-PUBLIC-KEY-HERE` | Reality 公钥 | 服务端 `privateKey` 对应的公钥   |
| `sid=`                     | shortId    | 服务端 `shortIds`；空串就留空     |
| `type=tcp`                 | 传输方式       | 服务端 `network`            |

---

## 四、验证是否真正连通的 3 个方法

| 方法              | 命令/操作                                                                       | 预期结果                       |
| --------------- | --------------------------------------------------------------------------- | -------------------------- |
| 本地代理测试          | 客户端开启后：<br />`curl --proxy socks5://127.0.0.1:10808 https://www.google.com` | 返回 200，且 IP 站显示为你的 VPS IP  |
| 服务端看 access log | `tail -f /var/log/xray/access.log`                                          | 有来自你客户端 IP 的 accepted 记录   |
| 端口监听检查          | `ss -tlnp \| grep 443`                                                      | 显示 xray 在 `0.0.0.0:443` 监听 |

---

## 五、常见启动失败原因速查

| 现象                         | 最可能原因                        | 处理                                                        |
| -------------------------- | ---------------------------- | --------------------------------------------------------- |
| `systemctl status xray` 失败 | `config.json` 含注释或 JSON 语法错误 | `python3 -m json.tool /usr/local/etc/xray/config.json` 验证 |
| 端口被占用                      | 443 被 nginx/caddy 占用         | `lsof -i :443` 查看并停掉占用服务，或改 Xray 端口                       |
| 外部连不上 443                  | 云厂商安全组 / ufw 没放行             | 双重检查                                                      |
| 客户端提示 auth failed          | UUID 填错，或 flow 不匹配           | 服务端和客户端 UUID、flow 完全一致                                    |
| Reality 握手失败               | sni/serverNames 不一致，或 pbk 填错 | 重新核对密钥对                                                   |

---

> 那段 `config.json` 是**核心中的核心**，但一个能用的节点 = `Xray 程序 + 合法 JSON 配置 + 真实 UUID/密钥 + 防火墙放行 + 启动服务 + 客户端参数对应`。缺一不可。

---

## deploy_xray_reality.sh一键部署脚本，使用方法：

```text
# 在 VPS 上以 root 执行
curl -O https://raw.githubusercontent.com/你的用户名/你的仓库/main/deploy_xray_reality.sh
bash deploy_xray_reality.sh
```

脚本跑完后会在 `/root/xray_credentials.txt` 保存 UUID、PrivateKey、PublicKey，并直接输出生成的 `vless://` 客户端链接。

**提醒**：这个脚本基于 Xray 官方二进制和官方配置格式封装，但脚本本身不是 Xray 官方出品
