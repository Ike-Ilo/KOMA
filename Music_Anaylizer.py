
import sys
import key_detection
import bpm_detection as bpm
import audio_input

def rec_audio(self):
    audio = audio_input.RecordAudio()
    audio_recording = audio.recAudio()
    sample_rate = audio.sample_rate()
    self.audio_recording = audio_recording
    self.sample_rate = sample_rate
    
def find_bpm(audio):    
    find_bpm = bpm.BPM().detect_BPM(audio, 44100)
    find_bpm = find_bpm[0]
    find_bpm = "{:.3f}".format(find_bpm)
    print("BPM analysis input shape")
    return find_bpm

def find_keysig(audio):
    # Identifying the key signature
    key_sig = key_detection.Key_Detection().detect_keySignature(audio)
    key, scale, strength = key_sig
    strength = strength * 100
    strength = "{:.2f}%".format(strength)
    print("🧠 Key analysis input shape:")
    return key,scale,strength        
