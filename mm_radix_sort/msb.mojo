"""Most-significant-digit radix sorts: partition, then recurse into buckets.

Where an LSD sort makes a fixed number of passes over the whole array, an MSD
sort splits on the top digit first and then sorts each bucket independently.
That has two consequences. It stops early -- once a bucket holds one element,
or few enough to hand to a comparison sort, the remaining digits are never
looked at -- and it recurses, so each sub-problem soon fits in cache.

Two variants live here, and the difference between them is only how the
partition step moves elements:

- `msb_radix_sort` copies the range aside and scatters it back. Two moves per
  element per level, one scratch buffer for the whole recursion.
- `american_flag_sort` permutes in place with cyclic swaps. No scratch at all,
  but the swap loop reloads and re-extracts a digit for every element it steps
  over.
"""

from std.memory import stack_allocation, unsafe_memcpy
from std.memory.alloc import Allocation, alloc, dealloc

from ._bits import digit, ordered_bits, pass_count

comptime _COUNTER_BLOCK = 513
"""Counters one recursion level needs: 256 for the histogram, then 257 bucket
starts with a sentinel so the last bucket's end is readable."""

comptime _COMPARISON_CUTOFF = 64
"""Below this many elements a bucket is handed to the comparison sort instead
of being partitioned again. A radix pass costs a histogram of 256 counters
however few elements it is given, which stops paying for itself long before
the bucket is empty."""


@always_inline
def _partition_counts[
    D: DType, origin: Origin, //
](
    span: Span[Scalar[D], origin],
    level: Int,
    counts: Pointer[UInt32, MutUntrackedOrigin],
) -> Bool:
    """Histograms `span`'s digits at `level` and reports whether they ascend.

    Parameters:
        D: The element type.
        origin: The origin of the span.

    Args:
        span: The range to histogram.
        level: Which digit to read, counting from the least significant.
        counts: 256 zeroed counters to fill.

    Returns:
        True if the digits are already non-decreasing across the range, in
        which case the range is already partitioned on this digit and the
        permutation step can be skipped.
    """
    var ptr = span.unsafe_ptr()
    var previous = digit[D, 8](ordered_bits(ptr[unsafe_offset=0]), level)
    var ascending = True
    for i in range(len(span)):
        var bucket = digit[D, 8](ordered_bits(ptr[unsafe_offset=i]), level)
        ascending = ascending and bucket >= previous
        previous = bucket
        counts[unsafe_offset=bucket] += 1
    return ascending


def _msb_radix_sort[
    D: DType,
    origin: MutOrigin,
    //,
](
    span: Span[Scalar[D], origin],
    level: Int,
    scratch: Pointer[Scalar[D], MutUntrackedOrigin],
    counts: Pointer[UInt32, MutUntrackedOrigin],
):
    """Sorts one range on digit `level` and recurses into its buckets."""
    var n = len(span)
    if n <= _COMPARISON_CUTOFF:
        sort(span)
        return

    # counts[0:256] histogram, bounds[0:257] bucket starts with a sentinel.
    # One such block per recursion level, carved out of the caller's block.
    var bounds = counts.unsafe_offset(256)
    for i in range(_COUNTER_BLOCK):
        counts[unsafe_offset=i] = 0

    var ascending = _partition_counts(span, level, counts)
    var base = span.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    var running = UInt32(0)
    for b in range(256):
        bounds[unsafe_offset=b] = running
        running += counts[unsafe_offset=b]
    bounds[unsafe_offset=256] = running

    if not ascending:
        # Copy the range aside, then scatter it back into bucket order. The
        # cursor walks `counts`, which is dead after the prefix sum above.
        unsafe_memcpy(dest=scratch, src=base, count=n)
        for b in range(256):
            counts[unsafe_offset=b] = bounds[unsafe_offset=b]
        for i in range(n):
            var value = scratch[unsafe_offset=i]
            var bucket = digit[D, 8](ordered_bits(value), level)
            var slot = counts[unsafe_offset=bucket]
            counts[unsafe_offset=bucket] = slot + 1
            base[unsafe_offset=Int(slot)] = value

    if level == 0:
        return

    for b in range(256):
        var start = Int(bounds[unsafe_offset=b])
        var count = Int(bounds[unsafe_offset=b + 1]) - start
        if count > 1:
            _msb_radix_sort(
                span.unsafe_subspan(offset=start, length=count),
                level - 1,
                scratch.unsafe_offset(start),
                counts.unsafe_offset(_COUNTER_BLOCK),
            )


