"""A tour of every entry point in the package."""

from mm_radix_sort import (
    american_flag_sort,
    byte_radix_sort,
    lsb_radix_sort,
    msb_radix_sort,
    radix_sort,
)
from std.random import random_ui64, seed


def scalars() raises:
    print("--- radix_sort on scalars ---")

    var integers = [Int32(5), -3, 9, -1, 0]
    var integer_span = Span(integers)
    radix_sort(integer_span)
    print("signed integers:", integers)

    # Floats sort correctly across zero: the order-preserving mapping flips
    # every bit of a negative and only the sign bit of a positive, which puts
    # the negatives below the positives and un-reverses them.
    var floats = [Float64(2.5), -1.0, 0.0, -7.25, 1e300, -1e300]
    var float_span = Span(floats)
    radix_sort(float_span)
    print("floats:", floats)


def strings() raises:
    print("\n--- radix_sort on strings ---")
    var words = [
        String("pear"),
        "apple",
        "apricot",
        "ap",
        "",
        "Ápple",
        "apple",
    ]
    var span = Span(words)
    radix_sort(span)
    # Byte order over UTF-8 is codepoint order, and a key that is a prefix of
    # another sorts first.
    print(words)


def picking_a_strategy() raises:
    print("\n--- choosing a strategy directly ---")
    seed(1)
    var count = 200_000
    var values = List[UInt32](unsafe_uninit_length=count)
    for i in range(count):
        values[i] = UInt32(Int(random_ui64(0, 4_000_000_000)))

    var a = values.copy()
    var b = values.copy()
    var c = values.copy()
    var d = values.copy()

    var a_span = Span(a)
    lsb_radix_sort[BITS=11](a_span)

    var b_span = Span(b)
    msb_radix_sort(b_span)

    # The one that touches no heap memory at all -- and the slowest.
    var c_span = Span(c)
    american_flag_sort(c_span)

    var d_span = Span(d)
    sort(d_span)

    for i in range(count):
        if a[i] != d[i] or b[i] != d[i] or c[i] != d[i]:
            raise Error("a strategy disagreed with the comparison sort")
    print("all four strategies agree on", count, "values")


def custom_keys() raises:
    print("\n--- byte_radix_sort on a key you define ---")

    # Sort records by a numeric field, by handing the sort that field's bytes
    # most significant first. Both callbacks must be declared `capturing`.
    var records = [
        (2024_03_15, String("march")),
        (2023_11_02, String("november")),
        (2024_01_20, String("january")),
    ]

    def key_byte(imm row: Tuple[Int, String], depth: Int) capturing -> Int:
        if depth >= 4:
            return -1
        return (row[0] >> ((3 - depth) * 8)) & 255

    def row_less(
        imm a: Tuple[Int, String], imm b: Tuple[Int, String], depth: Int
    ) capturing -> Bool:
        return a[0] < b[0]

    var span = Span(records)
    byte_radix_sort[key_byte, row_less](span)
    for i in range(len(records)):
        print(" ", records[i][0], records[i][1])


def main() raises:
    scalars()
    strings()
    picking_a_strategy()
    custom_keys()
