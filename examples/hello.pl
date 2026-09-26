#!/usr/bin/perl
use strict;
use warnings;

# A small script to try the IDE out on.
#   Ctrl-F9 runs it, F9 checks its syntax.

my @greetings = qw(Hello Salut Hallo Ciao);
my %where = (
    Hello => 'English',
    Salut => 'French',
    Hallo => 'German',
    Ciao  => 'Italian',
);

for my $g (@greetings) {
    printf "%-6s is %s\n", $g, $where{$g} // 'a mystery';
}

my $text = "the quick brown fox";
(my $shout = $text) =~ tr/a-z/A-Z/;
print "$shout\n";

print <<"END";
Ran under perl $].
END
