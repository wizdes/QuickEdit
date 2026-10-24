#!/bin/bash
# Writes the timing fixtures to bench/fixtures/ (ignored by Git). Same bytes every run.
#   1mb.txt, 10mb.txt, 100mb.txt   short ASCII lines, exactly 1, 10 and 100 MiB
#   long-line-10mb.txt             one 10 MiB line, no line ending
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/fixtures"
mkdir -p "$DIR"

lines() { # name bytes
    perl -e '
        my ($path, $size) = @ARGV;
        open(my $fh, ">", $path) or die "$path: $!";
        my ($n, $written) = (0, 0);
        while ($written < $size) {
            my $line = sprintf("line %08d the quick brown fox jumps over the lazy dog 0123456789\n", $n++);
            $line = substr($line, 0, $size - $written - 1) . "\n" if $written + length($line) > $size;
            print $fh $line; $written += length($line);
        }
        close($fh) or die;
    ' "$DIR/$1" "$2"
}

long_line() { # name bytes
    perl -e '
        my ($path, $size) = @ARGV;
        open(my $fh, ">", $path) or die "$path: $!";
        my $unit = "abcdefghijklmnopqrstuvwxyz0123456789 ";
        my $block = $unit x 1000;
        my $written = 0;
        while ($written < $size) {
            my $part = substr($block, 0, $size - $written);
            print $fh $part; $written += length($part);
        }
        close($fh) or die;
    ' "$DIR/$1" "$2"
}

lines 1mb.txt $((1024 * 1024))
lines 10mb.txt $((10 * 1024 * 1024))
lines 100mb.txt $((100 * 1024 * 1024))
long_line long-line-10mb.txt $((10 * 1024 * 1024))
for f in 1mb.txt 10mb.txt 100mb.txt long-line-10mb.txt; do
    echo "$f $(stat -f %z "$DIR/$f") bytes $(wc -l < "$DIR/$f" | tr -d ' ') lines $(shasum -a 256 "$DIR/$f" | cut -c1-16)"
done
