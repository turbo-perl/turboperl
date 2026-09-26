{ ========================================================================== }
{  TurboPerl - Unit: TPEdit                                                  }
{                                                                            }
{  The Perl source editor and the window that holds it.                      }
{                                                                            }
{  TPerlEditor extends Free Vision's TFileEditor with                        }
{    - syntax highlighting, by overriding the virtual FormatLine             }
{    - block comment / indent / strip operations                             }
{    - go to line, and the word under the cursor for perldoc                 }
{                                                                            }
{  Free Vision keeps its line walking helpers (LineStart, NextLine, LineNr)  }
{  private to the editors unit, so the equivalents here are built on the      }
{  public BufChar, which knows how to read across the gap in the buffer.     }
{ ========================================================================== }
unit TPEdit;

{$mode objfpc}{$H-}

interface

uses
  Objects, Drivers, Views, Editors, FVConsts,
  SysUtils,
  TPConst, TPHilite, TPConfig, TPText;

const
  { One entry per screen column of a formatted line. }
  MaxCells = MaxHiliteLine;

type
  PPerlEditor = ^TPerlEditor;
  TPerlEditor = object(TFileEditor)
  public
    constructor Init(var Bounds: TRect; AHScrollBar, AVScrollBar: PScrollBar;
                     AIndicator: PIndicator; AFileName: FNameStr);

    procedure Draw; virtual;
    procedure FormatLine(var DrawBuf; LinePtr: Sw_Word; Width: Sw_Integer;
                         Colors: Word); virtual;
    procedure HandleEvent(var Event: TEvent); virtual;

    { --- text access --- }
    function  GetRange(A, B: Sw_Word): AnsiString;
    function  WholeText: AnsiString;
    procedure ReplaceRange(A, B: Sw_Word; const NewText: AnsiString);
    procedure ReplaceAll(const NewText: AnsiString);

    { --- positions --- }
    function  LineStartOf(P: Sw_Word): Sw_Word;
    function  NextLineStart(P: Sw_Word): Sw_Word;
    function  LineIndexOf(P: Sw_Word): Integer;          { 0 based }
    function  StartOfLine(Index: Integer): Sw_Word;      { 0 based }
    function  CurrentLineNo: Integer;                    { 1 based }
    function  CurrentLineText: AnsiString;
    function  WordAtCursor: AnsiString;
    procedure GotoLine(N: Integer);                      { 1 based }

    { --- block operations --- }
    procedure BlockComment(Comment: Boolean);
    procedure BlockIndent(Indent: Boolean);
    procedure BlockStripTrailing;

    procedure ApplyConfig;
    procedure InvalidateHighlight;

  private
    { Set when a shifted cursor key turned Selecting on, so that the next
      unshifted cursor key can turn it off again without disturbing the
      Ctrl-K B style persistent block marking. }
    FShiftSel : Boolean;

    { Cached scanner state.  FStPtr is the buffer offset the state applies
      to, which lets consecutive lines of a redraw resume in constant time.
      See the comment on Draw for how staleness is avoided. }
    FStPtr   : Sw_Word;
    FStValid : Boolean;
    FState   : TPerlState;

    procedure ReadLine(P: Sw_Word; out Raw; out RawLen: Integer;
                       out EolPos: Sw_Word; out Truncated: Boolean);
    procedure StateAt(Target: Sw_Word; out St: TPerlState);
    procedure SelectedLineRange(out A, B: Sw_Word);
  end;

  PPerlEditWindow = ^TPerlEditWindow;
  TPerlEditWindow = object(TWindow)
    Editor: PPerlEditor;
    constructor Init(var Bounds: TRect; AFileName: FNameStr; ANumber: Integer);
    function  GetTitle(MaxSize: Sw_Integer): TTitleStr; virtual;
    procedure Close; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure SizeLimits(var Min, Max: TPoint); virtual;
  end;

{ The editor in the window that currently has the focus, or nil. }
function ActiveEditor: PPerlEditor;

implementation

uses
  App;

function ActiveEditor: PPerlEditor;
var
  W: PView;
begin
  Result := nil;
  if Desktop = nil then Exit;
  W := Desktop^.Current;
  if W = nil then Exit;
  if TypeOf(W^) = TypeOf(TPerlEditWindow) then
    Result := PPerlEditWindow(W)^.Editor;
end;

{ ========================================================================== }
{  TPerlEditor                                                               }
{ ========================================================================== }

constructor TPerlEditor.Init(var Bounds: TRect;
                             AHScrollBar, AVScrollBar: PScrollBar;
                             AIndicator: PIndicator; AFileName: FNameStr);
begin
  FStValid  := False;
  FStPtr    := 0;
  FShiftSel := False;
  InitPerlState(FState);
  inherited Init(Bounds, AHScrollBar, AVScrollBar, AIndicator, AFileName);
  ApplyConfig;
end;

procedure TPerlEditor.ApplyConfig;
begin
  TabSize    := Cfg.TabSize;
  AutoIndent := Cfg.AutoIndent;
  InvalidateHighlight;
end;

procedure TPerlEditor.InvalidateHighlight;
begin
  FStValid := False;
end;

{ -------------------------------------------------------------------------- }
{  Reading the buffer                                                         }
{ -------------------------------------------------------------------------- }

{ Copy the text of the line at P, without its terminator, into Raw.  EolPos
  comes back as the offset of the terminator (or of the end of the buffer). }
procedure TPerlEditor.ReadLine(P: Sw_Word; out Raw; out RawLen: Integer;
                               out EolPos: Sw_Word; out Truncated: Boolean);
var
  Dest: PChar;
  C   : Char;
begin
  Dest      := PChar(@Raw);
  RawLen    := 0;
  Truncated := False;
  while (P < BufLen) and (RawLen < MaxCells) do
  begin
    C := BufChar(P);
    if (C = #10) or (C = #13) then Break;
    Dest[RawLen] := C;
    Inc(RawLen);
    Inc(P);
  end;
  { A line longer than we can hold still has to report where it ends. }
  while (P < BufLen) do
  begin
    C := BufChar(P);
    if (C = #10) or (C = #13) then Break;
    Truncated := True;
    Inc(P);
  end;
  EolPos := P;
end;

function TPerlEditor.LineStartOf(P: Sw_Word): Sw_Word;
var
  C: Char;
begin
  if P > BufLen then P := BufLen;
  while P > 0 do
  begin
    C := BufChar(P - 1);
    if (C = #10) or (C = #13) then Break;
    Dec(P);
  end;
  Result := P;
end;

function TPerlEditor.NextLineStart(P: Sw_Word): Sw_Word;
var
  C: Char;
begin
  while P < BufLen do
  begin
    C := BufChar(P);
    Inc(P);
    if C = #13 then
    begin
      if (P < BufLen) and (BufChar(P) = #10) then Inc(P);
      Break;
    end
    else if C = #10 then
      Break;
  end;
  Result := P;
end;

function TPerlEditor.LineIndexOf(P: Sw_Word): Integer;
var
  Q: Sw_Word;
  N: Integer;
begin
  if P > BufLen then P := BufLen;
  Q := 0;
  N := 0;
  while Q < P do
  begin
    Q := NextLineStart(Q);
    if Q > P then Break;
    Inc(N);
    if Q = P then Break;
  end;
  Result := N;
end;

function TPerlEditor.StartOfLine(Index: Integer): Sw_Word;
var
  P, LastP: Sw_Word;
  N: Integer;
begin
  P := 0;
  N := 0;
  while (N < Index) and (P < BufLen) do
  begin
    LastP := P;
    P := NextLineStart(P);
    if P = LastP then Break;
    Inc(N);
  end;
  Result := P;
end;

function TPerlEditor.CurrentLineNo: Integer;
begin
  Result := LineIndexOf(CurPtr) + 1;
end;

function TPerlEditor.GetRange(A, B: Sw_Word): AnsiString;
var
  i: Sw_Word;
  N: SizeInt;
begin
  if B > BufLen then B := BufLen;
  if A > B then A := B;
  N := B - A;
  SetLength(Result, N);
  for i := 0 to N - 1 do
    Result[i + 1] := BufChar(A + i);
end;

function TPerlEditor.WholeText: AnsiString;
begin
  Result := GetRange(0, BufLen);
end;

function TPerlEditor.CurrentLineText: AnsiString;
var
  A: Sw_Word;
begin
  A := LineStartOf(CurPtr);
  Result := GetRange(A, NextLineStart(A));
  { drop the terminator }
  while (Length(Result) > 0) and
        ((Result[Length(Result)] = #10) or (Result[Length(Result)] = #13)) do
    SetLength(Result, Length(Result) - 1);
end;

function TPerlEditor.WordAtCursor: AnsiString;
var
  L: AnsiString;
  Col: Integer;

  function IsW(C: Char): Boolean;
  begin
    Result := (C = '_') or ((C >= 'A') and (C <= 'Z')) or
              ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'));
  end;

var
  A, B: Integer;
begin
  Result := '';
  L := CurrentLineText;
  Col := (CurPtr - LineStartOf(CurPtr)) + 1;
  if (L = '') or (Col > Length(L) + 1) then Exit;
  if Col > Length(L) then Col := Length(L);
  if Col < 1 then Col := 1;

  if (not IsW(L[Col])) and (Col > 1) and IsW(L[Col - 1]) then Dec(Col);
  if not IsW(L[Col]) then Exit;

  A := Col;
  while (A > 1) and IsW(L[A - 1]) do Dec(A);
  B := Col;
  while (B < Length(L)) and IsW(L[B + 1]) do Inc(B);

  { Take in the :: of a package name. }
  while (A > 2) and (L[A - 1] = ':') and (L[A - 2] = ':') do
  begin
    Dec(A, 2);
    while (A > 1) and IsW(L[A - 1]) do Dec(A);
  end;
  while (B + 2 <= Length(L)) and (L[B + 1] = ':') and (L[B + 2] = ':') do
  begin
    Inc(B, 2);
    while (B < Length(L)) and IsW(L[B + 1]) do Inc(B);
  end;

  Result := Copy(L, A, B - A + 1);
end;

procedure TPerlEditor.GotoLine(N: Integer);
var
  P: Sw_Word;
begin
  if N < 1 then N := 1;
  P := StartOfLine(N - 1);
  SetCurPtr(P, 0);
  TrackCursor(True);
  InvalidateHighlight;
  DrawView;
end;

{ -------------------------------------------------------------------------- }
{  Editing                                                                    }
{ -------------------------------------------------------------------------- }

procedure TPerlEditor.ReplaceRange(A, B: Sw_Word; const NewText: AnsiString);
var
  Ptr: Pointer;
begin
  if IsReadOnly then Exit;
  SetSelect(A, B, False);
  if NewText = '' then Ptr := nil else Ptr := @NewText[1];
  { InsertBuffer replaces the current selection, so this is a single
    edit and therefore a single undo step. }
  InsertText(Ptr, Length(NewText), False);
  InvalidateHighlight;
end;

procedure TPerlEditor.ReplaceAll(const NewText: AnsiString);
var
  SaveLine, SaveCol: Integer;
begin
  SaveLine := CurrentLineNo;
  SaveCol  := CurPtr - LineStartOf(CurPtr);
  ReplaceRange(0, BufLen, NewText);
  GotoLine(SaveLine);
  SetCurPtr(CurPtr + SaveCol, 0);
  TrackCursor(True);
  DrawView;
end;

{ The whole-line span the block operations act on: the lines touched by the
  selection, or the cursor's line when there is none. }
procedure TPerlEditor.SelectedLineRange(out A, B: Sw_Word);
begin
  if SelStart < SelEnd then
  begin
    A := LineStartOf(SelStart);
    B := SelEnd;
    { A selection ending exactly on a line start stops short of that line,
      which is what dragging down a column looks like it should do.
      Otherwise the partly covered last line is taken in whole. }
    if (B <= A) or (B <> LineStartOf(B)) then
      B := NextLineStart(B);
  end
  else
  begin
    A := LineStartOf(CurPtr);
    B := NextLineStart(A);
  end;
end;

procedure TPerlEditor.BlockComment(Comment: Boolean);
var
  A, B: Sw_Word;
  Old, New_: AnsiString;
begin
  SelectedLineRange(A, B);
  Old := GetRange(A, B);
  if Old = '' then Exit;
  New_ := CommentLines(Old, Comment);
  if New_ = Old then Exit;
  ReplaceRange(A, B, New_);
  SetSelect(A, A + Sw_Word(Length(New_)), False);
  DrawView;
end;

procedure TPerlEditor.BlockIndent(Indent: Boolean);
var
  A, B: Sw_Word;
  Old, New_: AnsiString;
begin
  SelectedLineRange(A, B);
  Old := GetRange(A, B);
  if Old = '' then Exit;
  New_ := IndentLines(Old, Indent, Cfg.TabSize, Cfg.UseTabChar);
  if New_ = Old then Exit;
  ReplaceRange(A, B, New_);
  SetSelect(A, A + Sw_Word(Length(New_)), False);
  DrawView;
end;

procedure TPerlEditor.BlockStripTrailing;
var
  Old, New_: AnsiString;
begin
  Old := WholeText;
  New_ := StripTrailing(Old);
  if New_ = Old then Exit;
  ReplaceAll(New_);
end;

{ -------------------------------------------------------------------------- }
{  Highlighting                                                               }
{ -------------------------------------------------------------------------- }

{ The scanner state at the start of the line beginning at Target.

  This walks the buffer from the top.  It is only reached for the first line
  of a redraw: every line after that resumes from the cached state, because
  FormatLine is called for consecutive lines. }
procedure TPerlEditor.StateAt(Target: Sw_Word; out St: TPerlState);
var
  Raw    : array[0..MaxCells - 1] of Char;
  Toks   : TTokLine;
  RawLen : Integer;
  Trunc  : Boolean;
  P, Eol, LastP: Sw_Word;
begin
  InitPerlState(St);
  P := 0;
  while P < Target do
  begin
    ReadLine(P, Raw, RawLen, Eol, Trunc);
    HighlightLine(Raw, RawLen, St, Toks, Trunc);
    LastP := P;
    P := NextLineStart(P);
    if P <= LastP then Break;          { defensive: never loop forever }
  end;
end;

procedure TPerlEditor.Draw;
begin
  { Any redraw may follow an edit, and Free Vision offers no hook that fires
    when the buffer changes (InsertBuffer and DeleteRange are not virtual).
    Dropping the cache here is what keeps the colours honest; the cost is one
    walk from the top of the buffer to the first visible line, after which
    the rest of the screen resumes incrementally. }
  FStValid := False;
  inherited Draw;
end;

procedure TPerlEditor.FormatLine(var DrawBuf; LinePtr: Sw_Word;
                                 Width: Sw_Integer; Colors: Word);
var
  Raw     : array[0..MaxCells - 1] of Char;
  Toks    : TTokLine;
  Cells   : array[0..MaxCells - 1] of Word;
  RawLen  : Integer;
  Trunc   : Boolean;
  EolPos  : Sw_Word;
  St      : TPerlState;
  NormAttr, SelAttr, BG, A: Byte;
  HasSel  : Boolean;
  DoHi    : Boolean;
  Col, k, n, j: Integer;
  Pos     : Sw_Word;
  Selected: Boolean;
  Out_    : PWord;
  Ofs, Vis: Integer;
begin
  if Width > MaxCells then Width := MaxCells;
  if Width < 0 then Width := 0;

  NormAttr := Lo(Colors);
  SelAttr  := Hi(Colors);
  BG       := NormAttr and $F0;
  HasSel   := SelStart < SelEnd;
  DoHi     := Cfg.Highlight;

  ReadLine(LinePtr, Raw, RawLen, EolPos, Trunc);

  if DoHi then
  begin
    if FStValid and (FStPtr = LinePtr) then
      St := FState
    else
      StateAt(LinePtr, St);

    HighlightLine(Raw, RawLen, St, Toks, Trunc);

    { Hand the resulting state to whichever line comes next. }
    FState   := St;
    FStPtr   := NextLineStart(LinePtr);
    FStValid := True;
  end;

  { --- lay the line out in screen columns --- }
  Col := 0;
  k := 0;
  while (k < RawLen) and (Col < Width) do
  begin
    Pos := LinePtr + Sw_Word(k);
    Selected := HasSel and (Pos >= SelStart) and (Pos < SelEnd);
    if Selected then
      A := SelAttr
    else if DoHi then
      A := BG or TokColour(Toks[k])
    else
      A := NormAttr;

    if Raw[k] = #9 then
    begin
      n := Integer(TabSize) - (Col mod Integer(TabSize));
      while (n > 0) and (Col < Width) do
      begin
        Cells[Col] := $20 or (Word(A) shl 8);
        Inc(Col);
        Dec(n);
      end;
    end
    else
    begin
      Cells[Col] := Word(Ord(Raw[k])) or (Word(A) shl 8);
      Inc(Col);
    end;
    Inc(k);
  end;

  { Trailing blanks take the selection colour when the line break itself is
    inside the selection, so a multi-line selection reads as one block. }
  Selected := HasSel and (EolPos >= SelStart) and (EolPos < SelEnd);
  if Selected then A := SelAttr else A := NormAttr;
  while Col < Width do
  begin
    Cells[Col] := $20 or (Word(A) shl 8);
    Inc(Col);
  end;

  { --- hand the visible window back to the caller ---

    TEditor.DrawLines declares its buffer as an array of Sw_Word but fills
    it with 16 bit character/attribute pairs, then passes B[Delta.X] to
    WriteBuf.  On a target where Sw_Word is wider than Word that index
    lands at the wrong byte, so a horizontally scrolled line comes out as
    rubbish.  Writing the visible columns at the offset the caller is
    really going to read from puts that right without touching the
    upstream unit. }
  Out_ := PWord(@DrawBuf);
  Ofs  := Integer(Delta.X) * (SizeOf(Sw_Word) div SizeOf(Word));
  Vis  := Width - Integer(Delta.X);
  if Vis < 0 then Vis := 0;
  if Ofs + Vis > 2 * MaxCells then
  begin
    { Cannot honour the stride; fall back to a plain layout. }
    Ofs := Integer(Delta.X);
    if Ofs + Vis > MaxCells then Vis := MaxCells - Ofs;
    if Vis < 0 then Vis := 0;
  end;

  for j := 0 to Vis - 1 do
    (Out_ + Ofs + j)^ := Cells[Integer(Delta.X) + j];
end;

{ -------------------------------------------------------------------------- }

{ Cursor movement keys, shifted or not. }
function IsMovementKey(Code: Word): Boolean;
begin
  case Code of
    kbUp, kbDown, kbLeft, kbRight, kbHome, kbEnd, kbPgUp, kbPgDn,
    kbCtrlUp, kbCtrlDown, kbCtrlLeft, kbCtrlRight,
    kbCtrlHome, kbCtrlEnd, kbCtrlPgUp, kbCtrlPgDn:
      Result := True;
  else
    Result := False;
  end;
end;

procedure TPerlEditor.HandleEvent(var Event: TEvent);
const
  ShiftMask = $03;          { Keyboard.kbShift: either shift key }
var
  Spaces: AnsiString;
  n: Integer;
begin
  { Selecting with Shift and the cursor keys.

    TEditor decides whether to extend the selection by calling
    Drivers.GetShiftState, which asks the keyboard driver for the shift keys
    held *right now*.  A terminal cannot answer that, so it always says no
    and shift-selection never works.  The shift state of the keystroke
    itself does arrive though, in Event.KeyShift, so we use that to drive
    the editor's own Selecting flag instead. }
  if (Event.What = evKeyDown) and IsMovementKey(Event.KeyCode) then
  begin
    if (Event.KeyShift and ShiftMask) <> 0 then
    begin
      Selecting := True;
      FShiftSel := True;
    end
    else if FShiftSel then
    begin
      Selecting := False;
      FShiftSel := False;
    end;
  end;

  { Soft tabs: insert enough spaces to reach the next tab stop.  Done before
    the inherited call so the editor never sees the tab itself. }
  if (Event.What = evKeyDown) and (Event.KeyCode = kbTab) and
     (not Cfg.UseTabChar) and (not IsReadOnly) then
  begin
    n := Integer(TabSize) - (CurPos.X mod Integer(TabSize));
    if n <= 0 then n := Integer(TabSize);
    Spaces := StringOfChar(' ', n);
    InsertText(@Spaces[1], n, False);
    InvalidateHighlight;
    ClearEvent(Event);
    Exit;
  end;

  if Event.What = evCommand then
    case Event.Command of
      cmCommentBlock   : begin BlockComment(True);   ClearEvent(Event); Exit; end;
      cmUncommentBlock : begin BlockComment(False);  ClearEvent(Event); Exit; end;
      cmIndentBlock    : begin BlockIndent(True);    ClearEvent(Event); Exit; end;
      cmUnindentBlock  : begin BlockIndent(False);   ClearEvent(Event); Exit; end;
      cmStripTrailing  : begin BlockStripTrailing;   ClearEvent(Event); Exit; end;
    end;

  inherited HandleEvent(Event);
end;

{ ========================================================================== }
{  TPerlEditWindow                                                           }
{ ========================================================================== }

constructor TPerlEditWindow.Init(var Bounds: TRect; AFileName: FNameStr;
                                 ANumber: Integer);
var
  HScroll : PScrollBar;
  VScroll : PScrollBar;
  Ind     : PIndicator;
  R       : TRect;
begin
  inherited Init(Bounds, '', ANumber);
  Options := Options or ofTileable;

  R.Assign(18, Size.Y - 1, Size.X - 2, Size.Y);
  HScroll := New(PScrollBar, Init(R));
  HScroll^.Hide;
  Insert(HScroll);

  R.Assign(Size.X - 1, 1, Size.X, Size.Y - 1);
  VScroll := New(PScrollBar, Init(R));
  VScroll^.Hide;
  Insert(VScroll);

  R.Assign(2, Size.Y - 1, 16, Size.Y);
  Ind := New(PIndicator, Init(R));
  Ind^.Hide;
  Insert(Ind);

  GetExtent(R);
  R.Grow(-1, -1);
  Editor := New(PPerlEditor, Init(R, HScroll, VScroll, Ind, AFileName));
  Insert(Editor);
end;

procedure TPerlEditWindow.Close;
begin
  { The clipboard lives for the whole session; closing it just puts it away. }
  if (Editor <> nil) and (Editors.Clipboard = PEditor(Editor)) then
    Hide
  else
    inherited Close;
end;

function TPerlEditWindow.GetTitle(MaxSize: Sw_Integer): TTitleStr;
var
  S: AnsiString;
begin
  if (Editor <> nil) and (Editors.Clipboard = PEditor(Editor)) then
    Exit('Clipboard');
  if (Editor = nil) or (Editor^.FileName = '') then
    Exit('Untitled');
  S := Editor^.FileName;
  { Show the tail of a long path rather than the head; the file name is the
    part that tells one window from another. }
  if Length(S) > MaxSize then
    S := '...' + Copy(S, Length(S) - MaxSize + 4, MaxSize - 3);
  Result := S;
end;

procedure TPerlEditWindow.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if Event.What = evBroadcast then
    case Event.Command of
      cmUpdateTitle:
        begin
          Frame^.DrawView;
          ClearEvent(Event);
        end;
    end;
end;

procedure TPerlEditWindow.SizeLimits(var Min, Max: TPoint);
begin
  inherited SizeLimits(Min, Max);
  Min.X := 24;
end;

end.
