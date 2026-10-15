# Docker 部署 DNMP 完整流程（Docker + Nginx + MySQL + PHP）

| 项目   | 内容                                                                        |
| ---- | ------------------------------------------------------------------------- |
| 适用环境 | 已装好 Docker 的 Linux 服务器（Ubuntu / Debian 为主，EL 系差异单独标注），root 身份操作           |
| 目标   | 从空机器做到：三个容器跑起一个能读写 MySQL 的 PHP 网站，并具备对外上线条件                               |
| 组件版本 | Nginx 1.30（stable）· PHP 8.4-FPM · MySQL 8.4 LTS —— 均为 2026-10 仍在安全支持期内的版本 |
| 项目根  | `/home/lnmp-web`                                                          |
| 通用性  | 全文不绑定域名与 IP，需要替换的地方一律写成 `<占位符>`                                           |
| 适合谁  | 想搞懂"每个文件为什么这么写"、而不只是复制粘贴的人                                                |

> **动手前先看两条。**
>
> **① 别抄旧教程的版本号。** 网上多数 DNMP 教程默认的 **MySQL 8.0 已于 2026 年 4 月到达生命周期终点（EOL）**，**PHP 8.2 的安全支持也在 2026-12-31 结束**。本文用 MySQL 8.4 LTS 与 PHP 8.4，选版理由见第 7 节，从 8.0 升级时要先删掉的两个参数见 7.4。
>
> **② DNMP 是"容器里的 LNMP"。** 它把 Nginx、PHP-FPM、MySQL 各装进一个容器，用 Docker 网络连起来。相比直接装在系统里（裸机 LNMP），它多了一层抽象，换来环境一致性、可整机搬迁、以及"改坏了 30 秒重建"。代价是排障时你要多看一层：错误可能来自应用，也可能来自编排或网络。
>
> **本文提到的"EL 系"** 指 RHEL（Red Hat Enterprise Linux）及按它源码重建的下游发行版：CentOS、Rocky Linux、AlmaLinux、Oracle Linux。它们共用 rpm / dnf、SELinux、firewalld，命令基本可互换，所以归为一类；**EL7 / EL8 / EL9** 是主版本号。另一族是 Ubuntu / Debian（apt / dpkg）。全文只需分清这两族。

---

## 先看全局：DNMP 一次请求怎么走

先记住一个比喻：三个容器就像三台互不干扰的小电脑 —— 各自有自己的文件系统、自己的进程，看不见对方的目录。它们之间要说话，只能靠 Docker 搭的"内部电话线"（容器网络）+ 门牌号（compose 服务名）。

| 角色        | 容器                            | 干什么                            | 类比    |
| --------- | ----------------------------- | ------------------------------ | ----- |
| Nginx     | lnmp-nginx（nginx:1.30-alpine） | 在 80 端口收请求；静态文件自己发，`.php` 转给别人 | 前台接待  |
| PHP-FPM   | lnmp-php（php:8.4-fpm-alpine）  | 真正执行 `.php`，要数据就去问数据库          | 后厨    |
| MySQL     | lnmp-mysql（mysql:8.4）         | 存取数据                           | 仓库    |
| Docker 网络 | compose 自定义网络                 | 容器之间按服务名互相找到（Docker 内嵌 DNS）    | 楼内电话线 |

一次请求的完整路径：

```
① 浏览器请求 http://<服务器IP>/
   │
   ▼
② 宿主机 80 端口收到 —— 被 ports: "80:80" 转进 nginx 容器
   │
   ▼
③ nginx 看请求是什么：
     · 静态文件（html / css / 图片）→ 直接从自己的 /usr/share/nginx/html 发回，结束
     · .php → 交给 PHP 处理，继续往下
        fastcgi_pass php:9000
        ↑ "php" 是 compose 服务名，不是域名也不是 IP，由 Docker 内嵌 DNS 解析成 php 容器地址
   │
   ▼
④ php 容器收到请求，在【它自己的】/usr/share/nginx/html 里找到文件并执行
     （所以 nginx 和 php 必须挂载"一模一样的容器内路径"，见 3.3）
   │  new mysqli('mysql', 'web_user', ...)
   ▼
⑤ php 需要数据 → 同样用服务名 mysql 连上 mysql 容器，查库
   │
   ▼
⑥ php 生成 HTML 交回 nginx，nginx 再发给浏览器
```

一句话：浏览器 → 宿主机 80 → nginx 容器 → php 容器 → mysql 容器，返回时原路回去。宿主机在这条链路里只干两件事：**转发端口**（80:80），以及**提供代码目录**（把 `./html` 同时挂给 nginx 和 php）。

**三条容器特有的规则，后面会反复用到：**

1. **容器之间只能走 TCP**，不能像裸机那样共用 unix socket —— 两个容器没有共享文件系统。
2. **"挂载"不等于"复制"。** 改挂载进来的**文件内容**，容器立刻读到；改 `docker-compose.yml`**本身**（端口 / 环境变量 / 挂载路径 / command），必须 `up -d` 重建才生效。
3. **容器的文件系统是临时的。** 只有卷和 bind 挂载目录里的东西会留下 —— 所以扩展要写进 Dockerfile，数据要放命名卷。

---

## 1. 安装 Docker 与 Compose

### 1.1 安装（docker + compose + buildx 一次装齐）

```bash
su - root
curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun
```

- `| sh -s --` 的作用：把"下载脚本"和"执行脚本"合成一步，`--` 后面的参数转交给脚本。等价于先 `curl -o install-docker.sh`、再 `sh install-docker.sh --mirror Aliyun`。
- **`--mirror Aliyun` 别省**：不加会走 `download.docker.com`，国内基本超时。
- 装完你就有 `docker`、`docker compose`（v2 插件形式，含 buildx），并且已设好开机自启。
- ⚠️ 如果机器上已经有 `docker` 命令，脚本只会警告并等 20 秒后继续装，**与 apt 装的 `docker.io` 混装会冲突**。先清干净：
  ```bash
  apt purge -y docker.io docker-compose-v2 docker-buildx
  ```
  （数据在 `/var/lib/docker`，不受影响。）

### 1.2 配置镜像加速 + 全局日志限额

```bash
mkdir -p /etc/docker
vim /etc/docker/daemon.json
```

