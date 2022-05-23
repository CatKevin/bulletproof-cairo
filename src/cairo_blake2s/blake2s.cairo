from starkware.cairo.common.alloc import alloc
from src.cairo_blake2s.packed_blake2s import N_PACKED_INSTANCES, blake2s_compress
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin
from starkware.cairo.common.math import assert_nn_le, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.memset import memset
from starkware.cairo.common.pow import pow
from starkware.cairo.common.registers import get_fp_and_pc, get_label_location

const INPUT_BLOCK_FELTS = 16
const INPUT_BLOCK_BYTES = 64
const STATE_SIZE_FELTS = 8
# Each instance consists of 8 words for the input state, 16 words of message, 2 words for t0 and f0,
# and 8 words for the output state.
const INSTANCE_SIZE = STATE_SIZE_FELTS + INPUT_BLOCK_FELTS + 2 + STATE_SIZE_FELTS

# Computes blake2s of 'input'.
# To use this function, split the input into words of 32 bits (little endian).
# For example, to compute blake2s('Hello world'), use:
#   input = [1819043144, 1870078063, 6581362]
# where:
#   1819043144 == int.from_bytes(b'Hell', 'little')
#   1870078063 == int.from_bytes(b'o wo', 'little')
#   6581362 == int.from_bytes(b'rld', 'little')
#
# output is an array of 8 32-bit words (little endian).
#
# Note: You must call finalize_blake2s() at the end of the program. Otherwise, this function
# is not sound and a malicious prover may return a wrong result.
# Note: the interface of this function may change in the future.
func blake2s{range_check_ptr, blake2s_ptr : felt*}(data : felt*, n_bytes : felt) -> (
        output : felt*):
    # Set the initial state to IV (IV[0] is modified).
    assert blake2s_ptr[0] = 0x6B08E647  # IV[0] ^ 0x01010020 (config: no key, 32 bytes output).
    assert blake2s_ptr[1] = 0xBB67AE85
    assert blake2s_ptr[2] = 0x3C6EF372
    assert blake2s_ptr[3] = 0xA54FF53A
    assert blake2s_ptr[4] = 0x510E527F
    assert blake2s_ptr[5] = 0x9B05688C
    assert blake2s_ptr[6] = 0x1F83D9AB
    assert blake2s_ptr[7] = 0x5BE0CD19
    static_assert STATE_SIZE_FELTS == 8
    let blake2s_ptr = blake2s_ptr + STATE_SIZE_FELTS

    let (output) = blake2s_inner(data=data, n_bytes=n_bytes, counter=0)
    return (output)
end

# Inner loop for blake2s. blake2s_ptr points to the middle of an instance: after the initial state,
# before the message.
func blake2s_inner{range_check_ptr, blake2s_ptr : felt*}(
        data : felt*, n_bytes : felt, counter : felt) -> (output : felt*):
    alloc_locals
    let (is_last_block) = is_le(n_bytes, INPUT_BLOCK_BYTES)
    if is_last_block != 0:
        return blake2s_last_block(data=data, n_bytes=n_bytes, counter=counter)
    end

    memcpy(blake2s_ptr, data, INPUT_BLOCK_FELTS)
    let blake2s_ptr = blake2s_ptr + INPUT_BLOCK_FELTS

    assert blake2s_ptr[0] = counter + INPUT_BLOCK_BYTES  # n_bytes.
    assert blake2s_ptr[1] = 0  # Is last byte = False.
    let blake2s_ptr = blake2s_ptr + 2

    # Write output.
    let output = blake2s_ptr
    %{
        from src.cairo_blake2s.blake2s_utils import compute_blake2s_func
        compute_blake2s_func(segments=segments, output_ptr=ids.output)
    %}
    let blake2s_ptr = blake2s_ptr + STATE_SIZE_FELTS

    # Write the current output to the input state for the next instance.
    memcpy(blake2s_ptr, output, STATE_SIZE_FELTS)
    let blake2s_ptr = blake2s_ptr + STATE_SIZE_FELTS
    return blake2s_inner(
        data=data + INPUT_BLOCK_FELTS,
        n_bytes=n_bytes - INPUT_BLOCK_BYTES,
        counter=counter + INPUT_BLOCK_BYTES)
end

