"""Tests for every sort in the package.

The oracle throughout is the stdlib's `sort`: a radix sort is correct exactly
when it produces the same sequence a comparison sort does, so every check here
is a comparison against that.
"""

from corpora import load, names
from mm_radix_sort import (
    american_flag_sort,
    byte_radix_sort,
    lsb_radix_sort,
    msb_radix_sort,
    radix_sort,
)
from std.random import random_float64, random_ui64, seed
from std.testing import TestSuite, assert_equal, assert_true

# ===-----------------------------------------------------------------------===#
# Helpers
# ===-----------------------------------------------------------------------===#


def _assert_matches_sort[
    D: DType, //
](var values: List[Scalar[D]], context: String) raises:
    """Runs every scalar sort over `values` and compares each to `sort`."""
    var expected = values.copy()
    sort(expected)

    var variants = [
        String("radix_sort"),
        "lsb_radix_sort[8]",
        "lsb_radix_sort[11]",
        "lsb_radix_sort[16]",
        "msb_radix_sort",
        "american_flag_sort",
    ]
    for which in range(len(variants)):
        var work = values.copy()
        var span = Span(work)
        if which == 0:
            radix_sort(span)
        elif which == 1:
            lsb_radix_sort[BITS=8](span)
        elif which == 2:
            lsb_radix_sort[BITS=11](span)
        elif which == 3:
            lsb_radix_sort[BITS=16](span)
        elif which == 4:
            msb_radix_sort(span)
        else:
            american_flag_sort(span)

        assert_equal(
            len(work),
            len(expected),
            String(context, " / ", variants[which], ": length changed"),
        )
        # Written out rather than handed to `assert_equal` per element: the
        # message argument is built eagerly, so every passing element cost a
        # `String` construction, which dominated the suite's runtime.
        for i in range(len(work)):
            if work[i] != expected[i]:
                assert_equal(
                    work[i],
                    expected[i],
                    String(
                        context,
                        " / ",
                        variants[which],
                        ": element ",
                        i,
                        " of ",
                        len(work),
                    ),
                )


def _assert_strings_match_sort(var words: List[String], context: String) raises:
    var expected = words.copy()
    sort(expected)
    var span = Span(words)
    radix_sort(span)
    assert_equal(len(words), len(expected), String(context, ": length changed"))
    for i in range(len(words)):
        if words[i] != expected[i]:
            assert_equal(
                words[i],
                expected[i],
                String(context, ": element ", i, " of ", len(words)),
            )


# ===-----------------------------------------------------------------------===#
# Shapes that break a sort
# ===-----------------------------------------------------------------------===#


def test_degenerate_lengths() raises:
    _assert_matches_sort(List[UInt32](), "empty")
    _assert_matches_sort([UInt32(42)], "one element")
    _assert_matches_sort([UInt32(2), 1], "two elements, reversed")
    _assert_matches_sort([UInt32(1), 2], "two elements, ordered")


def test_all_equal() raises:
    var values = List[UInt32](unsafe_uninit_length=5000)
    for i in range(5000):
        values[i] = 7
    _assert_matches_sort(values^, "five thousand equal values")


def test_already_sorted_and_reversed() raises:
    var ascending = List[Int32](unsafe_uninit_length=5000)
    var descending = List[Int32](unsafe_uninit_length=5000)
    for i in range(5000):
        ascending[i] = Int32(i - 2500)
        descending[i] = Int32(2500 - i)
    _assert_matches_sort(ascending^, "already ascending")
    _assert_matches_sort(descending^, "descending")


def test_extremes() raises:
    _assert_matches_sort(
        [Int8.MIN, Int8.MAX, 0, -1, 1, Int8.MIN, Int8.MAX], "int8 extremes"
    )
    _assert_matches_sort(
        [UInt64.MIN, UInt64.MAX, 1, UInt64.MAX - 1], "uint64 extremes"
    )


def test_signed_crosses_zero() raises:
    """The sign flip in the ordered mapping is what this exercises."""
    var values = List[Int32](unsafe_uninit_length=4000)
    seed(3)
    for i in range(4000):
        values[i] = Int32(Int(random_ui64(0, 2000)) - 1000)
    _assert_matches_sort(values^, "signed spanning zero")


