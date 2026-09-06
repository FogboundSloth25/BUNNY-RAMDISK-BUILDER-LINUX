.section __TEXT,__text
.globl _start
.p2align 2
_start:
    // Darwin arm64 syscall: write(2, banner, banner_len)
    movz x16, #4
    movk x16, #0x200, lsl #16
    mov x0, #2
    adrp x1, banner@PAGE
    add x1, x1, banner@PAGEOFF
    mov x2, #21
    svc #0x80

    // Build argv on the process stack without any external relocations.
    sub sp, sp, #64
    adrp x9, path@PAGE
    add x9, x9, path@PAGEOFF
    str x9, [sp, #0]

    adrp x9, arg_R@PAGE
    add x9, x9, arg_R@PAGEOFF
    str x9, [sp, #8]

    adrp x9, arg_E@PAGE
    add x9, x9, arg_E@PAGEOFF
    str x9, [sp, #16]

    adrp x9, arg_F@PAGE
    add x9, x9, arg_F@PAGEOFF
    str x9, [sp, #24]

    adrp x9, arg_p@PAGE
    add x9, x9, arg_p@PAGEOFF
    str x9, [sp, #32]

    adrp x9, arg_44@PAGE
    add x9, x9, arg_44@PAGEOFF
    str x9, [sp, #40]

    str xzr, [sp, #48]

    // Darwin arm64 syscall: execve(path, argv, envp=NULL)
    movz x16, #0x3b
    movk x16, #0x200, lsl #16
    adrp x0, path@PAGE
    add x0, x0, path@PAGEOFF
    mov x1, sp
    mov x2, xzr
    svc #0x80

    // execve only returns on error. Exit 127 instead of falling back into the
    // Apple restore daemon, making failure deterministic.
    movz x16, #1
    movk x16, #0x200, lsl #16
    mov x0, #127
    svc #0x80

.section __TEXT,__cstring
banner:
    .ascii "VALIDITY IS THE BEST\n"
path:
    .asciz "/usr/local/bin/dropbear"
arg_R:
    .asciz "-R"
arg_E:
    .asciz "-E"
arg_F:
    .asciz "-F"
arg_p:
    .asciz "-p"
arg_44:
    .asciz "44"
