#!/bin/sh
# Integration tests for TurboPerl.
#
# The IDE is a full screen terminal program, so these drive the real thing
# inside tmux and assert on what ends up on the screen.  Anything that can be
# checked without a screen lives in tests/ instead and runs much faster.
#
#   ./run-tests.sh            run them all
#   ./run-tests.sh -v         also print each captured screen

set -u

IDE=./turboperl
SESSION=turboperl-test-$$
VERBOSE=${1:-}
PASS=0
FAIL=0
TMPDIR_T=$(mktemp -d)
trap 'tmux kill-session -t "$SESSION" 2>/dev/null; rm -rf "$TMPDIR_T"' EXIT INT TERM

if [ ! -x "$IDE" ]; then
    echo "run-tests.sh: $IDE is not built; run make first" >&2
    exit 2
fi
if ! command -v tmux >/dev/null 2>&1; then
    echo "run-tests.sh: tmux is needed for the interface tests; skipping" >&2
    exit 0
fi

# start SESSION running the IDE on the given arguments
start() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    # FORCETERM runs the IDE under a different terminal description; tmux
    # still renders the result, which is what lets the alternate-screen
    # handling be exercised for more than one style of terminal.
    if [ -n "${FORCETERM:-}" ]; then
        tmux new-session -d -s "$SESSION" -x "${COLS:-100}" -y "${ROWS:-30}" \
             "TERM=$FORCETERM $IDE $*"
    else
        tmux new-session -d -s "$SESSION" -x "${COLS:-100}" -y "${ROWS:-30}" "$IDE $*"
    fi
    sleep 2
}

stop() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    sleep 0.3
}

keys() {
    tmux send-keys -t "$SESSION" "$@"
    sleep "${DELAY:-1}"
}

screen() { tmux capture-pane -t "$SESSION" -p; }

# tmux's own names for the function keys do not always reach the IDE as the
# key that was asked for - its F8 arrives as something else entirely - so
# the debugger keys are sent as the byte sequences a real xterm would send.
rawkeys() {
    tmux send-keys -t "$SESSION" -H "$@"
    sleep "${DELAY:-1}"
}
F7='1b 5b 31 38 7e'
F8='1b 5b 31 39 7e'
CTRL_F2='1b 5b 31 32 3b 35 7e'
CTRL_F8='1b 5b 31 39 3b 35 7e'
CTRL_F9='1b 5b 32 30 3b 35 7e'
screen_colour() { tmux capture-pane -t "$SESSION" -p -e; }

# check NAME HAYSTACK NEEDLE
check() {
    name=$1; hay=$2; needle=$3
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n' "$name"
        printf '       looked for: %s\n' "$needle"
        printf '%s\n' "$hay" | sed 's/^/       | /'
    fi
    [ "$VERBOSE" = "-v" ] && printf '%s\n' "$hay" | sed 's/^/     > /'
    return 0
}

# check_re NAME HAYSTACK EXTENDED-REGEX
check_re() {
    name=$1; hay=$2; re=$3
    if printf '%s' "$hay" | grep -qE -- "$re"; then
        PASS=$((PASS + 1))
        printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n' "$name"
        printf '       looked for /%s/\n' "$re"
        printf '%s\n' "$hay" | sed 's/^/       | /'
    fi
    return 0
}

check_not() {
    name=$1; hay=$2; needle=$3
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf 'FAIL %s (unexpectedly found "%s")\n' "$name" "$needle"
    else
        PASS=$((PASS + 1))
        printf 'ok   %s\n' "$name"
    fi
    return 0
}

# ---------------------------------------------------------------- fixtures
cat > "$TMPDIR_T/good.pl" <<'EOF'
#!/usr/bin/env perl
use strict;
use warnings;
my @xs = qw(one two three);
print "count: ", scalar(@xs), "\n";
warn "a warning\n";
print "last: $xs[-1]\n";
EOF

cat > "$TMPDIR_T/bad.pl" <<'EOF'
#!/usr/bin/env perl
use strict;
use warnings;

my $ok = 1;

sub thing {
    return $never_declared;
}
EOF

cat > "$TMPDIR_T/block.pl" <<'EOF'
my $a = 1;
my $b = 2;
my $c = 3;
my $d = 4;
EOF

perl -e 'print "my \$r = \"";
         printf "%09d|", $_*10 for 1..15;
         print "\";\n";' > "$TMPDIR_T/long.pl"

echo "== TurboPerl interface tests =="

# ------------------------------------------------------- 1. it comes up
start "$TMPDIR_T/good.pl"
S=$(screen)
check "menu bar is drawn"        "$S" "File  Edit  Search  Run  Debug  Tools  Options  Window  Help"
check "status line is drawn"     "$S" "F9 Check"
check "the file is loaded"       "$S" "print \"count: \", scalar(@xs)"
check "the title shows the file" "$S" "good.pl"

