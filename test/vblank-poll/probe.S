// Assemble from the repository root with HEADER_ROM set to a local GBA ROM.
.syntax unified
.cpu arm7tdmi
.text
.arm
start:
    b reset
    .incbin HEADER_ROM, 4, 156
    .ascii "VBLANK POLL VBLP00"
    .byte 0x96
    .space 10
    .byte 0x88                       // Header complement.
    .space 2
reset:
    mov r7, #0
    mov r0, #0x04000000
    ldr r1, =0x0403
    strh r1, [r0]                    // Mode 3 with BG2 enabled.
    ldr r1, =(0x08000000 + handler - start)
    str r1, [r0, #-4]                // BIOS IRQ callback in mirrored IWRAM.
    mov r1, #8
    strh r1, [r0, #4]                // DISPSTAT VBlank IRQ enable.
    add r2, r0, #0x200
    mov r1, #1
    strh r1, [r2]
    strh r1, [r2, #2]                // Clear any stale IF.
    strh r1, [r2, #8]                // IME
    mrs r1, cpsr
    bic r1, r1, #0x80
    msr cpsr_c, r1
    add r5, r0, #6                   // VCOUNT
    mov r6, #0
    adr r0, trials
    add r0, r0, #1
    bx r0

.thumb
trials:
    ldrb r4, [r5]
    cmp r4, #159
    bne trials
    movs r0, r6
delay:
    subs r0, #1
    bpl delay
    movs r7, #1
poll:
    ldrb r4, [r5]
    lsrs r0, r4, #5
    cmp r0, #5
    blo poll
await_irq:
    cmp r7, #0
    bne await_irq
    adds r6, #1
    cmp r6, #8
    blo trials
done:
    b done

.arm
.balign 4
handler:
    mov r0, #0x04000000
    add r0, r0, #0x200
    mov r1, #1
    strh r1, [r0, #2]
    cmp r7, #1
    bxne lr
    mov r0, #3840                    // Eight scanlines per trial.
    mul r1, r6, r0
    add r1, r1, #0x06000000
    ldr r0, [sp, #20]                // IRQ LR saved by BIOS.
    sub r0, r0, #4
    adr r2, poll
    sub r0, r0, r2
    and r0, r0, #255
    orr r0, r0, r4, lsl #8           // VCOUNT followed by resume offset.
    mov r2, #16
bits:
    tst r0, #0x8000
    mov r3, #0
    mvnne r3, #0
    mov r12, #8
pixels:
    strh r3, [r1], #2
    subs r12, r12, #1
    bne pixels
    lsl r0, r0, #1
    subs r2, r2, #1
    bne bits
    mov r7, #0
    bx lr
.ltorg
