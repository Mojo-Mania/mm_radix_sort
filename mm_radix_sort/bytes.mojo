"""Radix sort over variable-length byte keys, and the string sort built on it.

Everything in `lsb.mojo` and `msb.mojo` assumes a fixed-width key that fits in
a machine integer. This file drops that assumption: a key here is a sequence of
bytes of any length, produced one byte at a time by a function the caller
supplies. Strings are the obvious case, but so is a struct sorted on a
composite key, or a fixed-width integer exposed most significant byte first.

The partition uses **257 buckets, not 256**. Bucket 0 means *this key has no
byte at this depth* and every real byte `b` lands in bucket `b + 1`, which is
what makes `"ab"` sort before `"abc"` without a length comparison anywhere. It
also removes the read that made the ported implementation reach past the end of
a string: keys that have run out are answered by the extractor, not by loading
a byte that is not there.

The permutation is the in-place American flag cycle, so this sorts move-only
elements -- it only ever swaps them, never copies.
"""

from std.memory import stack_allocation

comptime _BYTE_BUCKETS = 257
"""Bucket 0 for an exhausted key, plus one bucket per byte value."""

comptime _COUNTER_BLOCK = _BYTE_BUCKETS * 2 + 1
"""Counters one recursion level needs: 257 for the histogram, then 258 bucket
starts with a sentinel so the last bucket's end is readable."""

comptime _COMPARISON_CUTOFF = 48
"""Below this many elements a bucket is handed to insertion sort. A radix pass
costs a 257-counter histogram however few elements it is given."""


def _insertion_sort[
    T: Movable,
    origin: MutOrigin,
    //,
    less: def(imm T, imm T, Int) capturing[_] -> Bool,
](span: Span[T, origin], depth: Int):
    """Sorts a short range by swapping neighbours, never copying an element.

    Every element in the range agrees on its first `depth` key bytes -- that
    is what put them in the same bucket -- so `less` is told to start there.
    Skipping the shared prefix is what keeps the cutoff cheap on data that is
    mostly prefix, such as a list of paths or namespaced identifiers.
    """
    for i in range(1, len(span)):
        var j = i
        while j > 0 and less(span[j], span[j - 1], depth):
            span.unsafe_swap_elements(j, j - 1)
            j -= 1


def _byte_radix_sort[
    T: Movable,
    origin: MutOrigin,
    //,
    byte_of: def(imm T, Int) capturing[_] -> Int,
    less: def(imm T, imm T, Int) capturing[_] -> Bool,
](span: Span[T, origin], depth: Int):
    """Sorts one range on the byte at `depth` and recurses into its buckets."""
    var n = len(span)
    if n <= _COMPARISON_CUTOFF:
        _insertion_sort[less](span, depth)
        return

    # counts[0:257] histogram, bounds[0:258] bucket starts with a sentinel.
    var counts = stack_allocation[_COUNTER_BLOCK, DType.uint32]()
    var bounds = counts.unsafe_offset(_BYTE_BUCKETS)
    for i in range(_COUNTER_BLOCK):
        counts[unsafe_offset=i] = 0

    var previous = byte_of(span[0], depth) + 1
    var ascending = True
    for i in range(n):
        var bucket = byte_of(span[i], depth) + 1
        ascending = ascending and bucket >= previous
        previous = bucket
        counts[unsafe_offset=bucket] += 1

    # Every key has run out, so every element in this range compares equal.
    if counts[unsafe_offset=0] == UInt32(n):
        return

    var running = UInt32(0)
    for b in range(_BYTE_BUCKETS):
        bounds[unsafe_offset=b] = running
        running += counts[unsafe_offset=b]
    bounds[unsafe_offset=_BYTE_BUCKETS] = running

    if not ascending:
        for b in range(_BYTE_BUCKETS):
            counts[unsafe_offset=b] = bounds[unsafe_offset=b]
        var cursor = 0
        while cursor < n:
            var bucket = byte_of(span[cursor], depth) + 1
            var head = Int(counts[unsafe_offset=bucket])
            if head == Int(bounds[unsafe_offset=bucket + 1]):
                cursor += 1
                continue
            if head == cursor:
                cursor += 1
            else:
                span.unsafe_swap_elements(cursor, head)
            counts[unsafe_offset=bucket] = UInt32(head + 1)

    # Bucket 0 holds the keys that ended here. They are all equal, so they
    # are done; only the buckets that still have bytes left are recursed into.
    for b in range(1, _BYTE_BUCKETS):
        var start = Int(bounds[unsafe_offset=b])
        var count = Int(bounds[unsafe_offset=b + 1]) - start
        if count > 1:
            _byte_radix_sort[byte_of, less](
                span.unsafe_subspan(offset=start, length=count), depth + 1
            )


def byte_radix_sort[
    T: Movable,
    origin: MutOrigin,
    //,
    byte_of: def(imm T, Int) capturing[_] -> Int,
    less: def(imm T, imm T, Int) capturing[_] -> Bool,
](span: Span[T, origin]):
    """Sorts `span` by a variable-length byte key, in place and off the heap.

    Equal keys are **not** kept in their original order: the partition is a
    cyclic permutation, which reorders within a bucket. That is invisible when
    the key is the whole element, and very visible when the element carries a
    payload the key does not cover.

    `byte_of(element, depth)` returns the `depth`-th byte of that element's
    sort key as an `Int` in `[0, 256)`, or **-1** when the key has no byte at
    that depth. Depth starts at 0 and the key is read most significant byte
    first, so a key that is a prefix of another sorts before it.

    `less(a, b, depth)` orders two elements that are already known to agree on
    their first `depth` key bytes, and is used for ranges small enough to hand
    to insertion sort. It must agree with the order `byte_of` implies. Reading
    from `depth` rather than from 0 is what keeps the cutoff cheap on keys that
    are mostly shared prefix; ignoring `depth` is always correct, just slower.

    Both must be declared `capturing`, whether or not they capture anything:

    ```mojo
    from mm_radix_sort import byte_radix_sort

    var rows = [(3, "c"), (1, "a"), (2, "b")]

    def key_byte(imm row: Tuple[Int, String], depth: Int) capturing -> Int:
        # A 2-byte big-endian key over row's first field.
        if depth >= 2:
            return -1
        return (row[0] >> ((1 - depth) * 8)) & 255

    def row_less(
        imm a: Tuple[Int, String], imm b: Tuple[Int, String], depth: Int
    ) capturing -> Bool:
        return a[0] < b[0]

    var span = Span(rows)
    byte_radix_sort[key_byte, row_less](span)
    ```

    Recursion depth is bounded by the length of the longest shared key prefix
    among any group of more than `48` elements, and each level takes about 2 KiB
    of stack.

    Parameters:
        T: The element type. Only `Movable` is required: elements are swapped,
           never copied, so a type that cannot be copied at all sorts fine.
        origin: The origin of the span.
        byte_of: Returns one byte of an element's key, or -1 past its end.
        less: Orders two elements known to share `depth` key bytes, for
           ranges below the comparison cutoff.

    Args:
        span: The elements to sort, in place.
    """
    if len(span) <= 1:
        return
    _byte_radix_sort[byte_of, less](span, 0)
