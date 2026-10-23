@echo off
setlocal EnableExtensions
rem DSH Pocket / HarmonyOS HAP build script.
rem hvigor rejects non-ASCII project paths, so the project is copied to
rem %TEMP%\dsh-pocket-build before building.

set "ROOT=%~dp0.."
pushd "%ROOT%"
set "ROOT=%CD%"
popd

if not defined DEVECO_HOME (
  if exist "C:\Program Files\Huawei\DevEco Studio\bin\devecostudio64.exe" set "DEVECO_HOME=C:\Program Files\Huawei\DevEco Studio"
)
if not defined DEVECO_HOME (
  echo DevEco Studio not found.
  echo Set DEVECO_HOME, or install DevEco Studio in the default location.
  exit /b 1
)

set "NODE_HOME=%DEVECO_HOME%\tools\node"
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"
if not exist "%NODE_HOME%\node.exe" (
  echo Missing %NODE_HOME%\node.exe
  exit /b 1
)
if not exist "%DEVECO_SDK_HOME%\default\sdk-pkg.json" (
  echo Missing SDK: %DEVECO_SDK_HOME%
  exit /b 1
)

set "BUILD_DIR=%TEMP%\dsh-pocket-build"
if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%"
robocopy "%ROOT%\harmony" "%BUILD_DIR%" /MIR /XD build .hvigor node_modules oh_modules /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
  echo Failed to copy the project to %BUILD_DIR%
  exit /b 1
)

set "SDK_FWD=%DEVECO_SDK_HOME:\=/%"
> "%BUILD_DIR%\local.properties" echo sdk.dir=%SDK_FWD%

pushd "%BUILD_DIR%"
call "%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
set "RC=%ERRORLEVEL%"
popd

if not "%RC%"=="0" (
  echo.
  echo Build failed. See the log above and docs\INSTALL.md.
  exit /b %RC%
)

if not exist "%ROOT%\dist" mkdir "%ROOT%\dist"
copy /Y "%BUILD_DIR%\entry\build\default\outputs\default\entry-default-unsigned.hap" "%ROOT%\dist\entry-default-unsigned.hap" >nul
echo.
echo Build OK (unsigned):
echo   %ROOT%\dist\entry-default-unsigned.hap
echo.
echo To install on a phone, sign it in DevEco Studio with a Huawei account.
echo See docs\INSTALL.md.
exit /b 0
