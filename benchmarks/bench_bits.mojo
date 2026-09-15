"""Sweeps the LSD digit width, which is the whole point of parameterising it.

The implementation this package was ported from shipped four separate
hand-written LSD sorts whose only real difference was the digit width: 8 bits
for everything, 11 for 32-bit values, and 13 and 16 for 64-bit ones. Here that
is one number, so it can be measured instead of chosen.

Wider digits mean fewer passes over the data but a larger histogram, and the
histogram is written twice -- once to zero it, once to prefix-sum it -- whether
or not there is enough data to fill it. Below, the cost of that fixed overhead
is visible as the small-n columns getting worse as `BITS` grows while the
large-n columns get better.

The 16-bit types are the one place a 16-bit digit is not obviously absurd:
it sorts them in a single pass. Whether one pass over a 256 KiB histogram
beats two over a 1 KiB one is the question the `float16` and `bfloat16` rows
answer.

Times are nanoseconds per element, refill included. Lower is better.
"""

from benchmarks.format import fixed, ljust, rjust
from benchmarks.harness import measure, random_buffers
from mm_radix_sort import lsb_radix_sort
from std.benchmark import keep
from std.random import seed
from std.sys.info import bit_width_of

comptime _SIZES = [1 << 12, 1 << 16, 1 << 18, 1 << 19, 1 << 20]
"""4 Ki to 1 Mi. 256 Ki and 512 Ki are there to find where a 64-bit type stops
preferring `BITS=11` and starts preferring `BITS=10`."""
comptime _WIDTHS = [4, 6, 8, 10, 11, 12, 13, 16]


def _measure_one[D: DType, BITS: Int](count: Int) raises -> Float64:
    seed(1)
    var buffers = random_buffers[D](count)

    def run_sort() raises {imm buffers}:
        buffers.refill()
        var span = buffers.span()
        lsb_radix_sort[BITS=BITS](span)
        keep(buffers.work)

    var nanos = measure(run_sort)
    if not buffers.is_sorted():
        raise Error("lsb_radix_sort did not sort")
    return nanos / Float64(count)


def bench_dtype[D: DType]() raises:
    var header = ljust(String(D), 10)
    comptime for j in range(len(_SIZES)):
        comptime size = _SIZES[j]
        header += rjust(String("n=", size), 12)
    print(header)

    comptime for w in range(len(_WIDTHS)):
        comptime BITS = _WIDTHS[w]
        comptime PASSES = (bit_width_of[D]() + BITS - 1) // BITS
        var line = ljust(String("  BITS=", BITS, " (", PASSES, "p)"), 10)
        comptime for j in range(len(_SIZES)):
            comptime size = _SIZES[j]
            line += rjust(fixed(_measure_one[D, BITS](size), 3), 12)
        print(line)
    print()


def main() raises:
    print("Nanoseconds per element, refill included. Lower is better.")
    print("(Np) is how many passes that digit width needs for the type.\n")
    bench_dtype[DType.float16]()
    bench_dtype[DType.bfloat16]()
    bench_dtype[DType.uint32]()
    bench_dtype[DType.float32]()
    bench_dtype[DType.uint64]()
    bench_dtype[DType.float64]()
