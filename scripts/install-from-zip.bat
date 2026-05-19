@echo off
set GXRA_API=http://192.168.68.54:8081
set GXRA_TENANT=pilot-1
set SRC=%USERPROFILE%\Downloads\gx-ra-agent-main
if not exist "%SRC%\pyproject.toml" (
  echo Extract gx-ra-agent-main.zip to Downloads first.
  pause
  exit /b 1
)
python -m venv C:\gxra-agent-venv 2>nul || py -3.12 -m venv C:\gxra-agent-venv
C:\gxra-agent-venv\Scripts\pip.exe install -e "%SRC%"
set GXRA_API_URL=%GXRA_API%
set GXRA_TENANT_ID=%GXRA_TENANT%
C:\gxra-agent-venv\Scripts\gxra-agent.exe register --hostname %COMPUTERNAME%
C:\gxra-agent-venv\Scripts\gxra-agent.exe learn --start-learning --interval 60 --count 6 --freeze
pause
