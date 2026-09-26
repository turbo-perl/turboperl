#!/bin/sh
# Run the highlighter over every Perl module it can find and check that none
# of them leaves the scanner stuck.
#
# A file that ends inside a quote, a here-document or a half finished s///
# means the highlighter lost track somewhere: from that point on the rest of
# the file would be painted as one long string.  Real code almost never ends
# that way, so a non-zero count here is a regression.
#
#   tests/corpus.sh [extra directory ...]

set -u
HL=tests/hltest
[ -x "$HL" ] || { echo "corpus.sh: build $HL first (make test)" >&2; exit 2; }

DIRS=$*
if [ -z "$DIRS" ]; then
    DIRS=$(perl -e 'print join "\n", grep { -d } @INC' 2>/dev/null)
fi
[ -n "$DIRS" ] || { echo "corpus.sh: no perl library directories found; skipping"; exit 0; }

TOTAL=0
STUCK=0
CRASH=0

for d in $DIRS; do
    [ -d "$d" ] || continue
    find "$d" \( -name '*.pm' -o -name '*.pl' -o -name '*.t' \) -type f 2>/dev/null
done | while IFS= read -r f; do
    printf '%s\n' "$f"
done > /tmp/corpus.$$.list

while IFS= read -r f; do
    TOTAL=$((TOTAL + 1))
    if ! ST=$(timeout 30 "$HL" -s "$f" 2>/dev/null | tail -1 | awk -F'|' '{gsub(/ /,"",$2); print $2}'); then
        CRASH=$((CRASH + 1))
        echo "CRASH $f"
        continue
    fi
    case "$ST" in
        quote*|seek*|heredoc*)
            STUCK=$((STUCK + 1))
            echo "STUCK($ST) $f"
            ;;
    esac
    printf '%d %d %d\n' "$TOTAL" "$STUCK" "$CRASH" > /tmp/corpus.$$.count
done < /tmp/corpus.$$.list

read -r TOTAL STUCK CRASH < /tmp/corpus.$$.count 2>/dev/null || { TOTAL=0; STUCK=0; CRASH=0; }
rm -f /tmp/corpus.$$.list /tmp/corpus.$$.count

echo "corpus: $TOTAL files, $STUCK left the scanner stuck, $CRASH crashed"
[ "$STUCK" -eq 0 ] && [ "$CRASH" -eq 0 ]
