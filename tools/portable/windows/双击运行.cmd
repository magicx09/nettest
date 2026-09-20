@echo off
rem ---------------------------------------------------------------------------
rem  Double-click me.  (Chinese filename: shuang-ji-yun-xing.cmd)
rem
rem  This opens a console window, asks for your subscription URL, runs the full
rem  audit and keeps the window open afterwards so you can read the result.
rem
rem  If this file's name shows up as garbage in Explorer, use run.cmd instead
rem  (same thing, ASCII filename).
rem ---------------------------------------------------------------------------
setlocal enableextensions
cd /d "%~dp0"
call "%~dp0pnq.cmd"
set "RC=%ERRORLEVEL%"
echo.
echo Done. Report: %~dp0out\latest\REPORT.md
echo (In the report, a dash "-" means "not measured", it does NOT mean zero.)
echo.
pause
exit /b %RC%
