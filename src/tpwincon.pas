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
  Con := GetStdHandle(STD_OUTPUT_HANDLE);
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

end.
