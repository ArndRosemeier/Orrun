@echo off
REM Orrun continent atlas 2D viewer.
REM Drag to pan, wheel to zoom (deep zoom supported), right-click cycles views.
REM Zoom until cells are ~56+ px wide to see per-cell field overlays.
REM
REM Optional: start_atlas.bat -- --seed=42 --size=256
REM Full production atlas: start_atlas.bat -- --size=1000

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

echo Starting atlas viewer with:
echo   %GODOT%
"%GODOT%" --path "%ROOT%" res://scenes/atlas_viewer.tscn %*
endlocal
