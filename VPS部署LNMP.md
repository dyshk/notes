

| 项目   | 内容                                                                     |
| ---- | ---------------------------------------------------------------------- |
| 适用系统 | Ubuntu / Debian 全系；CentOS / Rocky / AlmaLinux（下称 **EL 系**），跨发行版差异已单独标注 |
| 目标   | 一台刚装好的 VPS，从空系统做到能跑读写数据库的 PHP 网站，并具备对外上线条件                             |
| 通用性  | 全文不绑定域名、IP、PHP 版本、目录名，需要替换的地方一律写成 `<占位符>`                              |
| 适合谁  | 刚接触服务器运维、想知道"每一步为什么这么做"的人                                              |

> **先解释一个贯穿全文的词 —— EL 系。**  
> EL = Enterprise Linux，指 **RHEL（Red Hat Enterprise Linux）以及按它的源码重建的下游发行版：CentOS、Rocky Linux、AlmaLinux、Oracle Linux**。它们的包管理（rpm / dnf / yum）、目录布局、SELinux、firewalld 完全同源，命令基本可互换，所以本文把它们归为一类，统称「EL 系」；文中出现的 **EL7 / EL8 / EL9** 是主版本号，数字越大越新。另一类则是 Ubuntu / Debian 系，用 apt / dpkg。**全文只需分清这两族，其余内容两族通用。**

---

## 先看全局：LNMP 是什么，一次请求怎么走

LNMP = Linux + Nginx + MySQL + PHP，四个组件各司其职：

| 组件      | 角色                          | 类比   |
| ------- | --------------------------- | ---- |
| Nginx   | 监听 80 / 443 端口，接收所有 HTTP 请求 | 前台接待 |
| PHP-FPM | 真正执行 `.php` 代码的进程           | 后厨   |
| MySQL   | 存放数据的数据库                    | 仓库   |

一次请求的完整链路：

```
浏览器
  │ HTTP 请求（如 http://<你的IP>/index.php）
  ▼
Nginx（监听 80 端口）
  ├─ 静态文件（.html/.css/.jpg）→ 自己读磁盘返回，不经过 PHP
  └─ .php → 通过 FastCGI 转发给 PHP-FPM（socket 或 127.0.0.1:9000）
  ▼
PHP 执行代码 ──需要数据时──▶ MySQL（默认只监听 127.0.0.1，仅本机可连）
  ▼
PHP 生成 HTML → Nginx → 浏览器
```

关键认知：**Nginx 不会执行 PHP，它只是个"转发员"。** 所以配置里必须有"`.php` 交给谁"这一段 —— 漏了的后果极其严重，见 4.6。

### 三个"身份"，别搞混

| 身份       | 是谁                                                 | 用在哪          |
| -------- | -------------------------------------------------- | ------------ |
| SSH 登录用户 | 你（root 或普通用户）                                      | 敲命令、传文件      |
| Web 运行用户 | Debian 系是 `www-data`；EL 系默认是 `apache`（可改成 `nginx`） | PHP 读写文件时的身份 |
| MySQL 账号 | 你创建的数据库用户                                          | 网站连数据库时用     |

最常见的坑：用 root 把文件拷进站点目录，属主还是 root，而 PHP 以 `www-data` 身份运行 → 写不了文件 → 表单一提交就失败。解决办法在 6.2。

---

## 1. 准备工作

- 一台 VPS 或虚拟机，能 SSH 登录（FinalShell / Xshell / Termius 均可）
- 记下两个信息：服务器 IP、一个有 sudo 权限的登录用户
- **域名**：对外网站建议必备 —— HTTPS 证书、CDN、搜索引擎收录、同机多站点都依赖域名（详见第 9 节）
- **中国大陆境内主机**：先确认能否完成 ICP 备案（详见 8.8），它是整条链上工期最长的一环

---

## 2. 安装 Nginx + PHP-FPM + MySQL

### 2.1 Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y nginx mysql-server php-fpm php-mysql \
    php-mbstring php-curl php-gd php-xml php-zip php-intl
```

> 为什么多装后面那一串扩展：只装 `php-mysql` 是最常见的省事做法，但真实程序（WordPress / Typecho / ThinkPHP / Laravel）几乎必然用到 `mbstring`（中文处理）、`gd`（缩略图）、`curl`（调外部接口）、`zip`（装扩展包）、`xml`、`intl`。**缺了不会在安装时报错，而是在某个功能被点开时才崩**，排查成本很高。
>
> 装完 MySQL 可用 `sudo mysql_secure_installation` 做一遍基础加固（设 root 密码、删匿名用户、禁远程 root）。

### 2.2 EL 系（CentOS / Rocky / AlmaLinux）

```bash
# EL8 / EL9：MySQL 8.0 就在 AppStream 里，直接装即可
sudo dnf install -y nginx mysql-server php-fpm php-mysqlnd \
    php-mbstring php-curl php-gd php-xml php-zip php-intl
```

几个要点：

- **EL 系的 PHP MySQL 扩展包名是 `php-mysqlnd`**（对应 Debian 系的 `php-mysql`），它自带 `mysqli` 与 `pdo_mysql`，其余扩展包名两族相同。
- **不需要先 `dnf module enable mysql:8.0`**：EL8 / EL9 的 AppStream 默认流就是 MySQL 8.0，`dnf install mysql-server` 直接可用。想装 8.4（自 RHEL 9.6 起提供）才需要指定流：`sudo dnf module install mysql:8.4/server`。查看可用的流用 `sudo dnf module list mysql`。
- **MariaDB 与 MySQL 不能共存**：两者 RPM 包冲突，同一台机器只能装一个。
- **EL7 差异较大**：nginx 在 EPEL 里（先 `sudo yum install -y epel-release`）；数据库默认是 MariaDB，要装 MySQL 需自行添加 MySQL 官方源。
- EL 系 AppStream 版的 MySQL，root 初始无密码，先 `sudo mysql` 进去后用 `ALTER USER 'root'@'localhost' IDENTIFIED BY '<强密码>';` 设置，再跑 `mysql_secure_installation`。

### 2.3 启动并设为开机自启

包管理器装完，这些服务默认已是"开机自启 + 运行中"，下面属于保险动作（幂等，重复执行无害）。唯一要小心的是 **PHP-FPM 的服务名带版本号**，先查真名：

```bash
# 列出所有 php 相关服务单元（含未启动的）
systemctl list-unit-files --type=service | grep php

# 最可靠的依据：socket 文件名本身就带版本号
ls /run/php/        # Debian 系：如 php8.3-fpm.sock
ls /run/php-fpm/    # EL 系：通常是 www.sock
```

> **查服务名要用 `list-unit-files`，不要用 `list-units`。** 后者只列"当前已加载"的 unit —— 服务启动失败时恰恰查不到，而那正是你最需要查名字的场景。

关于 PHP 版本：`apt install php-fpm` / `dnf install php-fpm` **只装发行版锁定的版本**，不是你指定的版本。本文一律写作 `php<版本>-fpm`，请用上面 `ls /run/php/` 的实际结果替换。

| 系统               | 默认源给的 PHP                                                        |
| ---------------- | ---------------------------------------------------------------- |
| Ubuntu 24.04 LTS | 8.3                                                              |
| Ubuntu 22.04 LTS | 8.1                                                              |
| Debian 12        | 8.2                                                              |
| EL9              | 8.0（另提供 8.1 / 8.2 / 8.3 等可选流，用 `dnf module enable php:8.x` 切换）   |
| 想要更新的版本          | Debian 系加 `ondrej/php` PPA，EL 系加 `remi` 源 —— **第三方源有风险，生产需自行评估** |

```bash
# Debian 系（把 php<版本>-fpm 换成上一步查到的真名）
sudo systemctl enable --now nginx mysql php<版本>-fpm