func blake2s_last_block{range_check_ptr, blake2s_ptr : felt*}(
        data : felt*, n_bytes : felt, counter : felt) -> (output : felt*):
    alloc_locals
    let (n_felts, _) = unsigned_div_rem(n_bytes + 3, 4)
    memcpy(blake2s_ptr, data, n_felts)
    memset(blake2s_ptr + n_felts, 0, INPUT_BLOCK_FELTS - n_felts)
    let blake2s_ptr = blake2s_ptr + INPUT_BLOCK_FELTS

    assert blake2s_ptr[0] = counter + n_bytes  # n_bytes.
    assert blake2s_ptr[1] = 0xffffffff  # Is last byte = True.
    let blake2s_ptr = blake2s_ptr + 2

    # Write output.
    let output = blake2s_ptr
    %{
        from src.cairo_blake2s.blake2s_utils import compute_blake2s_func
        compute_blake2s_func(segments=segments, output_ptr=ids.output)
    %}
    let blake2s_ptr = blake2s_ptr + STATE_SIZE_FELTS

    return (output=output)
end

# Verifies that the results of blake2s() are valid.
func finalize_blake2s{range_check_ptr, bitwise_ptr : BitwiseBuiltin*}(
        blake2s_ptr_start : felt*, blake2s_ptr_end : felt*):
    alloc_locals

    let (__fp__, _) = get_fp_and_pc()

    let (sigma) = _get_sigma()

    tempvar n = (blake2s_ptr_end - blake2s_ptr_start) / INSTANCE_SIZE
    if n == 0:
        return ()
    end

    %{
        # Add dummy pairs of input and output.
        from src.cairo_blake2s.blake2s_utils import IV, blake2s_compress

        _n_packed_instances = int(ids.N_PACKED_INSTANCES)
        assert 0 <= _n_packed_instances < 20
        _blake2s_input_chunk_size_felts = int(ids.INPUT_BLOCK_FELTS)
        assert 0 <= _blake2s_input_chunk_size_felts < 100

        message = [0] * _blake2s_input_chunk_size_felts
        modified_iv = [IV[0] ^ 0x01010020] + IV[1:]
        output = blake2s_compress(
            message=message,
            h=modified_iv,
            t0=0,
            t1=0,
            f0=0xffffffff,
            f1=0,
        )
        padding = (modified_iv + message + [0, 0xffffffff] + output) * (_n_packed_instances - 1)
        segments.write_arg(ids.blake2s_ptr_end, padding)
    %}

    # Compute the amount of chunks (rounded up).
    let (local n_chunks, _) = unsigned_div_rem(n + N_PACKED_INSTANCES - 1, N_PACKED_INSTANCES)
    let blake2s_ptr = blake2s_ptr_start
    _finalize_blake2s_inner{blake2s_ptr=blake2s_ptr}(n=n_chunks, sigma=sigma)
    return ()
end

func _get_sigma() -> (sigma : felt*):
    alloc_locals
    let (sigma_address) = get_label_location(data)
    return (sigma=cast(sigma_address, felt*))

    data:
    dw 0
    dw 1
    dw 2
    dw 3
    dw 4
    dw 5
    dw 6
    dw 7
    dw 8
    dw 9
    dw 10
    dw 11
    dw 12
    dw 13
    dw 14
    dw 15
    dw 14
    dw 10
    dw 4
    dw 8
    dw 9
    dw 15
    dw 13
    dw 6
    dw 1
    dw 12
    dw 0
    dw 2
    dw 11
    dw 7
    dw 5
    dw 3
    dw 11
    dw 8
    dw 12
    dw 0
    dw 5
    dw 2
    dw 15
    dw 13
    dw 10
    dw 14
    dw 3
    dw 6
    dw 7
    dw 1
    dw 9
    dw 4
    dw 7
    dw 9
    dw 3
    dw 1
    dw 13
    dw 12
    dw 11
    dw 14
    dw 2
    dw 6
    dw 5
    dw 10
    dw 4
    dw 0
    dw 15
    dw 8
    dw 9
    dw 0
    dw 5
    dw 7
    dw 2
    dw 4
    dw 10
    dw 15
    dw 14
    dw 1
    dw 11
    dw 12
    dw 6
    dw 8
    dw 3
    dw 13
    dw 2
    dw 12
    dw 6
    dw 10
    dw 0
    dw 11
    dw 8
    dw 3
    dw 4
    dw 13
    dw 7
    dw 5
    dw 15
    dw 14
    dw 1
    dw 9
    dw 12
    dw 5
    dw 1
    dw 15
    dw 14
    dw 13
    dw 4
    dw 10
    dw 0
    dw 7
    dw 6
    dw 3
    dw 9
    dw 2
    dw 8
    dw 11
    dw 13
    dw 11
    dw 7
    dw 14
    dw 12
    dw 1
    dw 3
    dw 9
    dw 5
    dw 0
    dw 15
    dw 4
    dw 8
    dw 6
    dw 2
    dw 10
    dw 6
    dw 15
    dw 14
    dw 9
    dw 11
    dw 3
    dw 0
    dw 8
    dw 12
    dw 2
    dw 13
    dw 7
    dw 1
    dw 4
    dw 10
    dw 5
    dw 10
    dw 2
    dw 8
    dw 4
    dw 7
    dw 6
    dw 1
    dw 5
    dw 15
    dw 11
    dw 9
    dw 14
    dw 3
    dw 12
    dw 13
    dw 0