def test_floats_span_zero() raises:
    var values = List[Float32](unsafe_uninit_length=4000)
    seed(4)
    for i in range(4000):
        values[i] = Float32(random_float64() * 2000.0 - 1000.0)
    _assert_matches_sort(values^, "float32 spanning zero")


def test_float_special_values() raises:
    """Zeroes, denormals and infinities, but never NaN -- it has no order."""
    var values = [
        Float64(0.0),
        -0.0,
        1.0,
        -1.0,
        Float64.MAX,
        Float64.MIN,
        5e-324,
        -5e-324,
        1e308,
        -1e308,
    ]
    # -0.0 and 0.0 compare equal, so their relative order is not observable;
    # every other pair is.
    var work = values.copy()
    var span = Span(work)
    radix_sort(span)
    for i in range(1, len(work)):
        assert_true(
            work[i - 1] <= work[i],
            String("float specials out of order at ", i),
        )


def test_every_width_and_sign() raises:
    seed(5)

    comptime dtypes = [
        DType.uint8,
        DType.int8,
        DType.uint16,
        DType.int16,
        DType.uint32,
        DType.int32,
        DType.uint64,
        DType.int64,
    ]
    comptime for d in range(len(dtypes)):
        comptime dtype = dtypes[d]
        for count in [1, 2, 63, 64, 65, 1000, 3000]:
            var values = List[Scalar[dtype]](unsafe_uninit_length=count)
            for i in range(count):
                values[i] = Scalar[dtype](
                    Int(random_ui64(0, 255)) - (128 if dtype.is_signed() else 0)
                )
            _assert_matches_sort(
                values^, String(dtype, " with ", count, " elements")
            )


def test_float_widths() raises:
    seed(6)
    comptime dtypes = [DType.float32, DType.float64]
    comptime for d in range(len(dtypes)):
        comptime dtype = dtypes[d]
        for count in [1, 2, 65, 1000, 3000]:
            var values = List[Scalar[dtype]](unsafe_uninit_length=count)
            for i in range(count):
                values[i] = Scalar[dtype](random_float64() * 200.0 - 100.0)
            _assert_matches_sort(
                values^, String(dtype, " with ", count, " elements")
            )


def test_crosses_the_dispatch_threshold() raises:
    """Sizes either side of every fallback boundary the dispatcher uses."""
    seed(7)
    for count in [31, 32, 33, 63, 64, 65, 767, 768, 769, 1535, 1536, 1537]:
        var narrow = List[UInt8](unsafe_uninit_length=count)
        var wide = List[UInt64](unsafe_uninit_length=count)
        for i in range(count):
            narrow[i] = UInt8(Int(random_ui64(0, 255)))
            wide[i] = random_ui64(0, UInt64.MAX)
        _assert_matches_sort(narrow^, String("uint8 n=", count))
        _assert_matches_sort(wide^, String("uint64 n=", count))


# ===-----------------------------------------------------------------------===#
# Strings
# ===-----------------------------------------------------------------------===#


def test_strings_basic() raises:
    _assert_strings_match_sort(List[String](), "no strings")
    _assert_strings_match_sort([String("only")], "one string")
    _assert_strings_match_sort([String("pear"), "apple", "apricot"], "three")


def test_strings_prefixes_and_empties() raises:
    """A key that is a prefix of another must sort first, and never over-read.
    """
    _assert_strings_match_sort(
        [String(""), "a", "ab", "abc", "ab", "", "b", "ba"],
        "prefixes and empties",
    )


def test_strings_duplicates_recurse_past_their_length() raises:
    """Duplicates are what drive the recursion past a key's own length.

    The implementation this was ported from read `ptr[depth]` before checking
    whether the string had a byte there, so a bucket of duplicates recursing
    below their own length read out of bounds. Bucket 0 answers that here.
    """
    var words = List[String]()
    for _ in range(200):
        words.append(String("ab"))
    for _ in range(200):
        words.append(String("abc"))
    for _ in range(200):
        words.append(String(""))
    _assert_strings_match_sort(words^, "many duplicates")


