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

  { Data structures show their contents, not ARRAY(0x...). }
  Script := ExpandFileName('examples/datademo.pl');
  ToggleBreakpoint(Script, 10);
  S := TDebugSession.Create;
  if not S.Start(Script, '') then
  begin
    WriteLn('FAIL could not start: ', S.Error);
    Halt(1);
  end;
  S.Go;
  Check('run reached the print', Settle(S, 20000) and (S.CurLine = 10),
        'line ' + IntToStr(S.CurLine));
  Check('an array shows its elements', S.Pad.Values['@primes'] = '(2, 3, 5, 7)',
        S.Pad.Values['@primes']);
  Check('a hash shows its pairs', S.Pad.Values['%ages'] = '(alice => 31, bob => 27)',
        S.Pad.Values['%ages']);
  Check('a reference shows what it refers to',
        S.Pad.Values['$point'] = '{x => 1, y => [2, 3]}', S.Pad.Values['$point']);
  Check('an object shows its class', S.Pad.Values['$pet'] = 'Dog {name => ''Rex''}',
        S.Pad.Values['$pet']);
  S.Watches.Add('@primes');
  S.Watches.Add('scalar @primes');
  S.SendWatches;
  Settle(S, 5000);
  for i := 1 to 50 do
  begin
    S.Poll;
    if S.WatchVals.Count = 2 then Break;
    Sleep(20);
  end;
  Check('a watch on an array shows its elements',
        (S.WatchVals.Count = 2) and (S.WatchVals[0] = '(2, 3, 5, 7)'), S.WatchVals.Text);
  Check('a watch can still ask for the count',
        (S.WatchVals.Count = 2) and (S.WatchVals[1] = '4'), S.WatchVals.Text);
  S.Free;

  WriteLn;
  if Fails = 0 then WriteLn('all debugger tests passed')
  else begin WriteLn(Fails, ' FAILURES'); Halt(1); end;
end.
