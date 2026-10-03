{ ========================================================================== }
{  TurboPerl - Unit: TPWinCon                                                }
{                                                                            }
{  The Windows console's own ways of doing what a Unix terminal is asked to  }
{  do with escape sequences.  The console does not take them by default -    }
{  it prints them - so it is asked through its API instead.                  }
{                                                                            }
{  Kept apart from TPApp because the Windows unit would hide Free Vision's   }
{  own TRect, MessageBox and friends there.                                  }
{ ========================================================================== }
unit TPWinCon;

{$mode objfpc}{$H+}

interface

{ Give the console's sixteen colours the given values, as $RRGGBB in ANSI
  order (red is 1, blue is 4), saving the console's own to put back.  False
  if the console would not have them. }
function SetConsolePalette(const RGB: array of LongWord): Boolean;

{ Put back the colours SetConsolePalette replaced. }
procedure RestoreConsolePalette;

{ The console's answer to a terminal's alternate screen: a screen buffer of
  the IDE's own, so that the console's - the shell's history, and the
  output of console runs - is left as it was underneath.

  Free Pascal's video unit draws on whatever the standard output was when
  it was initialised, and keeps that to itself, so the buffer is made, and
  made the standard output, in this unit's initialisation - which is why
  this has to be the first unit the program uses.  It is not shown until
  UseOwnScreen, so anything printed before the IDE starts, such as --help,
  still reaches the console.  ShowConsole and ShowOwnScreen switch between the two,
  for console runs and the user screen; while the console is showing it
  takes escape sequences, as a terminal would.  However the IDE ends, the
  console is shown again.  False from UseOwnScreen leaves everything on the
  one buffer, as it was. }
function UseOwnScreen: Boolean;
procedure ShowConsole;
procedure ShowOwnScreen;

implementation

uses
  Windows;

{ Not in Free Pascal 3.2.2's Windows unit. }
{$push}{$packrecords c}
type
  TConsoleScreenBufferInfoEx = record
    cbSize               : ULONG;
    dwSize               : TCoord;
    dwCursorPosition     : TCoord;
    wAttributes          : Word;
    srWindow             : TSmallRect;
    dwMaximumWindowSize  : TCoord;
    wPopupAttributes     : Word;
    bFullscreenSupported : BOOL;
    ColorTable           : array[0..15] of COLORREF;
  end;
{$pop}

function GetConsoleScreenBufferInfoEx(hConsoleOutput: THandle;
  var Info: TConsoleScreenBufferInfoEx): BOOL; stdcall;
  external 'kernel32.dll' name 'GetConsoleScreenBufferInfoEx';
function SetConsoleScreenBufferInfoEx(hConsoleOutput: THandle;
  var Info: TConsoleScreenBufferInfoEx): BOOL; stdcall;
  external 'kernel32.dll' name 'SetConsoleScreenBufferInfoEx';

{ In it, but with the security attributes a var, where nil is wanted. }
function CreateConsoleScreenBuffer(dwDesiredAccess, dwShareMode: DWORD;
  lpSecurityAttributes: Pointer; dwFlags: DWORD;
  lpScreenBufferData: Pointer): THandle; stdcall;
  external 'kernel32.dll' name 'CreateConsoleScreenBuffer';

var
  Saved     : array[0..15] of COLORREF;
  HaveSaved : Boolean = False;

{ The console numbers its colours the way the VGA did, with blue as 1 and
  red as 4; ANSI has them the other way round. }
const
  AnsiToConsole: array[0..15] of Integer =
    (0, 4, 2, 6, 1, 5, 3, 7, 8, 12, 10, 14, 9, 13, 11, 15);

function Apply(const Table: array of COLORREF): Boolean;
var
  Con: THandle;
  Info: TConsoleScreenBufferInfoEx;
  i: Integer;
begin
  Result := False;
  { The buffer being drawn on, which may be the IDE's own. }
  Con := TextRec(Output).Handle;
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  if not GetConsoleScreenBufferInfoEx(Con, Info) then Exit;
  if not HaveSaved then
  begin
    Move(Info.ColorTable, Saved, SizeOf(Saved));
    HaveSaved := True;
  end;
  for i := 0 to 15 do Info.ColorTable[i] := Table[i];
  { Setting the information back shrinks the window by a row and a column:
    the call takes srWindow as exclusive where the one that read it gave
    it inclusive. }
  Inc(Info.srWindow.Right);
  Inc(Info.srWindow.Bottom);
  Result := SetConsoleScreenBufferInfoEx(Con, Info);
end;

function SetConsolePalette(const RGB: array of LongWord): Boolean;
var
  Table: array[0..15] of COLORREF;
  i: Integer;
begin
  Result := False;
  if Length(RGB) <> 16 then Exit;
  { $RRGGBB to COLORREF's $00BBGGRR. }
  for i := 0 to 15 do
    Table[AnsiToConsole[i]] := ((RGB[i] shr 16) and $FF) or
                               (RGB[i] and $FF00) or
                               ((RGB[i] and $FF) shl 16);
  Result := Apply(Table);
end;

procedure RestoreConsolePalette;
begin
  if HaveSaved then Apply(Saved);
end;

{ -------------------------------------------------------------------------- }

const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;

var
  ConsoleBuf : THandle = 0;    { the shell's, as we found it }
  OwnBuf     : THandle = 0;    { the IDE's }
  ConsoleMode: DWORD = 0;
  HaveMode   : Boolean = False;

{ Show Buf, and write on it.  Output is where WriteLn goes. }
procedure Point(Buf: THandle);
begin
  TextRec(Output).Handle := Buf;
  SetConsoleActiveScreenBuffer(Buf);
end;

{ Made at initialisation, before the video unit takes the standard output
  for its own.  Only for a console: with output to a pipe or a file there
  is no screen to keep. }
procedure MakeOwnBuffer;
var
  Info: TConsoleScreenBufferInfo;
  Size: TCoord;
begin
  ConsoleBuf := GetStdHandle(STD_OUTPUT_HANDLE);
  if not GetConsoleScreenBufferInfo(ConsoleBuf, Info) then Exit;
  OwnBuf := CreateConsoleScreenBuffer(GENERIC_READ or GENERIC_WRITE,
                                      FILE_SHARE_READ or FILE_SHARE_WRITE,
                                      nil, CONSOLE_TEXTMODE_BUFFER, nil);
  if OwnBuf = INVALID_HANDLE_VALUE then
  begin
    OwnBuf := 0;
    Exit;
  end;
  { Exactly the console\x27s window, so the IDE has no scroll bars to show. }
  Size.X := Info.srWindow.Right - Info.srWindow.Left + 1;
  Size.Y := Info.srWindow.Bottom - Info.srWindow.Top + 1;
  SetConsoleScreenBufferSize(OwnBuf, Size);
  SetStdHandle(STD_OUTPUT_HANDLE, OwnBuf);
end;

function UseOwnScreen: Boolean;
begin
  Result := OwnBuf <> 0;
  if Result then Point(OwnBuf);
end;

{ Programs run on the console inherit the standard output, so while the
  console is showing that is the console\x27s again. }
procedure ShowConsole;
begin
  if OwnBuf = 0 then Exit;
  SetStdHandle(STD_OUTPUT_HANDLE, ConsoleBuf);
  Point(ConsoleBuf);
  HaveMode := GetConsoleMode(ConsoleBuf, ConsoleMode);
  if HaveMode then
    SetConsoleMode(ConsoleBuf, ConsoleMode or ENABLE_VIRTUAL_TERMINAL_PROCESSING);
end;

procedure ShowOwnScreen;
begin
  if OwnBuf = 0 then Exit;
  if HaveMode then SetConsoleMode(ConsoleBuf, ConsoleMode);
  HaveMode := False;
  SetStdHandle(STD_OUTPUT_HANDLE, OwnBuf);
  Point(OwnBuf);
end;

initialization
  MakeOwnBuffer;

finalization
  if OwnBuf <> 0 then
  begin
    if HaveMode then SetConsoleMode(ConsoleBuf, ConsoleMode);
    SetStdHandle(STD_OUTPUT_HANDLE, ConsoleBuf);
    Point(ConsoleBuf);
    CloseHandle(OwnBuf);
  end;
end.
