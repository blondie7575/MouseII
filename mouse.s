;
;  mouse.s
;  Mouse driver for Apple //e Enhanced with mouse card (any slot), or Apple //c(+)
;
;  Created by Quinn Dunki on 7/14/15.
;  Copyright (c) 2014 One Girl, One Laptop Productions. All rights reserved.
;


.include "macros.s"
.include "switches.s"


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Mouse clamping values. These are set to a convenient one-byte
; range, but you can change to suit your application. If you
; change them, also change the scaling math below (search for SCALING)
; Hardware produces values 0-1023 in both dimensions if not clamped
SCALE_X_IIE	= $027f	;	640-1
SCALE_Y_IIE	= $02e0	;	736

; //c tracks much slower, so smaller clamps and no scaling works better
SCALE_X_IIC	= $004f	;	8-1
SCALE_Y_IIC	= $0017	;	24-1


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; ProDOS ROM entry points and constants
;
PRODOS_MLI = $bf00

ALLOC_INTERRUPT = $40
DEALLOC_INTERRUPT = $41


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Mouse firmware ROM entry points and constants
;

; These mouse firmware entry points are offsets from the firmware
; entry point of the slot, and also indirect.
SETMOUSE = $12
SERVEMOUSE = $13
READMOUSE = $14
CLEARMOUSE = $15
POSMOUSE = $16
CLAMPMOUSE = $17
HOMEMOUSE = $18
INITMOUSE = $19

MOUSTAT = $0778			; + Slot Num
MOUSE_XL = $0478		; + Slot Num
MOUSE_XH = $0578		; + Slot Num
MOUSE_YL = $04f8		; + Slot Num
MOUSE_YH = $05f8		; + Slot Num
MOUSE_CLAMPL = $04f8	; Upper mouse clamp (LSB). Slot independent.
MOUSE_CLAMPH = $05f8	; Upper mouse clamp (MSB). Slot independent.
MOUSE_ZEROL = $0478		; Zero value of mouse (LSB). Slot independent.
MOUSE_ZEROH = $0578		; Zero value of mouse (MSB). Slot independent.

MOUSTAT_MASK_BUTTONINT = %00000100
MOUSTAT_MASK_VBLINT = %00001000
MOUSTAT_MASK_MOVEINT = %00000010
MOUSTAT_MASK_DOWN = %10000000
MOUSTAT_MASK_WASDOWN = %01000000
MOUSTAT_MASK_MOVED = %00100000

MOUSEMODE_OFF = $00		; Mouse off
MOUSEMODE_PASSIVE = $01	; Passive mode (polling only)
MOUSEMODE_MOVEINT = $03	; Interrupts on movement
MOUSEMODE_BUTINT = $05	; Interrupts on button
MOUSEMODE_COMBINT = $0f	; Interrupts on VBL, movement and button


; Mouse firmware is all indirectly called, because
; it moved around a lot in different Apple II ROM
; versions. This macro helps abstracts this for us.
.macro CALLMOUSE name
	ldx #name
	jsr WGCallMouse
.endmacro



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGEnableMouse
; Prepares the mouse for use
;
WGEnableMouse:
	pha

	SETSWITCH PAGE2OFF

	; Find slot number and calculate the various indirections needed
	jsr WGFindMouse
	bcs WGEnableMouse_Error

	; Note if we're a //e or //c, because mouse tracking and interrupts are different
	lda $fbb3
	cmp #$06
	bne WGEnableMouse_Error		; II or II+? Sorry...
	lda $fbc0
	bne WGEnableMouse_IIe
	lda #1
	sta WG_APPLEIIC

