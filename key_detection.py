"""
Key Detection Module
====================

This module provides functionality for detecting the musical key and key signature
of an audio signal using `librosa`, `numpy`, and `essentia`.

Classes
-------
Key_Detection
    A class that offers methods to detect the key and key signature from an audio array.

Dependencies
------------
- librosa: Python library for analyzing audio and music.
- numpy: Python library for numerical computations.
- essentia: Library for audio analysis and audio-based music information retrieval.

Example Usage
-------------
# Initialize the key detector
key_detector = Key_Detection()

# Detect key using chroma features
key = key_detector.detect_key(audio, sample_rate)
print(f"Detected key: {key}")

# Detect key signature using Essentia
key, scale, strength = key_detector.detect_keySignature(audio)
print(f"Key: {key}, Scale: {scale}, Confidence: {strength}")
"""

import librosa
import numpy as np
# import essentia
import essentia.standard as es

class Key_Detection:
    """
    A class for detecting the musical key and key signature of an audio signal.

    Methods
    -------
    detect_key(audio, sample_rate):
        Detects the musical key of the input audio using chroma features and returns
        the most prominent pitch class.

    detect_keySignature(audio):
        Uses Essentia's KeyExtractor algorithm to identify the key signature (key,
        scale, and confidence strength) of the audio.
    """
    
    def detect_key(self, audio, sample_rate):
        """
        Detect the musical key of an audio signal based on chroma feature analysis.

        This method:
        1. Computes the Constant-Q chromagram of the audio using `librosa`.
        2. Sums the chroma energy across time for each pitch class.
        3. Identifies the pitch class (key) with the highest energy.

        Parameters
        ----------
        audio : numpy.ndarray
            The audio signal as a 1D NumPy array.
        
        sample_rate : int
            The sampling rate of the audio signal (in Hz).

        Returns
        -------
        detected_key : str
            The detected musical key, represented by its pitch class (e.g., 'C', 'D#', 'A').
        
        Notes
        -----
        - This method does not distinguish between major and minor scales.
        - It provides a basic key estimation based on pitch class energy.
        """
        chroma = librosa.feature.chroma_cqt(y=audio, sr=(sample_rate))

        chroma_sums = np.sum(chroma,axis=1)

        key_index = np.argmax(chroma_sums)


        keys = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
        detected_key = keys[key_index]

        return detected_key
    
    def detect_keySignature(self,audio):
        """
        Detect the key signature of an audio signal using Essentia's KeyExtractor algorithm.

        This method:
        1. Uses Essentia's `KeyExtractor` to analyze the audio signal.
        2. Returns the detected key, scale (major or minor), and confidence strength.

        Parameters
        ----------
        audio : numpy.ndarray
            The audio signal as a 1D NumPy array.

        Returns
        -------
        key : str
            The detected key (e.g., 'C', 'D#').

        scale : str
            The scale type ('major' or 'minor').

        strength : float
            A confidence score (typically between 0.0 and 1.0) indicating the reliability of the detection.

        Notes
        -----
        - Essentia's `KeyExtractor` uses a trained model based on pitch class profiles
          and works well with Western tonal music.
        - The strength value can be used to filter out low-confidence detections.
        """
        key_extractor = es.KeyExtractor()
        key, scale, strength = key_extractor(audio)
        return key, scale, strength
        
        