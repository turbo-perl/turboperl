#!/usr/bin/perl
# TurboPerl - Windows build script.
#
#   perl build.pl              build the IDE
#   perl build.pl test         build and run the headless unit tests
#   perl build.pl install      install under --prefix
#   perl build.pl uninstall    remove what install put there
#   perl build.pl clean        remove build products
#
# Windows has no make we can count on: nmake comes with Visual C, GNU make
# with Strawberry Perl, and the one FPC ships only works with FPC's bin
# directory on the PATH, which we advise against (it carries gcc, ld, rm and
# friends that get in the way of building XS modules).  Perl is the one tool
# every TurboPerl user already has, so the build is written in it, using
# only core modules.  Unix builds use the Makefile.

use strict;
use warnings;
use Getopt::Long qw( GetOptions );
use File::Basename qw( basename );
use File::Copy qw( copy );
use File::Path qw( mkpath rmtree );
use File::Spec;
use File::Temp qw( tempdir );

die "build.pl is for Windows; use make everywhere else\n"
  unless $^O eq 'MSWin32';

my %opt = (
  cpu    => 'x86_64',
  prefix => File::Spec->catdir(
    $ENV{LOCALAPPDATA} || File::Spec->catdir($ENV{USERPROFILE}, 'AppData', 'Local'),
    'Programs', 'turboperl'),
);
GetOptions(\%opt, 'fpc=s', 'cpu=s', 'prefix=s', 'help') or usage(2);
usage(0) if $opt{help};

my $target  = 'turboperl.exe';
my $unitdir = 'units';
my @tests   = map { File::Spec->catfile('tests', "$_.exe") }
              qw( hltest texttest perltest cfgtest dbgtest );

my %action = (
  all       => \&build,
  test      => \&test,
  install   => \&install,
  uninstall => \&uninstall,
  clean     => \&clean,
);
my @todo = @ARGV ? @ARGV : ('all');
for (@todo) { usage(2) unless $action{$_} }
$action{$_}->() for @todo;

sub usage {
  print "usage: perl build.pl [--fpc PATH] [--cpu x86_64|i386] [--prefix DIR]\n",
        "                     [all|test|install|uninstall|clean]...\n";
  exit shift;
}

# The compiler: --fpc, then $FPC, then the PATH, then the newest of the
# installer's usual C:\FPC\<version> directories.
my $fpc_found;
sub fpc {
  return $fpc_found if $fpc_found;
  my $fpc = $opt{fpc} || $ENV{FPC};
  unless ($fpc) {
    for my $dir (File::Spec->path) {
      my $f = File::Spec->catfile($dir, 'fpc.exe');
      if (-x $f) { $fpc = $f; last }
    }
  }
  unless ($fpc) {
    my @found = sort { vcmp($b, $a) } glob 'C:/FPC/*/bin/i386-win32/fpc.exe';
    $fpc = $found[0];
  }
  die "cannot find Free Pascal; install it or pass --fpc C:\\FPC\\<version>\\bin\\i386-win32\\fpc.exe\n"
    unless $fpc && -x $fpc;
  $fpc_found = $fpc;
}

# Compare the version directories of two C:\FPC paths numerically.
sub vcmp {
  my @a = $_[0] =~ m{/FPC/([\d.]+)/} ? split /\./, $1 : ();
  my @b = $_[1] =~ m{/FPC/([\d.]+)/} ? split /\./, $1 : ();
  while (@a || @b) {
    my $c = (shift(@a) || 0) <=> (shift(@b) || 0);
    return $c if $c;
  }
  0;
}

# Free Vision needs no -Fu here: the installer's fpc.cfg already searches
# units\<target>\*, which takes in units\<target>\fv.
sub compile {
  my ($out, $src) = @_;
  mkpath($unitdir) unless -d $unitdir;
  my @cmd = (fpc(), "-P$opt{cpu}", qw( -Sg -Mobjfpc -O2 -Xs -vw -Fusrc -Fisrc ),
             "-FU$unitdir", "-o$out", $src);
  print "@cmd\n";
  system(@cmd) == 0 or die "compile of $src failed\n";
}

sub build { compile($target, 'turboperl.pas') }

sub run {
  my @cmd = @_;
  system(@cmd) == 0 or die "$cmd[0] failed\n";
}

sub test {
  for my $t (@tests) {
    (my $src = $t) =~ s/\.exe$/.pas/;
    compile($t, $src);
  }
  print "== block operations ==\n";
  run(File::Spec->catfile('tests', 'texttest.exe'));

  print "\n== settings round trip ==\n";
  {
    my $d = tempdir(CLEANUP => 1);
    local $ENV{TPTESTHOME} = $d;
    local $ENV{HOME}       = $d;
    run(File::Spec->catfile('tests', 'cfgtest.exe'));
  }

  print "\n== perl process layer ==\n";
  run(File::Spec->catfile('tests', 'perltest.exe'));

  print "\n== debugger session ==\n";
  run(File::Spec->catfile('tests', 'dbgtest.exe'));

  print "\n== highlighter on the torture file ==\n";
  my $hl = File::Spec->catfile('tests', 'hltest.exe');
  my @out = `"$hl" -s tests/torture.pl`;
  die "$hl failed\n" if $?;
  my $state = (split /\|/, $out[-1] // '')[1] // '';
  $state =~ s/\s+//g;
  print "final scanner state: $state\n";

  # run-tests.sh drives the interface through tmux, which Windows lacks.
  print "\n(skipping the scripted interface tests: they need tmux)\n";
}

# The layout DetectLibDir looks for beside the binary:
#   <prefix>\turboperl.exe
#   <prefix>\lib\TurboPerl\...
#   <prefix>\examples\...
sub install {
  build() unless -f $target;
  my $p = $opt{prefix};
  for my $d ('', 'lib/TurboPerl/Debug', 'examples') {
    my $dir = File::Spec->catdir($p, split m{/}, $d);
    mkpath($dir) unless -d $dir;
  }
  inst($target, $p);
  inst('lib/TurboPerl/Unbuffer.pm',     File::Spec->catdir($p, 'lib', 'TurboPerl'));
  inst('lib/TurboPerl/Debug/Bridge.pm', File::Spec->catdir($p, 'lib', 'TurboPerl', 'Debug'));
  inst($_, File::Spec->catdir($p, 'examples')) for grep { -f } glob 'examples/*';
  print "installed under $p; add it to your PATH to run turboperl from anywhere\n";
}

sub inst {
  my ($file, $dir) = @_;
  my $to = File::Spec->catfile($dir, basename($file));
  print "copy $file $to\n";
  copy($file, $to) or die "cannot copy $file to $to: $!\n";
}

sub uninstall {
  my $p = $opt{prefix};
  unlink File::Spec->catfile($p, $target);
  rmtree(File::Spec->catdir($p, $_)) for qw( lib examples );
  rmdir $p;
}

sub clean {
  rmtree($unitdir);
  unlink $target, @tests, glob('src/*.o'), glob('src/*.ppu'),
         glob('tests/*.o'), glob('tests/*.ppu');
}
