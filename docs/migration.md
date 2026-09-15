# What changed from `mzaks/mojo-sort`

This package is a port of the `radix_sorting/` directory of
[mzaks/mojo-sort](https://github.com/mzaks/mojo-sort), which was written
against a 2023-era Mojo and has not compiled for some time. The port is not a
translation: the same algorithms are here, but there were eight of them and
now there are four, and three bugs did not survive the move.

## Eight implementations became four

| was | is |
| --- | --- |
| `radix_sort` (8-bit digits, all widths) | `lsb_radix_sort[BITS=8]` |
| `radix_sort11` (11-bit, 32-bit values) | `lsb_radix_sort[BITS=11]` |
| `radix_sort13` (13-bit, 64-bit values) | `lsb_radix_sort[BITS=13]` |
| `radix_sort16` (16-bit, 64-bit values) | `lsb_radix_sort[BITS=16]` |
| `aflag_sort` | `american_flag_sort` |
| `aflag_copy_sort` | `msb_radix_sort` |
| `aflag_8` | *removed* -- the dispatcher covers it |
| `msb_radix_sort` (strings) | `radix_sort` on a `Span[String]`, rewritten |
| `aflag_generic` (never committed) | `byte_radix_sort`, finished |

The four LSD sorts were one algorithm written out four times, a little over
600 lines. `radix_sorting13.mojo` and `radix_sorting16.mojo` held byte-for-byte
identical copies of the same 20-line float flip, and four more copies of that
flip lived in the other files. Here the digit width is a parameter, the flip
is defined once in `_bits.mojo`, and the sweep in `benchmarks/bench_bits.mojo`
measures the parameter rather than assuming it.

The renaming of `aflag_copy_sort` to `msb_radix_sort` is the author's own,
from the commit that introduced it: *"implemented aflag copying sort, which is
actually just msb radix sort"*.

## Three bugs

**The string sort could return the wrong order.** `_msb_radix_sort` guarded
its single-bucket shortcut with `partitions[0] == end - start`, comparing a
*byte value* to an *element count*. When those coincided it skipped the
permutation for the whole range and recursed a byte deeper, leaving every
singleton where it lay. `test_strings_single_multi_element_bucket` is that
case; it fails if the guard is put back.

**The string sort read past the end of a string.** It loaded
`v.unsafe_ptr().load(depth)` for every element *before* checking `depth`
against any length, so a bucket of duplicate strings recursing below their own
length read out of bounds. This package uses 257 buckets, with bucket 0
meaning *this key has no byte here*, so the question is answered by the key
extractor and never by a load.

**The 11-, 13- and 16-bit sorts wrote past the end of their buffers.** They
built scratch as `List[UInt32](capacity=elements)` -- capacity, not length --
and then indexed it. It worked because the capacity was allocated.

## Two hazards

**A 1 MiB `stack_allocation`.** `radix_sort16` put four 65 536-counter
histograms on the stack. That survives on an 8 MiB main thread and nowhere
else. Histograms are heap-allocated here, in one block.

**Recursive `stack_allocation`.** The MSD sorts allocated counters inside the
recursion. Mojo gives each activation its own (verified), but the scalar sorts
here hoist one block per level into the entry point anyway, since the depth is
known from the type.

## One benchmark that was not measuring what it said

`bench_low_cardinality_list_sort` passed its `delta` argument to the generator
for the stdlib sort and omitted it for all three radix variants. At delta 0
the stdlib sorted a constant array while radix sorted uniformly random data;
at delta 100 the stdlib sorted 100 distinct values while radix sorted 256.
Every row compared two different inputs, in both directions, which is why the
same table showed radix at 0.12x and at 26x.

`benchmarks/bench_cardinality.mojo` replaces it, and splits the one knob into
two that were being conflated: how many *distinct* values appear, and how
*wide* they are. Only the second one changes how many passes the sort makes.

## API notes

- Everything takes a `Span`, not a `List`. Call as `radix_sort(Span(values))`.
- `fn` became `def`, `@parameter` became `comptime`, `constrained` became
  `comptime assert`, and the stdlib imports gained their `std.` prefix.
- `bit_width_of` and `bitcast` moved to `std.sys.info` and `std.memory`.
- Callbacks passed to `byte_radix_sort` must be declared `capturing`, whether
  or not they capture anything.
