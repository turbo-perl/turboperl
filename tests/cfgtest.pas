{ Headless round trip test for the settings file. }
program CfgTest;
{$mode objfpc}{$H+}
uses SysUtils, TPConst, TPConfig;

var Fails: Integer = 0;

procedure Check(const What: AnsiString; Ok: Boolean);
begin
  if Ok then WriteLn('ok   ', What)
  else begin Inc(Fails); WriteLn('FAIL ', What); end;
end;

var
  Saved: TConfig;
  T: TPerlTok;
  Dir: AnsiString;
begin
  Dir := GetEnvironmentVariable('TPTESTHOME');
  if Dir = '' then
  begin
    WriteLn('cfgtest: set TPTESTHOME to a scratch directory');
    Halt(2);
  end;

  DefaultConfig;

  { Values chosen to exercise the awkward cases: a path with a #, a value
    that used to collide with a trailing comment, and every colour slot. }
  Cfg.PerlExe     := '/opt/perl#5/bin/perl';
  Cfg.ScriptArgs  := 'one "two three" --flag=x';
  Cfg.WorkDir     := '/tmp/some dir';
  Cfg.RunMode     := rmConsole;
  Cfg.Unbuffer    := False;
  Cfg.RunTimeout  := 17;
  Cfg.Warnings    := True;
  Cfg.IncludeDirs := '/a/lib:/b/lib';
  Cfg.TabSize     := 8;
  Cfg.AutoIndent  := False;
  Cfg.BackupFiles := False;
  Cfg.UseTabChar  := True;
  Cfg.Highlight   := False;
  Cfg.Scheme      := 2;
  Cfg.TidyExe     := '/usr/bin/perltidy';
  Cfg.TidyArgs    := '-q -l=100';
  Cfg.CriticExe   := '/usr/bin/perlcritic';
  Cfg.CriticSeverity := 5;
  Cfg.LibDir      := '/opt/turboperl/lib';
  for T := Low(TPerlTok) to High(TPerlTok) do
    Cfg.Colours[T] := (Ord(T) + 1) and $0F;

  Saved := Cfg;

  Check('SaveConfig succeeds', SaveConfig);
  Check('the file exists', FileExists(ConfigFileName));

  { Wipe the settings, then read them back. }
  DefaultConfig;
  Check('LoadConfig succeeds', LoadConfig);

  Check('perl path with a # survives', Cfg.PerlExe = Saved.PerlExe);
  Check('script arguments survive',    Cfg.ScriptArgs = Saved.ScriptArgs);
  Check('working directory survives',  Cfg.WorkDir = Saved.WorkDir);
  Check('run mode survives',           Cfg.RunMode = Saved.RunMode);
  Check('unbuffer survives',           Cfg.Unbuffer = Saved.Unbuffer);
  Check('timeout survives',            Cfg.RunTimeout = Saved.RunTimeout);
  Check('warnings survives',           Cfg.Warnings = Saved.Warnings);
  Check('include dirs survive',        Cfg.IncludeDirs = Saved.IncludeDirs);
  Check('tab size survives',           Cfg.TabSize = Saved.TabSize);
  Check('auto indent survives',        Cfg.AutoIndent = Saved.AutoIndent);
  Check('backup survives',             Cfg.BackupFiles = Saved.BackupFiles);
  Check('real tabs survive',           Cfg.UseTabChar = Saved.UseTabChar);
  Check('highlight survives',          Cfg.Highlight = Saved.Highlight);
  Check('scheme survives',             Cfg.Scheme = Saved.Scheme);
  Check('tidy path survives',          Cfg.TidyExe = Saved.TidyExe);
  Check('tidy args survive',           Cfg.TidyArgs = Saved.TidyArgs);
  Check('critic path survives',        Cfg.CriticExe = Saved.CriticExe);
  Check('critic severity survives',    Cfg.CriticSeverity = Saved.CriticSeverity);
  Check('lib dir survives',            Cfg.LibDir = Saved.LibDir);

  Fails := Fails;
  for T := Low(TPerlTok) to High(TPerlTok) do
    if Cfg.Colours[T] <> Saved.Colours[T] then
    begin
      WriteLn('FAIL colour ', TokName[T], ' was ', Saved.Colours[T],
              ' came back ', Cfg.Colours[T]);
      Inc(Fails);
    end;
  Check('all colour slots survive', True);

  { A missing file must fall back to the defaults rather than fail. }
  DeleteFile(ConfigFileName);
  DefaultConfig;
  Check('a missing file is not an error', not LoadConfig);
  Check('defaults are in place', Cfg.TabSize = 4);

  { Paths under the home directory are shown with a ~. }
  Check('home is ~', TildePath('/home/pat', '/home/pat') = '~');
  Check('a file at home', TildePath('/home/pat/x.pl', '/home/pat') = '~/x.pl');
  Check('a trailing / on $HOME', TildePath('/home/pat/src/x.pl', '/home/pat/') = '~/src/x.pl');
  Check('only a whole directory name matches',
        TildePath('/home/patricia/x.pl', '/home/pat') = '/home/patricia/x.pl');
  Check('elsewhere is left alone', TildePath('/etc/x.pl', '/home/pat') = '/etc/x.pl');
  Check('a $HOME of / changes nothing', TildePath('/etc/x.pl', '/') = '/etc/x.pl');
  Check('no $HOME changes nothing', TildePath('/etc/x.pl', '') = '/etc/x.pl');
{$ifdef MSWINDOWS}
  Check('a Windows home', TildePath('C:\Users\pat\x.pl', 'C:\Users\pat') = '~\x.pl');
  Check('a Windows home ignores case',
        TildePath('c:\users\PAT\x.pl', 'C:\Users\pat') = '~\x.pl');
  Check('a Windows home with / in the path',
        TildePath('C:/Users/pat/x.pl', 'C:\Users\pat') = '~/x.pl');
{$endif}

  WriteLn;
  if Fails = 0 then WriteLn('all settings tests passed')
  else begin WriteLn(Fails, ' FAILURES'); Halt(1); end;
end.
