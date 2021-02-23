
STACK_TOP equ 0x9FFF

  org 0x0000

  ld sp, STACK_TOP    ; stack pointer at 40k (base = 32k + 8k -1)
  jp main

  org 0x0200


