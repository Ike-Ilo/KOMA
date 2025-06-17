import pygame
import sys
import os
import piano_sound as ps
import Music_Anaylizer

def piano():
    psound = ps.PianoSound()
    analyzer = Music_Anaylizer.Music_Analyzer()
    pygame.init()
    pygame.mixer.pre_init(frequency=44100, size=16, channels= 2, buffer=512)
    pygame.mixer.init()
    # Screen setup
    screen_width = 800
    screen_height = 600
    screen = pygame.display.set_mode((screen_width, screen_height))
    pygame.display.set_caption('Virtual Piano with Recorder')

    # Notes
    notes = ["C4", "C#4", "D4", "D#4", "E4", "F4", "F#4", "G4", "G#4", "A4", "A#4", "B4"]
    white_keys = [n for n in notes if "#" not in n]
    black_keys = [n for n in notes if "#" in n]

    # Sounds loading
    sounds = {}
    sound_path = "sounds"
    for note in notes:
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

    channel = pygame.mixer.Channel(0)

    # UI Elements
    white_key_width = 50
    white_key_height = 180
    black_key_width = 30
    black_key_height = 120

    start_x = 50
    piano_y = screen_height - white_key_height - 50
    keys = []
    white_x = start_x

    black_positions = {
        "C#4": white_key_width * 0.7,
        "D#4": white_key_width * 1.7,
        "F#4": white_key_width * 3.7,
        "G#4": white_key_width * 4.7,
        "A#4": white_key_width * 5.7
    }

    # Create white keys
    for note in white_keys:
        rect = pygame.Rect(white_x, piano_y, white_key_width, white_key_height)
        keys.append({
            "note": note,
            "rect": rect,
            "color": (255, 255, 255),
            "base_color": (255, 255, 255),
            "pressed_color": (200, 200, 200),
            "is_pressed": False
        })
        white_x += white_key_width

    # Create black keys
    for note in black_keys:
        if note in black_positions:
            offset = black_positions[note]
            rect = pygame.Rect(start_x + offset, piano_y, black_key_width, black_key_height)
            keys.append({
                "note": note,
                "rect": rect,
                "color": (0, 0, 0),
                "base_color": (0, 0, 0),
                "pressed_color": (50, 50, 50),
                "is_pressed": False
            })

    # Fonts
    font_large = pygame.font.SysFont(None, 48)
    font_medium = pygame.font.SysFont(None, 36)

    # audio_rec = analyzer.rec_audio()
    key_signature = analyzer.find_keysig()
    bpm = analyzer.find_bpm()

    # Record button setup
    record_button_rect = pygame.Rect(screen_width // 2 - 60, screen_height // 2 + 40, 120, 40)
    recording = False

    def toggle_recording():
        nonlocal recording
        recording = not recording
        if recording:
            audio_rec
            print("Recording started...")
        else:
            print("Recording stopped. Audio saved!")  # Here, you can implement saving the actual recording.

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False

            if event.type == pygame.MOUSEBUTTONDOWN:
                pos = pygame.mouse.get_pos()

                # Record button clicked
                if record_button_rect.collidepoint(pos):
                    toggle_recording()

                # Piano key press detection
                for key in sorted(keys, key=lambda k: k["base_color"][0]):
                    if key["rect"].collidepoint(pos):
                        key["is_pressed"] = True
                        key["color"] = key["pressed_color"]
                        sound = sounds.get(key["note"])
                        if sound:
                            channel.play(sound)
                            print(f"Playing {key['note']}")
                        else:
                            print(f"No sound assigned to {key['note']}")
                        break

            if event.type == pygame.MOUSEBUTTONUP:
                for key in keys:
                    if key["is_pressed"]:
                        key["is_pressed"] = False
                        key["color"] = key["base_color"]

        screen.fill((220, 220, 220))

        # BPM display (top right)
        bpm_text = font_large.render(f"BPM: {bpm}", True, (0, 0, 0))
        screen.blit(bpm_text, (screen_width - 200, 20))

        # Key Signature display (center middle)
        key_sig_text = font_medium.render(f"Key Signature: {key_signature}", True, (0, 0, 0))
        key_sig_rect = key_sig_text.get_rect(center=(screen_width // 2, screen_height // 2 - 40))
        screen.blit(key_sig_text, key_sig_rect)

        # Draw piano white keys
        for key in [k for k in keys if k["base_color"] == (255, 255, 255)]:
            pygame.draw.rect(screen, key["color"], key["rect"])
            pygame.draw.rect(screen, (0, 0, 0), key["rect"], 2)

        # Draw piano black keys
        for key in [k for k in keys if k["base_color"] == (0, 0, 0)]:
            pygame.draw.rect(screen, key["color"], key["rect"])
            pygame.draw.rect(screen, (0, 0, 0), key["rect"], 2)

        # Record button drawing
        record_color = (255, 0, 0) if recording else (100, 100, 100)
        pygame.draw.rect(screen, record_color, record_button_rect)
        record_text = font_medium.render("Record", True, (255, 255, 255))
        record_text_rect = record_text.get_rect(center=record_button_rect.center)
        screen.blit(record_text, record_text_rect)

        pygame.display.flip()

    pygame.quit()
    sys.exit()

piano()
