import pygame
import sys
import os
import Piano_sound as ps
import Music_Anaylizer
import threading

class MA_GUI:
    def piano_gui():
        psound = ps.PianoSound()
        analyzer = Music_Anaylizer.Music_Analyzer()
        pygame.init()
        pygame.mixer.pre_init(frequency=44100, size=16, channels= 2, buffer=512)
        pygame.mixer.init()

        
        SCREEN_WIDTH = 800
        SCREEN_HEIGHT = 600
    
        
        # WHITE = (255, 255, 255)
        # BLACK = (0, 0 ,0)
        # GREY = (200, 200, 200)
        # DARK_GREY = (50, 50, 50)
        # RED = (255, 0 ,0)
        
        
        screen = pygame.display.set_mode((SCREEN_WIDTH,SCREEN_HEIGHT))
        pygame.display.set_caption('Konekt Music Analyzer')
        
        white_key_width = 50
        white_key_height = 180
        black_key_width = 30
        black_key_height = 120

        start_x = 50
        piano_y = SCREEN_HEIGHT - white_key_height - 50

        keys = []
        white_x = start_x
        
        black_positions = {
            "C#4": white_key_width*0.7, 
            "D#4": white_key_width*1.7,
            "F#4": white_key_width*3.7, 
            "G#4": white_key_width*4.7,
            "A#4": white_key_width*5.7
            }

        white_keys, black_keys = psound.piano_keys()
        
        for note in white_keys:
            rect = pygame.Rect(white_x, piano_y, white_key_width, white_key_height)
            keys.append({"note": note, 
                         "rect": rect, 
                         "color": (255,255,255), 
                         "base_color":(255,255,255),
                         "pressed_color": (200,200,200),
                         "is_pressed": False
            })
            white_x += white_key_width
            
        for note in black_keys:
            if note in black_positions:
                offset = black_positions[note]
                rect = pygame.Rect(start_x + offset, piano_y, black_key_width, black_key_height)
                keys.append({"note": note, 
                            "rect": rect, 
                            "color": (0,0,0), 
                            "base_color":(0,0,0),
                            "pressed_color": (50,50,50), 
                            "is_pressed": False
                            })
        
        font_large = pygame.font.SysFont(None,48)
        font_medium = pygame.font.SysFont(None,36)
        
        keysig = "None"
        scale = "None"
        strength = 0
        bpm = 0
        rec_botton_rect = pygame.Rect(SCREEN_WIDTH // 2 - 60, SCREEN_HEIGHT // 2 + 40, 120, 40)
        recording = False
        analysis_ready = False  
         
        def start_recording():
            nonlocal keysig, scale, strength, bpm, analysis_ready
            print("Recording started...")
            analyzer.rec_audio()
            print("Recording finished.")
            key_signature = analyzer.find_keysig()
            keysig, scale, strength = key_signature
            bpm = analyzer.find_bpm()
            print(f"Analysis complete. Key: {keysig, scale}, Strength {strength}, BPM: {bpm}")
            analysis_ready = True

        

        
        def recording_toggle():
            nonlocal recording
            if not recording:
                recording = True
                analysis_ready = False
                thread = threading.Thread(target=start_recording)
                thread.start()
            else:
                print("Recording in progress.")
        
        running = True
        while running:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False
                
                if event.type == pygame.MOUSEBUTTONDOWN:
                    pos = pygame.mouse.get_pos()
                    
                    if rec_botton_rect.collidepoint(pos):
                        recording_toggle()
                        
                    for key in sorted(keys, key=lambda k: k["base_color"][0]):
                        if key["rect"].collidepoint(pos):
                            key["is_pressed"] = True
                            key ["color"] = key["pressed_color"]
                            s = psound.piano_sounds()
                            sound = s.get(key["note"])
                            if sound:
                                psound.channel().play(sound)
                            else: 
                                print(f"No sound assigned to {key['note']}")
                            break
                
                if event.type == pygame.MOUSEBUTTONUP:
                    for key in keys:
                        if key["is_pressed"]:
                            key["is_pressed"] = False
                            key["color"] = key["base_color"]
                    
            screen.fill((220,220,220))
            
            bpm_text = font_large.render(f"BPM {bpm}", True, (0, 0, 0))
            screen.blit(bpm_text, (SCREEN_WIDTH - 200, 20))
            
            key_sig_display = f"Key Signature: {keysig, scale}, Strength {strength}" if analysis_ready else "Key signature is pending"
            key_sig_text = font_medium.render(key_sig_display, True, (0, 0 ,0))
            key_sig_rect = key_sig_text.get_rect(center = (SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2 - 40))
            screen.blit(key_sig_text, key_sig_rect)
            
            for key in [k for k in keys if k["base_color"] == (255,255,255)]:
                pygame.draw.rect(screen, key["color"], key["rect"])
                pygame.draw.rect(screen, (0,0,0), key["rect"], 2)
                
            for key in [k for k in keys if k["base_color"] == (0,0,0)]:
                pygame.draw.rect(screen, key["color"], key["rect"])
                pygame.draw.rect(screen, (0,0,0), key["rect"], 2)
                
            record_color = (255, 0, 0) if recording and not analysis_ready else (100, 100, 100)
            pygame.draw.rect(screen, record_color, rec_botton_rect)
            rec_text_label = "Recording" if recording and not analysis_ready else "Record"
            record_text = font_medium.render(rec_text_label, True, (255, 255, 255))
            record_text_rect = record_text.get_rect(center=rec_botton_rect.center)
            screen.blit(record_text, record_text_rect)
            
            pygame.display.flip()
            
        pygame.quit()
        sys.exit()
        
    piano_gui()
                