{ ========================================================================== }
{  TurboPerl - Unit: TPApp                                                   }
{                                                                            }
{  The application object: menus, status line, and everything that ties the  }
{  editor to perl.                                                           }
{ ========================================================================== }
unit TPApp;

{$mode objfpc}{$H-}

interface

uses
  Objects, Drivers, Views, Menus, App, MsgBox, StdDlg, Editors,
  FVConsts, Gadgets, Video,
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils, Classes,
  TPConst, TPConfig, TPPerl, TPEdit, TPViews, TPDlgs, TPText;

type
  PTurboPerl = ^TTurboPerl;
  TTurboPerl = object(TApplication)
    OutWin   : POutputWindow;
    MsgWin   : PMsgWindow;
    ClipWin  : PPerlEditWindow;
    Clock    : PClockView;
    WinNum   : Integer;
    LastDoc  : AnsiString;
    LastKind : TDocKind;

    constructor Init;

    procedure InitMenuBar; virtual;
    procedure InitStatusLine; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure Idle; virtual;

    { --- files --- }
    procedure NewFile;
    procedure OpenFile;
    function  OpenNamed(const FName: AnsiString): PPerlEditWindow;
    procedure SaveAll;
    function  CurrentEditor: PPerlEditor;
    function  WindowFor(const FName: AnsiString): PPerlEditWindow;

    { --- running --- }
    procedure RunScript(OnConsole: Boolean);
    procedure WaitForEnter(const Prompt: AnsiString; AtBottom: Boolean = False);
    procedure SyntaxCheck;
    procedure RunTidy;
    procedure RunCritic;
    procedure RunDeparse;
    procedure ShowPerlVersion;
    procedure ShowIncPath;

    { --- documentation --- }
    procedure PerlDocFor(const Topic: AnsiString; Kind: TDocKind);
    procedure PerlDocAtCursor;
    procedure PerlDocAsk;

    { --- output and messages --- }
    procedure ShowOutput(const Title, Text: AnsiString);
    procedure PostMessages(const M: TPerlMsgList; const Summary: AnsiString);
    procedure GotoCurrentError;
    procedure StepError(Dir: Integer);
    procedure SaveOutputToFile;

  private
    function  PrepareToRun(out Ed: PPerlEditor; out Script: AnsiString): Boolean;
    function  PerlArgsFor(const Script: AnsiString; Check: Boolean): TStringArray;
    function  RunEnv: TStringArray;
    function  ScriptWorkDir(const Script: AnsiString): AnsiString;
    procedure SuspendScreen;
    procedure ResumeScreen;
    procedure ShowUserScreen;
    procedure Complain(const S: AnsiString);
    function  NextWindowNumber: Integer;
  end;

implementation

const
  { How long a tool may take before we give up on it. }
  ToolTimeoutMs = 120 * 1000;

{ -------------------------------------------------------------------------- }

{ Append the elements of B to A. }
procedure Append(var A: TStringArray; const B: array of AnsiString);
var
  i, N: Integer;
begin
  N := Length(A);
  SetLength(A, N + Length(B));
  for i := 0 to High(B) do A[N + i] := B[i];
end;

{ ========================================================================== }
{  Construction                                                              }
{ ========================================================================== }

constructor TTurboPerl.Init;
var
  R, OutR, MsgR: Objects.TRect;
  H, OutH, MsgH: Integer;
begin
  { Free Vision's own editor dialogs (find, replace, go to line) have to be
    hooked up before any editor is created. }
  EditorDialog := @StdEditorDialog;
  LoadConfig;
  if Cfg.BackupFiles then
    EditorFlags := EditorFlags or efBackupFiles
  else
    EditorFlags := EditorFlags and not efBackupFiles;

  WinNum   := 0;
  LastDoc  := '';
  LastKind := dkTopic;

  inherited Init;

  GetExtent(R);
  R.A.X := R.B.X - 9;
  R.B.Y := R.A.Y + 1;
  Clock := New(PClockView, Init(R));
  Insert(Clock);

  { The clipboard is an ordinary editor that is simply never shown. }
  GetExtent(R);
  R.Grow(-8, -4);
  ClipWin := New(PPerlEditWindow, Init(R, '', wnNoNumber));
  if ValidView(ClipWin) <> nil then
  begin
    ClipWin^.Hide;
    ClipWin^.Editor^.CanUndo := False;
    InsertWindow(ClipWin);
    Editors.Clipboard := PEditor(ClipWin^.Editor);
  end;

  { Output and messages are created once and hidden; closing them hides
    them again rather than throwing the log away.  They are stacked along
    the bottom so that both can be read at once after a run. }
  Desktop^.GetExtent(R);
  H := R.B.Y - R.A.Y;
  MsgH := H div 5;
  if MsgH < 4 then MsgH := 4;
  OutH := H div 3;
  if OutH < 5 then OutH := 5;
  if MsgH + OutH > H - 3 then
  begin
    { A short screen: give them a third each and let them overlap the rest. }
    MsgH := H div 3;
    OutH := H div 3;
  end;

  OutR := R;
  OutR.A.Y := R.B.Y - MsgH - OutH;
  OutR.B.Y := R.B.Y - MsgH;
  OutWin := New(POutputWindow, Init(OutR, 'Output', wnNoNumber));
  OutWin^.Hide;
  InsertWindow(OutWin);

  MsgR := R;
  MsgR.A.Y := R.B.Y - MsgH;
  MsgWin := New(PMsgWindow, Init(MsgR, wnNoNumber));
  MsgWin^.Hide;
  InsertWindow(MsgWin);
