# mm_radix_sort

[![CI](https://github.com/Mojo-Mania/mm_radix_sort/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_radix_sort/actions/workflows/ci.yml)

Radix sorts for [Mojo](https://mojolang.org) — for scalars, for strings, and
for any key you can hand over one byte at a time.

A comparison sort asks "is this one smaller?" about `n log n` pairs. A radix
sort never asks: it reads the digits of a key and puts each element where its
digits say it belongs. The work is then proportional to the number of digits
rather than to `log n`, and on fixed-width numeric data that trade is very
one-sided — on an array of 64 Ki elements or more it is **7 to 28 times
faster than the stdlib's `sort`** on an Apple M4 and **7 to 30 times** on an
AMD Ryzen AI 9 HX 370, with the narrower types gaining the most.

```mojo
from mm_radix_sort import radix_sort

var values = [Int32(5), -3, 9, -1, 0]
var span = Span(values)
radix_sort(span)
print(values)                    # [-3, -1, 0, 5, 9]

var words = [String("pear"), "apple", "apricot"]
var word_span = Span(words)
radix_sort(word_span)
print(words)                     # ['apple', 'apricot', 'pear']
```

Signed integers and floats sort correctly, negatives included. `radix_sort`
picks a strategy from the element type and the input size using thresholds
measured by the suite in `benchmarks/`; the strategies it chooses between are
public too, for when you know something it does not.

## When to use it

**For numbers, above a few thousand of them, always.** The margin is large
enough that there is not much to weigh up, and it grows both with the size of
the array and as the type gets narrower — a narrow key has fewer digits to
walk. At 64 Ki elements a `uint8` sorts **28.3x** faster than `sort` and a
`uint64` **7.6x**; at 4 Ki the `uint8` becomes 8.3x and the `uint64` is not
worth quoting -- its baseline is the one cell that will not hold still. The Ryzen gives 29.9x
and 9.7x at 64 Ki but only 4.2x and 1.7x at 4 Ki, where a `float64` sorts
slower with every radix kernel than with `sort` (0.8x at best).

**Below the crossover, don't.** A radix pass writes its whole histogram twice —
once to zero it, once to prefix-sum it — whether you give it ten elements or
ten million, so on small inputs that fixed cost is the entire runtime.
`radix_sort` falls back to `sort` there and you can ignore this. If you call a
kernel directly, the crossovers are n = 64 for `uint8`, ~100 for `uint16`,
~700 for `uint32` and ~1100 for `uint64` on the M4. On the Ryzen they sit at
about 64, 128, 1000 and 4000, and the `uint64` fallback switches too early
there — see [The dispatch threshold](#the-dispatch-threshold).

**For strings, it depends on the shape of the keys.** Sorting half a million
words out of a book it wins by **1.7x**, and a shuffled vocabulary by
**1.9x** (2.4x and 1.9x on the Ryzen). But it advances one byte per recursion
level, so keys that are long or share a deep prefix — paths, ARNs, namespaced
identifiers — bring it back to parity or worse on the M4. On the Ryzen those
cases still win, by about 1.4x to 1.5x. See [Strings](#strings).

**It sorts by bytes, not by a comparator.** These sorts read a key's bytes, so
they cover scalars, strings, and anything you write a byte extractor for.
There is no comparator-driven entry point; that is what `sort` is for.

**NaN is not handled.** A NaN has no place in a total order.

## Install

```toml
[dependencies]
mm_radix_sort = { git = "https://github.com/Mojo-Mania/mm_radix_sort.git" }
```

Or vendor `mm_radix_sort/` and build with `-I .`.

## Usage

Everything takes a `Span`, so a `List` needs wrapping:

```mojo
from mm_radix_sort import radix_sort

var values = List[UInt32](unsafe_uninit_length=1_000_000)
# ... fill ...
var span = Span(values)
radix_sort(span)
```

### Choosing a strategy yourself

```mojo
from mm_radix_sort import lsb_radix_sort, msb_radix_sort, american_flag_sort

lsb_radix_sort[BITS=11](span)   # what radix_sort uses for 32- and 64-bit
lsb_radix_sort[BITS=8](span)    #   ... and for 8- and 16-bit
msb_radix_sort(span)            # top-down, one shared scratch buffer
american_flag_sort(span)        # in place, no heap allocation, slowest
```

### Sorting by a key you define

`byte_radix_sort` takes two callbacks: one yielding the `depth`-th byte of an
element's sort key — or `-1` once the key has run out — and one ordering two
elements already known to agree on their first `depth` key bytes. Both must be
declared `capturing`, whether or not they capture anything.

```mojo
from mm_radix_sort import byte_radix_sort

var records = [(2024_03_15, String("march")), (2023_11_02, String("november"))]

def key_byte(imm row: Tuple[Int, String], depth: Int) capturing -> Int:
    if depth >= 4:
        return -1
    return (row[0] >> ((3 - depth) * 8)) & 255      # 4 bytes, big-endian

def row_less(
    imm a: Tuple[Int, String], imm b: Tuple[Int, String], depth: Int
) capturing -> Bool:
    return a[0] < b[0]

var span = Span(records)
byte_radix_sort[key_byte, row_less](span)
```

Elements are only swapped, never copied, so `T` need only be `Movable` — a
type that cannot be copied at all sorts fine. Equal keys are **not** kept in
their original order, though, which matters once an element carries a payload
the key does not cover.

## API

Every entry point sorts ascending, in place, and returns nothing.

| | element | heap | stack | equal keys |
| --- | --- | --- | --- | --- |
| `radix_sort(span)` | `Scalar[D]` | one scratch + histogram † | — | kept in order |
| `radix_sort(span)` | `String` | none | ~2 KiB per level | may reorder |
| `lsb_radix_sort[BITS=8](span)` | `Scalar[D]` | one scratch + histogram | — | kept in order |
| `msb_radix_sort(span)` | `Scalar[D]` | one scratch + counters | — | kept in order |
| `american_flag_sort(span)` | `Scalar[D]` | none | 2 KiB per key byte | may reorder |
| `byte_radix_sort[byte_of, less](span)` | any `Movable` | none | ~2 KiB per level | may reorder |

† None below the fallback threshold, where it calls `sort`.

"Kept in order" is unobservable when the element *is* the key, which for the
scalar sorts it always is. It matters for `byte_radix_sort`, where an element
can carry a payload the key does not cover — and there the answer is that the
order is **not** kept, because the partition is a cyclic permutation.

`BITS` must be 1–16. `lsb_radix_sort` counts with `UInt32`, so the span must
hold fewer than 2^32 elements.

## How it works

### Every key becomes an unsigned integer first

A radix sort compares *digits of an unsigned integer*, so before it can touch
a value it needs an order-preserving bijection onto one: `a < b` must imply
`ordered(a) < ordered(b)` under unsigned comparison.

For unsigned integers that map is the identity. For two's-complement signed
integers it is a flip of the sign bit, which moves the negative half below the
positive half:

| `Int8` | raw | ordered |
| ---: | ---: | ---: |
| `-128` | `128` | `0` |
| `-1` | `255` | `127` |
| `0` | `0` | `128` |
| `127` | `127` | `255` |

Floats need more. IEEE 754 is *almost* ordered as an integer already —
positives ascend correctly — but negatives ascend in the wrong direction and
sit above every positive. Flipping the sign bit of a positive and **every** bit
of a negative fixes both at once:

| `Float32` | raw | ordered |
| ---: | ---: | ---: |
| `-inf` | `0xFF800000` | `0x007FFFFF` |
| `-2.0` | `0xC0000000` | `0x3FFFFFFF` |
| `-1.0` | `0xBF800000` | `0x407FFFFF` |
| `-0.0` | `0x80000000` | `0x7FFFFFFF` |
| `0.0` | `0x00000000` | `0x80000000` |
| `1.0` | `0x3F800000` | `0xBF800000` |
| `2.0` | `0x40000000` | `0xC0000000` |

The ordered column ascends; the raw one does not. Branchlessly, that is

```mojo
var mask = (0 - (raw >> (WIDTH - 1))) | SIGN_BIT
return raw ^ mask
```

— arithmetic-shifting the sign bit down to all-ones for a negative or
all-zeros for a positive, then forcing the sign bit on.

This lives in `_bits.mojo` and is defined once. The implementation this package
was ported from carried six copies of it across four files, two of them
byte-for-byte identical.

### Least significant digit first, or most

**LSD** (`lsb_radix_sort`) reads the array once to histogram *every* pass's
digits at the same time, turns each histogram into bucket offsets, then makes
one stable scatter per pass, least significant digit first. After the last
pass the array is sorted. It is the fastest thing here for almost everything,
because each pass is a linear read and a linear-ish write with no branching.

Two shortcuts matter. If the first read finds the array already ordered, it
stops. And a pass whose digit is the same for every element is skipped — its
scatter would be the identity — which is why 8-bit data in a `uint32` costs
one pass instead of three.

**MSD** (`msb_radix_sort`, `american_flag_sort`) partitions on the *top* digit
and recurses into each bucket. That stops early — once a bucket holds few
enough elements the remaining digits are never looked at — and each
sub-problem soon fits in cache. It wins on `uint64` at 4 Ki, where six full
LSD passes cost more than stopping early, and nowhere else measured bar an
edge of under 2% on `uint8` on the Ryzen.

The two MSD variants differ only in the partition step: `msb_radix_sort`
copies the range aside and scatters it back, `american_flag_sort` permutes in
place with cyclic swaps. Permuting in place costs between **1.8x and 7.3x**
across the measured grid on the M4 and 1.5x to 6.1x on the Ryzen — widest on
the narrow types — and buys you a sort that never touches the heap.

### Variable-length keys need a 257th bucket

`byte_radix_sort` uses **257 buckets, not 256**. Bucket 0 means *this key has
no byte at this depth*, and a real byte `b` lands in bucket `b + 1`.

That one extra bucket is what makes `"ab"` sort before `"abc"` with no length
comparison anywhere — the short key simply falls into bucket 0 and lands
first. It also removes a whole class of bug: a key that has run out is
answered by the extractor returning `-1`, not by loading a byte that is not
there. The ported implementation did load it, and read past the end of any
string whose duplicates drove the recursion below its own length.

## Performance

Two machines: an Apple M4, and an AMD Ryzen AI 9 HX 370 on Linux with the
process pinned to one of its four full-size Zen 5 cores (`taskset -c 2`). One
variant per process, `-D ASSERT=none`. Every timing refills the working buffer
from a pristine copy before sorting, both inside the timed region, because a
sort run twice on the same buffer measures the second run on already-sorted
input. That refill is a `memcpy` costing 0.01–0.10 ns/element on the M4 and
0.01–0.14 on the Ryzen; it is identical for every contender and is reported as
a floor rather than subtracted out.

The M4 scalar table below is the mean of two clean runs taken together, after
the private per-histogram change; a cell whose two runs differed by more than
20% is marked ‡. The other M4 tables, and all the Ryzen ones, predate that
change and are conservative for the `lsb` columns by up to 9% -- the counting
pass got faster, which those tables do not yet show.

The Ryzen figures are the median of eight runs for the 32- and 64-bit
digit-width table, of three for the scalar, 16-bit digit-width and path-key
tables, and the mean of two for the rest. A Ryzen cell whose runs differed by
more than 20% is marked ‡.

Reproduce with `pixi run bench`.

### Scalars

Speedup against `sort` on uniformly random input. The `sort` column is its
absolute cost in nanoseconds per element.

**Apple M4**

| type | n | `sort` | `lsb[8]` | `lsb[11]` | `msb` | `aflag` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `uint8` | 4 Ki | 5.7 ns | **8.3x** | — | 7.6x | 1.3x |
| `uint8` | 64 Ki | 18.6 ns | **28.3x** | — | 25.5x | 4.2x |
| `uint8` | 1 Mi | 19.2 ns | **27.8x** | — | 24.8x | 3.9x |
| `int16` | 4 Ki | 8.9 ns ‡ | **7.2x** | 4.1x | 1.9x | 0.9x |
| `int16` | 64 Ki | 33.1 ns | **27.1x** | 21.6x | 17.1x | 2.7x |
| `int16` | 1 Mi | 37.1 ns | **26.8x** | 23.7x | 20.9x | 2.9x |
| `float16` | 4 Ki | 7.5 ns | **4.7x** | 2.6x | 2.3x | 0.5x |
| `float16` | 64 Ki | 38.0 ns | **24.4x** | 16.6x | 15.5x | 2.6x |
| `float16` | 1 Mi | 38.9 ns | **25.1x** | 17.2x | 16.3x | 2.6x |
| `bfloat16` | 4 Ki | 10.0 ns | **4.4x** | 2.8x | 3.4x | 0.7x |
| `bfloat16` | 64 Ki | 31.6 ns | **14.1x** | 11.5x | 12.0x | 2.1x |
| `bfloat16` | 1 Mi | 32.5 ns | **14.6x** | 12.1x | 12.4x | 2.1x |
| `uint32` | 4 Ki | 9.0 ns ‡ | **4.0x** | 3.6x | 2.8x | 1.3x |
| `uint32` | 64 Ki | 34.5 ns | 14.2x | **16.0x** | 8.4x | 3.0x |
| `uint32` | 1 Mi | 44.8 ns | 12.1x | **21.0x** | 5.5x | 2.7x |
| `int32` | 4 Ki | 7.9 ns | **3.4x** | 3.2x | 1.7x | 0.9x |
| `int32` | 64 Ki | 32.2 ns | 13.3x | **15.1x** | 6.5x | 2.4x |
| `int32` | 1 Mi | 44.0 ns | 12.0x | **19.6x** | 3.9x | 2.2x |
| `float32` | 4 Ki | 8.1 ns | 2.3x | **2.6x** | 1.8x | 0.6x |
| `float32` | 64 Ki | 41.4 ns | 12.1x | **16.5x** | 5.6x | 2.2x |
| `float32` | 1 Mi | 55.2 ns | 15.5x | **22.7x** | 5.5x | 2.3x |
| `uint64` | 4 Ki | 16.4 ns ‡ | 3.7x | 4.1x | **5.1x** | 2.5x |
| `uint64` | 64 Ki | 33.5 ns | 6.4x | 7.6x | **7.9x** | 2.6x |
| `uint64` | 1 Mi | 44.6 ns | 7.0x | **9.5x** | 5.3x | 2.7x |
| `float64` | 4 Ki | 8.9 ns | 1.4x | **1.5x** | 1.1x | 0.5x |
| `float64` | 64 Ki | 41.6 ns | 6.4x | **7.2x** | 4.5x | 1.9x |
| `float64` | 1 Mi | 56.1 ns | 7.8x | **9.4x** | 3.8x | 1.9x |

‡ The three cells two clean runs disagreed on by more than 20%, all of them
the `sort` baseline at 4 Ki and none of them a radix kernel: `int16` 8.0 and
9.7 ns, `uint32` 8.0 and 10.0, `uint64` 25.1 and 7.8. The last is a factor of
3.2 and it is the denominator of every speedup in its row, so read that row as
an order of magnitude rather than a number. The other 129 cells of the 132
agreed to within 14%, and to within 5% at 1 Mi.

**AMD Ryzen AI 9 HX 370**

| type | n | `sort` | `lsb[8]` | `lsb[11]` | `msb` | `aflag` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `uint8` | 4 Ki | 2.9 ns | **4.2x** | — | 4.1x | 0.8x |
| `uint8` | 64 Ki | 21.1 ns | 29.9x | — | **30.1x** | 5.6x |
| `uint8` | 1 Mi | 20.5 ns | 26.6x | — | **27.0x** | 4.4x |
| `int16` | 4 Ki | 4.5 ns | **3.0x** | 2.8x | 1.4x | 0.6x |
| `int16` | 64 Ki | 40.8 ns | 27.9x | **28.7x** | 20.4x | 4.2x |
| `int16` | 1 Mi | 42.7 ns | 28.8x | **29.5x** | 22.9x | 4.4x |
| `float16` | 4 Ki | 5.5 ns | **2.7x** | 2.4x | 1.6x | 0.6x |
| `float16` | 64 Ki | 53.8 ns | **26.9x** | 24.9x | 18.8x | 5.5x |
| `float16` | 1 Mi | 52.4 ns | **25.6x** | 23.9x | 18.5x | 5.1x |
| `bfloat16` | 4 Ki | 6.5 ns | **3.3x** | 2.7x | 2.0x | 0.7x |
| `bfloat16` | 64 Ki | 36.9 ns | **18.9x** | 16.5x | 12.5x | 3.9x |
| `bfloat16` | 1 Mi | 36.6 ns | **18.3x** | 16.2x | 12.2x | 3.4x |
| `uint32` | 4 Ki | 4.3 ns | 1.8x | **1.9x** | 1.6x | 0.9x |
| `uint32` | 64 Ki | 37.4 ns | 15.3x | **19.0x** | 5.9x | 3.2x |
| `uint32` | 1 Mi | 47.5 ns | 19.0x | **23.3x** | 5.2x | 3.4x |
| `int32` | 4 Ki | 4.2 ns | 1.7x | **1.7x** | 1.1x | 0.7x |
| `int32` | 64 Ki | 36.3 ns | 15.3x | **17.0x** | 4.8x | 2.7x |
| `int32` | 1 Mi | 47.8 ns | 19.4x | **21.5x** | 4.1x | 2.8x |
| `float32` | 4 Ki | 5.1 ns | 1.6x | **1.9x** | 1.4x | 0.6x |
| `float32` | 64 Ki | 44.5 ns | 14.5x | **18.5x** | 4.7x | 2.3x |
| `float32` | 1 Mi | 56.2 ns | 18.0x | **22.8x** | 5.2x | 2.7x |
| `uint64` | 4 Ki | 5.1 ns ‡ | 1.0x | 1.1x | **1.7x** | 1.0x |
| `uint64` | 64 Ki | 38.6 ns | 7.7x | **9.7x** | 5.9x | 3.2x |
| `uint64` | 1 Mi | 50.8 ns | **8.6x** | 6.7x | 5.2x | 3.5x |
| `float64` | 4 Ki | 4.3 ns ‡ | 0.7x | **0.8x** | 0.7x | 0.4x |
| `float64` | 64 Ki | 44.8 ns | 7.4x | **9.1x** | 4.2x | 2.1x |
| `float64` | 1 Mi | 57.0 ns | **7.9x** | 7.0x | 4.0x | 2.2x |

‡ Both 4 Ki rows moved because `sort` itself did — by 33% for `uint64` and 21%
for `float64` across the three runs — taking every ratio in the row with it.

This table was re-run after `float16` and `bfloat16` joined the benchmark. The
library did not change, yet some cells moved further than the run-to-run
spread. Several on `int16` and at 4 Ki moved by 15–20%, enough for `lsb[11]` to
overtake `lsb[8]` on `int16`; `float32` at 4 Ki fell from 4.5x to 1.9x because
`sort` there went from 11.2 to 5.1 ns. Adding two types changed the benchmark
binary, most likely its code layout, not the sorts. Treat any single Ryzen cell
as approximate.

A few things worth reading off those tables.

**`american_flag_sort` is not the one to use for speed.** At 4 Ki it loses to
`sort` outright on five of the nine types on the M4, and on eight on the
Ryzen, tying on the ninth.
It differs from `msb_radix_sort` only in permuting in place rather than
through a scratch buffer, and pays 1.5 to 7.3 times over for it across the two
machines. Its reason to exist is that it touches no heap memory at all.

**`msb_radix_sort` wins exactly once** — `uint64` at 4 Ki, where stopping early
beats making six full passes. Everywhere else the LSD sort is ahead, on both
machines — bar `uint8` on the Ryzen, where `msb` edges `lsb[8]` by under 2%.

**The two 16-bit floats are the same width and do not behave the same.** The
comparison sort is faster on `bfloat16` (32.6 against 39.6 ns at 1 Mi) and the
radix sort slower (2.5 against 1.7), so the speedup nearly halves, 23.4x to
12.9x. The `sort` half of that has a cause: `bfloat16` keeps 7 mantissa bits
where `float16` keeps 10, so a million values drawn from the same range
collapse onto 3 147 distinct keys instead of 19 060, and duplicates are cheap
to partition around. That does not explain the radix half. Fewer distinct keys
also means a tighter scatter — 21 occupied buckets in the second pass against
139 — which should help, not hurt. Measured, unexplained, left in. On the
Ryzen only the `sort` half reproduces: `sort` is again faster on `bfloat16`
(36.6 against 52.4 ns at 1 Mi), but the radix sort is not slower (2.00 against
2.04 ns), so the unexplained part looks specific to the M4.

**The narrow types gain most.** A `uint8` needs one pass over 1 byte per
element; a `uint64` needs six passes over 8 bytes each. Between those two, at
64 Ki, the radix sort's cost rises 6.3x (0.70 to 4.42 ns/element) while the
comparison sort's rises only 1.7x — and 6.3 / 1.7 is exactly the 3.7x by which
the two speedups differ. On the Ryzen the same pair is 5.7x (0.70 to 4.01)
against 1.8x, and the speedups differ by 3.1x.

**The Ryzen prefers `lsb[8]` for 64-bit types at 1 Mi**, in all three runs:
5.9 against 7.6 ns/element for `uint64`, 7.2 against 8.2 for `float64`.
`radix_sort` uses `BITS=11` there, so on this machine it leaves between an
eighth and a quarter on the table. The next section has more.

### Digit width

The four LSD sorts this package replaced differed only in their digit width —
8, 11, 13 and 16 bits — so here it is a parameter. Sweeping it
(`pixi run bench-bits`, nanoseconds per element):

| | `uint32` 4 Ki | `uint32` 1 Mi | `uint64` 4 Ki | `uint64` 1 Mi |
| --- | ---: | ---: | ---: | ---: |
| `BITS=4` | 6.57 | 7.45 | 12.87 | 15.81 |
| `BITS=6` | 4.06 | 4.71 | 7.00 | 9.35 |
| `BITS=8` | 2.19 | 3.61 | 4.38 | 6.13 |
| `BITS=10` | 2.93 | 2.96 | 4.38 | 5.54 |
| **`BITS=11`** | **2.05** | **2.12** | **4.01** | **4.66** |
| `BITS=12` | 2.53 | 2.46 | 5.68 | 5.22 |
| `BITS=13` | 3.74 | 2.78 | 7.00 | 5.32 |
| `BITS=16` | 12.46 | 3.60 | 24.22 | 7.42 |

Mean of two runs taken after the private-histogram change; ‡ marks a cell
whose two runs differed by more than 20%. The eight-run medians this replaces
were 1-4% slower in every column. On the M4, **an 11-bit digit wins for every 32- and 64-bit type at every
size measured**, and an 8-bit digit for everything narrower. Two cases, not the
four-way table the original implied.

The one width the two machines disagree about most flatly is 10. On the Ryzen
it is the best choice for 64-bit types at 1 Mi; on the M4 it never wins
anything — `BITS=11` beat it in 8 runs out of 8 in all six 64-bit cases, by
8% at 4 Ki rising to 18% at 1 Mi.

For 16-bit types a 16-bit digit is not absurd at all — it sorts them in one
pass. Medians of three runs on the M4:

| | passes | `float16` 4 Ki | `float16` 64 Ki | `float16` 1 Mi | `bfloat16` 4 Ki | `bfloat16` 64 Ki | `bfloat16` 1 Mi |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `BITS=8` | 2 | **1.72** | 1.70 | 1.69 | **2.52** | 2.55 | 2.51 |
| `BITS=16` | 1 | 6.27 | **1.43** | **1.33** | 6.09 | **1.32** | **1.05** |

One pass over a 256 KiB histogram against two over a 1 KiB one. Below 64 Ki
the big histogram is all you are paying for and `BITS=8` wins by 2.4x to 3.7x;
from 64 Ki up `BITS=16` wins, by 1.19x for `float16` and **2.39x** for
`bfloat16` at 1 Mi. The dispatcher uses `BITS=8` for everything 16 bits and
narrower and so leaves that on the table — see
[`docs/improvements.md`](docs/improvements.md).

On the Ryzen, medians of three runs:

| | passes | `float16` 4 Ki | `float16` 64 Ki | `float16` 1 Mi | `bfloat16` 4 Ki | `bfloat16` 64 Ki | `bfloat16` 1 Mi |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `BITS=8` | 2 | **2.03** | 2.00 | 2.02 | **1.98** | 1.94 | 2.00 |
| `BITS=16` | 1 | 4.97 | **1.54** | **1.36** | 4.54 | **1.28** | **1.11** |

The crossover sits in the same place. Below it `BITS=8` wins by 2.4x and 2.3x;
above it `BITS=16` wins by 1.30x and 1.52x at 64 Ki and 1.49x and 1.80x at
1 Mi — more than on the M4 for `float16`, less for `bfloat16`.

The Ryzen agrees only in part:

| | `uint32` 4 Ki | `uint32` 1 Mi | `uint64` 4 Ki | `uint64` 1 Mi |
| --- | ---: | ---: | ---: | ---: |
| `BITS=4` | 4.67 | 4.95 | 10.68 | 12.17 ‡ |
| `BITS=8` | 2.38 | 2.42 | 5.02 | 5.79 ‡ |
| `BITS=10` | 2.69 | 2.54 | 4.81 | **5.46** |
| `BITS=11` | **2.23** | 1.99 | **4.49** | 7.81 ‡ |
| `BITS=13` | 3.32 | 2.13 | 5.70 | 7.39 ‡ |
| `BITS=16` | 8.46 | 1.99 | 18.65 | 8.57 ‡ |

On the Ryzen the best width depends on the type and the size. For 64-bit types
at 1 Mi a 10-bit digit takes about 30% less time than an 11-bit one — `float64`
too, 5.66 against 8.21 ns. Every width but `BITS=10` moved by more than 20%
between runs in that column, but the order did not: `BITS=11` took at least
1.31 times as long as `BITS=10` in every one of the eight runs. The other
disagreements are smaller and just as consistent. `float32` prefers `BITS=16`
in seven runs of eight: at 1 Mi `BITS=11` takes 1.27 times as long, at 64 Ki
1.04 times. `float64` at 4 Ki prefers `BITS=10` by about 5%, in all eight. For
`uint32` at 1 Mi, 11, 12 and 16 bits are within 2% of each other.

**Why 1 Mi: the L3 cache.** An LSD pass reads one buffer and scatters into
another, and for `uint64` at 1 Mi those two hold 16 MiB — the size of this
core's L3. The HX 370's smaller Zen 5c cores share an 8 MiB L3, and there the
cliff comes at half the size. On core 6, `BITS=11` takes 0.91 times as long as
`BITS=10` at 384 Ki, 1.18 times at 512 Ki and 1.69 at 768 Ki; on core 2 it is
still 0.94 at 768 Ki and 1.31 at 1 Mi. Past the cache fewer buckets keep
winning: at 2 Mi and 4 Mi an 8-bit digit is fastest and `BITS=11` takes about
twice as long as `BITS=10`. Page size makes it worse without causing it: with
transparent huge pages disabled the cliff arrives earlier — an 8- or 10-bit
digit already wins at 768 Ki — and every cell is slower, by up to 55%.

These were one-off sweeps outside `bench-bits`, three runs per setting, all
on `uint64`. The two core types may differ in more than L3 size, so this is
strong evidence rather than proof. The M4, which has no L3, shows no such jump
at 1 Mi.

`BITS=16` is the instructive row. Four passes instead of six looks like a clear
win and is not: four 65 536-counter histograms are 1 MiB, written twice before
any data moves. At 4 Ki that fixed cost makes it the *slowest* width in the
sweep — 24.2 ns/element against 4.0 for `BITS=11` on the M4, 18.7 against
4.5 on the Ryzen — and on the M4 it never catches up.

One case is left on the table on the M4: `float64` at 64 Ki prefers `BITS=13`
— 5.40 against 5.69 ns, about 5%, in both runs and in the 8 runs of the
earlier campaign. At 1 Mi it no longer reproduces: the two runs put `BITS=13`
at 5.38 and 12.72 ns against a steady 5.86 for `BITS=11`, so it wins or loses
by a factor of two depending on the run. The earlier campaign called it an 11%
win in 8 runs of 8; two runs now disagree with each other, and that is the
honest state of it.
The Ryzen shows the same at 64 Ki (4.42 vs 4.92) and prefers `BITS=10` at
1 Mi. The dispatcher uses 11 for all 64-bit types rather than carry a
size-dependent special case — which on the Ryzen costs every 64-bit type at
1 Mi, not just one.

### Repetition and key width

Two properties get conflated under "low cardinality", and only one of them
changes what a radix sort does. `uint32`, 1 Mi elements, mean of two runs,
`pixi run bench-cardinality`:

| distinct values | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 1 | **0.57** | 0.61 | 1.30 | 1.29 |
| 4 | 4.58 | 4.28 | **2.62** | 6.63 |
| 32 | 11.54 | 4.75 | **3.35** | 7.50 |
| 256 | 19.09 | **4.71** | 6.60 | 13.00 |
| 4 096 | 27.95 | **4.07** | 6.62 | 14.45 |
| 65 536 | 39.17 | **3.44** | 5.89 | 13.87 |
| all distinct | 43.07 | **2.13** | 8.12 | 16.30 |

| key width | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 8 bits | 18.88 | **1.32** | 2.10 | 6.99 |
| 16 bits | 40.06 | **1.80** | 3.52 | 12.38 |
| 24 bits | 43.70 | **2.51** | 8.84 | 17.06 |
| 32 bits | 43.17 | **2.13** | 8.09 | 16.26 |

On the Ryzen:

| distinct values | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 1 | **0.46** | 0.67 | 1.46 | 1.46 |
| 4 | 5.04 | **1.94** | 2.16 | 5.71 |
| 256 | 20.41 | **1.77** | 2.78 | 8.03 |
| 65 536 | 42.45 | **2.37** | 6.12 | 11.57 |
| all distinct | 46.16 | **1.98** | 8.56 | 13.75 |

| key width | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 8 bits | 20.45 | **1.11** | 1.96 | 4.75 |
| 16 bits | 42.73 | **1.52** | 2.49 | 7.87 |
| 24 bits | 46.30 | **2.12** | 8.95 | 14.13 |
| 32 bits | 46.25 | **1.99** | 8.57 | 13.75 |

The comparison sort gets steadily faster as values repeat — equal elements are
cheap to partition around, and at one distinct value it is the fastest thing
in the table. The LSD sort barely notices repetition at all. What it
notices is the *width* of the keys, because a pass whose digit never varies is
skipped entirely: 8-bit data in a `uint32` takes one pass instead of three and
runs about **1.6x** faster than full-width data (1.8x on the Ryzen). Less
than three times, because the single read that builds every pass's histogram
is paid either way.

One row in that table is not explained. **24-bit keys are consistently slower
than 32-bit ones** — 2.77 against 2.23 ns — across three separate runs, for
every one of the three radix sorts, although both widths need exactly the same
number of passes. Something about the narrower top digit costs more than the
wider one, and I have not worked out what. It is left in rather than smoothed
over. It is not an M4 quirk: the Ryzen shows it too, for all three radix sorts
in both runs (`lsb[11]` 2.12 against 1.99 ns).

The benchmark this replaces varied both knobs at once and reported it as one,
which is how the same table came to show radix at 0.12x and at 26x —
see [`docs/migration.md`](docs/migration.md).

### Strings

The twelve word lists in `corpora/` are a few hundred entries each, which is
below the size at which any radix sort has something to offer — they come out
a wash, and they cannot settle anything. The measurements that can are derived
from a whole book: half a million keys, four shapes.
`bash corpora/large/setup.sh` fetches the text, then `pixi run bench-large`.

| corpus | keys | mean len | prefix | prefix % | `sort` | `radix_sort` | net |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tokens | 563 286 | 4.8 B | 4.6 B | 96% | 68.7 ns | 40.5 ns | **1.71x** |
| vocabulary | 41 548 | 8.5 B | 5.8 B | 68% | 101.6 ns | 54.6 ns | **1.87x** |
| lines | 51 861 | 61.9 B | 8.1 B | 13% | 121.7 ns | 109.2 ns | **1.12x** |
| phrases | 563 280 | 33.7 B | 10.5 B | 31% | 146.0 ns | 148.5 ns | 0.98x |

On the Ryzen:

| corpus | keys | mean len | prefix | prefix % | `sort` | `radix_sort` | net |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tokens | 563 286 | 4.8 B | 4.6 B | 96% | 77.4 ns | 33.0 ns | **2.41x** |
| vocabulary | 41 548 | 8.5 B | 5.8 B | 68% | 115.8 ns | 60.2 ns | **1.94x** |
| lines | 51 861 | 61.9 B | 8.1 B | 13% | 186.3 ns | 95.5 ns | **2.04x** |
| phrases | 563 280 | 33.7 B | 10.5 B | 31% | 227.9 ns | 163.3 ns | **1.42x** |

Nanoseconds per key, and the speedup net of the `List[String]` copy each
iteration needs to start from unsorted input. On each machine two clean runs
agreed to within 3% on every row, and both machines sorted the same text —
the key counts match exactly.

An earlier version of this table had them differing by 2%, and blamed CRLF.
That was wrong: the M4 column had been measured on a hand-supplied copy of the
book rather than on what `setup.sh` fetches, which is a different edition with
no Project Gutenberg front matter. Both columns now come from the documented
command. (The CRLF stripping in `setup.sh` is real and necessary — a kept
`\r` would end every line key and turn every blank line into a key — it just
was not the cause here.)

*tokens* is every whitespace-separated word in order, so it repeats heavily —
the hundred commonest words are about half the text. *vocabulary* is the
distinct tokens, shuffled back out of sorted order. *lines* and *phrases* are
the non-blank lines and every run of six consecutive words.

The other axis is how much prefix the keys share, measured on generated
path-like keys (`pixi run bench-strings`):

| keys | shared prefix | `sort` | `radix_sort` | net |
| ---: | ---: | ---: | ---: | ---: |
| 100 000 | 7.5 B | 111.7 ns | 63.5 ns | **1.77x** |
| 100 000 | 20.5 B | 137.8 ns | 95.7 ns | **1.45x** |
| 100 000 | 66.5 B | 172.8 ns | 178.2 ns | 0.97x |

On the Ryzen:

| keys | shared prefix | `sort` | `radix_sort` | net |
| ---: | ---: | ---: | ---: | ---: |
| 100 000 | 7.5 B | 127.8 ns | 65.7 ns | **1.97x** ‡ |
| 100 000 | 20.5 B | 202.4 ns | 85.3 ns | **2.45x** |
| 100 000 | 66.5 B | 208.0 ns | 139.0 ns | **1.54x** |

**A deep shared prefix is what costs.** This sort advances one byte per
recursion level, so a 66-byte shared prefix means 66 full histogram passes
over the range, each finding a single occupied bucket, before the keys begin
to differ at all. The comparison sort walks that same prefix with a
word-at-a-time memcmp. That is the one mechanism here that both tables agree
on, and the fix — advancing eight bytes at a time when a level has one
occupied bucket — is in [`docs/improvements.md`](docs/improvements.md).

On the Ryzen the prefix still costs — 2.45x falls to 1.54x between 20.5 and
66.5 shared bytes — but not down to parity, because both sides move: at
66.5 B the comparison sort is slower there than on the M4 (208 against
173 ns) and the radix sort faster (139 against 178).

**Prefix depth alone does not order every row, though.** *lines* shares only
8.1 bytes and manages 1.12x, while path keys sharing 7.5 bytes manage 1.77x.
The difference between them is key length — 61.9 bytes against about 20 — so
length is doing something too, and I have not separated the two effects. The
Ryzen does not show that gap at all — *lines* 2.04x against 1.97x — so
whatever length is doing depends on the machine. On the M4 the tables support
the pairing **short keys, shallow prefixes, a clear win; long keys or deep
prefixes, parity.** On the Ryzen `radix_sort` won every corpus of 10 000 keys
or more, by 1.36x at worst.

### The dispatch threshold

`pixi run bench-dispatch` shows where the fallback should sit and whether
`radix_sort` tracks it. `uint64`, nanoseconds per element, mean of two runs:

| n | `sort` | `lsb[11]` | `radix_sort` |
| ---: | ---: | ---: | ---: |
| 16 | 2.29 | 236.06 | **2.21** |
| 256 | 4.58 | 17.37 | **4.57** |
| 1024 | **6.09** | 6.52 | 6.11 |
| 2048 | 6.75 | 4.69 | **4.66** |
| 4096 | 8.67 ‡ | 3.96 | **3.96** |

On the Ryzen:

| n | `sort` | `lsb[11]` | `radix_sort` |
| ---: | ---: | ---: | ---: |
| 16 | 2.16 | 180.58 | **2.03** ‡ |
| 256 | 2.76 | 14.75 | **2.75** |
| 1024 | **3.21** | 6.53 | 3.25 |
| 2048 | **3.50** | 5.14 | 5.13 |
| 4096 | 5.10 ‡ | 4.75 | **4.48** |

At n=16 the kernel is a hundred times slower than the comparison sort on the
M4 and 84 times on the Ryzen, all of it histogram. The threshold is derived
from the histogram size rather than tabulated per type: each pass costs at
least about 64 elements' worth of work, and more once its histogram is large.

**That derivation does not carry over to the Ryzen for `uint64`.** There
`radix_sort` stops falling back at n = 1536, but the kernel does not beat
`sort` until about 4096: at 2048 `radix_sort` takes 5.13 ns/element against
3.50 for `sort`, 1.5x slower, in both runs. For `uint8`, `uint16` and `uint32`
the thresholds match the crossover as closely as the measured sizes can tell.

## Development

```bash
pixi run test               # the test suite (18 tests)
pixi run main               # the example
pixi run format             # mojo format
pixi run docs               # docstring check
pixi build                  # the conda package (needs pixi >= 0.80)

pixi run bench              # the scalar table
pixi run bench-bits         # the digit-width sweep
pixi run bench-cardinality  # repetition and key width
pixi run bench-dispatch     # where the fallback should sit
pixi run bench-strings      # the small corpora and the path-like keys
pixi run bench-large        # a whole book, four ways (needs setup, below)
```

The large-string benchmark needs one text file that is not committed:

```bash
bash corpora/large/setup.sh                  # download it
bash corpora/large/setup.sh ~/some/book.txt  # or point at a copy
```

See [`corpora/large/README.md`](corpora/large/README.md). Everything else runs
from a clean checkout.

Benchmarks are sensitive to anything else running on the machine — an
unrelated `git add` during a run moved one row by 50%. Run them on an
otherwise idle box, and re-run before believing a number. On a CPU with two
kinds of core, pin the run to a full-size one — the Ryzen figures above come
from `taskset -c 2 pixi run bench` and friends — or the scheduler decides
which core you measured.

## Provenance

A port of the `radix_sorting/` directory of
[mzaks/mojo-sort](https://github.com/mzaks/mojo-sort), which was written
against a 2023-era Mojo. Eight implementations became four, three bugs did not
survive the move, and one benchmark turned out not to be measuring what it
said. See [`docs/migration.md`](docs/migration.md).

The word lists in `corpora/` come from
[mzaks/compact-dict](https://github.com/mzaks/compact-dict).

The LSD design follows Michael Herf's
[radix tricks](http://stereopsis.com/radix.html), which is what the original
`radix_sort11` cited.

## License

MIT. See [LICENSE](LICENSE).
