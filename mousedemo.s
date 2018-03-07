;
;  mousedemo.s
;  Mouse driver sample application
;
;  Created by Quinn Dunki on 7/14/15.
;  Copyright (c) 2015 One Girl, One Laptop Productions. All rights reserved.
;


.org $6000

COUT			= $fded
PRBYTE			= $fdda


main:	; BRUN lands here

	jsr WGEnableMouse

loop:
	; Print current mouse position
	lda #'X' + $80
	jsr COUT
	lda #'=' + $80
	jsr COUT

	lda WG_MOUSEPOS_X
	jsr PRBYTE

	lda #' ' + $80
	jsr COUT
	lda #'Y' + $80
	jsr COUT
	lda #'=' + $80
	jsr COUT

	lda WG_MOUSEPOS_Y
	jsr PRBYTE

	lda WG_MOUSECLICK_X
	bmi lineDone
	lda #' ' + $80
	jsr COUT
	lda #'!' + $80
	jsr COUT
	lda #$ff
	sta WG_MOUSECLICK_X

lineDone:
	lda #13 + $80
	jsr COUT

	; Check for any key to quit
	lda KBD
	bpl loop			; No key pending

	; Clean up and return to BASIC
	sta KBDSTRB			; Clear strobe

	jsr WGDisableMouse
	rts
	


.include "mouse.s"


; Suppress some linker warnings - Must be the last thing in the file
; This is because Quinn doesn't really know how to use ca65 properly
.SEGMENT "ZPSAVE"
.SEGMENT "EXEHDR"
.SEGMENT "STARTUP"
.SEGMENT "INIT"
.SEGMENT "LOWCODE"
.SEGMENT "ONCE"