end;

function TTurboPerl.NextWindowNumber: Integer;
begin
  Inc(WinNum);
  if WinNum > 9 then WinNum := 1;
  Result := WinNum;
end;

{ ========================================================================== }
{  Menu and status line                                                      }
{ ========================================================================== }

{ --------------------------------------------------------------------------
  Menu construction.  Each submenu is built by its own function so that the
  chain of nested NewItem calls - and the run of closing parentheses it ends
  with - stays short enough to read.
  -------------------------------------------------------------------------- }

function MenuFile: PMenuItem;
begin
  Result :=
    NewItem('~N~ew',                     '',          kbNoKey,    cmNew,             hcNoContext,
    NewItem('~O~pen...',                 'F3',        kbF3,       cmOpen,            hcNoContext,
    NewItem('~S~ave',                    'F2',        kbF2,       cmSave,            hcNoContext,
    NewItem('Save ~a~s...',              '',          kbNoKey,    cmSaveAs,          hcNoContext,
    NewItem('Save a~l~l',                '',          kbNoKey,    cmSaveAll,         hcNoContext,
    NewLine(
    NewItem('~C~hange dir...',           '',          kbNoKey,    cmChangeDir,       hcNoContext,
    NewItem('S~h~ell to OS',             '',          kbNoKey,    cmDosShell,        hcNoContext,
    NewLine(
    NewItem('E~x~it',                    'Alt-X',     kbAltX,     cmQuit,            hcNoContext,
    nil))))))))));
end;

function MenuEdit: PMenuItem;
begin
  Result :=
    NewItem('~U~ndo',                    'Alt-BkSp',  kbAltBack,  cmUndo,            hcNoContext,
    NewItem('~R~edo',                    '',          kbNoKey,    cmRedo,            hcNoContext,
    NewLine(
    NewItem('Cu~t~',                     'Shift-Del', kbShiftDel, cmCut,             hcNoContext,
    NewItem('~C~opy',                    'Ctrl-Ins',  kbCtrlIns,  cmCopy,            hcNoContext,
    NewItem('~P~aste',                   'Shift-Ins', kbShiftIns, cmPaste,           hcNoContext,
    NewItem('C~l~ear',                   'Ctrl-Del',  kbCtrlDel,  cmClear,           hcNoContext,
    NewLine(
    NewItem('Show clip~b~oard',          '',          kbNoKey,    cmClipboard,       hcNoContext,
    NewLine(
    NewItem('Comme~n~t block',           'Alt-C',     kbAltC,     cmCommentBlock,    hcNoContext,
    NewItem('~U~ncomment block',         'Alt-U',     kbAltU,     cmUncommentBlock,  hcNoContext,
    NewItem('~I~ndent block',            'Alt-I',     kbAltI,     cmIndentBlock,     hcNoContext,
    NewItem('Unin~d~ent block',          'Alt-D',     kbAltD,     cmUnindentBlock,   hcNoContext,
    NewItem('Strip trailing s~p~aces',   '',          kbNoKey,    cmStripTrailing,   hcNoContext,
    nil)))))))))))))));
end;

function MenuSearch: PMenuItem;
begin
  Result :=
    NewItem('~F~ind...',                 'Ctrl-Q F',  kbNoKey,    cmFind,            hcNoContext,
    NewItem('~R~eplace...',              'Ctrl-Q A',  kbNoKey,    cmReplace,         hcNoContext,
    NewItem('~S~earch again',            'Ctrl-L',    kbNoKey,    cmSearchAgain,     hcNoContext,
    NewItem('~G~o to line...',           'Ctrl-Q G',  kbNoKey,    cmJumpLine,        hcNoContext,
    NewLine(
    NewItem('~N~ext message',            'Alt-F8',    kbAltF8,    cmNextError,       hcNoContext,
    NewItem('~P~revious message',        'Alt-F7',    kbAltF7,    cmPrevError,       hcNoContext,
    nil)))))));
end;

function MenuRun: PMenuItem;
begin
  Result :=
    NewItem('~R~un',                     'Ctrl-F9',   kbCtrlF9,   cmRunProgram,      hcNoContext,
    NewItem('Run on ~c~onsole',          '',          kbNoKey,    cmRunConsole,      hcNoContext,
    NewLine(
    NewItem('~S~yntax check',            'F9',        kbF9,       cmSyntaxCheck,     hcNoContext,
    NewLine(
    NewItem('~P~rogram arguments...',    '',          kbNoKey,    cmRunArgs,         hcNoContext,
    nil))))));
end;

