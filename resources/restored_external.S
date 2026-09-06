.section __TEXT,__text
.globl _start
.p2align 2
_start:
    // Darwin arm64 syscall ABI: x16 = 0x20000000 | syscall number.
    // write(fd=2, banner, 21)
    movz x16, #4
    movk x16, #0x2000, lsl #16
    mov x0, #2
    adrp x1, banner@PAGE
    add x1, x1, banner@PAGEOFF
    mov x2, #21
    svc #0x80

    // argv = { "/usr/local/bin/dropbear", "-R", "-E", "-F", "-p", "44", NULL }
    // envp = { NULL }
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
    str xzr, [sp, #56]

    // Darwin arm64 execve syscall (59).
    movz x16, #0x3b
    movk x16, #0x2000, lsl #16
    adrp x0, path@PAGE
    add x0, x0, path@PAGEOFF
    mov x1, sp
    add x2, sp, #56
    svc #0x80

    // Only reached when execve failed.
    adrp x1, exec_failed@PAGE
    add x1, x1, exec_failed@PAGEOFF
    mov x0, #2
    mov x2, #14
    movz x16, #4
    movk x16, #0x2000, lsl #16
    svc #0x80

    // Darwin arm64 exit syscall (1).
    movz x16, #1
    movk x16, #0x2000, lsl #16
    mov x0, #127
    svc #0x80

.section __TEXT,__const
banner:
    .asciz "VALIDITY IS THE BEST\n"
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
exec_failed:
    .asciz "EXECVE FAILED\n"
