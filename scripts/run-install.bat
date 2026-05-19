@echo off
REM Download from: https://github.com/brkn404/gx-ra-agent/raw/main/scripts/run-install.bat
REM Or from your GX-RA server: http://192.168.68.54:8081/agent/run-install.bat

set GXRA_API=http://192.168.68.54:8081
set GXRA_TENANT=pilot-1

echo GX-RA agent installer
echo API: %GXRA_API%
echo.

set SCRIPT=%USERPROFILE%\Downloads\gxra-install.ps1
echo Downloading install script...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%GXRA_API%/agent/install-windows.ps1' -OutFile '%SCRIPT%'"

if not exist "%SCRIPT%" (
  echo Trying GitHub mirror...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://github.com/brkn404/gx-ra-agent/raw/main/scripts/install-windows.ps1' -OutFile '%SCRIPT%'"
)

echo Running install...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ApiUrl "%GXRA_API%" -TenantId "%GXRA_TENANT%" -Hostname %COMPUTERNAME%

echo.
pause
