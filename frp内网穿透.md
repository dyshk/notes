# frp 内网穿透完整部署教程

基于 [fatedier/frp](https://github.com/fatedier/frp) v0.71.1，配置格式使用官方推荐的 TOML。

---

## 📋 前提条件

| 角色 | 需要 |
|------|------|
| **服务端（frps）** | 一台有**公网 IP** 的 VPS（Linux） |
| **客户端（frpc）** | 内网机器（Linux / Windows / macOS） |
| 防火墙 | VPS 安全组/防火墙放行 frp 端口（默认 7000 和要转发的端口） |

---

## 🏗️ 整体架构

```
你的电脑(FinalShell) → 公网VPS(frps, 端口6000) → 内网机器(frpc → 本地22端口)
```

---

## 第一步：下载 frp

### 查看架构

```bash
uname -m
# x86_64  → amd64
# aarch64 → arm64
```

### 下载并解压（以 Linux amd64 为例）

```bash
cd /opt
wget https://github.com/fatedier/frp/releases/download/v0.71.1/frp_0.71.1_linux_amd64.tar.gz
tar -zxvf frp_0.71.1_linux_amd64.tar.gz
cd frp_0.71.1_linux_amd64
```

> 文件说明：
> - `frps` + `frps.toml` → 服务端用（放 VPS 上）
> - `frpc` + `frpc.toml` → 客户端用（放内网机器上）

---

## 第二步：配置服务端（VPS 上操作）

### 2.1 编辑 frps.toml

```bash
cd /opt/frp_0.71.1_linux_amd64
vi frps.toml
```

填入：

```toml
# frps.toml - 服务端配置
bindPort = 7000                     # frp 服务端口，客户端连接用
auth.token = "你自己设一个复杂密码"    # 身份验证，客户端必须一致

# 可选：开启 Dashboard 面板
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "面板密码"
```

### 2.2 放行防火墙端口

```bash
# 如果你用 ufw
ufw allow 7000/tcp
ufw allow 6000/tcp    # SSH 转发用的端口
ufw allow 7500/tcp    # Dashboard 面板端口（可选）

# 如果你用 firewalld
firewall-cmd --add-port=7000/tcp --permanent
firewall-cmd --add-port=6000/tcp --permanent
firewall-cmd --reload
```

> ⚠️ **别忘了去 VPS 服务商的控制台（安全组/防火墙）也放行这些端口！**

### 2.3 启动服务端（前台测试）

```bash
./frps -c frps.toml
```

看到 `frps started successfully` 说明启动成功。按 `Ctrl+C` 停止，后面配置 systemd 后台运行。

---

## 第三步：配置客户端（内网机器上操作）

### 3.1 同样下载 frp

```bash
cd /opt
wget https://github.com/fatedier/frp/releases/download/v0.71.1/frp_0.71.1_linux_amd64.tar.gz
tar -zxvf frp_0.71.1_linux_amd64.tar.gz
cd frp_0.71.1_linux_amd64
```

### 3.2 编辑 frpc.toml

```bash
vi frpc.toml
```

填入：

```toml
# frpc.toml - 客户端配置
serverAddr = "你的VPS公网IP"
serverPort = 7000
auth.token = "和服务端一样的密码"

# 可选：客户端管理面板
webServer.addr = "127.0.0.1"
webServer.port = 7400

# SSH 隧道
[[proxies]]
name = "ssh-ubuntu"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000    # VPS 上对外暴露的端口，随便设（1024-65535）
```

> `remotePort = 6000` 的意思：别人连 VPS 的 6000 端口，就等于连我内网机器的 22 端口。

### 3.3 启动客户端测试

```bash
./frpc -c frpc.toml
```

看到 `login to server success` 和 `proxy started` 就说明连上了。

---

## 第四步：测试 FinalShell 连接

打开 FinalShell，新建 SSH 连接：

| 项 | 值 |
|----|-----|
| 主机 | **你的 VPS 公网 IP** |
| 端口 | **6000**（就是 remotePort） |
| 用户名 | 内网机器的 SSH 用户名（比如 root） |
| 密码/密钥 | 内网机器的 SSH 密码或密钥 |

> ⚠️ 注意：连的是 **VPS 的 IP + 转发端口**，不是内网机器的 IP。

能成功登录就说明穿透成功了！

---

## 第五步：配置开机自启（systemd）

测试通过后，配置成系统服务，开机自动运行。

### 5.1 服务端（VPS）

```bash
vi /etc/systemd/system/frps.service
```

写入：

```ini
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
ExecStart=/opt/frp_0.71.1_linux_amd64/frps -c /opt/frp_0.71.1_linux_amd64/frps.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启动并设为开机自启：

```bash
systemctl daemon-reload
systemctl start frps
systemctl enable frps
systemctl status frps   # 查看状态
```

### 5.2 客户端（内网机器）

```bash
vi /etc/systemd/system/frpc.service
```

写入：

```ini
[Unit]
Description=frp client
After=network.target

[Service]
Type=simple
ExecStart=/opt/frp_0.71.1_linux_amd64/frpc -c /opt/frp_0.71.1_linux_amd64/frpc.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启动并设为开机自启：

```bash
systemctl daemon-reload
systemctl start frpc
systemctl enable frpc
systemctl status frpc
```

---

## 附录 A：Windows 客户端一键部署（PowerShell + nssm）

> 以下是 Windows 系统部署 frp 客户端的**一键 PowerShell 脚本**，包含：下载解压、Defender 排除、配置生成、nssm 安装为系统服务（开机自启）。示例以转发 RDP（3389 端口）为例。
>
> **需要以管理员身份运行 PowerShell。**

### A.1 完整脚本

```powershell
# 先把目录建出来，把整个目录排除掉（zip 和解压后的 exe 都在这里面）
New-Item -ItemType Directory -Force -Path C:\frp | Out-Null
Add-MpPreference -ExclusionPath "C:\frp"
Add-MpPreference -ExclusionProcess "frpc.exe","frps.exe"

# 确认生效
(Get-MpPreference).ExclusionPath

#下到已排除的目录里
Invoke-WebRequest -Uri "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.71.1/frp_0.71.1_windows_amd64.zip" `
  -OutFile "C:\frp\frp.zip" -UseBasicParsing

# 用系统自带 tar 解压，比 Expand-Archive 稳（后者对大 zip 还有路径长度限制）
tar -xf C:\frp\frp.zip -C C:\frp
Get-ChildItem C:\frp\frp_0.71.1_windows_amd64

#配置并设置开机自启
$D='C:\frp\frp_0.71.1_windows_amd64'; Add-MpPreference -ExclusionPath $D -EA 0; Add-MpPreference -ExclusionProcess frpc.exe -EA 0; Copy-Item $D\frpc.toml "$D\frpc.toml.bak.$(Get-Date -f yyyyMMdd-HHmmss)" -EA 0; @('serverAddr = "32.188.73.145"','serverPort = 40000','auth.token = "dyshk"','','[[proxies]]','name = "test-tcp"','type = "tcp"','localIP = "127.0.0.1"','localPort = 3389','remotePort = 43389') | Set-Content -Path $D\frpc.toml -Encoding ASCII; [Net.ServicePointManager]::SecurityProtocol=3072; Invoke-WebRequest https://nssm.cc/release/nssm-2.24.zip -OutFile $env:TEMP\nssm.zip -UseBasicParsing; Expand-Archive $env:TEMP\nssm.zip -DestinationPath $env:TEMP\nssm -Force; $n=(Get-ChildItem $env:TEMP\nssm -Filter nssm.exe -Recurse -File | ? FullName -match win64 | select -First 1).FullName; & $n stop frpc 2>$null; & $n remove frpc confirm 2>$null; & $n install frpc "$D\frpc.exe"; & $n set frpc AppParameters "-c `"$D\frpc.toml`""; & $n set frpc AppDirectory $D; & $n set frpc DisplayName "frp client"; & $n set frpc Start SERVICE_AUTO_START; & $n set frpc AppRestartDelay 5000; & $n set frpc AppStdout "$D\frpc.log"; & $n set frpc AppStderr "$D\frpc.log"; & $n start frpc; & $n status frpc; Get-Service frpc | select Name,Status,StartType
```

### A.2 脚本各段简要说明

| 段落 | 作用 |
|------|------|
| `New-Item` + `Add-MpPreference` | 创建 `C:\frp` 目录并加入 Windows Defender 排除列表，防止 frp 被误报查杀 |
| `Invoke-WebRequest` 下载 frp | 通过 gh-proxy 镜像加速下载 Windows 版 frp 到已排除目录 |
| `tar -xf` 解压 | 用系统自带 tar 解压 zip，比 `Expand-Archive` 更稳定 |
| `$D='C:\frp\...'` 配置生成 | 自动写入 `frpc.toml` 配置（示例：转发本地 3389 → VPS 43389） |
| 下载 nssm | 下载 nssm（Non-Sucking Service Manager），用来把 frpc 注册成 Windows 系统服务 |
| `nssm install/set` | 安装 frpc 服务，设置自动启动、崩溃重启延迟、日志输出路径 |
| `nssm start` + `Get-Service` | 启动服务并查看运行状态 |

### A.3 需要修改的参数

脚本里的示例配置，使用前请改成你自己的：

| 参数 | 示例值 | 说明 |
|------|-------|------|
| `serverAddr` | `ipip`  | 你的 VPS 公网 IP |
| `serverPort` | `40000` | frps 服务端端口（对应 frps.toml 的 `bindPort`） |
| `auth.token` | `dyshk` | 认证密钥，必须和服务端一致 |
| `localPort` | `3389` | 内网要转发的本地端口（3389=RDP，22=SSH） |
| `remotePort` | `43389` | VPS 上对外暴露的端口 |

### A.4 常用管理命令

```powershell
# 查看服务状态
Get-Service frpc

# 启动 / 停止 / 重启服务
Start-Service frpc
Stop-Service frpc
Restart-Service frpc

# 查看日志
Get-Content C:\frp\frp_0.71.1_windows_amd64\frpc.log -Tail 50 -Wait

# 修改配置后重启服务生效
Restart-Service frpc
```

---

## 第六步：进阶 — 添加更多穿透服务（可选）

frp 不止能转发 SSH，想穿透什么服务就在 `frpc.toml` 里加一个 `[[proxies]]` 块。

### 转发 Web 服务（80 端口）

```toml
[[proxies]]
name = "web-http"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 8080
```

### 转发 RDP（Windows 远程桌面）

```toml
[[proxies]]
name = "rdp"
type = "tcp"
localIP = "192.168.124.10"   # 内网 Windows 的 IP
localPort = 3389
remotePort = 6389
```

### 转发 MySQL

```toml
[[proxies]]
name = "mysql"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3306
remotePort = 6306
```

改完配置重载：

```bash
systemctl restart frpc
```

---

## 🔒 安全建议

1. **auth.token 一定要设复杂**，否则别人可以扫到你的 7000 端口随便连
2. **不要转发不必要的端口**，只转发你需要的
3. **SSH 建议用密钥登录**，禁用密码登录，防止被爆破
4. 服务端限制允许转发的端口范围：
   ```toml
   # frps.toml 里加
   allowPorts = [
     { start = 6000, end = 7000 }
   ]
   ```
5. Dashboard 面板不要暴露给公网，或者设置强密码
6. 开启 TLS 加密传输（v0.71.x 默认已支持 wire protocol v2 + AEAD）

---

## 📝 常用命令

```bash
# 查看服务状态
systemctl status frps   # 服务端
systemctl status frpc   # 客户端

# 实时查看日志
journalctl -u frps -f   # 服务端
journalctl -u frpc -f   # 客户端

# 重启服务
systemctl restart frps
systemctl restart frpc

# 停止服务
systemctl stop frps
systemctl stop frpc
```

---

## ❓ 常见问题排查

### 1. 客户端连不上服务端

- 检查 VPS 安全组/防火墙是否放行 7000 端口
- 确认 `serverAddr` 填的是 VPS 公网 IP
- 确认 `auth.token` 服务端和客户端一致

### 2. 连不上转发端口

- 检查 VPS 防火墙是否放行 `remotePort` 端口
- 确认内网服务是否在运行（SSH 是否开着）
- 看 `journalctl -u frpc -f` 有没有报错

### 3. 频繁断开

- 检查网络稳定性
- 已配置 systemd + `Restart=always` 的话会自动重连

---

## 🔗 参考链接

- frp 官方仓库：[github.com/fatedier/frp](https://github.com/fatedier/frp)
- frp 官方文档：[gofrp.org](https://gofrp.org/)
