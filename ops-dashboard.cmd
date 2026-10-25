@echo off
rem ---------------------------------------------------------------------------
rem In-repo entry point for the RDD operations dashboard.
rem
rem The dashboard lives with the engine (rdd-engine/dashboard/, entry beside
rem the implementation: dashboard.cmd -> server.mjs). This root-level alias
rem exists so that a checkout can start the board without knowing the engine
rem sub-path ??? it simply delegates, passing every argument through.
rem
rem Usage: ops-dashboard.cmd [-Port <n>]
rem ---------------------------------------------------------------------------
call "%~dp0rdd-engine\dashboard\dashboard.cmd" %*
exit /b %ERRORLEVEL%
