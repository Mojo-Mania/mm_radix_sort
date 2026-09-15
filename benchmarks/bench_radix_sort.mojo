"""Compares every sort in the package against the stdlib's, across widths.

Each measurement refills the working buffer from a pristine copy and then
sorts it, both inside the timed region. The refill is a `memcpy` and is
reported as a floor so it can be read off rather than subtracted out.

Times are nanoseconds per element, so they are comparable down a column as
well as across one. The speedup is against `sort` on the same input.
"""

from benchmarks.format import fixed, ljust, rjust
from benchmarks.harness import measure, random_buffers
from mm_radix_sort import american_flag_sort, lsb_radix_sort, msb_radix_sort
from std.benchmark import keep
from std.memory import unsafe_memcpy
from std.random import seed
from std.sys.info import bit_width_of

comptime _SIZES = [1 << 12, 1 << 16, 1 << 20]
"""4 Ki, 64 Ki and 1 Mi elements: comfortably in L1, around L2, and past it."""


def _row(label: String, nanos: Float64, count: Int, baseline: Float64):
    var per_element = nanos / Float64(count)
    var line = String("  ", ljust(label, 22), rjust(fixed(per_element, 3), 9))
    if baseline > 0.0:
        line += rjust(String(fixed(baseline / nanos), "x"), 10)
    print(line)


def bench_dtype[D: DType](count: Int) raises:
    seed(1)
    var buffers = random_buffers[D](count)
    print(
        ljust(String(D, ", n = ", count), 24),
        rjust("ns/elem", 9),
        rjust("vs sort", 9),
    )

    def floor() raises {imm buffers}:
        buffers.refill()
        keep(buffers.work)

    def stdlib() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        sort(span)
        keep(buffers.work)

    def lsb8() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        lsb_radix_sort[BITS=8](span)
        keep(buffers.work)

    def lsb11() raises {imm buffers}:
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

    _row("memcpy floor", measure(floor), count, 0.0)
    var baseline = measure(stdlib)
    if not buffers.is_sorted():
        raise Error("stdlib sort did not sort")
    _row("sort (stdlib)", baseline, count, baseline)

    _row("lsb_radix_sort[8]", measure(lsb8), count, baseline)
    if not buffers.is_sorted():
        raise Error("lsb_radix_sort[8] did not sort")

    comptime if bit_width_of[D]() > 8:
        _row("lsb_radix_sort[11]", measure(lsb11), count, baseline)
        if not buffers.is_sorted():
            raise Error("lsb_radix_sort[11] did not sort")

    _row("msb_radix_sort", measure(msb), count, baseline)
    if not buffers.is_sorted():
        raise Error("msb_radix_sort did not sort")

    _row("american_flag_sort", measure(aflag), count, baseline)
    if not buffers.is_sorted():
        raise Error("american_flag_sort did not sort")
    print()


def main() raises:
    print("Nanoseconds per element, refill included. Lower is better.\n")
    comptime dtypes = [
        DType.uint8,
        DType.int16,
        DType.uint32,
        DType.int32,
        DType.float32,
        DType.uint64,
        DType.float64,
    ]
    comptime for i in range(len(dtypes)):
        comptime dtype = dtypes[i]
        comptime for j in range(len(_SIZES)):
            comptime size = _SIZES[j]
            bench_dtype[dtype](size)
