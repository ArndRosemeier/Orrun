@echo off
REM Orrun - procedural fantasy wilderness.
REM WASD move, mouse look, Space jump, Shift sprint, F toggle fly,
REM H debug HUD, M world map, 1-3 terrain debug views, Esc release mouse.
REM Script errors are mirrored to logs\godot_runtime.log (also via AgentLog).

setlocal
cd /d "%~dp0"
REM %~dp0 ends with \, which escapes the closing quote in "--path "%~dp0"".
REM %CD% after the cd above does not, so the path stays well-formed.
set "ROOT=%CD%"

set "GODOT="
if defined ORRUN_GODOT if exist "%ORRUN_GODOT%" set "GODOT=%ORRUN_GODOT%"
if not defined GODOT if exist "%ROOT%\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=%ROOT%\tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "%ROOT%\tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=%ROOT%\tools\godot\Godot_v4.6-stable_win64.exe"
if not defined GODOT if exist "C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "C:\Projekte\InfiniWorld\tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=C:\Projekte\InfiniWorld\tools\godot\Godot_v4.6-stable_win64.exe"

if not defined GODOT (
    echo ERROR: Godot 4.6 not found.
    echo Put the editor at tools\godot\Godot_v4.6-voxel_win64.exe
    echo or set ORRUN_GODOT to the full path of the executable.
    pause
    exit /b 1
)

if not exist "%ROOT%\project.godot" (
    echo ERROR: project.godot not found next to start.bat.
    pause
    exit /b 1
)

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

echo Starting Orrun with:
echo   %GODOT%
echo   script errors -^> %ROOT%\logs\godot_runtime.log
echo   engine log    -^> %ROOT%\logs\godot_engine.log
"%GODOT%" --path "%ROOT%" --log-file "%ROOT%\logs\godot_engine.log" %*
endlocal
