# mm_radix_sort

[![CI](https://github.com/Mojo-Mania/mm_radix_sort/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_radix_sort/actions/workflows/ci.yml)

Radix sorts for [Mojo](https://mojolang.org) — for scalars, for strings, and
for any key you can hand over one byte at a time.

A comparison sort asks "is this one smaller?" about `n log n` pairs. A radix
sort never asks: it reads the digits of a key and puts each element where its
digits say it belongs. The work is then proportional to the number of digits
rather than to `log n`, and on fixed-width numeric data that trade is very
one-sided — on an array of 64 Ki elements or more it is **7 to 28 times
faster than the stdlib's `sort`**, with the narrower types gaining the most.

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
walk. At 64 Ki elements a `uint8` sorts **27.8x** faster than `sort` and a
`uint64` **7.6x**; at 4 Ki those become 8.4x and 2.3x.

**Below the crossover, don't.** A radix pass writes its whole histogram twice —
once to zero it, once to prefix-sum it — whether you give it ten elements or
ten million, so on small inputs that fixed cost is the entire runtime.
`radix_sort` falls back to `sort` there and you can ignore this. If you call a
kernel directly, the crossovers are n = 64 for `uint8`, ~100 for `uint16`,
~700 for `uint32` and ~1100 for `uint64`.

**For strings, it depends on the shape of the keys.** Sorting half a million
words out of a book it wins by **1.7x**, and a shuffled vocabulary by
**1.9x**. But it advances one byte per recursion level, so keys that are long
or share a deep prefix — paths, ARNs, namespaced identifiers — bring it back
to parity or worse. See [Strings](#strings).

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
LSD passes cost more than stopping early, and nowhere else measured.

The two MSD variants differ only in the partition step: `msb_radix_sort`
copies the range aside and scatters it back, `american_flag_sort` permutes in
place with cyclic swaps. Permuting in place costs between **1.8x and 7.3x**
across the measured grid — widest on the narrow types — and buys you a sort
that never touches the heap.

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

Apple M4, one variant per process, `-D ASSERT=none`. Every timing refills the
working buffer from a pristine copy before sorting, both inside the timed
region, because a sort run twice on the same buffer measures the second run on
already-sorted input. That refill is a `memcpy` costing 0.01–0.10 ns/element;
it is identical for every contender and is reported as a floor rather than
subtracted out.

Reproduce with `pixi run bench`.

### Scalars

Speedup against `sort` on uniformly random input. The `sort` column is its
absolute cost in nanoseconds per element.

| type | n | `sort` | `lsb[8]` | `lsb[11]` | `msb` | `aflag` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `uint8` | 4 Ki | 6.0 ns | **8.4x** | — | 8.2x | 1.3x |
| `uint8` | 64 Ki | 19.5 ns | **27.8x** | — | 26.7x | 4.4x |
| `uint8` | 1 Mi | 19.3 ns | **25.7x** | — | 25.3x | 3.9x |
| `int16` | 4 Ki | 8.3 ns | **6.2x** | 4.4x | 1.7x | 0.8x |
| `int16` | 64 Ki | 33.9 ns | **25.0x** | 20.0x | 17.6x | 2.7x |
| `int16` | 1 Mi | 36.5 ns | **24.0x** | 20.9x | 20.7x | 2.8x |
| `uint32` | 4 Ki | 9.8 ns | 4.5x | **4.7x** | 3.0x | 1.4x |
| `uint32` | 64 Ki | 34.7 ns | 14.3x | **15.8x** | 7.9x | 2.8x |
| `uint32` | 1 Mi | 44.9 ns | 11.9x | **20.5x** | 5.5x | 2.7x |
| `int32` | 4 Ki | 9.2 ns | 4.0x | **4.3x** | 1.9x | 1.1x |
| `int32` | 64 Ki | 34.8 ns | 13.9x | **15.9x** | 7.2x | 2.5x |
| `int32` | 1 Mi | 44.9 ns | 12.0x | **19.6x** | 3.9x | 2.2x |
| `float32` | 4 Ki | 8.2 ns | 2.4x | **3.0x** | 1.8x | 0.6x |
| `float32` | 64 Ki | 42.8 ns | 12.1x | **16.5x** | 5.5x | 2.1x |
| `float32` | 1 Mi | 55.8 ns | 14.6x | **21.9x** | 5.4x | 2.3x |
| `uint64` | 4 Ki | 7.5 ns | 1.8x | 1.8x | **2.3x** | 1.2x |
| `uint64` | 64 Ki | 33.6 ns | 6.5x | **7.6x** | 6.4x | 2.3x |
| `uint64` | 1 Mi | 44.2 ns | 7.0x | **9.2x** | 5.1x | 2.7x |
| `float64` | 4 Ki | 7.7 ns | **1.2x** | 0.7x † | 1.0x | 0.5x |
| `float64` | 64 Ki | 43.5 ns | 6.6x | **7.5x** | 5.1x | 2.0x |
| `float64` | 1 Mi | 55.9 ns | 7.6x | **9.2x** | 3.7x | 1.9x |

† The one cell two independent clean runs disagreed on by more than 20%: the
other run put it at 1.3x. At 4 Ki a six-pass sort is close enough to the
crossover that the number is not stable. Of the 81 cells measured twice, this
was the only genuine disagreement.

Three things worth reading off that table.

**`american_flag_sort` is not the one to use for speed.** At 4 Ki it loses to
`sort` outright on four of the seven types. It differs from `msb_radix_sort`
only in permuting in place rather than through a scratch buffer, and pays two
to five times over for it. Its reason to exist is that it touches no heap
memory at all.

**`msb_radix_sort` wins exactly once** — `uint64` at 4 Ki, where stopping early
beats making six full passes. Everywhere else the LSD sort is ahead.

**The narrow types gain most.** A `uint8` needs one pass over 1 byte per
element; a `uint64` needs six passes over 8 bytes each. Between those two, at
64 Ki, the radix sort's cost rises 6.3x (0.70 to 4.42 ns/element) while the
comparison sort's rises only 1.7x — and 6.3 / 1.7 is exactly the 3.7x by which
the two speedups differ.

### Digit width

The four LSD sorts this package replaced differed only in their digit width —
8, 11, 13 and 16 bits — so here it is a parameter. Sweeping it
(`pixi run bench-bits`, nanoseconds per element):

| | `uint32` 4 Ki | `uint32` 1 Mi | `uint64` 4 Ki | `uint64` 1 Mi |
| --- | ---: | ---: | ---: | ---: |
| `BITS=4` | 6.56 | 7.58 | 12.90 | 16.20 |
| `BITS=8` | 2.24 | 3.74 | 4.22 | 6.36 |
| **`BITS=11`** | **2.10** | **2.20** | **4.48** | **4.84** |
| `BITS=13` | 3.76 | 2.72 | 7.66 | 5.17 |
| `BITS=16` | 12.56 | 3.61 | 24.91 | 7.70 |

**An 11-bit digit wins for every 32- and 64-bit type at every size measured**,
and an 8-bit digit for everything narrower. Two cases, not the four-way table
the original implied.

`BITS=16` is the instructive row. Four passes instead of six looks like a clear
win and is not: four 65 536-counter histograms are 1 MiB, written twice before
any data moves. At 4 Ki that fixed cost makes it the *slowest* width in the
sweep — 24.9 ns/element against 4.5 for `BITS=11` — and it never catches up.

One case is left on the table: `float64` at 64 Ki and above prefers `BITS=13`
by about 9% (5.45 vs 6.01 ns at 1 Mi, confirmed across two runs). The
dispatcher uses 11 for all 64-bit types rather than carry a size-dependent
special case for one of them.

### Repetition and key width

Two properties get conflated under "low cardinality", and only one of them
changes what a radix sort does. `uint32`, 1 Mi elements,
`pixi run bench-cardinality`:

| distinct values | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 1 | **0.57** | 0.66 | 1.32 | 1.33 |
| 4 | 4.78 | 4.64 | **2.64** | 6.74 |
| 256 | 19.54 | **4.82** | 6.84 | 13.40 |
| 65 536 | 40.16 | **3.50** | 6.10 | 14.39 |
| all distinct | 44.35 | **2.19** | 8.27 | 16.76 |

| key width | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 8 bits | 19.29 | **1.32** | 2.14 | 7.20 |
| 16 bits | 40.82 | **1.86** | 3.47 | 12.73 |
| 24 bits | 44.53 | **2.77** | 9.19 | 18.05 |
| 32 bits | 45.26 | **2.23** | 8.44 | 17.16 |

The comparison sort gets steadily faster as values repeat — equal elements are
cheap to partition around, and at one distinct value it is the fastest thing
in the table. The LSD sort barely notices repetition at all. What it
notices is the *width* of the keys, because a pass whose digit never varies is
skipped entirely: 8-bit data in a `uint32` takes one pass instead of three and
runs about **1.6x** faster than full-width data. Less than three times,
because the single read that builds every pass's histogram is paid either way.

One row in that table is not explained. **24-bit keys are consistently slower
than 32-bit ones** — 2.77 against 2.23 ns — across three separate runs, for
every one of the three radix sorts, although both widths need exactly the same
number of passes. Something about the narrower top digit costs more than the
wider one, and I have not worked out what. It is left in rather than smoothed
over.

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
| tokens | 562 488 | 4.7 B | 4.5 B | 96% | 67.8 ns | 39.5 ns | **1.73x** |
| vocabulary | 41 621 | 8.0 B | 5.6 B | 70% | 101.9 ns | 55.0 ns | **1.87x** |
| lines | 50 886 | 61.7 B | 7.7 B | 13% | 119.0 ns | 103.4 ns | **1.16x** |
| phrases | 562 482 | 33.0 B | 10.3 B | 31% | 143.3 ns | 147.9 ns | 0.97x |

Nanoseconds per key, and the speedup net of the `List[String]` copy each
iteration needs to start from unsorted input. Two clean runs agreed to within
3% on every row.

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

**A deep shared prefix is what costs.** This sort advances one byte per
recursion level, so a 66-byte shared prefix means 66 full histogram passes
over the range, each finding a single occupied bucket, before the keys begin
to differ at all. The comparison sort walks that same prefix with a
word-at-a-time memcmp. That is the one mechanism here that both tables agree
on, and the fix — advancing eight bytes at a time when a level has one
occupied bucket — is in [`docs/improvements.md`](docs/improvements.md).

**Prefix depth alone does not order every row, though.** *lines* shares only
7.7 bytes and manages 1.16x, while path keys sharing 7.5 bytes manage 1.77x.
The difference between them is key length — 61.7 bytes against about 20 — so
length is doing something too, and I have not separated the two effects. What
the tables support is the pairing: **short keys, shallow prefixes, a clear
win; long keys or deep prefixes, parity.**

### The dispatch threshold

`pixi run bench-dispatch` shows where the fallback should sit and whether
`radix_sort` tracks it. `uint64`, nanoseconds per element:

| n | `sort` | `lsb[11]` | `radix_sort` |
| ---: | ---: | ---: | ---: |
| 16 | 2.48 | 240.13 | **2.47** |
| 256 | 4.99 | 17.81 | **4.87** |
| 1024 | 6.22 | 6.71 | **6.40** |
| 2048 | 6.89 | 4.84 | **4.80** |
| 4096 | 8.06 | 4.08 | **4.08** |

At n=16 the kernel is a hundred times slower than the comparison sort, all of
it histogram. The threshold is derived from the histogram size rather than
tabulated per type: each pass costs at least about 64 elements' worth of work,
and more once its histogram is large.

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
otherwise idle box, and re-run before believing a number.

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
