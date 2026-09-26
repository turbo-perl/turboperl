#!/usr/bin/perl
#
# Badly laid out on purpose: Tools / Tidy runs it through perltidy
# and replaces the buffer, as a single undo step.
use strict;use warnings;
my %h=(a=>1,b=>2,c=>3);
foreach my $k (sort keys %h){
if($h{$k}>1){print "$k is big\n";}
else{print "$k is small\n"}
}