WGEnableMouse_IIe:
	; Install our interrupt handler via ProDOS (play nice!)
	jsr PRODOS_MLI
	.byte ALLOC_INTERRUPT
	.addr WG_PRODOS_ALLOC
	bne WGEnableMouse_Error		; ProDOS will return here with Z clear on error

	; Initialize the mouse
	stz WG_MOUSEPOS_X
	stz WG_MOUSEPOS_Y
	stz WG_MOUSEBG

	CALLMOUSE INITMOUSE
	bcs WGEnableMouse_Error	; Firmware sets carry if mouse is not available

	CALLMOUSE CLEARMOUSE

	lda #MOUSEMODE_COMBINT		; Enable combination interrupt mode
	CALLMOUSE SETMOUSE

	; Set the mouse's zero postion to (1,1), since we're in text screen space
	stz MOUSE_ZEROH
	lda #0
	sta MOUSE_ZEROL
	lda #1
	CALLMOUSE CLAMPMOUSE
	lda #0
	CALLMOUSE CLAMPMOUSE

	; Scale the mouse's range into something easy to do math with,
	; while retaining as much range of motion and precision as possible
	lda WG_APPLEIIC
	bne WGEnableMouse_ConfigIIc		; Sorry //c, no scaling for you

	lda #<SCALE_X_IIE
	sta MOUSE_CLAMPL
	lda #>SCALE_X_IIE
	sta MOUSE_CLAMPH
	lda #0
	CALLMOUSE CLAMPMOUSE

	lda #<SCALE_Y_IIE
	sta MOUSE_CLAMPL
	lda #>SCALE_Y_IIE
	sta MOUSE_CLAMPH
	lda #1
	CALLMOUSE CLAMPMOUSE
	bra WGEnableMouse_Activate

WGEnableMouse_Error:
	stz WG_MOUSEACTIVE

WGEnableMouse_done:			; Exit point here for branch range
	pla
	rts

WGEnableMouse_ConfigIIc:	; //c's tracking is weird. Need to clamp to a much smaller range
	lda #<SCALE_X_IIC
	sta MOUSE_CLAMPL
	lda #>SCALE_X_IIC
	sta MOUSE_CLAMPH
	lda #0
	CALLMOUSE CLAMPMOUSE

	lda #<SCALE_Y_IIC
	sta MOUSE_CLAMPL
	lda #>SCALE_Y_IIC
	sta MOUSE_CLAMPH
	lda #1
	CALLMOUSE CLAMPMOUSE

WGEnableMouse_Activate:
	lda #1
	sta WG_MOUSEACTIVE

	cli					; Once all setup is done, it's safe to enable interrupts
	bra WGEnableMouse_done



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGDisableMouse
; Shuts off the mouse when we're done with it
;
WGDisableMouse:
	pha

	SETSWITCH PAGE2OFF

	lda WG_MOUSEACTIVE			; Never activated the mouse
	beq WGDisableMouse_done

	lda MOUSEMODE_OFF
	CALLMOUSE SETMOUSE

	stz WG_MOUSEACTIVE

	lda #MOUSEMODE_OFF			; Disable VBL manually
	CALLMOUSE SETMOUSE

	; Remove our interrupt handler via ProDOS (done playing nice!)
	lda WG_PRODOS_ALLOC+1		; Copy interrupt ID that ProDOS gave us
	sta WG_PRODOS_DEALLOC+1

	jsr PRODOS_MLI
	.byte DEALLOC_INTERRUPT
	.addr WG_PRODOS_DEALLOC

	jsr WGUndrawPointer			; Be nice if we're disabled during a program

WGDisableMouse_done:
	pla
	rts


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGCallMouse
; Calls a mouse firmware routine. Here's where we handle all
; the layers of indirection needed to call mouse firmware. The
; firmware moved in ROM several times over the life of the
; Apple II, so it's kind of a hassle to call it.
; X: Name of routine (firmware offset constant)
; Side effects: Clobbers all registers
WGCallMouse:
	stx WGCallMouse+4	; Use self-modifying code to smooth out some indirection

	; This load address is overwritten by the above code, AND by the mouse set
	; up code, to make sure we have the right slot entry point and firmware
	; offset
	ldx $c400			; Self-modifying code!
	stx WG_MOUSE_JUMPL	; Get low byte of final jump from firmware

	php					; Note that mouse firmware is not re-entrant,
	sei					; so we must disable interrupts inside them

	jsr WGCallMouse_redirect
	plp					; Restore interrupts to previous state
	rts

WGCallMouse_redirect:
	ldx WG_MOUSE_JUMPH
	ldy WG_MOUSE_SLOTSHIFTED
	jmp (WG_MOUSE_JUMPL)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGFindMouse
