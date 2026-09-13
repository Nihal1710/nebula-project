// EQY proves 12 of 13 partitions for this fix. The 13th, uart_rx_valid,
// fails with a counterexample that is UNREACHABLE: EQY cuts the cone at
// n_fsm_state and passes it in as a free input, losing the fact that it is
// computed from fsm_state and next_bit. Gold reads n_fsm_state, gate reads
// next_bit, so decoupling them lets SAT pick contradictory values such as
// fsm_state=FSM_STOP, next_bit=1, n_fsm_state=FSM_START.
//
// This miter recomputes n_fsm_state from the same case statement, so the
// dependency is preserved, then compares the two expressions. Purely
// combinational: depth 1 enumerates all 64 combinations of the free
// variables, including all 32 unreachable fsm_state encodings. The result
// is exhaustive, not bounded.

module valid_miter (
    input [2:0] fsm_state,
    input       next_bit,
    input       rxd_reg,
    input       payload_done
);
    localparam FSM_IDLE = 0;
    localparam FSM_START= 1;
    localparam FSM_RECV = 2;
    localparam FSM_STOP = 3;

    reg [2:0] n_fsm_state;
    always @(*) begin
        case(fsm_state)
            FSM_IDLE : n_fsm_state = rxd_reg      ? FSM_IDLE : FSM_START;
            FSM_START: n_fsm_state = next_bit     ? FSM_RECV : FSM_START;
            FSM_RECV : n_fsm_state = payload_done ? FSM_STOP : FSM_RECV ;
            FSM_STOP : n_fsm_state = next_bit     ? FSM_IDLE : FSM_STOP ;
            default  : n_fsm_state = FSM_IDLE;
        endcase
    end

    wire gold_valid = (fsm_state == FSM_STOP) && (n_fsm_state == FSM_IDLE);
    wire gate_valid = (fsm_state == FSM_STOP) && next_bit;

    always @(*)
        assert (gold_valid == gate_valid);
endmodule
