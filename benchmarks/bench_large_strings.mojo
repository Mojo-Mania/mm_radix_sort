"""Sorts a whole book, four ways, because a few hundred words proves nothing.

The twelve corpora in `corpora/` run to a few hundred words each. That is well
under the size at which any radix sort has an advantage, so `bench_strings`
comes out close to a tie and cannot say much. This one derives four corpora
from a single large text -- `corpora/large/setup.sh` puts one there -- and they
differ along the two axes that decide whether a string radix sort is worth it:

- **tokens**: every whitespace-separated word, in order. Half a million keys,
  most of them very short, and heavily repeated -- the hundred commonest words
  are about half the text. Nearly all of a token is shared prefix.
- **vocabulary**: the distinct tokens. Same shape, no repetition, an order of
  magnitude fewer keys.
- **lines**: the non-blank lines. Long keys that diverge almost immediately.
- **phrases**: every run of six consecutive words. Long keys again, but now
  with real repetition in the first word or two before they diverge.

The shape of each is printed alongside its timing, so a run against a
different book is still interpretable. Times are nanoseconds per key.
"""

from benchmarks.format import fixed, ljust, rjust
from benchmarks.harness import measure
from corpora import load_large_text
from mm_radix_sort import radix_sort
from std.benchmark import keep

comptime _PHRASE_WORDS = 6
comptime _MAX_KEYS = 600_000
"""A cap, so a much larger book does not turn one benchmark into the whole
afternoon."""


def tokens_of(text: String) -> List[String]:
    """Splits `text` on whitespace, keeping every occurrence."""
    var out = List[String]()
    for piece in text.replace("\n", " ").replace("\t", " ").split(" "):
        if piece.byte_length() > 0:
            out.append(String(piece))
            if len(out) == _MAX_KEYS:
                break
    return out^


def lines_of(text: String) -> List[String]:
    """Returns the non-blank lines of `text`."""
    var out = List[String]()
    for piece in text.split("\n"):
        if piece.byte_length() > 0:
            out.append(String(piece))
            if len(out) == _MAX_KEYS:
                break
    return out^


def phrases_of(words: List[String]) -> List[String]:
    """Returns every run of `_PHRASE_WORDS` consecutive words."""
    var out = List[String]()
    var limit = len(words) - _PHRASE_WORDS
    for i in range(0, limit if limit < _MAX_KEYS else _MAX_KEYS):
        var phrase = words[i].copy()
        for j in range(1, _PHRASE_WORDS):
            phrase += " "
            phrase += words[i + j]
        out.append(phrase^)
    return out^


def distinct(var words: List[String]) -> List[String]:
    """Returns the distinct entries of `words`, in a shuffled order.

    Deduplicating means sorting, and handing a sorted list to a sort benchmark
    measures the early-exit path rather than the sort -- both contenders here
    detect ordered input. So the result is shuffled back up before it is
    returned, deterministically, so runs stay comparable.
    """
    sort(words)
    var out = List[String]()
    for i in range(len(words)):
        if i == 0 or words[i] != words[i - 1]:
            out.append(words[i].copy())

    # Fisher-Yates with a fixed multiplicative-congruential source, so the
    # permutation is the same on every run and on every platform.
    var state = UInt64(0x2545F4914F6CDD1D)
    for i in range(len(out) - 1, 0, -1):
        state = state * 6364136223846793005 + 1442695040888963407
        var j = Int((state >> 33) % UInt64(i + 1))
        out.swap_elements(i, j)
    return out^


def shape(var words: List[String]) -> Tuple[Float64, Float64]:
    """Returns the mean key length and mean shared prefix, in bytes.

    Args:
        words: The corpus. Sorted in place to measure the prefix.

    Returns:
        `(mean length, mean shared prefix with the preceding key)`.
    """
    var total_length = 0
    for i in range(len(words)):
        total_length += words[i].byte_length()
    sort(words)
    var total_shared = 0
    for i in range(1, len(words)):
        var a = words[i - 1]
        var b = words[i]
        var limit = min(a.byte_length(), b.byte_length())
        var shared = 0
        while (
            shared < limit
            and a.unsafe_ptr()[unsafe_offset=shared]
            == b.unsafe_ptr()[unsafe_offset=shared]
        ):
            shared += 1
        total_shared += shared
    var n = Float64(len(words))
    return (
        Float64(total_length) / n,
        Float64(total_shared) / (n - 1.0 if n > 1.0 else 1.0),
    )


def compare(label: String, words: List[String]) raises:
    """Times `sort` against `radix_sort` on `words` and prints a row."""
    var mean_length: Float64
    var mean_prefix: Float64
    mean_length, mean_prefix = shape(words.copy())

    # Not part of the measurement: the closures below discard their copies, so
    # without this the benchmark would happily time a sort that came out wrong.
    var check = words.copy()
    var check_span = Span(check)
    radix_sort(check_span)
    var expected = words.copy()
    sort(expected)
    for i in range(len(check)):
        if check[i] != expected[i]:
            raise Error(label, ": radix_sort disagreed with sort at ", i)

    def floor() raises {imm words}:
        var copy = words.copy()
        keep(len(copy))

    def stdlib() raises {imm words}:
        var copy = words.copy()
        sort(copy)
        keep(len(copy))

    def radix() raises {imm words}:
        var copy = words.copy()
        var span = Span(copy)
        radix_sort(span)
        keep(len(copy))

    var n = Float64(len(words))
    var overhead = measure(floor)
    var baseline = measure(stdlib)
    var ours = measure(radix)

    print(
        ljust(label, 12),
        rjust(String(len(words)), 8),
        rjust(fixed(mean_length, 1), 7),
        rjust(fixed(mean_prefix, 1), 7),
        rjust(fixed(mean_prefix / mean_length * 100.0, 0), 7),
        rjust(fixed(overhead / n), 7),
        rjust(fixed(baseline / n), 8),
        rjust(fixed(ours / n), 11),
        rjust(String(fixed((baseline - overhead) / (ours - overhead)), "x"), 8),
    )


def main() raises:
    var text = load_large_text()
    print(
        "Nanoseconds per key. `copy` is the per-iteration `List[String]` copy"
    )
    print("both sorts pay; `net` is the speedup with it taken out.\n")
    print(
        ljust("corpus", 12),
        rjust("keys", 8),
        rjust("len", 7),
        rjust("prefix", 7),
        rjust("pfx%", 7),
        rjust("copy", 7),
        rjust("sort", 8),
        rjust("radix_sort", 11),
        rjust("net", 8),
    )

    var words = tokens_of(text)
    compare("tokens", words)
    compare("vocabulary", distinct(words.copy()))
    compare("lines", lines_of(text))
    compare("phrases", phrases_of(words))
