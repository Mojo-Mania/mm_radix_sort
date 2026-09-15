"""`radix_sort` -- the entry point that picks a strategy for you.

The measurements this package ships do not have a single winner. The digit
width that is fastest for a `UInt64` is not the one that is fastest for a
`UInt16`, and below a few hundred elements no radix sort beats the comparison
sort at all, because a radix pass pays for its whole histogram however little
data it is given. So `radix_sort` is a dispatcher, and the numbers it
dispatches on came out of `benchmarks/`.

Reach past it -- for `lsb_radix_sort`, `msb_radix_sort` or
`american_flag_sort` -- when you know something it does not: that the sort
must not allocate, or that your data is nothing like the uniformly random
input the thresholds were measured on.
"""

from std.sys.info import bit_width_of

from ._bits import pass_count
from .bytes import byte_radix_sort
from .lsb import lsb_radix_sort


def radix_sort[D: DType, origin: MutOrigin, //](span: Span[Scalar[D], origin]):
    """Sorts `span` of scalars in ascending order, in place.

    Signed integers and floating-point values sort correctly, negatives
    included; see `_bits` for the order-preserving mapping that makes that
    work. NaN has no place in a total order and is not handled.

    ```mojo
    from mm_radix_sort import radix_sort

    var values = [Float32(2.5), -1.0, 0.0, -7.25]
    var span = Span(values)
    radix_sort(span)
    print(values)  # [-7.25, -1.0, 0.0, 2.5]
    ```

    Parameters:
        D: The element type.
        origin: The origin of the span.

    Args:
        span: The elements to sort, in place.
    """
    comptime WIDTH = bit_width_of[D]()

    # Measured on uniformly random input: an 8-bit digit wins for 8- and
    # 16-bit values, where a wider digit would buy no fewer passes; an 11-bit
    # digit wins for 32- and 64-bit ones, at every size measured. See
    # `benchmarks/bench_bits.mojo`, which sweeps this.
    comptime BITS = 8 if WIDTH <= 16 else 11
    comptime PASSES = pass_count[D, BITS]()

    # A radix pass writes its whole histogram twice -- once to zero it, once
    # to prefix-sum it -- whether it is given ten elements or ten million, so
    # below some size that fixed cost is the entire runtime and the comparison
    # sort wins. The measured crossovers are n = 64 for `uint8`, ~100 for
    # `uint16`, ~700 for `uint32` and ~1100 for `uint64`; see
    # `benchmarks/bench_dispatch.mojo`, which is the table they came from.
    #
    # Read as: each pass costs at least about 64 elements' worth of work, and
    # more than that once its histogram is large enough to matter.
    comptime BUCKETS = 1 << BITS
    comptime PER_PASS = 64 if BUCKETS < 512 else BUCKETS // 8
    comptime FALLBACK_BELOW = PASSES * PER_PASS

    if len(span) < FALLBACK_BELOW:
        sort(span)
        return
    lsb_radix_sort[BITS=BITS](span)


def radix_sort[origin: MutOrigin, //](span: Span[String, origin]):
    """Sorts `span` of strings into ascending byte order, in place.

    Byte order over UTF-8 is codepoint order, so this agrees with `String`'s
    own `<`. Strings are swapped, never copied, and no heap memory is
    allocated. Equal strings may be reordered, which nothing can observe.

    ```mojo
    from mm_radix_sort import radix_sort

    var words = [String("pear"), "apple", "apricot"]
    var span = Span(words)
    radix_sort(span)
    print(words)  # ['apple', 'apricot', 'pear']
    ```

    Parameters:
        origin: The origin of the span.

    Args:
        span: The strings to sort, in place.
    """

    def string_byte(imm value: String, depth: Int) capturing -> Int:
        if depth >= value.byte_length():
            return -1
        return Int(value.unsafe_ptr()[unsafe_offset=depth])

    def string_less(imm a: String, imm b: String, depth: Int) capturing -> Bool:
        var a_length = a.byte_length()
        var b_length = b.byte_length()
        var limit = min(a_length, b_length)
        var a_bytes = a.unsafe_ptr()
        var b_bytes = b.unsafe_ptr()
        for i in range(depth, limit):
            var left = a_bytes[unsafe_offset=i]
            var right = b_bytes[unsafe_offset=i]
            if left != right:
                return left < right
        return a_length < b_length

    byte_radix_sort[string_byte, string_less](span)
