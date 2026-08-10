@echo off
REM Orrun 2D hamlet lab — markets + houses, live constants.
REM Sliders regenerate immediately. Roads deferred.
REM After script edits from the agent: close this window, re-run this bat.

setlocal
cd /d "%~dp0"
set "ROOT=%CD%"

set "GODOT="
if defined ORRUN_GODOT if exist "%ORRUN_GODOT%" set "GODOT=%ORRUN_GODOT%"
if not defined GODOT if exist "%ROOT%\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=%ROOT%\tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "%ROOT%\tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=%ROOT%\tools\godot\Godot_v4.6-stable_win64.exe"
if not defined GODOT if exist "C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe" set "GODOT=C:\Projekte\City\tools\godot\Godot_v4.6-voxel_win64.exe"
if not defined GODOT if exist "C:\Projekte\InfiniWorld\tools\godot\Godot_v4.6-stable_win64.exe" set "GODOT=C:\Projekte\InfiniWorld\tools\godot\Godot_v4.6-stable_win64.exe"

if not defined GODOT (
    echo ERROR: Godot 4.6 not found.
    pause
    exit /b 1
)

if not exist "%ROOT%\scenes\debug\hamlet_planner_2d.tscn" (
    echo ERROR: scenes\debug\hamlet_planner_2d.tscn not found.
    pause
    exit /b 1
)

echo Starting hamlet planner with:
echo   %GODOT%
"%GODOT%" --path "%ROOT%" res://scenes/debug/hamlet_planner_2d.tscn %*
endlocal
