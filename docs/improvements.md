# Identified improvements

Things measured, understood, and not done. Each has a number attached, because
an optimisation without one is a guess.

## Skip a shared prefix in machine words, not bytes

`byte_radix_sort` advances one byte per recursion level. When a range shares a
long prefix -- paths, namespaced identifiers, ARNs -- every one of those shared
bytes costs a full pass over the range that finds exactly one occupied bucket
and moves nothing.

Measured on 100 000 path-like keys built from the English word list
(`pixi run bench-strings`):

| shared prefix | `sort` | `radix_sort` | net |
| --- | --- | --- | --- |
| 7.5 bytes | 116.1 ns/word | 65.1 ns/word | **1.79x** |
| 20.5 bytes | 138.1 ns/word | 95.5 ns/word | **1.46x** |
| 66.5 bytes | 153.8 ns/word | 165.7 ns/word | **0.93x** |

The comparison sort walks the same prefix with a word-at-a-time memcmp, which
is why it does not degrade the same way.

The fix is to detect a single-occupied-bucket level and advance `depth` eight
bytes at a time by comparing `UInt64` chunks, falling back to a byte at the
first chunk that differs. That turns 59 passes into 8. It needs a wider
extractor than the current `byte_of(element, depth) -> Int`, so it is a change
to the generic interface, not just to the implementation -- which is why it is
written down here rather than done.

## The cutoff comparison still calls through `byte_of` per byte

`_insertion_sort` is handed `depth` and compares from there, which is what
keeps the cutoff cheap on shared-prefix data. For `String` the comparator then
walks byte by byte. The same word-at-a-time treatment applies.

## A 13-bit digit for `float64`

The dispatcher uses an 11-bit digit for every 32- and 64-bit type. That is
right for three of the four wide types and about 9% short for one:

| `float64`, ns/element | `BITS=11` | `BITS=13` |
| --- | ---: | ---: |
| 4 096 | **6.40** | 7.77 |
| 65 536 | 5.76 | **5.49** |
| 1 048 576 | 6.01 | **5.45** |

Confirmed across two clean runs. Taking it would mean a size-dependent branch
for one type, which is more special case than 9% is worth until something
shows the same shape for `uint64` too -- and it does not: `BITS=11` wins there
at every size.

## Ideas that measurement killed

**A per-type table of digit widths.** The obvious shape for the dispatcher was
a table -- 8-bit digits here, 11 there, 13 or 16 for the wide types, as the
four hand-written sorts this package replaced implied. The sweep in
`benchmarks/bench_bits.mojo` says an 11-bit digit is fastest for every 32- and
64-bit type at every size measured, and an 8-bit digit for everything
narrower. Two cases, no table.

**A 16-bit digit for 64-bit values.** Four passes instead of six looks like a
clear win and is not: four 65 536-counter histograms are 1 MiB, written twice
before any data moves. At 4 096 elements that fixed cost makes `BITS=16` the
*slowest* width in the sweep -- 25.2 ns/element against 4.2 for `BITS=11` --
and it never catches up at any size measured.
