@echo off
REM Inspect continental XZ (optional --yaw <rad>). Writes logs\inspect_at.txt
REM   inspect.bat 173495 39048
REM   inspect.bat 173495 39048 --yaw 1.20

setlocal
cd /d "%~dp0"
set "ROOT=%CD%"

set "GODOT="
if defined ORRUN_GODOT if exist "%ORRUN_GODOT%" set "GODOT=%ORRUN_GODOT%"
if not defined GODOT if exist "%ROOT%\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=%ROOT%\tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "%ROOT%\tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=%ROOT%\tools\godot\Godot_v4.6-stable_win64.exe"
if not defined GODOT if exist "C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe"

if not defined GODOT (
    echo ERROR: Godot 4.6 not found.
    exit /b 1
)

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

echo Inspecting with %GODOT%
"%GODOT%" --headless --path "%ROOT%" --script res://tools/inspect_at.gd -- %*
set "ERR=%ERRORLEVEL%"
echo.
if exist "%ROOT%\logs\inspect_at.txt" (
    echo --- logs\inspect_at.txt ---
    type "%ROOT%\logs\inspect_at.txt"
)
exit /b %ERR%
