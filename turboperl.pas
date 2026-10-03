{ ========================================================================== }
{  TurboPerl - a Turbo Pascal style IDE for Perl, built with Free Pascal     }
{  and the Free Vision text mode UI framework.                               }
{                                                                            }
{      turboperl [options] [file ...]                                        }
{                                                                            }
{  Run "turboperl --help" for the options.                                   }
{ ========================================================================== }
program TurboPerl;

{$mode objfpc}{$H-}

uses
  { First, so that on Windows its initialisation runs before the video
    unit's: see TPWinCon. }
  {$IFDEF MSWINDOWS} TPWinCon, {$ENDIF}
  SysUtils,
  TPConst, TPConfig, TPApp;

var
  TheApp : TTurboPerl;
  Files  : array of AnsiString;

procedure Usage;
begin
  WriteLn(TPTitle, ' ', TPVersion, ' - ', TPCopyright);
  WriteLn;
  WriteLn('usage: turboperl [options] [file ...]');
  WriteLn;
  WriteLn('  -h, --help       show this and exit');
  WriteLn('  -v, --version    show the version and exit');
  WriteLn('      --perl PATH  use this perl for this session');
  WriteLn('      --no-hilite  start with syntax highlighting off');
  WriteLn;
  WriteLn('Settings live in ', ConfigFileName, ' and are written by');
  WriteLn('Options / Save options inside the IDE.');
  WriteLn;
  WriteLn('Keys:  F2 save   F3 open   F9 syntax check   Ctrl-F9 run');
  WriteLn('       F10 menu  Alt-F3 close window         Alt-X exit');
end;

{ Read the command line before the screen is taken over, so that --help and
  any complaint about a bad option land on the terminal as plain text. }
function ParseCommandLine: Boolean;
var
  i: Integer;
  A: AnsiString;
  OverridePerl: AnsiString;
  NoHilite: Boolean;
begin
  Result       := False;
  OverridePerl := '';
  NoHilite     := False;
  SetLength(Files, 0);

  i := 1;
  while i <= ParamCount do
  begin
    A := ParamStr(i);
    if (A = '-h') or (A = '--help') then
    begin
      Usage;
      Exit;
    end
    else if (A = '-v') or (A = '--version') then
    begin
      WriteLn(TPTitle, ' ', TPVersion);
      Exit;
    end
    else if A = '--perl' then
    begin
      Inc(i);
      if i > ParamCount then
      begin
        WriteLn('turboperl: --perl needs a path');
        Exit;
      end;
      OverridePerl := ParamStr(i);
    end
    else if A = '--no-hilite' then
      NoHilite := True
    else if (Length(A) > 1) and (A[1] = '-') then
    begin
      WriteLn('turboperl: unknown option ', A);
      WriteLn('try turboperl --help');
      Exit;
    end
    else
    begin
      SetLength(Files, Length(Files) + 1);
      Files[High(Files)] := A;
    end;
    Inc(i);
  end;

  { The settings file is read by the application's constructor, so stash the
    overrides and apply them once it has. }
  LoadConfig;
  if OverridePerl <> '' then Cfg.PerlExe := OverridePerl;
  if NoHilite then Cfg.Highlight := False;

  if Cfg.PerlExe = '' then
    WriteLn('turboperl: warning - no perl found on PATH; set one under Options/Perl.');

  Result := True;
end;

var
  i: Integer;
  SavedPerl: AnsiString;
  SavedHilite: Boolean;
begin
  if not ParseCommandLine then Halt(0);

  SavedPerl   := Cfg.PerlExe;
  SavedHilite := Cfg.Highlight;

  TheApp.Init;

  { Init re-reads the settings file, so put the command line back on top. }
  Cfg.PerlExe   := SavedPerl;
  Cfg.Highlight := SavedHilite;

  for i := 0 to High(Files) do
    TheApp.OpenNamed(Files[i]);

  TheApp.Run;
  TheApp.Done;
end.
