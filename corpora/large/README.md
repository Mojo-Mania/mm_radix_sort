# Large corpus

The twelve word lists in `corpora/` are a few hundred words each — below the
size at which a radix sort has anything to offer. This directory holds the one
input the large-string benchmark uses instead: a whole book.

```bash
bash corpora/large/setup.sh                  # download it
bash corpora/large/setup.sh ~/some/book.txt  # or point at a copy
pixi run bench-large
```

Nothing here is committed. `benchmarks/bench_large_strings.mojo` derives every
corpus from the single text file in Mojo — tokens, vocabulary, lines and
phrases — so the derivations are in the benchmark where they can be read,
rather than baked into files. Besides dropping Gutenberg's header and footer,
`setup.sh` strips `\r`: Gutenberg serves CRLF, and the benchmark splits lines
on `\n`.

The default text is Tolstoy's *War and Peace* in the Maude translation,
[Project Gutenberg ebook 2600](https://www.gutenberg.org/ebooks/2600), public
domain. Any large plain-text file works; the benchmark prints the shape of
each corpus it builds, so a run on a different book stays interpretable.
