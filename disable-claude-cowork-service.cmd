@echo off
setlocal EnableDelayedExpansion
title Disable Claude CoworkVMService Auto-Start

REM Check Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ========================================================
    echo   [INFO] Administrator privileges required.
    echo   Requesting UAC elevation...
    echo ========================================================
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/k cd /d \"%~dp0\" && call \"%~nx0\" :elevated' -Verb RunAs" 2>nul
    if %errorlevel% neq 0 (
        echo.
        echo [NOTICE] If UAC prompt did not appear, please:
        echo   Right-click this file and select:
        echo   'Run as administrator'
        echo.
        pause
    )
    exit /b
)

:elevated
cls
echo ========================================================
echo        Disable Claude CoworkVMService Auto-Start
echo ========================================================
echo.

echo [1/3] Stopping CoworkVMService (if running)...
sc stop CoworkVMService >nul 2>&1

echo [2/3] Setting service startup type to Disabled...
sc config CoworkVMService start= disabled

echo [3/3] Setting HKLM registry Start = 4...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\CoworkVMService" /v Start /t REG_DWORD /d 4 /f

echo.
echo ========================================================
echo [Verification]
reg query "HKLM\SYSTEM\CurrentControlSet\Services\CoworkVMService" /v Start
sc qc CoworkVMService | findstr "START_TYPE"
echo ========================================================
echo.
echo [DONE] CoworkVMService has been completely disabled!
echo SCM will NOT auto-start this service on Windows boot.
echo.
pause