# ------------------------------------------------- 2. syntax highlighting
C=$(screen_colour)
check "keywords are coloured"    "$C" "$(printf '\033[97m')"
check "comments are coloured"    "$C" "$(printf '\033[36m')"
check "strings are coloured"     "$C" "$(printf '\033[92m')"
check "variables are coloured"   "$C" "$(printf '\033[96m')"
stop

# --------------------------------------------------- 3. syntax check, clean
start "$TMPDIR_T/good.pl"
keys F9
DELAY=3 keys ""
S=$(screen)
check "clean file reports syntax OK" "$S" "syntax OK"
keys Enter
stop

# -------------------------------------------------- 4. syntax check, broken
start "$TMPDIR_T/bad.pl"
DELAY=4 keys F9
S=$(screen)
check "error is listed with its line" "$S" "bad.pl:8:"
check "error text is shown"           "$S" "Global symbol"
check "output window shows perl"      "$S" "had compilation errors"

# ------------------------------------------------------- 5. jump to the error
DELAY=2 keys Enter
S=$(screen)
check "Enter jumps to the error line" "$S" "8:1"
stop

# ------------------------------------------------------------ 6. running
start "$TMPDIR_T/good.pl"
keys M-r
DELAY=4 keys r
S=$(screen)
check "run captures stdout"        "$S" "count: 3"
check "run captures stderr"        "$S" "a warning"
check "run captures later output"  "$S" "last: three"
check "exit code is reported"      "$S" "exit code 0"
# print/warn/print must come back in the order the script made them
ORDER=$(printf '%s' "$S" | grep -n -E "count: 3|a warning|last: three" | cut -d: -f1 | tr '\n' ' ')
FIRST=$(echo "$ORDER" | awk '{print $1}')
SECOND=$(echo "$ORDER" | awk '{print $2}')
THIRD=$(echo "$ORDER" | awk '{print $3}')
if [ -n "$THIRD" ] && [ "$FIRST" -lt "$SECOND" ] && [ "$SECOND" -lt "$THIRD" ]; then
    PASS=$((PASS + 1)); echo "ok   stdout and stderr interleave in order"
else
    FAIL=$((FAIL + 1)); echo "FAIL stdout and stderr interleave in order ($ORDER)"
fi
check_not "clean run raises no messages" "$S" "Messages - good.pl"
stop

# ------------------------------------------------- 7. block comment round trip
start "$TMPDIR_T/block.pl"
DELAY=0.4 keys S-Down
DELAY=0.4 keys S-Down
DELAY=1.5 keys M-c
S=$(screen)
check "block comment marks the selected lines" "$S" "# my \$a = 1;"
check_re "block comment stops at the selection" "$S" '[^#]my \$c = 3;'
DELAY=1.5 keys M-u
S=$(screen)
check_re "uncomment restores the text"          "$S" '[^#]my \$a = 1;'
check_not "no # is left behind"                "$S" "# my \$a"
stop

# -------------------------------------------------- 8. horizontal scrolling
COLS=80 ROWS=12 start "$TMPDIR_T/long.pl"
S=$(screen)
check "long line starts at column 1" "$S" "my \$r = \"000000010|"
DELAY=1.5 keys End
S=$(screen)
check "scrolled view shows the line end" "$S" "000000150|\";"
check_not "no stale text from column 1" "$S" "my \$r = \""
stop

# ------------------------------------------------------------- 9. perldoc
start "$TMPDIR_T/good.pl"
DELAY=0.3 keys Down Down Down Down
DELAY=0.3 keys Right Right
keys M-t
DELAY=5 keys h
S=$(screen)
check "perldoc looks the word up" "$S" "perldoc -f print"
stop

# ------------------------------- 10. running on the console, and the user screen
cat > "$TMPDIR_T/console.pl" <<'EOF'
$| = 1;
print "CONSOLE OUTPUT LINE\n";
EOF
start "$TMPDIR_T/console.pl"
keys M-r
DELAY=3 keys c
S=$(screen)
check "console run shows the script's output" "$S" "CONSOLE OUTPUT LINE"
check "console run waits before returning"    "$S" "press Enter to return to the IDE"

# Stray bytes arriving on the terminal must not dismiss that prompt.
tmux send-keys -t "$SESSION" -H 1b 5b 4d 20 21 21
sleep 2
S=$(screen)
check "stray input does not dismiss the prompt" "$S" "press Enter to return to the IDE"

DELAY=2 keys Enter
S=$(screen)
check "Enter returns to the IDE" "$S" "File  Edit  Search  Run  Debug"

# Alt-F5 steps back to the terminal, where the output still is.
DELAY=2 keys M-F5
S=$(screen)
check "the user screen brings the output back" "$S" "CONSOLE OUTPUT LINE"
check "its prompt sits at the bottom"          "$S" "user screen - press Enter to go back"
DELAY=2 keys Enter
S=$(screen)
check "Enter leaves the user screen" "$S" "File  Edit  Search  Run  Debug"
stop