内容：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live",
    "https://dockerpull.com"
  ],
  "dns": ["223.5.5.5", "114.114.114.114", "8.8.8.8"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

这一段同时做三件事：

- **镜像加速器**只对"从 Docker Hub 拉镜像"生效（`nginx` / `mysql` / `php` 这些基础镜像）；Dockerfile 里的 `apk add` 走的是 Alpine 软件源，加速器管不到，拉得慢是正常的。  
  ⚠️ 上面几个地址都是第三方社区服务，**可用性会随时间波动**（详见 7.3），照抄前先自测一下。
- **`log-opts` 是全局日志上限。** Docker 的 `json-file` 日志驱动**默认不设上限**，一个报错循环刷上几天就能把磁盘写满、连带整台机器一起挂掉。在这里设一次，比每个服务单独写更省事。（注意：**只对新建的容器生效**，已存在的容器要 `up -d` 重建。）
- **`dns`** 给容器一个可靠的解析来源，避免个别环境下容器内解析慢或不稳。

改完必须重启 Docker 才生效：

```bash
python3 -m json.tool /etc/docker/daemon.json    # 先验 JSON，写错会导致 Docker 起不来
systemctl daemon-reload
systemctl restart docker
docker info | grep -A 4 'Registry Mirrors'      # 能列出上面几个地址即成功
```

⚠️ `daemon.json` 是 JSON，**最后一个键后面不能有逗号**。写错 Docker 会直接起不来，报 `unable to configure the Docker daemon with file /etc/docker/daemon.json`。

### 1.3 验证

```bash
docker version            # Client 和 Server 都要有版本号
docker compose version
systemctl is-active docker
```

---

## 2. 项目目录与 4 个文件

### 2.1 建目录

```bash
mkdir -p /home/lnmp-web/{html,nginx,php}
cd /home/lnmp-web
```

### 2.2 文件清单

最终长这样：

```
/home/lnmp-web/
├─ docker-compose.yml     ← 编排：定义三个容器、挂载、网络、数据库口令
├─ Dockerfile-php         ← 定制 PHP 镜像（加 pdo_mysql / mysqli 扩展）
├─ html/                  ← 网站源码（bind 挂载给 nginx 和 php 两个容器）
├─ nginx/
│  └─ default.conf        ← Nginx 站点配置
└─ php/
   └─ php.ini             ← PHP 自定义配置
```

上传时的对应关系：

| 本地文件               | 放到 VPS 的位置                        | 备注                         |
| ------------------ | --------------------------------- | -------------------------- |
| docker-compose.yml | /home/lnmp-web/docker-compose.yml | 必须和 Dockerfile-php 同级      |
| Dockerfile-php     | /home/lnmp-web/Dockerfile-php     | compose 按 build.context 找它 |
| nginx/default.conf | /home/lnmp-web/nginx/default.conf |                            |
| php/php.ini        | /home/lnmp-web/php/php.ini        |                            |

> **口令直接写在 `docker-compose.yml` 里，不另建 `.env`。** 理由与代价见 3.5。

⚠️ **上传完先 `ls -l` 看一眼类型。** bind 挂载有一个隐蔽的坑：如果宿主机上被挂载的**那个文件**不存在，Docker 会**自动创建一个同名目录**，不报错。结果是 nginx 拿到一个目录当配置文件，行为诡异且报错不直观。`ls -l` 里看到权限位以 `d` 开头，就说明搞错了。

---

## 3. 逐文件讲解：每个文件为什么这么写

### 3.1 Dockerfile-php —— 为什么 PHP 要自己构建镜像

官方 `php:8.4-fpm-alpine` 是"裸"的：不带 `mysqli` / `pdo_mysql` 扩展，而网站连 MySQL 必须要它们。所以基于官方镜像加装扩展，构建成自己的镜像：

```dockerfile
FROM php:8.4-fpm-alpine

# pdo_mysql / mysqli 的源码随 PHP 一起发布，编译它们不需要任何额外的 apk 包
RUN docker-php-ext-install pdo_mysql mysqli

# 需要 zip / gd 时再放开下面三行（含各自的编译期依赖，缺一不可）
# RUN apk add --no-cache libzip-dev freetype-dev libjpeg-turbo-dev libpng-dev
# RUN docker-php-ext-configure gd --with-freetype --with-jpeg
# RUN docker-php-ext-install zip gd
```

**要点：**

- **扩展要编译进镜像，不能等容器起来再 `docker-php-ext-install`** —— 后者是一次性的，`docker compose down` 重建容器就丢了。改了 Dockerfile 必须带 `--build` 重建。
- **`apk add` 的依赖是按扩展区分的。** 只装 `pdo_mysql` / `mysqli` 时，**一个额外的 apk 包都不需要**（官方 PHP 镜像本身不做区分，这两个扩展的源码随 PHP 一起发布）。`libzip-dev` 是给 `zip` 用的；而 **`gd` 在 Alpine 上必须先装 `freetype-dev libjpeg-turbo-dev libpng-dev` 并执行 `docker-php-ext-configure`，否则编译直接失败。** 上面注释块里已经写全，取消注释即可用。
- 编译慢的话可以加并发：`docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli`。
- **确认 opcache 是否已启用**：官方镜像通常已经内置并启用，先查再决定要不要处理：
  ```bash
  docker exec lnmp-php php -m | grep -i opcache   # 有 "Zend OPcache" 即已启用
  ```
  没有输出时，在 Dockerfile 里加一行 `RUN docker-php-ext-enable opcache`，重新 build。

**为什么基础镜像是 8.4 而不是 8.2**：PHP 每个分支支持 4 年（2 年活跃支持 + 2 年仅安全修复）。**8.2 的安全支持在 2026-12-31 结束**，现在新起项目不该再用它。8.4 的安全支持到 2028-12-31；若所用框架已明确声明支持 PHP 8.5，也可换 `php:8.5-fpm-alpine`（支持到 2029-12-31）。详见第 7 节。

### 3.2 php/php.ini —— 挂到 conf.d 当"附加配置"

```ini
; ---------- 基础 ----------
date.timezone          = Asia/Shanghai
expose_php             = Off

; ---------- 报错：关回显、开日志（两条必须成对出现）----------
display_errors         = Off
display_startup_errors = Off
log_errors             = On
error_log              = /proc/self/fd/2
;                        ↑ 容器专用写法：PHP 错误直接进容器 stderr，
;                          用 docker compose logs -f php 就能看到，不必进容器翻文件
error_reporting        = E_ALL

; ---------- 上传与执行：必须成严格递增关系 ----------
upload_max_filesize = 20M    ; ① 单个文件上限
post_max_size       = 25M    ; ② 整个 POST 上限，必须 > ①
memory_limit        = 256M   ; ③ 必须 >= ②（建议再宽一档）
max_execution_time  = 120    ; ④ 单个脚本最长执行秒数（默认 30，大文件/导入会超时）
max_input_time      = 120    ; ⑤ 接收请求数据的最长时间

; ---------- 会话 ----------
session.cookie_httponly = 1
session.cookie_samesite = Lax
; session.cookie_secure = 1  ; 启用 HTTPS 之后再打开

; ---------- opcache（上线后按需微调）----------
opcache.enable                = 1
opcache.memory_consumption    = 128
opcache.max_accelerated_files = 10000
opcache.validate_timestamps   = 1
opcache.revalidate_freq       = 60
```

它被挂载为 `/usr/local/etc/php/conf.d/custom.ini` —— 官方镜像会自动加载 `conf.d/*.ini`，我们的文件**叠加**在默认配置之上，不用覆盖主 `php.ini`。

**逐条说明：**

- **`display_errors` 与 `log_errors` 必须成对出现。** `display_errors = Off` 只负责"不给访客看报错细节"；错误记不记、记到哪，由 `log_errors` 和 `error_log` 决定。只关不记的结果是：页面白屏、日志里什么都没有，线上排障完全失明。
- **`error_log = /proc/self/fd/2` 是容器里的省事写法**：PHP 错误直接写进容器 stderr，`docker compose logs -f php` 就能看到。裸机上你会写成 `/var/log/php/error.log`，但容器里没必要为了看日志再 `docker exec` 进去。
- **四个上传 / 执行上限必须成严格递增关系。** POST 的体积 = 文件本体 + 表单其他字段 + multipart 边界与头部，所以 `post_max_size` 必须**大于** `upload_max_filesize`。两者相等时，一个"看着没超限"的文件会先撞上 `post_max_size`，PHP 会**丢弃整个 POST 且不报错** —— 表现为提交后页面空白、`$_POST` 与 `$_FILES` 全空。这是"文件明明不大却传不上去"最常见的成因。
- **`expose_php = Off`** 让响应头不再出现 `X-Powered-By: PHP/8.4`。
- **注意 `mysqli_report` 不是 php.ini 指令。** PHP 官方 mysqli 的 ini 指令清单里没有它，写进去会被静默忽略、既不报错也不生效。PHP 8.1 起 mysqli 的报错模式默认已是"抛异常"（`MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT`），这是更现代的写法；确实需要旧行为时，在应用入口写 `mysqli_report(MYSQLI_REPORT_OFF);`，不要走 php.ini。
- **`session.cookie_secure`** 先注释着，等 HTTPS 通了再打开 —— 开着它而站点只有 HTTP 的话，PHP 会拒绝下发会话 Cookie。

### 3.3 nginx/default.conf —— 逐段解释

**第一段：监听与站点名**

```nginx
server {
    listen      80;
    listen      [::]:80;                 # IPv6，缺它会导致走 IPv6 的请求命中不到本站点
    server_name _;
```

`server_name _;` 这一行值得单独说清楚，因为它经常被误解：

> `_` **不是通配符**，它就是一个不匹配任何 Host 的无效占位名。这里能工作，真正原因是**本容器 80 端口下只有这一个 server 块，且没有任何块声明 `default_server`**，于是它被隐式当作该端口的默认 server 兜底 —— 与 `_` 这个字符串本身毫无关系。
>
> 一旦这套配置被挪进多站点场景（比如宿主机上另有一个带 `default_server` 的站点），请求会被那个站点接走，而 `nginx -t` 依然全过、配置文件看着完全正确。**所以多站点场景必须写真实域名 / IP，或显式声明 `default_server`。**

（顺带说明一个常见困惑：裸机 LNMP 里"用 IP 访问看到 nginx 欢迎页或 403"，就是系统自带的 default 站在兜底；容器里没有那个站点，所以现象不同。）

**第二段：路径、生产开关与上传上限**

```nginx
    root  /usr/share/nginx/html;         # 容器内路径，靠 volume 映射进来
    index index.php index.html index.htm;

    server_tokens off;                   # 不在响应头和错误页暴露 nginx 版本号
    client_max_body_size 25m;            # 必须 >= php.ini 的 post_max_size

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;
```


`root` 写的是**容器内**路径 —— `/usr/share/nginx/html` 在宿主机上"不存在"完全正常，靠 `volumes: - ./html:/usr/share/nginx/html` 把宿主机目录映射进来。官方 nginx 镜像已经把这个日志目录软链到容器的 stdout / stderr，所以直接写这两个路径即可，日志照样能用 `docker compose logs` 看到。

`server_tokens off;` 对应 PHP 侧的 `expose_php = Off`：两边都不暴露版本号，能省掉一类"按版本号找漏洞"的自动化扫描。

**第三段：三条 deny 规则 —— 位置很关键**

```nginx
    location / { try_files $uri $uri/ /index.php?$query_string; }

    # ★ 以下三条必须排在 \.php$ 之前 —— nginx 的正则 location「先匹配者胜」
    location ~* ^/uploads/.*\.(php|phtml|phar|php[0-9])$ { deny all; }        # ① 上传目录禁执行
    location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }  # ② 隐藏文件
    location ~* \.(bak|sql|log|ini|conf|env)$ { deny all; }                   # ③ 备份与敏感后缀
```

第 ② 条尤其不能省。`try_files $uri $uri/` 一旦命中真实文件就把它当静态文件返回，所以站点根目录下的这些东西**默认可被匿名下载**：

```
/.env            → 若你后来改用 .env 存口令，这里就是数据库账号（见 3.5）
/.git/config     → 可顺着遍历拉走整个源码
/config.php.bak  → 绕过 PHP 解析直接出源码
/.user.ini       → PHP 的每目录配置
```

**这条规则不是"因为用了 `.env` 才要加"。** 本项目把口令直接写进了 compose 文件（见 3.5），站点目录下并没有 `.env`；但 `.git`、`.bak`、`.user.ini` 这些东西**默认就能被匿名下载**，任何一项泄露都等于源码或配置外流。所以它属于"宁可多拦一层"的基础配置，与口令存哪儿无关。括号里的 `(?!well-known)` 是为将来签发证书留的口子 —— 去掉它，ACME 验证会失败。

**第四段：PHP 转发**

```nginx
    location ~ \.php$ {
        try_files $uri =404;             # 文件不存在直接 404，不甩给 PHP
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;  # 必须显式给
        fastcgi_index index.php;
        fastcgi_pass php:9000;           # 容器间只能 TCP，php 是 compose 服务名
        fastcgi_read_timeout 120s;       # 与 php.ini 的 max_execution_time 对齐
    }
```

三条最容易踩的：

1. **绝对不能写 unix socket。** 裸机 LNMP 用 `unix:/run/php/...sock`，但两个容器是隔离的、没有共享文件系统，只有 TCP 可走。`php` 这个名字由 Docker 内嵌 DNS 解析成 php 容器的地址。
2. **`SCRIPT_FILENAME` 必须显式设置** —— `include fastcgi_params` 里**不含**这个值，少了它 PHP-FPM 一律返回 `File not found`。
3. **两个容器必须挂载一模一样的容器内路径。** Nginx 负责拼路径交给 PHP-FPM，PHP-FPM 拿到路径后按**自己容器的文件系统**去读；一边改成别的路径，立刻 502 / File not found。

> 完整可直接复制的版本见**附录 A.3**。

### 3.4 docker-compose.yml —— 三个容器怎么编排

**nginx 服务：唯一对外入口**

```yaml
  nginx:
    image: nginx:1.30-alpine           # 固定到小版本；追求极致可锁 digest
    container_name: lnmp-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      # - "443:443"                    # 启用 HTTPS 后打开
    volumes:
      - ./html:/usr/share/nginx/html
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    environment:
      TZ: Asia/Shanghai
    depends_on:
      php:
        condition: service_started
    networks: [frontend, backend]
```

**php 服务：自定义构建 + 等数据库就绪**

```yaml
  php:
    build:
      context: .
      dockerfile: Dockerfile-php
    image: lnmp-web-php:8.4             # 给构建结果命名并加版本
    container_name: lnmp-php
    restart: unless-stopped
    volumes:
      - ./html:/usr/share/nginx/html   # ★ 必须和 nginx 挂载的容器内路径一模一样
      - ./php/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    environment:
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy     # 等 MySQL 真的就绪，而不是"启动过"
    networks: [backend]
```

**mysql 服务：数据持久化 + 健康检查**

```yaml
  mysql:
    image: mysql:8.4
    container_name: lnmp-mysql
    restart: unless-stopped
    ports:
      - "3306:3306"                    # 对宿主机所有网卡开放，供 DBeaver 等外部工具连库（见 4.6）；
                                       # 不需要外部连库时改回 "127.0.0.1:3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql      # named volume：数据库持久化
    environment:
      TZ: Asia/Shanghai
      MYSQL_ROOT_PASSWORD: "<强口令，替换掉这对尖括号>"
      MYSQL_DATABASE:      lnmp_web
      MYSQL_USER:          web_user
      MYSQL_PASSWORD:      "<强口令，替换掉这对尖括号>"
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_0900_ai_ci
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s
```

**关键点：**

- **bind 挂载（`./xxx:...`）不需要在底部 `volumes:` 声明；命名卷（`mysql_data:...`）必须声明**，否则 compose 直接报错。
- **顶层 `name: lnmp-web` 不能省。** 它显式指定项目名（默认取所在目录名）。本项目目录是 `/home/lnmp-web`，两者一致，所以已有的数据卷 `lnmp-web_mysql_data` 不会被当成新卷。**改了项目名就等于换了一套卷，数据会"不见了"。**
- **`depends_on` 只保证启动顺序，不保证"已就绪"。** MySQL 首次初始化要几十秒，`up -d` 完立刻开页面会连不上。正确解法是 `healthcheck` + `condition: service_healthy` —— 上面已经配好，php 会等 MySQL 真的能响应 `mysqladmin ping` 才启动。（`$$` 是 compose 的转义写法，表示传给容器的是字面量 `$`。）
- **口令直接写在 compose 文件里。** 首次装完记得把它换掉（`openssl rand -base64 24` 生成一条随机串粘进去），不要留 `MYSQL_PASSWORD: 123456` 这种。**代价要清楚**：这个 yml 一旦被拷走、发群里、传进笔记或提交进 git，口令就跟着一起泄露 —— 所以它**只适合单机自用**；要和别人共享这份配置，就把口令抽到 `.env` 里（做法见 3.5）。另外注意 YAML 里有 `: `（冒号加空格）、`#`、`@` 这类字符的口令要**套上引号**，否则解析会出错。
- **`3306:3306` 与 `127.0.0.1:3306:3306` 的区别，就是"能不能从外面连"。** 前者等价于 `0.0.0.0:3306`，对宿主机**所有网卡**开放；后者只绑回环，只有宿主机自己能连。**本文（HTTP 版）用前者**，因为你在 Windows 上用 DBeaver 直连数据库要靠它 —— 具体填法见 4.6，安全取舍也在那里说清。**上生产时改回 `"127.0.0.1:3306:3306"` 或直接删掉这两行**：容器之间始终能通过服务名 `mysql:3306` 互通，网站访问完全不受影响。
- **`mysql:8.4` 而不是 `mysql:8.0`**：8.0 已于 2026 年 4 月 EOL。8.4 是当前 LTS，且 `command` 里已经不带任何会被 8.4 移除的参数 —— 换版本不需要再改别处（8.0 升级时要先删的两个参数见 7.4）。
- **`MYSQL_DATABASE` / `MYSQL_USER` 只在数据目录为空（首次初始化）时生效。** 之后想改密码或加库，要么进容器执行 SQL，要么 `down -v` 清卷重来（会删光数据）。
- **官方 mysql 镜像首次初始化时，`MYSQL_USER` 建出的账号 host 是 `'%'`** —— 这就是容器里、容器外都能连它的原因。
- **`restart: unless-stopped` 而不是 `always`**：语义是"崩了自动拉起，但你手动 `stop` 之后就别再自己回来"。用 `always` 的话，你为了维护手动停掉的容器会在 Docker 重启后不听指令地回来。
- **`container_name` 写死了三个容器名**，好处是命令短、好读（`docker exec lnmp-mysql ...`）。代价是**该服务无法扩容**（`--scale` 会因名字冲突失败）。单机单实例场景没问题；要跑多份副本时删掉这三个 `container_name`，改用 `docker compose exec <服务名>`。
- **`command` 写成 YAML 列表而不是多行字符串。** Compose 的 `command` 无论字符串还是列表都等价于 Dockerfile 的 **exec 形式、不经 shell**，字符串会按空白切分 —— 所以两种写法都能工作。但一旦某个参数含空格，字符串写法就会被切错，列表式更稳。
- **`--collation-server=utf8mb4_0900_ai_ci`** 是 MySQL 8.0 起的默认排序规则（Unicode 9.0、重音不敏感）。旧的 `utf8mb4_general_ci` 仍可用，但新项目没必要沿用 5.7 时代的规则。
- **`explicit_defaults_for_timestamp` 这类参数不要加。** 它在 8.0 里已是默认 ON 且被标记弃用（写了等于没写），在 8.4 里**已被移除** —— 传进去会让 mysqld 直接启动失败并报 `unknown variable`。同理 `--default-authentication-plugin` 在 8.4 也已移除。PHP 侧基于 mysqlnd，**原生支持 `caching_sha2_password`**，完全不需要把认证降级为 `mysql_native_password`。

> 完整可直接复制的版本见**附录 A.4**。

### 3.5 口令怎么写：本项目直接放 yml，`.env` 留作备选

**本版做法**：数据库口令直接写进 `docker-compose.yml` 的 `environment` 里（见 3.4）。

**为什么这么选**：这个项目的定位是**单机自用** —— 一份配置只对应一台服务器，没有"开发/测试/生产三套不同口令"的场景，也不进版本库。这种情况下多一个文件就多一处要记得传、记得 `chmod`、记得别漏传的地方，反而增加出错面。少一个文件，`docker compose up -d` 就能跑。

**代价必须说清**（三选一时，你至少要知道自己放弃了什么）：

| 场景                  | 直接写 yml 会怎样                  |
| ------------------- | ---------------------------- |
| 把 yml 发到群里 / 写进笔记教程 | 口令跟着一起泄露，删不干净                |
| 这个目录纳入了 git         | 口令进了提交历史，**改密码也删不掉旧记录**      |
| 想给另一台机器换套口令         | 只能维护两份 yml，diff 时结构改动被口令差异淹没 |

> **而 `.env` 正是为解决这三条存在的**：把口令抽到同目录下一个叫 `.env` 的文件里（compose 会自动读取，不需要任何声明），yml 里改写成 `${MYSQL_PASSWORD}` 取值；再给必填项加校验 `${MYSQL_PASSWORD:?请在 .env 中设置}` —— 没建 `.env` 时会直接报错退出，而不是起来一个空口令的数据库。真要共享这份配置、或纳入 git 时，把它换回来即可。

**如果你决定改用 `.env`**，三步：

```bash
openssl rand -base64 24
```

```ini
# .env —— 与 docker-compose.yml 放同一目录，compose 会自动读取
MYSQL_ROOT_PASSWORD=<粘贴上一条随机串>
MYSQL_DATABASE=lnmp_web
MYSQL_USER=web_user
MYSQL_PASSWORD=<再生成一条随机串粘贴到这里>
```

```bash
chmod 600 /home/lnmp-web/.env
```

然后把 yml 里那 4 行 `environment` 换回变量写法：

```yaml
    environment:
      TZ: Asia/Shanghai
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:?请在 .env 中设置}
      MYSQL_DATABASE:      ${MYSQL_DATABASE:-lnmp_web}
      MYSQL_USER:          ${MYSQL_USER:-web_user}
      MYSQL_PASSWORD:      ${MYSQL_PASSWORD:?请在 .env 中设置}
```

⚠️ **改用 `.env` 后有一件事必须做**：确认它**不能被浏览器下载** —— 靠 3.3 节第 ② 条那条 deny 规则。否则等于把口令从代码仓库挪到了网站根目录下，问题反而更严重。

**`.gitignore` / `.dockerignore` 本项目同样不需要**：

| 文件              | 什么时候才值得加                                                                                                                          |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `.gitignore`    | 只有你把这个目录纳入了 **git 管理**时才需要（内容就是一行一条：`.env`、`*.sql`、`*.tgz`）。不用 git 就删掉                                                            |
| `.dockerignore` | 只有**构建上下文很大**时才值得加（本项目 `build` 只用到 `Dockerfile-php`，`context: .` 打包的那点文件可以忽略）。网站代码到了几百 MB 再加，内容通常是 `html/`、`.git/`、`.env`、`*.log` |

### 3.6 Named Volume 与 Bind Mount：两种挂载怎么选

两者都是挂载，区别在于数据归谁管：

| 对比项                      | Named Volume 命名卷                                                        | Bind Mount 绑定挂载                                 |
| ------------------------ | ----------------------------------------------------------------------- | ----------------------------------------------- |
| 写法                       | `卷名:/容器内路径`，如 `mysql_data:/var/lib/mysql`                               | `宿主机路径:/容器内路径`，如 `./html:/usr/share/nginx/html` |
| 数据在哪                     | Docker 管理区 `/var/lib/docker/volumes/<卷名>/_data`，`docker volume ls` 能看到  | 你指定的宿主机目录，`docker volume ls` 里看不到（它不是卷）         |
| 首次挂载行为                   | 空卷会把镜像内该目录的原有内容连同属主拷进去                                                  | 宿主机目录直接盖住容器内目录，容器原有内容被遮蔽                        |
| 权限归谁                     | Docker 管理，实际取决于容器内进程 UID                                                | 就是宿主机文件权限；宿主机 UID 与容器 UID 对不上就写入失败              |
| 宿主机直接改                   | 路径深、要 root，一般不直接改                                                       | ✅ Vim / IDE 直接改，容器立刻读到（代码、配置的常规做法）              |
| 备份 / 迁移                  | 需 `docker run --rm -v 卷名:/d -v $PWD:/b alpine tar czf ...`，或直接拷 `_data` | 直接拷目录，最省事                                       |
| compose 里                | 必须在文件末尾 `volumes:` 声明，否则报错                                              | 不需要声明                                           |
| 名字 / 路径规则                | 自动加项目名前缀：`lnmp-web_mysql_data`                                          | 相对路径按 compose 文件所在目录解析（不是执行命令时的当前目录）            |
| `docker compose down` 之后 | 容器删了卷还在；加 `-v` 才连卷一起删                                                   | 完全不受影响                                          |

**怎么选**：代码和配置用 bind（要随时改、看得见）；数据库这类由容器自己维护的数据用命名卷（别让宿主机权限去管它，bind 最容易踩 UID 坑）。

本项目的分法就是：`./html`、`./nginx/default.conf`、`./php/php.ini` 用 bind；`mysql_data:/var/lib/mysql` 用命名卷。

---

## 4. 部署执行

### 4.1 改代码目录属主（alpine 的 www-data 是 uid 82）


```bash
chown -R 82:82 /home/lnmp-web/html
chmod -R 755 /home/lnmp-web/html
```

**为什么是 82：**

- **alpine 版 php-fpm 的运行用户 `www-data` 的 UID 是 82**（Debian 系的 php 镜像才是 33）。PHP 要往 `html/` 里写配置文件、往 `uploads/` 存图片，属主不是它就"页面能开、一提交就报错"—— 和裸机 LNMP 改 `www-data` 属主是同一个道理，只是容器环境里**用数字 UID 最稳**：宿主机上并不存在叫 `www-data` 的用户也没关系，容器按 UID 认人。
- **755 让 nginx 容器（uid=101）能进入目录、读文件**，但**不需要也不应该把属主给它** —— nginx 只读，PHP 才需要写。
- 以后往 `html/` 传了新文件，如果 PHP 写不了，重跑一次上面的 `chown`。

### 4.2 启动（首次必须带 --build）

```bash
cd /home/lnmp-web
docker compose config          # 先预览最终生效的配置（展开 YAML 锚点、检查缩进与语法）
docker compose up -d --build
```

- `--build`：按 Dockerfile 构建自定义 PHP 镜像。**以后只要改了 Dockerfile，都要重新带上它**，否则跑的还是旧镜像。
- `up -d`：按依赖顺序后台启动，并自动创建 compose 网络（服务名互为 DNS）和命名卷。
- `docker compose config` 这一步能提前发现缩进、变量名之类的问题，值得固定成习惯。

### 4.3 验证容器状态

```bash
docker compose ps                        # 三个容器都应为 Up；mysql 稍慢属正常
docker compose logs -f                   # 看启动日志，Ctrl+C 退出
docker compose logs -f nginx             # 单看某个服务
ss -lntp | grep -E ':80|:3306'           # 宿主机 80 / 3306 已被 docker-proxy 监听
```

`docker compose ps` 的 `STATUS` 列如果显示 `(healthy)`，说明健康检查已通过；显示 `(health: starting)` 是还在探测中。

如果 80 端口起不来，先看是不是宿主机以前 apt 装过 nginx / mysql 还占着端口：`systemctl stop nginx mysql` 并 `disable` 掉，再 `docker compose up -d`。

### 4.4 放一个探针页面

```bash
echo '<?php phpinfo();' > /home/lnmp-web/html/index.php
```

浏览器访问 `http://<服务器IP>/`，能看到 PHP Info 页、且 **Server API 是 `FPM/FastCGI`、扩展列表里能看到 `mysqli` 和 `pdo_mysql`**，就说明 nginx → php 这条链通了。

⚠️ **验证完把这个文件删掉**（或换成普通静态页）。`phpinfo()` 会输出大量环境信息，对外暴露没有任何好处。

### 4.5 验证 MySQL

```bash
# 一条命令直接登录（推荐）
docker exec -it lnmp-mysql mysql -u web_user -p lnmp_web

# 或先进容器 shell 再手动登录
docker exec -it lnmp-mysql sh
```

进去后：

```sql
SHOW DATABASES;                       -- 能看到 lnmp_web
SELECT user, host FROM mysql.user;    -- web_user 的 host 是 %，所以哪都能连
SELECT VERSION();                     -- 应为 8.4.x
exit;
```

### 4.6 用 DBeaver / Navicat 等外部工具连库（HTTP 版）

4.5 是在容器里连。要在 Windows 上用 DBeaver 连过去看表，需要三件事同时成立：

```sql
-- ① 账号允许任意来源。官方 mysql 镜像用 MYSQL_USER 建的账号本来就是 'web_user'@'%'；
--    只有账号被限制成 localhost / 127.0.0.1 时才需要补一句放开来源
SELECT user, host FROM mysql.user;
```

```yaml
# ② 端口要发布到宿主机（附录 A.4 里已经是这一行）
    ports:
      - "3306:3306"
```

```bash
# ③ 宿主机防火墙与云厂商安全组都要放行 3306（两层，只放一层等于没放）
ufw allow 3306/tcp
```

**DBeaver 里这样填**：

| 字段       | 填什么                                                     |
| -------- | ------------------------------------------------------- |
| 主机       | 服务器的公网 / 内网 IP                                          |
| 端口       | 3306                                                    |
| 数据库      | lnmp_web                                                |
| 用户名 / 密码 | web_user / `docker-compose.yml` 里 `MYSQL_PASSWORD` 那行的值 |

**连不上时按顺序查**：

```bash
ss -lntp | grep 3306                                                     # 宿主机应看到 docker-proxy 监听 0.0.0.0:3306
docker exec lnmp-mysql mysql -uweb_user -p -e "SELECT CURRENT_USER();"   # 容器内先确认账号本身能连
```

- 报 **`Public Key Retrieval is not allowed`**（MySQL 8 的 `caching_sha2_password` 碰上未加密连接）：在 DBeaver 的连接设置里勾选"允许公钥检索"，或在 JDBC URL 后追加 `?allowPublicKeyRetrieval=true&useSSL=false`。
- 报 **1130 Host is not allowed**：账号的 host 不是 `%`，按第 ① 步放开来源。
- **展开"用户""系统"这类菜单报权限错属正常**：`web_user` 只被授予了 `lnmp_web` 一个库。

⚠️ **这一节与后面的安全建议是冲突的，取舍要清楚**：3306 一旦发布到公网就是自动化扫描的重灾区。**HTTP 学习版**为了这层方便可以接受；**上生产就把这两行改回 `"127.0.0.1:3306:3306"` 或删掉**，改用更安全的 SSH 隧道：

```bash
ssh -L 3306:127.0.0.1:3306 root@<服务器IP>   # 在本机执行，然后 DBeaver 连 127.0.0.1:3306
```

---

## 5. 日常运维命令

约定：`<服务名>` = compose 文件里的服务名（`nginx` / `php` / `mysql`）；`<容器名>` = `container_name` 指定的名字（`lnmp-nginx` / `lnmp-php` / `lnmp-mysql`）。**所有 `docker compose` 命令都要在放着 `docker-compose.yml` 的目录里执行**；不在该目录时用 `-f` 指定文件。

### 5.1 看状态与日志

| 目的              | 命令                                                               |
| --------------- | ---------------------------------------------------------------- |
| 当前项目的容器状态       | `docker compose ps`                                              |
| 跟看日志（Ctrl+C 退出） | `docker compose logs -f [服务名]`                                   |
| 只看最后 100 行      | `docker compose logs --tail=100 [服务名]`                           |
| 列出所有容器（含已停止）    | `docker ps -a`                                                   |
| 容器名 / 状态 / 端口速览 | `docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` |
| 某容器挂了哪些卷        | `docker inspect -f '{{json .Mounts}}' <容器名>`                     |
| 资源占用实时排行        | `docker stats`                                                   |
| Docker 自身磁盘占用   | `docker system df`                                               |

### 5.2 启动 / 停止 / 重建

| 目的                  | 命令                                             |
| ------------------- | ---------------------------------------------- |
| 按当前配置启动（缺什么建什么）     | `docker compose up -d`                         |
| 首次启动，或改过 Dockerfile | `docker compose up -d --build`                 |
| 只重建某一个服务            | `docker compose up -d --build <服务名>`           |
| 改了**挂载进来的配置文件内容**   | `docker compose restart <服务名>`                 |
| 暂停 / 继续（不删容器）       | `docker compose stop` / `docker compose start` |
| 删除容器与网络（保留数据卷）      | `docker compose down`                          |
| 删除容器 + 网络 + 数据卷 ⚠️  | `docker compose down -v`                       |
| 重启 Docker 本体        | `systemctl restart docker`                     |

**判断该用 `up -d` 还是 `restart`**：改的是 `docker-compose.yml` **本身**（端口 / 环境变量 / 挂载路径 / command）→ `up -d` 重建；改的只是**挂载进去的文件内容**（nginx 配置、php.ini、网站代码）→ `restart` 对应服务就够。

⚠️ `down -v` 会把数据卷一起删掉，数据库内容全没，只在"确实要从零重来"时用。

### 5.3 进容器、查问题

| 目的                        | 命令                                                               |
| ------------------------- | ---------------------------------------------------------------- |
| 进容器（alpine 基础镜像只有 sh）     | `docker exec -it <容器名> sh`                                       |
| 进容器（Debian / Ubuntu 基础镜像） | `docker exec -it <容器名> bash`                                     |
| 在容器里跑一条命令                 | `docker exec <容器名> <命令>`，如 `docker exec lnmp-nginx nginx -t`     |
| 看某容器日志                    | `docker logs --tail=200 -f <容器名>`                                |
| 查容器为什么退出                  | `docker inspect -f '{{.State.ExitCode}} {{.State.Error}}' <容器名>` |
| 看 compose 解析后的最终配置        | `docker compose config`                                          |
| 不在项目目录时操作该项目              | `docker compose -f /路径/docker-compose.yml <子命令>`                 |

上线前建议固定跑这两条：

```bash
docker exec lnmp-nginx nginx -t     # nginx 语法校验
docker exec lnmp-php  php-fpm -t    # PHP-FPM 池配置校验
```

### 5.4 清理（谨慎）

```bash
docker system df             # 先看清各类对象占了多少空间
docker image prune           # 删无用镜像（不影响运行中的容器）
docker system prune          # 删已停止的容器、无用网络、悬空镜像
docker system prune -a       # ⚠️ 连"没在用"的镜像一起删，之后重建要重新拉
```

服务在跑的时候别随手 `prune -a`；**命名卷不会被 prune 删掉**（数据安全），只有显式 `docker volume rm <卷名>` 才会删。

---

## 6. 数据备份与恢复

### 6.1 手动备份

```bash
cd /home/lnmp-web

# ① 数据库 —— 口令走环境变量，不要写进命令行
docker exec -e MYSQL_PWD="$MYSQL_PWD" lnmp-mysql sh -c 'exec mysqldump --single-transaction -uroot --all-databases' > db_$(date +%F).sql

# ② 网站代码（bind 挂载，就是普通目录拷贝）
tar czf html_$(date +%F).tgz -C /home/lnmp-web html

# ③ 从备份恢复数据库
docker exec -i -e MYSQL_PWD="$MYSQL_PWD" lnmp-mysql sh -c 'exec mysql -uroot' < db_2026-10-15.sql
```

**为什么用 `-e MYSQL_PWD=` 而不是 `-p<密码>`**：命令行参数会出现在 `ps` 的输出里，同机上的任何用户都能看到，而且会进 shell history。环境变量不会。

命名卷里的数据也能整体打包出来：

```bash
docker run --rm -v lnmp-web_mysql_data:/data -v "$PWD":/backup alpine tar czf /backup/vol.tgz -C /data .
```

### 6.2 自动备份（这才是真备份）

先明确一条：**没有推送到异地的备份，不算备份。** 云主机硬盘损坏或被误删时，同一台机器上的备份会一起消失。

```bash
# /root/.my.cnf —— 建议单独建一个只读的备份账号，不要用 root
cat > /root/.my.cnf <<'EOF'
[client]
user=backup_user
password=<备份账号口令>
EOF
chmod 600 /root/.my.cnf
```

```bash
# /usr/local/bin/backup-web.sh
#!/bin/bash
set -euo pipefail
BACKUP_DIR=/backup/web
KEEP_DAYS=7
mkdir -p "$BACKUP_DIR"

# ① 数据库：--single-transaction 保证不锁表
docker exec lnmp-mysql sh -c 'exec mysqldump --single-transaction --all-databases' | gzip > "$BACKUP_DIR/db_$(date +%F).sql.gz"

# ② 网站代码
tar czf "$BACKUP_DIR/html_$(date +%F).tgz" -C /home/lnmp-web html

# ③ 清理本地过期文件
find "$BACKUP_DIR" -type f -mtime +$KEEP_DAYS -delete

# ④ ★ 推送到异地（对象存储 / 另一台机器）—— 没有这一步等于没备份
# rclone sync "$BACKUP_DIR" oss:my-bucket/web-backup
```

```bash
chmod +x /usr/local/bin/backup-web.sh
crontab -e
# 每天凌晨 3 点跑
0 3 * * * /usr/local/bin/backup-web.sh >> /var/log/backup-web.log 2>&1
```

**并且至少做一次恢复演练**：在一台测试机上按 6.1 第 ③ 步把备份导入，确认数据完整。**没验证过的备份不算备份。**

---

## 7. 补充知识：镜像选型与版本时效

这一节解释"为什么默认版本会变"，下次自己选版本时可以照着判断。

### 7.1 三个组件的支持周期不一样

| 组件    | 本文使用         | 支持情况（2026-10 口径）    | 判断依据                                |
| ----- | ------------ | ------------------- | ----------------------------------- |
| Nginx | 1.30（stable） | 稳定分支持续维护            | nginx.org 的 stable / mainline 双分支模型 |
| PHP   | 8.4          | 安全支持至 2028-12-31    | 每个分支 4 年：2 年活跃 + 2 年仅安全修复           |
| MySQL | 8.4 LTS      | Premier 支持至 2029-04 | MySQL 的 LTS / Innovation 双轨发布模型     |

**已终止或不再推荐用于新项目的版本：**

| 版本        | 状态                     | 说明                                                 |
| --------- | ---------------------- | -------------------------------------------------- |
| MySQL 8.0 | **已于 2026 年 4 月 EOL**  | 8.0.46 是最后一个版本；此后进入 Sustaining Support，**不再有安全补丁** |
| PHP 8.2   | **安全支持 2026-12-31 结束** | 网上多数 DNMP 教程仍在用它；距 EOL 仅剩约 2 个月                    |
| PHP 8.3   | 仅安全修复至 2027-12-31      | 可用，但不建议新起项目                                        |

**一句话结论**：新项目用 **PHP 8.4 / MySQL 8.4 LTS**；旧项目升级时先看这两个 EOL 日期，再决定要不要动手。

### 7.2 选版本时的三个实操习惯

1. **先查 EOL 日期，再选版本。** 三个项目的官网都有支持周期表（PHP 的 *Supported Versions*、MySQL 的 *Lifetime Support Policy*、nginx 的 news 页），`endoflife.date` 这类聚合站也能一站看全。
2. **小版本号锁定，必要时锁 digest。** `nginx:alpine` 这种浮动 tag 会随上游变化，今天能起来不代表半年后重建还能起来。生产上建议写全小版本（`nginx:1.30-alpine`），追求极致稳定可以锁 digest。
3. **升级前先读"移除清单"。** 大版本之间的破坏性变更（被移除的配置变量、被禁用的插件）是升级失败的头号原因，官方文档的 "Changes in..." / "新增、弃用与移除" 章节里列得很全。MySQL 8.0 → 8.4 的具体清单见 7.4。

### 7.3 镜像加速地址的时效性

1.2 节给的几个地址都是第三方社区服务，**可用性会随时间波动**，被限流或停止服务都很常见。照抄前先自测：

```bash
curl -sI --max-time 8 https://docker.m.daocloud.io/v2/ | head -1
```

返回 `200` 或 `401` 都说明可达（`401` 是正常的鉴权挑战）。全部不可用时，优先考虑使用你自己云厂商提供的加速服务。


### 7.4 从 MySQL 8.0 升到 8.4：先删两个参数

8.4 的核心定位是“清理历史债务”：8.0 里标记为 Deprecated 的东西，8.4 直接 Removed。

| 8.0 时代的写法                                               | 在 8.4 的结果                                  | 怎么处理                                                            |
| ------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------- |
| `--default-authentication-plugin=mysql_native_password` | **已移除**，传入即 `unknown variable`，mysqld 启动失败 | 删掉。认证策略改由 `authentication_policy` 控制，默认 `caching_sha2_password` |
| `--explicit_defaults_for_timestamp=1`                   | **已移除**，同样导致启动失败                           | 删掉（8.0 里它本来就默认 ON，写了等于没写）                                       |

两条要**一起**删 —— 只改认证插件那一条，容器依然起不来，而且报错指向的是另一个参数。

**还有一个不可回退的点**：把 `image` 从 8.0 换成 8.4 时，如果沿用同一个数据卷，8.4 会**就地升级数据字典**，而 MySQL 官方不支持从 8.4 降回 8.0。所以动镜像前务必先备份、并验证备份能恢复，最稳的是“导出 → 换新卷 → 导入”。同理，`mysql_native_password` 插件在 8.4 里默认禁用，**不要为了兼容老客户端去打开它** —— 本文的 PHP 走 mysqlnd，原生支持 `caching_sha2_password`，用不上它。

---

## 8. 上线前必须补齐的 8 件事

前面七节讲的都是"让它跑起来"。这一节是"让它能长期跑下去"。**Docker 不等于免运维** —— `ports: 80:80` 是在宿主机上开的口，防火墙和安全组仍然要收敛；操作系统层面的漏洞也不会因为应用容器化就消失。

### 8.1 宿主机防火墙与安全组

```bash
# 先确认 SSH 实际端口，不要想当然认为一定是 22
sudo sshd -T | grep -i '^port'

# 先放行 SSH，再放行 Web —— 顺序错了会把自己锁在外面
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# 最后才启用
sudo ufw enable
sudo ufw status verbose
```

⚠️ 两点容易漏：**顺序必须是"先放行 SSH 再 `ufw enable`"**；**云厂商控制台的"安全组"是另一层防火墙**，同样只放 22 / 80 / 443 —— 两层都要收敛，只改一层等于没改。数据库端口（3306）默认两边都**不要**放行；只有按 4.6 让 DBeaver 等外部工具直连时才临时打开，用完关掉（更稳的做法是 SSH 隧道）。

### 8.2 自动安全更新

```bash
# Debian / Ubuntu
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades

# EL 系
sudo dnf install -y dnf-automatic
sudo systemctl enable --now dnf-automatic.timer
```

Docker 本体和镜像的更新是另一回事：先 `docker compose pull`，再 `docker compose up -d`，手动执行，**别上自动更新** —— 容器镜像的自动升级在生产上风险太大，一次不兼容的升级就是一次事故。

### 8.3 fail2ban（防爆破）

```bash
sudo apt install -y fail2ban          # EL 系：sudo dnf install -y fail2ban
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd      # 看是否已生效
```

公网上的 SSH 每天会被扫几百次，fail2ban 是成本最低的一道门。如果机器上装了面板（宝塔 / 1Panel），顺手把面板端口也纳入防护。

### 8.4 日志限额

1.2 节已经在 `daemon.json` 里设了全局默认，这里补两句：

- **全局设置只对新建容器生效**，已存在的容器要 `up -d` 重建。
- 也可以在 compose 里按服务单独设（本文的 compose 已给每个服务写了一份 `logging` 块，两处叠加时以更细的那层为准）。
- 另一个容易走偏的地方：**不要靠 `docker exec` 进容器 `cat` 日志文件去排查**。官方镜像已经把日志软链到容器 stdout / stderr，走 `docker compose logs` 才是正规路径。

### 8.5 监控与告警

不需要上重型方案，先有最小可用的三项：

1. **站点可用性**：定时请求首页，状态码非 200 就告警。
   ```bash
   # 每分钟探测一次，失败就记一条
   */1 * * * * curl -sf -o /dev/null -m 10 http://127.0.0.1/ || echo "站点异常 $(date)" >> /var/log/site-alert.log
   ```
2. **磁盘与内存水位**：根分区超过 85% 就该处理了 —— 磁盘写满是"网站某天突然全挂"的头号原因，而新手通常先怀疑代码。
3. **证书到期时间**：如果用 HTTPS，这是最常见的"周末事故"。检查命令见 9.4。

外部监控（Uptime Kuma、云厂商的站点监控等）比自建更可靠 —— 机器整个挂掉时，自建的监控也一起挂了，告警根本发不出来。

### 8.6 镜像固定与可复现构建

- `nginx:alpine` → `nginx:1.30-alpine`；有条件就锁 digest。
- 给构建结果命名（本文 compose 里的 `image: lnmp-web-php:8.4`）：`docker images` 里能一眼看出"当前跑的是哪次构建产出的镜像"，回滚时也有明确靶子。
- 构建上下文很大时再加 `.dockerignore`（见 3.5）。

### 8.7 用非 root 与最小权限收口

- 官方镜像本身已经降权运行：**nginx 以 uid 101、php-fpm 以 uid 82（www-data）** 运行 worker，你不需要额外配 `USER`。
- **不要把站点目录整个 `chmod 777`。** 正确做法是"属主给 82"，见 4.1。
- 数据库账号只授它自己那个库的权限，不要给 `ALL PRIVILEGES`。
- 不用的端口一律不 `ports:` 发布 —— 端口不发出去，就是最彻底的防护。

### 8.8 容器加固（可选，务必先验证）

再进一步可以加：

```yaml
security_opt: ["no-new-privileges:true"]
cap_drop: [ALL]
cap_add: [NET_BIND_SERVICE]   # 仅 nginx 需要，用于绑定 80 端口
```

⚠️ **这一项不要直接上生产。** 官方 nginx 镜像的 entrypoint 会以 root 完成初始化（写配置、建目录）后再降权，激进裁剪 capabilities 可能让它直接起不来。**先在一台测试机上单独验证**：三个容器都能正常启动、站点可访问，再考虑挪到业务机。

---

## 9. 启用 HTTPS（对外网站必须）

### 9.1 容器环境里有一个必须绕开的坑

裸机教程通常让你跑 `certbot --nginx`，它会自动读配置、自动写 443 块、自动加跳转。**在容器里这条命令不能用** —— certbot 的 nginx 插件操作的是**宿主机**上的 nginx 配置和 systemd 服务，而你的 nginx 在容器里，它什么都找不到。

容器里的正确做法是：

1. **在宿主机上装 certbot**；
2. 用 **`certonly --webroot`** 模式签发 —— 它只往一个目录里写验证文件，不碰 nginx 配置；
3. **把证书目录只读挂载进 nginx 容器**；
4. **443 块和 80 跳转自己手写**（9.3 节给了直接可用的版本）。

顺带说清为什么不能用 `standalone` 模式：standalone 会自己起一个临时 HTTP 服务占用 80 端口，而你的 80 端口已经被 nginx 容器占了 —— 两者必然冲突。

### 9.2 五个前置条件（缺一个就会失败）

```bash
# ① DNS 已生效 —— 输出的必须是你 VPS 的 IP
dig +short example.com
dig +short www.example.com

# ② 80 和 443 都已放行（80 是证书验证必需，443 是业务必需）
sudo ufw status | grep -E '80|443'
#    云厂商控制台的安全组也要放行，见 8.1

# ③ 站点已在 80 端口正常服务
curl -I http://example.com        # 期望 200
```

④ **`server_name` 已改成真实域名**（见 9.3 的配置）—— ACME 验证请求会带着 Host 头进来，占位名虽然能兜底，但写真实域名才能保证命中正确。

⑤ **主机在中国大陆境内的话，必须先完成 ICP 备案。** 这是个死结：未备案 → 云厂商封 80 / 443 → Let's Encrypt 取不到验证文件 → 证书签不出来。**备案是前置条件，不是"先上线后补"的事**，管理局审核通常要 20 天左右，是整条链上工期最长的一环。

### 9.3 签发证书

```bash
# 宿主机上安装
sudo apt install -y certbot          # EL 系：sudo dnf install -y certbot

# 用 webroot 模式签发。注意 -w 指向宿主机上的网站根目录，
# 它与容器内的 /usr/share/nginx/html 是同一个目录
sudo certbot certonly --webroot -w /home/lnmp-web/html -d example.com -d www.example.com --deploy-hook "docker compose -f /home/lnmp-web/docker-compose.yml exec -T nginx nginx -s reload"
```

证书会落在宿主机 `/etc/letsencrypt/live/example.com/`。**`--deploy-hook` 很重要**：证书续期后，容器里的 nginx 需要重新加载才能读到新文件。

**给容器开两个口子**（改 `docker-compose.yml`）：

```yaml
  nginx:
    ports:
      - "80:80"
      - "443:443"                                    # 新增
    volumes:
      - ./html:/usr/share/nginx/html
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro         # 新增：证书只读挂载
```

**然后用下面两块替换 `nginx/default.conf` 的内容**（与附录 B.1 相同，可直接复制）：

```nginx
# ============ 第 1 块 · 80 端口：放行 ACME 验证 + 跳转到 HTTPS ============
server {
    listen      80;
    listen      [::]:80;
    server_name example.com www.example.com;

    # ★ 这一条不能删。续期请求走 80 端口，被跳转掉就会静默失败
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }

    location / { return 301 https://$host$request_uri; }
}

# ============ 第 2 块 · 443 端口：真正的站点 ============
server {
    listen      443 ssl;
    listen      [::]:443 ssl;
    http2 on;                             # nginx 1.25.1+ 的写法，别再写 listen ... http2

    server_name example.com www.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;

    root  /usr/share/nginx/html;
    index index.php index.html index.htm;

    server_tokens off;
    client_max_body_size 25m;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;

    location / { try_files $uri $uri/ /index.php?$query_string; }

    location ~* ^/uploads/.*\.(php|phtml|phar|php[0-9])$ { deny all; }
    location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
    location ~* \.(bak|sql|log|ini|conf|env)$ { deny all; }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index index.php;
        fastcgi_pass php:9000;
        fastcgi_read_timeout 120s;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public";
        access_log off;
    }

    # HSTS：确认 HTTPS 一切正常后再取消注释。
    # 一旦开启，浏览器会在有效期内强制走 HTTPS，回退非常麻烦。
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
```

改完重载：

```bash
docker exec lnmp-nginx nginx -t        # 语法校验，必须通过
docker compose up -d nginx             # 端口和挂载变了，要重建
```

⚠️ **`listen 443 ssl` 的 server 块里必须同时有 `ssl_certificate` 和 `ssl_certificate_key`**，而且必须在同一个 server 块内（不能放 `http` 块或 `location` 块）。缺了 nginx 会直接起不来：

```
nginx: [emerg] no "ssl_certificate" is defined in server listening on SSL port
```

### 9.4 验证与管理

```bash
# HTTPS 是否通
curl -I https://example.com              # 期望 200

# 80 是否正确跳转
curl -I http://example.com               # 期望 301，Location 指向 https://

# 证书主体与剩余天数
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -subject -dates

# 证书链是否完整（缺中间证书时部分客户端会报错）
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | grep -i verify

# ★ 确认自动续期真的能跑 —— 不做这条，等于把过期风险留到 90 天后
sudo certbot renew --dry-run

# 续期定时任务是否已装好
systemctl list-timers | grep certbot
```

**最容易漏的一项检查**：确认验证路径没有被跳转覆盖。

```bash
curl -I http://example.com/.well-known/acme-challenge/test
# 期望 404（文件不存在是正常的）
# 若返回 301，说明 80 端口被整块重定向了 —— 证书会在 90 天后静默续期失败
```

### 9.5 三个坑

1. **别把 80 端口整块 301 到 443 而忘了放行 `/.well-known/acme-challenge/`。** 后果不是立刻报错，而是 90 天后证书悄悄过期 —— 那时你早已忘了这套配置的存在。9.3 配置里那一行就是为它留的。
2. **证书路径永远指 `/etc/letsencrypt/live/<域名>/`，不要指 `archive/`。** `archive/` 里是带日期的历史版本，续期后不会自动跟随。
3. **HSTS 确认无误再开。** 开了之后浏览器在 `max-age` 有效期内会强制走 HTTPS，即使你后来撤掉证书也回不去（只能换域名或清浏览器缓存）。

---

## 附录 A：完整配置文件（基础版 · 仅 HTTP）

按 2.1 建好目录后，把下面 5 个文件放到位即可开始。

> **启用 HTTPS 时，请用 9.3 节的两块 server（即附录 B.1）替换 A.3 的内容** —— 不要直接照抄 443 块，那时你还没有证书，nginx 会起不来。

### A.1 Dockerfile-php

```dockerfile
FROM php:8.4-fpm-alpine

# pdo_mysql / mysqli 的源码随 PHP 一起发布，编译它们不需要任何额外的 apk 包
RUN docker-php-ext-install pdo_mysql mysqli

# 需要 zip / gd 时再放开下面三行（含各自的编译期依赖，缺一不可）
# RUN apk add --no-cache libzip-dev freetype-dev libjpeg-turbo-dev libpng-dev
# RUN docker-php-ext-configure gd --with-freetype --with-jpeg
# RUN docker-php-ext-install zip gd

# 确认 opcache 是否已启用：docker exec lnmp-php php -m | grep -i opcache
# 若没有输出，取消下一行注释后重新 build
# RUN docker-php-ext-enable opcache
```

### A.2 php/php.ini

```ini
; ---------- 基础 ----------
date.timezone          = Asia/Shanghai
expose_php             = Off

; ---------- 报错：关回显、开日志（两条必须成对出现）----------
display_errors         = Off
display_startup_errors = Off
log_errors             = On
error_log              = /proc/self/fd/2
error_reporting        = E_ALL

; ---------- 上传与执行：必须成严格递增关系 ----------
upload_max_filesize = 20M    ; ① 单个文件上限
post_max_size       = 25M    ; ② 整个 POST 上限，必须 > ①
memory_limit        = 256M   ; ③ 必须 >= ②
max_execution_time  = 120    ; ④ 单个脚本最长执行秒数
max_input_time      = 120    ; ⑤ 接收请求数据的最长时间

; ---------- 会话 ----------
session.cookie_httponly = 1
session.cookie_samesite = Lax
; session.cookie_secure = 1  ; 启用 HTTPS 之后再打开

; ---------- opcache ----------
opcache.enable                = 1
opcache.memory_consumption    = 128
opcache.max_accelerated_files = 10000
opcache.validate_timestamps   = 1
opcache.revalidate_freq       = 60
```


### A.3 nginx/default.conf

```nginx
server {
    listen      80;
    listen      [::]:80;
    server_name _;
    # _ 不是通配符，它不匹配任何 Host。这里能工作，是因为本容器 80 端口下
    # 只有这一个 server 块、且没有块声明 default_server，于是它被隐式当作默认 server。
    # 多站点场景必须写真实域名 / IP，或显式声明 default_server。

    root  /usr/share/nginx/html;
    index index.php index.html index.htm;

    server_tokens off;
    client_max_body_size 25m;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # 以下三条 deny 规则必须排在 \.php$ 之前 —— nginx 正则 location「先匹配者胜」
    location ~* ^/uploads/.*\.(php|phtml|phar|php[0-9])$ { deny all; }
    location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
    location ~* \.(bak|sql|log|ini|conf|env)$ { deny all; }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index index.php;
        fastcgi_pass php:9000;
        fastcgi_read_timeout 120s;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public";
        access_log off;
    }
}
```

### A.4 docker-compose.yml

```yaml
name: lnmp-web
# 顶层 name 显式指定项目名。默认取所在目录名，本项目是 /home/lnmp-web，结果一致 ——
# 已有数据卷 lnmp-web_mysql_data 不会被当成新卷。

services:
  nginx:
    image: nginx:1.30-alpine
    container_name: lnmp-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      # - "443:443"                                          # 启用 HTTPS 后打开
    volumes:
      - ./html:/usr/share/nginx/html
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      # - /etc/letsencrypt:/etc/letsencrypt:ro               # 启用 HTTPS 后打开
    environment:
      TZ: Asia/Shanghai
    depends_on:
      php:
        condition: service_started
    networks: [frontend, backend]
    logging: &log
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    healthcheck:
      test: ["CMD-SHELL", "nginx -t || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  php:
    build:
      context: .
      dockerfile: Dockerfile-php
    image: lnmp-web-php:8.4
    container_name: lnmp-php
    restart: unless-stopped
    volumes:
      - ./html:/usr/share/nginx/html
      - ./php/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    environment:
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
    networks: [backend]
    logging: *log
    healthcheck:
      test: ["CMD-SHELL", "php-fpm -t || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

  mysql:
    image: mysql:8.4
    container_name: lnmp-mysql
    restart: unless-stopped
    ports:
      - "3306:3306"                                        # 供 DBeaver 等外部工具连库（见 4.6）；生产改回 127.0.0.1:3306:3306
    volumes:
      - mysql_data:/var/lib/mysql
    environment:
      TZ: Asia/Shanghai
      MYSQL_ROOT_PASSWORD: "<强口令，替换掉这对尖括号>"
      MYSQL_DATABASE:      lnmp_web
      MYSQL_USER:          web_user
      MYSQL_PASSWORD:      "<强口令，替换掉这对尖括号>"
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_0900_ai_ci
    networks: [backend]
    logging: *log
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s

volumes:
  mysql_data:

networks:
  frontend:
  backend:
```

> `logging: &log` 是 YAML 锚点，php 与 mysql 用 `*log` 复用它。若你的 compose 版本对锚点报错，把这段在三个服务里各写一遍即可。

### A.5 口令写在哪

本版**不建 `.env`**：数据库口令直接写在 A.4 的 `environment` 里，把 `<强口令，替换掉这对尖括号>` 换成 `openssl rand -base64 24` 生成的真口令即可。

改用 `.env` 的写法（含 `.env` 内容、变量写法和 `chmod 600`）见 **3.5**。附录不再单独列出 `.env` 文件。

---

## 附录 B：完整配置文件（HTTPS 版）

与附录 A 相比只差三处，其余文件（`Dockerfile-php`、`php/php.ini`）和口令写法完全一样：

| 差别                          | 从                  | 到                             |
| --------------------------- | ------------------ | ----------------------------- |
| `nginx/default.conf`        | 附录 A.3 的单块 80 端口配置 | 下面 B.1 的两块：80 跳转 + 443 站点     |
| compose 里 nginx 的 `ports`   | 只有 `"80:80"`       | 增加 `"443:443"`                |
| compose 里 nginx 的 `volumes` | html + 站点配置        | 增加证书目录 `/etc/letsencrypt`（只读） |

> **顺序不能反**：必须先在宿主机上用 webroot 模式签出证书（见 9.3），再把下面这块配置放上去。没有证书就写 `listen 443 ssl`，nginx 直接起不来。

### B.1 nginx/default.conf（HTTPS 全量）

```nginx
# ============ 第 1 块 · 80 端口：放行 ACME 验证 + 跳转到 HTTPS ============
server {
    listen      80;
    listen      [::]:80;
    server_name example.com www.example.com;

    # ★ 这一条不能删。续期请求走 80 端口，被整块跳转掉就会静默失败
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }

    location / { return 301 https://$host$request_uri; }
}

# ============ 第 2 块 · 443 端口：真正的站点 ============
server {
    listen      443 ssl;
    listen      [::]:443 ssl;
    http2 on;                          # nginx 1.25.1+ 的写法，别再写 listen ... http2

    server_name example.com www.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;

    root  /usr/share/nginx/html;
    index index.php index.html index.htm;

    server_tokens off;
    client_max_body_size 25m;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;

    location / { try_files $uri $uri/ /index.php?$query_string; }

    location ~* ^/uploads/.*\.(php|phtml|phar|php[0-9])$ { deny all; }
    location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
    location ~* \.(bak|sql|log|ini|conf|env)$ { deny all; }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index index.php;
        fastcgi_pass php:9000;
        fastcgi_read_timeout 120s;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public";
        access_log off;
    }

    # HSTS：确认 HTTPS 一切正常后再取消注释。一旦开启，浏览器会在有效期内强制走 HTTPS，回退非常麻烦
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
```

### B.2 docker-compose.yml 的 nginx 服务（只标出改动的两处）

```yaml
  nginx:
    image: nginx:1.30-alpine
    container_name: lnmp-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"                                     # ← 新增
    volumes:
      - ./html:/usr/share/nginx/html
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro          # ← 新增：证书只读挂载
    environment:
      TZ: Asia/Shanghai
    depends_on:
      php:
        condition: service_started
    networks: [frontend, backend]
```

### B.3 改完的执行顺序

```bash
docker exec lnmp-nginx nginx -t        # 语法校验，必须通过
docker compose up -d nginx             # 端口和挂载都变了，必须重建，不能只 restart
```
