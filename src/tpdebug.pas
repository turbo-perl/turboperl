{ ========================================================================== }
{  TurboPerl - Unit: TPDebug                                                 }
{                                                                            }
{  The IDE's half of the integrated debugger.                                }
{                                                                            }
{  A debug session is a conversation with the bridge process (see            }
{  lib/TurboPerl/Debug/Bridge.pm), one JSON object per line each way.  The   }
{  IDE never blocks waiting for the debugged program: movement commands are  }
{  sent and forgotten, and the reply is picked up by Poll, which the         }
{  application calls from its idle loop.  The few places that genuinely      }
{  need an answer before carrying on - starting up, evaluating an            }
{  expression for a dialog - use WaitFor, which pumps Poll rather than       }
{  sitting on the pipe.                                                      }
{                                                                            }
{  Break points live here rather than in the session, because they are set   }
{  and cleared with no program running and have to outlive it.               }
{ ========================================================================== }
unit TPDebug;

{$mode objfpc}{$H-}

interface

uses
  SysUtils, Classes, Process, fpjson, jsonparser,
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  TPConst, TPConfig, TPText;

type
  TDebugState = (
    dsOff,        { no bridge, no program                      }
    dsStarting,   { bridge launched, program not yet loaded    }
    dsRunning,    { the program is executing; no location      }
    dsStopped,    { stopped somewhere; all the panes are valid }
    dsFinished);  { the program ran to the end                 }

  TStackFrame = record
    Subroutine : AnsiString;
    FileName   : AnsiString;
    Args       : AnsiString;
    Line       : Integer;
  end;

  { One row of the variables tree, in the order they are drawn: a variable,
    then everything inside it, depth first.  Path names the node uniquely
    and stays the same from one stop to the next, so a pane can remember
    which nodes the user opened. }
  TVarNode = record
    Depth   : Integer;
    Name    : AnsiString;
    Value   : AnsiString;
    Path    : AnsiString;
    HasKids : Boolean;
  end;
  TVarNodes = array of TVarNode;

  TDebugSession = class
  private
    FProc     : TProcess;
    FState    : TDebugState;
    FInbox    : AnsiString;      { bytes read but not yet a whole line }
    FStderr   : AnsiString;      { whatever the bridge complained about  }
    FSeq      : Integer;
    FPending  : TFPList;         { parsed messages not yet consumed    }
    FError    : AnsiString;

    FFile     : AnsiString;
    FLine     : Integer;
    FSub      : AnsiString;
    FCodeLine : AnsiString;
    FPid      : Integer;

    FStack    : array of TStackFrame;
    FPad      : TStringList;     { name=value }
    FVars     : TVarNodes;
    FVarCount : Integer;         { in use; FVars grows by doubling while read }
    { Watch results, in the order the expressions were sent.  Held by
      position rather than keyed by the expression, because an expression
      may perfectly well contain an equals sign. }
    FWatchVals: TStringList;
    FOutput   : AnsiString;      { accumulated, drained by TakeOutput  }
    FChanged  : Boolean;

    procedure Drain;
    procedure DrainStderr;
    function  NextMessage: TJSONObject;
    procedure Apply(Msg: TJSONObject);
    function  WaitFor(const Ev: AnsiString; TimeoutMs: Integer): TJSONObject;
    procedure SetStoppedFrom(Msg: TJSONObject);
    procedure ReadWatches(Msg: TJSONObject);
    procedure ReadVars(A: TJSONArray; Depth: Integer; const Parent: AnsiString);
    function  Send(const Cmd: AnsiString; Extra: TJSONObject): Integer;
  public
    Watches : TStringList;       { expressions, owned by the caller's UI }

    constructor Create;
    destructor  Destroy; override;

    function  Start(const Script, Args: AnsiString): Boolean;
    procedure Stop;

    { Movement.  These return as soon as the command is away; watch State. }
    procedure Go;
    procedure StepInto;
    procedure StepOver;
    procedure StepOut;
    procedure RunTo(const AFile: AnsiString; ALine: Integer);
    procedure Interrupt;

    procedure SendBreakpoint(const AFile: AnsiString; ALine: Integer; Setting: Boolean);
    procedure SendWatches;
    function  Evaluate(const Expr: AnsiString): AnsiString;

    { Read whatever the bridge has said.  True when anything changed, which
      is the application's cue to redraw. }
    function  Poll: Boolean;

    function  TakeOutput: AnsiString;
    function  StackCount: Integer;
    function  StackFrame(i: Integer): TStackFrame;

    property State    : TDebugState read FState;
    property CurFile  : AnsiString  read FFile;
    property CurLine  : Integer     read FLine;
    property CurSub   : AnsiString  read FSub;
    property CodeLine : AnsiString  read FCodeLine;
    property Pad      : TStringList read FPad;
    property Vars     : TVarNodes   read FVars;
    property WatchVals: TStringList read FWatchVals;
    property Error    : AnsiString  read FError;
  end;

{ -------------------------------------------------------------------------- }
{  Break points.                                                              }
{                                                                             }
{  Kept outside the session so they survive a program restart, and reachable  }
{  as plain functions so the editor can ask about a line while drawing it     }
{  without knowing anything about sessions.                                   }
{ -------------------------------------------------------------------------- }

function  ToggleBreakpoint(const AFile: AnsiString; ALine: Integer): Boolean;
function  IsBreakpoint(const AFile: AnsiString; ALine: Integer): Boolean;
procedure MoveBreakpoint(const AFile: AnsiString; FromLine, ToLine: Integer);
procedure ClearBreakpointsIn(const AFile: AnsiString);
function  BreakpointCount: Integer;
procedure BreakpointAt(i: Integer; out AFile: AnsiString; out ALine: Integer);

{ The single session the IDE runs.  Nil until the first debug command. }
var
  Session: TDebugSession = nil;

{ Where the program is stopped, for the editor's highlight.  Empty when
  nothing is stopped. }
function DebugStopFile: AnsiString;
function DebugStopLine: Integer;

implementation

var
  Breakpoints: TStringList = nil;   { 'expandedpath|line' }

{ -------------------------------------------------------------------------- }
{  Break point store                                                          }
{ -------------------------------------------------------------------------- }

function BPKey(const AFile: AnsiString; ALine: Integer): AnsiString;
begin
  Result := ExpandFileName(AFile) + '|' + IntToStr(ALine);
end;

procedure NeedBreakpoints;
begin
  if Breakpoints = nil then
  begin
    Breakpoints := TStringList.Create;
    Breakpoints.Sorted := True;
    Breakpoints.Duplicates := dupIgnore;
  end;
end;

function ToggleBreakpoint(const AFile: AnsiString; ALine: Integer): Boolean;
var
  Key: AnsiString;
  i: Integer;
begin
  NeedBreakpoints;
  Key := BPKey(AFile, ALine);
  i := Breakpoints.IndexOf(Key);
  if i >= 0 then
  begin
    Breakpoints.Delete(i);
    Result := False;
  end
  else
  begin
    Breakpoints.Add(Key);
    Result := True;
  end;
  if Session <> nil then
    Session.SendBreakpoint(AFile, ALine, Result);
end;

function IsBreakpoint(const AFile: AnsiString; ALine: Integer): Boolean;
begin
  if Breakpoints = nil then Exit(False);
  Result := Breakpoints.IndexOf(BPKey(AFile, ALine)) >= 0;
end;

{ Perl can only stop on a line that begins a statement.  When the backend
  reports that a break point landed somewhere else, move the marker to
  match, so the editor shows the truth rather than the request. }
procedure MoveBreakpoint(const AFile: AnsiString; FromLine, ToLine: Integer);
var
  i: Integer;
begin
  if (FromLine = ToLine) or (ToLine <= 0) then Exit;
  NeedBreakpoints;
  i := Breakpoints.IndexOf(BPKey(AFile, FromLine));
  if i >= 0 then Breakpoints.Delete(i);
  Breakpoints.Add(BPKey(AFile, ToLine));
end;

procedure ClearBreakpointsIn(const AFile: AnsiString);
var
  i: Integer;
  Prefix: AnsiString;
begin
  if Breakpoints = nil then Exit;
  Prefix := ExpandFileName(AFile) + '|';
  for i := Breakpoints.Count - 1 downto 0 do
    if Copy(Breakpoints[i], 1, Length(Prefix)) = Prefix then
      Breakpoints.Delete(i);
end;

function BreakpointCount: Integer;
begin
  if Breakpoints = nil then Result := 0 else Result := Breakpoints.Count;
end;

procedure BreakpointAt(i: Integer; out AFile: AnsiString; out ALine: Integer);
var
  S: AnsiString;
  P: Integer;
begin
  AFile := '';
  ALine := 0;
  if (Breakpoints = nil) or (i < 0) or (i >= Breakpoints.Count) then Exit;
  S := Breakpoints[i];
  P := LastDelimiter('|', S);
  if P = 0 then Exit;
  AFile := Copy(S, 1, P - 1);
  ALine := StrToIntDef(Copy(S, P + 1, Length(S)), 0);
end;

function DebugStopFile: AnsiString;
begin
  if (Session <> nil) and (Session.State = dsStopped) then
    Result := Session.CurFile
  else
    Result := '';
end;

function DebugStopLine: Integer;
begin
  if (Session <> nil) and (Session.State = dsStopped) then
    Result := Session.CurLine
  else
    Result := 0;
end;

{ ========================================================================== }
{  TDebugSession                                                             }
{ ========================================================================== }

constructor TDebugSession.Create;
begin
  inherited Create;
  FState     := dsOff;
  FSeq       := 0;
  FPending   := TFPList.Create;
  FPad       := TStringList.Create;
  FWatchVals := TStringList.Create;
  Watches    := TStringList.Create;
end;

destructor TDebugSession.Destroy;
begin
  Stop;
  FPending.Free;
  FPad.Free;
  FWatchVals.Free;
  Watches.Free;
  inherited Destroy;
end;

function TDebugSession.Send(const Cmd: AnsiString; Extra: TJSONObject): Integer;
var
  O: TJSONObject;
  Line: AnsiString;
begin
  Result := 0;
  if (FProc = nil) or (not FProc.Running) then Exit;

  Inc(FSeq);
  Result := FSeq;
  if Extra <> nil then O := Extra else O := TJSONObject.Create;
  try
    O.Add('cmd', Cmd);
    O.Add('seq', FSeq);
    Line := O.AsJSON + LineEnding;
    FProc.Input.Write(Line[1], Length(Line));
  finally
    O.Free;
  end;
end;

function TDebugSession.Start(const Script, Args: AnsiString): Boolean;
var
  O, BP: TJSONObject;
  A: TJSONArray;
  Parts: TStringArray;
  N, i: Integer;
  F: AnsiString;
  L: Integer;
  Msg: TJSONObject;
  LibDir: AnsiString;
begin
  Stop;
  FError := '';

  LibDir := Cfg.LibDir;
  if (LibDir = '') or
     (not FileExists(IncludeTrailingPathDelimiter(LibDir) + 'TurboPerl' +
                     PathDelim + 'Debug' + PathDelim + 'Bridge.pm')) then
  begin
    FError := 'the debugger bridge was not found; expected TurboPerl/Debug/' +
              'Bridge.pm under ' + LibDir;
    Exit(False);
  end;

  FProc := TProcess.Create(nil);
  FProc.Executable := Cfg.PerlExe;
  FProc.Parameters.Add('-I' + LibDir);
  FProc.Parameters.Add('-MTurboPerl::Debug::Bridge');
  FProc.Parameters.Add('-e');
  FProc.Parameters.Add('TurboPerl::Debug::Bridge::run()');
  FProc.CurrentDirectory := ExtractFilePath(ExpandFileName(Script));
  FProc.Options := [poUsePipes];
  try
    FProc.Execute;
  except
    on E: Exception do
    begin
      FError := 'could not start the debugger bridge: ' + E.Message;
      FreeAndNil(FProc);
      Exit(False);
    end;
  end;

  FState   := dsStarting;
  FInbox   := '';
  FStderr  := '';
  FOutput  := '';
  FChanged := True;

  { Hand over the program, its arguments and every break point at once, so
    the bridge can have them all in place before the program starts. }
  O := TJSONObject.Create;
  O.Add('program', ExpandFileName(Script));
  O.Add('perl', Cfg.PerlExe);

  A := TJSONArray.Create;
  SplitArgs(Args, Parts, N);
  for i := 0 to N - 1 do A.Add(Parts[i]);
  O.Add('args', A);

  A := TJSONArray.Create;
  for i := 0 to BreakpointCount - 1 do
  begin
    BreakpointAt(i, F, L);
    if F = '' then Continue;
    BP := TJSONObject.Create;
    BP.Add('file', F);
    BP.Add('line', L);
    A.Add(BP);
  end;
  O.Add('breakpoints', A);

  A := TJSONArray.Create;
  for i := 0 to Watches.Count - 1 do A.Add(Watches[i]);
  O.Add('watches', A);

  Send('start', O);

  { Starting is the one thing worth waiting for: until it is done there is
    nothing to show, and any error belongs in front of the user now.  Perl
    has to compile the program first, so allow for a slow one. }
  Msg := WaitFor('stopped', 30000);
  if Msg = nil then
  begin
    DrainStderr;
    if FError = '' then
    begin
      if Trim(FStderr) <> '' then
        { Almost always the real explanation: Devel::ebug not installed, or
          the program failing to compile under the debugger. }
        FError := 'the debugger did not start: ' + Trim(Copy(FStderr, 1, 300))
      else
        FError := 'the debugger did not start, and said nothing about why; ' +
                  'check that Devel::ebug is installed for ' + Cfg.PerlExe;
    end;
    Stop;
    Exit(False);
  end;
  Apply(Msg);
  Msg.Free;
  Result := FState in [dsStopped, dsFinished];
  if not Result and (FError = '') then FError := 'the program did not load';
end;

procedure TDebugSession.Stop;
var
  i: Integer;
begin
  if FProc <> nil then
  begin
    try
      if FProc.Running then
      begin
        Send('quit', nil);
        FProc.Terminate(0);
      end;
    except
    end;
    FreeAndNil(FProc);
  end;
  for i := 0 to FPending.Count - 1 do TJSONObject(FPending[i]).Free;
  FPending.Clear;
  SetLength(FStack, 0);
  FPad.Clear;
  SetLength(FVars, 0);
  FWatchVals.Clear;
  FState   := dsOff;
  FFile    := '';
  FLine    := 0;
  FSub     := '';
  FChanged := True;
end;

{ -------------------------------------------------------------------------- }
{  Reading                                                                    }
{ -------------------------------------------------------------------------- }

{ The bridge's stderr has to be read whether or not anyone wants it: left
  alone it fills its pipe and the bridge stops dead.  It is also the only
  place a startup failure explains itself - a missing Devel::ebug, say. }
procedure TDebugSession.DrainStderr;
var
  Buf  : array[0..4095] of Byte;
  Got  : LongInt;
  Avail: LongInt;
  Chunk: AnsiString;
begin
  if FProc = nil then Exit;
  while True do
  begin
    Avail := FProc.Stderr.NumBytesAvailable;
    if Avail <= 0 then Break;
    if Avail > SizeOf(Buf) then Avail := SizeOf(Buf);
    Got := FProc.Stderr.Read(Buf, Avail);
    if Got <= 0 then Break;
    SetLength(Chunk, Got);
    Move(Buf, Chunk[1], Got);
    if Length(FStderr) < 8192 then FStderr := FStderr + Chunk;
  end;
end;

procedure TDebugSession.Drain;
var
  Buf   : array[0..8191] of Byte;
  Got   : LongInt;
  Avail : LongInt;
  Chunk : AnsiString;
  NL    : Integer;
  Line  : AnsiString;
  D     : TJSONData;
begin
  if FProc = nil then Exit;
  DrainStderr;

  while True do
  begin
    Avail := FProc.Output.NumBytesAvailable;
    if Avail <= 0 then Break;
    if Avail > SizeOf(Buf) then Avail := SizeOf(Buf);
    Got := FProc.Output.Read(Buf, Avail);
    if Got <= 0 then Break;
    SetLength(Chunk, Got);
    Move(Buf, Chunk[1], Got);
    FInbox := FInbox + Chunk;
  end;

  { Whole lines only; a partial one waits for the next poll. }
  repeat
    NL := Pos(#10, FInbox);
    if NL = 0 then Break;
    Line := Copy(FInbox, 1, NL - 1);
    System.Delete(FInbox, 1, NL);
    Line := TrimRight(Line);
    if Line = '' then Continue;

    D := nil;
    try
      D := GetJSON(Line);
    except
      on E: Exception do
      begin
        FError := 'bad message from the bridge: ' + E.Message;
        D := nil;
      end;
    end;
    if (D <> nil) and (D is TJSONObject) then
      FPending.Add(D)
    else
      D.Free;
  until False;
end;

function TDebugSession.NextMessage: TJSONObject;
begin
  Result := nil;
  if FPending.Count = 0 then Exit;
  Result := TJSONObject(FPending[0]);
  FPending.Delete(0);
end;

procedure TDebugSession.SetStoppedFrom(Msg: TJSONObject);
var
  A    : TJSONArray;
  O    : TJSONObject;
  i    : Integer;
  Names: TJSONObject;
begin
  FPid := Msg.Get('pid', 0);

  if Msg.Get('finished', False) then
  begin
    FState := dsFinished;
    FFile  := '';
    FLine  := 0;
    FSub   := '';
    SetLength(FStack, 0);
    FPad.Clear;
    SetLength(FVars, 0);
    Exit;
  end;

  FState    := dsStopped;
  FFile     := Msg.Get('file', '');
  FLine     := Msg.Get('line', 0);
  FSub      := Msg.Get('subroutine', '');
  FCodeLine := Msg.Get('codeline', '');

  SetLength(FStack, 0);
  A := TJSONArray(Msg.Find('stack'));
  if A <> nil then
  begin
    SetLength(FStack, A.Count);
    for i := 0 to A.Count - 1 do
    begin
      O := TJSONObject(A.Items[i]);
      FStack[i].Subroutine := O.Get('subroutine', '');
      FStack[i].FileName   := O.Get('file', '');
      FStack[i].Line       := O.Get('line', 0);
      FStack[i].Args       := O.Get('args', '');
    end;
  end;

  FPad.Clear;
  Names := TJSONObject(Msg.Find('pad'));
  if Names <> nil then
    for i := 0 to Names.Count - 1 do
      FPad.Add(Names.Names[i] + '=' + Names.Items[i].AsString);

  SetLength(FVars, 0);
  FVarCount := 0;
  ReadVars(TJSONArray(Msg.Find('vars')), 0, '');
  SetLength(FVars, FVarCount);

  ReadWatches(Msg);
end;

procedure TDebugSession.ReadVars(A: TJSONArray; Depth: Integer;
                                 const Parent: AnsiString);
var
  i, n: Integer;
  O   : TJSONObject;
  Kids: TJSONArray;
begin
  if A = nil then Exit;
  for i := 0 to A.Count - 1 do
  begin
    O := TJSONObject(A.Items[i]);
    Kids := TJSONArray(O.Find('k'));
    n := FVarCount;
    Inc(FVarCount);
    if n >= Length(FVars) then SetLength(FVars, 2 * n + 16);
    FVars[n].Depth   := Depth;
    FVars[n].Name    := O.Get('n', '');
    FVars[n].Value   := O.Get('v', '');
    { #1 cannot turn up in a name, so paths cannot run into one another. }
    FVars[n].Path    := Parent + #1 + FVars[n].Name;
    FVars[n].HasKids := (Kids <> nil) and (Kids.Count > 0);
    ReadVars(Kids, Depth + 1, FVars[n].Path);
  end;
end;

procedure TDebugSession.ReadWatches(Msg: TJSONObject);
var
  A: TJSONArray;
  i: Integer;
begin
  A := TJSONArray(Msg.Find('watches'));
  if A = nil then Exit;
  FWatchVals.Clear;
  for i := 0 to A.Count - 1 do
    FWatchVals.Add(TJSONObject(A.Items[i]).Get('value', ''));
end;

procedure TDebugSession.Apply(Msg: TJSONObject);
var
  Ev     : AnsiString;
  Actual : Integer;
  Line   : Integer;
  AFile  : AnsiString;
begin
  Ev := Msg.Get('ev', '');

  if Ev = 'stopped' then
  begin
    SetStoppedFrom(Msg);
    FOutput  := FOutput + Msg.Get('output', '');
    FChanged := True;
  end
  else if Ev = 'breakpoint' then
  begin
    AFile  := Msg.Get('file', '');
    Line   := Msg.Get('line', 0);
    Actual := Msg.Get('actual', 0);
    if (Actual > 0) and (Actual <> Line) then
      MoveBreakpoint(AFile, Line, Actual);
    FChanged := True;
  end
  else if Ev = 'watches' then
  begin
    ReadWatches(Msg);
    FChanged := True;
  end
  else if Ev = 'error' then
  begin
    FError   := Msg.Get('message', 'unknown error');
    FChanged := True;
  end;
end;

{ Pump the pipe until a particular event turns up, applying everything else
  that arrives on the way.  Only for the handful of places that cannot carry
  on without an answer: starting up, and evaluating an expression for a
  dialog.  The program is stopped in both cases, so the wait is brief.

  The returned object belongs to the caller. }
function TDebugSession.WaitFor(const Ev: AnsiString; TimeoutMs: Integer): TJSONObject;
var
  Deadline: QWord;
  Msg: TJSONObject;
begin
  Result := nil;
  if FProc = nil then Exit;
  Deadline := GetTickCount64 + QWord(TimeoutMs);

  while True do
  begin
    Drain;
    while True do
    begin
      Msg := NextMessage;
      if Msg = nil then Break;
      if Msg.Get('ev', '') = Ev then Exit(Msg);
      Apply(Msg);
      Msg.Free;
    end;

    if not FProc.Running then Exit(nil);
    if GetTickCount64 > Deadline then Exit(nil);
    Sleep(5);
  end;
end;

function TDebugSession.Poll: Boolean;
var
  Msg: TJSONObject;
begin
  Result := False;
  if FProc = nil then Exit;

  if not FProc.Running then
  begin
    Drain;
    while True do
    begin
      Msg := NextMessage;
      if Msg = nil then Break;
      Apply(Msg);
      Msg.Free;
    end;
    if FState <> dsOff then
    begin
      FState   := dsFinished;
      FChanged := True;
    end;
    Result := FChanged;
    FChanged := False;
    Exit;
  end;

  Drain;
  while True do
  begin
    Msg := NextMessage;
    if Msg = nil then Break;
    Apply(Msg);
    Msg.Free;
  end;

  Result   := FChanged;
  FChanged := False;
end;

function TDebugSession.TakeOutput: AnsiString;
begin
  Result  := FOutput;
  FOutput := '';
end;

function TDebugSession.StackCount: Integer;
begin
  Result := Length(FStack);
end;

function TDebugSession.StackFrame(i: Integer): TStackFrame;
begin
  { Not FillChar: the record holds strings, and zeroing them behind the
    compiler's back loses their reference counts. }
  Result := Default(TStackFrame);
  if (i >= 0) and (i < Length(FStack)) then Result := FStack[i];
end;

{ -------------------------------------------------------------------------- }
{  Commands                                                                   }
{ -------------------------------------------------------------------------- }

procedure TDebugSession.Go;
begin
  if FState <> dsStopped then Exit;
  FState := dsRunning;
  Send('run', nil);
end;

procedure TDebugSession.StepInto;
begin
  if FState <> dsStopped then Exit;
  FState := dsRunning;
  Send('step', nil);
end;

procedure TDebugSession.StepOver;
begin
  if FState <> dsStopped then Exit;
  FState := dsRunning;
  Send('next', nil);
end;

procedure TDebugSession.StepOut;
begin
  if FState <> dsStopped then Exit;
  FState := dsRunning;
  Send('return', nil);
end;

procedure TDebugSession.RunTo(const AFile: AnsiString; ALine: Integer);
var
  O: TJSONObject;
begin
  if FState <> dsStopped then Exit;
  O := TJSONObject.Create;
  O.Add('file', ExpandFileName(AFile));
  O.Add('line', ALine);
  FState := dsRunning;
  Send('runto', O);
end;

{ The bridge is sitting in a blocking run() and cannot act on a request, so
  the debuggee is signalled directly.  Its own SIGINT handler drops it back
  into the debugger, run() returns, and the stop arrives as usual. }
procedure TDebugSession.Interrupt;
begin
  if (FState <> dsRunning) or (FPid <= 0) then Exit;
  {$IFDEF UNIX}
  FpKill(FPid, SIGINT);
  {$ENDIF}
end;

procedure TDebugSession.SendBreakpoint(const AFile: AnsiString; ALine: Integer;
                                       Setting: Boolean);
var
  O: TJSONObject;
begin
  if FProc = nil then Exit;
  O := TJSONObject.Create;
  O.Add('file', ExpandFileName(AFile));
  O.Add('line', ALine);
  if Setting then Send('setbp', O) else Send('clearbp', O);
end;

function TDebugSession.Evaluate(const Expr: AnsiString): AnsiString;
var
  O, Msg: TJSONObject;
begin
  Result := '';
  if FState <> dsStopped then Exit('<the program is not stopped>');
  O := TJSONObject.Create;
  O.Add('expr', Expr);
  Send('eval', O);
  Msg := WaitFor('value', 10000);
  if Msg = nil then Exit('<no answer from the debugger>');
  Result := Msg.Get('value', '');
  Msg.Free;
end;

procedure TDebugSession.SendWatches;
var
  O: TJSONObject;
  A: TJSONArray;
  i: Integer;
begin
  if FProc = nil then Exit;
  O := TJSONObject.Create;
  A := TJSONArray.Create;
  for i := 0 to Watches.Count - 1 do A.Add(Watches[i]);
  O.Add('watches', A);
  Send('watch', O);
end;

end.
