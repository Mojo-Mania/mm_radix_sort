# mm_radix_sort

[![CI](https://github.com/Mojo-Mania/mm_radix_sort/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_radix_sort/actions/workflows/ci.yml)

Radix sorts for [Mojo](https://mojolang.org) — for scalars, for strings, and
for any key you can hand over one byte at a time.

A comparison sort asks "is this one smaller?" about `n log n` pairs. A radix
sort never asks: it reads the digits of a key and puts each element where its
digits say it belongs. The work is then proportional to the number of digits
rather than to `log n`, and on fixed-width numeric data that trade is very
one-sided — **7 to 28 times faster than the stdlib's `sort`**, with the
narrower types gaining the most.

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

**For numbers, above a few hundred of them, always.** The margin is large
enough that there is not much to weigh up. It grows as the type gets narrower,
because a narrow key has fewer digits to walk: a `uint8` sorts up to **27.8x**
faster than `sort`, a `uint64` **9.2x**.

**Below the crossover, don't.** A radix pass writes its whole histogram twice —
once to zero it, once to prefix-sum it — whether you give it ten elements or
ten million, so on small inputs that fixed cost is the entire runtime.
`radix_sort` falls back to `sort` there and you can ignore this. If you call a
kernel directly, the crossovers are n = 64 for `uint8`, ~100 for `uint16`,
~700 for `uint32` and ~1100 for `uint64`.

**For strings it depends on the shape of the keys.** On a few hundred words it
is a wash. On a hundred thousand it wins by **1.8x** — unless the keys share a
long prefix, where it *loses*, because this sort spends one full pass over the
range per shared byte. See [Strings](#strings).

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

| | |
| --- | --- |
| `radix_sort(span)` | Scalars. Dispatches on type and size. |
| `radix_sort(span)` | `Span[String]`. Byte order, which over UTF-8 is codepoint order. |
| `lsb_radix_sort[BITS=8](span)` | Least-significant-digit, `BITS` wide, 1–16. |
| `msb_radix_sort(span)` | Most-significant-digit, out of place. |
| `american_flag_sort(span)` | Most-significant-digit, in place, no heap. |
| `byte_radix_sort[byte_of, less](span)` | Any variable-length byte key. |

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

**The narrow types gain most.** A `uint8` needs one pass and a 256-counter
histogram; a `uint64` needs six passes over data twice as wide.

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
changes what a radix sort does. `uint32`, 1 Mi elements, `pixi run
bench-cardinality`:

| distinct values | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 4.84 | 4.76 | **2.64** | 6.75 |
| 256 | 19.56 | **4.82** | 6.71 | 13.29 |
| 65 536 | 40.40 | **3.53** | 6.08 | 14.37 |
| all distinct | 44.23 | **2.19** | 8.27 | 16.95 |

| key width | `sort` | `lsb[11]` | `msb` | `aflag` |
| ---: | ---: | ---: | ---: | ---: |
| 8 bits | 19.39 | **2.00** | 2.13 | 7.23 |
| 16 bits | 41.39 | **2.35** | 3.58 | 12.70 |
| 32 bits | 44.46 | **2.18** | 8.30 | 16.83 |

The comparison sort gets faster as values repeat, because equal elements are
cheap to partition around. The LSD sort mostly does not care: its cost tracks
the *width* of the keys, since a pass whose digit never varies is skipped
entirely. Narrow 8-bit data costs one pass instead of three.

The benchmark this replaces varied both knobs at once and reported it as one,
which is how the same table came to show radix at 0.12x and at 26x —
see [`docs/migration.md`](docs/migration.md).

### Strings

`pixi run bench-strings`. Both columns include a `List[String]` copy per
iteration, the only way to start each run from unsorted input; `net` takes it
out.

Twelve real word lists — a few hundred words each, below the size where a
radix sort has anything to offer:

| corpus | words | shared prefix | `sort` | `radix_sort` | net |
| --- | ---: | ---: | ---: | ---: | ---: |
| english | 999 | 3.6 B | 21.9 ns | 22.1 ns | 0.99x |
| french | 471 | 2.1 B | 19.8 ns | 17.5 ns | **1.14x** |
| l33t | 487 | 2.6 B | 18.9 ns | 16.2 ns | **1.18x** |
| s3_actions | 161 | 10.8 B | 24.5 ns | 35.4 ns | 0.68x |
| hindi | 450 | 12.4 B | 31.7 ns | 40.9 ns | 0.77x |

The same words built into path-like keys, at scale:

| keys | shared prefix | `sort` | `radix_sort` | net |
| ---: | ---: | ---: | ---: | ---: |
| 10 000 | 6.4 B | 85.4 ns | 52.9 ns | **1.62x** |
| 100 000 | 7.5 B | 111.7 ns | 63.5 ns | **1.77x** |
| 100 000 | 20.5 B | 137.8 ns | 95.7 ns | **1.45x** |
| 10 000 | 65.4 B | 97.3 ns | 140.3 ns | 0.69x |
| 100 000 | 66.5 B | 172.8 ns | 178.2 ns | 0.97x |

This table was written expecting the opposite. A comparison sort re-reads a
shared prefix at every level of its recursion, so long prefixes ought to favour
the radix sort — but the loss is on the radix side: it advances **one byte per
level**, so a 59-byte shared prefix costs 59 full histogram passes over the
range, each finding a single occupied bucket, before the keys begin to differ.
The comparison sort walks that prefix with a word-at-a-time memcmp.

Advancing eight bytes at a time when a level has one occupied bucket would turn
those 59 passes into 8. It needs a wider extractor than
`byte_of(element, depth) -> Int`, so it is written up in
[`docs/improvements.md`](docs/improvements.md) rather than done.

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
pixi run bench-strings      # the corpora and the path-like keys
```

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