function MenuTools: PMenuItem;
begin
  Result :=
    NewItem('~H~elp on word',            'Ctrl-F1',   kbCtrlF1,   cmPerlDocWord,     hcNoContext,
    NewItem('~L~ook up...',              '',          kbNoKey,    cmPerlDocDlg,      hcNoContext,
    NewLine(
    NewItem('~T~idy (perltidy)',         '',          kbNoKey,    cmPerlTidy,        hcNoContext,
    NewItem('~C~ritique (perlcritic)',   '',          kbNoKey,    cmPerlCritic,      hcNoContext,
    NewItem('~D~eparse',                 '',          kbNoKey,    cmDeparse,         hcNoContext,
    NewLine(
    NewItem('Perl ~v~ersion',            '',          kbNoKey,    cmPerlVersion,     hcNoContext,
    NewItem('Show ~@~INC',               '',          kbNoKey,    cmPerlIncPath,     hcNoContext,
    nil)))))))));
end;

function MenuOptions: PMenuItem;
begin
  Result :=
    NewItem('~P~erl...',                 '',          kbNoKey,    cmOptPerl,         hcNoContext,
    NewItem('~E~ditor...',               '',          kbNoKey,    cmOptEditor,       hcNoContext,
    NewLine(
    NewItem('~S~ave options',            '',          kbNoKey,    cmSaveOptions,     hcNoContext,
    nil))));
end;

function MenuWindow: PMenuItem;
begin
  Result :=
    NewItem('~T~ile',                    '',          kbNoKey,    cmTile,            hcNoContext,
    NewItem('C~a~scade',                 '',          kbNoKey,    cmCascade,         hcNoContext,
    NewLine(
    NewItem('~N~ext',                    'F6',        kbF6,       cmNext,            hcNoContext,
    NewItem('~P~revious',                'Shift-F6',  kbShiftF6,  cmPrev,            hcNoContext,
    NewItem('~Z~oom',                    'F5',        kbF5,       cmZoom,            hcNoContext,
    NewItem('~S~ize/move',               'Ctrl-F5',   kbCtrlF5,   cmResize,          hcNoContext,
    NewItem('~C~lose',                   'Alt-F3',    kbAltF3,    cmClose,           hcNoContext,
    NewLine(
    NewItem('~U~ser screen',             'Alt-F5',    kbAltF5,    cmUserScreen,      hcNoContext,
    NewLine(
    NewItem('~O~utput',                  'Alt-O',     kbAltO,     cmShowOutput,      hcNoContext,
    NewItem('~M~essages',                'Alt-M',     kbAltM,     cmShowMessages,    hcNoContext,
    NewItem('Cl~e~ar output',            '',          kbNoKey,    cmClearOutput,     hcNoContext,
    NewItem('Sa~v~e output...',          '',          kbNoKey,    cmSaveOutput,      hcNoContext,
    nil)))))))))))))));
end;

function MenuHelp: PMenuItem;
begin
  Result :=
    NewItem('~A~bout...',                '',          kbNoKey,    cmAboutBox,        hcNoContext,
    nil);
end;

procedure TTurboPerl.InitMenuBar;
var
  R: Objects.TRect;
begin
  GetExtent(R);
  R.B.Y := R.A.Y + 1;
  MenuBar := New(PMenuBar, Init(R, NewMenu(
    NewSubMenu('~F~ile', hcNoContext, NewMenu(MenuFile),
    NewSubMenu('~E~dit', hcNoContext, NewMenu(MenuEdit),
    NewSubMenu('~S~earch', hcNoContext, NewMenu(MenuSearch),
    NewSubMenu('~R~un', hcNoContext, NewMenu(MenuRun),
    NewSubMenu('~T~ools', hcNoContext, NewMenu(MenuTools),
    NewSubMenu('~O~ptions', hcNoContext, NewMenu(MenuOptions),
    NewSubMenu('~W~indow', hcNoContext, NewMenu(MenuWindow),
    NewSubMenu('~H~elp', hcNoContext, NewMenu(MenuHelp),
    nil)))))))))));
end;

procedure TTurboPerl.InitStatusLine;
var
  R: Objects.TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  R.B.X := R.B.X - 9;
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~F2~ Save',    kbF2,     cmSave,
      NewStatusKey('~F3~ Open',    kbF3,     cmOpen,
      NewStatusKey('~F9~ Check',   kbF9,     cmSyntaxCheck,
      NewStatusKey('~Ctrl-F9~ Run', kbCtrlF9, cmRunProgram,
      NewStatusKey('~Alt-F3~ Close', kbAltF3, cmClose,
      NewStatusKey('~Alt-X~ Exit', kbAltX,   cmQuit,
      NewStatusKey('', kbF10, cmMenu,
      nil))))))),
    nil)));
end;

{ ========================================================================== }
{  Helpers                                                                   }
{ ========================================================================== }

procedure TTurboPerl.Complain(const S: AnsiString);
var
  T: String;
begin
  T := Copy(S, 1, 250);
  MessageBox(T, nil, mfError or mfOKButton);
end;

{ The editor to act on: the focused one, else the topmost edit window. }
function TTurboPerl.CurrentEditor: PPerlEditor;
var
  P, Start: PView;
begin
  Result := ActiveEditor;
  if Result <> nil then Exit;

  if (Desktop = nil) or (Desktop^.Last = nil) then Exit;
  Start := Desktop^.Last;
  P := Start;
  repeat
    P := P^.Next;
    if P = nil then Break;
    if (TypeOf(P^) = TypeOf(TPerlEditWindow)) and
       ((P^.State and sfVisible) <> 0) and
       (PPerlEditWindow(P) <> ClipWin) then
      Exit(PPerlEditWindow(P)^.Editor);
  until P = Start;
