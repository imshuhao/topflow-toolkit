@echo off
setlocal
rem ---------------------------------------------------------------
rem TopFlow wireless ADB helper (Windows).
rem Connects to the router adbd over br-lan, then lists transports.
rem
rem Change the port here if /data/adb-wifi/config uses another value
rem (ADB_WIFI_PORT, default 15555).
rem ---------------------------------------------------------------
set "ADB_HOST=192.168.0.1"
set "ADB_PORT=15555"
set "ADB_SERIAL=%ADB_HOST%:%ADB_PORT%"

where adb >nul 2>nul
if errorlevel 1 (
  echo [adb-wifi] adb not found in PATH.
  echo [adb-wifi] install Android platform-tools or open this from a shell where adb works.
  goto :done
)

echo [adb-wifi] adb connect %ADB_SERIAL%
adb connect %ADB_SERIAL%
if errorlevel 1 (
  echo [adb-wifi] connect failed.
  echo [adb-wifi] on the router: /data/adb-wifi/adb-wifi.sh status
  echo [adb-wifi] see adb-wifi\README.md - troubleshooting
)

echo.
adb devices -l
echo.
echo [adb-wifi] USB and wireless can show up with the SAME serial.
echo [adb-wifi] pin the target, otherwise adb says "more than one device":
echo     adb -s %ADB_SERIAL% shell
echo     set ANDROID_SERIAL=%ADB_SERIAL%
echo.
echo [adb-wifi] done. run adb-wifi\disconnect.cmd when finished.
echo.

:done
rem Never leave a failing code in the interactive prompt.
exit /b 0
