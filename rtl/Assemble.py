# Minimal RV32I assembler for exactly the instructions this firmware needs.

def lui(rd, imm20):
    imm20 &= 0xFFFFF
    return (imm20 << 12) | (rd << 7) | 0b0110111

def addi(rd, rs1, imm12):
    imm12 &= 0xFFF
    return (imm12 << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0b0010011

def sw(rs2, rs1, imm12):
    imm12 &= 0xFFF
    imm_11_5 = (imm12 >> 5) & 0x7F
    imm_4_0  = imm12 & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | (imm_4_0 << 7) | 0b0100011

def jal(rd, imm21_signed_bytes):
    imm = imm21_signed_bytes & 0x1FFFFF
    bit20   = (imm >> 20) & 0x1
    bits10_1 = (imm >> 1) & 0x3FF
    bit11   = (imm >> 11) & 0x1
    bits19_12 = (imm >> 12) & 0xFF
    return (bit20 << 31) | (bits19_12 << 12) | (bit11 << 20) | (bits10_1 << 21) | (rd << 7) | 0b1101111

# register numbers
x0=0; x1=1; x2=2; x3=3; x4=4; x5=5; x6=6; x7=7; x8=8

UART_BASE = 0x10000000
I2C_BASE  = 0x10000020
SPI_BASE  = 0x10000040
FIR_BASE  = 0x10000060

def hi20(addr):   return (addr + 0x800) >> 12   # standard lui/addi split, unused here since our offsets are small & positive
def base_hi(addr): return addr >> 12
def base_lo(addr): return addr & 0xFFF

prog = []

# --- UART: write 'A' (0x41) to TXDATA (offset 0) ---
prog.append(lui(x1, base_hi(UART_BASE)))          # x1 = UART_BASE (upper 20 bits)
prog.append(addi(x2, x0, 0x41))                   # x2 = 0x41
prog.append(sw(x2, x1, 0))                        # mem[UART_BASE + 0] = x2   (TXDATA)

# --- I2C: write 0x81 to CTR (offset 0x08 within I2C's window) ---
prog.append(lui(x3, base_hi(I2C_BASE)))           # x3 = I2C_BASE
prog.append(addi(x4, x0, 0x81))                   # x4 = 0x81
prog.append(sw(x4, x3, base_lo(I2C_BASE) + 8))    # mem[I2C_BASE + 8] = x4   (CTR)

# --- SPI: write 0x50 to SPCR (offset 0 within SPI's window) ---
prog.append(lui(x5, base_hi(SPI_BASE)))           # x5 = SPI_BASE
prog.append(addi(x6, x0, 0x50))                   # x6 = 0x50
prog.append(sw(x6, x5, base_lo(SPI_BASE) + 0))    # mem[SPI_BASE + 0] = x6   (SPCR)

# --- FIR: write 1 to WRDATA (offset 0 within FIR's window) ---
prog.append(lui(x7, base_hi(FIR_BASE)))           # x7 = FIR_BASE
prog.append(addi(x8, x0, 1))                      # x8 = 1
prog.append(sw(x8, x7, base_lo(FIR_BASE) + 0))    # mem[FIR_BASE + 0] = x8   (WRDATA)

loop_addr = len(prog) * 4
prog.append(jal(x0, 0))   # infinite self-jump: spin here forever

with open('firmware.hex', 'w') as f:
    for instr in prog:
        f.write('%08x\n' % instr)

print(f"{len(prog)} instructions assembled -> firmware.hex")
for i, instr in enumerate(prog):
    print(f"  [{i}] addr=0x{i*4:02x}  0x{instr:08x}")
