@echo off
:: ============================================================================
:: GTNH Updater Launcher
:: ============================================================================
:: Double-click this file to launch the GTNH Updater.
:: If PowerShell 7 is not installed, it will offer to install it for you.
:: ============================================================================

where pwsh >nul 2>nul
if %errorlevel% equ 0 goto :launch

echo.
echo   PowerShell 7 is required but not installed.
echo.

:: Check if winget is available (Windows 10 1709+ and Windows 11)
where winget >nul 2>nul
if %errorlevel% neq 0 goto :manual

echo   Install it now? This uses winget (built into Windows).
echo.
echo   [1] Install PowerShell 7 now (recommended)
echo   [2] Open download page instead
echo   [3] Cancel
echo.
set /p choice="  Choose (1/2/3): "

if "%choice%"=="1" goto :winget_install
if "%choice%"=="2" goto :manual
goto :cancel

:winget_install
echo.
echo   Installing PowerShell 7...
echo.
winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
if %errorlevel% neq 0 (
    echo.
    echo   Installation failed. Try running this as Administrator, or install manually:
    echo   https://github.com/PowerShell/PowerShell/releases
    echo.
    pause
    exit /b 1
)
echo.
echo   PowerShell 7 installed successfully.
echo   Please close this window and double-click the launcher again.
echo   If it still doesn't work, restart your computer to update PATH.
echo.
pause
exit /b 0

:manual
echo   Download PowerShell 7 from:
echo   https://github.com/PowerShell/PowerShell/releases
echo.
echo   Pick the .msi installer for Windows (x64).
echo   After installing, double-click this launcher again.
echo.
pause
exit /b 1

:cancel
exit /b 0

:launch
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-GTNH.ps1"
pause
