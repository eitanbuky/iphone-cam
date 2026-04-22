@echo off
setlocal

if "%~1"=="" (
    set /p IPHONE_IP="Enter iPhone IP address: "
) else (
    set IPHONE_IP=%~1
)

echo.
echo Starting iPhone Cam receiver for %IPHONE_IP%...
echo.
python "%~dp0receiver.py" %IPHONE_IP%

pause
