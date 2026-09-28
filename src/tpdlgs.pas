{ ========================================================================== }
{  TurboPerl - Unit: TPDlgs                                                  }
{                                                                            }
{  The settings dialogs and the about box.                                   }
{                                                                            }
{  Turbo Vision moves data in and out of a dialog as one flat record whose    }
{  fields line up, in order and byte for byte, with the data bearing views    }
{  as they were inserted.  Two sizes matter and are easy to get wrong:        }
{  an input line built with Init(R, N) occupies N+1 bytes, and a cluster      }
{  (check boxes or radio buttons) occupies SizeOf(Sw_Word), which is four     }
{  bytes on a 64 bit build rather than the two a 16 bit Turbo Vision used.    }
{ ========================================================================== }
unit TPDlgs;

{$mode objfpc}{$H-}

interface

uses
  Objects, Drivers, Views, Dialogs, App, MsgBox, FVConsts,
  SysUtils,
  TPConst, TPConfig;

type
  TDocKind = (dkTopic, dkFunction, dkSource, dkFaq);

{ Each returns True when the user pressed OK, having already written the
  new settings back into Cfg. }
function ExecRunArgsDialog: Boolean;
function ExecPerlOptionsDialog: Boolean;
function ExecEditorOptionsDialog: Boolean;

{ Asks what to look up.  Topic comes in as the default. }
function ExecPerlDocDialog(var Topic: AnsiString; var Kind: TDocKind): Boolean;

procedure ShowAbout;

implementation

const
  { History list identifiers. }
  hiArgs    = 10;
  hiWorkDir = 11;
  hiPerlDoc = 12;
  hiIncDirs = 13;

{ -------------------------------------------------------------------------- }

function IntStr(V: Integer): ShortString;
begin
  Str(V, Result);
end;

function StrToIntDef2(const S: ShortString; Def: Integer): Integer;
var
  V, Code: Integer;
begin
  Val(Trim(S), V, Code);
  if Code = 0 then Result := V else Result := Def;
end;

{ Add an input line with a label and a history list in one go. }
function AddInput(D: PDialog; var R: Objects.TRect; const Caption: String;
                  MaxLen: Integer; HistId: Word): PInputLine;
var
  IL: PInputLine;
  LR: Objects.TRect;
begin
  LR := R;
  Dec(LR.A.Y);
  LR.B.Y := LR.A.Y + 1;
  LR.B.X := LR.A.X + Length(Caption) + 2;

  IL := New(PInputLine, Init(R, MaxLen));
  D^.Insert(IL);
  D^.Insert(New(PLabel, Init(LR, Caption, IL)));
  if HistId <> 0 then
  begin
    LR := R;
    LR.A.X := R.B.X;
    LR.B.X := R.B.X + 3;
    D^.Insert(New(PHistory, Init(LR, IL, HistId)));
  end;
  Result := IL;
end;

procedure AddButtons(D: PDialog; Y: Integer);
var
  R: Objects.TRect;
begin
  R.Assign(D^.Size.X div 2 - 14, Y, D^.Size.X div 2 - 4, Y + 2);
  D^.Insert(New(PButton, Init(R, 'O~K~', cmOK, bfDefault)));
  R.Assign(D^.Size.X div 2 + 2, Y, D^.Size.X div 2 + 12, Y + 2);
  D^.Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));
end;

{ ========================================================================== }
{  Run arguments                                                             }
{ ========================================================================== }

type
  TRunArgsRec = packed record
    Args    : String[128];
    WorkDir : String[128];
  end;

function ExecRunArgsDialog: Boolean;
var
  D : PDialog;
  R : Objects.TRect;
  Rec: TRunArgsRec;
begin
  R.Assign(0, 0, 64, 13);
  D := New(PDialog, Init(R, 'Program Arguments'));
  D^.Options := D^.Options or ofCentered;

  R.Assign(3, 3, 56, 4);
  AddInput(D, R, '~A~rguments passed to the script', 128, hiArgs);

  R.Assign(3, 6, 56, 7);
  AddInput(D, R, '~W~orking directory (blank = script''s own)', 128, hiWorkDir);

  R.Assign(3, 8, 60, 9);
  D^.Insert(New(PStaticText, Init(R,
    'Arguments are split on spaces; quote to group them.')));

  AddButtons(D, 10);
  D^.SelectNext(False);

  Rec.Args    := Copy(Cfg.ScriptArgs, 1, 128);
  Rec.WorkDir := Copy(Cfg.WorkDir, 1, 128);

  Result := Application^.ExecuteDialog(D, @Rec) <> cmCancel;
  if Result then
  begin
    Cfg.ScriptArgs := Rec.Args;
    Cfg.WorkDir    := Trim(Rec.WorkDir);
  end;
