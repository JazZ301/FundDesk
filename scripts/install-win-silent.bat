@echo off
setlocal
for %%F in ("%~dp0..\release\*-setup.exe") do (
  start /wait "" "%%~fF" /S
  exit /b %errorlevel%
)
exit /b 1
