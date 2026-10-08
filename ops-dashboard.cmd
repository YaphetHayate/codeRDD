@echo off
rem ---------------------------------------------------------------------------
rem In-repo entry point for the RDD operations dashboard.
rem
rem The dashboard itself is distributed with the engine (rdd-engine/scripts/
rem dashboard.cmd -> rdd-engine/dashboard/server.mjs). This root-level alias
rem exists so that a checkout can start the board without knowing the engine
rem sub-path ??? it simply delegates, passing every argument through.
rem
rem Usage: ops-dashboard.cmd [-Port <n>]
rem ---------------------------------------------------------------------------
call "%~dp0rdd-engine\scripts\dashboard.cmd" %*
exit /b %ERRORLEVEL%
