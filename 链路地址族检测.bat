@echo off
chcp 936 >nul
setlocal
title 一键检测链路地址族 - 双栈 / 仅IPv4 / 仅IPv6

rem ============================================================
rem  一键检测链路地址族：双栈 / 仅IPv4 / 仅IPv6
rem  用途：判断一条链路会不会踩到「坏的 AAAA 记录」
rem  原理：IPv4 与 IPv6 是两条独立通路，必须各测一次
rem        造一个「只能用某一种地址族到达」的目标，看能否打通
rem  用法：只改下面的 PROXY 为你代理客户端的本地端口，双击运行
rem  说明：探测命令带 --ssl-no-revoke，避免 Windows curl 证书吊销
rem        检查离线时出现「假 000」（CRYPT_E_REVOCATION_OFFLINE）
rem  编码：本文件为 GBK(ANSI) 编码，配合脚本内的 chcp 936
rem        切勿另存为 UTF-8，否则中文乱码并可能中断批处理解析
rem ============================================================

rem ===================== 可修改区 =====================
set PROXY=127.0.0.1:10808
rem 只有 A 记录的主机，只能用 IPv4 到达
set V4HOST=https://v4.ident.me/
rem 只有 AAAA 记录的主机，只能用 IPv6 到达
set V6HOST=https://v6.ident.me/
rem 同时有 A 和 AAAA 记录的主机，用于 -4 / -6 交叉印证
set DUALHOST=https://www.cloudflare.com/
rem ====================================================

echo ============================================================
echo   一键检测链路地址族                  %date% %time%
echo   代理端口：%PROXY%
echo ============================================================
echo.

rem ---------- 一、直连链路：两个方向各测一次 ----------
set D4=000
set D6=000
set D4F=000
set D6F=000
for /f %%i in ('curl -sk --ssl-no-revoke -m 15 --noproxy "*" -o NUL -w "%%{http_code}" %V4HOST%') do set D4=%%i
for /f %%i in ('curl -sk --ssl-no-revoke -m 15 --noproxy "*" -o NUL -w "%%{http_code}" %V6HOST%') do set D6=%%i
for /f %%i in ('curl -s --ssl-no-revoke -4 -m 15 --noproxy "*" -o NUL -w "%%{http_code}" %DUALHOST%') do set D4F=%%i
for /f %%i in ('curl -s --ssl-no-revoke -6 -m 15 --noproxy "*" -o NUL -w "%%{http_code}" %DUALHOST%') do set D6F=%%i

echo [一] 直连链路（不经代理）
echo     IPv4 方向  打 IPv4 专用主机 = %D4%      -4 打双栈主机 = %D4F%
echo     IPv6 方向  打 IPv6 专用主机 = %D6%      -6 打双栈主机 = %D6F%
echo     说明：000 表示这次请求没成功（多为该方向不通；偶发单次
echo          000 也可能是假失败，见末尾注意 4）
echo.

rem ---------- 二、代理链路：v6 专用判能力 + v4 专用作对照 ----------
set P6=000
set P4=000
for /f %%i in ('curl -sk --ssl-no-revoke -m 20 -x http://%PROXY% -o NUL -w "%%{http_code}" %V6HOST%') do set P6=%%i
for /f %%i in ('curl -sk --ssl-no-revoke -m 20 -x http://%PROXY% -o NUL -w "%%{http_code}" %V4HOST%') do set P4=%%i

echo [二] 代理链路  http://%PROXY%
echo     IPv4 方向  打 IPv4 专用主机 = %P4%      对照组，用来证明链路是活的
echo     IPv6 方向  打 IPv6 专用主机 = %P6%      用来判断出口能否走 IPv6
echo.

rem ---------- 三、判定 ----------
set V4OK=NO
set V6OK=NO
if not "%D4%"=="000" set V4OK=YES
if not "%D4F%"=="000" set V4OK=YES
if not "%D6%"=="000" set V6OK=YES
if not "%D6F%"=="000" set V6OK=YES

set VD=链路不通
if "%V4OK%"=="YES" if "%V6OK%"=="YES" set VD=双栈
if "%V4OK%"=="YES" if "%V6OK%"=="NO" set VD=仅IPv4
if "%V4OK%"=="NO" if "%V6OK%"=="YES" set VD=仅IPv6

set VP=链路不通
if not "%P6%"=="000" set VP=双栈
if "%P6%"=="000" if not "%P4%"=="000" set VP=仅IPv4

echo ============================================================
echo   检测结果
echo     直连链路 ：%VD%
echo     代理链路 ：%VP%
echo ------------------------------------------------------------
echo   怎么用这个结果：
echo     双栈   两个方向都通，会优先走 IPv6。遇到坏的 AAAA 记录会
echo            卡在 TLS 握手且不回退，需要给该域名单独指定 IPv4 出口
echo            v2rayN 的做法是加一条路由规则指向 direct，并把
echo            freedom 出站的拨号策略设为 UseIPv4
echo     仅IPv4 没有可用的 IPv6，坏 AAAA 伤不到你，天然免疫，无需改动
echo     仅IPv6 最危险，坏记录上无路可退，优先更换链路
echo     链路不通 链路本身不通，先修链路或更换探测主机
echo ============================================================
echo.
echo 四点注意：
echo   1 经代理的请求回显的永远是代理自己的地址，判断地址族只能看
echo     专用主机能不能打开，不能看回显 IP
echo   2 -4 / -6 只对本机直连有效。经代理时域名是交给代理去解析和
echo     拨号的，加 -4 / -6 没有任何作用
echo   3 若同一方向的两条探测结果不一致，以「专用主机」那条为准。
echo     若两个专用主机都打不开，先怀疑探测主机本身不通，可以换成
echo     ipv4.icanhazip.com 与 ipv6.icanhazip.com 再试
echo   4 偶发的单次 000 可能是「证书吊销检查离线」造成的假失败
echo     （Windows curl 特性，实测报 CRYPT_E_REVOCATION_OFFLINE），
echo     与连通性无关。重跑一次即可复判；本脚本已加 --ssl-no-revoke
echo     从根上规避；手工测试时也建议带上该参数
echo.
pause
