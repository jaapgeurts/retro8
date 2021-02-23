;CTC_A  equ 0x00
;SIO_AD equ 0x40
;SIO_BD equ 0x41
;SIO_AC equ 0x42
;SIO_BC equ 0x43

;SIO_AC equ 0x80
;SIO_AD equ 0x811


;BS equ 8
;CR equ 13
;LF equ 10


STACK_TOP equ 0x9FFF

  org 0x0000

  ld sp, STACK_TOP    ; stack pointer at 40k (base = 32k + 8k -1)
  jp main

  org 0x0200


