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
from std.sys.info import CompilationTarget, bit_width_of

from ._bits import digit, ordered_bits, pass_count

comptime _TABLE_BUDGET = 64 * 1024 if (
    CompilationTarget.is_apple_silicon()
) else 16 * 1024
"""Bytes of counter the counting pass may spend, which decides how many
private histograms it keeps.

There is no way to ask the target how large its L1 data cache is, so this is a
constant per architecture. Both numbers are half of a typical L1 -- 128 KiB on
Apple silicon, 32 KiB on x86 -- and the half is deliberate: the counting pass
does not have the cache to itself, and spending all of it there costs the
scatter passes more than it saves. See `_table_count`.

Only the Apple silicon figure has been measured. The other is a guess shaped
to be safe rather than fast."""

comptime _MAX_TABLES = 4
"""Beyond four the measured curve is flat."""

comptime _FOLD_MARGIN = 8
"""How many times the counting work must exceed the fold before the private
tables are worth building.

Folding costs `(tables - 1) * PASSES * BUCKETS` additions whatever `n` is,
while counting costs `n * PASSES` increments, so on a short span the fold is
the larger of the two. At `n = 4096` with `BITS=11` it is 6144 additions
against 12288 increments, and the first version of this shipped without the
check and made that case **19% slower** -- 2.08 to 2.47 ns/element. The
re-measured digit-width table is what caught it."""


def _table_count[PASSES: Int, BUCKETS: Int]() -> Int:
    """Returns how many private histograms fit the budget.

    Successive increments into one table are a load-modify-store chain, and
    two elements in a row landing in the same bucket make the second wait on
    the first. Dealing elements round robin into a few private tables breaks
    that dependency. Counting a million elements at `BITS=11`, in isolation:

    | tables | bytes | uint32 | float32 | uint64 |
    | ---: | ---: | ---: | ---: | ---: |
    | 1 | 24/48 KiB | 619 us | 767 us | 1123 us |
    | 2 | 48/96 KiB | 576 | 698 | **1065** |
    | 4 | 96/192 KiB | **571** | **672** | 1735 |

    **That table is why the budget is half of L1 rather than all of it.** Read
    on its own it argues for four tables, 96 KiB, on a 128 KiB machine. Put
    back into the sort, four tables made `uint32` 2-3% *slower*: the counting
    pass shares the cache with the scatter passes that follow it, and tables
    that fit L1 on their own do not fit alongside the data being streamed. An
    isolated measurement of a phase does not predict the whole.

    At half the budget this picks two tables for a 32-bit type at `BITS=11`
    and one for a 64-bit one, and the whole sort moves like this:

    | | before | after |
    | --- | ---: | ---: |
    | float32, BITS=11 | 2689 us | **2593** |
    | uint32, BITS=8 | 2835 | **2783** |
    | uint32, BITS=11 | 2123 | 2125 |
    | int32, BITS=11 | 2116 | 2110 |
    | uint64, BITS=11 | 4434 | 4396 |

    So: worth 3-4% where the order-preserving map does real work, which is the
    float types, and level everywhere else. The counting pass is a quarter of
    the sort and this takes 8-19% off it, which is the whole of the arithmetic
    -- there is no larger number hiding here.

    Narrower counters were tried alongside this and are not worth it. A
    counter has to hold up to `n`; sixteen-bit ones are wrong as soon as a
    digit is constant across the span, which is exactly the case the
    pass-skipping below exists for; and draining them often enough to stay
    correct costs more than the smaller tables save.
    """
    var tables = _MAX_TABLES
    while tables > 1 and tables * PASSES * BUCKETS * 4 > _TABLE_BUDGET:
        tables //= 2
    return tables


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
    2**32 elements. Narrower counters were tried and are not worth it: a
    counter has to hold up to `n`, a digit that is constant across the span
    puts every element in one bucket -- which is exactly the case the
    pass-skipping below exists for -- and draining sixteen-bit counters often
    enough to stay correct costs more than the smaller tables save.

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

    # One histogram per pass, laid end to end, and `TABLES` private copies of
    # that laid end to end again. The implementation this was ported from put
    # these on the stack, which at BITS=16 meant a 1 MiB `stack_allocation` --
    # survivable on an 8 MiB main thread and nowhere else.
    comptime TABLES = _table_count[PASSES, BUCKETS]()
    comptime TABLE = PASSES * BUCKETS
    comptime COUNTERS = TABLES * TABLE
    var histograms = alloc[UInt32]({count = COUNTERS}).unsafe_leak()
    unsafe_memset_zero(histograms, COUNTERS)

    # A single read of the array feeds every pass's histogram and, on the way,
    # answers whether there is anything to do at all. Elements are dealt round
    # robin into the private tables so that consecutive increments land in
    # different ones; see `_table_count` for what that buys.
    var already_sorted = True
    var previous = ordered_bits(base[unsafe_offset=0])
    var i = 0
    var folding = False
    comptime if TABLES > 1:
        # Only worth the fold on a span long enough to amortise it.
        if n >= _FOLD_MARGIN * (TABLES - 1) * BUCKETS:
            folding = True
            var whole = n - (n % TABLES)
            while i < whole:
                comptime for t in range(TABLES):
                    var key = ordered_bits(base[unsafe_offset=i + t])
                    already_sorted = already_sorted and key >= previous
                    previous = key
                    comptime for p in range(PASSES):
                        var slot = (
                            t * TABLE + p * BUCKETS + digit[D, BITS](key, p)
                        )
                        histograms[unsafe_offset=slot] += 1
                i += TABLES

    # Whatever that loop did not take -- which is all of it when the span was
    # too short to bother -- goes straight into the first table.
    while i < n:
        var key = ordered_bits(base[unsafe_offset=i])
        already_sorted = already_sorted and key >= previous
        previous = key
        comptime for p in range(PASSES):
            histograms[unsafe_offset=p * BUCKETS + digit[D, BITS](key, p)] += 1
        i += 1

    # Fold the private tables into the first one, which everything below reads.
    comptime if TABLES > 1:
        if folding:
            for slot in range(TABLE):
                var total = histograms[unsafe_offset=slot]
                comptime for t in range(1, TABLES):
                    total += histograms[unsafe_offset=t * TABLE + slot]
                histograms[unsafe_offset=slot] = total

    if already_sorted:
        dealloc(
            Allocation(unsafe_owned_ptr=histograms, layout={count = COUNTERS})
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
    dealloc(Allocation(unsafe_owned_ptr=histograms, layout={count = COUNTERS}))
