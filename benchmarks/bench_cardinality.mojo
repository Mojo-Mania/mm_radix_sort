"""How each sort responds to input with few distinct values.

This is radix sort's home turf -- a histogram does not care how many times a
value repeats -- so it deserves an honest measurement. The benchmark it
replaces was not one: the low-cardinality suite in the implementation this
package was ported from passed its `delta` argument to the generator for the
stdlib sort and omitted it for all three radix variants, so at delta 0 the
stdlib sorted a constant array while radix sorted uniformly random data, and
at delta 100 the stdlib sorted 100 distinct values while radix sorted 256.
Every row of it compared two different inputs, in both directions.

Here `distinct` is passed to one generator and every contender sorts the same
buffer. Times are nanoseconds per element, refill included.
"""

from benchmarks.format import fixed, ljust, rjust
from benchmarks.harness import measure, random_buffers
from mm_radix_sort import american_flag_sort, lsb_radix_sort, msb_radix_sort
from std.benchmark import keep
from std.random import seed

comptime _COUNT = 1 << 20
comptime _CARDINALITIES = [1, 4, 32, 256, 4096, 65536, 0]
comptime _KEY_WIDTHS = [8, 16, 24, 32]


def bench_case[D: DType](label: String, distinct: Int, key_bits: Int) raises:
    seed(1)
    var buffers = random_buffers[D](
        _COUNT, distinct=distinct, key_bits=key_bits
    )

    def stdlib() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        sort(span)
        keep(buffers.work)

    def lsb() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        lsb_radix_sort[BITS=11](span)
        keep(buffers.work)

    def msb() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        msb_radix_sort(span)
        keep(buffers.work)

    def aflag() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        american_flag_sort(span)
        keep(buffers.work)

    var count = Float64(_COUNT)
    var line = rjust(label, 10)
    line += rjust(fixed(measure(stdlib) / count), 12)
    if not buffers.is_sorted():
        raise Error("stdlib sort did not sort")
    line += rjust(fixed(measure(lsb) / count), 12)
    if not buffers.is_sorted():
        raise Error("lsb_radix_sort did not sort")
    line += rjust(fixed(measure(msb) / count), 12)
    if not buffers.is_sorted():
        raise Error("msb_radix_sort did not sort")
    line += rjust(fixed(measure(aflag) / count), 12)
    if not buffers.is_sorted():
        raise Error("american_flag_sort did not sort")
    print(line)


def _header(first: String):
    print()
    print(
        rjust(first, 10),
        rjust("sort", 11),
        rjust("lsb[11]", 11),
        rjust("msb", 11),
        rjust("aflag", 11),
    )


def main() raises:
    print(
        "uint32, nanoseconds per element over",
        _COUNT,
        "elements. Lower is better.",
    )

    print()
    print("How many distinct values appear, drawn from the full 32-bit range:")
    _header("distinct")
    comptime for i in range(len(_CARDINALITIES)):
        comptime distinct = _CARDINALITIES[i]
        var label = String(distinct) if distinct > 0 else String("all")
        bench_case[DType.uint32](label, distinct, 0)

    print()
    print("How wide the values are, with no repetition imposed. The LSD sort")
    print("skips a pass whose digit never varies, so narrow data costs less:")
    _header("key bits")
    comptime for i in range(len(_KEY_WIDTHS)):
        comptime bits = _KEY_WIDTHS[i]
        bench_case[DType.uint32](String(bits), 0, bits)
