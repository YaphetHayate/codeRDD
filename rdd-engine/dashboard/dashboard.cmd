@echo off
rem ---------------------------------------------------------------------------
rem RDD operations dashboard - launch shell (works with any RDD project).
rem
rem ASCII only on purpose: cmd.exe parses .cmd files with the console codepage,
rem so Chinese text here would be mojibake. All user-facing Chinese output is
rem produced by the Node service (UTF-8).
rem
rem Usage:
rem   dashboard.cmd                 start on the default port (8787)
rem   dashboard.cmd -Port 8899      start on another port
rem
rem The data root is resolved by the service: RDD_PROJECT_ROOT, else the nearest
rem ".rdd" ancestor of the current directory.
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul 2>nul
where node >nul 2>nul
if errorlevel 1 (
    echo [rdd-dashboard] Node.js was not found on PATH.
    echo [rdd-dashboard] Install Node.js 18 or newer, then retry. The dashboard
    echo [rdd-dashboard] itself needs no npm packages.
    exit /b 1
)
node "%~dp0server.mjs" %*
exit /b %ERRORLEVEL%