def msb_radix_sort[
    D: DType, origin: MutOrigin, //
](span: Span[Scalar[D], origin]):
    """Sorts `span` in ascending order with an out-of-place MSD radix sort.

    Partitions on the most significant byte, then recurses into each bucket
    that holds more than one element, handing small buckets to the comparison
    sort. One scratch buffer the length of the span is allocated up front and
    reused by every level of the recursion.

    Each level scatters elements in the order it reads them, so equal keys keep
    their relative order -- not that two equal scalars can be told apart.

    Parameters:
        D: The element type. Signed integers and floats sort correctly.
        origin: The origin of the span.

    Args:
        span: The elements to sort, in place.
    """
    var n = len(span)
    if n <= 1:
        return
    comptime LEVELS = pass_count[D, 8]()
    comptime COUNTERS = LEVELS * _COUNTER_BLOCK
    var scratch = alloc[Scalar[D]]({count = n}).unsafe_leak()
    var counts = alloc[UInt32]({count = COUNTERS}).unsafe_leak()
    _msb_radix_sort(span, LEVELS - 1, scratch, counts)
    dealloc(Allocation(unsafe_owned_ptr=counts, layout={count = COUNTERS}))
    dealloc(Allocation(unsafe_owned_ptr=scratch, layout={count = n}))


def _american_flag_sort[
    D: DType,
    origin: MutOrigin,
    //,
](
    span: Span[Scalar[D], origin],
    level: Int,
    counts: Pointer[UInt32, MutUntrackedOrigin],
):
    """Sorts one range on digit `level` in place and recurses into buckets."""
    var n = len(span)
    if n <= _COMPARISON_CUTOFF:
        sort(span)
        return

    # counts[0:256] histogram, bounds[0:257] bucket starts with a sentinel.
    # One such block per recursion level, carved out of the caller's block.
    var bounds = counts.unsafe_offset(256)
    for i in range(_COUNTER_BLOCK):
        counts[unsafe_offset=i] = 0

    var ascending = _partition_counts(span, level, counts)

    var running = UInt32(0)
    for b in range(256):
        bounds[unsafe_offset=b] = running
        running += counts[unsafe_offset=b]
    bounds[unsafe_offset=256] = running

    if not ascending:
        # The American flag permutation. `counts` is reused as the per-bucket
        # write head. An element whose bucket is already full must already sit
        # inside that bucket -- a full bucket holds exactly its own count of
        # elements, so none of them can be elsewhere -- and the cursor steps
        # over it.
        for b in range(256):
            counts[unsafe_offset=b] = bounds[unsafe_offset=b]
        var cursor = 0
        while cursor < n:
            var ptr = span.unsafe_ptr()
            var bucket = digit[D, 8](
                ordered_bits(ptr[unsafe_offset=cursor]), level
            )
            var head = Int(counts[unsafe_offset=bucket])
            if head == Int(bounds[unsafe_offset=bucket + 1]):
                cursor += 1
                continue
            if head == cursor:
                cursor += 1
            else:
                span.unsafe_swap_elements(cursor, head)
            counts[unsafe_offset=bucket] = UInt32(head + 1)

    if level == 0:
        return

    for b in range(256):
        var start = Int(bounds[unsafe_offset=b])
        var count = Int(bounds[unsafe_offset=b + 1]) - start
        if count > 1:
            _american_flag_sort(
                span.unsafe_subspan(offset=start, length=count),
                level - 1,
                counts.unsafe_offset(_COUNTER_BLOCK),
            )


def american_flag_sort[
    D: DType, origin: MutOrigin, //
](span: Span[Scalar[D], origin]):
    """Sorts `span` in ascending order in place, touching no heap memory.

    An MSD radix sort whose partition step is a cyclic permutation rather than
    a scatter into scratch, so the whole sort runs in the caller's buffer. The
    counters live on the stack: about 2 KiB per byte of element width, so 8 KiB
    for a 32-bit type and 16 KiB for a 64-bit one.

    This is the variant to reach for when the allocation matters more than the
    throughput. It is measurably the slowest thing in the package -- on 4096
    elements it loses to the stdlib's `sort` outright -- and `msb_radix_sort`,
    which differs only in permuting through a scratch buffer, is usually two
    to three times faster.

    Equal elements are not kept in their original order.

    Parameters:
        D: The element type. Signed integers and floats sort correctly.
        origin: The origin of the span.

    Args:
        span: The elements to sort, in place.
    """
    if len(span) <= 1:
        return
    comptime LEVELS = pass_count[D, 8]()
    var counts = stack_allocation[LEVELS * _COUNTER_BLOCK, DType.uint32]()
    _american_flag_sort(span, LEVELS - 1, counts)
