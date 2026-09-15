"""Least-significant-digit radix sort, with the digit width as a parameter.

The algorithm is the classic one: read the array once to histogram *every*
pass's digits at the same time, turn each histogram into a set of bucket
offsets, then make one stable scatter per pass, least significant digit first.
After the last pass the array is sorted.

The digit width is the parameter `BITS`. It is the only thing that separates
what were four separate hand-written implementations in the code this package
was ported from -- an 8-bit one covering every width, an 11-bit one for 32-bit
values, and 13- and 16-bit ones for 64-bit values, a little over 600 lines in
total. They are the same algorithm, so here they are one function and `BITS` is
a number you can sweep. `benchmarks/bench_bits.mojo` sweeps it.

`BITS` trades passes against histogram size: a `BITS`-wide digit needs
`ceil(width / BITS)` scatters over the data, but `2 ** BITS` counters per pass,
and every one of those counters is written twice (zeroed, then prefix-summed)
whether or not the data is large enough to fill it.
"""

from std.memory import unsafe_memcpy, unsafe_memset_zero
from std.memory.alloc import Allocation, alloc, dealloc
from std.sys.info import bit_width_of

from ._bits import digit, ordered_bits, pass_count


def lsb_radix_sort[
    D: DType,
    origin: MutOrigin,
    //,
    BITS: Int = 8,
](span: Span[Scalar[D], origin]):
    """Sorts `span` in ascending order with an LSD radix sort.

    Allocates one scratch buffer the length of the span plus one histogram,
    and makes at most `ceil(bit_width_of[D]() / BITS)` passes over the data.
    Passes whose digit is constant across the whole span are skipped, so
    narrow data costs fewer passes than its type suggests.

    Each pass scatters elements in the order it reads them, so equal keys keep
    their relative order -- not that two equal scalars can be told apart.

    The histogram counters are `UInt32`, so the span must hold fewer than
    2**32 elements.

    Parameters:
        D: The element type. Signed integers and floats are handled by the
           order-preserving mapping in `_bits`, so every scalar type sorts
           correctly, negatives and all.
        origin: The origin of the span.
        BITS: The digit width, in bits. Must be between 1 and 16.

    Args:
        span: The elements to sort, in place.
    """
    comptime assert 1 <= BITS <= 16, "BITS must be between 1 and 16"

    comptime PASSES = pass_count[D, BITS]()
    comptime BUCKETS = 1 << BITS

    var n = len(span)
    if n < 2:
        return

    var base = span.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    # One histogram per pass, laid end to end in a single allocation. The
    # implementation this was ported from put these on the stack, which at
    # BITS=16 meant a 1 MiB `stack_allocation` -- survivable on an 8 MiB main
    # thread and nowhere else.
    var histograms = alloc[UInt32]({count = PASSES * BUCKETS}).unsafe_leak()
    unsafe_memset_zero(histograms, PASSES * BUCKETS)

    # A single read of the array feeds every pass's histogram and, on the way,
    # answers whether there is anything to do at all.
    var already_sorted = True
    var previous = ordered_bits(base[unsafe_offset=0])
    for i in range(n):
        var key = ordered_bits(base[unsafe_offset=i])
        already_sorted = already_sorted and key >= previous
        previous = key

        comptime for p in range(PASSES):
            var slot = p * BUCKETS + digit[D, BITS](key, p)
            histograms[unsafe_offset=slot] += 1

    if already_sorted:
        dealloc(
            Allocation(
                unsafe_owned_ptr=histograms, layout={count = PASSES * BUCKETS}
            )
        )
        return

    # Element 0's digits identify, for each pass, a bucket known to be
    # occupied. A pass whose histogram puts every element in that one bucket
    # is a no-op -- the scatter would be the identity permutation -- and can be
    # skipped. This is what makes a `uint64` holding only small values cost
    # one pass instead of eight.
    var witness = ordered_bits(base[unsafe_offset=0])

    var scratch = alloc[Scalar[D]]({count = n}).unsafe_leak()
    var flipped = False

    comptime for p in range(PASSES):
        var histogram = histograms.unsafe_offset(p * BUCKETS)
        if histogram[unsafe_offset=digit[D, BITS](witness, p)] != UInt32(n):
            # Exclusive prefix sum: each counter becomes the offset at which
            # its bucket starts.
            var running = UInt32(0)
            for b in range(BUCKETS):
                var count = histogram[unsafe_offset=b]
                histogram[unsafe_offset=b] = running
                running += count

            var src = scratch if flipped else base
            var dst = base if flipped else scratch
            for i in range(n):
                var value = src[unsafe_offset=i]
                var d = digit[D, BITS](ordered_bits(value), p)
                var slot = histogram[unsafe_offset=d]
                histogram[unsafe_offset=d] = slot + 1
                dst[unsafe_offset=Int(slot)] = value
            flipped = not flipped

    if flipped:
        unsafe_memcpy(dest=base, src=scratch, count=n)

    dealloc(Allocation(unsafe_owned_ptr=scratch, layout={count = n}))
    dealloc(
        Allocation(
            unsafe_owned_ptr=histograms, layout={count = PASSES * BUCKETS}
        )
    )
