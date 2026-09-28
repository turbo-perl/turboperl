#!/usr/bin/env perl
use strict;
use warnings;

my $total = 0;

sub add {
    my ($n) = @_;
    $total += $n;
    return $total;
}

for my $i (1 .. 3) {
    add($i);
    print "after $i: $total\n";
}

print "done: $total\n";
