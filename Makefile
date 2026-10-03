# TurboPerl - build rules.
#
#   make            build the IDE
#   make test       build and run the headless unit tests
#   make install    install under $(PREFIX), default /usr/local
#   make deb        build a Debian package that installs under /usr
#   make clean      remove build products

FPC       ?= fpc
PREFIX    ?= /usr/local
FVUNITS   ?= $(shell $(FPC) -iV >/dev/null 2>&1 && \
               d=$$(dirname $$(realpath $$($(FPC) -PB))) && \
               echo $$d/units/$$($(FPC) -iTP)-$$($(FPC) -iTO)/fv)

SRCDIR    := src
UNITDIR   := units
BINDIR    := .
TESTDIR   := tests

FPCFLAGS  := -Sg -Mobjfpc -O2 -Xs -vw -Fu$(SRCDIR) -Fu$(FVUNITS) -Fi$(SRCDIR) -FU$(UNITDIR)

TARGET    := turboperl
TESTS     := $(TESTDIR)/hltest $(TESTDIR)/texttest $(TESTDIR)/perltest \
             $(TESTDIR)/cfgtest $(TESTDIR)/dbgtest

SOURCES   := $(wildcard $(SRCDIR)/*.pas) $(SRCDIR)/perlwords.inc turboperl.pas

.PHONY: all test clean install uninstall check corpus deb

all: $(TARGET)

$(UNITDIR):
	@mkdir -p $(UNITDIR)

$(TARGET): $(SOURCES) | $(UNITDIR)
	$(FPC) $(FPCFLAGS) -o$(TARGET) turboperl.pas

$(TESTDIR)/%: $(TESTDIR)/%.pas $(SOURCES) | $(UNITDIR)
	$(FPC) $(FPCFLAGS) -o$@ $<

test: $(TESTS)
	@echo "== block operations =="; $(TESTDIR)/texttest
	@echo; echo "== settings round trip =="; \
	  d=$$(mktemp -d) && TPTESTHOME=$$d HOME=$$d $(TESTDIR)/cfgtest; \
	  rc=$$?; rm -rf $$d; exit $$rc
	@echo; echo "== perl process layer =="; $(TESTDIR)/perltest
	@echo; echo "== debugger session =="; $(TESTDIR)/dbgtest
	@echo; echo "== highlighter on the torture file =="; \
	  $(TESTDIR)/hltest -s $(TESTDIR)/torture.pl | \
	  awk -F'|' '{gsub(/ /,"",$$2)} END{print "final scanner state: " $$2}'
	@echo; ./run-tests.sh

# Slower: runs the highlighter over every Perl file it can find and checks
# that none of them leaves the scanner stuck inside a quote or here-document.
corpus: $(TESTDIR)/hltest
	@$(TESTDIR)/corpus.sh

check: test

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/$(TARGET)
	install -d $(DESTDIR)$(PREFIX)/share/turboperl/lib/TurboPerl
	install -m 644 lib/TurboPerl/Unbuffer.pm \
	  $(DESTDIR)$(PREFIX)/share/turboperl/lib/TurboPerl/Unbuffer.pm
	install -d $(DESTDIR)$(PREFIX)/share/turboperl/lib/TurboPerl/Debug
	install -m 644 lib/TurboPerl/Debug/Bridge.pm \
	  $(DESTDIR)$(PREFIX)/share/turboperl/lib/TurboPerl/Debug/Bridge.pm
	install -d $(DESTDIR)$(PREFIX)/share/turboperl/examples
	install -m 644 examples/* $(DESTDIR)$(PREFIX)/share/turboperl/examples/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(TARGET)
	rm -rf $(DESTDIR)$(PREFIX)/share/turboperl

# The version is the IDE's own, so the package can never disagree with what
# turboperl --version says.  The binary is linked statically and needs only
# perl to be useful; the debugger also wants Devel::ebug, which Debian and
# Ubuntu do not package, so it cannot be named as a dependency.
VERSION   := $(shell sed -n "s/^ *TPVersion *= *'\([^']*\)'.*/\1/p" $(SRCDIR)/tpconst.pas)
DEBARCH   := $(shell dpkg --print-architecture 2>/dev/null)
PKGDIR    := packages
DEBROOT   := $(PKGDIR)/root
DEB       := $(PKGDIR)/$(TARGET)_$(VERSION)_$(DEBARCH).deb

deb: $(DEB)

$(DEB): $(TARGET) lib/TurboPerl/Unbuffer.pm lib/TurboPerl/Debug/Bridge.pm
	rm -rf $(DEBROOT)
	mkdir -p $(PKGDIR)
	$(MAKE) install DESTDIR=$(CURDIR)/$(DEBROOT) PREFIX=/usr
	install -d $(DEBROOT)/DEBIAN $(DEBROOT)/usr/share/doc/$(TARGET)
	install -m 644 README.md $(DEBROOT)/usr/share/doc/$(TARGET)/README.md
	{ echo 'Package: $(TARGET)'; \
	  echo 'Version: $(VERSION)'; \
	  echo 'Architecture: $(DEBARCH)'; \
	  echo 'Maintainer: Graham Ollis <plicease@gmail.com>'; \
	  echo 'Installed-Size: '$$(du -sk --apparent-size $(DEBROOT)/usr | cut -f1); \
	  echo 'Depends: perl'; \
	  echo 'Recommends: perl-doc'; \
	  echo 'Suggests: perltidy, libperl-critic-perl'; \
	  echo 'Section: devel'; \
	  echo 'Priority: optional'; \
	  echo 'Homepage: https://github.com/turbo-perl/turboperl'; \
	  echo 'Description: Turbo Pascal style IDE for Perl'; \
	  echo ' A full screen text mode IDE for Perl in the style of Turbo Pascal,'; \
	  echo ' with syntax highlighting, syntax checking, captured runs, perldoc'; \
	  echo ' lookup and an integrated debugger built on Devel::ebug.'; \
	} > $(DEBROOT)/DEBIAN/control
	dpkg-deb --build --root-owner-group $(DEBROOT) $@
	rm -rf $(DEBROOT)

clean:
	rm -rf $(UNITDIR) $(TARGET) $(TESTS) $(PKGDIR)
	rm -f $(SRCDIR)/*.o $(SRCDIR)/*.ppu $(TESTDIR)/*.o $(TESTDIR)/*.ppu
