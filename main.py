
# rnd_QOxfiAvxEG8Mh1W559X80qBW77DO

from fastapi import FastAPI, WebSocket, File, UploadFile
from fastapi.responses import JSONResponse
import io
import soundfile as sf
from Music_Anaylizer import find_bpm, find_keysig
import numpy as np
from fastapi import Request, HTTPException, Depends


app = FastAPI()


API_KEY = "your-secret-key"

def verify_api_key(request: Request):
    key = request.headers.get("x-api-key")
    if key != API_KEY:
        raise HTTPException(status_code=403, detail="Unauthorized")

def decode_pcm(pcm_bytes, sample_rate=44100, channels=1):
    
    if not pcm_bytes:
        raise ValueError("Empty audio buffer")
    
    try: 
        audio = np.frombuffer(pcm_bytes, dtype=np.int16)
        if audio.size ==0:
            raise ValueError("Decoded audio buffer is empty")
    except Exception as e:
        raise ValueError(f"Failed to convert buffer: {e}")
    if channels > 1:
        audio = audio.reshape((-1, channels))
    else:
        audio = audio.reshape(-1)
    audio = audio.astype(np.float32) / 32768.0
    if not isinstance(audio, np.ndarray):
        raise TypeError("Decoded audio is not a numpy.ndarray")
    print(f"🔄 Received {len(pcm_bytes)} bytes from Swift")
    return audio, sample_rate

@app.post("analyze")
async def analyze_audio(file: UploadFile = File(...), _: None = Depends(verify_api_key)):
    try:
        audio_bytes = await file.read()
        audio = io.BytesIO(audio_bytes)
        y, sr = sf.read(audio)
        bpm = find_bpm(y, sr)
        key = find_keysig(y, sr)
        return {"bpm": bpm, "key": key, "status": "Detected"}
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})
    

@app.websocket("/ws/audio")
async def websocket_audio(websocket: WebSocket):
    await websocket.accept()
    audio_buffer = bytearray()
    
    SAMPLE_RATE = 44100
    CHANNELS = 1
    SECONDS = 5
    BYTES_PER_SAMPLE = 2
    TARGET_SIZE = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE * SECONDS

    try:
        while True:
            msg = await websocket.receive()

            # 🔁 Handle binary audio data
            if "bytes" in msg:
                audio_buffer.extend(msg["bytes"])

                if len(audio_buffer) >= TARGET_SIZE:
                    try:
                        y, sr = decode_pcm(audio_buffer[:TARGET_SIZE], sample_rate=SAMPLE_RATE, channels=CHANNELS)
                        if not isinstance(y, np.ndarray):
                            raise TypeError("Audio must be a numpy.ndarray")
                        if y.size == 0:
                            raise ValueError("Received empty audio array")

                        print(f"✅ Decoding audio: shape={y.shape}, dtype={y.dtype}")
                        bpm = find_bpm(y)
                        key, scale, strength = find_keysig(y)
                        key_str = f"{key}{scale}"

                        await websocket.send_json({
                            "bpm": bpm,
                            "key": key_str,
                            "strength": f"{strength:.1f}%",
                            "status": "Detected"
                        })

                    except Exception as processing_error:
                        print("❌ Processing error:", processing_error)
                        await websocket.send_json({
                            "bpm": "Unknown",
                            "key": "Unknown",
                            "status": "Error"
                        })

                    # Clear buffer for next cycle
                    audio_buffer.clear()

            # 🛑 Handle "stop" command from client
            elif "text" in msg and msg["text"].strip().lower() == "stop":
                print("🛑 Stop command received. Closing session.")
                await websocket.send_json({
                    "status": "Stopped"
                })
                break

    except Exception as e:
        print("WebSocket session error:", e)
    finally:
        try:
            await websocket.close(code=1000)
        except Exception as e:
            print(f"⚠️ Error during WebSocket close: {e}")





if __name__ == "__main__":
    import os
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8080)
        
