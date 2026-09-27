@echo off
rem ============================================================
rem  Domain Access Diagnosis (Windows CMD, pure built-in tools)
rem  Save as .bat and double-click. Edit the block below only.
rem  NOTE: keep this file ASCII-only. Chinese text inside a .bat
rem        breaks the batch parser (codepage mismatch).
rem ============================================================
chcp 65001 >nul
setlocal

rem ============== EDIT THIS BLOCK ==============
set DOMAIN=www.freedidi.com
set HTTPURL=https://www.freedidi.com/
set PROXY=127.0.0.1:10808
set A_IP=
set AAAA_IP=
set V2RAYN_CFG=D:\v2rayN-windows-64\binConfigs\config.json
rem =============================================

echo ==========================================================
echo   Domain Access Diagnosis
echo   target : %DOMAIN%
echo   proxy  : %PROXY%
echo   time   : %date% %time%
echo ==========================================================

echo.
echo [STEP 1] DNS "A" record (IPv4)  -- only lines after "Name:" are the answer
nslookup -type=A %DOMAIN%

echo.
echo [STEP 2] DNS "AAAA" record (IPv6)  ^<== the record everyone forgets
nslookup -type=AAAA %DOMAIN%

echo.
echo [STEP 3] Direct by domain name, bypassing proxy: which stack does the OS pick?
set SAVED_PROXY=%http_proxy%
set http_proxy=
set https_proxy=
curl -sk --noproxy "*" -o NUL -w "     HTTP %%{http_code}   connected-ip %%{remote_ip}   time %%{time_total}s\n" -m 20 %HTTPURL%
if errorlevel 1 echo      ^>^> FAILED before HTTP: TCP or TLS layer problem
set http_proxy=%SAVED_PROXY%
set https_proxy=%SAVED_PROXY%

echo.
echo [STEP 4] Through the proxy client port %PROXY%
curl -sk -x http://%PROXY% -o NUL -w "     HTTP %%{http_code}   time %%{time_total}s\n" -m 25 %HTTPURL%
if errorlevel 1 echo      ^>^> FAILED before HTTP
echo      -- proxy egress identity (AS13335 = Cloudflare = resolves remotely) --
curl -s -m 15 -x http://%PROXY% https://api.ip.sb/geoip
echo.

echo.
echo [STEP 5] Verbose through proxy: locate the exact failing layer
echo          ("CONNECT tunnel established" = proxy fine / "fatal SSL/TLS alert" = TLS layer)
curl -sv -x http://%PROXY% -o NUL -m 25 %HTTPURL% 2>&1 | findstr /I /C:"Trying" /C:"CONNECT tunnel" /C:"schannel" /C:"fatal" /C:"alert"

echo.
echo [STEP 6] Force IPv4 -- fill A_IP from STEP 1 above, then rerun
if "%A_IP%"=="" echo      A_IP empty - skipped
if not "%A_IP%"=="" curl -sk --noproxy "*" --resolve %DOMAIN%:443:%A_IP% -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" -o NUL -w "     ipv4-forced HTTP %%{http_code}   size %%{size_download}\n" -m 20 %HTTPURL%

echo.
echo [STEP 7] Force IPv6 -- fill AAAA_IP from STEP 2 above, then rerun
if "%AAAA_IP%"=="" echo      AAAA_IP empty - skipped
if not "%AAAA_IP%"=="" curl -sk --noproxy "*" --resolve "%DOMAIN%:443:[%AAAA_IP%]" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" -o NUL -w "     ipv6-forced HTTP %%{http_code}   size %%{size_download}\n" -m 20 %HTTPURL%
if not "%AAAA_IP%"=="" if errorlevel 1 echo      ^>^> IPv6 FAILED while IPv4 works = BROKEN AAAA RECORD CONFIRMED

echo.
echo [STEP 8] TLS certificate of each server (no openssl needed)
echo          set A_IP / AAAA_IP first; one of them will fail with alert 112
if not "%A_IP%"=="" powershell -NoProfile -Command "$c=New-Object Net.Sockets.TcpClient; $c.Connect('%A_IP%',443); $s=New-Object Net.Security.SslStream($c.GetStream(),$false,{$true}); $s.AuthenticateAsClient('%DOMAIN%'); 'A_IP certificate  : ' + $s.RemoteCertificate.Subject; $c.Close()"
if not "%AAAA_IP%"=="" powershell -NoProfile -Command "$c=New-Object Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetworkV6); $c.Connect('%AAAA_IP%',443); $s=New-Object Net.Security.SslStream($c.GetStream(),$false,{$true}); try{ $s.AuthenticateAsClient('%DOMAIN%'); 'AAAA_IP certificate: ' + $s.RemoteCertificate.Subject } catch { 'AAAA_IP certificate: TLS REJECTED - this server does not host ' + '%DOMAIN%' }; $c.Close()"

echo.
echo [STEP 9] Global reachability, 4 countries (check-host.net)
curl -s -m 20 -H "Accept: application/json" "https://check-host.net/check-http?host=%HTTPURL%&max_nodes=4" -o "%TEMP%\chk.json"
set RID=
for /f "delims=" %%a in ('findstr /C:"request_id" "%TEMP%\chk.json"') do set RID=%%a
set RID=%RID:*request_id":=%
set RID=%RID:"=%
set RID=%RID:}=%
if "%RID%"=="" echo      parse failed, raw response:
if "%RID%"=="" findstr /C:"request_id" "%TEMP%\chk.json"
if not "%RID%"=="" (
  echo      request %RID% - waiting 8s ...
  ping -n 9 127.0.0.1 >nul
  curl -s -m 20 -H "Accept: application/json" "https://check-host.net/check-result/%RID%"
  echo.
)

echo.
echo [STEP 10] What the kernel actually runs (GUI settings can differ)
if exist "%V2RAYN_CFG%" findstr /N /C:"freedidi" /C:"UseIPv4" /C:"domainStrategy" "%V2RAYN_CFG%"
if not exist "%V2RAYN_CFG%" echo      config not found: %V2RAYN_CFG%
echo      ^(no "freedidi" line printed = rule is NOT in the ACTIVE rule set^)

echo.
echo ==========================================================
echo  HOW TO READ THE RESULT
echo   STEP3 fail + STEP6 OK     = broken AAAA / IPv6 path   (this case)
echo   STEP3 fail + STEP6 fail   = egress IP blocked, or site down
echo   STEP4 fail + STEP6 OK     = proxy egress resolves to the bad IPv6
echo   STEP5 "fatal SSL/TLS alert"= TCP connected but TLS rejected
echo   HTTP 403 / verify page    = anti-bot, NOT a network fault
echo ==========================================================
pause
