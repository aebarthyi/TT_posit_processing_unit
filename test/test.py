# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from softposit import *
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


# Opcodes (ui_in[4:3])
MAC_OP   = 0b01
READ_OP  = 0b10
CLEAR_OP = 0b11


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


async def do_mac(dut, val1, val2):
    """Perform MAC: quire += val1 * val2, return posit8 of quire."""
    # Send first operand
    dut.ui_in.value = 0b00100001  # ready_in=1, input1_valid=1
    dut.uio_in.value = val1
    await ClockCycles(dut.clk, 1)

    # Send second operand + MAC opcode
    dut.ui_in.value = 0b00100000 | (MAC_OP << 3) | 0b110  # input2_valid + instruction_valid
    dut.uio_in.value = val2
    await ClockCycles(dut.clk, 1)

    # Wait for valid output
    dut.ui_in.value = 0b00000000
    for _ in range(10):
        if int(dut.uo_out.value) & 1:  # valid_o
            break
        await ClockCycles(dut.clk, 1)

    result = int(dut.uio_out.value)

    # Acknowledge and return to idle
    dut.ui_in.value = 0b00100000  # ready_in
    await ClockCycles(dut.clk, 2)

    return result


async def do_read(dut):
    """Read quire as posit8."""
    # Send READ instruction (no operands)
    dut.ui_in.value = (READ_OP << 3) | 0b100  # instruction_valid only
    await ClockCycles(dut.clk, 1)

    # Wait for valid output
    dut.ui_in.value = 0b00000000
    for _ in range(10):
        if int(dut.uo_out.value) & 1:
            break
        await ClockCycles(dut.clk, 1)

    result = int(dut.uio_out.value)

    # Acknowledge
    dut.ui_in.value = 0b00100000
    await ClockCycles(dut.clk, 2)

    return result


