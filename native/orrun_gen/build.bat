@echo off
setlocal
cd /d "%~dp0"
set CARGO_TARGET_DIR=%~dp0target
cargo build --release
if errorlevel 1 exit /b 1
mkdir "%~dp0..\..\addons\orrun_gen\bin" 2>nul
copy /Y "%~dp0target\release\orrun_gen.dll" "%~dp0..\..\addons\orrun_gen\bin\orrun_gen.dll" >nul
mkdir "%~dp0..\..\.godot" 2>nul
> "%~dp0..\..\.godot\extension_list.cfg" echo res://addons/orrun_gen/orrun_gen.gdextension
echo Installed addons\orrun_gen\bin\orrun_gen.dll
