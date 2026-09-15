# Identified improvements

Things measured, understood, and not done. Each has a number attached, because
an optimisation without one is a guess.

## Skip a shared prefix in machine words, not bytes

`byte_radix_sort` advances one byte per recursion level. When a range shares a
long prefix -- paths, namespaced identifiers, ARNs -- every one of those shared
bytes costs a full pass over the range that finds exactly one occupied bucket
and moves nothing.

Measured two ways. On generated path-like keys, 100 000 of them
(`pixi run bench-strings`):

| shared prefix | `sort` | `radix_sort` | net |
| --- | ---: | ---: | ---: |
| 7.5 bytes | 111.7 ns/key | 63.5 ns/key | **1.77x** |
| 20.5 bytes | 137.8 ns/key | 95.7 ns/key | **1.45x** |
| 66.5 bytes | 172.8 ns/key | 178.2 ns/key | **0.97x** |

And on corpora derived from a book (`pixi run bench-large`), where the short
keys win and the long ones do not:

| corpus | keys | mean len | prefix | net |
| --- | ---: | ---: | ---: | ---: |
| tokens | 562 488 | 4.7 B | 4.5 B | **1.73x** |
| vocabulary | 41 621 | 8.0 B | 5.6 B | **1.87x** |
| lines | 50 886 | 61.7 B | 7.7 B | **1.16x** |
| phrases | 562 482 | 33.0 B | 10.3 B | **0.97x** |

The comparison sort walks a shared prefix with a word-at-a-time memcmp, which
is why it does not degrade the same way.

The fix is to detect a single-occupied-bucket level and advance `depth` eight
bytes at a time by comparing `UInt64` chunks, falling back to a byte at the
first chunk that differs. That turns 66 passes into 9. It needs a wider
extractor than the current `byte_of(element, depth) -> Int`, so it is a change
to the generic interface, not just to the implementation -- which is why it is
written down here rather than done.

Note that prefix depth does not explain everything: `lines` shares 7.7 bytes
and gets 1.16x while path keys sharing 7.5 bytes get 1.77x. Key length differs
between them by 3x, so length is doing something independent of prefix depth.
Worth separating before assuming the chunked skip fixes both.

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
