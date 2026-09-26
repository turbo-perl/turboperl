{ ========================================================================== }
{  TurboPerl - Unit: TPText                                                  }
{                                                                            }
{  The block operations, written as pure functions over a run of text.       }
{                                                                            }
{  Keeping them out of the editor object has two benefits: they can be       }
{  tested without a screen, and the editor can apply each one as a single    }
{  replacement, so a whole block comment is one undo step rather than one    }
{  per line.                                                                 }
{                                                                            }
{  Every function preserves the line endings it is given, including a        }
{  missing one on the last line.                                             }
{ ========================================================================== }
unit TPText;

{$mode objfpc}{$H-}

interface

uses SysUtils;

type
  TStringArray = array of AnsiString;

{ Put a # in front of every line, or take one off again.  Uncommenting also
  removes one space after the # so that a comment/uncomment round trip gets
  back to the original text. }
function CommentLines(const S: AnsiString; Comment: Boolean): AnsiString;

{ Shift every line right or left by Width columns.  Unindenting removes at
  most Width columns of leading whitespace, counting a tab as Width. }
function IndentLines(const S: AnsiString; Indent: Boolean;
                     Width: Integer; UseTab: Boolean): AnsiString;

{ Drop spaces and tabs at the end of every line. }
function StripTrailing(const S: AnsiString): AnsiString;

{ True when every non-blank line already starts with a #. }
function AllCommented(const S: AnsiString): Boolean;

{ Split off the line ending at the front of S starting at P, returning ''
  when there is none.  Advances P past it. }
function TakeEOL(const S: AnsiString; var P: Integer): AnsiString;

{ Split a command line into arguments the way a shell would: whitespace
  separates, single and double quotes group, and a backslash escapes the
  next character outside single quotes.  Count comes back as the number of
  arguments written into Args. }
procedure SplitArgs(const S: AnsiString; out Args: TStringArray;
                    out Count: Integer);

implementation

procedure SplitArgs(const S: AnsiString; out Args: TStringArray;
                    out Count: Integer);
var
  i    : Integer;
  Cur  : AnsiString;
  Have : Boolean;      { True once the current argument has been started, so
                         that an explicit empty '' becomes an argument }
  Quote: Char;

  procedure Flush;
  begin
    if not Have then Exit;
    if Count >= Length(Args) then SetLength(Args, Length(Args) * 2 + 8);
    Args[Count] := Cur;
    Inc(Count);
    Cur  := '';
    Have := False;
  end;

begin
  Args  := nil;
  Count := 0;
  SetLength(Args, 8);
  Cur   := '';
  Have  := False;
  Quote := #0;
  i := 1;

  while i <= Length(S) do
  begin
    if Quote <> #0 then
    begin
      if S[i] = Quote then
        Quote := #0
      else if (Quote = '"') and (S[i] = '\') and (i < Length(S)) then
      begin
        Inc(i);
        Cur := Cur + S[i];
      end
      else
        Cur := Cur + S[i];
      Inc(i);
      Continue;
    end;

    case S[i] of
      ' ', #9, #10, #13:
        Flush;
      '''', '"':
        begin
          Quote := S[i];
          Have  := True;
        end;
      '\':
        begin
          Have := True;
          if i < Length(S) then
          begin
            Inc(i);
            Cur := Cur + S[i];
          end;
        end;
    else
      begin
        Have := True;
        Cur  := Cur + S[i];
      end;
    end;
    Inc(i);
  end;

  Flush;
  SetLength(Args, Count);
end;

function TakeEOL(const S: AnsiString; var P: Integer): AnsiString;
begin
  Result := '';
  if P > Length(S) then Exit;
  if S[P] = #13 then
  begin
    Result := #13;
    Inc(P);
    if (P <= Length(S)) and (S[P] = #10) then
    begin
      Result := Result + #10;
      Inc(P);
    end;
  end
  else if S[P] = #10 then
  begin
    Result := #10;
    Inc(P);
  end;
end;

{ Walk S line by line, handing each line's text and its terminator to the
  caller through the out parameters. }
function NextLine(const S: AnsiString; var P: Integer;
                  out Text, EOL: AnsiString): Boolean;
var
  Start: Integer;
begin
  if P > Length(S) then Exit(False);
  Start := P;
  while (P <= Length(S)) and (S[P] <> #10) and (S[P] <> #13) do Inc(P);
  Text := Copy(S, Start, P - Start);
  EOL  := TakeEOL(S, P);
  Result := True;
end;

function FirstNonBlank(const L: AnsiString): Integer;
begin
  Result := 1;
  while (Result <= Length(L)) and ((L[Result] = ' ') or (L[Result] = #9)) do
    Inc(Result);
end;

function AllCommented(const S: AnsiString): Boolean;
var
  P, NB: Integer;
  Text, EOL: AnsiString;
  Any: Boolean;
begin
  P := 1;
  Any := False;
  while NextLine(S, P, Text, EOL) do
  begin
    if Trim(Text) = '' then Continue;
    Any := True;
    NB := FirstNonBlank(Text);
    if (NB > Length(Text)) or (Text[NB] <> '#') then Exit(False);
  end;
  Result := Any;
end;

function CommentLines(const S: AnsiString; Comment: Boolean): AnsiString;
var
  P, NB, Cut: Integer;
  Text, EOL : AnsiString;
begin
  Result := '';
  P := 1;
  while NextLine(S, P, Text, EOL) do
  begin
    if Comment then
    begin
      { Blank lines are left alone: commenting them out adds noise and the
        uncomment pass would not know to take it away again. }
      if Trim(Text) <> '' then Text := '# ' + Text;
    end
    else
    begin
      NB := FirstNonBlank(Text);
      if (NB <= Length(Text)) and (Text[NB] = '#') then
      begin
        Cut := 1;
        if (NB + 1 <= Length(Text)) and (Text[NB + 1] = ' ') then Cut := 2;
        Delete(Text, NB, Cut);
      end;
    end;
    Result := Result + Text + EOL;
  end;
end;

function IndentLines(const S: AnsiString; Indent: Boolean;
                     Width: Integer; UseTab: Boolean): AnsiString;
var
  P, i, Removed: Integer;
  Text, EOL, Pad: AnsiString;
begin
  Result := '';
  if Width < 1 then Width := 1;
  if UseTab then Pad := #9 else Pad := StringOfChar(' ', Width);

  P := 1;
  while NextLine(S, P, Text, EOL) do
  begin
    if Indent then
    begin
      if Trim(Text) <> '' then Text := Pad + Text;
    end
    else
    begin
      { Take away up to Width columns of leading whitespace.  A tab counts
        for the whole width, which matches how it is displayed. }
      Removed := 0;
      i := 1;
      while (i <= Length(Text)) and (Removed < Width) do
      begin
        if Text[i] = ' ' then
        begin
          Inc(Removed);
          Inc(i);
        end
        else if Text[i] = #9 then
        begin
          Inc(Removed, Width);
          Inc(i);
        end
        else
          Break;
      end;
      if i > 1 then Delete(Text, 1, i - 1);
    end;
    Result := Result + Text + EOL;
  end;
end;

function StripTrailing(const S: AnsiString): AnsiString;
var
  P, L: Integer;
  Text, EOL: AnsiString;
begin
  Result := '';
  P := 1;
  while NextLine(S, P, Text, EOL) do
  begin
    L := Length(Text);
    while (L > 0) and ((Text[L] = ' ') or (Text[L] = #9)) do Dec(L);
    SetLength(Text, L);
    Result := Result + Text + EOL;
  end;
end;

end.
