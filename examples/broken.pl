#!/usr/bin/perl
#
# Deliberately broken: press F9 and the error turns up in the message
# window at the bottom.  Press Enter on it to land on the offending line.

use strict;
use warnings;

my $count = 0;

sub tally {
    my @items = @_;
    foreach my $it (@items) {
        $count += $it;
    }
    return $undeclared_total;
}

print tally(1, 2, 3), "\n";
