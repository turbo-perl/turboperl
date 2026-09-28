{ Headless exerciser for the debugger session: drives the real bridge and a
  real debuggee, with no user interface involved. }
program DbgTest;
{$mode objfpc}{$H+}
uses SysUtils, TPConst, TPConfig, TPPerl, TPDebug;

var Fails: Integer = 0;

procedure Check(const What: AnsiString; Ok: Boolean; const Got: AnsiString = '');
begin
  if Ok then
    WriteLn('ok   ', What)
  else
  begin
    Inc(Fails);
    Write('FAIL ', What);
    if Got <> '' then Write('  (got: ', Got, ')');
    WriteLn;
  end;
end;

{ Movement is asynchronous; wait for the session to come to rest. }
function Settle(S: TDebugSession; TimeoutMs: Integer): Boolean;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    S.Poll;
    if S.State in [dsStopped, dsFinished, dsOff] then Exit(True);
    Sleep(5);
  end;
  Result := False;
end;

var
  S: TDebugSession;
  Script: AnsiString;
  Out_: AnsiString;
  i: Integer;
  Frame: TStackFrame;
begin
  LoadConfig;
  Cfg.LibDir := ExpandFileName('lib');
  Script := ExpandFileName('examples/debugdemo.pl');

  S := TDebugSession.Create;

  { line 9 is "$total += $n;" inside add() }
  ToggleBreakpoint(Script, 9);
  Check('breakpoint recorded', IsBreakpoint(Script, 9));

  if not S.Start(Script, '') then
  begin
    WriteLn('FAIL could not start: ', S.Error);
    Halt(1);
  end;
  Check('session started', S.State = dsStopped, IntToStr(Ord(S.State)));

  S.Go;
  Check('run reached the breakpoint', Settle(S, 20000) and (S.CurLine = 9),
        'line ' + IntToStr(S.CurLine));
  Check('stopped inside add()', Pos('add', S.CurSub) > 0, S.CurSub);
  Check('call stack has a frame', S.StackCount >= 1, IntToStr(S.StackCount));
  Frame := S.StackFrame(0);
  Check('frame names the sub', Pos('add', Frame.Subroutine) > 0, Frame.Subroutine);

  Check('lexicals are visible', S.Pad.IndexOfName('$n') >= 0, S.Pad.Text);
  Check('$n is 1 on the first call', S.Pad.Values['$n'] = '1', S.Pad.Values['$n']);

  Check('eval runs in the stopped frame', S.Evaluate('$n * 10') = '10',
        S.Evaluate('$n * 10'));

  S.StepOut;
  Check('step out leaves add()', Settle(S, 10000) and (Pos('add', S.CurSub) = 0), S.CurSub);

  S.Go;
  Settle(S, 20000);
  Out_ := S.TakeOutput;
  Check('program output is captured', Pos('after 1: 1', Out_) > 0, Out_);
  Check('$n is 2 on the second call', S.Pad.Values['$n'] = '2', S.Pad.Values['$n']);

  { Run out the remaining calls and off the end. }
  for i := 1 to 6 do
  begin
    if S.State = dsFinished then Break;
    S.Go;
    Settle(S, 20000);
  end;
  Check('the program finishes', S.State = dsFinished, IntToStr(Ord(S.State)));
  Out_ := S.TakeOutput;
  Check('final output arrived', Pos('done: 6', Out_) > 0, Out_);

  S.Free;

  WriteLn;
  if Fails = 0 then WriteLn('all debugger tests passed')
  else begin WriteLn(Fails, ' FAILURES'); Halt(1); end;
end.
