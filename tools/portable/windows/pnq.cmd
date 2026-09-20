@echo off
rem ---------------------------------------------------------------------------
rem  proxy-node-audit portable launcher (Windows)
rem
rem  Usage:   pnq.cmd --check
rem           pnq.cmd "https://your-subscription-url"
rem
rem  NOTE: every message in this .cmd is intentionally ASCII-only.  cmd.exe reads
rem  .cmd files using the OEM code page (GBK on Chinese Windows), so non-ASCII
rem  text here would be garbled on some machines.  The Chinese docs live in
rem  README-FIRST.txt (UTF-8).
rem ---------------------------------------------------------------------------
setlocal enableextensions
chcp 65001 >nul 2>&1

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "HEREP=%HERE:\=/%"
set "RT=%HERE%\runtime"
set "BASH=%RT%\msys\usr\bin\bash.exe"

if not exist "%BASH%" (
  echo.
  echo [x] Missing: %BASH%
  echo.
  echo     The archive was not extracted completely. Please unzip the WHOLE
  echo     .zip with 7-Zip / WinRAR / Bandizip into a normal folder, then run
  echo     this file again. Do NOT run it from inside the archive preview.
  echo.
  echo     Details: README-FIRST.txt
  echo.
  pause
  exit /b 1
)

rem Bundled runtimes first, so system-wide tools cannot shadow them.
set "PATH=%RT%\bin;%RT%\python;%RT%\msys\usr\bin;%PATH%"
set "PNQ_PORTABLE=1"
set "PNQ_RUNTIME=%RT%"
if not defined HOME set "HOME=%USERPROFILE%"

"%BASH%" "%HEREP%/launch.sh" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo [x] exited with code %RC%
  echo     First run? Try:  pnq.cmd --check
  echo     It prints which component is missing.
  echo.
)
exit /b %RC%