end;

{ ========================================================================== }
{  Perl options                                                              }
{ ========================================================================== }

type
  TPerlOptRec = packed record
    PerlExe : String[128];
    IncDirs : String[128];
    Timeout : String[8];
    Flags   : Sw_Word;      { bit 0 = warnings, bit 1 = unbuffer }
    RunMode : Sw_Word;      { 0 = capture, 1 = console }
  end;

function ExecPerlOptionsDialog: Boolean;
var
  D  : PDialog;
  R  : Objects.TRect;
  Rec: TPerlOptRec;
begin
  R.Assign(0, 0, 66, 21);
  D := New(PDialog, Init(R, 'Perl Options'));
  D^.Options := D^.Options or ofCentered;

  R.Assign(3, 3, 58, 4);
  AddInput(D, R, '~P~erl interpreter', 128, 0);

  R.Assign(3, 6, 58, 7);
  AddInput(D, R, '~I~nclude directories (colon separated, passed as -I)',
           128, hiIncDirs);

  R.Assign(3, 9, 13, 10);
  AddInput(D, R, '~T~ime limit in seconds (0 = none)', 8, 0);

  R.Assign(3, 12, 30, 14);
  D^.Insert(New(PCheckBoxes, Init(R,
    NewSItem('Enable ~w~arnings (-w)',
    NewSItem('~U~nbuffer script output', nil)))));

  R.Assign(34, 12, 62, 14);
  D^.Insert(New(PRadioButtons, Init(R,
    NewSItem('Output to a ~w~indow',
    NewSItem('Run on the ~c~onsole', nil)))));

  R.Assign(34, 11, 62, 12);
  D^.Insert(New(PStaticText, Init(R, 'When running:')));

  R.Assign(3, 15, 62, 17);
  D^.Insert(New(PStaticText, Init(R,
    'Unbuffering keeps print and warn output in the order the' + #13 +
    'script produced them.  It needs the bundled perl library.')));

  AddButtons(D, 18);
  D^.SelectNext(False);

  Rec.PerlExe := Copy(Cfg.PerlExe, 1, 128);
  Rec.IncDirs := Copy(Cfg.IncludeDirs, 1, 128);
  Rec.Timeout := IntStr(Cfg.RunTimeout);
  Rec.Flags   := 0;
  if Cfg.Warnings then Rec.Flags := Rec.Flags or 1;
  if Cfg.Unbuffer then Rec.Flags := Rec.Flags or 2;
  if Cfg.RunMode = rmConsole then Rec.RunMode := 1 else Rec.RunMode := 0;

  Result := Application^.ExecuteDialog(D, @Rec) <> cmCancel;
  if Result then
  begin
    Cfg.PerlExe     := Trim(Rec.PerlExe);
    Cfg.IncludeDirs := Trim(Rec.IncDirs);
    Cfg.RunTimeout  := StrToIntDef2(Rec.Timeout, Cfg.RunTimeout);
    if Cfg.RunTimeout < 0 then Cfg.RunTimeout := 0;
    Cfg.Warnings    := (Rec.Flags and 1) <> 0;
    Cfg.Unbuffer    := (Rec.Flags and 2) <> 0;
    if Rec.RunMode = 1 then Cfg.RunMode := rmConsole else Cfg.RunMode := rmCapture;
  end;
end;

{ ========================================================================== }
{  Editor options                                                            }
{ ========================================================================== }

type
  TEditOptRec = packed record
    TabSize : String[4];
    Flags   : Sw_Word;   { 1 autoindent, 2 backup, 4 real tabs, 8 highlight,
                           16 VGA palette }
    Scheme  : Sw_Word;
  end;

function ExecEditorOptionsDialog: Boolean;
var
  D  : PDialog;
  R  : Objects.TRect;
  Rec: TEditOptRec;
