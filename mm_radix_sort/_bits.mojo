"""The order-preserving bit mapping every radix sort in this package shares.

A radix sort compares *digits of an unsigned integer*, so before it can touch a
value it needs a bijection from that value's type onto an unsigned integer of
the same width that preserves ordering: `a < b` must imply
`ordered_bits(a) < ordered_bits(b)` under unsigned comparison.

For unsigned integers that map is the identity. For two's-complement signed
integers it is a flip of the sign bit, which moves the negative half below the
positive half. For IEEE 754 floats it is: flip the sign bit of a positive
number, flip *every* bit of a negative one -- which both moves negatives below
positives and reverses their internally ascending magnitude order.

Defining it once, here, is deliberate. The implementation this package was
ported from carried six near-identical copies of this flip across four files,
two of which had drifted apart; `radix_sorting13.mojo` and `radix_sorting16.mojo`
held byte-for-byte identical versions of the same 20 lines.
"""

from std.memory import bitcast
from std.sys.info import bit_width_of


@always_inline
def unsigned_dtype[D: DType]() -> DType:
    """Returns the unsigned integer `DType` of the same bit width as `D`.

    Parameters:
        D: The type whose width is to be matched.

    Returns:
        One of `uint8`, `uint16`, `uint32` or `uint64`.
    """
    comptime W = bit_width_of[D]()
    return (
        DType.uint8 if W
        == 8 else DType.uint16 if W
        == 16 else DType.uint32 if W
        == 32 else DType.uint64
    )


@always_inline
def ordered_bits[D: DType, //](value: Scalar[D]) -> Scalar[unsigned_dtype[D]()]:
    """Maps `value` onto an unsigned integer that sorts in the same order.

    Parameters:
        D: The element type.

    Args:
        value: The value to map.

    Returns:
        An unsigned integer of the same width whose unsigned ordering matches
        the natural ordering of `D`.
    """
    comptime U = unsigned_dtype[D]()
    comptime W = bit_width_of[D]()
    comptime SIGN = Scalar[U](1) << Scalar[U](W - 1)

    comptime if D.is_floating_point():
        var raw = bitcast[U](value)
        # Arithmetic-shifting the sign bit down to all-ones (for a negative)
        # or all-zeros (for a positive), then forcing the sign bit on.
        var mask = (Scalar[U](0) - (raw >> Scalar[U](W - 1))) | SIGN
        return raw ^ mask
    elif D.is_signed():
        return bitcast[U](value) ^ SIGN
    else:
        return bitcast[U](value)


@always_inline
def digit[
    D: DType, BITS: Int
](key: Scalar[unsigned_dtype[D]()], pass_index: Int) -> Int:
    """Extracts the `pass_index`-th `BITS`-wide digit of an ordered key.

    Digits are numbered from the least significant end, so pass 0 sees the low
    `BITS` bits. The top digit of a key whose width is not a multiple of `BITS`
    is short, which is harmless: the bits above the width are always zero and
    the corresponding buckets stay empty.

    Parameters:
        D: The element type the key came from.
        BITS: The digit width.

    Args:
        key: An ordered key, as returned by `ordered_bits`.
        pass_index: Which digit to read.

    Returns:
        The digit, in `[0, 1 << BITS)`.
    """
    comptime U = unsigned_dtype[D]()
    comptime MASK = (Scalar[U](1) << Scalar[U](BITS)) - 1
    return Int((key >> Scalar[U](pass_index * BITS)) & MASK)


@always_inline
def pass_count[D: DType, BITS: Int]() -> Int:
    """Returns how many `BITS`-wide digits cover a value of type `D`.

    Parameters:
        D: The element type.
        BITS: The digit width.

    Returns:
        `ceil(bit_width_of[D]() / BITS)`.
    """
    return (bit_width_of[D]() + BITS - 1) // BITS