# EL 系（注意服务名：MySQL 是 mysqld，PHP-FPM 是不带版本号的 php-fpm）
sudo systemctl enable --now nginx mysqld php-fpm
```

```bash
# 确认状态：enabled = 会开机自启，active = 正在运行
systemctl is-enabled nginx mysql php<版本>-fpm
systemctl is-active  nginx mysql php<版本>-fpm
```

> - `is-enabled` 返回 `static` 属正常：表示该 unit 没有"安装"段、不能单独 enable，由别的服务依赖拉起。想真正确认能自启，`sudo reboot` 后重新登录再跑一次最快。
> - **EL 系的 MySQL 服务名是 `mysqld`**（不是 `mysql`），`systemctl is-active mysql` 会报 not found。

### 2.4 确认安装结果（必须做，后面配置要用到）

```bash
nginx -v
php -v
systemctl list-unit-files --type=service | grep -E 'nginx|mysql|php'

# 关键：拿到 PHP-FPM 的 socket 真实文件名
ls /run/php/        # Debian 系
ls /run/php-fpm/    # EL 系
```

为什么必须确认：Nginx 配置里要写 `fastcgi_pass unix:/run/php/<这里>;`，**名字写错就是 502 Bad Gateway**。三种常见写法对照：

| 场景              | 典型路径                             |
| --------------- | -------------------------------- |
| Ubuntu / Debian | `unix:/run/php/php<版本>-fpm.sock` |
| EL 系            | `unix:/run/php-fpm/www.sock`     |
| 走 TCP 端口        | `127.0.0.1:9000`                 |

---

## 3. 理解 Nginx 的站点管理机制

核心原则：一台服务器可以放很多网站，每个网站一个配置文件。**不要直接改 Nginx 主配置里的全局参数。**

### 3.1 Debian / Ubuntu：软链接可插拔

```
/etc/nginx/
├─ nginx.conf                ← 主配置，其中一行：include /etc/nginx/sites-enabled/*;
├─ sites-available/          ← 仓库：存放所有站点配置，放这里【不会生效】
│   ├─ default                （系统自带的默认站）
│   └─ <你的站点名>
└─ sites-enabled/            ← 生效区：只放【软链接】，指向 sites-available
    └─ <你的站点名> -> ../sites-available/<你的站点名>
```

主配置 include 的是 `sites-enabled/*`，所以只有在这里出现过的配置才会被加载；而这里放的是软链接 —— **链接在，站点生效；链接删，站点停用，配置文件本体还在**。可以类比成"安装包"与"桌面快捷方式"：删快捷方式不等于删游戏。

| 想干什么         | 命令                                                                               |
| ------------ | -------------------------------------------------------------------------------- |
| 启用站点         | `sudo ln -s /etc/nginx/sites-available/<站点名> /etc/nginx/sites-enabled/`          |
| 停用站点（不删配置文件） | `sudo unlink /etc/nginx/sites-enabled/<站点名>`                                     |
| 查看当前启用了哪些站点  | `ls -l /etc/nginx/sites-enabled/`                                                |
| 恢复系统默认站      | `sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default` |
| 改完配置必做       | `sudo nginx -t && sudo systemctl reload nginx`                                   |

> `unlink` 和 `rm` 在这里效果一样：都只删链接，不碰 `sites-available` 里的源文件。

### 3.2 两个必须分清的层次

- **软链接**控制"整套站点配置要不要加载"（决定用哪些 server 块）；
- **`root` 指令**（写在站点配置里）控制"这个站点去哪个目录读网页文件"。

改网页内容 = 改 `root` 指向的目录里的文件；改站点开关 = 增删软链接。两者互不相干。

### 3.3 两个发行版族的区别

**server 块的内容在两族上是同一份**，第 4 节的配置逐字相同都能用；差别只在"文件放哪、怎么启用、默认站在哪"。

| 差别             | Debian / Ubuntu                          | EL 系                                                 |
| -------------- | ---------------------------------------- | ---------------------------------------------------- |
| 站点配置放哪         | `/etc/nginx/sites-available/<名字>`，无扩展名要求 | `/etc/nginx/conf.d/<名字>.conf`，**必须以 `.conf` 结尾**才被加载 |
| 怎么启用           | 软链接到 `sites-enabled/`                    | 无需软链接，放进去 reload 即生效                                 |
| 怎么停用           | 删软链接                                     | 文件改名或移走（如加 `.bak` 后缀）                                |
| 系统自带默认站        | `sites-enabled/default`（软链接）             | 见下方说明                                                |
| PHP-FPM socket | `/run/php/php<版本>-fpm.sock`              | `/run/php-fpm/www.sock`                              |
| fastcgi 参数片段   | 有 `snippets/fastcgi-php.conf`            | 没有 `snippets/`，用 `include fastcgi_params`（两族都自带）     |

**EL 系的默认站在哪？** 它**不是**一个可以删的文件，而是**内联写在 `/etc/nginx/nginx.conf` 里**的一个 server 块，`conf.d/` 目录通常是空的甚至不存在。该块形如：

```nginx
server {
    listen       80 default_server;
    listen       [::]:80 default_server;
    server_name  _;
    root         /usr/share/nginx/html;
    include      /etc/nginx/default.d/*.conf;
    location / { }
}
```

它带 `default_server`，是所有未命中请求的兜底。于是 EL 系会出现一个 Debian 上不会有的怪现象：**站点配置看着完全正确、`nginx -t` 也通过，访问却看到 nginx 欢迎页** —— 请求被这个内联块接走了。定位与停用方法见 4.5。

**EL 系建站点就两步**（不需要另抄一份配置，第 4 节的配置本身跨发行版）：

```bash
sudo vim /etc/nginx/conf.d/<你的站点>.conf     # 粘贴第 4 节的配置
sudo nginx -t && sudo systemctl reload nginx
```

> **EL 系还有一个独有坑：PHP-FPM 默认以 `apache` 用户运行，不是 `nginx`。** 所以第 6.2 节的改属主，EL 系要么 `chown` 给 `apache:apache`，要么把 `/etc/php-fpm.d/www.conf` 里的 `user` / `group` 改成 `nginx` 后重启 php-fpm —— 二选一，保持一致即可。

> **SELinux（EL 系默认开启）**：它可能在"权限看起来都对"的情况下拒绝 PHP 写文件，页面报 permission denied。诊断与放行：
>
> ```bash
> sudo ausearch -m avc -ts recent                       # 看有没有 AVC 拒绝记录，确认病因
> sudo setsebool -P httpd_can_network_connect on        # 需要 PHP 连外部网络/数据库时
> sudo semanage fcontext -a -t httpd_sys_content_t "/var/www/<你的站点目录>(/.*)?"
> sudo restorecon -Rv /var/www/<你的站点目录>            # 站点目录不在标准路径时修正上下文
> ```
>
> `sudo setenforce 0` 只能用来**诊断**是不是它导致的，**不是解决方案** —— 长期应改为上面这种放行，而不是关掉它。

---

## 4. 写站点配置：改 3 处即可用

本节给出的是**只监听 80 端口**的基础版，先把 HTTP 跑通。等第 9 节启用 HTTPS 时，直接换成**附录 A 的完整模板**（HTTP + HTTPS 一体），两者结构一致，改动只是多一个 443 块。

### 4.1 基础配置

创建配置文件：Debian 系放 `sites-available`；EL 系直接建 `/etc/nginx/conf.d/<名字>.conf`。

```bash
sudo vim /etc/nginx/sites-available/<站点名>
# 按 i 进入插入模式，粘贴下面内容，改完 3 处后 Esc → :wq 保存
```

```nginx
server {
    listen 80;
    listen [::]:80;

    # 【改这里 1】填你的域名或服务器 IP
    server_name <域名或IP>;

    # 【改这里 2】网站文件所在目录的绝对路径
    root /var/www/<你的站点目录>;
    index index.php index.html;

    server_tokens off;              # 隐藏 nginx 版本号
    client_max_body_size 10m;       # 上传上限，默认只有 1 MB

    location / {
        # 有真实文件就直接返回；都没有就落到入口 PHP
        try_files $uri $uri/ /index.php?$query_string;
    }

    # 拒绝访问隐藏文件：.env、.git、.svn 等
    # ★ 必须放行 .well-known，否则第 9 节的证书签发与续期会失败
    location ~ /\.(?!well-known) {
        deny all;
        access_log off;
        log_not_found off;
    }

    # 上传目录只当静态资源：就算有人传上来 .php 也一律不许执行
    location ~* ^/uploads/.*\.(php|phtml|phar|php[0-9])$ {
        deny all;
    }

    location ~ \.php$ {
        try_files $uri =404;        # 脚本必须真实存在
        include fastcgi_params;     # 发行版自带，比 snippets/ 更通用
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index index.php;

        # 大响应体 / 慢脚本：默认 60 秒，备份、导入、图片处理常超时
        fastcgi_read_timeout   300s;
        fastcgi_buffers        16 32k;
        fastcgi_buffer_size    64k;
        fastcgi_busy_buffers_size 64k;

        # 【改这里 3】PHP-FPM 的监听地址（先 ls /run/php/ 看清真实文件名）
        fastcgi_pass unix:/run/php/php<版本>-fpm.sock;    # Debian 系
        # fastcgi_pass unix:/run/php-fpm/www.sock;        # EL 系
        # fastcgi_pass 127.0.0.1:9000;                    # 走 TCP 时
    }
}
```


### 4.2 逐行解释

| 配置段                                        | 作用                                                | 不写的后果                                               |
| ------------------------------------------ | ------------------------------------------------- | --------------------------------------------------- |
| `listen 80; listen [::]:80;`               | 监听 80 端口（IPv4 + IPv6）                             | 只写 IPv4 时，走 IPv6 的请求命中不到你的站点                        |
| `server_name`                              | 声明这个站点接待哪些请求。写真实域名/IP 才会被精确命中；`_` 只是占位符，本身不匹配任何东西 | 请求落到别的站点上（见 4.5）                                    |
| `root`                                     | 网站文件根目录                                           | 404 Not Found                                       |
| `index`                                    | 访问目录时默认找哪个文件                                      | 访问根路径显示目录列表或 403                                    |
| `server_tokens off`                        | 响应头与错误页不再暴露 nginx 版本号                             | 版本号外泄，便于攻击者按版本找已知漏洞                                 |
| `try_files $uri $uri/ /index.php?...`      | 静态文件优先，找不到交给 PHP 入口                               | 伪静态链接全部 404                                         |
| `location ~ /\.(?!well-known)`             | 拒绝所有隐藏文件                                          | `.env`（数据库口令）、`.git/config`（可拉走整份源码）被匿名下载           |
| `location ~* ^/uploads/...`                | 上传目录禁止执行脚本                                        | 别人上传一个 .php 就能在服务器上执行代码（高危）                         |
| `client_max_body_size`                     | 请求体上限。只解决 Nginx 这一关                               | 稍大的图片上传直接 413                                       |
| `fastcgi_read_timeout` / `fastcgi_buffers` | 允许长耗时脚本、容纳大响应体                                    | 备份/导入类页面 504；响应头过大时报 `upstream sent too big header` |
| `location ~ \.php$` + `fastcgi_pass`       | 把 .php 交给 PHP-FPM，socket 名必须按实际版本填                | 见 4.6，这是全文最严重的一条                                    |
| `try_files $uri =404`（PHP 段内）              | 只执行存在的脚本                                          | 可被构造路径探测                                            |

> 表中 `try_files ... /index.php?$query_string` 就是常说的"伪静态"入口，它把 `/article/3` 这类网址在服务器层翻译给程序处理。只有你的程序确实存在这类页面时才有意义，本教程不展开。

### 4.3 上传大小要过四道关

这四道关的**数值必须递增**，不能都填同一个数：

| 门槛         | 在哪改                                              | 作用            | 没改的症状                                                    |
| ---------- | ------------------------------------------------ | ------------- | -------------------------------------------------------- |
| ① Nginx    | 站点配置 `client_max_body_size 10m;`                 | 限制整个 HTTP 请求体 | `413 Request Entity Too Large`                           |
| ② PHP 表单上限 | `php.ini` 的 `post_max_size = 10M`                | 限制整个 POST 数据  | 表单提交后**空白页、没有任何报错**（PHP 静默丢弃整个 POST）                     |
| ③ PHP 文件上限 | `php.ini` 的 `upload_max_filesize = 8M`           | 单个上传文件大小      | `$_FILES` 里文件报错"文件太大"                                    |
| ④ PHP 执行时间 | `php.ini` 的 `max_execution_time = 300`（默认仅 30 秒） | 单个脚本最长执行时间    | 大文件上传 / 图片处理跑到一半 502 或 `Maximum execution time exceeded` |

> **为什么不能都填 8M**：POST 里除了文件还有表单字段和 multipart 边界，所以"看起来没超 8M"的文件会先撞上 `post_max_size`，PHP 直接丢弃整个请求**且不报错**。正确的数值关系：
>
> ```
> upload_max_filesize = 8M     # 单个文件
> post_max_size       = 10M    # 整个 POST，必须 > upload_max_filesize
> memory_limit        = 128M   # 必须 >= post_max_size
> max_execution_time  = 300    # 秒
> client_max_body_size 10m;    # Nginx 侧，必须 >= post_max_size
> ```

②③④ 改完**必须重启 PHP-FPM** 才生效：

```bash
# 找到 php.ini 位置（不同系统路径不同，这条最准）
php -i | grep "Loaded Configuration File"

sudo systemctl restart php<版本>-fpm
```

> 也有人用站点配置里的 `fastcgi_param PHP_VALUE "..."` 临时覆盖，不必改 php.ini。**不推荐**：一是多值必须用 `\n` 转义、部分 SAPI 下不生效；二是超限后 `$_POST` / `$_FILES` 被静默清空，用这种方式出问题比改 php.ini 更难定位。

### 4.4 启用并生效

```bash
# Debian 系：建软链接启用（EL 系略过，文件放进 conf.d/ 即生效）
sudo ln -s /etc/nginx/sites-available/<站点名> /etc/nginx/sites-enabled/

# 校验语法 —— 上线前必做，养成习惯
sudo nginx -t

# 重载生效（reload 不断连接，比 restart 温和）
sudo systemctl reload nginx
```

> 建软链接若提示 `File exists`，说明之前建过了，跳过即可。

### 4.5 让 IP / 域名直接进你的站点

先解释一个高频困惑：照模板写完，为什么用浏览器访问 IP 会跑到别的站点去？

**nginx 选 server 块分两步：**

1. 按 `server_name` 精确匹配请求头里的 `Host`（访问 `192.168.124.9`，`Host` 就是这个 IP）；
2. 没有任何站点精确命中时，交给该端口的 `default_server` 兜底。

而 `_` **不是通配符**，它就是一个"不会命中任何请求"的占位名 —— 写了它，你的站点永远走不到第 1 步。这时如果机器上还留着系统自带的默认站，IP 访问就全被它接走。

> **接走之后你看到什么，取决于默认站的文件：**
>
> - Debian / Ubuntu：默认站根目录 `/var/www/html` 且装了 `index.nginx-debian.html`，会看到 **"Welcome to nginx!"（HTTP 200）**；
> - EL 系：根目录 `/usr/share/nginx/html`，同样是欢迎页。
>
> 只有当默认站根目录里确实没有可用索引文件（被清空），或目录不可读时，才会出现 **403 Forbidden**。nginx 内置错误页的页脚会带版本号 —— 这也是判断"请求没到你的站点"的线索。

**结论：用 IP 或域名访问，就把真实的 IP/域名填进 `server_name`，精确匹配优先级最高，必中你的站点。**

如果还想让"任意乱七八糟的 Host"也落到自己站点，按发行版选一种：

**方式一：停用系统默认站**

```bash
# Debian / Ubuntu
sudo unlink /etc/nginx/sites-enabled/default

# EL 系：默认站内联在 nginx.conf 里，没有 conf.d/default.conf 可删
sudo vim /etc/nginx/nginx.conf
# 找到 listen 80 default_server; 的那个 server 块，整块删除
# 或只去掉两行 listen 后面的 default_server 参数

sudo nginx -t && sudo systemctl reload nginx
```

**方式二：把兜底权交给你的站点（推荐，两边配置都保留）**

先在系统默认站里去掉 `default_server`（Debian 系改 `sites-available/default`，EL 系改 `nginx.conf`）：

```nginx
listen 80 default_server;      # 改成 listen 80;
listen [::]:80 default_server; # 改成 listen [::]:80;
```

再给你的站点加上（**全系统只能有一个 `default_server`**）：

```nginx
listen 80 default_server;
listen [::]:80 default_server;
```

这样 `server_name _;` 才真正变成"兜底" —— 因为**兜底身份是靠 `default_server` 给的，不是靠 `_` 这个名字**。保存后 `nginx -t && systemctl reload nginx`。

> 自查：`curl -I http://<你的IP>/` 看响应是否来自你的站点；拿不准请求落到哪个 server 块时，最快的办法是用 `nginx -T` 打印完整配置后过滤 `default_server`。

### 4.6 最容易致命的一条：location ~ .php$

这段的作用是**拦截所有以 `.php` 结尾的请求，交给 PHP-FPM 进程解析执行**。漏了它的后果不是"页面打不开"，而是：

`.php` 文件会被 Nginx 当成普通静态文件返回 —— 由于 MIME 表里没有 `.php`，浏览器会**以 `application/octet-stream` 直接下载**它。于是任何人访问 `http://<你的IP>/config.php`，就能把里面的数据库账号密码、网站管理密码原文下载走。

**配好之后立刻自测**（第 9 节启用 HTTPS 后同样适用）：

```bash
curl -I http://<你的IP>/index.php    # 期望 HTTP/1.1 200，且 Content-Type 是 text/html
# 若返回 application/octet-stream 或直接下载文件，说明这段没生效
```

---

## 5. 数据库：建库 + 建专用账号

### 5.1 网站不要用 root 连数据库

只给网站一个"够用就好"的专用账号：能读写它自己那个库，不碰别的库、不碰系统库。

登录 MySQL（Debian 系的 MySQL 8 与 EL 系 AppStream 版默认 root 走 socket 免密，直接 `sudo mysql` 即可）：

```bash
sudo mysql
```

执行下面 SQL（把 `<库名>`、`<账号>`、`<强密码>` 换成你自己的）：

```sql
-- 1) 建库（字符集一定要 utf8mb4，否则中文、emoji 都可能存不进去）
CREATE DATABASE IF NOT EXISTS `<库名>` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- 2) 建专用账号 —— 建这一条就够了
-- `%` 表示允许从任意来源连接：网页（TCP）、命令行（socket）、远程 GUI 都能用
CREATE USER IF NOT EXISTS '<账号>'@'%' IDENTIFIED BY '<强密码>';

-- 3) 只授权这个库
GRANT ALL ON `<库名>`.* TO '<账号>'@'%';

-- 4) 立即生效
FLUSH PRIVILEGES;
EXIT;
```

验证：

```sql
SELECT user, host, plugin FROM mysql.user WHERE user='<账号>';
```

应该只看到一条记录（host 为 `%`）。

> **想更严格：把两处 `'%'` 换成 `'127.0.0.1'`**（只允许本机 TCP 连接）。
>
> 本文用 `'%'`，因为它一条账号同时覆盖"网页 + 命令行 + 远程 GUI"，且不受反向解析环境影响；它安全的前提是**你必须保证 3306 端口不对外**（MySQL 默认 `bind-address = 127.0.0.1`，加上 8.1 节的防火墙规则）。换成 `'127.0.0.1'` 会更紧一档，代价是命令行要用 `mysql -h127.0.0.1 -u<账号> -p`。两种写法的逐场景差异见 5.2。

### 5.2 为什么一条账号就够：账号 = 用户名 + 来源主机

MySQL 里 **账号是「用户名 + 来源主机」的组合**，这是理解后面所有 1045 报错的钥匙：

- `'<账号>'@'localhost'` → 匹配走本机 socket 的连接（命令行 `mysql -u<账号> -p` 默认走这条）
- `'<账号>'@'127.0.0.1'` → 匹配走 TCP 的连接（网页里连 127.0.0.1 走这条）
- `'<账号>'@'%'` → 匹配任意来源（socket、TCP、远程都算）

所以 5.1 只建一条 `'%'` 就全都能连 —— 它是上面两种情况的超集。

**当多条账号都"能匹配"这次连接时，MySQL 按以下优先级取第一条命中的，取到就停**（不是取最精确的，也不是取最宽松的）：

**① 具体 IP 地址 → ② 主机名 → ③ 通配符 `%`**

也就是说，如果同时存在 `'app'@'127.0.0.1'` 和 `'app'@'%'`，从 127.0.0.1 过来的连接会命中**前者**，即使你刚改的是 `%` 那条的密码。这就是"改了密码还是 1045"的真正原因 —— 改的那条根本不是被命中的那条。

排查时用这条命令看清本次连接实际命中的账号：

```sql
SELECT USER(), CURRENT_USER();
-- USER()         = 你尝试连接的账号（如 app@127.0.0.1）
-- CURRENT_USER() = 实际认证成功的账号（如 app@localhost）
-- 两者不同，就说明被别的账号接管了
```

三种 host 写法的实际行为差别很大：

| 场景                                       | `'%'` 账号 | `'127.0.0.1'` 账号          | `'localhost'` 账号                                 |
| ---------------------------------------- | -------- | ------------------------- | ------------------------------------------------ |
| 网站连库（主机填 `127.0.0.1`，走 TCP）              | 正常       | 正常                        | 看环境：默认配置正常；开启 `skip-name-resolve` 的服务器失败（报 1130） |
| 网站连库（主机填 `localhost`，走 socket）           | 正常       | 1045 Access denied        | 正常                                               |
| 服务器上 `mysql -u<账号> -p`（不加 `-h`，走 socket） | 正常       | 1045 Access denied        | 正常                                               |
| 服务器上加 `-h127.0.0.1`（走 TCP）               | 正常       | 正常                        | 同第一行（看环境）                                        |
| 自己电脑上用 DBeaver 远程连                       | 正常       | 连不上（127.0.0.1 只代表"服务器本机"） | 连不上（同理）                                          |

> 关键点：`mysql -u<账号> -p` 不带 `-h` 时走本机 socket，服务器眼里来源是 `localhost`，而 `'127.0.0.1'` 这条账号匹配不到 `localhost`，所以必然 1045 —— **不是密码错，是"来源主机"对不上**。  
> 另外 `-h` 必须带值，不能只写一个字母：`-h` 后面若直接跟别的参数，会被当成主机名（实测报 `Unknown MySQL server host '-u<账号>'`）。

**两个报错号的区分（排查时很有用）：**

- **1045 Access denied** = 找到了账号记录，但密码或来源主机不符；
- **1130 Host ... is not allowed** = 服务器直接拒绝这个来源，一条账号都没匹配上。

为什么 `'localhost'` 标的是"看环境"？MySQL 默认会把 TCP 来源 `127.0.0.1` 反向解析成 `localhost`，此时 `'localhost'` 也能覆盖 TCP；但服务器开启 `skip-name-resolve` 后不做解析，它就完全覆盖不到 TCP（实测连 root 都被 1130 拒绝）。同一份账号密码，换台机器或换个配置就登不上 —— 这就是它不可靠的地方。

### 5.3 utf8mb4 要三处一致

中文乱码 / 插入失败的常见原因是字符集不统一，**库、表、连接三处都要是 utf8mb4**：

| 位置 | 怎么保证                                                                    |
| -- | ----------------------------------------------------------------------- |
| 库  | `CREATE DATABASE ... DEFAULT CHARACTER SET utf8mb4`                     |
| 表  | 建表语句里带 `DEFAULT CHARSET=utf8mb4`                                        |
| 连接 | PHP 连上后立即 `SET NAMES utf8mb4`（mysqli），或在 DSN 里写 `;charset=utf8mb4`（PDO） |

第三处最容易被忘，表现是"英文能存，中文报 `Incorrect string value`"。

---

## 6. 部署网站代码与目录权限

### 6.1 把代码放到站点目录

推荐直接用 FinalShell 左侧的文件面板把整个目录拖到 `/var/www/` 下。

> `.env`、`config.php` 这类含口令的文件，已被 4.1 节的隐藏文件防护挡在外部访问之外；但仍建议**尽量放在 `root` 目录之外**，双保险。

### 6.2 改属主（跳过必踩坑）

PHP 干活时的身份不是你，而是 Web 运行用户。不改属主，会出现"页面能打开、一提交就报错"的典型症状。

```bash
# Debian / Ubuntu
sudo chown -R www-data:www-data /var/www/<你的站点目录>

# EL 系（PHP-FPM 默认以 apache 身份运行）
sudo chown -R apache:apache /var/www/<你的站点目录>
```


> **权限要不要另外改？基本不用。** 关键在属主：属主改对之后，运行用户对文件有读权限、对目录有"进入"权限，站点就能正常工作，保持上传时的默认值（目录 755、文件 644）即可。只有权限被改乱时才需要归一化（目录丢了"执行位"会直接 403）：
>
> ```bash
> sudo find /var/www/<你的站点目录> -type d -exec chmod 755 {} \;
> sudo find /var/www/<你的站点目录> -type f -exec chmod 644 {} \;
> ```
>
> ⚠️ **不要用 `chmod -R 777`。** 那等于让同一台机器上的任何进程都能改你的网站代码，是提权跳板。

**`www-data` 到底是什么？**

- **不是文件、不是目录，是你从没创建过的东西。** 它是一个系统账号（用户名就叫 `www-data`，同名用户组也在）。`chown 属主:属组 路径` 就是把这个路径的属主和属组都改成它。
- **它是装软件时自动建的。** 在 Debian/Ubuntu 上用 apt 装 nginx / apache2 / php-fpm 时，包管理器会自动创建这个"专供 Web 服务使用的低权限账号"（UID 通常是 33），它没有登录密码、不能登录系统。
- **为什么必须改成它。** PHP-FPM 进程以 `www-data` 身份运行 —— 它要写 `config.php`、要往 `uploads/` 存图片，文件属主不是它就会被拒（表现就是"页面能开、一提交就报写入失败"）。反过来，正因为它是低权限账号，即使网站被攻破，攻击者也拿不到 root 权限。
- **怎么确认它在工作：**

```bash
id www-data                                  # 存在则输出 uid/gid
grep www-data /etc/passwd /etc/group         # 看账号与组
ps -o user,cmd -C php-fpm<版本>              # 看 PHP-FPM 进程实际以哪个用户运行
```

- 如果 `id www-data` 报"不存在"，说明这套环境不是用发行版包管理器装的（比如自己编译的），把用户名换成 `nginx` 或你在 fpm 配置里指定的运行用户即可 —— **原则只有一个：与 PHP-FPM 实际运行的身份保持一致**。

> 顺手区分三个容易混的名字：`root` 是你 SSH 登录用的超级用户；`ubuntu` / 你的用户名是普通登录用户；`www-data` 是 Web 服务专用账号，你平时根本不"登录"它，只在 chown 时用到它。

---

## 7. 补充知识：su、root 登录、远程连 MySQL

### 7.1 `su root` 和 `su - root` 的区别

| 命令          | 切换身份 | 是否切换目录      | 是否加载目标用户环境变量 | 推荐  |
| ----------- | ---- | ----------- | ------------ | --- |
| `su root`   | 是    | 否，目录不变      | 否            | 不推荐 |
| `su - root` | 是    | 是，进 `/root` | 是，完整加载       | 推荐  |

- `-` 等价于 `--login`，即"完整登录"。不带 `-` 时环境变量还是旧用户的，执行脚本、编译时容易找不到命令或路径错乱。**日常一律用 `su - <用户名>`。**
- `su - root` 可以简写成 `su -`；它与 `sudo -i` 效果类似，区别是 `sudo -i` 输当前用户密码，`su - root` 输 root 密码。

### 7.2 开启 root 直接 SSH 登录

> ⚠️ **反面教材 · 仅限虚拟机 / 学习环境 · 切勿用于生产。**  
> 生产服务器的正确姿势是：禁用密码登录、改用密钥、禁止 root 直连、用普通用户 + sudo。本节命令会显著降低服务器安全性。

```bash
# ① 设置 root 密码
sudo passwd root

# ② 允许 root 密码登录
sudo vim /etc/ssh/sshd_config
# 找到并改成 / 添加：PermitRootLogin yes
# 同时确认：PasswordAuthentication yes
# 如果sshd_config里包含Include /etc/ssh/sshd_config.d/*.conf，需要确保sshd_config.d文件夹下的*.conf中PasswordAuthentication yes
# ③ ★ 先校验配置语法，再重载 —— 配置写错又直接 restart 会让你再也登不上
sudo sshd -t

# Debian / Ubuntu：服务名是 ssh
sudo systemctl reload ssh

# EL 系：服务名是 sshd（带 d）—— 写成 ssh 会报 Unit ssh.service not found
sudo systemctl reload sshd
```

> 改 sshd 配置后一律"**先 `sshd -t` 校验、再 reload**"。直接用 `restart`，一旦配置有误就会断开你当前连接且无法重连。

### 7.3 用 DBeaver 等工具远程连 MySQL

**首选方案：SSH 隧道 —— 不开端口、不改配置、暴露面为零。**

```bash
# 在你自己的电脑上执行（不是服务器上）
ssh -L 3306:127.0.0.1:3306 <登录用户>@<服务器IP>
然后把 DBeaver 连到 **`127.0.0.1:3306`**（本机）即可。这条隧道的含义是"把服务器的 3306 映射到你本机的 3306"。
```

```bash
# 方式2
直接进入DBeaver 切到 「SSH」标签页：勾选"使用 SSH 隧道"，填服务器 IP 、用户 root、密码（或选密钥文件）
回到「主要」标签页：Host 填 127.0.0.1（注意是服务器本机视角）、端口 3306、用户、密码
```

好处：**不用放开 3306、不用改 `bind-address`、不用在防火墙开口子**，而且可以用 `'127.0.0.1'` 这种最紧的账号。**生产环境推荐这种做法。**

下面这套"直接暴露 3306"的方案**仅限内网 / 学习环境**，四件事缺一不可：

#### ① 账号必须允许"远程来源"

若 5.1 已建过 `'%'` 的账号，这一步可跳过。

```sql
CREATE USER IF NOT EXISTS '<账号>'@'%' IDENTIFIED BY '<强密码>';
GRANT ALL ON `<库名>`.* TO '<账号>'@'%';
FLUSH PRIVILEGES;
```

反之，如果账号只建了 `'127.0.0.1'` 或 `'localhost'`，远程工具一定连不上（这两个只代表"服务器本机"），报 1045。三种 host 的完整对比见 5.2。

#### ② MySQL 监听地址放开（生产强烈不建议）

```bash
sudo vim /etc/mysql/mysql.conf.d/mysqld.cnf
# 找到 bind-address = 127.0.0.1，改成 bind-address = 0.0.0.0
sudo systemctl restart mysql
ss -lntp | grep 3306                      # 正常应看到 0.0.0.0:3306
```

> EL 系的配置文件是 `/etc/my.cnf` 或 `/etc/my.cnf.d/mysql-server.cnf`。  
> `127.0.0.1` = 只有本机能连；`0.0.0.0` = 所有网卡都能连。  
> **生产环境不要把 3306 暴露到公网** —— 数据库端口是自动化扫描的重灾区。生产做法是只监听回环，需要远程就用 SSH 隧道。

#### ③ 防火墙放行 3306（必须限定来源）

```bash
# Debian / Ubuntu：只允许你的固定公网 IP
sudo ufw allow from <你的固定公网IP> to any port 3306 proto tcp

# EL 系：用 rich rule 限定来源
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<你的固定IP>/32" port port="3306" protocol="tcp" accept'
sudo firewall-cmd --reload
```

> 千万不要写成不限来源的 `ufw allow 3306` —— 那等于把数据库交给全网扫描器。  
> 如果你的宽带 IP 是动态的，这条规则会失效 —— 这本身就是一个信号：**这种场景就该用 SSH 隧道，而不是开端口。**

#### ④ DBeaver 连接参数

主机填服务器 IP、端口 3306、库名、账号、密码。MySQL 8 建议在 URL 末尾追加：

```
?allowPublicKeyRetrieval=true&useSSL=false
```

完整 JDBC URL 形如：

```
jdbc:mysql://<服务器IP>:3306/<库名>?allowPublicKeyRetrieval=true&useSSL=false
```

- `allowPublicKeyRetrieval=true`：允许驱动向服务器索取 RSA 公钥来加密密码，解决 `Public Key Retrieval is not allowed`。
- `useSSL=false`：**仅限纯内网**。跨公网连接必须改成 `useSSL=true&requireSSL=true`（MySQL 8 默认支持 TLS），否则账号口令在链路上可被截取。**最稳的仍是走 SSH 隧道。**

另外，如果账号只授权了业务库，DBeaver 里展开"用户"等系统菜单会报权限错误 —— 这是正常的，不影响业务库操作。

#### 附：老版本 PHP / 老驱动认不出 MySQL 8 的认证插件

MySQL 8 默认使用 `caching_sha2_password` 插件。PHP 7.4 以下（及部分旧驱动）不认识它，会报 `authentication method unknown`。解决办法是把该账号的认证插件改回旧插件：

```sql
-- 只想换插件、保留原授权，用 ALTER 最省事
ALTER USER '<账号>'@'%' IDENTIFIED WITH mysql_native_password BY '<新密码>';
```

> 认证插件是**按账号存的属性**（`mysql.user` 表的 `plugin` 列），它决定"用哪套算法验密码"。连接时服务器先告诉客户端"这个账号要求用哪个插件"，客户端必须自己实现了它才能应答 —— 老驱动只实现了 `mysql_native_password`，所以改它就能连上。账号、密码、授权都不变，也不影响其他账号。`BY '<强密码>'` 只是输入方式，服务器内部存的仍是哈希，不是明文。
>
> 若账号不存在、需要重建，则要记得 `DROP` 会连授权一起删掉，后面必须重新 `GRANT`：
>
> ```sql
> DROP USER IF EXISTS '<账号>'@'%';
> CREATE USER '<账号>'@'%' IDENTIFIED WITH mysql_native_password BY '<强密码>';
> GRANT ALL ON `<库名>`.* TO '<账号>'@'%';
> FLUSH PRIVILEGES;
> ```

> **这是临时手段，不是长期方案。** 该插件用的 SHA-1 算法偏弱，MySQL 8.0.34 起弃用、8.4 起默认禁用（需启动加 `--mysql_native_password=ON`）、9.0 起移除。**正解是升级 PHP**（7.4+ 自带 `caching_sha2_password` 支持）；驱动够新之后，也可以不换插件，改用 RSA 公钥交换（即上面 DBeaver 的 `allowPublicKeyRetrieval=true`）或走 TLS。

---

## 8. 生产化：上线前必须补齐的 8 件事

做完第 0～6 节，你得到的是一个"能跑通"的站点；做完这一节，它才**具备上线资格**。

建议顺序：8.1 → 8.7 → 8.5 先做，其余可稍后补，但**上线前一条都不能少**。

### 8.1 防火墙基线

> ⚠️ **顺序至关重要：先放行 SSH，再启用防火墙。** 反过来会把自己锁在服务器外面。

```bash
# 先确认 SSH 实际端口（不要想当然认为一定是 22）
sudo sshd -T | grep -i '^port'
```

**Debian / Ubuntu（ufw）**

```bash
sudo ufw allow <SSH端口>/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable                 # 最后才启用
sudo ufw status verbose
```

**EL 系（firewalld）**

```bash
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

> **云厂商控制台的"安全组"是另一层防火墙**，同样只放行 22 / 80 / 443。两层都要收敛 —— 只改系统防火墙而忘了安全组，等于没做。

### 8.2 自动安全更新

漏洞修补要靠自动更新，爆破防护要靠 fail2ban（8.3）。"生产别用 root 直连 SSH"属于自律，不是机制。

```bash
# Debian / Ubuntu
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades         # 选择自动安装安全更新
sudo unattended-upgrade --dry-run -d 2>&1 | tail -20    # 验证
```

```bash
# EL 系
sudo dnf install -y dnf-automatic
sudo systemctl enable --now dnf-automatic.timer
sudo systemctl list-timers dnf-automatic.timer
```

### 8.3 fail2ban（防爆破）

SSH 和面板端口是自动化爆破的首要目标。fail2ban 按失败次数自动封 IP，是成本最低的一道防线。

```bash
sudo apt install -y fail2ban          # Debian / Ubuntu
sudo dnf install -y fail2ban          # EL 系（EL9 需 EPEL）
sudo systemctl enable --now fail2ban
```

默认会保护 SSH。装了服务器面板（宝塔 / 1Panel）的还要为面板端口单独加规则 —— 面板被爆破等于整台机器失守。

### 8.4 日志轮转

nginx / php-fpm / MySQL 的日志会持续增长。**日志撑爆磁盘是"网站某天突然挂掉"的头号原因**，而新手往往先去怀疑代码。

```bash
ls /etc/logrotate.d/                              # 看系统现有的轮转配置
sudo logrotate -d /etc/logrotate.d/nginx          # -d 是 dry-run，验证配置是否有效
```

若日志目录不在默认位置，补一个 `/etc/logrotate.d/<站点名>` 指定 `daily` / `rotate 14` / `compress` 即可。同时**给根分区做磁盘水位告警**（见 8.6）。

### 8.5 定时备份（含异地 —— 这一步才是真备份）

先明确一条：**没有推送到异地的备份，不算备份。** 云主机硬盘损坏或被误删时，同机备份会一起消失。

准备一个只读数据库的备份账号（不要用业务账号，也不要用 root），口令放在 `0600` 的文件里 —— **写在命令行会进 `ps` 和 shell history**：

```bash
sudo tee /root/.my.cnf > /dev/null <<'EOF'
[client]
user=<备份账号>
password=<备份账号口令>
EOF
sudo chmod 600 /root/.my.cnf
```

备份脚本（建议放 `/usr/local/bin/site-backup.sh`）：

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR=/var/backups/site
KEEP_DAYS=14
STAMP=$(date +%F_%H%M)
mkdir -p "$BACKUP_DIR"

# 1) 数据库（--single-transaction 保证不锁表）
mysqldump --defaults-extra-file=/root/.my.cnf \
  --single-transaction --routines --triggers '<库名>' \
  | gzip > "$BACKUP_DIR/db_${STAMP}.sql.gz"

# 2) 网站代码
tar czf "$BACKUP_DIR/site_${STAMP}.tar.gz" -C /var/www '<你的站点目录>'

# 3) 清理本地过期文件
find "$BACKUP_DIR" -type f -mtime +"$KEEP_DAYS" -delete

# 4) ★ 推送到异地（对象存储 / 另一台机器）—— 没有这一步等于没备份
rclone copy "$BACKUP_DIR" remote:my-backups/site
```

```bash
sudo chmod 750 /usr/local/bin/site-backup.sh

# 每天凌晨 3 点跑
( sudo crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/site-backup.sh >> /var/log/site-backup.log 2>&1" ) | sudo crontab -
```

> **最后一步别省：做一次恢复演练。** 把备份文件在临时目录里解出来、导入到一个临时库、确认数据完整。**没验证过能恢复的备份，等于没有备份。**

### 8.6 监控与告警

目标不是"上一套监控系统"，而是"出事之前有人知道"。最小可用三项：

| 监控项       | 为什么       | 最简单的做法                                   |
| --------- | --------- | ---------------------------------------- |
| 站点可用性     | 挂了要知道     | 外部服务（UptimeRobot 等），或另一台机器定时 requests 探活 |
| 磁盘 / 内存水位 | 撑爆前要有预警   | `df -h` / `free -m` 定时取数，超阈值发通知          |
| 证书到期时间    | 续期失败不会自己喊 | `certbot certificates` 取剩余天数，少于 15 天告警   |

> 证书这一项最容易漏：Let's Encrypt 证书 90 天有效，续期一旦悄悄失败（常见原因是 80 端口的 `/.well-known/acme-challenge/` 被跳转覆盖），你会在几个月后的某天突然收到"网站证书过期"的投诉。第 9 节给了验证方法。

### 8.7 PHP / Nginx 生产开关

开发时方便的错误提示，上线后就是信息泄露。

```ini
; /etc/php/<版本>/fpm/php.ini
display_errors = Off          ; 不把报错打到页面上
log_errors     = On           ; 但要记进日志
error_log      = /var/log/php/error.log
expose_php     = Off          ; 不在响应头里暴露 PHP 版本
```

```bash
sudo mkdir -p /var/log/php
sudo chown www-data:www-data /var/log/php     # EL 系换成 apache:apache
sudo systemctl restart php<版本>-fpm
```

nginx 侧的 `server_tokens off;` 已写进 4.1 节的配置（也可以放到主配置的 `http` 块里全局生效）。

### 8.8 ICP 备案（仅中国大陆境内主机）

| 步骤      | 说明                                |
| ------- | --------------------------------- |
| ① 准备域名  | 需在工信部认可的注册商注册，且后缀在可备案列表内          |
| ② 选择接入商 | 一般就是你的云厂商（他们同时是接入服务商）             |
| ③ 提交资料  | 主体信息（企业营业执照 / 法人证件）+ 网站信息 + 负责人核验 |
| ④ 等待审核  | 接入商初审 → 提交管局，**管局审核通常约 20 天**     |
| ⑤ 备案号公示 | 通过后备案号需在网站底部展示                    |

> **为什么必须做在前面**：未备案时云厂商会封禁域名的 80 / 443 端口。而第 9 节的 HTTPS 证书依赖 80 端口完成验证 —— 端口被封 → 证书签不出来 → HTTPS 上不了。这是一条**连锁失败**，不是"先上线后补"能绕过的。

---

## 9. 启用 HTTPS（对外网站必须）

2026 年对外网站没有 HTTPS，会同时踩三件事：浏览器"不安全"警告、搜索引擎降权、合规不达标。

### 9.1 先对齐三个概念

| 东西        | 是什么                                             | 谁给       |
| --------- | ----------------------------------------------- | -------- |
| **公网 IP** | 机器开出来就自带，不用"绑定"                                 | 云厂商      |
| **域名**    | 单独购买，然后在 DNS 里加一条 **A 记录**指向 IP（这一步才叫"解析 / 绑定"） | 域名注册商    |
| **证书**    | 里面写的身份标识是**域名**，不是 IP。浏览器验证时比的是"你访问的那个名字"       | CA（可免费签） |

所以"VPS 有 IP"和"网站能被 HTTPS 访问"之间，缺的是**一条 DNS 解析记录 + 一张证书**，不是缺一道"IP 绑定"的手续。


### 9.2 五个前置条件（缺一个就会失败）

```bash
# ① DNS 已生效 —— 输出的必须是你 VPS 的 IP
dig +short <你的域名>

# ② 80 和 443 都已放行（80 是证书验证必需，443 是业务必需）
sudo ufw status | grep -E '80|443'          # 或 firewall-cmd --list-all
```

③ **云厂商安全组**同样放行 80 / 443。  
④ 境内主机**先完成 ICP 备案**（8.8）。  
⑤ `server_name` 已改成真实域名 —— `certbot --nginx` 是靠 `-d 域名` 匹配配置里的 `server_name` 来定位该改哪个 server 块的；若还写着 `_`，它要么报错、要么悄悄另建一个新块，结果是"你改的地方没生效，生效的地方你没看过"。

### 9.3 申请证书

```bash
# Debian / Ubuntu
sudo apt install -y certbot python3-certbot-nginx

# EL 系（需 EPEL）
sudo dnf install -y certbot python3-certbot-nginx

# 一条命令：签发 + 自动写 443 块 + 自动加 80→443 跳转
sudo certbot --nginx -d <你的域名> -d www.<你的域名> --redirect
```

certbot 会自动完成：写 `listen 443 ssl;`、写 `ssl_certificate` / `ssl_certificate_key`、include 推荐的 TLS 参数、加 80→443 跳转、reload nginx、安装自动续期定时器。**它写的每一行都带 `# managed by Certbot` 注释**，可以这样精确审计它动了哪里：

```bash
sudo grep -rn "managed by Certbot" /etc/nginx/
```

想让配置完全受自己控制，就用 `certonly` 模式签发，然后**直接把附录 A 的完整模板贴进站点配置**（把 3 处占位符换成你的值）：

```bash
sudo certbot certonly --webroot -w /var/www/<你的站点目录> \
  -d <你的域名> -d www.<你的域名>
```

### 9.4 验证与管理

```bash
sudo nginx -t && sudo systemctl reload nginx

curl -I https://<你的域名>       # 期望 200
curl -I http://<你的域名>        # 期望 301 跳转到 https

# 证书主体与剩余天数
echo | openssl s_client -servername <你的域名> -connect <你的域名>:443 2>/dev/null \
  | openssl x509 -noout -subject -dates

# ★ 确认自动续期真的能跑（不做这条，等于把过期风险留到 90 天后）
sudo certbot renew --dry-run
```

再补一个最容易漏的检查 —— **ACME 验证路径不能被跳转覆盖**：

```bash
# 期望返回 404（而不是 301）。返回 301 就意味着续期会静默失败
curl -sI http://<你的域名>/.well-known/acme-challenge/test | head -1
```

> **HSTS 先别急着开。** `add_header Strict-Transport-Security` 一旦下发，浏览器会记住"这个域名只能走 HTTPS"，之后想回退到 HTTP 很麻烦。确认证书、跳转、子域名都稳定运行一段时间后再开（附录 A 里这行默认是注释掉的）。

### 9.5 三个容易踩的坑

1. **只写 `listen 443 ssl;` 却忘写证书两行 → nginx 直接启动失败：**
   ```
   nginx: [emerg] no "ssl_certificate" is defined in server listening on SSL port
   ```
   这两个指令必须与 `listen ... ssl` 同级（在同一个 server 块内），不能写在 `http` 或 `location` 里。
2. **证书路径永远指向 `/etc/letsencrypt/live/<域名>/`，不要指 `archive/`** —— 那是带日期的历史版本，续期后不会自动跟随。
3. **CMS 把绝对网址存在数据库里。** 如果装的是 WordPress / Typecho 这类，换域名后打开首页可能跳回旧地址、或 CSS 图片全 404。这跟 Nginx 无关，要改数据库里的 `siteurl` / `home`（WordPress 可用 `wp search-replace`）。

---

## 附录 ：Nginx 站点配置模板（完整版）

> **用法**：把整个文件内容复制进你的站点配置，替换 3 处占位符：
>
> 1. `<你的域名>` → 你的真实域名（全文件共 5 处）
> 2. `/var/www/<你的站点目录>` → 你的站点根目录（用 `grep -rn "root" /etc/nginx/` 查）
> 3. `/run/php/php<版本>-fpm.sock` → 你的 `fastcgi_pass` 值（用 `ls /run/php/` 查）
>
> 只有静态站（不含 PHP）时，删掉所有 `location ~ \.php$` 段落。

```nginx
# ===========================================================================
#  第 1 块 · 80 端口：只做证书验证放行 + 跳转到 HTTPS
# ===========================================================================
server {
    listen      80;
    listen      [::]:80;
    server_name <你的域名> www.<你的域名>;

    # ★ 必须保留，且必须位于下面的 301 跳转【之前】。
    #   Let's Encrypt 续期验证始终走 80 端口，这一条没了，90 天后会静默失败。
    location /.well-known/acme-challenge/ {
        root /var/www/<你的站点目录>;
        default_type text/plain;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# ===========================================================================
#  第 2 块 · 443 端口：真正的站点
# ===========================================================================
server {
    listen      443 ssl;
    listen      [::]:443 ssl;
    http2       on;                 # nginx 1.25.1+ 的写法；老版本用 listen 443 ssl http2;

    server_name <你的域名> www.<你的域名>;

    # ---- 证书：certbot 签发后的固定路径，勿指向 archive/ ----
    ssl_certificate         /etc/letsencrypt/live/<你的域名>/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/<你的域名>/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/<你的域名>/chain.pem;   # OCSP stapling 用

    # ---- TLS 参数（nginx 默认值已足够，此处显式写出便于审计）----
    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       10m;
    ssl_session_tickets       off;
    ssl_stapling              on;
    ssl_stapling_verify       on;
    resolver                  223.5.5.5 119.29.29.29 valid=300s;
    resolver_timeout          5s;

    # ---- HSTS：确认站点稳定、所有子域名都能走 HTTPS 之后再取消注释 ----
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # ---- 基础安全响应头 ----
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    # ---- 站点根目录 ----
    root  /var/www/<你的站点目录>;
    index index.php index.html index.htm;

    server_tokens off;
    client_max_body_size 10m;

    # 隐藏文件防护：.env / .git / .ht* 之类绝不能被下载
    location ~ /\.(?!well-known) {
        deny all;
        access_log off;
        log_not_found off;
    }

    # 入口与伪静态
    location / {
        try_files $uri $uri/ /index.php?$query_string;
        # WordPress 用：try_files $uri $uri/ /index.php?$args;
    }

    # ---- PHP：fastcgi_pass 按实际 socket 名填 ----
    location ~ \.php$ {
        try_files      $uri =404;
        include        fastcgi_params;
        fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index  index.php;
        fastcgi_read_timeout      300s;
        fastcgi_buffers           16 32k;
        fastcgi_buffer_size       64k;
        fastcgi_busy_buffers_size 64k;

        fastcgi_pass unix:/run/php/php<版本>-fpm.sock;   # EL 系换 /run/php-fpm/www.sock
    }

    # 静态资源缓存
    location ~* \.(jpg|jpeg|png|gif|webp|svg|ico|css|js|woff2?|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # 上传目录禁止执行脚本（CMS 强烈建议保留）
    location ~* /(uploads|files|images)/.*\.(php|php5|phtml|phar|php[0-9])$ {
        deny all;
    }

    access_log /var/log/nginx/<你的域名>.access.log;
    error_log  /var/log/nginx/<你的域名>.error.log;
}

# ===========================================================================
#  第 3 块 · 可选：兜底，未匹配到任何域名的请求直接断开
#  ⚠ 若已有 default_server（Debian 的 sites-enabled/default，或 EL 的 nginx.conf），
#    请【整块删掉】本块，否则 nginx -t 会报：
#      a duplicate default server for 0.0.0.0:80
# ===========================================================================
server {
    listen      80 default_server;
    listen      [::]:80 default_server;
    server_name _;
    return      444;
}
```
