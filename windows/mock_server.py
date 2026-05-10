import subprocess
import threading
import time

def run_video_server():
    print("Starting mock video server on 4747...")
    # Generate test pattern, encode to h264, serve over TCP
    cmd = [
        "ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=44100", # unused in video
        "-vcodec", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p",
        "-f", "h264", "tcp://127.0.0.1:4747?listen"
    ]
    subprocess.run(cmd, stderr=subprocess.DEVNULL)

def run_audio_server():
    print("Starting mock audio server on 4748...")
    # Generate 1kHz sine wave, raw PCM s16le, serve over TCP
    cmd = [
        "ffmpeg", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
        "-acodec", "pcm_s16le", "-f", "s16le", "-ac", "1", "-ar", "44100",
        "tcp://127.0.0.1:4748?listen"
    ]
    subprocess.run(cmd, stderr=subprocess.DEVNULL)

if __name__ == "__main__":
    t1 = threading.Thread(target=run_video_server, daemon=True)
    t2 = threading.Thread(target=run_audio_server, daemon=True)
    t1.start()
    t2.start()
    
    print("Mock servers running. Press Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("Done.")
