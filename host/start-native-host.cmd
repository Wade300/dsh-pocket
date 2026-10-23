@echo off
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js not found. Install Node 18+ from https://nodejs.org/
  pause
  exit /b 1
)
echo.
echo DSH 随身连 · 原生版主机
echo 电脑和手机连同一个 Wi-Fi。保持本窗口开着。
echo.
node dsh-native-host.mjs %*
echo.
echo 主机已停止。
pause
