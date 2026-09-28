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
  {$IFDEF UNIX} BaseUnix, TermIO, {$ENDIF}
  SysUtils, Classes,
  TPConst, TPConfig, TPPerl, TPEdit, TPViews, TPDlgs, TPText, TPDebug;

type
  PTurboPerl = ^TTurboPerl;
  TTurboPerl = object(TApplication)
    OutWin   : POutputWindow;
    MsgWin   : PMsgWindow;
    WatchWin : PInfoWindow;
    StackWin : PInfoWindow;
    VarWin   : PInfoWindow;
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
    procedure WaitForEnter(const Prompt: AnsiString; Erase: Boolean = False);
    procedure SyntaxCheck;
    procedure RunTidy;
    procedure RunCritic;
    procedure RunDeparse;
    procedure ShowPerlVersion;
    procedure ShowIncPath;

    { --- debugging --- }
    function  DebugActive: Boolean;
    function  StartDebug: Boolean;
    procedure EnsureDebug;
    procedure DebugStop;
    procedure DebugStep(Which: Integer);
    procedure DebugRunToCursor;
    procedure DebugToggleBreakpoint;
    procedure DebugClearBreakpoints;
    procedure DebugEvaluate;
    procedure DebugAddWatch;
    procedure DebugRefresh;
    procedure DebugShowStop;
    procedure InfoSelected(V: PInfoView);

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

{ ---------------------------------------------------------------------------
  Terminal state captured before the IDE takes the screen over.

  These are deliberately unit variables rather than fields of TTurboPerl.
  Turbo Vision's TObject.Init clears every data field of the object it is
  constructing, so anything stored in the application object before the
  inherited Init runs is wiped - and this has to be collected first, while
  the terminal is still the console's.
  --------------------------------------------------------------------------- }
var
  { The terminal's own enter/leave alternate screen sequences, empty when it
    has none.  See DetectScreenSwitch. }
  Smcup : AnsiString = '';
  Rmcup : AnsiString = '';

