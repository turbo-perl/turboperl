#!/usr/bin/env perl
use strict;
use warnings;

my @primes = (2, 3, 5, 7);
my %ages   = (alice => 31, bob => 27);
my $point  = { x => 1, y => [2, 3] };
my $pet    = bless { name => 'Rex' }, 'Dog';

print scalar(@primes), " primes, ", scalar(keys %ages), " people\n";
