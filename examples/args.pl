#!/usr/bin/perl
use strict;
use warnings;

print "argv: @ARGV\n";
warn "a warning between the prints\n";
print "cwd:  ", `pwd`;
print "done\n";