end

# Handles n chunks of N_PACKED_INSTANCES blake2s instances.
func _finalize_blake2s_inner{range_check_ptr, bitwise_ptr : BitwiseBuiltin*, blake2s_ptr : felt*}(
        n : felt, sigma : felt*):
    if n == 0:
        return ()
    end

    alloc_locals
    let blake2s_start = blake2s_ptr

    # Load instance data.
    let (local data : felt*) = alloc()
    _pack_ints(INSTANCE_SIZE, data)

    let input_state : felt* = data
    let message : felt* = input_state + STATE_SIZE_FELTS
    let t0_and_f0 : felt* = message + INPUT_BLOCK_FELTS
    let output_state : felt* = t0_and_f0 + 2

    # Run blake2s on N_PACKED_INSTANCES instances.
    blake2s_compress(
        h=input_state,
        message=message,
        t0=t0_and_f0[0],
        f0=t0_and_f0[1],
        sigma=sigma,
        output=output_state)
    let blake2s_ptr = blake2s_start + INSTANCE_SIZE * N_PACKED_INSTANCES

    return _finalize_blake2s_inner(n=n - 1, sigma=sigma)
end

# Given N_PACKED_INSTANCES sets of m (32-bit) integers in the blake2s implicit argument,
# where each set starts at offset INSTANCE_SIZE from the previous set,
# computes m packed integers.
# blake2s_ptr is advanced m steps (just after the first set).
func _pack_ints{range_check_ptr, blake2s_ptr : felt*}(m, packed_values : felt*):
    static_assert N_PACKED_INSTANCES == 7
    alloc_locals

    local MAX_VALUE = 2 ** 32 - 1

    tempvar packed_values = packed_values
    tempvar blake2s_ptr = blake2s_ptr
    tempvar range_check_ptr = range_check_ptr
    tempvar m = m

    loop:
    tempvar x0 = blake2s_ptr[0 * INSTANCE_SIZE]
    assert [range_check_ptr + 0] = x0
    assert [range_check_ptr + 1] = MAX_VALUE - x0
    tempvar x1 = blake2s_ptr[1 * INSTANCE_SIZE]
    assert [range_check_ptr + 2] = x1
    assert [range_check_ptr + 3] = MAX_VALUE - x1
    tempvar x2 = blake2s_ptr[2 * INSTANCE_SIZE]
    assert [range_check_ptr + 4] = x2
    assert [range_check_ptr + 5] = MAX_VALUE - x2
    tempvar x3 = blake2s_ptr[3 * INSTANCE_SIZE]
    assert [range_check_ptr + 6] = x3
    assert [range_check_ptr + 7] = MAX_VALUE - x3
    tempvar x4 = blake2s_ptr[4 * INSTANCE_SIZE]
    assert [range_check_ptr + 8] = x4
    assert [range_check_ptr + 9] = MAX_VALUE - x4
    tempvar x5 = blake2s_ptr[5 * INSTANCE_SIZE]
    assert [range_check_ptr + 10] = x5
    assert [range_check_ptr + 11] = MAX_VALUE - x5
    tempvar x6 = blake2s_ptr[6 * INSTANCE_SIZE]
    assert [range_check_ptr + 12] = x6
    assert [range_check_ptr + 13] = MAX_VALUE - x6
    assert packed_values[0] = x0 + 2 ** 35 * x1 + 2 ** (35 * 2) * x2 + 2 ** (35 * 3) * x3 +
        2 ** (35 * 4) * x4 + 2 ** (35 * 5) * x5 + 2 ** (35 * 6) * x6

    tempvar packed_values = packed_values + 1
    tempvar blake2s_ptr = blake2s_ptr + 1
    tempvar range_check_ptr = range_check_ptr + 14
    tempvar m = m - 1
    jmp loop if m != 0

    return ()
end
