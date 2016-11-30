;
;  mouse.s
;  Mouse driver for Apple //e Enhanced with mouse card (any slot), or Apple //c(+)
;
;  Created by Quinn Dunki on 7/14/15.
;  Updated on 11/29/16 by Peter Ferrie.
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
	sta WG_APPLEIIE

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
	stz MOUSE_ZEROL
	lda #1
	CALLMOUSE CLAMPMOUSE
	lda #0
	CALLMOUSE CLAMPMOUSE

	; Scale the mouse's range into something easy to do math with,
	; while retaining as much range of motion and precision as possible
	lda WG_APPLEIIE
	bne WGEnableMouse_ConfigIIe

	; Sorry //c, no scaling for you
	; //c's tracking is weird. Need to clamp to a much smaller range

	lda #>SCALE_X_IIC
	pha
	lda #<SCALE_X_IIC
	ldx #<SCALE_Y_IIC
	ldy #>SCALE_Y_IIC
	bra WGClampMouse1

WGEnableMouse_ConfigIIe:
	lda #>SCALE_X_IIE
	pha
	lda #<SCALE_X_IIE
	ldx #<SCALE_Y_IIE
	ldy #>SCALE_Y_IIE

WGClampMouse1
	pha
	lda #1
	.byte $2C				; mask plx/ply
WGClampMouse2
        plx
        ply
	stx MOUSE_CLAMPL
	sty MOUSE_CLAMPH
	pha
	CALLMOUSE CLAMPMOUSE
        pla
        dec
        bpl WGClampMouse2

WGEnableMouse_Activate:
	inc WG_MOUSEACTIVE

	cli					; Once all setup is done, it's safe to enable interrupts

WGEnableMouse_Error:

WGEnableMouse_done:			; Exit point here for branch range
	pla
	rts




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; WGDisableMouse
; Shuts off the mouse when we're done with it
;
WGDisableMouse:
	pha

	SETSWITCH PAGE2OFF

	lda WG_MOUSEACTIVE			; Never activated the mouse
	beq WGDisableMouse_done

	lda #MOUSEMODE_OFF
	CALLMOUSE SETMOUSE

	stz WG_MOUSEACTIVE

	; Remove our interrupt handler via ProDOS (done playing nice!)
	dec WG_PRODOS_ALLOC		; change Alloc parm count to DeAlloc parm count

	jsr PRODOS_MLI
	.byte DEALLOC_INTERRUPT
	.addr WG_PRODOS_ALLOC

	inc WG_PRODOS_ALLOC		; restore DeAlloc parm count to Alloc parm count

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

	stz WG_MOUSE_SLOT
	ldx #$c7

WGFindMouse_loop:
	stx WGFindMouse_loopModify+6		; Self-modifying code!
	ldy #4

WGFindMouse_loopModify:
	; Check for the magic 5-byte pattern that gives away the mouse card
	phx
	ldx WG_MOUSE_OFFSETS, y	
	lda $c700, x
	plx
	cmp WG_MOUSE_IDBYTES, y
	bne WGFindMouse_nextSlot
	dey
	bpl WGFindMouse_loopModify

WGFindMouse_found:
	; Found it! Now configure all our indirection lookups
	stx WG_MOUSE_JUMPH
	stx WGCallMouse+5			; Self-modifying code!
	txa
	and #7
	sta WG_MOUSE_SLOT
	asl
	asl
	asl
	asl					; shift clears the carry
	sta WG_MOUSE_SLOTSHIFTED
	bra WGFindMouse_done

WGFindMouse_nextSlot:
	dex
	cpx #$c0
	bne WGFindMouse_loop			; Carry is set on exit

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

WGMouseInterruptHandler_disregard:
	; Carry will still be set here, to notify ProDOS that
	; this interrupt was not ours
	RESTORE_AXY
	rts

