# Cloudflare Pages/Workers 自建节点失效排查与代理原理详解

> 仅作网络技术学习与故障排查方法交流，实验均在自己搭建的服务上完成，请遵守所在地法律法规。
> 文中域名、UUID、账号均为占位符（`my.domain.com` / `demo.pages.dev` / `xxxx-xxxx-…`）；"机器 A / 机器 B"为抽象后的对照案例。

## 0. 故障现象

- 前几天正常的 VLESS 节点某天起全部失效，客户端延迟全为 `-1`；
- 同一账号下另一个 Pages 项目（`*.pages.dev`）的节点仍正常；
- 同一份节点配置，机器 A 能用、机器 B 不能用；
- 失效机器上 `curl` 测试时通时不通；
- Cloudflare 面板中域名 `status: active`、证书正常。

结论：这类"突然集体失效、服务端无异常"的故障，绝大多数是域名级（SNI 关键字）封锁；"一台能用一台不能用"通常是客户端 TLS 分片开关状态不同。

---

## 1. 通用代理原理

### 1.1 正向代理

代理做的事情只有一句：客户端把"要访问谁"委托给中转者，中转者代访，再把结果转回。

```
无代理：  浏览器 ─────────────────────────→ 目标网站
有代理：  浏览器 → 本机客户端 → 【出境】 → 代理服务器 → 目标网站
```

三个必然产物：目标网站看到的来源 IP 是代理服务器的；出境段流量必经审查设备；出境段的外观决定能否被识别。**所有伪装技术的目标都是第三点。**

### 1.2 三层结构：TLS + WebSocket + VLESS

**外层 TLS**：出境段是一条标准 HTTPS 连接，与访问正常网站无区别。审查 HTTPS 的唯一抓手是握手中的 SNI。

**中层 WebSocket**：TLS 建立后发送 HTTP Upgrade 请求，升级为 WS 长连接，帧内容可为任意字节，解决 HTTP 不适合承载任意 TCP 流量的问题。

**内层 VLESS**：WS 帧的载荷，最小结构三项：

```
[ UUID ]           身份凭据，服务端校验，不匹配即断开
[ 目标地址端口 ]    告诉服务端"替我连谁"
[ 数据 ]           实际内容
```

VLESS 省去了外层已有 TLS 的重复加密，头部开销极小，适合 CF 边缘按请求计费的环境。Trojan、Shadowsocks 角色相同，差别在头部格式与身份校验方式。

### 1.3 SNI 为什么无法加密

TLS 握手顺序决定：

1. 客户端发 ClientHello，其中的 **SNI 扩展**写明要访问的域名；
2. 服务器**按 SNI 选择证书**返回；
3. 双方协商出密钥，此后内容（含 HTTP 的 Host 头）才加密。

第 1、2 步在加密协商之前，**SNI 必须明文**，否则服务器不知用哪张证书。ECH/ESNI 试图解决但远未普及。

因此整条链路唯一裸露的信息就是域名字符串，审查侧的对策成本极低：**域名入黑名单，握手匹配到即发 RST 掐断连接**。明文 HTTP（80 端口）的 Host 字段同理，所以这类封锁通常 443 与 80 同时生效。

### 1.4 Cloudflare 架构如何充当代理服务器

| 组件 | 作用 |
|---|---|
| 免费二级域名服务（NS 托管型） | 提供 DNS 入口，NS 记录指向 Cloudflare 后解析权移交 |
| Cloudflare Pages | 运行环境与 IP：全球边缘节点、Anycast 就近接入、自动签发证书 |
| 开源项目（`_worker.js`） | 协议服务端实现（VLESS/Trojan/SS）、订阅生成器、`/admin` 面板 |
| KV 命名空间 | 存 `config.json`（UUID、HOSTS、节点信息）与日志，改配置无需重新部署 |

部署流程：

