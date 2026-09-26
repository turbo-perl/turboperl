#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(floor ceil);
use Data::Dumper;

package My::Thing;

our $VERSION = '1.02';
my $count = 0;
my @items = qw(alpha beta gamma);
my %map   = (one => 1, two => 2, s => 3, y => 4, q => 5);

sub new {
    my ($class, %args) = @_;
    my $self = { name => $args{name} // 'anon', n => 0 };
    return bless $self, $class;
}

sub y { my $self = shift; return $self->{y} }

sub process {
    my ($self, $text) = @_;
    my @parts = split /,\s*/, $text;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s{ (\d+) }{ $1 * 2 }gex;
    (my $copy = $text) =~ tr/a-z/A-Z/;
    my $re = qr/^(?<key>\w+)=(?<val>.*)$/;
    if ($text =~ $re) { print "key=$+{key}\n" }
    my $n = 10;
    my $half = $n / 2;
    my $shift = 1 << 4;
    my $mod = $n % 3;
    my $and = $n & 1;
    return @parts;
}

sub report {
    my $self = shift;
    my $name = $self->{name};
    print <<"HEADER";
Report for $name
  total: @{[ scalar @items ]}
HEADER
    print <<'RAW';
No $interpolation here at all.
RAW
    print <<~INDENTED;
        this one is indented
        and ends indented
        INDENTED
    my ($a, $b) = (<<ONE, <<TWO);
first heredoc
ONE
second heredoc
TWO
    return;
}

my $path  = 'C:\temp\nothing';
my $msg   = "line1\nline2\ttabbed $count items";
my $cmd   = `ls -l`;
my $qw    = q{braced 'single' quoted};
my $qq    = qq{braced "double" with $count and ${\ 'expr' }};
my $nest  = q(outer (inner) outer);
my $num   = 0xDEAD_BEEF;
my $bin   = 0b1010_1010;
my $flt   = 3.14159e-10;
my $big   = 1_000_000;

print "done\n" if $count > 0;
print $count / 2, "\n";

=pod

=head1 NAME

This is POD and should be uniformly coloured, even { braces } and "quotes".

=cut

print "after pod\n";

__END__
Everything down here is the data section.
Even "this" and $that and =head1.
