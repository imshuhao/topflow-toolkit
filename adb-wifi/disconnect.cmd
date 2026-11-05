@echo off
setlocal
rem ---------------------------------------------------------------
rem TopFlow wireless ADB helper (Windows): drop the wireless transport.
rem Keep ADB_PORT in sync with adb-wifi\connect.cmd and the router
rem config /data/adb-wifi/config (ADB_WIFI_PORT, default 15555).
rem ---------------------------------------------------------------
set "ADB_HOST=192.168.0.1"
set "ADB_PORT=15555"
set "ADB_SERIAL=%ADB_HOST%:%ADB_PORT%"

where adb >nul 2>nul
if errorlevel 1 (
  echo [adb-wifi] adb not found in PATH.
  goto :done
)

adb disconnect %ADB_SERIAL%
if errorlevel 1 (
  echo [adb-wifi] nothing to disconnect, or adb reported an error.
)

echo.
adb devices -l
echo.

:done
rem Never leave a failing code in the interactive prompt.
exit /b 0