1. 领取子域名 `my.domain.com`；
2. 把该域名 **NS 记录**改为 Cloudflare 分配的两台 NS 服务器；
3. 在 CF 添加站点，取得证书签发与流量接管授权；
4. 下载项目 `main.zip`，Pages 控制台"上传资产"建项目部署；
5. 设环境变量 `ADMIN`（面板密码），保存后重新部署；
6. 添加 KV 绑定，**变量名必须为 `KV`**（代码按此名读取）；
7. 添加自定义域 `my.domain.com`，CF 自动创建 **CNAME → `<项目名>.pages.dev`** 并签发证书；
8. 访问 `https://my.domain.com/admin` 登录，固定 UUID，导入 `vless://` 链接。

第 7 步必须用 CNAME：CF 边缘 IP 段经常调整，A 记录写死会随时失效；CNAME 指向名字，其背后的 IP 由 CF 维护。根域名协议上不允许挂 CNAME，CF 用 CNAME Flattening 展开为 A 记录。

**这套架构能代理的支点**：Cloudflare 向 Workers 开放了 **`connect()` 原始 TCP socket API**。Worker 本只处理 HTTP，该接口让边缘代码获得与任意 IP:端口建连的能力。项目逻辑即：校验 UUID → 取出目标地址 → `connect()` 直连目标 → 双向搬运字节。

**能长期工作的原因**：出境段是访问 Cloudflare 的普通 HTTPS，海量正常业务同样跑在 CF 上，无法整体封禁；Anycast 使同一 IP 承载无数域名，封 IP 误伤面过大。而封域名只需一行关键字，且链路唯一暴露的恰好是域名——这是此类方案的根本矛盾。

### 1.5 节点的四个字段

| 字段 | 作用 | 客户端列表显示 |
|---|---|---|
| `address` | 连接哪个 CF IP（Anycast：同一 IP 承载无数域名） | 显示 |
| `port` + `path` | 通常 443 + `/` | 不显示 |
| **`SNI`（serverName）** | 明文写入 ClientHello，关键字封锁的靶子 | 不显示 |
| **`WS Host`** | 进隧道后才发送，决定服务端 HOSTS 白名单 | 不显示 |

**地址相同不代表节点相同。** 下文对照案例中两台机器界面显示一致，行为不同的差异全部藏在不可见字段与全局开关里。

---

## 2. 排查：先保证测得准，再逐层定位

### 2.1 排除系统代理对 curl 的污染

Windows 的 `curl.exe` 会读取 **WinINET 系统代理**（注册表 `HKCU\...\Internet Settings` 的 `ProxyEnable`/`ProxyServer`）与 `http_proxy` 环境变量。客户端开启系统代理时，"直连测试"实际走本地代理端口，测的是节点而非线路。

识别：输出出现 `HTTP/1.1 200 Connection established`（HTTP 代理的 CONNECT 应答，直连不会出现）。

所有直连测试加参数：

```bash
curl --noproxy "*" -4 -sS -o /dev/null -w "%{http_code}\n" https://my.domain.com/
```

显式 `-x http://127.0.0.1:10809` 即"走本机代理"测试。两者配合可将线路层与节点层分开测。

### 2.2 分层测试

链路为 **DNS → TCP 三次握手 → TLS 握手 → 应用层**，逐层测，定位断点。

**DNS**（换两个公共 DNS，排除缓存与污染）：

```bash
nslookup -type=A my.domain.com 223.5.5.5
nslookup -type=A my.domain.com 8.8.8.8
# 均正常解析出 CF 的 A 记录
```

**TCP**（此步不发送域名信息，三次握手本身不含数据，审查设备无从判断目标）：

```python
import socket, time
for ip, port in [('104.21.50.215', 443), ('172.67.167.118', 443), ('104.21.50.215', 80)]:
    t = time.time()
    try:
        s = socket.create_connection((ip, port), 6)
        print('TCP %s:%d -> OK %.0f ms' % (ip, port, (time.time()-t)*1000))
        s.close()
    except Exception as e:
        print('TCP %s:%d -> FAIL %s' % (ip, port, e))
```

```
TCP 104.21.50.215:443  -> OK  303 ms
TCP 172.67.167.118:443 -> OK 1278 ms
TCP 104.21.50.215:80   -> OK  253 ms
```

