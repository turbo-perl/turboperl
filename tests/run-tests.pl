#!/usr/bin/perl
# Interface tests for TurboPerl on Windows.
#
# The Windows counterpart of run-tests.sh: the IDE is driven through
# VisionDrive (https://github.com/turbo-perl/VisionDrive), which runs it in
# a console of its own and types into it, the way run-tests.sh uses tmux.
# The cases are run-tests.sh's, less the ones about Unix terminals.
#
#   perl tests/run-tests.pl          run them all
#   perl tests/run-tests.pl -v       also print each captured screen
#
# VisionDrive is looked for in %VISIONDRIVE%, then on the PATH, then in a
# VisionDrive checkout beside this one.  Without it the tests are skipped.

use strict;
use warnings;
use File::Basename qw( dirname );
use File::Copy qw( copy );
use File::Path qw( mkpath );
use File::Spec;
use File::Temp qw( tempdir );
use Time::HiRes qw( sleep time );

my $verbose = @ARGV && $ARGV[0] eq '-v';
my $top     = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $ide     = File::Spec->catfile($top, 'turboperl.exe');
my ($pass, $fail) = (0, 0);

die "run-tests.pl: $ide is not built; run perl build.pl first\n" unless -x $ide;

my $vd = find_visiondrive();
unless ($vd) {
  print STDERR "run-tests.pl: VisionDrive is needed for the interface tests; skipping\n";
  exit 0;
}

sub find_visiondrive {
  return $ENV{VISIONDRIVE} if $ENV{VISIONDRIVE} && -x $ENV{VISIONDRIVE};
  for my $dir (File::Spec->path) {
    my $f = File::Spec->catfile($dir, 'visiondrive.exe');
    return $f if -x $f;
  }
  my $beside = File::Spec->catfile($top, '..', 'VisionDrive', 'visiondrive.exe');
  return -x $beside ? $beside : undef;
}

# ------------------------------------------------------------------ driving

my $session;

# start the IDE on the given files, COLS by ROWS
sub start {
  my ($cols, $rows, @files) = @_;
  stop();
  my $out = `"$vd" start --cols $cols --rows $rows -- "$ide" @{[ map { qq{"$_"} } @files ]}`;
  ($session) = $out =~ /(\d+)/;
  die "run-tests.pl: VisionDrive could not start the IDE\n" unless $session;
  waitfor('F9 Check');
}

sub stop {
  return unless $session;
  system($vd, 'stop', $session);
  undef $session;
  sleep 0.3;
}

sub press {
  system($vd, 'keys', $session, @_) == 0
    or die "run-tests.pl: VisionDrive could not type @_\n";
}

# wait until TEXT is on the screen; false if it never came
sub waitfor {
  my ($text, $ms) = @_;
  system($vd, 'wait', $session, $text, '--timeout', $ms || 10000) == 0;
}

sub gone {
  my ($text, $ms) = @_;
  system($vd, 'wait', $session, $text, '--gone', '--timeout', $ms || 10000) == 0;
}

# wait until TEST, given the screen, is true; for what wait cannot say.  With
# COLOUR the screen comes with its colours, as from screen_colour.
sub poll {
  my ($test, $ms, $colour) = @_;
  my $until = time + ($ms || 10000) / 1000;
  my $e = $colour ? ' -e' : '';
  while (time < $until) {
    return 1 if $test->(scalar `"$vd" screen $session$e`);
    sleep 0.1;
  }
  0;
}

