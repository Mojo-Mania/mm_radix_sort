"""Where `radix_sort` hands over to the comparison sort, and whether it should.

A radix pass writes its whole histogram twice -- once to zero it, once to
prefix-sum it -- however few elements it is given, so on small inputs that
fixed cost is the entire runtime. `radix_sort` therefore falls back to `sort`
below a threshold derived from the histogram size.

This table is what that threshold was set from, and what would catch it
drifting: `lsb` is the radix kernel called directly, so the column shows the
cost the fallback avoids. `radix_sort` should track whichever of the other two
columns is faster.

Times are nanoseconds per element, refill included. Lower is better.
"""

from benchmarks.format import fixed, ljust, rjust
from benchmarks.harness import measure, random_buffers
from mm_radix_sort import lsb_radix_sort, radix_sort
from std.benchmark import keep
from std.random import seed
from std.sys.info import bit_width_of

comptime _SIZES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096]


def bench_size[D: DType, BITS: Int](count: Int) raises:
    seed(1)
    var buffers = random_buffers[D](count)

    def stdlib() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        sort(span)
        keep(buffers.work)

    def kernel() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        lsb_radix_sort[BITS=BITS](span)
        keep(buffers.work)

    def dispatched() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        radix_sort(span)
        keep(buffers.work)

    var n = Float64(count)
    var line = rjust(String(count), 10)
    line += rjust(fixed(measure(stdlib) / n), 12)
    if not buffers.is_sorted():
        raise Error("stdlib sort did not sort")
    line += rjust(fixed(measure(kernel) / n), 12)
    if not buffers.is_sorted():
        raise Error("lsb_radix_sort did not sort")
    line += rjust(fixed(measure(dispatched) / n), 12)
    if not buffers.is_sorted():
        raise Error("radix_sort did not sort")
    print(line)


def bench_dtype[D: DType, BITS: Int]() raises:
    comptime PASSES = (bit_width_of[D]() + BITS - 1) // BITS
    print()
    print(
        String(D),
        " -- the dispatcher uses BITS=",
        BITS,
        " (",
        PASSES,
        " passes), and falls back below n=",
        PASSES * (64 if (1 << BITS) < 512 else (1 << BITS) // 8),
        sep="",
    )
    print(
        rjust("n", 10),
        rjust("sort", 11),
        rjust("lsb", 11),
        rjust("radix_sort", 11),
    )
    comptime for i in range(len(_SIZES)):
        comptime size = _SIZES[i]
        bench_size[D, BITS](size)


def main() raises:
    print("Nanoseconds per element, refill included. Lower is better.")
    bench_dtype[DType.uint8, 8]()
    bench_dtype[DType.uint16, 8]()
    bench_dtype[DType.uint32, 11]()
    bench_dtype[DType.uint64, 11]()