# A second console run must carry on below the first rather than starting
# again at the top of the screen and painting over it.
cat > "$TMPDIR_T/twice.pl" <<'EOF'
$| = 1;
print "MARKER-$ARGV[0]\n";
EOF
start "$TMPDIR_T/twice.pl"
keys M-r
DELAY=3 keys c
DELAY=2 keys Enter
keys M-r
DELAY=3 keys c
S=$(screen)
COUNT=$(printf '%s' "$S" | grep -c "MARKER")
if [ "$COUNT" -ge 2 ]; then
    PASS=$((PASS + 1)); echo "ok   a second console run appends below the first"
else
    FAIL=$((FAIL + 1))
    echo "FAIL a second console run appends below the first (found $COUNT of 2)"
    printf '%s\n' "$S" | sed 's/^/       | /'
fi
# Nothing should be stepping diagonally across the screen: every line the
# IDE wrote has to start hard against the left margin.
if printf '%s' "$S" | grep -qE '^[[:space:]]+--- TurboPerl'; then
    FAIL=$((FAIL + 1)); echo "FAIL console output starts at the left margin"
else
    PASS=$((PASS + 1)); echo "ok   console output starts at the left margin"
fi
DELAY=2 keys Enter
stop

# The same again on a terminal whose alternate screen does not carry the
# cursor across.  putty's smcup/rmcup are a bare ESC [ ? 47 h / l, so without
# the IDE saving and restoring the cursor itself a console run lands in the
# middle of the console and writes over it.
FORCETERM=putty start "$TMPDIR_T/twice.pl"
keys M-r
DELAY=3 keys c
DELAY=2 keys Enter
keys M-r
DELAY=3 keys c
S=$(screen)
COUNT=$(printf '%s' "$S" | grep -c "MARKER")
if [ "$COUNT" -ge 2 ]; then
    PASS=$((PASS + 1)); echo "ok   console runs append on a terminal without cursor save"
else
    FAIL=$((FAIL + 1))
    echo "FAIL console runs append on a terminal without cursor save (found $COUNT of 2)"
    printf '%s\n' "$S" | sed 's/^/       | /'
fi
DELAY=2 keys Enter
unset FORCETERM
stop

# ----------------------------------------------------------- 11. the debugger
cat > "$TMPDIR_T/dbg.pl" <<'EOF'
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
start "$TMPDIR_T/dbg.pl"
DELAY=6 rawkeys $F7
S=$(screen)
check "the debugger starts and stops before the first statement" "$S" "3:1"
C=$(screen_colour)
# black on cyan is the current statement marker
check "the current statement is marked" "$C" "$(printf '\033[30m\033[46m')"

# down to the '$total += $n' line and set a break point there
DELAY=0.4 keys Down Down Down
DELAY=1.5 rawkeys $CTRL_F8
C=$(screen_colour)
check "a break point line turns red" "$C" "$(printf '\033[41m')"

DELAY=5 rawkeys $CTRL_F9
S=$(screen)
check "continue stops at the break point" "$S" "6:1"

# the debugger panes
keys M-d
DELAY=2 keys v
S=$(screen)
check "the variables pane lists lexicals" "$S" "\$n = 1"
check "and the outer lexical too"         "$S" "\$total = 0"

keys M-d
DELAY=2 keys s
S=$(screen)
check "the call stack names the frame" "$S" "main::add(1)"

DELAY=3 rawkeys $CTRL_F2
S=$(screen)
check_not "program reset ends the session" "$S" "main::add(1)"
stop

# a long value is cut to fit, and opens out a level at a time
cat > "$TMPDIR_T/deep.pl" <<'EOF'
use strict;
use warnings;
my $deep = { list => [1 .. 40], name => 'x' x 200 };
print "ok\n";
EOF
start "$TMPDIR_T/deep.pl"
DELAY=6 rawkeys $F7
DELAY=0.4 keys Down
DELAY=1.5 rawkeys $CTRL_F8
DELAY=5 rawkeys $CTRL_F9
keys M-d
DELAY=2 keys v
S=$(screen)
check_re "a long variable is cut to one line" "$S" '\+ \$deep = \{list => \[1, 2, .*\.\.\.'
keys Right
S=$(screen)
check "Right opens it"                   "$S" "- \$deep"
check "showing its elements, still shut" "$S" "+ {list} = [1, 2, 3"
check "and its plain values"             "$S" "{name} = 'xxx"
keys Right Right
S=$(screen)
check "an element opens in turn"         "$S" "    [0] = 1"
keys Left Left Left
S=$(screen)
check "Left goes back up and closes"     "$S" "+ \$deep = {list"
check_not "leaving the elements hidden"  "$S" "{name}"
DELAY=3 rawkeys $CTRL_F2
stop

# ------------------------------------------------------------- 12. quitting
start "$TMPDIR_T/good.pl"
DELAY=2 keys M-x
if tmux has-session -t "$SESSION" 2>/dev/null; then
    FAIL=$((FAIL + 1)); echo "FAIL Alt-X exits"
else
    PASS=$((PASS + 1)); echo "ok   Alt-X exits"
fi

echo
echo "interface tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
