#!/usr/bin/perl
# TurboPerl - Windows build script.
#
#   perl build.pl              build the IDE
#   perl build.pl test         build and run the headless unit tests
#   perl build.pl install      install under --prefix
#   perl build.pl uninstall    remove what install put there
#   perl build.pl zip          packages\turboperl-<version>-win64.zip
#   perl build.pl installer    packages\turboperl-<version>-setup.exe
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
  zip       => \&zip,
  installer => \&installer,
  clean     => \&clean,
);
my @todo = @ARGV ? @ARGV : ('all');
for (@todo) { usage(2) unless $action{$_} }
$action{$_}->() for @todo;

sub usage {
  print "usage: perl build.pl [--fpc PATH] [--cpu x86_64|i386] [--prefix DIR]\n",
        "                     [all|test|install|uninstall|zip|installer|clean]...\n";
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

  # run-tests.sh drives the interface through tmux; on Windows
  # tests/run-tests.pl does the same through VisionDrive.  Built every
  # time, as make would when the sources change: FPC recompiles only what
  # has, and an IDE left over from before is not the one to test.
  build();
  print "\n";
  run($^X, File::Spec->catfile('tests', 'run-tests.pl'));
}

# The layout DetectLibDir looks for beside the binary:
#   <prefix>\turboperl.exe
#   <prefix>\lib\TurboPerl\...
#   <prefix>\examples\...
sub install {
  build();
  stage($opt{prefix});
  print "installed under $opt{prefix}; add it to your PATH to run turboperl from anywhere\n";
}

# Lay the IDE out in Dir, as DetectLibDir looks for it beside the binary.
sub stage {
  my ($p) = @_;
  for my $d ('', 'lib/TurboPerl/Debug', 'examples') {
    my $dir = File::Spec->catdir($p, split m{/}, $d);
    mkpath($dir) unless -d $dir;
  }
  inst($target, $p);
  inst('lib/TurboPerl/Unbuffer.pm',     File::Spec->catdir($p, 'lib', 'TurboPerl'));
  inst('lib/TurboPerl/Debug/Bridge.pm', File::Spec->catdir($p, 'lib', 'TurboPerl', 'Debug'));
  inst($_, File::Spec->catdir($p, 'examples')) for grep { -f } glob 'examples/*';
}

# The version is the IDE's own, as for the Debian package, so the zip can
# never disagree with what turboperl --version says.
sub version {
  open my $fh, '<', 'src/tpconst.pas' or die "cannot read src/tpconst.pas: $!\n";
  while (<$fh>) {
    return $1 if /^\s*TPVersion\s*=\s*'([^']*)'/;
  }
  die "no TPVersion in src/tpconst.pas\n";
}

# The install layout, with the README and licence, in a folder of its own
# inside the zip: unzipped anywhere, it runs from there.
sub zip {
  require IO::Compress::Zip;
  require File::Find;
  build();
  my $arch  = $opt{cpu} eq 'i386' ? 'win32' : 'win64';
  my $name  = 'turboperl-' . version() . "-$arch";
  my $stage = File::Spec->catdir('packages', $name);
  my $zip   = "$stage.zip";
  rmtree($stage);
  unlink $zip;
  stage($stage);
  inst($_, $stage) for 'README.md', 'LICENSE';
  my @files;
  File::Find::find(sub { push @files, $File::Find::name if -f }, $stage);
  IO::Compress::Zip::zip([ sort @files ] => $zip,
    FilterName => sub { s{\\}{/}g; s{^packages/}{} })
    or die "cannot write $zip: $IO::Compress::Zip::ZipError\n";
  rmtree($stage);
  print "wrote $zip\n";
}

# Inno Setup's compiler: $ISCC, the PATH, then where its installer puts it,
# for everyone or (as winget does) for the user alone.
sub iscc {
  return $ENV{ISCC} if $ENV{ISCC} && -x $ENV{ISCC};
  for my $dir (File::Spec->path) {
    my $f = File::Spec->catfile($dir, 'ISCC.exe');
    return $f if -x $f;
  }
  require File::Glob;
  for my $base (grep { defined } @ENV{qw( ProgramFiles(x86) ProgramFiles LOCALAPPDATA )}) {
    # bsd_glob, since glob would split "Inno Setup*" at the space
    my @found = File::Glob::bsd_glob(File::Spec->catfile($base,
      $base eq ($ENV{LOCALAPPDATA} // '') ? 'Programs' : (), 'Inno Setup*', 'ISCC.exe'));
    return $found[-1] if @found && -x $found[-1];
  }
  die "cannot find Inno Setup's ISCC.exe; install it (winget install JRSoftware.InnoSetup) or set ISCC\n";
}

# packages\turboperl-<version>-setup.exe, from turboperl.iss: the zip's
# files, installed for the user alone or for everyone, with a Start menu
# entry and, if asked, the PATH.
sub installer {
  build();
  my $iscc  = iscc();
  my $stage = File::Spec->rel2abs(File::Spec->catdir('packages', 'setup-stage'));
  rmtree($stage);
  stage($stage);
  inst($_, $stage) for 'README.md', 'LICENSE';
  my @cmd = ($iscc, '/Q', '/DAppVersion=' . version(), "/DStage=$stage", 'turboperl.iss');
  print "@cmd\n";
  my $ok = system(@cmd) == 0;
  rmtree($stage);
  die "Inno Setup failed\n" unless $ok;
  print 'wrote ', File::Spec->catfile('packages', 'turboperl-' . version() . '-setup.exe'), "\n";
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
  rmtree('packages');
  unlink $target, @tests, glob('src/*.o'), glob('src/*.ppu'),
         glob('tests/*.o'), glob('tests/*.ppu');
}
