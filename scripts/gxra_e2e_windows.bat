@echo off
REM Windows E2E demo — keeps window open so you can read the result.
setlocal
set ENTITY_ID=ent-c8b507e0cad4
set GXRA_DEMO_HOST=win-vm-lab01
set GXRA_API_BASE=http://192.168.68.54:8081
set GXRA_TENANT_ID=pilot-1

cd /d "%~dp0.."

where bash >nul 2>&1
if errorlevel 1 (
  echo Git Bash not found. Install Git for Windows, or run from PowerShell:
  echo   $env:ENTITY_ID='ent-c8b507e0cad4'; $env:GXRA_API_BASE='http://192.168.68.54:8081'
  echo   Invoke-WebRequest http://192.168.68.54:8081/health
  pause
  exit /b 1
)

bash scripts/gxra_e2e_windows.sh
set EXITCODE=%ERRORLEVEL%
echo.
if %EXITCODE% equ 0 (
  echo E2E finished successfully.
) else (
  echo E2E failed with exit code %EXITCODE%.
)
pause
exit /b %EXITCODE%
