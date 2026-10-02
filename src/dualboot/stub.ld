/* Snouty Arcade dual-boot launch stub (stub.S): linked at 0 and copied by
 * the launcher app to a 256-byte aligned SRAM address. The code is
 * position independent; only vector words 1..3 are relocated, by the app. */
ENTRY(stub_start)
SECTIONS
{
    . = 0;
    .text : { KEEP(*(.text.stub)) }
    /DISCARD/ : { *(.text*) *(.data*) *(.bss*) }
}
