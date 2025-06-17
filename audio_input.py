"""
Audio Recording Module
======================

This module provides a simple class for recording audio from an input device
using the `sounddevice` library and processes the audio data for further analysis.

Classes:
--------
RecordAudio
    A class that handles audio recording with a fixed sample rate and normalization
    of the recorded audio.

Dependencies:
-------------
- sounddevice (as sd): Provides audio input/output capabilities.
- numpy (as np): Used for array manipulation and normalization of audio data.

Example Usage:
--------------
# Create a recorder instance
recorder = RecordAudio()

# Record audio for the specified duration
audio_data = recorder.recAudio()

# Get the sample rate used for recording
sample_rate = recorder.sample_rate()

Notes:
------
- Make sure the microphone or input device is properly configured on your system.
- Requires the `sounddevice` and `numpy` packages.
"""

import sounddevice as sd
import numpy as np


class RecordAudio:
    """
    A class for recording and processing audio input.

    Attributes
    ----------
    SAMPLE_RATE : int
        The sample rate in Hz used for recording audio. Default is 44100 Hz.

    Methods
    -------
    recAudio():
        Records a 5-second audio clip and returns a normalized NumPy array of the audio samples.
    
    sample_rate():
        Returns the sample rate used for recording.
    """
    def __init__ (self):
        """
        Initializes the RecordAudio class with a default sample rate.

        Parameters
        ----------
        None
        """
        SAMPLE_RATE = 44100
        self.SAMPLE_RATE = SAMPLE_RATE

    def recAudio(self):
        """
        Records audio for a fixed duration and normalizes the audio signal.

        This method:
        1. Records audio for a duration of 5 seconds using the system's default microphone.
        2. Flattens the multi-dimensional array to a 1D array.
        3. Normalizes the audio signal so that its maximum absolute value is 1.0.

        Returns
        -------
        audio : numpy.ndarray
            A 1D NumPy array of normalized float32 audio samples.

        Notes
        -----
        - The audio is recorded in mono (single channel).
        - Normalization ensures consistent volume scaling for analysis or playback.
        """
        DURATION = 5
        print("recording...")
        audio = sd.rec(int(DURATION * self.SAMPLE_RATE), samplerate=self.SAMPLE_RATE, channels=1, dtype='float32')
        sd.wait()
        audio = audio.flatten()
        audio = audio /np.max(np.abs(audio))

        return audio
    
    def sample_rate(self):
        """
        Returns the sample rate used for audio recording.

        Returns
        -------
        int
            The sample rate in Hz.
        """
        return self.SAMPLE_RATE