async def do_clear(dut):
    """Clear quire to zero."""
    dut.ui_in.value = (CLEAR_OP << 3) | 0b100  # instruction_valid only
    await ClockCycles(dut.clk, 1)

    dut.ui_in.value = 0b00000000
    for _ in range(10):
        if int(dut.uo_out.value) & 1:
            break
        await ClockCycles(dut.clk, 1)

    # Acknowledge
    dut.ui_in.value = 0b00100000
    await ClockCycles(dut.clk, 2)


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    await reset(dut)
    dut._log.info("Test project behavior")

    ########################################
    #    BASIC MAC TEST
    ########################################

    p1 = posit_2(None, 8, bits=int(0b01000100))  # 1.5
    p2 = posit_2(None, 8, bits=int(0b00110010))  # 0.3125
    expected = p1 * p2  # 0.46875

    result_bits = await do_mac(dut, 0b01000100, 0b00110010)
    dut_posit = posit_2(None, 8, bits=result_bits)
    dut._log.info(f"MAC: {p1} * {p2} = {dut_posit} (expected {expected})")
    assert dut_posit == expected, f"MAC failed: got {dut_posit}, expected {expected}"

    ########################################
    #    READ QUIRE TEST
    ########################################

    read_bits = await do_read(dut)
    read_posit = posit_2(None, 8, bits=read_bits)
    dut._log.info(f"READ: quire = {read_posit} (expected {expected})")
    assert read_posit == expected, f"READ failed: got {read_posit}, expected {expected}"

    ########################################
    #    ACCUMULATION TEST
    ########################################

    # quire already has 1.5*0.3125 = 0.46875
    # now add 2.0 * 4.0 = 8.0
    p3 = posit_2(None, 8, bits=int(0b01001000))  # 2.0
    p4 = posit_2(None, 8, bits=int(0b01010000))  # 4.0
    accumulated = p1 * p2 + p3 * p4  # 0.46875 + 8.0 = 8.46875

    result_bits = await do_mac(dut, 0b01001000, 0b01010000)
    dut_posit = posit_2(None, 8, bits=result_bits)
    dut._log.info(f"ACCUMULATE: quire = {dut_posit} (expected ~{accumulated})")

    ########################################
    #    CLEAR TEST
    ########################################

    await do_clear(dut)

    read_bits = await do_read(dut)
    read_posit = posit_2(None, 8, bits=read_bits)
    dut._log.info(f"CLEAR+READ: quire = {read_posit} (expected 0)")
    assert read_bits == 0, f"CLEAR failed: got {read_posit}, expected 0"

    ########################################
    #    NEGATIVE VALUES TEST
    ########################################

    # MAC with negative: -1.5 * 0.3125 = -0.46875
    neg_p1_bits = (~0b01000100 + 1) & 0xFF  # 2's complement of 1.5
    neg_p1 = posit_2(None, 8, bits=neg_p1_bits)
    result_bits = await do_mac(dut, neg_p1_bits, 0b00110010)
    dut_posit = posit_2(None, 8, bits=result_bits)
    expected_neg = neg_p1 * p2
    dut._log.info(f"NEG MAC: {-p1} * {p2} = {dut_posit} (expected {expected_neg})")
    assert dut_posit == expected_neg, f"NEG MAC failed: got {dut_posit}, expected {expected_neg}"

    # Clear for next test
    await do_clear(dut)

    ########################################
    #    ZERO MULTIPLY TEST
    ########################################

    result_bits = await do_mac(dut, 0b00000000, 0b01000100)
    dut_posit = posit_2(None, 8, bits=result_bits)
    dut._log.info(f"ZERO MAC: 0 * 1.5 = {dut_posit}")
    assert result_bits == 0, f"ZERO MAC failed: got {dut_posit}"

    await do_clear(dut)

    ########################################
    #    FSM HANDSHAKING TEST
    ########################################

    # Invalid first input
    dut.ui_in.value = 0b00100000
    dut.uio_in.value = 0b01000100
    await ClockCycles(dut.clk, 1)
    assert int(dut.uo_out.value) & 0b00001000, "Should be ready"

    # Valid first input
    dut.ui_in.value = 0b00100001
    dut.uio_in.value = 0b01000100
    await ClockCycles(dut.clk, 1)
    assert int(dut.uo_out.value) & 0b00001000, "Should still be ready"

    # Invalid second input but valid opcode
    dut.ui_in.value = 0b00001100  # instruction_valid but no input2_valid
    dut.uio_in.value = 0b01000100
    await ClockCycles(dut.clk, 1)
    assert int(dut.uo_out.value) & 0b00001000, "Should still be ready"

    # Valid second input and valid MAC opcode
    dut.ui_in.value = (MAC_OP << 3) | 0b110  # input2_valid + instruction_valid
    dut.uio_in.value = 0b01000100
    await ClockCycles(dut.clk, 1)

    # Should be computing (not ready, not valid yet)
    dut.ui_in.value = 0b00000000
    await ClockCycles(dut.clk, 1)

    # Wait for done
    for _ in range(10):
        if int(dut.uo_out.value) & 1:
            break
        await ClockCycles(dut.clk, 1)

    assert int(dut.uo_out.value) & 1, "Should be valid (complete)"

    # Acknowledge
    dut.ui_in.value = 0b00100000
    await ClockCycles(dut.clk, 2)
    assert int(dut.uo_out.value) & 0b00001000, "Should be back to ready"

    await do_clear(dut)

    ########################################
    #    DOT PRODUCT FUZZ TEST
    ########################################

    import random
    random.seed(42)

    NUM_TRIALS = 500
    MAX_DOT_LEN = 16
    num_exact = 0
    num_close = 0
    num_wrong = 0
    worst_cases = []

    for trial in range(NUM_TRIALS):
        dot_len = random.randint(1, MAX_DOT_LEN)
        pairs = [(random.randint(0, 254), random.randint(0, 254)) for _ in range(dot_len)]

        await do_clear(dut)

        # Compute expected using softposit (accumulate products as floats for reference)
        expected_float = 0.0
        for a_bits, b_bits in pairs:
            pa = posit_2(None, 8, a_bits)
            pb = posit_2(None, 8, b_bits)
            expected_float += float(pa) * float(pb)

        # Run on DUT
        for a_bits, b_bits in pairs:
            await do_mac(dut, a_bits, b_bits)

        result_bits = await do_read(dut)
        dut_posit = posit_2(None, 8, bits=result_bits)
        dut_float = float(dut_posit)

        # Compare: find closest posit8 to expected
        best_bits = 0
        best_dist = abs(expected_float)
        for b in range(256):
            candidate = posit_2(None, 8, b)
            dist = abs(float(candidate) - expected_float)
            if dist < best_dist:
                best_dist = dist
                best_bits = b
        expected_posit = posit_2(None, 8, best_bits)

        if result_bits == best_bits:
            num_exact += 1
        elif abs(dut_float - expected_float) <= abs(float(expected_posit) - expected_float) * 2:
            num_close += 1
        else:
            num_wrong += 1
            if len(worst_cases) < 20:
                worst_cases.append((trial, dot_len, expected_float, dut_float, float(expected_posit)))

    print(f"DOT PRODUCT FUZZ: {NUM_TRIALS} trials, len 1-{MAX_DOT_LEN}")
    print(f"  Exact match: {num_exact}")
    print(f"  Close (within 2x nearest): {num_close}")
    print(f"  Wrong: {num_wrong}")
    if worst_cases:
        print("WORST CASES:")
        for trial, dlen, exp, got, nearest in worst_cases:
            print(f"  trial={trial} len={dlen}: expected={exp}, got={got}, nearest_posit={nearest}")
