"""Sorts real word lists, where a comparison is not a single instruction.

`corpora/` holds twelve word lists -- Latin, Greek, Hebrew, Arabic, Georgian,
Devanagari and CJK scripts, plus a list of AWS S3 action names for long ASCII
identifiers -- taken from github.com/mzaks/compact-dict.

Two things about this benchmark are worth knowing before reading it.

The word lists are *small*, a few hundred entries each. That is below the size
at which any radix sort has an advantage, so the first table is close to a tie
throughout, and where it is not, it mostly reflects how much of the work fell
to the insertion-sort cutoff.

The second table was written expecting a shared prefix to favour the radix
sort -- a comparison sort re-reads the prefix at every level of its recursion,
where a radix sort reads each byte position once for the whole range. The
measurement says otherwise, and the reason is on the radix side: this sort
advances one byte per level, so a 59-byte shared prefix costs 59 full
histogram passes over the range before the keys even start to differ, each of
them finding a single occupied bucket. The comparison sort walks that same
prefix with a word-at-a-time memcmp. At scale and without a long shared
prefix the radix sort wins by 1.6-1.8x; add the prefix and it loses. See
`docs/improvements.md`.

Times are nanoseconds per word. Lower is better.
"""

from benchmarks.format import fixed, ljust, rjust
from benchmarks.harness import measure
from corpora import load, names
from mm_radix_sort import radix_sort
from std.benchmark import keep


def shared_prefix_bytes(var words: List[String]) -> Float64:
    """Returns the mean shared prefix length between adjacent sorted words.

    Args:
        words: The corpus, which is sorted in place to measure this.

    Returns:
        Mean bytes two neighbouring words agree on.
    """
    sort(words)
    if len(words) < 2:
        return 0.0
    var total = 0
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
        total += shared
    return Float64(total) / Float64(len(words) - 1)


def _scaled_keys(
    base: List[String], count: Int, prefix: String
) -> List[String]:
    """Builds `count` path-like keys from `base`, all sharing `prefix`."""
    var keys = List[String]()
    for i in range(count):
        keys.append(String(prefix, base[i % len(base)], "/", i))
    return keys^


def _compare(label: String, words: List[String], prefix: Float64) raises:
    var count = Float64(len(words))

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

    # Each iteration has to start from unsorted input, and the only way to get
    # that is to copy the list -- which for `List[String]` is not free. It is
    # the same copy for both contenders, so it is reported rather than
    # subtracted; the speedup column is against the totals, and so understates
    # the difference between the sorts themselves.
    # Not part of the measurement: the closures above discard their copies,
    # so without this the benchmark would happily report timings for a sort
    # that returned the wrong answer.
    var check = words.copy()
    var check_span = Span(check)
    radix_sort(check_span)
    var expected = words.copy()
    sort(expected)
    for i in range(len(check)):
        if check[i] != expected[i]:
            raise Error(label, ": radix_sort disagreed with sort at ", i)

    var overhead = measure(floor)
    var baseline = measure(stdlib)
    var ours = measure(radix)

    print(
        ljust(label, 14),
        rjust(String(len(words)), 8),
        rjust(fixed(prefix, 1), 8),
        rjust(fixed(overhead / count), 8),
        rjust(fixed(baseline / count), 9),
        rjust(fixed(ours / count), 11),
        rjust(String(fixed(baseline / ours), "x"), 9),
        rjust(String(fixed((baseline - overhead) / (ours - overhead)), "x"), 9),
    )


def _header():
    print()
    print(
        ljust("corpus", 14),
        rjust("words", 8),
        rjust("prefix", 8),
        rjust("copy", 8),
        rjust("sort", 9),
        rjust("radix_sort", 11),
        rjust("total", 9),
        rjust("net", 9),
    )


def main() raises:
    print("Nanoseconds per word. Lower is better.")
    print("`copy` is the per-iteration `List[String]` copy both sorts pay.")
    print("`total` compares the timed regions; `net` takes the copy out.")

    print()
    print("Twelve real word lists -- a few hundred words each:")
    _header()
    for name in names():
        var words = load(name)
        var prefix = shared_prefix_bytes(words.copy())
        _compare(name, words, prefix)

    print()
    print("The same words built into path-like keys, at scale. The prefix")
    print("column is what the keys share; this sort spends one full pass")
    print("over the range per shared byte, so it loses the long-prefix rows.")
    _header()
    var english = load("english")
    comptime prefixes = [
        StaticString(""),
        "arn:aws:s3:::",
        "arn:aws:s3:::my-organisation-production-artifacts/releases/",
    ]
    comptime for p in range(len(prefixes)):
        comptime prefix = prefixes[p]
        for count in [10000, 100000]:
            var keys = _scaled_keys(english, count, String(prefix))
            var shared = shared_prefix_bytes(keys.copy())
            _compare(
                String(String(prefix).byte_length(), "-byte prefix"),
                keys,
                shared,
            )
