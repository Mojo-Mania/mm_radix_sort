"""Input generation and timing shared by the benchmark files.

Sorting is destructive, so a benchmark that sorts the same buffer twice
measures the second sort on already-sorted input. Every measurement here
therefore refills the working buffer from a pristine copy before each sort,
and the refill is inside the timed region.

That refill is a `memcpy`, it is identical for every contender, and its cost
is reported alongside the results as a floor rather than subtracted out --
subtracting a separately-measured baseline turned out to add more noise than
it removed.
"""

from std.benchmark import Unit, keep, run
from std.memory import unsafe_memcpy
from std.memory.alloc import Allocation, alloc, dealloc
from std.sys.info import bit_width_of
from std.random import random_float64, random_ui64, seed


struct Buffers[D: DType](Movable):
    """A pristine input and a working buffer of the same length.

    Parameters:
        D: The element type.
    """

    var pristine: Pointer[Scalar[Self.D], MutUntrackedOrigin]
    var work: Pointer[Scalar[Self.D], MutUntrackedOrigin]
    var count: Int

    def __init__(out self, count: Int):
        """Allocates both buffers.

        Args:
            count: How many elements each buffer holds.
        """
        self.count = count
        self.pristine = alloc[Scalar[Self.D]]({count = count}).unsafe_leak()
        self.work = alloc[Scalar[Self.D]]({count = count}).unsafe_leak()

    def __deinit__(deinit self):
        """Frees both buffers."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.pristine, layout={count = self.count}
            )
        )
        dealloc(
            Allocation(unsafe_owned_ptr=self.work, layout={count = self.count})
        )

    @always_inline
    def refill(self):
        """Restores the working buffer from the pristine one."""
        unsafe_memcpy(dest=self.work, src=self.pristine, count=self.count)

    def span(
        self,
    ) -> Span[Scalar[Self.D], MutUntrackedOrigin]:
        """Returns a mutable span over the working buffer.

        Returns:
            A span of `count` elements.
        """
        return Span[Scalar[Self.D], MutUntrackedOrigin](
            unsafe_ptr=self.work, length=self.count
        )

    def at(self, index: Int) -> Scalar[Self.D]:
        """Returns the working buffer's element at `index`, by value.

        Reach for this rather than indexing `work` directly. `work` carries an
        untracked origin, so a bare `buffers.work[unsafe_offset=i]` is not a
        use of `buffers` as far as the compiler is concerned -- it will happily
        destroy the buffers first and hand you freed memory.

        Args:
            index: Which element to read.

        Returns:
            A copy of that element.
        """
        return self.work[unsafe_offset=index]

    def is_sorted(self) -> Bool:
        """Returns whether the working buffer is in ascending order.

        Returns:
            True if every element is at least its predecessor.
        """
        for i in range(1, self.count):
            if self.work[unsafe_offset=i] < self.work[unsafe_offset=i - 1]:
                return False
        return True


def random_buffers[
    D: DType
](count: Int, distinct: Int = 0, key_bits: Int = 0) -> Buffers[D]:
    """Builds buffers of `count` random values of type `D`.

    The two optional axes are deliberately independent, because conflating
    them is how a low-cardinality benchmark ends up measuring something else.
    `distinct` controls how many *different* values appear; `key_bits`
    controls how *wide* those values are. Drawing 32 distinct values from the
    full range exercises repetition. Drawing full-cardinality data from 8 bits
    exercises the pass-skipping in the LSD sort. Varying one knob and calling
    it the other measures neither.

    Parameters:
        D: The element type.

    Args:
        count: How many elements to generate.
        distinct: If positive, draw every element from a palette of this many
            randomly chosen values instead of drawing independently.
        key_bits: If positive, restrict values to `[0, 2 ** key_bits)`.

    Returns:
        Freshly filled buffers.
    """
    var palette = List[Scalar[D]]()
    var palette_size = distinct if distinct > 0 else 0
    for _ in range(palette_size):
        palette.append(_random_value[D](key_bits))

    var buffers = Buffers[D](count)
    for i in range(count):
        if palette_size > 0:
            buffers.pristine[unsafe_offset=i] = palette[
                Int(random_ui64(0, UInt64(palette_size - 1)))
            ]
        else:
            buffers.pristine[unsafe_offset=i] = _random_value[D](key_bits)
    buffers.refill()
    return buffers^


def _random_value[D: DType](key_bits: Int) -> Scalar[D]:
    """Draws one random value of type `D`, optionally narrowed to `key_bits`."""
    comptime WIDTH = bit_width_of[D]()
    comptime if D.is_floating_point():
        if key_bits > 0:
            # A narrow float key means a small non-negative integer stored as
            # a float, which is the shape real data takes when it is narrow.
            var span = UInt64(1) << UInt64(min(key_bits, 30))
            return Scalar[D](Float64(Int(random_ui64(0, span - 1))))
        # Uniform in [-1000, 1000). Never NaN: a NaN has no place in a total
        # order, so it would make both the radix sorts and the comparison sort
        # meaningless rather than measurable.
        return Scalar[D](random_float64() * 2000.0 - 1000.0)
    else:
        comptime VALUE_BITS = WIDTH - 1 if D.is_signed() else WIDTH
        var bits = VALUE_BITS if key_bits <= 0 else min(key_bits, VALUE_BITS)
        var span = UInt64.MAX if bits >= 64 else (UInt64(1) << UInt64(bits)) - 1
        var raw = Int(random_ui64(0, span))
        comptime if D.is_signed():
            # Centre on zero when the full range is in play, so the sign flip
            # in the ordered mapping is actually exercised.
            if key_bits <= 0:
                return Scalar[D](raw - (Int(span) // 2))
        return Scalar[D](raw)


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    """Times `f` and returns its mean duration in nanoseconds.

    Args:
        f: The closure to time.

    Returns:
        Mean nanoseconds per call.
    """
    return run(f, min_runtime_secs=0.05, max_runtime_secs=1.0).mean(Unit.ns)
