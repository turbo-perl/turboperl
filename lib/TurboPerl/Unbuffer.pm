package TurboPerl::Unbuffer;

# Loaded through PERL5OPT by the TurboPerl IDE when "unbuffer script output"
# is switched on.
#
# When a script's output is a pipe rather than a terminal, perl makes STDOUT
# block buffered while STDERR stays unbuffered.  Everything the script prints
# then arrives after everything it warns about, which makes the run window
# useless for following what a script actually did.  Turning on autoflush for
# both handles restores the original order.

use strict;
use warnings;

BEGIN {
    my $old = select(STDERR); $| = 1;
             select(STDOUT);  $| = 1;
    select($old) if defined $old && $old ne \*STDOUT;
}

1;
