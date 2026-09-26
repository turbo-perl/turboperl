{ ========================================================================== }
{  TurboPerl - Unit: TPHilite                                                }
{                                                                            }
{  A line oriented Perl syntax highlighter.                                  }
{                                                                            }
{  The editor hands us one line at a time together with the scanner state    }
{  left over from the previous line.  We fill in a token kind for every      }
{  character and hand back the state for the next line.  Keeping the whole   }
{  cross-line context in a plain record means the editor can cache it and    }
{  resume anywhere without re-reading the file.                              }
{                                                                            }
{  Constructs that survive a line break, and so live in the state:           }
{    - POD blocks            =pod ... =cut                                   }
{    - the data section      __END__ / __DATA__                              }
{    - here-documents        <<EOT, <<"EOT", <<'EOT', <<~EOT; a single line  }
{                            may queue up several                           }
{    - quote-like operators  '' "" `` q qq qw qr qx m s tr y, including the  }
{                            gap between the two halves of s(...)(...)       }
{                                                                            }
{  Perl cannot be lexed exactly without running it, so a few deliberate      }
{  choices are made where the grammar is ambiguous; they are noted at the    }
{  point where they are taken.                                               }
{ ========================================================================== }
unit TPHilite;

{$mode objfpc}{$H-}

interface

uses TPConst;

const
  { Must be at least as large as editors.MaxLineLength. }
  MaxHiliteLine     = 4096;
  MaxPendingHeredoc = 4;
  MaxHereTerm       = 40;

