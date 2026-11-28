@echo off
setlocal
set "ROOT=%~dp0.."
if "%CARGO_HOME%"=="" set "CARGO_HOME=C:\cargo"
if "%RUSTUP_HOME%"=="" set "RUSTUP_HOME=C:\rustup"
if "%VCVARSALL%"=="" set "VCVARSALL=C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"

call "%VCVARSALL%" x64
if errorlevel 1 exit /b 1

set "PATH=%CARGO_HOME%\bin;%PATH%"
cd /d "%ROOT%"
set "EXTRA_ARGS="
if "%TAURI_SIGNING_PRIVATE_KEY%"=="" if exist "%USERPROFILE%\.tauri\funddesk.key" set "TAURI_SIGNING_PRIVATE_KEY=%USERPROFILE%\.tauri\funddesk.key"
if "%TAURI_SIGNING_PRIVATE_KEY%"=="" (
  echo No updater signing key found; building without updater artifacts.
  set EXTRA_ARGS=--config "%CD%\tauri.ci.conf.json"
)
if not "%WINDOWS_CERT_THUMBPRINT%"=="" (
  > tauri.signing.conf.json echo {"bundle":{"windows":{"certificateThumbprint":"%WINDOWS_CERT_THUMBPRINT%","digestAlgorithm":"sha256","timestampUrl":"http://timestamp.digicert.com"}}}
  set EXTRA_ARGS=%EXTRA_ARGS% --config "%CD%\tauri.signing.conf.json"
)
call node_modules\.bin\tauri.cmd build --target x86_64-pc-windows-msvc --bundles nsis %EXTRA_ARGS%
if errorlevel 1 exit /b 1
if not "%WINDOWS_CERT_THUMBPRINT%"=="" del tauri.signing.conf.json

if not exist release mkdir release
for %%F in ("target\x86_64-pc-windows-msvc\release\bundle\nsis\*-setup.exe") do copy /Y "%%~fF" "release\" >nul
echo Installer created in %CD%\release
