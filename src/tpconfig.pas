{ ========================================================================== }
{  TurboPerl - Unit: TPConfig                                                }
{                                                                            }
{  Settings, and the plain text file they are kept in (~/.turboperlrc).      }
{  The format is one key = value per line with # comments, so it stays       }
{  readable and editable outside the IDE.                                    }
{ ========================================================================== }
unit TPConfig;

{$mode objfpc}{$H-}

interface

uses
  SysUtils, Classes, TPConst;

type
  TRunMode = (rmCapture, rmConsole);

  TConfig = record
    { --- perl --- }
    PerlExe       : AnsiString;
    ScriptArgs    : AnsiString;     { command line handed to the script }
    WorkDir       : AnsiString;     { '' means the script's own directory }
    RunMode       : TRunMode;
    Unbuffer      : Boolean;        { autoflush the script's handles }
    RunTimeout    : Integer;        { seconds; 0 disables the limit }
    Warnings      : Boolean;        { add -w when running }
    IncludeDirs   : AnsiString;     { separated like PATH, added with -I }

    { --- editor --- }
    TabSize       : Integer;
    AutoIndent    : Boolean;
    BackupFiles   : Boolean;
    UseTabChar    : Boolean;        { insert a real tab instead of spaces }

    { --- display --- }
    Highlight     : Boolean;
    Scheme        : Integer;        { 0 classic, 1 quiet, 2 custom }
    Colours       : array[TPerlTok] of Byte;

    { --- external tools --- }
    TidyExe       : AnsiString;
    TidyArgs      : AnsiString;
    CriticExe     : AnsiString;
    CriticSeverity: Integer;

    { --- installation --- }
    LibDir        : AnsiString;     { holds TurboPerl/Unbuffer.pm }
  end;

var
  Cfg: TConfig;

procedure DefaultConfig;
function  ConfigFileName: AnsiString;
function  LoadConfig: Boolean;
function  SaveConfig: Boolean;

{ The foreground colour actually in force for a token kind. }
function TokColour(T: TPerlTok): Byte;

{ Where the bundled perl library lives, '' when it cannot be found. }
function DetectLibDir: AnsiString;

implementation

uses
  TPPerl;

{ -------------------------------------------------------------------------- }

function DetectLibDir: AnsiString;
var
  Base: AnsiString;

  function HasLib(const D: AnsiString): Boolean;
  begin
    Result := FileExists(IncludeTrailingPathDelimiter(D) +
                         'TurboPerl' + PathDelim + 'Unbuffer.pm');
  end;

begin
  Result := '';
  Base := ExtractFilePath(ExpandFileName(ParamStr(0)));
  if Base = '' then Exit;

  { Running from the build tree, and the two usual installed layouts. }
  if HasLib(Base + 'lib') then Exit(Base + 'lib');
  if HasLib(Base + '..' + PathDelim + 'lib') then
    Exit(ExpandFileName(Base + '..' + PathDelim + 'lib'));
  if HasLib(Base + '..' + PathDelim + 'share' + PathDelim + 'turboperl' +
         PathDelim + 'lib') then
    Exit(ExpandFileName(Base + '..' + PathDelim + 'share' + PathDelim +
                        'turboperl' + PathDelim + 'lib'));
end;

procedure DefaultConfig;
var
  T: TPerlTok;
begin
  FillChar(Cfg, SizeOf(Cfg), 0);

  Cfg.PerlExe     := FindOnPath('perl');
  if Cfg.PerlExe = '' then Cfg.PerlExe := 'perl';
  Cfg.ScriptArgs  := '';
  Cfg.WorkDir     := '';
  Cfg.RunMode     := rmCapture;
  Cfg.Unbuffer    := True;
  Cfg.RunTimeout  := 60;
  Cfg.Warnings    := False;
  Cfg.IncludeDirs := '';

  Cfg.TabSize     := 4;
  Cfg.AutoIndent  := True;
  Cfg.BackupFiles := True;
  Cfg.UseTabChar  := False;

  Cfg.Highlight   := True;
  Cfg.Scheme      := 0;
  for T := Low(TPerlTok) to High(TPerlTok) do
    Cfg.Colours[T] := DefaultScheme[T];

  Cfg.TidyExe        := FindOnPath('perltidy');
  Cfg.TidyArgs       := '-q';
  Cfg.CriticExe      := FindOnPath('perlcritic');
  Cfg.CriticSeverity := 3;

  Cfg.LibDir := DetectLibDir;
end;

function TokColour(T: TPerlTok): Byte;
begin
  case Cfg.Scheme of
    0: Result := DefaultScheme[T];
    1: Result := MonoScheme[T];
  else
    Result := Cfg.Colours[T];
  end;
  Result := Result and $0F;
end;

{ -------------------------------------------------------------------------- }

function ConfigFileName: AnsiString;
var
  Home: AnsiString;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then Home := GetCurrentDir;
  Result := IncludeTrailingPathDelimiter(Home) + '.turboperlrc';
end;

function BoolStr(B: Boolean): AnsiString;
begin
  if B then Result := 'yes' else Result := 'no';
end;

function StrBool(const S: AnsiString; Def: Boolean): Boolean;
var
  L: AnsiString;
begin
  L := LowerCase(Trim(S));
  if (L = 'yes') or (L = 'true') or (L = '1') or (L = 'on') then
    Result := True
  else if (L = 'no') or (L = 'false') or (L = '0') or (L = 'off') then
    Result := False
  else
    Result := Def;
end;

function StrInt(const S: AnsiString; Def: Integer): Integer;
var
  V, Code: Integer;
begin
  Val(Trim(S), V, Code);
  if Code = 0 then Result := V else Result := Def;
end;

function LoadConfig: Boolean;
var
  F      : TextFile;
  Line   : AnsiString;
  Key, V : AnsiString;
  Eq     : Integer;
  T      : TPerlTok;
  Found  : Boolean;
begin
  DefaultConfig;
  Result := False;
  if not FileExists(ConfigFileName) then Exit;

  AssignFile(F, ConfigFileName);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not EOF(F) do
  begin
    {$I-}
    ReadLn(F, Line);
    {$I+}
    if IOResult <> 0 then Break;

    Line := Trim(Line);
    if (Line = '') or (Line[1] = '#') or (Line[1] = ';') then Continue;
    Eq := Pos('=', Line);
    if Eq = 0 then Continue;
    Key := LowerCase(Trim(Copy(Line, 1, Eq - 1)));
    { The rest of the line is the value, in full: a path may legitimately
      contain a #, so trailing comments are not recognised.  SaveConfig
      therefore always writes comments on lines of their own. }
    V   := Trim(Copy(Line, Eq + 1, Length(Line)));

    if      Key = 'perl'            then Cfg.PerlExe        := V
    else if Key = 'args'            then Cfg.ScriptArgs     := V
    else if Key = 'workdir'         then Cfg.WorkDir        := V
    else if Key = 'runmode'         then
      begin
        if LowerCase(V) = 'console' then Cfg.RunMode := rmConsole
                                    else Cfg.RunMode := rmCapture;
      end
    else if Key = 'unbuffer'        then Cfg.Unbuffer       := StrBool(V, True)
    else if Key = 'timeout'         then Cfg.RunTimeout     := StrInt(V, 60)
    else if Key = 'warnings'        then Cfg.Warnings       := StrBool(V, False)
    else if Key = 'includedirs'     then Cfg.IncludeDirs    := V
    else if Key = 'tabsize'         then Cfg.TabSize        := StrInt(V, 4)
    else if Key = 'autoindent'      then Cfg.AutoIndent     := StrBool(V, True)
    else if Key = 'backup'          then Cfg.BackupFiles    := StrBool(V, True)
    else if Key = 'usetabchar'      then Cfg.UseTabChar     := StrBool(V, False)
    else if Key = 'highlight'       then Cfg.Highlight      := StrBool(V, True)
    else if Key = 'scheme'          then Cfg.Scheme         := StrInt(V, 0)
    else if Key = 'tidy'            then Cfg.TidyExe        := V
    else if Key = 'tidyargs'        then Cfg.TidyArgs       := V
    else if Key = 'critic'          then Cfg.CriticExe      := V
    else if Key = 'criticseverity'  then Cfg.CriticSeverity := StrInt(V, 3)
    else if Key = 'libdir'          then Cfg.LibDir         := V
    else
    begin
      { colour.<token> = <0..15> }
      if Copy(Key, 1, 7) = 'colour.' then
      begin
        Found := False;
        for T := Low(TPerlTok) to High(TPerlTok) do
          if LowerCase(TokName[T]) = Copy(Key, 8, Length(Key)) then
          begin
            Cfg.Colours[T] := StrInt(V, DefaultScheme[T]) and $0F;
            Found := True;
            Break;
          end;
        if not Found then ;      { unknown key: left alone }
      end;
    end;
  end;

  {$I-}
  CloseFile(F);
  {$I+}
  if IOResult <> 0 then ;

  if Cfg.TabSize  < 1  then Cfg.TabSize := 1;
  if Cfg.TabSize  > 16 then Cfg.TabSize := 16;
  if Cfg.Scheme   < 0  then Cfg.Scheme  := 0;
  if Cfg.Scheme   > 2  then Cfg.Scheme  := 0;
  if Cfg.LibDir   = '' then Cfg.LibDir  := DetectLibDir;

  Result := True;
end;

function SaveConfig: Boolean;
var
  F: TextFile;
  T: TPerlTok;
begin
  Result := False;
  AssignFile(F, ConfigFileName);
  {$I-}
  Rewrite(F);
  {$I+}
  if IOResult <> 0 then Exit;

  WriteLn(F, '# TurboPerl ', TPVersion, ' settings.');
  WriteLn(F, '# Written by Options/Save, and re-read at start up.');
  WriteLn(F);
  WriteLn(F, '# --- perl ---');
  WriteLn(F, 'perl           = ', Cfg.PerlExe);
  WriteLn(F, 'args           = ', Cfg.ScriptArgs);
  WriteLn(F, '# workdir: blank means the directory the script lives in');
  WriteLn(F, 'workdir        = ', Cfg.WorkDir);
  WriteLn(F, '# runmode: capture (output into a window) or console');
  if Cfg.RunMode = rmConsole then
    WriteLn(F, 'runmode        = console')
  else
    WriteLn(F, 'runmode        = capture');
  WriteLn(F, 'unbuffer       = ', BoolStr(Cfg.Unbuffer));
  WriteLn(F, '# timeout is in seconds; 0 removes the limit');
  WriteLn(F, 'timeout        = ', Cfg.RunTimeout);
  WriteLn(F, '# warnings passes -w to perl');
  WriteLn(F, 'warnings       = ', BoolStr(Cfg.Warnings));
  WriteLn(F, '# includedirs is passed as -I, separated the way this system');
  WriteLn(F, '# separates PATH (a ', PathSeparator, ')');
  WriteLn(F, 'includedirs    = ', Cfg.IncludeDirs);
  WriteLn(F);
  WriteLn(F, '# --- editor ---');
  WriteLn(F, 'tabsize        = ', Cfg.TabSize);
  WriteLn(F, 'autoindent     = ', BoolStr(Cfg.AutoIndent));
  WriteLn(F, 'backup         = ', BoolStr(Cfg.BackupFiles));
  WriteLn(F, 'usetabchar     = ', BoolStr(Cfg.UseTabChar));
  WriteLn(F);
  WriteLn(F, '# --- display ---');
  WriteLn(F, 'highlight      = ', BoolStr(Cfg.Highlight));
  WriteLn(F, '# scheme: 0 classic, 1 quiet, 2 custom');
  WriteLn(F, 'scheme         = ', Cfg.Scheme);
  WriteLn(F, '# custom colours are used when scheme = 2; values are 0..15');
  for T := Low(TPerlTok) to High(TPerlTok) do
    WriteLn(F, 'colour.', LowerCase(TokName[T]),
            StringOfChar(' ', 9 - Length(TokName[T])), '= ', Cfg.Colours[T]);
  WriteLn(F);
  WriteLn(F, '# --- external tools ---');
  WriteLn(F, 'tidy           = ', Cfg.TidyExe);
  WriteLn(F, 'tidyargs       = ', Cfg.TidyArgs);
  WriteLn(F, 'critic         = ', Cfg.CriticExe);
  WriteLn(F, 'criticseverity = ', Cfg.CriticSeverity);
  WriteLn(F);
  WriteLn(F, '# --- installation ---');
  WriteLn(F, '# libdir holds TurboPerl/Unbuffer.pm; blank lets the IDE look for it');
  WriteLn(F, 'libdir         = ', Cfg.LibDir);

  {$I-}
  CloseFile(F);
  {$I+}
  Result := IOResult = 0;
end;

initialization
  DefaultConfig;

end.