; Figures out which slot (//e) or port (//c) the mouse is in.
; It moved around a lot over the years. Sets it to 0 if no mouse
; could be found
; OUT C: Set if no mouse could be found
WGFindMouse:
	SAVE_AX

	ldx #7

WGFindMouse_loop:
	txa							; Compute slot firmware locations for this loop
	ora #$c0
	sta WGFindMouse_loopModify+2		; Self-modifying code!
	sta WGFindMouse_loopModify+9
	sta WGFindMouse_loopModify+16
	sta WGFindMouse_loopModify+23
	sta WGFindMouse_loopModify+30

WGFindMouse_loopModify:
	; Check for the magic 5-byte pattern that gives away the mouse card
	lda $c005					; These addresses are modified in place on
	cmp #$38					; each loop iteration
	bne WGFindMouse_nextSlot
	lda $c007
	cmp #$18
	bne WGFindMouse_nextSlot
	lda $c00b
	cmp #$01
	bne WGFindMouse_nextSlot
	lda $c00c
	cmp #$20
	bne WGFindMouse_nextSlot
	lda $c0fb
	cmp #$d6
	bne WGFindMouse_nextSlot
	bra WGFindMouse_found

WGFindMouse_nextSlot:
	dex
	bmi WGFindMouse_none
	bra WGFindMouse_loop

WGFindMouse_found:
	; Found it! Now configure all our indirection lookups
	stx WG_MOUSE_SLOT
	lda #$c0
	ora WG_MOUSE_SLOT
	sta WG_MOUSE_JUMPH
	sta WGCallMouse+5			; Self-modifying code!
	txa
	asl
	asl
	asl
	asl
	sta WG_MOUSE_SLOTSHIFTED
	clc
	bra WGFindMouse_done

WGFindMouse_none:
	stz WG_MOUSE_SLOT
	sec

WGFindMouse_done:
	RESTORE_AX
	rts


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGMouseInterruptHandler
; Handles interrupts that may be related to the mouse
; This is a ProDOS-compliant interrupt handling routine, and
; should be installed and removed via ProDOS as needed.
; 
; IMPORTANT: This routine is NOT MLI-reentrant, which means MLI
; calls can NOT be made within this handler. See page 108 of the
; ProDOS 8 Technical Reference Manual if this feature needs to be
; added.
;
WGMouseInterruptHandler:
	cld						; ProDOS interrupt handlers must open with this
	SAVE_AXY

	CALLMOUSE SERVEMOUSE
	bcc WGMouseInterruptHandler_regard
	jmp WGMouseInterruptHandler_disregard

WGMouseInterruptHandler_regard:
	php
	sei

	lda PAGE2			; Need to preserve text bank, because we may interrupt rendering
	pha
	SETSWITCH	PAGE2OFF

	ldx WG_MOUSE_SLOT
	lda MOUSTAT,x			; Check interrupt status bits first, because READMOUSE clears them
	and #MOUSTAT_MASK_BUTTONINT
	bne WGMouseInterruptHandler_button

	lda MOUSTAT,x
	and #MOUSTAT_MASK_MOVEINT
	bne WGMouseInterruptHandler_mouse
	jmp WGMouseInterruptHandler_VBL

WGMouseInterruptHandler_mouse:
	jsr WGUndrawPointer			; Erase the old mouse pointer

	; Read the mouse state. Note that interrupts need to remain
	; off until after the data is copied.
	CALLMOUSE READMOUSE

	ldx WG_MOUSE_SLOT
	lda MOUSTAT,x			; Movement/button status bits are now valid
	sta WG_MOUSE_STAT

	lda WG_APPLEIIC
	bne WGMouseInterruptHandler_IIc

	; Read mouse position and transform it into screen space
	; SCALING:  If you change the clamps, change this division from
	; 1024 to match your new values.
	lsr MOUSE_XH,x
	ror MOUSE_XL,x
	lsr MOUSE_XH,x
	ror MOUSE_XL,x
	lsr MOUSE_XH,x
	ror MOUSE_XL,x

	lda MOUSE_XL,x
	sta WG_MOUSEPOS_X

	lsr MOUSE_YH,x
	ror MOUSE_YL,x
	lsr MOUSE_YH,x
	ror MOUSE_YL,x
	lsr MOUSE_YH,x
	ror MOUSE_YL,x
	lsr MOUSE_YH,x
	ror MOUSE_YL,x
	lsr MOUSE_YH,x
	ror MOUSE_YL,x

	lda MOUSE_YL,x
	sta WG_MOUSEPOS_Y
	bra WGMouseInterruptHandler_draw

WGMouseInterruptHandler_IIc:		; IIc tracks much slower, so don't scale
	lda MOUSE_XL,x
	sta WG_MOUSEPOS_X
	lda MOUSE_YL,x
	sta WG_MOUSEPOS_Y

WGMouseInterruptHandler_draw:
	jsr WGDrawPointer				; Redraw the pointer
	bra WGMouseInterruptHandler_intDone

WGMouseInterruptHandler_disregard:
	; Carry will still be set here, to notify ProDOS that
	; this interrupt was not ours
	RESTORE_AXY
	rts

WGMouseInterruptHandler_button:
	CALLMOUSE READMOUSE
	ldx WG_MOUSE_SLOT
	lda MOUSTAT,x			; Movement/button status bits are now valid
	sta WG_MOUSE_STAT

	bit WG_MOUSE_STAT			; Check for rising edge of button state
	bpl WGMouseInterruptHandler_intDone

	lda WG_MOUSE_BUTTON_DOWN
	bne WGMouseInterruptHandler_intDone

WGMouseInterruptHandler_buttonDown:
	; Button went down, so make a note of location for later
	lda #1
	sta WG_MOUSE_BUTTON_DOWN

	lda WG_MOUSEPOS_X
	sta WG_MOUSECLICK_X
	lda WG_MOUSEPOS_Y
	sta WG_MOUSECLICK_Y

WGMouseInterruptHandler_intDone:
	pla						; Restore text bank
	bpl WGMouseInterruptHandler_intDoneBankOff
	SETSWITCH	PAGE2ON
	bra WGMouseInterruptHandler_done

WGMouseInterruptHandler_VBL:
	CALLMOUSE READMOUSE
	ldx WG_MOUSE_SLOT
	lda MOUSTAT,x			; Movement/button status bits are now valid
	sta WG_MOUSE_STAT

	bmi WGMouseInterruptHandler_intDone

	stz WG_MOUSE_BUTTON_DOWN
	bra WGMouseInterruptHandler_intDone

WGMouseInterruptHandler_intDoneBankOff:
	SETSWITCH	PAGE2OFF

WGMouseInterruptHandler_done:
	RESTORE_AXY

	plp
	clc								; Notify ProDOS this was our interrupt
	rts




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGUndrawPointer
; Unplots the mouse pointer at current location
; Stub for your use
;
WGUndrawPointer:
	rts



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGDrawPointer
; Plots the mouse pointer at current location
; Stub for your use
;
WGDrawPointer:
	rts



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Mouse API state
;

; Useful things you can poll in your code:
WG_MOUSEACTIVE:
.byte 0
WG_MOUSEPOS_X:
.byte 39
WG_MOUSEPOS_Y:
.byte 11
WG_MOUSECLICK_X:
.byte $ff
WG_MOUSECLICK_Y:
.byte 0


; Internal state for the driver (no touchy!)
WG_MOUSE_STAT:
.byte 0
WG_MOUSEBG:
.byte 0
WG_APPLEIIC:
.byte 0
WG_MOUSE_JUMPL:
.byte 0
WG_MOUSE_JUMPH:
.byte 0
WG_MOUSE_SLOT:
.byte 0
WG_MOUSE_SLOTSHIFTED:
.byte 0
WG_MOUSE_BUTTON_DOWN:
.byte 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; ProDOS system call parameter blocks
;
WG_PRODOS_ALLOC:
	.byte 2
	.byte 0						; ProDOS returns an ID number for the interrupt here
	.addr WGMouseInterruptHandler

WG_PRODOS_DEALLOC:
	.byte 1
	.byte 0						; To be filled with ProDOS ID number