# wait until the debugger marks the line holding TEXT as the one it is on
sub stopped_at {
  my ($text) = @_;
  poll(sub { $_[0] =~ /\e\[30m\e\[46m[^\n]*\Q$text\E/ }, 10000, 1);
}

sub screen {
  my $s = `"$vd" screen $session`;
  print map { "     > $_\n" } split /\n/, $s if $verbose;
  $s;
}

# the screen with its colours as ANSI escapes, as tmux capture-pane -e has it
sub screen_colour { scalar `"$vd" screen $session -e` }

sub alive { system($vd, 'alive', $session) == 0 }

# ----------------------------------------------------------------- checking

sub check {
  my ($name, $hay, $needle) = @_;
  if (index($hay, $needle) >= 0) {
    $pass++;
    print "ok   $name\n";
  } else {
    $fail++;
    print "FAIL $name\n       looked for: $needle\n";
    print map { "       | $_\n" } split /\n/, $hay;
  }
}

sub check_re {
  my ($name, $hay, $re) = @_;
  if ($hay =~ $re) {
    $pass++;
    print "ok   $name\n";
  } else {
    $fail++;
    print "FAIL $name\n       looked for /$re/\n";
    print map { "       | $_\n" } split /\n/, $hay;
  }
}

sub check_not {
  my ($name, $hay, $needle) = @_;
  if (index($hay, $needle) >= 0) {
    $fail++;
    print "FAIL $name (unexpectedly found \"$needle\")\n";
  } else {
    $pass++;
    print "ok   $name\n";
  }
}

sub ok {
  my ($name, $ok) = @_;
  if ($ok) { $pass++; print "ok   $name\n" }
  else     { $fail++; print "FAIL $name\n" }
}

# ----------------------------------------------------------------- fixtures

my $tmp = tempdir(CLEANUP => 1);

sub fixture {
  my ($name, $text) = @_;
  my $f = File::Spec->catfile($tmp, $name);
  open my $fh, '>', $f or die "cannot write $f: $!\n";
  print $fh $text;
  close $fh;
  $f;
}

# A home of the tests' own, so the settings file is not the user's.
my $home = File::Spec->catdir($tmp, 'home');
mkpath($home);
$ENV{HOME} = $home;

my $good = fixture('good.pl', <<'EOF');
#!/usr/bin/env perl
use strict;
use warnings;
my @xs = qw(one two three);
print "count: ", scalar(@xs), "\n";
warn "a warning\n";
print "last: $xs[-1]\n";
EOF

my $bad = fixture('bad.pl', <<'EOF');
#!/usr/bin/env perl
use strict;
use warnings;

my $ok = 1;

sub thing {
    return $never_declared;
}
EOF

my $block = fixture('block.pl', <<'EOF');
my $a = 1;
my $b = 2;
my $c = 3;
my $d = 4;
EOF

my $long = fixture('long.pl',
  'my $r = "' . join('', map { sprintf '%09d|', $_ * 10 } 1 .. 15) . "\";\n");

my $console = fixture('console.pl', <<'EOF');
$| = 1;
print "CONSOLE OUTPUT LINE\n";
EOF

my $twice = fixture('twice.pl', <<'EOF');
$| = 1;
print "MARKER-$ARGV[0]\n";
EOF

my $dbg = fixture('dbg.pl', <<'EOF');
use strict;
use warnings;
my $total = 0;
sub add {
    my ($n) = @_;
    $total += $n;
    return $total;
}
for my $i (1 .. 3) { add($i) }
print "total=$total\n";
EOF

my $deep = fixture('deep.pl', <<'EOF');
use strict;
use warnings;
my $deep = { list => [1 .. 40], name => 'x' x 200 };
print "ok\n";
EOF

print "== TurboPerl interface tests (Windows) ==\n";

# -------------------------------------------------------- 1. it comes up
start(100, 30, $good);
my $s = screen();
check('menu bar is drawn',        $s, 'File  Edit  Search  Run  Debug  Tools  Options  Window  Help');
check('status line is drawn',     $s, 'F9 Check');
check('the file is loaded',       $s, 'print "count: ", scalar(@xs)');
check('the title shows the file', $s, 'good.pl');
# The console shows an ESC it does not obey as an arrow, U+2190, which the
# screen arrives in as UTF-8.
check_not('no escape sequence is printed', $s, "\xe2\x86\x90]");

# ------------------------------------------------- syntax highlighting
my $c = screen_colour();
check('keywords are coloured',  $c, "\e[97m");
check('comments are coloured',  $c, "\e[36m");
check('strings are coloured',   $c, "\e[92m");
check('variables are coloured', $c, "\e[96m");
stop();

# --------------------------------------------------- 2. syntax check, clean
start(100, 30, $good);
press('F9');
waitfor('syntax OK');
check('clean file reports syntax OK', screen(), 'syntax OK');
press('Enter');
stop();

# -------------------------------------------------- 3. syntax check, broken
start(100, 30, $bad);
press('F9');
waitfor('bad.pl:8:');
$s = screen();
check('error is listed with its line', $s, 'bad.pl:8:');
check('error text is shown',           $s, 'Global symbol');
check('output window shows perl',      $s, 'had compilation errors');

# ---------------------------------------------------- 4. jump to the error
press('Enter');
waitfor('8:1', 3000);
check('Enter jumps to the error line', screen(), '8:1');
stop();

# ------------------------------------------------------------ 5. running
start(100, 30, $good);
press('M-r', 'r');
waitfor('exit code');
$s = screen();
check('run captures stdout',       $s, 'count: 3');
check('run captures stderr',       $s, 'a warning');
check('run captures later output', $s, 'last: three');
check('exit code is reported',     $s, 'exit code 0');
# in the output window, not the source above it, which says "a warning" too
my $output = substr($s, index($s, 'Output:'));
my @order = map { index($output, $_) } 'count: 3', 'a warning', 'last: three';
ok('stdout and stderr interleave in order',
   $order[0] >= 0 && $order[0] < $order[1] && $order[1] < $order[2]);
check_not('clean run raises no messages', $s, 'Messages - good.pl');
stop();

# ------------------------------------------------ 6. block comment round trip
start(100, 30, $block);
press('S-Down', 'S-Down', 'M-c');
waitfor('# my $a = 1;', 3000);
$s = screen();
check('block comment marks the selected lines', $s, '# my $a = 1;');
check_re('block comment stops at the selection', $s, qr/[^#]my \$c = 3;/);
press('M-u');
gone('# my $a', 3000);
$s = screen();
check_re('uncomment restores the text', $s, qr/[^#]my \$a = 1;/);
check_not('no # is left behind',       $s, '# my $a');
stop();

# ------------------------------------------------- 7. horizontal scrolling
start(80, 12, $long);
check('long line starts at column 1', screen(), 'my $r = "000000010|');
press('End');
waitfor('000000150|";', 3000);
$s = screen();
check('scrolled view shows the line end', $s, '000000150|";');
check_not('no stale text from column 1',  $s, 'my $r = "');
stop();

# ------------------------------------------------------------- 8. perldoc
start(100, 30, $good);
press('Down', 'Down', 'Down', 'Down', 'Right', 'Right', 'M-t', 'h');
waitfor('perldoc -f print');
check('perldoc looks the word up', screen(), 'perldoc -f print');
stop();

# ------------------------------- 9. running on the console, and the user screen
start(100, 30, $console);
press('M-r', 'c');
waitfor('press Enter to return to the IDE');
$s = screen();
check("console run shows the script's output", $s, 'CONSOLE OUTPUT LINE');
check('console run waits before returning',    $s, 'press Enter to return to the IDE');

# Keys that are not Enter must not dismiss that prompt.
press('x', 'Down');
sleep 1;
check('other keys do not dismiss the prompt', screen(), 'press Enter to return to the IDE');

press('Enter');
waitfor('F9 Check');
check('Enter returns to the IDE', screen(), 'File  Edit  Search  Run  Debug');

# Alt-F5 steps back to the console, where the output still is.
press('M-F5');
waitfor('user screen - press Enter to go back');
$s = screen();
check('the user screen brings the output back', $s, 'CONSOLE OUTPUT LINE');
check('its prompt sits at the bottom',          $s, 'user screen - press Enter to go back');
press('Enter');
waitfor('F9 Check');
check('Enter leaves the user screen', screen(), 'File  Edit  Search  Run  Debug');
stop();

# A second console run must carry on below the first rather than starting
# again at the top of the screen and painting over it.
start(100, 30, $twice);
press('M-r', 'c');
waitfor('press Enter to return');
press('Enter');
waitfor('F9 Check');
press('M-r', 'c');
# Not the prompt: the first run's is still on the console.
poll(sub { my $n = () = $_[0] =~ /MARKER/g; $n >= 2 });
$s = screen();
my $count = () = $s =~ /MARKER/g;
ok("a second console run appends below the first (found $count of 2)", $count >= 2);
ok('console output starts at the left margin', $s !~ /^[ \t]+--- TurboPerl/m);
press('Enter');
stop();

# ----------------------------------------------------------- 10. the debugger
start(100, 30, $dbg);
press('F7');
waitfor('3:1');
check('the debugger starts and stops before the first statement', screen(), '3:1');
# black on cyan is the current statement marker
check('the current statement is marked', screen_colour(), "\e[30m\e[46m");

# down to the '$total += $n' line, set a break point there, and go to it
press('Down', 'Down', 'Down', 'C-F8');
sleep 1;
check('a break point line turns red', screen_colour(), "\e[41m");
press('C-F9');
# Not waiting for 6:1, which the cursor already was on to set the break
# point: for the marker to move there.
stopped_at('$total += $n');
check('continue stops at the break point', screen(), '6:1');

# the debugger panes
press('M-d', 'v');
waitfor('$n = 1');
$s = screen();
check('the variables pane lists lexicals', $s, '$n = 1');
check('and the outer lexical too',         $s, '$total = 0');

press('M-d', 's');
waitfor('main::add(1)', 3000);
check('the call stack names the frame', screen(), 'main::add(1)');

press('C-F2');
gone('main::add(1)', 5000);
check_not('program reset ends the session', screen(), 'main::add(1)');
stop();

# a long value is cut to fit, and opens out a level at a time
start(100, 30, $deep);
press('F7');
waitfor('3:1');
press('Down', 'C-F8');
sleep 1;
press('C-F9');
# Not 4:1, which the cursor already was on to set the break point, nor
# $deep, which the source says too: the marker, then the pane's own line.
stopped_at('print "ok');
press('M-d', 'v');
waitfor('+ $deep = {');
check_re('a long variable is cut to one line', screen(), qr/\+ \$deep = \{list => \[1, 2, .*\.\.\./);
press('Right');
waitfor('- $deep', 3000);
$s = screen();
check('Right opens it',                   $s, '- $deep');
check('showing its elements, still shut', $s, '+ {list} = [1, 2, 3');
check('and its plain values',             $s, "{name} = 'xxx");
press('Right', 'Right');
waitfor('    [0] = 1', 3000);
check('an element opens in turn', screen(), '    [0] = 1');
press('Left', 'Left', 'Left');
# Not for {name} to go: the pane is three rows, and it has already
# scrolled out of sight with {list} open.  For the closed line.
waitfor('+ $deep = {list', 3000);
$s = screen();
check('Left goes back up and closes',    $s, '+ $deep = {list');
check_not('leaving the elements hidden', $s, '{name}');
press('C-F2');
stop();

# a bridge from another release still works, but the IDE says so
{
  my $old = File::Spec->catdir($tmp, 'oldlib');
  mkpath(File::Spec->catdir($old, 'TurboPerl', 'Debug'));
  copy(File::Spec->catfile($top, qw( lib TurboPerl Unbuffer.pm )),
       File::Spec->catfile($old, qw( TurboPerl Unbuffer.pm ))) or die "copy: $!";
  open my $in,  '<', File::Spec->catfile($top, qw( lib TurboPerl Debug Bridge.pm )) or die $!;
  open my $out, '>', File::Spec->catfile($old, qw( TurboPerl Debug Bridge.pm )) or die $!;
  while (<$in>) {
    s/^our \$VERSION = .*/our \$VERSION = '0.00';/;
    print $out $_;
  }
  close $in;
  close $out;
  open my $rc, '>', File::Spec->catfile($home, '.turboperlrc') or die $!;
  print $rc "libdir = $old\n";
  close $rc;

  start(100, 30, $dbg);
  press('F7');
  waitfor('the debugger bridge is version 0.00');
  check('a mismatched bridge raises a warning', screen(), 'the debugger bridge is version 0.00');
  press('Enter');
  gone('Warning', 3000);
  $s = screen();
  check_not('Enter dismisses it',      $s, 'Warning');
  check('and the session carries on',  $s, '3:1');
  press('C-F2');
  stop();
  unlink File::Spec->catfile($home, '.turboperlrc');
}

# ------------------------------------------------------------- 11. quitting
start(100, 30, $good);
press('M-x');
my $t0 = time;
sleep 0.2 while alive() && time - $t0 < 5;
ok('Alt-X exits', !alive());
undef $session;

print "\ninterface tests: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
