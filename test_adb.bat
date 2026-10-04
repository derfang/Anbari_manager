@echo off
title ADB Hotspot Auto-Connect
echo ==========================================
echo    ADB Hotspot Auto-Connect Script
echo ==========================================
echo.
echo Please ensure your phone is plugged in via USB
echo and your PC is connected to the phone's hotspot.
echo.

echo.
echo [1/4] Disconnecting old ADB sessions...
adb disconnect

echo [2/4] Enabling TCP mode on USB device...
:: -d forces ADB to use the physical USB device, preventing "more than one device" errors
adb -d tcpip 5555
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Could not find your phone via USB. 
    echo Please make sure it is plugged in and USB debugging is allowed.
    exit /b
)

echo Waiting 3 seconds for port to open...
timeout /t 3 /nobreak >nul

echo [3/4] Finding Hotspot IP Address...
:: This PowerShell command grabs the Default Gateway IP of your primary active internet connection (the hotspot)
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object NextHop -ne '0.0.0.0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop"') do set PHONE_IP=%%i

if "%PHONE_IP%"=="" (
    echo.
    echo ERROR: Could not find your Hotspot IP address. 
    echo Are you connected to the hotspot?
    exit /b
)

echo Found Phone IP: %PHONE_IP%

echo [4/4] Connecting over Wi-Fi...
adb connect %PHONE_IP%:5555

echo.
echo ==========================================
echo   SUCCESS! You can unplug the USB now.
echo ==========================================
