@echo off
taskkill /IM funddesk.exe /F >nul 2>&1
for /d %%D in ("C:\Users\MAC\AppData\Local\*") do (
  if exist "%%D\funddesk.exe" start "" "%%D\funddesk.exe"
)
