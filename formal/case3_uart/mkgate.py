import sys
src = open('uart_rx_gold.v').read()

WIRES = ("wire next_bit     = cycle_counter == CYCLES_PER_BIT ||\n"
         "                        fsm_state       == FSM_STOP && \n"
         "                        cycle_counter   == CYCLES_PER_BIT/2;\n"
         "wire payload_done = bit_counter   == PAYLOAD_BITS  ;\n")

ORIG_ASSIGN = "assign uart_rx_valid = fsm_state == FSM_STOP && n_fsm_state == FSM_IDLE;\n"
NEW_ASSIGN  = "assign uart_rx_valid = fsm_state == FSM_STOP && next_bit;\n"
BREAK_LINE  = "assign uart_rx_break = uart_rx_valid && ~|recieved_data;\n"

for name, needle in (("wire block", WIRES),
                     ("original assign", ORIG_ASSIGN),
                     ("break assign", BREAK_LINE)):
    if src.count(needle) != 1:
        sys.exit(f"ERROR: expected one '{name}', found {src.count(needle)}")

src = src.replace(WIRES + "\n", "", 1)
src = src.replace(BREAK_LINE, WIRES + "\n" + BREAK_LINE, 1)
src = src.replace(ORIG_ASSIGN, NEW_ASSIGN, 1)
open('uart_rx_gate.v', 'w').write(src)
print("wrote uart_rx_gate.v")
