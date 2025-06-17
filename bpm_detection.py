import librosa
import audio_input

"""
BPM Detection Module
====================

This module provides functionality for detecting the tempo (beats per minute, BPM)
of an audio signal using the `librosa` library.

Classes
-------
BPM
    A class that contains a method to detect the BPM of an audio signal.

Dependencies
------------
- librosa: Python library for audio and music analysis.
- audio_input: Custom module (assumed to handle audio recording or input processing).

Example Usage
-------------
# Example of how to use the BPM detection class:

import audio_input
from bpm_detection import BPM

# Record or load audio
recorder = audio_input.RecordAudio()
audio = recorder.recAudio()
sample_rate = recorder.sample_rate()

# Initialize BPM detector
bpm_detector = BPM()

# Detect BPM
tempo = bpm_detector.detect_BPM(audio, sample_rate)
print(f"Detected BPM: {tempo}")

Notes
-----
- Ensure your audio input is preprocessed (e.g., mono, normalized) for more accurate BPM detection.
"""
class BPM:
    """
    A class to detect the tempo (beats per minute) of an audio signal.

    Methods
    -------
    detect_BPM(audio, sample_rate):
        Detects and returns the estimated tempo of the provided audio signal in BPM.
    """
    def detect_BPM(self, audio, sample_rate):
        """
        Detect the tempo (BPM) of an audio signal.

        This method uses `librosa`'s `beat_track()` function to analyze the input
        audio signal and estimate its tempo in beats per minute (BPM).

        Parameters
        ----------
        audio : numpy.ndarray
            The audio signal as a 1D NumPy array (mono).
        
        sample_rate : int
            The sampling rate of the audio signal (in Hz).

        Returns
        -------
        tempo : float
            The estimated tempo of the audio in beats per minute (BPM).

        Notes
        -----
        - The `librosa.beat.beat_track()` function returns both tempo and frame positions;
          only the tempo value is used here.
        - Performance may vary based on the quality of the input audio and its rhythmic clarity.
        - Preprocessing the audio (e.g., converting to mono, filtering noise) can improve accuracy.
        """
        tempo, _ = librosa.beat.beat_track(y=audio, sr=sample_rate)
        return tempo