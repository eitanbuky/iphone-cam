"""
iPhone Cam - Windows Receiver
Connects to the iPhone app, decodes the H.264 stream via ffmpeg,
and pushes frames into a virtual camera (OBS Virtual Camera).

Usage:
    python receiver.py <IPHONE_IP>
    python receiver.py 192.168.1.42
"""

import sys
import os
import json
import time
import subprocess
import threading
import shutil
import numpy as np

# Find ffmpeg — check PATH first, then known winget install location
def find_ffmpeg():
    if shutil.which("ffmpeg"):
        return "ffmpeg"
    winget_path = os.path.expandvars(
        r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1-full_build\bin\ffmpeg.exe"
    )
    if os.path.exists(winget_path):
        return winget_path
    return None

def find_ffprobe():
    if shutil.which("ffprobe"):
        return "ffprobe"
    winget_path = os.path.expandvars(
        r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1-full_build\bin\ffprobe.exe"
    )
    if os.path.exists(winget_path):
        return winget_path
    return None

FFMPEG = find_ffmpeg()
FFPROBE = find_ffprobe()

try:
    import pyvirtualcam
except ImportError:
    print("[ERROR] pyvirtualcam not installed. Run: pip install -r requirements.txt")
    sys.exit(1)

PORT = 4747

# ── Resolution detection ─────────────────────────────────────────────────────

def detect_stream_info(ip: str, port: int, timeout: int = 60) -> tuple[int, int, float]:
    """Run ffprobe against the iPhone stream and return (width, height, fps)."""
    print(f"[Probe] Connecting to {ip}:{port} (waiting up to {timeout}s for iPhone app)...")
    if not FFPROBE:
        print("[ERROR] ffprobe not found. Open a new terminal so PATH updates take effect.")
        sys.exit(1)

    ffprobe = FFPROBE  # narrowed to str for type checker

    try:
        result = subprocess.run(
            [
                ffprobe,
                "-v", "quiet",
                "-print_format", "json",
                "-show_streams",
                "-timeout", str(timeout * 1_000_000),  # microseconds
                f"tcp://{ip}:{port}",
            ],
            capture_output=True,
            timeout=timeout + 5,
        )
    except subprocess.TimeoutExpired:
        print("[ERROR] Timed out waiting for iPhone. Is the app running and on the same WiFi?")
        sys.exit(1)
    except FileNotFoundError:
        print("[ERROR] ffmpeg/ffprobe not found. Install from https://www.gyan.dev/ffmpeg/builds/")
        sys.exit(1)

    try:
        info = json.loads(result.stdout)
        video = next(s for s in info["streams"] if s["codec_type"] == "video")
        w = int(video["width"])
        h = int(video["height"])
        num, den = video["r_frame_rate"].split("/")
        fps = float(num) / float(den)
        print(f"[Probe] Detected stream: {w}x{h} @ {fps:.1f}fps")
        return w, h, fps
    except Exception as e:
        print(f"[ERROR] Could not parse stream info: {e}")
        print(f"        ffprobe stderr: {result.stderr.decode()[:500]}")
        sys.exit(1)


# ── Main receive loop ─────────────────────────────────────────────────────────

def receive(ip: str):
    w, h, fps = detect_stream_info(ip, PORT)
    fps_int = max(1, round(fps))
    frame_bytes = w * h * 3  # BGR24

    print(f"\n[Camera] Starting virtual camera: {w}x{h} @ {fps_int}fps")
    print(f"[Camera] Look for 'OBS Virtual Camera' in Zoom / Teams / OBS\n")

    if not FFMPEG:
        print("[ERROR] ffmpeg not found. Open a new terminal so PATH updates take effect.")
        sys.exit(1)

    assert FFMPEG is not None
    ffmpeg: str = FFMPEG
    ffmpeg_cmd: list[str] = [
        ffmpeg,
        "-loglevel", "error",
        "-f", "h264",
        "-i", f"tcp://{ip}:{PORT}",
        "-f", "rawvideo",
        "-pix_fmt", "bgr24",
        "pipe:1",
    ]

    proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    # Print ffmpeg errors in background
    def log_errors():
        for line in proc.stderr:
            print(f"[ffmpeg] {line.decode().strip()}")
    threading.Thread(target=log_errors, daemon=True).start()

    frame_count = 0
    t_start = time.time()

    try:
        with pyvirtualcam.Camera(width=w, height=h, fps=fps_int, fmt=pyvirtualcam.PixelFormat.BGR) as cam:
            print(f"[Camera] Device: {cam.device}")
            while True:
                raw = proc.stdout.read(frame_bytes)
                if len(raw) < frame_bytes:
                    print("\n[Camera] Stream ended (iPhone disconnected?)")
                    break

                frame = np.frombuffer(raw, dtype=np.uint8).reshape((h, w, 3))
                cam.send(frame)

                frame_count += 1
                elapsed = time.time() - t_start
                if frame_count % 150 == 0:
                    print(f"[Camera] Running — {frame_count} frames, avg {frame_count/elapsed:.1f}fps")

    except pyvirtualcam.CameraError as e:
        print(f"\n[ERROR] Virtual camera error: {e}")
        print("        Make sure OBS Studio is installed (obsproject.com)")
        print("        OBS does NOT need to be running, just installed once.")
    except KeyboardInterrupt:
        print("\n[Camera] Stopped by user.")
    finally:
        proc.terminate()


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 2:
        ip = input("Enter iPhone IP address (shown in the app): ").strip()
    else:
        ip = sys.argv[1]

    if not ip:
        print("No IP provided.")
        sys.exit(1)

    print(f"\n iPhone Cam Receiver")
    print(f" Target: {ip}:{PORT}")
    print(f" Make sure the iPhone app is open and on the same WiFi\n")

    receive(ip)
