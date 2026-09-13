#!/bin/bash
# Rename both DUTs so the miter can instantiate them side by side.
set -e
sed 's/^module fir_filter /module fir_gold /' fir_gold_delayed.v > miter_gold.v
sed 's/^module fir_filter /module fir_gate /' fir_gate.v         > miter_gate.v
echo "wrote miter_gold.v (module fir_gold) and miter_gate.v (module fir_gate)"