三次握手全部成功，排除 IP 封锁、线路中断、路由异常。同时说明：**只测 TCP 的测速方式，在这个已失效的节点上仍会显示正常延迟。**

**TLS**：

```bash
curl --noproxy "*" -4 -sv -o /dev/null -m 12 https://my.domain.com/
# curl: (35) Recv failure: Connection was reset
```

断点在 TLS 握手：TCP 通，ClientHello 一发出即被 RST。ClientHello 相比 TCP 多出的内容就是明文域名，怀疑方向锁定为按域名封锁。

### 2.3 SNI 交叉实验

目标是**目标 IP 不变、只改 SNI**。curl 的 `--resolve` 可把域名强行解析到指定 IP：

```bash
IP=104.21.50.215

curl --noproxy "*" -4 -sS -o /dev/null -w "http=%{http_code}\n" \
     --resolve demo.pages.dev:443:$IP https://demo.pages.dev/          # A

curl --noproxy "*" -4 -sS -o /dev/null -w "http=%{http_code}\n" \
     --resolve my.domain.com:443:$IP https://my.domain.com/            # B

curl --noproxy "*" -4 -sS -o /dev/null -w "http=%{http_code}\n" \
     --resolve www.cloudflare.com:443:$IP https://www.cloudflare.com/  # C
```

```
A  同IP  SNI=demo.pages.dev      → 200 OK
B  同IP  SNI=my.domain.com        → Recv failure: Connection was reset
C  同IP  SNI=www.cloudflare.com   → 200 OK
```

同 IP、同 TCP 通路，仅 SNI 不同即通断相反 ⇒ **封锁由 SNI 字符串触发，与 IP 无关。**

补充特征：

| 实验 | 结果 | 结论 |
|---|---|---|
| 换多个 CF IP、IPv4/IPv6 | 全部 RST | 与 IP、协议版本无关 |
| 80 端口明文 | 同样 RST | Host 字段也在匹配范围 |
| 大小写变体 | 仍 RST | 不区分大小写，按子串匹配 |
| 境外节点探测（check-host.net） | 全部 200 | 域名与服务器全球正常，仅国内出境路径被掐 |
| 域名末尾加 `.` | 裸 curl 可穿透 | xray 内核会规范化域名，实战无效 |

**结论**：节点、Cloudflare、配置均正常，是域名进入黑名单。这也解释了"前几天还正常"——服务端未变，变的是审查设备上的名单。

---

## 3. 对照案例：同一节点，机器 A 能用、机器 B 不能用

### 3.1 假设一（被推翻）：A 的 SNI 填了别的域名

客户端列表只显示 `address`，SNI 与 Host 不显示，故先怀疑 A 的 SNI 为未封域名。读取 A 的实际生效 `guiConfigs/config.json`：

```
address    = my.domain.com
serverName = my.domain.com     # SNI
Host       = my.domain.com     # WS Host
```

三个字段与 B 逐字相同，假设不成立。

### 3.2 找到唯一差异：TLS 分片

diff 两份配置，A 的 `outbounds` 比 B 多两个对象：

```jsonc
{
  "tag": "proxy",
  "streamSettings": {
    "sockopt": { "dialerProxy": "proxy3" }   // proxy 的连接先经过 proxy3 出站
  }
},
{
  "tag": "proxy3",
  "protocol": "freedom",
  "settings": {
    "fragment": {                             // 启用 TLS 分片
      "packets": "tlshello",
      "length": "100-200",
      "interval": "10-20"
    }
  }
}
```

B 的 `guiNConfig.json` 中 `coreBasicItem.enableFragment: false`。**唯一差异：A 开了分片，B 未开。**

### 3.3 五组对照实验

5 套配置同时运行在 B 机器上（不同端口），按固定顺序轮询多轮。节点、UUID、域名相同，唯一差异是分片相关配置：

