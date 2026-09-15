#!/usr/bin/env bash
# Fetches the text the large-string benchmark runs on: Tolstoy's War and Peace
# in the Maude translation, Project Gutenberg ebook 2600, public domain.
#
#   bash corpora/large/setup.sh              # download it
#   bash corpora/large/setup.sh path/to.txt  # or use a copy you already have
#
# One plain text file goes in; `benchmarks/bench_large_strings.mojo` derives
# every corpus from it in Mojo, so the derivations are visible and nothing but
# the book needs storing. Nothing here is committed.
set -eu
cd "$(dirname "$0")"
target=war-and-peace.txt

if [ $# -ge 1 ]; then
  cp "$1" "$target"
  echo "copied $1 -> corpora/large/$target"
else
  url=https://www.gutenberg.org/cache/epub/2600/pg2600.txt
  echo "downloading $url"
  curl -fsSL "$url" -o "$target.tmp"
  # Drop the Project Gutenberg header and footer, keeping only the book.
  awk '/^\*\*\* START OF/{p=1;next} /^\*\*\* END OF/{p=0} p' "$target.tmp" > "$target"
  [ -s "$target" ] || mv "$target.tmp" "$target"
  rm -f "$target.tmp"
  echo "wrote corpora/large/$target"
fi
wc -lc < "$target" | awk '{printf "  %s lines, %s bytes\n", $1, $2}'
