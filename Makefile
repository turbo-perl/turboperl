# TurboPerl - build rules.
#
#   make            build the IDE
#   make test       build and run the headless unit tests
#   make install    install under $(PREFIX), default /usr/local
#   make clean      remove build products

FPC       ?= fpc
PREFIX    ?= /usr/local
FVUNITS   ?= $(shell $(FPC) -iV >/dev/null 2>&1 && \
               echo /usr/lib/x86_64-linux-gnu/fpc/$$($(FPC) -iV)/units/$$($(FPC) -iTP)-$$($(FPC) -iTO)/fv)

SRCDIR    := src
UNITDIR   := units
BINDIR    := .
TESTDIR   := tests

FPCFLAGS  := -Sg -Mobjfpc -O2 -Xs -vw -Fu$(SRCDIR) -Fu$(FVUNITS) -Fi$(SRCDIR) -FU$(UNITDIR)

TARGET    := turboperl
TESTS     := $(TESTDIR)/hltest $(TESTDIR)/texttest $(TESTDIR)/perltest \
             $(TESTDIR)/cfgtest

SOURCES   := $(wildcard $(SRCDIR)/*.pas) $(SRCDIR)/perlwords.inc turboperl.pas

.PHONY: all test clean install uninstall check corpus

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
	install -d $(DESTDIR)$(PREFIX)/share/turboperl/examples
	install -m 644 examples/* $(DESTDIR)$(PREFIX)/share/turboperl/examples/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(TARGET)
	rm -rf $(DESTDIR)$(PREFIX)/share/turboperl

clean:
	rm -rf $(UNITDIR) $(TARGET) $(TESTS)
	rm -f $(SRCDIR)/*.o $(SRCDIR)/*.ppu $(TESTDIR)/*.o $(TESTDIR)/*.ppu
