# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from softposit import *
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):

    dut._log.info("Start")
    # Set the clock period to 10 us (100 KHz)
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Test project behavior")

    ########################################
    #    SIMPLE SINGLE ADD TEST
    ########################################

    # send our first 8 bit operand (valid is bit 0 of ui_in)
    # ready is high (bit 5 of ui_in)
    dut.ui_in.value = 0b00100001
    dut.uio_in.value = 0b00011100 #0.03125
    p1 = posit_2(None, 8, int(0b00011100))

    await ClockCycles(dut.clk, 1)

    # send our second 8 bit operand and opcode (valids are bits 1&2 of ui_in)
    # ready is high (bit 5 of ui_in)
    dut.ui_in.value = 0b00101110
    dut.uio_in.value = 0b00011100 #0.03125
    p2 = posit_2(None, 8, int(0b00011100))

    # wait until output is ready (bit 0 of uo_out)
    while not (dut.uo_out.value[0]): 
        await ClockCycles(dut.clk, 1)

    dut_posit = posit_2(None, 8, int(dut.uio_out.value))

    p3 = p1 + p2
    
    # assert that 0.03125 + 0.03125 = 0.0625
    assert dut_posit == p3

    await ClockCycles(dut.clk, 1)

    ########################################
    #    SIMPLE SINGLE MULT TEST
    ########################################

    # send our first 8 bit operand (valid is bit 0 of ui_in)
    # ready is high (bit 5 of ui_in)
    dut.ui_in.value = 0b00100001
    dut.uio_in.value = 0b01000100	 #1.5
    p1 = posit_2(None, 8, int(0b01000100))

    await ClockCycles(dut.clk, 1)

    dut.ui_in.value = 0b00110110
    dut.uio_in.value = 0b00110010	#0.3125
    p2 = posit_2(None, 8, int(0b00110010))

    while not (dut.uo_out.value[0]): 
        await ClockCycles(dut.clk, 1)

    dut_posit = posit_2(None, 8, int(dut.uio_out.value))

    p3 = p1 * p2

    # assert that 1.5 * 0.3125 = 0.46875 
    assert dut_posit == p3

    await ClockCycles(dut.clk, 1)

    ########################################
    #    READY/VALID STATES TEST
    ########################################

    #invalid first input:
    dut.ui_in.value = 0b00100000
    dut.uio_in.value = 0b01000100

    await ClockCycles(dut.clk, 1)

    #assert ready but not valid
    assert dut.uo_out.value == 0b00001000

    #valid first input:
    dut.ui_in.value = 0b00100001
    dut.uio_in.value = 0b01000100

    await ClockCycles(dut.clk, 1)

    #assert still ready but not valid
    assert dut.uo_out.value == 0b00001000

    #invalid second input, but valid opcode:
    dut.ui_in.value = 0b00101100
    dut.uio_in.value = 0b01000100

    await ClockCycles(dut.clk, 1)

    #assert still ready but not valid
    assert dut.uo_out.value == 0b00001000

    #valid second input, and valid opcode (STARTS computation)
    dut.ui_in.value = 0b00101110
    dut.uio_in.value = 0b01000100

    await ClockCycles(dut.clk, 1)

    #assert still ready but not valid
    assert dut.uo_out.value == 0b00001000

    await ClockCycles(dut.clk, 1)

    #assert not ready and not valid (computing)
    assert dut.uo_out.value == 0b00000000

    #set ready_in to 0, should stay in complete state
    dut.ui_in.value = 0b00000000

    await ClockCycles(dut.clk, 1)

    #assert not ready but valid (complete)
    assert dut.uo_out.value == 0b00000001

    #set ready_in to 1, should now exit complete state to idle
    dut.ui_in.value = 0b00100000

    await ClockCycles(dut.clk, 1)

    #assert not ready but valid (complete)
    assert dut.uo_out.value == 0b00000001

    await ClockCycles(dut.clk, 1)

    #assert ready but not valid (back to IDLE/INIT state)
    assert dut.uo_out.value == 0b00001000

    ########################################
    #    ROUNDING ERROR FUZZ TEST ADD
    ########################################

    # TEST ADD
    num_rounding_diffs_add = 0
    add_max_diff = 0
    problematic_sum = []

    # 0-255
    for i in range(0,255):
        # i-255 gets rid of mirrored calculations I.E 0+1 == 1+0
        for j in range(i,255):
            dut.ui_in.value = 0b00100001
            dut.uio_in.value = i
            p1 = posit_2(None, 8, i)

            await ClockCycles(dut.clk, 1)

            dut.ui_in.value = 0b00101110
            dut.uio_in.value = j
            p2 = posit_2(None, 8, j)

            p3 = p1 + p2

            while not (dut.uo_out.value[0]):
                await ClockCycles(dut.clk, 1)

            dut_posit = posit_2(None, 8, int(dut.uio_out.value))

            if(dut_posit != p3):
                num_rounding_diffs_add += 1

            if (abs(dut_posit - p3) > add_max_diff):
                problematic_sum.append((p1, p2, p3, dut_posit))
                add_max_diff = abs(dut_posit - p3)

            await ClockCycles(dut.clk, 1)

    print(num_rounding_diffs_add)
    for sum_err in problematic_sum:
        print(sum_err)

    ########################################
    #    ROUNDING ERROR FUZZ TEST MULT
    ########################################

    num_rounding_diffs_mult = 0
    mult_max_diff = 0
    problematic_product = []

    # 0-255
    for i in range(0,255):
        # i-255 gets rid of mirrored calculations I.E 5*6 == 6*5
        for j in range(i,255):
            dut.ui_in.value = 0b00100001
            dut.uio_in.value = i
            p1 = posit_2(None, 8, i)

            await ClockCycles(dut.clk, 1)

            dut.ui_in.value = 0b00110110
            dut.uio_in.value = j
            p2 = posit_2(None, 8, j)

            p3 = p1 * p2

            dut_posit = posit_2(None, 8, int(dut.uio_out.value))

            while not (dut.uo_out.value[0]):
                await ClockCycles(dut.clk, 1)

            if(dut_posit != p3):
                num_rounding_diffs_mult += 1

            if (abs(dut_posit - p3) > mult_max_diff):
                problematic_product.append((p1, p2, p3, dut_posit))
                mult_max_diff = abs(dut_posit - p3)

            await ClockCycles(dut.clk, 1)
    
    print(num_rounding_diffs_mult)
    for product in problematic_product:
        print(product)
