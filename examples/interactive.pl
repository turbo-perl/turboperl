#!/usr/bin/perl
use strict;
use warnings;

# Reads from the keyboard, so run it with Run / Run on console
# (or set Options / Perl / When running to "Run on the console").

print "What is your name? ";
my $name = <STDIN>;
$name = defined($name) ? $name : '';
chomp $name;
print "Hello, ", ($name || 'nobody'), "!\n";

print "Type a number: ";
my $n = <STDIN>;
$n = defined($n) ? $n : 0;
chomp $n;
printf "Twice that is %d\n", 2 * ($n || 0);