type
  TWordStr = String[20];

  TPerlMode = (
    pmNormal,     { ordinary code                                        }
    pmPod,        { inside a POD block                                   }
    pmData,       { after __END__ or __DATA__                            }
    pmHeredoc,    { inside a here-document body                          }
    pmQuote,      { inside a quote-like section                          }
    pmSeek);      { between the halves of s(...)(...), looking for the   }
                  { bracket that opens the second half                   }

  TQuoteKind = (
    qkSingle,     { '...'  q(...)         no interpolation }
    qkDouble,     { "..."  qq(...)        interpolating    }
    qkBack,       { `...`  qx(...)        interpolating    }
    qkWords,      { qw(...)                                }
    qkRegex,      { m//  qr//  and the pattern half of s// }
    qkReplace,    { the replacement half of s///           }
    qkTrans);     { tr///  y///                            }

  THeredocInfo = record
    Term     : String[MaxHereTerm];
    Interp   : Boolean;
    Indented : Boolean;          { <<~TERM lets the terminator be indented }
  end;

  TPerlState = record
    Mode       : TPerlMode;
    Quote      : TQuoteKind;     { section open now, or sought in pmSeek }
    CloseDelim : Char;
    OpenDelim  : Char;           { #0 when the delimiter does not nest }
    Depth      : Integer;
    Pending    : TQuoteKind;     { second half of s/tr/y, if any }
    HasPending : Boolean;
    HereCount  : Integer;
    Here       : array[0..MaxPendingHeredoc - 1] of THeredocInfo;
  end;

  TTokLine = array[0..MaxHiliteLine - 1] of TPerlTok;

procedure InitPerlState(out S: TPerlState);

{ Classify one line.  Line/Len describe the raw text *without* its line
  terminator.  S is updated in place to the state for the following line.

  Truncated says the caller had to cut the line short because it was longer
  than MaxHiliteLine.  The tail of such a line is never seen, so any
  delimiter closing in it would be missed; rather than carry a quote that
  can never close into the rest of the file, the state is reset. }
procedure HighlightLine(const Line; Len: Integer; var S: TPerlState;
                        out Toks: TTokLine; Truncated: Boolean = False);

function IsIdentStart(C: Char): Boolean;
function IsIdentChar(C: Char): Boolean;
function PerlWordKind(const W: ShortString): TPerlTok;

implementation

{$I perlwords.inc}

{ -------------------------------------------------------------------------- }
{  Small character predicates                                                 }
{ -------------------------------------------------------------------------- }

function IsIdentStart(C: Char): Boolean;
begin
  Result := (C = '_') or ((C >= 'A') and (C <= 'Z')) or
                         ((C >= 'a') and (C <= 'z'));
end;

function IsIdentChar(C: Char): Boolean;
begin
  Result := IsIdentStart(C) or ((C >= '0') and (C <= '9'));
end;

function IsDigit(C: Char): Boolean;
begin
  Result := (C >= '0') and (C <= '9');
end;

function IsSpace(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

{ Binary search over one of the sorted tables in perlwords.inc. }
function InList(const W: ShortString; const List: array of TWordStr): Boolean;
var
  Lo, Hi, Mid: Integer;
begin
  if Length(W) > 20 then Exit(False);
  Lo := 0;
  Hi := High(List);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if List[Mid] = W then
      Exit(True)
    else if List[Mid] < W then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := False;
end;

function PerlWordKind(const W: ShortString): TPerlTok;
begin
  if InList(W, KeywordList) then
    Result := ptKeyword
  else if InList(W, BuiltinList) then
    Result := ptBuiltin
  else
    Result := ptNormal;
end;

{ The closing half of a delimiter pair; anything that is not a bracket
  closes with itself. }
function CloseFor(C: Char): Char;
begin
  case C of
    '(': Result := ')';
    '[': Result := ']';
    '{': Result := '}';
    '<': Result := '>';
  else
    Result := C;
  end;
end;

function IsBracket(C: Char): Boolean;
begin
  Result := (C = '(') or (C = '[') or (C = '{') or (C = '<');
end;

function Interpolates(K: TQuoteKind): Boolean;
begin
  Result := K in [qkDouble, qkBack, qkRegex, qkReplace];
end;

function QuoteTok(K: TQuoteKind): TPerlTok;
begin
  case K of
    qkRegex, qkTrans: Result := ptRegex;
  else
    Result := ptString;
  end;
end;

procedure InitPerlState(out S: TPerlState);
begin
  FillChar(S, SizeOf(S), 0);
  S.Mode       := pmNormal;
  S.Quote      := qkDouble;
  S.Pending    := qkDouble;
  S.CloseDelim := #0;
  S.OpenDelim  := #0;
  S.Depth      := 0;
  S.HasPending := False;
  S.HereCount  := 0;
end;

{ ========================================================================== }

{ The scanner proper.  It has several early exits - an unterminated quote,
  a POD block, the data section - so the Truncated post-condition is applied
  by the wrapper below rather than at the bottom of this routine. }
procedure ScanLine(const Line; Len: Integer; var S: TPerlState;
                   out Toks: TTokLine);
var
  Buf        : PChar;
  i          : Integer;
  ExpectTerm : Boolean;   { True where a term - and so a bare /regex/ - may start }
  LastKw     : ShortString;
  { "print $fh <<EOT" puts a here-document after a variable, which is not
    otherwise a term position.  PrintKw marks that the last word was print,
    printf or say; PrintFh marks that the token just scanned was the
    filehandle following one.  Only here-document detection consults these,
    so "print $x / 2" still divides. }
  PrintKw    : Boolean;
  PrintFh    : Boolean;

  { ---------------------------------------------------------------------- }

  function Ch(K: Integer): Char;
  begin
    if (K >= 0) and (K < Len) then Result := Buf[K] else Result := #0;
  end;

  procedure Mark(A, B: Integer; T: TPerlTok);
  var
    K: Integer;
  begin
    if A < 0 then A := 0;
    if B > Len then B := Len;
    for K := A to B - 1 do Toks[K] := T;
  end;

  function WordAt(K: Integer): ShortString;
  var
    E: Integer;
  begin
    Result := '';
    if not IsIdentStart(Ch(K)) then Exit;
    E := K;
    while IsIdentChar(Ch(E)) do Inc(E);
    if E - K > 255 then E := K + 255;
    SetLength(Result, E - K);
    Move(Buf[K], Result[1], E - K);
  end;

  function SkipSpace(K: Integer): Integer;
  begin
    while (K < Len) and IsSpace(Buf[K]) do Inc(K);
    Result := K;
  end;

  { ---------------------------------------------------------------------- }
  {  Variables                                                              }
  { ---------------------------------------------------------------------- }

  { $_ $0 $! $@ $/ @_ and the rest of the punctuation variables. }
  function IsPunctVar(C: Char): Boolean;
  begin
    Result := C in ['_', '!', '@', '/', '\', ',', ';', '.', '&', '`', '''',
                    '+', '^', '~', '=', '-', '<', '>', '|', '?', ':', '$',
                    '0'..'9', '"', '[', ']'];
  end;

  { Scan a variable whose sigil is at K.

    IdentOnly is set when we are inside a string or a regex.  There only
    $name / @name / $$name may be recognised: allowing a braced deref
    would eat the brace that the section's own depth counter needs, and allowing the
    punctuation variables would turn the $ in /foo$/ into $/ and swallow the
    closing delimiter. }
  function ScanVariable(var K: Integer; IdentOnly: Boolean): Boolean;
  var
    Sig  : Char;
    Tok  : TPerlTok;
    Start: Integer;
    J    : Integer;
  begin
    Start := K;
    Sig   := Buf[K];
    case Sig of
      '$': Tok := ptScalar;
      '@': Tok := ptArray;
      '%': Tok := ptHash;
      '&': Tok := ptScalar;
    else
      Exit(False);
    end;

    J := K + 1;

    { $#array - the last index of an array. }
    if (Sig = '$') and (Ch(J) = '#') and
       (IsIdentStart(Ch(J + 1)) or (Ch(J + 1) = '{') or (Ch(J + 1) = '$')) then
    begin
      Tok := ptArray;
      Inc(J);
    end;

    { Extra sigils for dereferencing: $$ref, $$$ref. }
    while (Ch(J) = '$') and (IsIdentStart(Ch(J + 1)) or (Ch(J + 1) = '$') or
                             ((not IdentOnly) and (Ch(J + 1) = '{'))) do
      Inc(J);

    if IsIdentStart(Ch(J)) then
    begin
      while IsIdentChar(Ch(J)) do Inc(J);
      while (Ch(J) = ':') and (Ch(J + 1) = ':') and IsIdentChar(Ch(J + 2)) do
      begin
        Inc(J, 2);
        while IsIdentChar(Ch(J)) do Inc(J);
      end;
    end
    else if IdentOnly and IsDigit(Ch(J)) then
    begin
      { Capture variables: $1 .. $9 inside a string or a replacement. }
      while IsDigit(Ch(J)) do Inc(J);
    end
    else if (not IdentOnly) and (Ch(J) = '{') then
      (* ${name} / @{$ref}: colour the sigil and brace only, and let the
         ordinary scanner deal with what is inside. *)
      Inc(J)
    else if (not IdentOnly) and (J = K + 1) and IsPunctVar(Ch(J)) then
      Inc(J)
    else
      Exit(False);

    Mark(Start, J, Tok);
    K := J;
    Result := True;
  end;

  { ---------------------------------------------------------------------- }
  {  Quote-like sections                                                    }
  { ---------------------------------------------------------------------- }

  { Scan the body of the section described by S, starting at K which is
    already inside it.  Returns True when the closing delimiter is found on
    this line, leaving K just past it; False when the body runs on. }
  function ScanSection(var K: Integer): Boolean;
  var
    Tok     : TPerlTok;
    Interp  : Boolean;
    EscTok  : TPerlTok;
    Save    : Integer;
  begin
    Tok    := QuoteTok(S.Quote);
    Interp := Interpolates(S.Quote);
    if Interp then EscTok := ptEscape else EscTok := Tok;

    while K < Len do
    begin
      { A backslash always hides the next character, even in '...' where
        only \\ and \' really are escapes - we still must not let \' end
        the string. }
      if (Buf[K] = '\') and (K + 1 < Len) then
      begin
        Mark(K, K + 2, EscTok);
        Inc(K, 2);
        Continue;
      end;

      if (S.OpenDelim <> #0) and (Buf[K] = S.OpenDelim) then
      begin
        Inc(S.Depth);
        Toks[K] := Tok;
        Inc(K);
        Continue;
      end;

      if Buf[K] = S.CloseDelim then
      begin
        Dec(S.Depth);
        Toks[K] := Tok;
        Inc(K);
        if S.Depth <= 0 then Exit(True);
        Continue;
      end;

      if Interp and (Buf[K] in ['$', '@']) then
      begin
        Save := K;
        if ScanVariable(K, True) then Continue;
        K := Save;
      end;

      Toks[K] := Tok;
      Inc(K);
    end;

    Result := False;
  end;

  { Trailing modifiers of a regex: m/.../gimsxe }
  procedure ScanModifiers(var K: Integer);
  var
    Start: Integer;
  begin
    Start := K;
    while IsIdentChar(Ch(K)) do Inc(K);
    Mark(Start, K, ptRegex);
  end;

  { Open a section whose opening delimiter sits at K. }
  procedure OpenSection(var K: Integer; Kind: TQuoteKind);
  var
    C: Char;
  begin
    C := Buf[K];
    S.Quote := Kind;
    if IsBracket(C) then
    begin
      S.OpenDelim  := C;
      S.CloseDelim := CloseFor(C);
    end
    else
    begin
      S.OpenDelim  := #0;
      S.CloseDelim := C;
    end;
    S.Depth := 1;
    Toks[K] := QuoteTok(Kind);
    Inc(K);
  end;

  { In pmSeek: skip whitespace and comments looking for the bracket that
    opens the second half of s(...)(...). }
  function SeekSecond(var K: Integer): Boolean;
  begin
    while K < Len do
    begin
      if IsSpace(Buf[K]) then
      begin
        Inc(K);
        Continue;
      end;
      if Buf[K] = '#' then
      begin
        Mark(K, Len, ptComment);
        K := Len;
        Exit(False);
      end;
      OpenSection(K, S.Quote);
      S.Mode := pmQuote;
      Exit(True);
    end;
    Result := False;
  end;

  { Carry on with whatever section is open, handing over to a second
    section and picking up the trailing modifiers.  Used both when a
    construct starts and when one is resumed at the top of a line. }
  procedure ContinueQuote(var K: Integer);
  begin
    while True do
    begin
      if not ScanSection(K) then
      begin
        S.Mode := pmQuote;          { runs past the end of this line }
        Exit;
      end;

      if S.HasPending then
      begin
        S.HasPending := False;
        S.Quote      := S.Pending;
        if S.OpenDelim <> #0 then
        begin
          { s(...)(...): the second half brings its own bracket, which may
            not be on this line. }
          S.Mode := pmSeek;
          if not SeekSecond(K) then Exit;
        end
        else
          { s/.../.../: the delimiter just closed opens the second half. }
          S.Depth := 1;
        Continue;
      end;

      S.Mode := pmNormal;
      ScanModifiers(K);
      ExpectTerm := False;
      Exit;
    end;
  end;

  { Drive a possibly two part quote-like construct from K, which points at
    the opening delimiter. }
  procedure RunQuote(var K: Integer; Kind, Second: TQuoteKind;
                     TwoPart: Boolean);
  begin
    S.HasPending := TwoPart;
    S.Pending    := Second;
    OpenSection(K, Kind);
    ContinueQuote(K);
  end;

  { ---------------------------------------------------------------------- }
  {  Here-documents                                                         }
  { ---------------------------------------------------------------------- }

  procedure PushHeredoc(const Term: ShortString; Interp, Indented: Boolean);
  begin
    if S.HereCount >= MaxPendingHeredoc then Exit;
    S.Here[S.HereCount].Term     := Copy(Term, 1, MaxHereTerm);
    S.Here[S.HereCount].Interp   := Interp;
    S.Here[S.HereCount].Indented := Indented;
    Inc(S.HereCount);
  end;

  procedure PopHeredoc;
  var
    K: Integer;
  begin
    for K := 0 to S.HereCount - 2 do S.Here[K] := S.Here[K + 1];
    if S.HereCount > 0 then Dec(S.HereCount);
  end;

  { <<EOT, <<"EOT", <<'EOT', <<~EOT at K, which points at the first '<'.

    Telling a here-document from a left shift is done by what follows the
    <<: an identifier or an opening quote means a here-document, anything
    else - a space, a digit, a sigil - means a shift. }
  function TryHeredoc(var K: Integer): Boolean;
  var
    J        : Integer;
    Indented : Boolean;
    Interp   : Boolean;
    Quoted   : Boolean;
    Quote    : Char;
    Term     : ShortString;
    Start    : Integer;
  begin
    Start := K;
    if (Ch(K) <> '<') or (Ch(K + 1) <> '<') then Exit(False);
    J := K + 2;

    Indented := Ch(J) = '~';
    if Indented then Inc(J);

    { Perl allows space before a *quoted* terminator - print << "EOF" - but
      not before a bare one, where <<EOF must be written closed up. }
    if IsSpace(Ch(J)) then
    begin
      J := SkipSpace(J);
      if not (Ch(J) in ['''', '"', '`']) then Exit(False);
    end;

    if Ch(J) in ['''', '"', '`'] then
    begin
      Quoted := True;
      Quote  := Ch(J);
      Interp := Quote <> '''';
      Inc(J);
      Term := '';
      while (J < Len) and (Buf[J] <> Quote) do
      begin
        if Length(Term) < MaxHereTerm then Term := Term + Buf[J];
        Inc(J);
      end;
      if J >= Len then Exit(False);          { unterminated - not a heredoc }
      Inc(J);
    end
    else if IsIdentStart(Ch(J)) then
    begin
      Quoted := False;
      Interp := True;
      Term   := WordAt(J);
      Inc(J, Length(Term));
    end
    else
      Exit(False);

    { <<"" is legal: the body then runs to the first empty line.  A bare
      << with nothing after it is not a here-document at all. }
    if (Term = '') and (not Quoted) then Exit(False);

    PushHeredoc(Term, Interp, Indented);
    Mark(Start, J, ptHeredoc);
    K := J;
    Result := True;
  end;

  function IsHereTerminator: Boolean;
  var
    K, E : Integer;
    T    : ShortString;
  begin
    if S.HereCount = 0 then Exit(False);
    T := S.Here[0].Term;
    K := 0;
    if S.Here[0].Indented then
      while (K < Len) and IsSpace(Buf[K]) do Inc(K);
    if Len - K < Length(T) then Exit(False);
    for E := 1 to Length(T) do
      if Buf[K + E - 1] <> T[E] then Exit(False);
    K := K + Length(T);
    while (K < Len) and IsSpace(Buf[K]) do Inc(K);
    Result := K >= Len;
  end;

  procedure MarkHeredocBody;
  var
    K, Save: Integer;
  begin
    if (S.HereCount = 0) or (not S.Here[0].Interp) then
    begin
      Mark(0, Len, ptHeredoc);
      Exit;
    end;
    K := 0;
    while K < Len do
    begin
      if (Buf[K] = '\') and (K + 1 < Len) then
      begin
        Mark(K, K + 2, ptEscape);
        Inc(K, 2);
        Continue;
      end;
      if Buf[K] in ['$', '@'] then
      begin
        Save := K;
        if ScanVariable(K, True) then Continue;
        K := Save;
      end;
      Toks[K] := ptHeredoc;
      Inc(K);
    end;
  end;

  { ---------------------------------------------------------------------- }
  {  Numbers                                                                }
  { ---------------------------------------------------------------------- }

  procedure ScanNumber(var K: Integer);
  var
    Start: Integer;
  begin
    Start := K;
    if (Buf[K] = '0') and (Ch(K + 1) in ['x', 'X', 'b', 'B']) then
    begin
      Inc(K, 2);
      while IsIdentChar(Ch(K)) do Inc(K);
    end
    else
    begin
      while IsDigit(Ch(K)) or (Ch(K) = '_') do Inc(K);
      if (Ch(K) = '.') and IsDigit(Ch(K + 1)) then
      begin
        Inc(K);
        while IsDigit(Ch(K)) or (Ch(K) = '_') do Inc(K);
      end;
      if Ch(K) in ['e', 'E'] then
        if IsDigit(Ch(K + 1)) or
           ((Ch(K + 1) in ['+', '-']) and IsDigit(Ch(K + 2))) then
        begin
          Inc(K, 2);
          while IsDigit(Ch(K)) do Inc(K);
        end;
    end;
    Mark(Start, K, ptNumber);
  end;

  { ---------------------------------------------------------------------- }

  (* Would the character at K serve as the delimiter of a quote-like
     operator?  The awkward cases are a bareword hash key (q => 1) and a
     hash subscript ($h{s}), so punctuation that normally closes or
     separates an expression is rejected. *)
  function ValidDelim(K: Integer): Boolean;
  var
    C: Char;
  begin
    C := Ch(K);
    if (C = #0) or IsIdentChar(C) or IsSpace(C) then Exit(False);
    { A comma is allowed: s,foo,bar, and m,/path/,i are real idioms, and a
      bareword q/s/y immediately followed by a comma is not. }
    if C in [';', ')', '}', ']', '#'] then Exit(False);
    if (C = '=') and (Ch(K + 1) = '>') then Exit(False);
    Result := True;
  end;

  { True when the word at K is preceded by -> , which makes it a method
    name: $obj->y(3) is a call, not a transliteration. }
  function AfterArrow(K: Integer): Boolean;
  begin
    Dec(K);
    while (K >= 0) and IsSpace(Buf[K]) do Dec(K);
    Result := (K >= 1) and (Buf[K] = '>') and (Buf[K - 1] = '-');
  end;

  { True when the word at K is preceded by a minus sign.  The only file
    test operator that collides with a quote-like operator is -s, so this
    is deliberately narrow: "-s $file" is a file size test, not the start
    of a substitution delimited by spaces. }
  function AfterMinus(K: Integer): Boolean;
  begin
    Dec(K);
    while (K >= 0) and IsSpace(Buf[K]) do Dec(K);
    Result := (K >= 0) and (Buf[K] = '-');
  end;

var
  W        : ShortString;
  WLen     : Integer;
  Kind     : TPerlTok;
  Save     : Integer;
  DelimPos : Integer;
  C        : Char;

begin
  Buf := @Line;
  if Len > MaxHiliteLine then Len := MaxHiliteLine;
  if Len < 0 then Len := 0;
  if Len > 0 then FillChar(Toks, Len * SizeOf(TPerlTok), 0);

  ExpectTerm := True;
  LastKw     := '';
  PrintKw    := False;
  PrintFh    := False;
  i          := 0;

  { ---- resume whatever the previous line left open ---- }
  case S.Mode of
    pmData:
      begin
        Mark(0, Len, ptData);
        Exit;
      end;

    pmPod:
      begin
        Mark(0, Len, ptPod);
        if (Len >= 4) and (Buf[0] = '=') and (WordAt(1) = 'cut') then
          S.Mode := pmNormal;
        Exit;
      end;

    pmHeredoc:
      begin
        if IsHereTerminator then
        begin
          Mark(0, Len, ptHeredoc);
          PopHeredoc;
          if S.HereCount = 0 then S.Mode := pmNormal;
        end
        else
          MarkHeredocBody;
        Exit;
      end;

    pmQuote:
      begin
        ContinueQuote(i);
        if S.Mode <> pmNormal then Exit;
      end;

    pmSeek:
      begin
        if not SeekSecond(i) then Exit;
        ContinueQuote(i);
        if S.Mode <> pmNormal then Exit;
      end;
  end;

  { ---- ordinary code ---- }
  while i < Len do
  begin
    C := Buf[i];

    { --- POD and the data section; both only at column 0 --- }
    if (i = 0) and (C = '=') and IsIdentStart(Ch(1)) then
    begin
      Mark(0, Len, ptPod);
      if WordAt(1) <> 'cut' then S.Mode := pmPod;
      Exit;
    end;

    if (i = 0) and (C = '_') then
    begin
      W := WordAt(0);
      if (W = '__END__') or (W = '__DATA__') then
      begin
        Mark(0, Len, ptKeyword);
        S.Mode := pmData;
        Exit;
      end;
    end;

    if C = '#' then
    begin
      Mark(i, Len, ptComment);
      { Break rather than Exit: the line may have opened a here-document
        before the comment, as in  entry => <<'END', # a note  , and the
        queue is turned into pmHeredoc at the bottom of this routine. }
      Break;
    end;

    if IsSpace(C) then
    begin
      Inc(i);
      Continue;
    end;

    { --- words --- }
    if IsIdentStart(C) then
    begin
      W    := WordAt(i);
      WLen := Length(W);

      { Quote-like operators. }
      if ((W = 'q') or (W = 'qq') or (W = 'qw') or (W = 'qr') or (W = 'qx') or
          (W = 'm') or (W = 's') or (W = 'tr') or (W = 'y')) and
         (not AfterArrow(i)) and (LastKw <> 'sub') and
         (not ((W = 's') and AfterMinus(i))) then
      begin
        DelimPos := SkipSpace(i + WLen);
        if ValidDelim(DelimPos) then
        begin
          Mark(i, i + WLen, ptRegex);
          i := DelimPos;
          if W = 'q' then
            RunQuote(i, qkSingle, qkSingle, False)
          else if W = 'qq' then
            RunQuote(i, qkDouble, qkDouble, False)
          else if W = 'qw' then
            RunQuote(i, qkWords, qkWords, False)
          else if W = 'qx' then
            RunQuote(i, qkBack, qkBack, False)
          else if (W = 'qr') or (W = 'm') then
            RunQuote(i, qkRegex, qkRegex, False)
          else if W = 's' then
            RunQuote(i, qkRegex, qkReplace, True)
          else                                   { tr, y }
            RunQuote(i, qkTrans, qkTrans, True);
          if S.Mode <> pmNormal then Exit;
          LastKw := '';
          Continue;
        end;
      end;

      { The name introduced by sub / package / use / no / require. }
      if LastKw = 'sub' then
        Kind := ptSubName
      else if LastKw = 'package' then
        Kind := ptPackage
      else if (LastKw = 'use') or (LastKw = 'no') or (LastKw = 'require') then
      begin
        if InList(W, PragmaList) then Kind := ptPragma else Kind := ptPackage;
      end
      else
        Kind := PerlWordKind(W);

      { Take a package qualified name in one go. }
      Save := i + WLen;
      if Kind in [ptPackage, ptSubName] then
        while (Ch(Save) = ':') and (Ch(Save + 1) = ':') do
        begin
          Inc(Save, 2);
          while IsIdentChar(Ch(Save)) do Inc(Save);
        end;

      { A bareword in front of => is a hash key, not a function. }
      if Kind in [ptBuiltin, ptKeyword] then
      begin
        DelimPos := SkipSpace(Save);
        if (Ch(DelimPos) = '=') and (Ch(DelimPos + 1) = '>') then
          Kind := ptNormal;
      end;

      Mark(i, Save, Kind);

      PrintKw := (W = 'print') or (W = 'printf') or (W = 'say');
      PrintFh := False;

      if Kind in [ptKeyword, ptBuiltin] then
      begin
        LastKw := W;
        { An expression follows most keywords, so a slash after one starts a
          match rather than a division.  This gets "split /,/" right at the
          cost of "time / 60", which is the rarer of the two. }
        ExpectTerm := True;
      end
      else
      begin
        LastKw     := '';
        ExpectTerm := False;
      end;

      i := Save;
      Continue;
    end;

    { --- numbers --- }
    if IsDigit(C) then
    begin
      ScanNumber(i);
      ExpectTerm := False;
      LastKw     := '';
      Continue;
    end;

    { --- variables --- }
    if C in ['$', '@'] then
    begin
      Save := i;
      if ScanVariable(i, False) then
      begin
        ExpectTerm := False;
        PrintFh    := PrintKw;
        PrintKw    := False;
        LastKw     := '';
        Continue;
      end;
      i := Save;
    end
    else if (C = '%') or (C = '&') then
    begin
      { A sigil only where a term is expected; elsewhere it is modulus or
        bitwise and. }
      if ExpectTerm then
      begin
        Save := i;
        if ScanVariable(i, False) then
        begin
          ExpectTerm := False;
          LastKw     := '';
          Continue;
        end;
        i := Save;
      end;
    end;

    { --- a glob naming a punctuation variable: *" *' *` ---
      English.pm aliases the interpolation variables this way, and without
      this the bare quote would open a string that never closes. }
    if (C = '*') and ExpectTerm and (Ch(i + 1) in ['"', '''', '`']) then
    begin
      Mark(i, i + 2, ptScalar);
      Inc(i, 2);
      ExpectTerm := False;
      PrintKw    := False;
      PrintFh    := False;
      LastKw     := '';
      Continue;
    end;

    { --- string literals --- }
    if C = '''' then
    begin
      RunQuote(i, qkSingle, qkSingle, False);
      if S.Mode <> pmNormal then Exit;
      LastKw := '';
      Continue;
    end;

    if C = '"' then
    begin
      RunQuote(i, qkDouble, qkDouble, False);
      if S.Mode <> pmNormal then Exit;
      LastKw := '';
      Continue;
    end;

    if C = '`' then
    begin
      RunQuote(i, qkBack, qkBack, False);
      if S.Mode <> pmNormal then Exit;
      LastKw := '';
      Continue;
    end;

    { --- here-documents ---
      Only where a term may begin, so that "1<<index($s,$c)" stays a left
      shift rather than opening a here-document called index. }
    if (C = '<') and (Ch(i + 1) = '<') and (ExpectTerm or PrintFh) then
      if TryHeredoc(i) then
      begin
        ExpectTerm := False;
        PrintKw    := False;
        PrintFh    := False;
        LastKw     := '';
        Continue;
      end;

    { --- a bare /regex/ where a term may start --- }
    if C = '/' then
    begin
      if ExpectTerm then
      begin
        RunQuote(i, qkRegex, qkRegex, False);
        if S.Mode <> pmNormal then Exit;
        LastKw := '';
        Continue;
      end;
      { Otherwise this is division, /= , or the defined-or // and //= .
        Taking both slashes at once matters: leaving the second one to the
        next pass would make it open a regex that never closes. }
      Toks[i] := ptOperator;
      Inc(i);
      if Ch(i) = '/' then
      begin
        Toks[i] := ptOperator;
        Inc(i);
      end;
      if Ch(i) = '=' then
      begin
        Toks[i] := ptOperator;
        Inc(i);
      end;
      ExpectTerm := True;
      LastKw := '';
      Continue;
    end;

    { --- everything else is punctuation --- }
    Toks[i] := ptOperator;
    ExpectTerm := not (C in [')', ']', '}']);
    LastKw := '';
    Inc(i);
  end;

  { A here-document introduced on this line has its body on the next. }
  if (S.Mode = pmNormal) and (S.HereCount > 0) then
    S.Mode := pmHeredoc;
end;

procedure HighlightLine(const Line; Len: Integer; var S: TPerlState;
                        out Toks: TTokLine; Truncated: Boolean = False);
begin
  ScanLine(Line, Len, S, Toks);

  { See the note on Truncated in the interface.  A line we could not read to
    the end may well have closed its quote in the part we never saw, so
    carrying that quote forward would paint the rest of the file as one long
    string.  A here-document queued from the part we did see is genuine and
    is left alone. }
  if Truncated and (S.Mode in [pmQuote, pmSeek]) then
  begin
    S.Mode       := pmNormal;
    S.HasPending := False;
    S.Depth      := 0;
    if S.HereCount > 0 then S.Mode := pmHeredoc;
  end;
end;

end.