end;

function TTurboPerl.WindowFor(const FName: AnsiString): PPerlEditWindow;
var
  P, Start: PView;
  Want: AnsiString;
begin
  Result := nil;
  Want := ExpandFileName(FName);
  if (Desktop = nil) or (Desktop^.Last = nil) then Exit;
  Start := Desktop^.Last;
  P := Start;
  repeat
    P := P^.Next;
    if P = nil then Break;
    if (TypeOf(P^) = TypeOf(TPerlEditWindow)) and
       (PPerlEditWindow(P) <> ClipWin) then
      if ExpandFileName(PPerlEditWindow(P)^.Editor^.FileName) = Want then
        Exit(PPerlEditWindow(P));
  until P = Start;
end;

{ ========================================================================== }
{  Files                                                                     }
{ ========================================================================== }

procedure TTurboPerl.NewFile;
var
  R: Objects.TRect;
begin
  Desktop^.GetExtent(R);
  InsertWindow(New(PPerlEditWindow, Init(R, '', NextWindowNumber)));
end;

function TTurboPerl.OpenNamed(const FName: AnsiString): PPerlEditWindow;
var
  R: Objects.TRect;
  W: PPerlEditWindow;
begin
  Result := WindowFor(FName);
  if Result <> nil then
  begin
    Result^.Select;
    Result^.Show;
    Exit;
  end;
  Desktop^.GetExtent(R);
  W := New(PPerlEditWindow, Init(R, FName, NextWindowNumber));
  if InsertWindow(W) = nil then Exit(nil);
  Result := W;
end;

procedure TTurboPerl.OpenFile;
var
  D    : PFileDialog;
  FName: FNameStr;
begin
  FName := '*.p[lm]';
  New(D, Init(FName, 'Open Perl source', '~N~ame', fdOpenButton or fdHelpButton, 1));
  if ExecuteDialog(D, @FName) <> cmCancel then
    OpenNamed(FName);
end;

procedure TTurboPerl.SaveAll;
var
  P, Start: PView;
begin
  if (Desktop = nil) or (Desktop^.Last = nil) then Exit;
  Start := Desktop^.Last;
  P := Start;
  repeat
    P := P^.Next;
    if P = nil then Break;
    if (TypeOf(P^) = TypeOf(TPerlEditWindow)) and
       (PPerlEditWindow(P) <> ClipWin) then
      if PPerlEditWindow(P)^.Editor^.Modified then
        Message(P, evCommand, cmSave, nil);
  until P = Start;
end;

{ ========================================================================== }
{  Running perl                                                              }
{ ========================================================================== }

function TTurboPerl.ScriptWorkDir(const Script: AnsiString): AnsiString;
begin
  if Cfg.WorkDir <> '' then
    Result := Cfg.WorkDir
  else
    Result := ExtractFilePath(Script);
  if Result = '' then Result := GetCurrentDir;
end;

{ PERL5LIB and PERL5OPT make perl load the bundled autoflush helper, so that
  print and warn output reach the log in the order the script made them. }
function TTurboPerl.RunEnv: TStringArray;
var
  Existing: AnsiString;
begin
  Result := nil;
  if (not Cfg.Unbuffer) or (Cfg.LibDir = '') then Exit;
  if not FileExists(IncludeTrailingPathDelimiter(Cfg.LibDir) +
                    'TurboPerl' + PathDelim + 'Unbuffer.pm') then Exit;

  SetLength(Result, 2);
  Existing := GetEnvironmentVariable('PERL5LIB');
  if Existing <> '' then
    Result[0] := 'PERL5LIB=' + Cfg.LibDir + ':' + Existing
  else
    Result[0] := 'PERL5LIB=' + Cfg.LibDir;

  Existing := GetEnvironmentVariable('PERL5OPT');
  if Existing <> '' then
    Result[1] := 'PERL5OPT=' + Existing + ' -MTurboPerl::Unbuffer'
  else
    Result[1] := 'PERL5OPT=-MTurboPerl::Unbuffer';
end;

function TTurboPerl.PerlArgsFor(const Script: AnsiString;
                                Check: Boolean): TStringArray;
var
  N, i : Integer;
  Dirs : AnsiString;
  P    : Integer;
  Dir  : AnsiString;
  UserArgs: TStringArray;
