import pygame
import sys
import os

pygame.init()
pygame.mixer.pre_init(frequency=44100, size=16, channels= 2, buffer=512)
pygame.mixer.init()

class PianoSound:
    def __init__(self):
        notes = ["C4", "C#4", "D4", "D#4", "E4", "F4", "F#4", "G4", "G#4", "A4", "A#4", "B4"]
        self.notes = notes
    
    def channel(self):
        channel = pygame.mixer.Channel(0)
        return channel         

    def piano_keys(self):
        white_keys = [n for n in self.notes if "#" not in n] #naturals
        black_keys = [n for n in self.notes if "#" in n] #accidentals 
        return white_keys, black_keys
    
    def piano_sounds(self):

        sounds = {}
        sound_path = "sounds"
        for note in self.notes:
            sound_file = os.path.join(sound_path, f"{note}.wav")
            if os.path.exists(sound_file):
                try:
                    sounds[note] = pygame.mixer.Sound(sound_file)
                    sounds[note].set_volume(1.0)
                except Exception as e:
                    print(f"Error loading {note}: {e}")
                    sounds[note] = None
            else: 
                print(f"Sound file not found: {sound_file}")
                sounds[note] = None
        return sounds
            