WGMouseInterruptHandler_regard:
	php
	sei

	lda PAGE2			; Need to preserve text bank, because we may interrupt rendering
	pha
	SETSWITCH	PAGE2OFF

	ldx WG_MOUSE_SLOT
	lda MOUSTAT,x			; Check interrupt status bits first, because READMOUSE clears them
	and #(MOUSTAT_MASK_BUTTONINT or MOUSTAT_MASK_MOVEINT)
	tax
	jmp (WG_MOUSE_DISPATCH, X)

WGMouseInterruptHandler_mouse:
	jsr WGUndrawPointer			; Erase the old mouse pointer

	; Read the mouse state. Note that interrupts need to remain
	; off until after the data is copied.
	jsr WGReadMouse			; Movement/button status bits are now valid

	lda WG_APPLEIIE
	cmp #1				; check via carry
	lda MOUSE_XL,x
	ldy MOUSE_YL,x

WGMouseInterruptHandler_IIc:		; IIc tracks much slower, so don't scale
	bcc WGMouseInterruptHandler_draw

WGMouseInterruptHandler_IIe:
	; Read mouse position and transform it into screen space
	; SCALING:  If you change the clamps, change this division from
	; 1024 to match your new values.
	lsr MOUSE_XH,x
	ror
	lsr MOUSE_XH,x
	ror
	lsr MOUSE_XH,x
	ror
	tax
	tya

	lsr MOUSE_YH,x
	ror
	lsr MOUSE_YH,x
	ror
	lsr MOUSE_YH,x
	ror
	lsr MOUSE_YH,x
	ror
	lsr MOUSE_YH,x
	ror
	tay
	txa

WGMouseInterruptHandler_draw:
	sta WG_MOUSEPOS_X
	sty WG_MOUSEPOS_Y
	jsr WGDrawPointer				; Redraw the pointer
	bra WGMouseInterruptHandler_intDone

WGMouseInterruptHandler_VBL:
	jsr WGReadMouse			; Movement/button status bits are now valid
	bmi WGMouseInterruptHandler_intDone

	stz WG_MOUSE_BUTTON_DOWN
	bra WGMouseInterruptHandler_intDone

WGMouseInterruptHandler_button:
	jsr WGReadMouse			; Movement/button status bits are now valid
	bpl WGMouseInterruptHandler_intDone	; Check for rising edge of button state

	lda WG_MOUSE_BUTTON_DOWN
	bne WGMouseInterruptHandler_intDone

WGMouseInterruptHandler_buttonDown:
	; Button went down, so make a note of location for later
	inc WG_MOUSE_BUTTON_DOWN

	lda WG_MOUSEPOS_X
	sta WG_MOUSECLICK_X
	lda WG_MOUSEPOS_Y
	sta WG_MOUSECLICK_Y

WGMouseInterruptHandler_intDone:
	ldx #0
	pla						; Restore text bank
	bpl WGMouseInterruptHandler_intDoneBankOff
	inx

WGMouseInterruptHandler_intDoneBankOff:
	sta	PAGE2OFF, x

WGMouseInterruptHandler_done:
	RESTORE_AXY

	plp
	clc								; Notify ProDOS this was our interrupt
	rts

WGReadMouse:
	CALLMOUSE READMOUSE

	ldx WG_MOUSE_SLOT
	lda MOUSTAT,x
	sta WG_MOUSE_STAT
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


; Mouse identification data
WG_MOUSE_OFFSETS:
.byte 5, 7, $b, $c, $fb
WG_MOUSE_IDBYTES:
.byte $38, $18, $1, $20, $d6

; Mouse interrupt handler dispatch table
WG_MOUSE_DISPATCH:
.addr WGMouseInterruptHandler_VBL
.addr WGMouseInterruptHandler_mouse
.addr WGMouseInterruptHandler_button

; Internal state for the driver (no touchy!)
WG_MOUSE_STAT:
.byte 0
WG_MOUSEBG:
.byte 0
WG_APPLEIIE:
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