begin
  Result := nil;

  if Cfg.Warnings then Append(Result, ['-w']);

  { -I for each configured include directory. }
  Dirs := Cfg.IncludeDirs;
  while Dirs <> '' do
  begin
    P := Pos(':', Dirs);
    if P = 0 then
    begin
      Dir  := Dirs;
      Dirs := '';
    end
    else
    begin
      Dir  := Copy(Dirs, 1, P - 1);
      System.Delete(Dirs, 1, P);
    end;
    Dir := Trim(Dir);
    if Dir <> '' then Append(Result, ['-I' + Dir]);
  end;

  if Check then Append(Result, ['-c']);
  Append(Result, [Script]);

  { The script's own arguments only make sense for a real run. }
  if not Check then
  begin
    SplitArgs(Cfg.ScriptArgs, UserArgs, N);
    for i := 0 to N - 1 do Append(Result, [UserArgs[i]]);
  end;
end;

{ Make sure there is something to run and that it is on disk. }
function TTurboPerl.PrepareToRun(out Ed: PPerlEditor;
                                 out Script: AnsiString): Boolean;
begin
  Result := False;
  Script := '';
  Ed := CurrentEditor;
  if Ed = nil then
  begin
    Complain('There is no source window to run.');
    Exit;
  end;

  if Ed^.FileName = '' then
  begin
    { perl needs a file, so an untitled buffer has to be named first. }
    if not Ed^.SaveAs then Exit;
    if Ed^.FileName = '' then Exit;
  end
  else if Ed^.Modified then
    if not Ed^.Save then Exit;

  Script := Ed^.FileName;
  Result := Script <> '';
end;

{ Throw away anything already sitting in the terminal's input buffer.

  Between handing the terminal back and asking the user to press Enter, all
  sorts of bytes can arrive that nobody typed: a left over mouse report, a
  reply to a terminal query, or type-ahead aimed at the script that has just
  finished.  Any one of them satisfies a plain ReadLn straight away, the IDE
  repaints, and the run's output is gone before it could be read. }
procedure DrainPendingInput;
{$IFDEF UNIX}
var
  Flags, Got: Integer;
  Buf: array[0..255] of Byte;
begin
  Flags := FpFcntl(0, F_GetFl, 0);
  if Flags = -1 then Exit;
  if FpFcntl(0, F_SetFl, Flags or O_NONBLOCK) = -1 then Exit;
  repeat
    Got := FpRead(0, Buf, SizeOf(Buf));
  until Got <= 0;
  FpFcntl(0, F_SetFl, Flags);
end;
{$ELSE}
begin
end;
{$ENDIF}

{ Print a prompt on the bare terminal and wait for a real Enter.

  AtBottom parks the prompt on the last line first.  After stepping off the
  IDE's display the cursor sits at the top, so printing there would scroll
  away the very output the user asked to look at. }
procedure TTurboPerl.WaitForEnter(const Prompt: AnsiString; AtBottom: Boolean);
begin
  if AtBottom then
    { Row 999 clamps to the last line on any terminal able to run the IDE. }
    Write(#27'[999;1H')
  else
    WriteLn;
  Write(Prompt);
  Flush(Output);
  DrainPendingInput;
  ReadLn;
end;

procedure TTurboPerl.SuspendScreen;
begin
  DoneSysError;
  DoneEvents;
  Drivers.DoneVideo;
  Drivers.DoneKeyboard;
end;

{ Turbo Pascal's user screen: step off the IDE's display and back onto the
  terminal underneath, which is where a console run left its output. }
procedure TTurboPerl.ShowUserScreen;
begin
  SuspendScreen;
  WaitForEnter('--- ' + TPTitle + ' user screen - press Enter to go back ---', True);
  ResumeScreen;
end;

procedure TTurboPerl.ResumeScreen;
begin
  Drivers.InitKeyboard;
  Drivers.InitVideo;
  Video.SetCursorType(crHidden);
  InitScreen;
  InitEvents;
  InitSysError;
  Redraw;
end;

procedure TTurboPerl.RunScript(OnConsole: Boolean);
var
  Ed     : PPerlEditor;
  Script : AnsiString;
  Args   : TStringArray;
  Env    : TStringArray;
  Res    : TRunResult;
  Code   : Integer;
  Summary: AnsiString;
  Msgs   : TPerlMsgList;
  T      : Integer;
begin
  if not PrepareToRun(Ed, Script) then Exit;

  Args := PerlArgsFor(Script, False);
  Env  := RunEnv;

  if OnConsole then
  begin
    SuspendScreen;
    WriteLn;
    WriteLn('--- ', TPTitle, ': running ', ExtractFileName(Script), ' ---');
    Flush(Output);
    Code := RunOnConsole(Cfg.PerlExe, Args, ScriptWorkDir(Script), Env);
    WaitForEnter('--- exit code ' + IntToStr(Code) +
                 ' --- press Enter to return to the IDE (Alt-F5 shows this again) ---');
    ResumeScreen;
    Exit;
  end;

  T := Cfg.RunTimeout * 1000;
  Res := RunCaptured(Cfg.PerlExe, Args, ScriptWorkDir(Script), '', Env, T);

  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.PerlExe + ': ' + Res.ErrMsg);
    Exit;
  end;

  Summary := ExtractFileName(Script);
  if Res.TimedOut then
    Summary := Summary + ' - stopped after ' + IntToStr(Cfg.RunTimeout) + 's'
  else
    Summary := Summary + ' - exit code ' + IntToStr(Res.ExitCode);
  if Res.Truncated then Summary := Summary + ' (output truncated)';

  ShowOutput('Output: ' + Summary, Res.Output);
  Msgs := DiagnosticsOnly(ParseDiagnostics(Res.Output));
  PostMessages(Msgs, Summary);
end;

procedure TTurboPerl.SyntaxCheck;
var
  Ed     : PPerlEditor;
  Script : AnsiString;
  Args   : TStringArray;
  Res    : TRunResult;
  Msgs   : TPerlMsgList;
  Summary: AnsiString;
begin
  if not PrepareToRun(Ed, Script) then Exit;

  Args := PerlArgsFor(Script, True);
  Res := RunCaptured(Cfg.PerlExe, Args, ScriptWorkDir(Script), '', ToolTimeoutMs);

  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.PerlExe + ': ' + Res.ErrMsg);
    Exit;
  end;

  Msgs := DiagnosticsOnly(ParseDiagnostics(Res.Output));

  if SyntaxOK(Res.Output) and (Length(Msgs) = 0) then
  begin
    PostMessages(Msgs, 'syntax OK');
    MessageBox(ExtractFileName(Script) + ' - syntax OK', nil,
               mfInformation or mfOKButton);
    Exit;
  end;

  Summary := ExtractFileName(Script) + ' - ' + IntToStr(Length(Msgs)) + ' message(s)';
  ShowOutput('Syntax check: ' + Summary, Res.Output);
  PostMessages(Msgs, Summary);

  { Leave the first problem selected but stay in the message list rather
    than jumping straight into the source: a full height editor window
    would cover the very message the user is meant to read.  Enter on the
    message, or Alt-F8, goes to the line. }
  if MsgWin^.View^.Items.Count > 0 then
  begin
    MsgWin^.View^.FocusItem(0);
    MsgWin^.Show;
    MsgWin^.Select;
  end;
end;

{ ========================================================================== }
{  External tools                                                            }
{ ========================================================================== }

procedure TTurboPerl.RunTidy;
var
  Ed  : PPerlEditor;
  Res : TRunResult;
  Src : AnsiString;
  Args: TStringArray;
  N, i: Integer;
  Split: TStringArray;
begin
  Ed := CurrentEditor;
  if Ed = nil then
  begin
    Complain('There is no source window to tidy.');
    Exit;
  end;
  if Cfg.TidyExe = '' then
  begin
    Complain('perltidy was not found.  Set its path under Options/Perl, ' +
             'or install Perl::Tidy.');
    Exit;
  end;

  Src := Ed^.WholeText;
  if Src = '' then Exit;

  Args := nil;
  SplitArgs(Cfg.TidyArgs, Split, N);
  for i := 0 to N - 1 do Append(Args, [Split[i]]);
  { With no file argument perltidy filters stdin; -st sends the result to
    stdout and -se keeps its diagnostics on stderr, so the two never mix. }
  Append(Args, ['-st', '-se']);

  Res := RunFilter(Cfg.TidyExe, Args, ScriptWorkDir(Ed^.FileName), Src,
                   [], ToolTimeoutMs);

  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.TidyExe + ': ' + Res.ErrMsg);
    Exit;
  end;

  { Only touch the buffer if perltidy really produced a program.  A syntax
    error makes it print diagnostics and little or nothing on stdout, and
    replacing the source with that would lose the user's work. }
  if (Res.ExitCode <> 0) or (Length(Res.Output) = 0) then
  begin
    ShowOutput('perltidy', Res.ErrOutput + Res.Output);
    Complain('perltidy reported a problem; the source was left unchanged.');
    Exit;
  end;

  if Res.Output = Src then
  begin
    MessageBox('Already tidy.', nil, mfInformation or mfOKButton);
    Exit;
  end;

  Ed^.ReplaceAll(Res.Output);
  if Res.ErrOutput <> '' then ShowOutput('perltidy', Res.ErrOutput);
end;

procedure TTurboPerl.RunCritic;
var
  Ed  : PPerlEditor;
  Script: AnsiString;
  Res : TRunResult;
  Args: TStringArray;
  Msgs: TPerlMsgList;
begin
  if not PrepareToRun(Ed, Script) then Exit;
  if Cfg.CriticExe = '' then
  begin
    Complain('perlcritic was not found.  Set its path under Options/Perl, ' +
             'or install Perl::Critic.');
    Exit;
  end;

  Args := nil;
  { Ask for perl's own "... at FILE line N" wording so that the same
    diagnostic parser can find the locations. }
  Append(Args, ['--severity', IntToStr(Cfg.CriticSeverity),
                '--verbose', '%m at %f line %l (severity %s)\n', Script]);

  Res := RunCaptured(Cfg.CriticExe, Args, ScriptWorkDir(Script), '',
                     ToolTimeoutMs);
  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.CriticExe + ': ' + Res.ErrMsg);
    Exit;
  end;

  ShowOutput('perlcritic: ' + ExtractFileName(Script), Res.Output);
  Msgs := DiagnosticsOnly(ParseDiagnostics(Res.Output));
  PostMessages(Msgs, 'perlcritic - ' + IntToStr(Length(Msgs)) + ' finding(s)');