begin
  R.Assign(0, 0, 62, 21);
  D := New(PDialog, Init(R, 'Editor Options'));
  D^.Options := D^.Options or ofCentered;

  R.Assign(3, 3, 9, 4);
  AddInput(D, R, '~T~ab size', 4, 0);

  R.Assign(3, 6, 34, 11);
  D^.Insert(New(PCheckBoxes, Init(R,
    NewSItem('~A~uto indent',
    NewSItem('Create ~b~ackup files',
    NewSItem('Insert ~r~eal tab characters',
    NewSItem('~S~yntax highlighting',
    NewSItem('Classic ~V~GA palette', nil))))))));

  R.Assign(36, 6, 58, 9);
  D^.Insert(New(PRadioButtons, Init(R,
    NewSItem('~C~lassic colours',
    NewSItem('~Q~uiet colours',
    NewSItem('C~u~stom colours', nil))))));

  R.Assign(36, 5, 58, 6);
  D^.Insert(New(PStaticText, Init(R, 'Colour scheme:')));

  R.Assign(3, 12, 58, 17);
  D^.Insert(New(PStaticText, Init(R,
    'Turning off real tab characters makes the Tab key insert' + #13 +
    'spaces up to the next tab stop.' + #13 + #13 +
    'Custom colours are edited in ~/.turboperlrc, under the' + #13 +
    'colour.* keys; save options first to write them out.')));

  AddButtons(D, 18);
  D^.SelectNext(False);

  Rec.TabSize := IntStr(Cfg.TabSize);
  Rec.Flags   := 0;
  if Cfg.AutoIndent  then Rec.Flags := Rec.Flags or 1;
  if Cfg.BackupFiles then Rec.Flags := Rec.Flags or 2;
  if Cfg.UseTabChar  then Rec.Flags := Rec.Flags or 4;
  if Cfg.Highlight   then Rec.Flags := Rec.Flags or 8;
  if Cfg.VgaPalette  then Rec.Flags := Rec.Flags or 16;
  Rec.Scheme := Cfg.Scheme;

  Result := Application^.ExecuteDialog(D, @Rec) <> cmCancel;
  if Result then
  begin
    Cfg.TabSize := StrToIntDef2(Rec.TabSize, Cfg.TabSize);
    if Cfg.TabSize < 1  then Cfg.TabSize := 1;
    if Cfg.TabSize > 16 then Cfg.TabSize := 16;
    Cfg.AutoIndent  := (Rec.Flags and 1) <> 0;
    Cfg.BackupFiles := (Rec.Flags and 2) <> 0;
    Cfg.UseTabChar  := (Rec.Flags and 4) <> 0;
    Cfg.Highlight   := (Rec.Flags and 8) <> 0;
    Cfg.VgaPalette  := (Rec.Flags and 16) <> 0;
    Cfg.Scheme      := Rec.Scheme;
    if Cfg.Scheme > 2 then Cfg.Scheme := 0;
  end;
end;

{ ========================================================================== }
{  perldoc                                                                   }
{ ========================================================================== }

type
  TDocRec = packed record
    Topic : String[80];
    Kind  : Sw_Word;
  end;

function ExecPerlDocDialog(var Topic: AnsiString; var Kind: TDocKind): Boolean;
var
  D  : PDialog;
  R  : Objects.TRect;
  Rec: TDocRec;
begin
  R.Assign(0, 0, 60, 17);
  D := New(PDialog, Init(R, 'Perl Documentation'));
  D^.Options := D^.Options or ofCentered;

  R.Assign(3, 3, 52, 4);
  AddInput(D, R, '~L~ook up', 80, hiPerlDoc);

  R.Assign(3, 6, 40, 10);
  D^.Insert(New(PRadioButtons, Init(R,
    NewSItem('~P~age or module    (perldoc)',
    NewSItem('~F~unction          (perldoc -f)',
    NewSItem('Module ~s~ource     (perldoc -m)',
    NewSItem('Search the F~A~Q    (perldoc -q)', nil)))))));

  R.Assign(3, 11, 56, 13);
  D^.Insert(New(PStaticText, Init(R,
    'Ctrl-F1 in the editor looks up the word at the cursor' + #13 +
    'without asking.')));

  AddButtons(D, 14);
  D^.SelectNext(False);

  Rec.Topic := Copy(Topic, 1, 80);
  Rec.Kind  := Ord(Kind);

  Result := Application^.ExecuteDialog(D, @Rec) <> cmCancel;
  if Result then
  begin
    Topic := Trim(Rec.Topic);
    if Rec.Kind > Ord(High(TDocKind)) then Rec.Kind := 0;
    Kind := TDocKind(Rec.Kind);
    Result := Topic <> '';
  end;
end;

{ ========================================================================== }

procedure ShowAbout;
begin
  MessageBox(
    #3'TurboPerl ' + TPVersion + #13 +
    #3'' + TPCopyright + #13 + #13 +
    #3'Built with Free Pascal and Free Vision' + #13 +
    #3'Editing Perl the way Turbo Pascal edited Pascal' + #13 + #13 +
    #3'F9 checks syntax   Ctrl-F9 runs   F1 reads the docs',
    nil, mfInformation or mfOKButton);
end;

end.