| 组 | 配置差异 | 结果 | 说明 |
|---|---|---|---|
| A | 无分片、无中转（B 原状） | youtube 000，50 次 RST | 基线 |
| B | 有分片 + 有中转（A 原样） | 8/8 成功，0 次 RST | A 的配置在 B 上同样有效 |
| C | 有中转、删掉 fragment | 000，5 次 RST | 排除"多一层出站本身有用" |
| D | 有 fragment 但 `length: 60000`（不真正切包） | 000，5 次 RST | 证明必须真的切开 |
| E | `length: 136`（切点落在 SNI 字符串内部） | 200，0 次 RST | 有效成分是切断 SNI 字符串 |

C 组排除中转层干扰，D 组证明"切开"本身是有效成分——这两组是结论能否成立的关键。

### 3.4 反证：TCP 层切分无效

用 Python 构造真实 ClientHello，把 TCP 载荷切成两段发送，间隔 300ms，设置 `TCP_NODELAY` 禁用 Nagle 合并，切点从 100 到 1200 扫描：

```
切点 100 / 130 / 136 / 140 / 150 / 400 / 1200 → 全部 RST
```

说明审查设备会**重组 TCP 流**，关注的是重组后的应用层数据。有效分片必须发生在更上层。

### 3.5 抓包取证

在客户端与 CF 之间插一个透明 TCP 中继：监听本地端口，把收到的字节原样落盘后转发给真实 CF IP，并将 xray 出站地址指向中继：

```
【无分片】 ClientHello 总长 585 字节，1 条 TLS 记录发完
  记录1 载荷 = 589 字节（含 5 字节记录头）
  → SNI 完整可见 → 匹配关键字 → RST

【有分片】 ClientHello 总长 585 字节，拆成 5 条 TLS 记录发送
  记录1 载荷 = 114 字节  ← SNI 在握手层第 131~143 字节，不在这条记录里
  记录2 载荷 = 117 字节
  记录3 载荷 = 157 字节
  记录4 载荷 = 198 字节
  记录5 载荷 = 3 字节
  （相邻记录间隔 10~20ms）
```

`fragment` 切的是 **TLS 记录**而非 TCP 段。TLS 允许一条握手消息跨多条记录，每条记录有 5 字节头（类型 + 版本 + 长度），接收方按序拼接恢复完整握手消息，是合法报文形式。

### 3.6 机制

审查设备的行为模型：

1. 会重组 TCP 流（3.4 已证）；
2. 在 TLS 记录层解析：读 5 字节记录头，**在单条记录内**提取握手消息、匹配 server_name；
3. 不实现跨记录的握手消息重组——记录声明后续还有 585 字节握手消息、实际载荷仅 114 字节时解析中断，取不到 SNI，匹配失败，放行；
4. Cloudflare 是完整 TLS 实现，跨记录拼接正常，握手照常完成。

参数含义：

| 参数 | 取值 | 作用 |
|---|---|---|
| `packets` | `tlshello` | 只切握手包，业务数据不切，不影响网速 |
| `length` | `100-200` | 每条记录载荷 100~200 字节 |
| `interval` | `10-20` | 相邻记录间隔 10~20ms |

**报文在协议上合法，客户端与服务器均能正确处理，只有审查设备的解析器不完整（不跨记录重组）而读不懂，遂放行。** 利用的是实现能力差异，不是加密或绕路。

局限：审查设备一旦实现跨记录重组即整体失效，属时效性对策，非长期方案。

### 3.7 结论

A 只是多勾了一个开关（v2rayN：参数设置 → 核心：基础设置 → 启用分片 Fragment），使配置多出 proxy3 分片出站与 dialerProxy 引用。B 补上后实测 youtube 200、出口 IP 为 Cloudflare 段，域名与 UUID 均未改动。

**分片是客户端全局设置，`vless://` 链接不携带**——节点链接只含 address / port / UUID / SNI / Host / path，故复制节点不会复制分片。

---

## 4. 客户端配置：源与产物

`guiConfigs/config.json` 是**输出产物**，配置源头只有两个：

```
guiNDB.db        节点库（SQLite，ProfileItem / SubItem 存节点参数）
guiNConfig.json  全局设置（enableFragment 等开关）
```