end;

procedure TTurboPerl.RunDeparse;
var
  Ed    : PPerlEditor;
  Script: AnsiString;
  Res   : TRunResult;
  Args  : TStringArray;
begin
  if not PrepareToRun(Ed, Script) then Exit;
  Args := nil;
  Append(Args, ['-MO=Deparse,-p', Script]);
  Res := RunCaptured(Cfg.PerlExe, Args, ScriptWorkDir(Script), '',
                     ToolTimeoutMs);
  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.PerlExe + ': ' + Res.ErrMsg);
    Exit;
  end;
  ShowOutput('Deparse: ' + ExtractFileName(Script), Res.Output);
end;

procedure TTurboPerl.ShowPerlVersion;
var
  Res: TRunResult;
begin
  Res := RunCaptured(Cfg.PerlExe, ['-V'], '', '', ToolTimeoutMs);
  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.PerlExe + ': ' + Res.ErrMsg);
    Exit;
  end;
  ShowOutput('perl -V', Res.Output);
end;

procedure TTurboPerl.ShowIncPath;
var
  Res: TRunResult;
begin
  Res := RunCaptured(Cfg.PerlExe,
    ['-e', 'print "$_\n" for @INC'], '', '', RunEnv, ToolTimeoutMs);
  if not Res.Launched then
  begin
    Complain('Could not start ' + Cfg.PerlExe + ': ' + Res.ErrMsg);
    Exit;
  end;
  ShowOutput('@INC', Res.Output);
