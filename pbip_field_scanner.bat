@echo off
chcp 65001 >nul 2>&1
title PBIP Field Scanner
echo.
echo ============================================================
echo   PBIP Field Dependency Scanner
echo   Double-click to run, no dependencies required
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pbip_field_scanner.ps1" -Path "%~dp0."
echo.
pause
