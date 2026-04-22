@echo off
echo ============================================
echo  iPhone Cam - Windows Setup
echo ============================================
echo.

REM ── Python deps ─────────────────────────────────────────────
echo [1/3] Installing Python dependencies...
pip install -r "%~dp0..\windows\requirements.txt"
if errorlevel 1 (
    echo ERROR: pip install failed. Make sure Python 3.10+ is installed.
    pause
    exit /b 1
)
echo       Done.
echo.

REM ── ffmpeg check ────────────────────────────────────────────
echo [2/3] Checking ffmpeg...
where ffmpeg >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ffmpeg not found. Install it:
    echo  1. Go to: https://www.gyan.dev/ffmpeg/builds/
    echo  2. Download "ffmpeg-release-essentials.zip"
    echo  3. Extract to C:\ffmpeg
    echo  4. Add C:\ffmpeg\bin to your system PATH:
    echo     Settings > System > About > Advanced system settings
    echo     > Environment Variables > Path > New > C:\ffmpeg\bin
    echo.
    echo  Then close and reopen this window and run setup again.
    pause
    exit /b 1
) else (
    echo       ffmpeg found: OK
)
echo.

REM ── OBS check ───────────────────────────────────────────────
echo [3/3] OBS Virtual Camera...
echo.
echo  Make sure OBS Studio is installed (needed for virtual camera driver):
echo  https://obsproject.com/
echo.
echo  OBS does NOT need to be running during use.
echo  Just install it once to register the virtual camera driver.
echo.
echo ============================================
echo  Setup complete!
echo.
echo  To start receiving your iPhone camera:
echo    cd windows
echo    start.bat
echo    (enter your iPhone IP when prompted)
echo ============================================
echo.
pause