客户端在启动、切换节点、修改设置、重载内核时都会按源头重新渲染并覆盖 `config.json`；`guiNConfig.json` 在退出时会被内存中的设置回写。因此直接改 `config.json` 必被覆盖，运行中改 `guiNConfig.json` 退出时被覆盖。正确做法：界面内修改，或**完全退出后**再改 `guiNConfig.json`。

验证分片是否生效：重启后 `guiConfigs/config.json` 的 `outbounds` 应出现第 4 个出站 `proxy3`（freedom + fragment），且 `proxy.streamSettings.sockopt.dialerProxy == "proxy3"`。**看不到 proxy3 即未生效。**

---

## 5. 延迟 -1 的成因

"真连接延迟"= 经该节点完整走 **TCP 握手 → TLS 握手 → 一次业务请求**，任一环失败记 `-1`。它与可用性脱钩的原因有三：

1. **列表数字是历史快照**，不自动刷新，节点恢复后旧 `-1` 仍在，直到手动重测；
2. **测速与真实流量是两条路径**，测速是单独发起的短连接探测，与生效配置承载的持续流量状态可以不一致；
3. **测速目标可能未走代理**：实测默认测速地址解析出国内 CDN IP，命中路由 `geoip:cn → direct` 走直连——节点已死仍返回 204，日志记录 `[http → direct]`。

`-1` 仅表示那一次探测的 TLS 握手被掐断。反之，若测速只测 TCP，失效域名同样显示正常延迟（2.2 已证）——**数字反映测法，不反映可用性**。判断可用性应实际打开网页并核对出口 IP。

---

## 6. 修复与配置项

**应急**：客户端开启 TLS 记录分片（v2rayN：参数设置 → 核心：基础设置 → 启用分片 Fragment → 完全退出重开）。域名、UUID、SNI、Host 均不需改。

**治本**：换自有付费域名绑定 Pages 项目。免费子域名（NS 托管型）被整批拉黑的概率高，且域名生死取决于免费服务商。

**服务端配置项**：

| 配置 | 位置 | 作用 |
|---|---|---|
| `ADMIN` | 环境变量 | `/admin` 面板密码 |
| `UUID` | KV config.json | 节点身份凭据，客户端必须一致 |
| `HOSTS` | KV config.json | 面板/订阅入口域白名单（只影响提示，不影响代理） |
| `KEY` | 环境变量 | 快速订阅路径 `https://域名/KEY值` |
| `PROXYIP` | 环境变量 | Worker 访问同托管在 CF 的站点时的中转 IP，解决 CF 到 CF 回环 |
| `URL` | 环境变量 | 根路径伪装主页地址 |
| `BEST_SUB` | 环境变量 | 优选订阅生成器，将测速筛出的低延迟 CF IP 写入订阅 |
| PATH 参数 | 节点链接 | `/proxyip=…`、`/socks5=…`、`/http=…`、`/trojan=…` 切换出站 |

**安全**：面板用强密码，域名与面板地址不公开分享，节点链接（含 UUID）等同于密码。

---

## 7. 排查清单

```
1. 测量干净：curl 一律加 --noproxy "*"，确认无系统代理污染
2. 分层测：DNS → 纯 TCP 握手 → TLS → 应用层，定位断点
3. SNI 交叉实验：--resolve 锁定 IP 只换 SNI，判定是否按域名封锁
4. 境外节点对照：区分"服务器故障"与"仅出境路径被掐"
5. 对照实验一次只动一个变量，并保留"看似多余"的对照组
   （只删 fragment / 只改 length 不真正切包）
6. 推断不清时抓包：透明 TCP 中继看客户端真实发送的字节
7. 验证只看两项：网页能否打开、出口 IP 是谁，不看延迟列
```

```
客户端配置通则：
- 源 = guiNDB.db + guiNConfig.json；产物 = guiConfigs/config.json
- 改动要落在"源"上，改文件前先完全退出程序
- 分片开关 = coreBasicItem.enableFragment，vless:// 不携带该设置
- 验证：config.json 出现 proxy3 且 dialerProxy == "proxy3"
```

> 结论基于特定时间点的实测，网络环境持续变化，方法比数字更值得参考。