end;

{ ========================================================================== }
{  Documentation                                                             }
{ ========================================================================== }

procedure TTurboPerl.PerlDocFor(const Topic: AnsiString; Kind: TDocKind);
var
  Res  : TRunResult;
  Args : TStringArray;
  Doc  : AnsiString;
  Title: AnsiString;
begin
  if Trim(Topic) = '' then Exit;

  Doc := FindOnPath('perldoc');
  if Doc = '' then
  begin
    Complain('perldoc was not found on PATH.');
    Exit;
  end;

  Args := nil;
  { -T keeps perldoc out of a pager, which would fight us for the terminal. }
  Append(Args, ['-T']);
  case Kind of
    dkFunction: Append(Args, ['-f']);
    dkSource  : Append(Args, ['-m']);
    dkFaq     : Append(Args, ['-q']);
  end;
  Append(Args, [Topic]);

  Res := RunCaptured(Doc, Args, '', '', ToolTimeoutMs);
  if not Res.Launched then
  begin
    Complain('Could not start perldoc: ' + Res.ErrMsg);
    Exit;
  end;

  case Kind of
    dkFunction: Title := 'perldoc -f ' + Topic;
    dkSource  : Title := 'perldoc -m ' + Topic;
    dkFaq     : Title := 'perldoc -q ' + Topic;
  else
    Title := 'perldoc ' + Topic;
  end;

  if Trim(Res.Output) = '' then
  begin
    MessageBox('Nothing found for ' + Copy(Topic, 1, 60) + '.', nil,
               mfInformation or mfOKButton);
    Exit;
  end;

  ShowOutput(Title, Res.Output);
end;

procedure TTurboPerl.PerlDocAtCursor;
var
  Ed  : PPerlEditor;
  Word_: AnsiString;
  Kind: TDocKind;
begin
  Ed := CurrentEditor;
  if Ed = nil then Exit;
  Word_ := Ed^.WordAtCursor;
  if Word_ = '' then
  begin
    PerlDocAsk;
    Exit;
  end;

  { A bare lower case name is most likely a builtin; anything with a :: or a
    capital is a module. }
  if (Pos('::', Word_) > 0) or ((Word_ <> '') and (Word_[1] in ['A'..'Z'])) then
    Kind := dkTopic
  else
    Kind := dkFunction;

  LastDoc  := Word_;
  LastKind := Kind;
  PerlDocFor(Word_, Kind);
end;

procedure TTurboPerl.PerlDocAsk;
var
  Ed   : PPerlEditor;
  Topic: AnsiString;
  Kind : TDocKind;
begin
  Topic := LastDoc;
  Kind  := LastKind;
  Ed := CurrentEditor;
  if (Topic = '') and (Ed <> nil) then Topic := Ed^.WordAtCursor;

  if ExecPerlDocDialog(Topic, Kind) then
  begin
    LastDoc  := Topic;
    LastKind := Kind;
    PerlDocFor(Topic, Kind);
  end;
end;

{ ========================================================================== }
{  Output and messages                                                       }
{ ========================================================================== }

procedure TTurboPerl.ShowOutput(const Title, Text: AnsiString);
begin
  if OutWin = nil then Exit;
  OutWin^.SetCaption(Copy(Title, 1, 64));
  OutWin^.View^.SetText(Text);
  OutWin^.Show;
  OutWin^.Select;
end;

procedure TTurboPerl.PostMessages(const M: TPerlMsgList;
                                  const Summary: AnsiString);
begin
  if MsgWin = nil then Exit;
  MsgWin^.View^.SetMessages(M);
  MsgWin^.SetCaption(Copy('Messages - ' + Summary, 1, 64));
  if Length(M) > 0 then
  begin
    MsgWin^.Show;
    MsgWin^.Select;
  end;
end;

procedure TTurboPerl.GotoCurrentError;
var
  It: TMsgItem;
  W : PPerlEditWindow;
begin
  if MsgWin = nil then Exit;
  It := MsgWin^.View^.Current;
  if (It = nil) or (It.Line <= 0) or (It.FileName = '') then Exit;

  W := WindowFor(It.FileName);
  if W = nil then
  begin
    if not FileExists(It.FileName) then Exit;
    W := OpenNamed(It.FileName);
    if W = nil then Exit;
  end;

  W^.Show;
  W^.Select;
  W^.Editor^.GotoLine(It.Line);
  W^.Editor^.Select;
end;

procedure TTurboPerl.StepError(Dir: Integer);
begin
  if (MsgWin = nil) or (MsgWin^.View^.Items.Count = 0) then Exit;
  MsgWin^.Show;
  if MsgWin^.View^.StepLocated(Dir) then
    GotoCurrentError;