const
  { Not every terminal's alternate screen carries the cursor across.
    xterm and screen use ESC [ ? 1049, which saves and restores it; rxvt and
    konsole spell their smcup/rmcup with an explicit ESC 7 / ESC 8 pair; but
    putty's are a bare ESC [ ? 47 h and ESC [ ? 47 l, which move between the
    screens and leave the cursor wherever the IDE happened to put it - so a
    console run would land in the middle of the console and write over it.

    Bracketing the switch with our own save and restore covers all three.
    Where the terminal already does it the extra pair is a no-op: it writes
    and reads back the same position. }
  CursorSave    = #27'7';
  CursorRestore = #27'8';

var
  { Where the console's cursor was when the IDE last had the screen.  Zero
    means we never managed to find out. }
  ConsoleRow : Integer = 0;
  ConsoleCol : Integer = 0;
  {$IFDEF UNIX}
  { The terminal settings as the shell had them, so a console run gets the
    console back exactly as it was. }
  SavedTIOS : TTermios;
  HaveTIOS  : Boolean = False;
  {$ENDIF}

{ -------------------------------------------------------------------------- }

procedure DetectScreenSwitch; forward;
procedure DebugScreenSwitch; forward;

{$IFDEF UNIX}
{ Free Pascal's video driver recognises a terminal by the start of its name
  and has never heard of tmux, so under tmux-256color - tmux's own default -
  it falls back to plain ANSI and draws every bright colour as bold on top of
  the dim one.  tmux emulates screen, so the driver is shown screen's name
  while it looks, and the real one is put back before anything is run. }
var
  TermSlot : PPChar = nil;
  RealTerm : PChar  = nil;
  FakeTerm : AnsiString;

procedure HideTmux;
var
  E: PPChar;
begin
  E := envp;
  if E = nil then Exit;
  while E^ <> nil do
  begin
    if StrLComp(E^, 'TERM=tmux', 9) = 0 then
    begin
      TermSlot := E;
      RealTerm := E^;
      FakeTerm := 'TERM=screen' + StrPas(E^ + 9) + #0;
      E^ := PChar(FakeTerm);
      Exit;
    end;
    Inc(E);
  end;
end;

procedure ShowTmux;
begin
  if TermSlot <> nil then TermSlot^ := RealTerm;
  TermSlot := nil;
end;
{$ENDIF}

{ The sixteen colours as a VGA card showed them, which is what Turbo Pascal
  was drawn in.  Terminals are free to show the ANSI colours however they
  like, and modern schemes do: Konsole's Breeze makes blue a bright sky blue
  that its cyan and green comments all but vanish into.  So while the IDE
  has the screen the terminal is told, with OSC 4, to use the VGA colours,
  and told with OSC 104 to go back to its own the moment anything else is
  shown - a console run, the user screen, or the shell after Alt-X.

  The table is in ANSI order, not VGA order: red is 1 and blue is 4.  The
  Linux console already uses these colours and does not understand OSC 4,
  so it is left alone. }
const
  VgaRGB : array[0..15] of String[8] = (
    '00/00/00', 'aa/00/00', '00/aa/00', 'aa/55/00',
    '00/00/aa', 'aa/00/aa', '00/aa/aa', 'aa/aa/aa',
    '55/55/55', 'ff/55/55', '55/ff/55', 'ff/ff/55',
    '55/55/ff', 'ff/55/ff', '55/ff/ff', 'ff/ff/ff');

var
  PaletteSet : Boolean = False;

procedure SetVgaPalette;
var
  i: Integer;
  S: AnsiString;
begin
  if not Cfg.VgaPalette then Exit;
  if Copy(GetEnvironmentVariable('TERM'), 1, 5) = 'linux' then Exit;
  S := #27']4';
  for i := 0 to 15 do
    S := S + ';' + IntToStr(i) + ';rgb:' + VgaRGB[i];
  Write(S, #7);
  Flush(Output);
  PaletteSet := True;
end;

procedure RestorePalette;
begin
  if not PaletteSet then Exit;
  Write(#27']104'#7);
  Flush(Output);
  PaletteSet := False;
end;

{$IFDEF UNIX}
{ Ask the terminal where its cursor is, with a device status report.

  This is the only dependable way to get the console's cursor back after a
  spell on the alternate screen.  The terminal's own save slot cannot be
  used: Free Pascal's InitVideo homes the cursor just before switching
  screens, and on xterm the switch saves the cursor into the same slot that
  ESC 7 writes to - so whatever was saved beforehand is overwritten with
  row 1, column 1, and leaving the alternate screen faithfully puts the
  cursor back at the top of the console.

  Returns False if the terminal does not answer, in which case the caller
  falls back to the save slot and hopes. }
function QueryCursor(out Row, Col: Integer): Boolean;
var
  Old, Raw : TTermios;
  Buf      : array[0..63] of Char;
  Got, i, j: Integer;
  Reply    : AnsiString;
  Tries    : Integer;
  V, Code  : Integer;
begin
  Result := False;
  Row := 0;
  Col := 0;
  if TCGetAttr(0, Old) <> 0 then Exit;

  Raw := Old;
  { Unbuffered and unechoed, with a tenth of a second per read, so a
    terminal that never replies costs a moment rather than the session. }
  Raw.c_lflag := Raw.c_lflag and not (ICANON or ECHO);
  Raw.c_cc[VMIN]  := 0;
  Raw.c_cc[VTIME] := 1;
  if TCSetAttr(0, TCSANOW, Raw) <> 0 then Exit;

  try
    Write(#27'[6n');
    Flush(Output);

    Reply := '';
    for Tries := 1 to 5 do
    begin
      Got := FpRead(0, Buf, SizeOf(Buf));
      if Got > 0 then
      begin
        SetLength(Reply, Length(Reply) + Got);
        Move(Buf, Reply[Length(Reply) - Got + 1], Got);
        if Pos('R', Reply) > 0 then Break;
      end;
    end;
  finally
    TCSetAttr(0, TCSANOW, Old);
  end;

  { The answer is ESC [ row ; col R, possibly with other input around it. }
  j := 0;
  for i := Length(Reply) downto 2 do
    if (Reply[i] = 'R') and (j = 0) then j := i;
  if j = 0 then Exit;

  i := j;
  while (i > 1) and not ((Reply[i] = #27) and (i + 1 <= Length(Reply)) and
                         (Reply[i + 1] = '[')) do
    Dec(i);
  if (i < 1) or (Reply[i] <> #27) then Exit;

  Reply := Copy(Reply, i + 2, j - i - 2);      { "row;col" }
  i := Pos(';', Reply);
  if i = 0 then Exit;

  Val(Copy(Reply, 1, i - 1), V, Code);
  if (Code <> 0) or (V < 1) then Exit;
  Row := V;
  Val(Copy(Reply, i + 1, Length(Reply)), V, Code);
  if (Code <> 0) or (V < 1) then Exit;
  Col := V;
  Result := True;
end;

{ Remember where the console's cursor is, while we are looking at it. }
procedure NoteConsoleCursor;
var
  R, C: Integer;
begin
  if QueryCursor(R, C) then
  begin
    ConsoleRow := R;
    ConsoleCol := C;
  end;
end;
{$ELSE}
procedure NoteConsoleCursor;
begin
end;
{$ENDIF}

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

  { Both of these read the terminal as the shell left it, so they have to
    run before the drivers take it over. }
  DetectScreenSwitch;
  {$IFDEF UNIX}
  HaveTIOS := TCGetAttr(0, SavedTIOS) = 0;
  {$ENDIF}
  { The first switch to the alternate screen is made by the video driver
    inside the inherited Init, so the console's cursor has to be put away
    before that for the first console run to come back to the right place. }
  if Smcup <> '' then
  begin
    NoteConsoleCursor;
    Write(CursorSave);
    Flush(Output);
  end;
  DebugScreenSwitch;

  {$IFDEF UNIX} HideTmux; {$ENDIF}
  inherited Init;
  {$IFDEF UNIX} ShowTmux; {$ENDIF}
  SetVgaPalette;

  { Only now: TObject.Init has just cleared every field of this object. }
  WinNum   := 0;
  LastDoc  := '';
  LastKind := dkTopic;

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

  { The debugger's panes share the message strip: they are alternatives to
    one another rather than things you read at the same time, and the
    editor keeps the rest of the screen. }
  WatchWin := New(PInfoWindow, Init(MsgR, 'Watches', wnNoNumber));
  WatchWin^.Hide;
  InsertWindow(WatchWin);

  StackWin := New(PInfoWindow, Init(MsgR, 'Call stack', wnNoNumber));
  StackWin^.Hide;
  InsertWindow(StackWin);

  VarWin := New(PVarWindow, Init(MsgR, 'Variables', wnNoNumber));
  VarWin^.Hide;
  InsertWindow(VarWin);
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

function MenuDebug: PMenuItem;
begin
  Result :=
    NewItem('Step ~i~nto',               'F7',        kbF7,       cmDbgStepInto,     hcNoContext,
    NewItem('Step ~o~ver',               'F8',        kbF8,       cmDbgStepOver,     hcNoContext,
    NewItem('Step o~u~t',                '',          kbNoKey,    cmDbgStepOut,      hcNoContext,
    NewItem('~R~un to cursor',           'F4',        kbF4,       cmDbgRunTo,        hcNoContext,
    NewLine(
    NewItem('~C~ontinue',                'Ctrl-F9',   kbNoKey,    cmRunProgram,      hcNoContext,
    NewItem('~P~rogram reset',           'Ctrl-F2',   kbCtrlF2,   cmDbgReset,        hcNoContext,
    NewItem('I~n~terrupt',               '',          kbNoKey,    cmDbgInterrupt,    hcNoContext,
    NewLine(
    NewItem('Toggle ~b~reakpoint',       'Ctrl-F8',   kbCtrlF8,   cmDbgToggleBP,     hcNoContext,
    NewItem('Clear all break~p~oints',   '',          kbNoKey,    cmDbgClearBPs,     hcNoContext,
    NewLine(
    NewItem('~E~valuate/modify...',      'Ctrl-F4',   kbCtrlF4,   cmDbgEvaluate,     hcNoContext,
    NewItem('~A~dd watch...',            'Ctrl-F7',   kbCtrlF7,   cmDbgAddWatch,     hcNoContext,
    NewLine(
    NewItem('~W~atches',                 '',          kbNoKey,    cmDbgWatches,      hcNoContext,
    NewItem('Call ~s~tack',              'Ctrl-F3',   kbCtrlF3,   cmDbgCallStack,    hcNoContext,
    NewItem('~V~ariables',               '',          kbNoKey,    cmDbgVariables,    hcNoContext,
    nil))))))))))))))))));
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
    NewSubMenu('~D~ebug', hcNoContext, NewMenu(MenuDebug),
    NewSubMenu('~T~ools', hcNoContext, NewMenu(MenuTools),
    NewSubMenu('~O~ptions', hcNoContext, NewMenu(MenuOptions),
    NewSubMenu('~W~indow', hcNoContext, NewMenu(MenuWindow),
    NewSubMenu('~H~elp', hcNoContext, NewMenu(MenuHelp),
    nil))))))))))));
end;

procedure TTurboPerl.InitStatusLine;
var
  R: Objects.TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
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
    Result[0] := 'PERL5LIB=' + Cfg.LibDir + PathSeparator + Existing
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

  { -I for each configured include directory.  Separated the way the
    operating system separates PATH, so that a Windows drive letter is not
    mistaken for a separator. }
  Dirs := Cfg.IncludeDirs;
  while Dirs <> '' do
  begin
    P := Pos(PathSeparator, Dirs);
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

{ Print a prompt on the console and wait for a real Enter.

  Erase takes the prompt back off again afterwards, so that visiting the
  user screen repeatedly does not leave a trail of them down the console. }
procedure TTurboPerl.WaitForEnter(const Prompt: AnsiString; Erase: Boolean);
begin
  WriteLn;
  Write(Prompt);
  Flush(Output);
  DrainPendingInput;
  ReadLn;
  if Erase then
  begin
    { Enter echoed a newline, so the cursor is a line below the prompt:
      step up over the prompt and the blank line and clear both. }
    Write(#27'[1A'#27'[2K'#13, #27'[1A'#27'[2K'#13);
    Flush(Output);
  end;
end;

{ Ask the terminal how it switches to and from its alternate screen.

  Free Pascal's video driver puts the IDE on that screen when terminfo says
  there is one, and the terminal then keeps the console's contents and
  cursor safe underneath.  Where there is no alternate screen - the Linux
  console and plain vt100 among them - the IDE and the console share one
  screen and there is nothing to preserve.

  Asking tput rather than hard coding the xterm sequences means the right
  thing happens on both, and the escape codes come from the terminal's own
  description.  If tput is missing both come back empty and the ordinary
  DoneVideo path is used. }
{ Set TURBOPERL_DEBUG to a file name to have the detected sequences and the
  terminal type written there; useful when a console run misbehaves on a
  terminal that is not to hand. }
procedure DebugScreenSwitch;
var
  F: TextFile;
  H: AnsiString;

  function Hex(const A: AnsiString): AnsiString;
  var
    i: Integer;
  begin
    Result := '';
    for i := 1 to Length(A) do Result := Result + IntToHex(Ord(A[i]), 2) + ' ';
  end;

begin
  H := GetEnvironmentVariable('TURBOPERL_DEBUG');
  if H = '' then Exit;
  AssignFile(F, H);
  {$I-}
  Rewrite(F);
  WriteLn(F, 'TERM=', GetEnvironmentVariable('TERM'));
  WriteLn(F, 'tput=', FindOnPath('tput'));
  WriteLn(F, 'smcup=[', Hex(Smcup), ']');
  WriteLn(F, 'rmcup=[', Hex(Rmcup), ']');
  WriteLn(F, 'console cursor=', ConsoleRow, ';', ConsoleCol);
  CloseFile(F);
  {$I+}
  if IOResult <> 0 then ;
end;

procedure DetectScreenSwitch;
var
  R: TRunResult;
  T: AnsiString;
begin
  Smcup := '';
  Rmcup := '';
  T := FindOnPath('tput');
  if T = '' then Exit;

  R := RunCaptured(T, ['smcup'], '', '', 3000);
  if not R.Launched then Exit;
  if R.ExitCode <> 0 then Exit;
  Smcup := R.Output;

  R := RunCaptured(T, ['rmcup'], '', '', 3000);
  if (not R.Launched) or (R.ExitCode <> 0) then
  begin
    Smcup := '';
    Exit;
  end;
  Rmcup := R.Output;

  if (Smcup = '') or (Rmcup = '') then
  begin
    Smcup := '';
    Rmcup := '';
  end;
end;

{ Hand the terminal back to the console.

  On a terminal with an alternate screen this deliberately does not call
  DoneVideo.  DoneVideo does leave that screen correctly - the terminal
  restores the console's contents and its cursor along with it - but it
  then homes the cursor, so everything written next lands on top of
  whatever the console already held.  That is why a console run used to
  start at the top of the screen and paint over the run before it.

  Doing the switch here instead leaves the cursor where the console left
  it, so successive runs carry on below one another the way Turbo Pascal's
  user screen did.

  Without an alternate screen there is no console image to go back to - the
  IDE has been drawing straight over it - so DoneVideo, which clears, is
  exactly right. }
procedure TTurboPerl.SuspendScreen;
begin
  DoneSysError;
  DoneEvents;
  Drivers.DoneKeyboard;
  RestorePalette;
  if Rmcup <> '' then
  begin
    { Put the terminal back the way the shell had it.  DoneKeyboard on its
      own leaves output translation off, so the newlines written by the
      script would step diagonally down the screen instead of returning to
      the left margin.  DoneVideo is what normally restores this, and the
      whole point here is not to call it. }
    {$IFDEF UNIX}
    if HaveTIOS then TCSetAttr(0, TCSANOW, SavedTIOS);
    {$ENDIF}
    Write(Rmcup);
    if ConsoleRow > 0 then
      Write(#27'[', ConsoleRow, ';', ConsoleCol, 'H')
    else
      { Nothing to go on; the terminal's own save slot is all we have. }
      Write(CursorRestore);
    Flush(Output);
  end
  else
    Drivers.DoneVideo;
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
  if Smcup <> '' then
  begin
    { Re-entering the alternate screen stores the console's cursor for the
      next visit and hands back a cleared screen, so the repaint that
      follows has to be unconditional whatever the video unit believes is
      still up there. }
    NoteConsoleCursor;
    Write(CursorSave, Smcup);
    Flush(Output);
    Drivers.InitKeyboard;
    InitEvents;
    InitSysError;
  end
  else
  begin
    Drivers.InitKeyboard;
    Drivers.InitVideo;
    InitScreen;
    InitEvents;
    InitSysError;
  end;
  SetVgaPalette;
  Video.SetCursorType(crHidden);
  Redraw;
  Video.UpdateScreen(True);
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
{  Debugging                                                                 }
{ ========================================================================== }

function TTurboPerl.DebugActive: Boolean;
begin
  Result := (Session <> nil) and (Session.State in [dsStopped, dsRunning]);
end;

{ Start a session on the window in front, saving it first the way a run
  does.  The program stops before its first statement, exactly as Turbo
  Pascal's F7 did from cold. }
function TTurboPerl.StartDebug: Boolean;
var
  Ed     : PPerlEditor;
  Script : AnsiString;
begin
  Result := False;
  if not PrepareToRun(Ed, Script) then Exit;

  if Session = nil then Session := TDebugSession.Create;
  if not Session.Start(Script, Cfg.ScriptArgs) then
  begin
    Complain(Session.Error);
    Exit;
  end;

  if OutWin <> nil then
  begin
    OutWin^.View^.Clear;
    OutWin^.SetCaption('Output: ' + ExtractFileName(Script));
  end;
  DebugRefresh;
  Result := True;
end;

procedure TTurboPerl.EnsureDebug;
begin
  if not DebugActive then StartDebug;
end;

procedure TTurboPerl.DebugStop;
begin
  if Session = nil then Exit;
  Session.Stop;
  DebugRefresh;
  if Desktop <> nil then Desktop^.Redraw;
end;

{ 0 into, 1 over, 2 out, 3 continue }
procedure TTurboPerl.DebugStep(Which: Integer);
begin
  if not DebugActive then
  begin
    if not StartDebug then Exit;
    { Starting already stops before the first statement, so F7 from cold
      has done its job; only continue actually needs to move. }
    if Which <> 3 then Exit;
  end;
  if Session.State <> dsStopped then Exit;

  case Which of
    0: Session.StepInto;
    1: Session.StepOver;
    2: Session.StepOut;
  else
    Session.Go;
  end;
end;

procedure TTurboPerl.DebugRunToCursor;
var
  Ed: PPerlEditor;
begin
  Ed := CurrentEditor;
  if Ed = nil then Exit;
  if not DebugActive then
    if not StartDebug then Exit;
  if Session.State <> dsStopped then Exit;
  Session.RunTo(Ed^.FileName, Ed^.CurrentLineNo);
end;

procedure TTurboPerl.DebugToggleBreakpoint;
var
  Ed: PPerlEditor;
begin
  Ed := CurrentEditor;
  if Ed = nil then Exit;
  if Ed^.FileName = '' then
  begin
    Complain('Save the file before setting a break point in it.');
    Exit;
  end;
  ToggleBreakpoint(Ed^.FileName, Ed^.CurrentLineNo);
  Ed^.DrawView;
end;

procedure TTurboPerl.DebugClearBreakpoints;
var
  F: AnsiString;
  L, i: Integer;
begin
  for i := BreakpointCount - 1 downto 0 do
  begin
    BreakpointAt(i, F, L);
    if F <> '' then ToggleBreakpoint(F, L);
  end;
  if Desktop <> nil then Desktop^.Redraw;
end;

procedure TTurboPerl.DebugEvaluate;
var
  Ed    : PPerlEditor;
  Expr  : AnsiString;
  Value : AnsiString;
begin
  if (Session = nil) or (Session.State <> dsStopped) then
  begin
    Complain('Nothing is stopped; start the debugger first.');
    Exit;
  end;
  Ed := CurrentEditor;
  Expr := '';
  if Ed <> nil then Expr := Ed^.WordAtCursor;
  if not ExecEvaluateDialog(Expr, Value) then Exit;
  if Trim(Expr) = '' then Exit;
  Value := Session.Evaluate(Expr);
  ExecEvaluateResult(Expr, Value);
end;

procedure TTurboPerl.DebugAddWatch;
var
  Ed   : PPerlEditor;
  Expr : AnsiString;
begin
  if Session = nil then Session := TDebugSession.Create;
  Ed := CurrentEditor;
  Expr := '';
  if Ed <> nil then Expr := Ed^.WordAtCursor;
  if not ExecAddWatchDialog(Expr) then Exit;
  if Trim(Expr) = '' then Exit;
  Session.Watches.Add(Expr);
  Session.SendWatches;
  if WatchWin <> nil then
  begin
    WatchWin^.Show;
    WatchWin^.Select;
  end;
  DebugRefresh;
end;

{ Put everything the session knows back on the screen. }
procedure TTurboPerl.DebugRefresh;
var
  i     : Integer;
  Frame : TStackFrame;
  Text  : AnsiString;
  Live  : Boolean;
begin
  Live := (Session <> nil) and (Session.State = dsStopped);

  if WatchWin <> nil then
  begin
    WatchWin^.View^.Clear;
    if Session <> nil then
      for i := 0 to Session.Watches.Count - 1 do
      begin
        Text := Session.Watches[i];
        if Live and (i < Session.WatchVals.Count) then
          Text := Text + ' = ' + Session.WatchVals[i]
        else
          Text := Text + ' = <not stopped>';
        WatchWin^.View^.Add(Text);
      end;
    WatchWin^.View^.Refreshed;
  end;

  if StackWin <> nil then
  begin
    StackWin^.View^.Clear;
    if Live then
      for i := 0 to Session.StackCount - 1 do
      begin
        Frame := Session.StackFrame(i);
        Text  := Format('%s(%s)  %s:%d', [Frame.Subroutine, Frame.Args,
                        ExtractFileName(Frame.FileName), Frame.Line]);
        StackWin^.View^.Add(Text,
          Frame.FileName + '|' + IntToStr(Frame.Line));
      end;
    StackWin^.View^.Refreshed;
  end;

  if VarWin <> nil then
  begin
    if Live then
      PVarView(VarWin^.View)^.SetVars(Session.Vars)
    else
      PVarView(VarWin^.View)^.SetVars(nil);
  end;
end;

{ Bring the source of the stop into view with the cursor on it. }
procedure TTurboPerl.DebugShowStop;
var
  W: PPerlEditWindow;
begin
  if (Session = nil) or (Session.State <> dsStopped) then Exit;
  if Session.CurFile = '' then Exit;
  if not FileExists(Session.CurFile) then Exit;

  W := WindowFor(Session.CurFile);
  if W = nil then W := OpenNamed(Session.CurFile);
  if W = nil then Exit;

  W^.Show;
  W^.Select;
  W^.Editor^.GotoLine(Session.CurLine);
end;

procedure TTurboPerl.InfoSelected(V: PInfoView);
var
  F: AnsiString;
  L: Integer;
  W: PPerlEditWindow;
begin
  if V = nil then Exit;
  if not V^.CurrentTarget(F, L) then Exit;
  if not FileExists(F) then Exit;
  W := WindowFor(F);
  if W = nil then W := OpenNamed(F);
  if W = nil then Exit;
  W^.Show;
  W^.Select;
  W^.Editor^.GotoLine(L);
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

    { Turbo Pascal's Run key does double duty: with a program stopped in
      the debugger it carries on from there, otherwise it runs normally. }
    cmRunProgram   : if DebugActive then DebugStep(3)
                     else RunScript(Cfg.RunMode = rmConsole);
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
    cmInfoSelect   : InfoSelected(PInfoView(Event.InfoPtr));

    cmDbgStepInto  : DebugStep(0);
    cmDbgStepOver  : DebugStep(1);
    cmDbgStepOut   : DebugStep(2);
    cmDbgRunTo     : DebugRunToCursor;
    cmDbgReset     : DebugStop;
    cmDbgInterrupt : if Session <> nil then Session.Interrupt;
    cmDbgToggleBP  : DebugToggleBreakpoint;
    cmDbgClearBPs  : DebugClearBreakpoints;
    cmDbgEvaluate  : DebugEvaluate;
    cmDbgAddWatch  : DebugAddWatch;
    cmDbgWatches   : if WatchWin <> nil then begin WatchWin^.Show; WatchWin^.Select; end;
    cmDbgCallStack : if StackWin <> nil then begin StackWin^.Show; StackWin^.Select; end;
    cmDbgVariables : if VarWin   <> nil then begin VarWin^.Show;   VarWin^.Select;   end;
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
          RestorePalette;
          SetVgaPalette;
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
  HasEd   : Boolean;
  HasMsg  : Boolean;
  Dbg     : Boolean;
  Stopped : Boolean;
  Text    : AnsiString;
  WasState: TDebugState;
begin
  inherited Idle;
  if Clock <> nil then Clock^.Update;

  { The debugger runs alongside the interface rather than blocking it, so
    this is where a stop, a line of output or the program ending is picked
    up.  Poll says whether anything actually changed. }
  if Session <> nil then
  begin
    WasState := Session.State;
    if Session.Poll then
    begin
      Text := Session.TakeOutput;
      if (Text <> '') and (OutWin <> nil) then
      begin
        OutWin^.View^.AddText(Text);
        OutWin^.Show;
      end;

      DebugRefresh;

      if Session.State = dsStopped then
        DebugShowStop
      else if (Session.State = dsFinished) and (WasState <> dsFinished) then
      begin
        if Desktop <> nil then Desktop^.Redraw;
        MessageBox('The program has finished.', nil,
                   mfInformation or mfOKButton);
      end;

      if Session.Error <> '' then
      begin
        Complain(Session.Error);
        Session.Stop;
        DebugRefresh;
      end;
    end;
  end;

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

  Dbg     := DebugActive;
  Stopped := (Session <> nil) and (Session.State = dsStopped);

  { Stepping needs a stopped program; starting one only needs a source. }
  if Stopped then
    EnableCommands([cmDbgStepInto, cmDbgStepOver, cmDbgStepOut, cmDbgRunTo,
                    cmDbgEvaluate])
  else
  begin
    DisableCommands([cmDbgStepOut, cmDbgEvaluate]);
    if HasEd then
      EnableCommands([cmDbgStepInto, cmDbgStepOver, cmDbgRunTo])
    else
      DisableCommands([cmDbgStepInto, cmDbgStepOver, cmDbgRunTo]);
  end;

  if Dbg then EnableCommands([cmDbgReset]) else DisableCommands([cmDbgReset]);
  if (Session <> nil) and (Session.State = dsRunning) then
    EnableCommands([cmDbgInterrupt])
  else
    DisableCommands([cmDbgInterrupt]);

  if HasEd then EnableCommands([cmDbgToggleBP]) else DisableCommands([cmDbgToggleBP]);
  if BreakpointCount > 0 then
    EnableCommands([cmDbgClearBPs])
  else
    DisableCommands([cmDbgClearBPs]);
  EnableCommands([cmDbgAddWatch, cmInfoSelect]);

  if (OutWin <> nil) and (OutWin^.View^.Lines.Count > 0) then
    EnableCommands([cmSaveOutput, cmClearOutput])
  else
    DisableCommands([cmSaveOutput]);

  { These never depend on context. }
  EnableCommands([cmRunArgs, cmClearOutput]);
end;

finalization
  { However the IDE ends, the shell gets its own colours back. }
  RestorePalette;

end.
