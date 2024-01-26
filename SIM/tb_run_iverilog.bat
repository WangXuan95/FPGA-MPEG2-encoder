del sim.out dump.vcd
iverilog  -g2001  -o sim.out  tb_mpeg2encoder.v ../RTL/mpeg2encoder.v
vvp -n sim.out
del sim.out
pause