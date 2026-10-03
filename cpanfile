# The Perl modules TurboPerl needs beyond those core since perl 5.8.8.
#
#   cpanm --installdeps .               what the IDE needs to run
#   cpanm --installdeps --with-develop . and to build it on Windows

# The integrated debugger drives Devel::ebug, and its bridge
# (lib/TurboPerl/Debug/Bridge.pm) talks JSON: Cpanel::JSON::XS if it is
# there, otherwise JSON::PP, which is core only since 5.14.
requires 'Devel::ebug';
requires 'JSON::PP';
# Much faster, and the bridge takes it over JSON::PP when it is there.
suggests 'Cpanel::JSON::XS';

# Tools / Tidy and Critique, if perltidy and perlcritic are on the PATH.
suggests 'Perl::Tidy';
suggests 'Perl::Critic';

on develop => sub {
  # perl build.pl zip, on Windows; core only since 5.10.
  requires 'IO::Compress::Zip';
};