def test_strings_long_shared_prefix() raises:
    var prefix = String("")
    for _ in range(300):
        prefix += "x"
    var words = List[String]()
    for i in range(500):
        words.append(String(prefix, i))
    _assert_strings_match_sort(words^, "300-byte shared prefix")


def test_strings_single_multi_element_bucket() raises:
    """Regression test for the partition guard in the ported implementation.

    That guard read `partitions[0] == end - start`, comparing a *byte value*
    to an *element count*. When they coincided it skipped the permutation for
    the whole range and recursed a byte deeper, leaving every singleton where
    it lay.

    Three things have to hold for this to catch that, and two earlier versions
    of this test got them wrong:

    - The range must be comfortably larger than `_COMPARISON_CUTOFF`, or
      insertion sort repairs the damage and the test proves nothing.
    - The leading bytes must be ASCII. `chr(200)` is two UTF-8 bytes, so a
      range of "singletons" above 127 all share a leading 0xC2 or 0xC3 and the
      shape is destroyed.
    - Every byte after the first must be identical across the whole range, so
      that a sort which skips byte 0 has nothing left to reconstruct the order
      from.
    """
    var shape = String("zzzz")
    var words = List[String]()
    # One bucket of a hundred identical keys, and one singleton per remaining
    # ASCII leading byte. Interleaved, so the input is not already sorted.
    for b in range(34, 128):
        words.append(String(chr(b), shape))
        words.append(String(chr(33), shape))
    for _ in range(100 - 94):
        words.append(String(chr(33), shape))
    assert_equal(len(words), 194, "the shape this test needs")
    _assert_strings_match_sort(words^, "one multi-element bucket")


def test_strings_utf8_corpora() raises:
    """Byte order over UTF-8 is codepoint order, across twelve scripts."""
    for name in names():
        _assert_strings_match_sort(load(name), name)


# ===-----------------------------------------------------------------------===#
# The generic byte-key entry point
# ===-----------------------------------------------------------------------===#


def test_byte_radix_sort_with_a_custom_key() raises:
    """Sorts on a two-byte big-endian key carried in a struct's first field."""
    seed(8)
    var rows = List[Tuple[Int, Int]]()
    for i in range(2000):
        rows.append((Int(random_ui64(0, 65535)), i))

    def key_byte(imm row: Tuple[Int, Int], depth: Int) capturing -> Int:
        if depth >= 2:
            return -1
        return (row[0] >> ((1 - depth) * 8)) & 255

    def row_less(
        imm a: Tuple[Int, Int], imm b: Tuple[Int, Int], depth: Int
    ) capturing -> Bool:
        return a[0] < b[0]

    var span = Span(rows)
    byte_radix_sort[key_byte, row_less](span)
    for i in range(1, len(rows)):
        assert_true(
            rows[i - 1][0] <= rows[i][0],
            String("custom key out of order at ", i),
        )


struct MoveOnly(Movable):
    """A payload that cannot be copied, only moved.

    The point of it is the absence of `Copyable`: if `byte_radix_sort` ever
    copies an element instead of swapping it, this type stops compiling.
    """

    var key: Int
    var payload: List[Int]

    def __init__(out self, key: Int):
        self.key = key
        self.payload = [key, key * 2]


def test_byte_radix_sort_moves_without_copying() raises:
    """A move-only element type, sorted by a field of it."""
    seed(9)
    var items = List[MoveOnly]()
    for _ in range(500):
        items.append(MoveOnly(Int(random_ui64(0, 65535))))

    def key_byte(imm item: MoveOnly, depth: Int) capturing -> Int:
        if depth >= 2:
            return -1
        return (item.key >> ((1 - depth) * 8)) & 255

    def item_less(
        imm a: MoveOnly, imm b: MoveOnly, depth: Int
    ) capturing -> Bool:
        return a.key < b.key

    var span = Span(items)
    byte_radix_sort[key_byte, item_less](span)
    for i in range(len(items)):
        assert_true(
            i == 0 or items[i - 1].key <= items[i].key,
            String("move-only elements out of order at ", i),
        )
        # The payload must have travelled with its key, not been reconstructed.
        assert_equal(
            items[i].payload[1],
            items[i].key * 2,
            String("payload parted company with its key at ", i),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
