@echo off
REM Orrun - procedural fantasy wilderness.
REM WASD move, mouse look, Space jump, Shift sprint, F toggle fly,
REM H debug HUD, M hydro map, 1-3 terrain debug views, Esc release mouse.

setlocal
cd /d "%~dp0"

set "GODOT="
if defined ORRUN_GODOT if exist "%ORRUN_GODOT%" set "GODOT=%ORRUN_GODOT%"
if not defined GODOT if exist "%~dp0tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=%~dp0tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "%~dp0tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=%~dp0tools\godot\Godot_v4.6-stable_win64.exe"
if not defined GODOT if exist "C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "C:\Projekte\InfiniWorld\tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=C:\Projekte\InfiniWorld\tools\godot\Godot_v4.6-stable_win64.exe"

if not defined GODOT (
    echo ERROR: Godot 4.6 not found.
    echo Put the editor at tools\godot\Godot_v4.6-voxel_win64.exe
    echo or set ORRUN_GODOT to the full path of the executable.
    pause
    exit /b 1
)

if not exist "%~dp0project.godot" (
    echo ERROR: project.godot not found next to start.bat.
    pause
    exit /b 1
)

echo Starting Orrun with:
echo   %GODOT%
"%GODOT%" --path "%~dp0" %*
endlocal