end;

procedure TTurboPerl.SaveOutputToFile;
var
  D    : PFileDialog;
  FName: FNameStr;
  F    : TextFile;
begin
  if (OutWin = nil) or (OutWin^.View^.Lines.Count = 0) then
  begin
    Complain('There is no output to save.');
    Exit;
  end;

  FName := 'output.txt';
  New(D, Init(FName, 'Save output', '~N~ame', fdOKButton, 2));
  if ExecuteDialog(D, @FName) = cmCancel then Exit;

  AssignFile(F, FName);
  {$I-}
  Rewrite(F);
  Write(F, OutWin^.View^.AsText);
  CloseFile(F);
  {$I+}
  if IOResult <> 0 then
    Complain('Could not write ' + FName + '.');
end;

{ ========================================================================== }
{  Events                                                                    }
{ ========================================================================== }

procedure TTurboPerl.HandleEvent(var Event: TEvent);
var
  Ed: PPerlEditor;
begin
  inherited HandleEvent(Event);

  if Event.What <> evCommand then Exit;

  case Event.Command of
    cmNew          : NewFile;
    cmOpen         : OpenFile;
    cmSaveAll      : SaveAll;

    cmRunProgram   : RunScript(Cfg.RunMode = rmConsole);
    cmRunConsole   : RunScript(True);
    cmSyntaxCheck  : SyntaxCheck;
    cmRunArgs      : ExecRunArgsDialog;

    cmPerlTidy     : RunTidy;
    cmPerlCritic   : RunCritic;
    cmDeparse      : RunDeparse;
    cmPerlVersion  : ShowPerlVersion;
    cmPerlIncPath  : ShowIncPath;

    cmPerlDocWord  : PerlDocAtCursor;
    cmPerlDocDlg   : PerlDocAsk;

    cmGotoError    : GotoCurrentError;
    cmNextError    : StepError(1);
    cmPrevError    : StepError(-1);

    cmUserScreen   : ShowUserScreen;
    cmShowOutput   : if OutWin <> nil then begin OutWin^.Show; OutWin^.Select; end;
    cmShowMessages : if MsgWin <> nil then begin MsgWin^.Show; MsgWin^.Select; end;
    cmClearOutput  :
      begin
        if OutWin <> nil then
        begin
          OutWin^.View^.Clear;
          OutWin^.SetCaption('Output');
        end;
        if MsgWin <> nil then
        begin
          MsgWin^.View^.Clear;
          MsgWin^.SetCaption('Messages');
        end;
      end;
    cmSaveOutput   : SaveOutputToFile;

    cmClipboard    :
      if ClipWin <> nil then
      begin
        ClipWin^.Show;
        ClipWin^.Select;
      end;

    cmOptPerl      : ExecPerlOptionsDialog;
    cmOptEditor    :
      begin
        if ExecEditorOptionsDialog then
        begin
          if Cfg.BackupFiles then
            EditorFlags := EditorFlags or efBackupFiles
          else
            EditorFlags := EditorFlags and not efBackupFiles;
          Ed := CurrentEditor;
          if Ed <> nil then
          begin
            Ed^.ApplyConfig;
            Ed^.DrawView;
          end;
          { Other open editors pick the settings up when they next redraw,
            so nudge the whole desktop. }
          Desktop^.Redraw;
        end;
      end;
    cmSaveOptions  :
      begin
        if SaveConfig then
          MessageBox('Settings written to ' + ConfigFileName, nil,
                     mfInformation or mfOKButton)
        else
          Complain('Could not write ' + ConfigFileName);
      end;

    cmAboutBox     : ShowAbout;
  else
    Exit;
  end;

  ClearEvent(Event);
end;

procedure TTurboPerl.Idle;
var
  HasEd : Boolean;
  HasMsg: Boolean;
begin
  inherited Idle;
  if Clock <> nil then Clock^.Update;

  HasEd  := CurrentEditor <> nil;
  HasMsg := (MsgWin <> nil) and (MsgWin^.View^.Items.Count > 0);

  if HasEd then
    EnableCommands([cmRunProgram, cmRunConsole, cmSyntaxCheck, cmPerlDocWord,
                    cmPerlTidy, cmPerlCritic, cmDeparse, cmCommentBlock,
                    cmUncommentBlock, cmIndentBlock, cmUnindentBlock,
                    cmStripTrailing, cmJumpLine, cmSaveAll])
  else
    DisableCommands([cmRunProgram, cmRunConsole, cmSyntaxCheck, cmPerlDocWord,
                     cmPerlTidy, cmPerlCritic, cmDeparse, cmCommentBlock,
                     cmUncommentBlock, cmIndentBlock, cmUnindentBlock,
                     cmStripTrailing, cmJumpLine, cmSaveAll]);

  if HasMsg then
    EnableCommands([cmNextError, cmPrevError, cmGotoError])
  else
    DisableCommands([cmNextError, cmPrevError, cmGotoError]);

  if (OutWin <> nil) and (OutWin^.View^.Lines.Count > 0) then
    EnableCommands([cmSaveOutput, cmClearOutput])
  else
    DisableCommands([cmSaveOutput]);

  { These never depend on context. }
  EnableCommands([cmRunArgs, cmClearOutput]);
end;

end.
