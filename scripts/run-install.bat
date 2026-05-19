@echo off
REM Download from http://192.168.68.54:8081/agent/run-install.bat or GitHub

set GXRA_API=http://192.168.68.54:8081
set GXRA_TENANT=pilot-1
set GH_PS1=https://github.com/brkn404/gx-ra-agent/raw/main/scripts/install-windows.ps1
set SCRIPT=%USERPROFILE%\Downloads\gxra-install.ps1

echo GX-RA agent installer
echo.

echo Downloading install script from GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -Uri '%GH_PS1%' -OutFile '%SCRIPT%' -UseBasicParsing } catch { exit 1 }"
if errorlevel 1 (
  echo GitHub failed, trying GX-RA server...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -Uri '%GXRA_API%/agent/install-windows.ps1' -OutFile '%SCRIPT%' -UseBasicParsing"
)

if not exist "%SCRIPT%" (
  echo ERROR: Could not download installer.
  pause
  exit /b 1
)

echo Running install...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ApiUrl "%GXRA_API%" -TenantId "%GXRA_TENANT%" -Hostname %COMPUTERNAME%
pause
