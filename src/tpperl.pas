{ ========================================================================== }
{  TurboPerl - Unit: TPPerl                                                  }
{                                                                            }
{  Everything that shells out to perl: running a script and capturing what   }
{  it prints, checking syntax, deparsing, perldoc lookups and running the    }
{  external tidy/critic helpers.                                             }
{                                                                            }
{  Also the parser for perl's diagnostics, which turns lines such as         }
{                                                                            }
{      Global symbol "$x" requires explicit package name at t.pl line 5.     }
{                                                                            }
{  into a file name and a line number the IDE can jump to.                   }
{ ========================================================================== }
unit TPPerl;

{$mode objfpc}{$H-}

interface

uses
  SysUtils, Classes, Process;

const
  { Beyond this we stop reading; a runaway script should not take the IDE
    down with it. }
  MaxCaptureBytes = 4 * 1024 * 1024;

type
  TRunResult = record
    Output    : AnsiString;  { stdout, plus stderr unless it was split off }
    ErrOutput : AnsiString;  { stderr, only when SplitErr was asked for }
    ExitCode  : Integer;
    TimedOut  : Boolean;
    Launched  : Boolean;     { False when the program could not be started }
    ErrMsg    : AnsiString;  { why it could not be started }
    Truncated : Boolean;
  end;

  TPerlMsg = record
    Text     : AnsiString;
    FileName : AnsiString;
    Line     : Integer;      { 0 when the message carries no location }
    IsError  : Boolean;
  end;

  TPerlMsgList = array of TPerlMsg;

{ Run a program, capture stdout and stderr together and wait for it to
  finish.  TimeoutMs <= 0 means wait indefinitely.

  ExtraEnv holds NAME=VALUE strings added to (or replacing entries in) the
  inherited environment.  Passing an empty array inherits it unchanged. }
function RunCaptured(const Exe: AnsiString; const Args: array of AnsiString;
                     const WorkDir, StdInput: AnsiString;
                     const ExtraEnv: array of AnsiString;
                     TimeoutMs: Integer): TRunResult; overload;
function RunCaptured(const Exe: AnsiString; const Args: array of AnsiString;
                     const WorkDir, StdInput: AnsiString;
                     TimeoutMs: Integer): TRunResult; overload;

{ As above but keeps stderr apart, which is what a filter such as perltidy
  needs: its diagnostics must not end up spliced into the source it emits. }
function RunFilter(const Exe: AnsiString; const Args: array of AnsiString;
                   const WorkDir, StdInput: AnsiString;
                   const ExtraEnv: array of AnsiString;
                   TimeoutMs: Integer): TRunResult;

{ Run a program on the real terminal, inheriting stdin, stdout and stderr,
  and wait for it.  The caller is responsible for having handed the terminal
  back first.  Returns the exit code, or -1 if it would not start. }
function RunOnConsole(const Exe: AnsiString; const Args: array of AnsiString;
                      const WorkDir: AnsiString;
                      const ExtraEnv: array of AnsiString): Integer;

{ Locate a program on PATH.  Returns '' when it is not there. }
function FindOnPath(const Name: AnsiString): AnsiString;

{ Pull the "at FILE line N" locations out of a block of perl output. }
function ParseDiagnostics(const Output: AnsiString): TPerlMsgList;

{ Keep only the entries that point at a source line.  Run output is mostly
  whatever the script printed, and turning all of that into "messages" would
  bury the one line that actually says what went wrong. }
function DiagnosticsOnly(const M: TPerlMsgList): TPerlMsgList;

{ True when perl said nothing worse than "syntax OK". }
function SyntaxOK(const Output: AnsiString): Boolean;

{ The identifier under a cursor, for perldoc lookups. }
function WordAround(const Line: AnsiString; Col: Integer): AnsiString;

implementation

{ -------------------------------------------------------------------------- }

function FindOnPath(const Name: AnsiString): AnsiString;
var
  Path, Dir, Candidate: AnsiString;
  P: Integer;
begin
  Result := '';
  if Name = '' then Exit;

  { An explicit path is taken as given.  Windows accepts a forward slash as
    well as its own separator, so look for either. }
  if (Pos('/', Name) > 0) or (Pos(PathDelim, Name) > 0) then
  begin
    if FileExists(Name) then Result := Name;
    Exit;
  end;

  Path := GetEnvironmentVariable('PATH');
  while Path <> '' do
  begin
    { PathSeparator is what the operating system puts between entries in a
      list of directories: a colon here, a semicolon on Windows, where a
      colon would split C:\... down the middle instead. }
    P := Pos(PathSeparator, Path);
    if P = 0 then
    begin
      Dir  := Path;
      Path := '';
    end
    else
    begin
      Dir  := Copy(Path, 1, P - 1);
      Delete(Path, 1, P);
    end;
    if Dir = '' then Continue;
    Candidate := IncludeTrailingPathDelimiter(Dir) + Name;
    if FileExists(Candidate) then
      Exit(Candidate);
  end;
end;

{ -------------------------------------------------------------------------- }

{ Build a full environment block from the inherited one plus overrides. }
procedure ApplyEnv(P: TProcess; const ExtraEnv: array of AnsiString);
var
  i, j, Eq : Integer;
  Entry    : AnsiString;
  Name     : AnsiString;
  Replaced : Boolean;
begin
  if Length(ExtraEnv) = 0 then Exit;     { inherit unchanged }

  for i := 1 to GetEnvironmentVariableCount do
    P.Environment.Add(GetEnvironmentString(i));

  for j := Low(ExtraEnv) to High(ExtraEnv) do
  begin
    Entry := ExtraEnv[j];
    Eq := Pos('=', Entry);
    if Eq <= 1 then Continue;
    Name := Copy(Entry, 1, Eq);          { includes the '=' }
    Replaced := False;
    for i := 0 to P.Environment.Count - 1 do
      if Copy(P.Environment[i], 1, Length(Name)) = Name then
      begin
        P.Environment[i] := Entry;
        Replaced := True;
        Break;
      end;
    if not Replaced then P.Environment.Add(Entry);
  end;
end;

{ The one implementation behind all the capturing variants. }
function RunWorker(const Exe: AnsiString; const Args: array of AnsiString;
                   const WorkDir, StdInput: AnsiString;
                   const ExtraEnv: array of AnsiString;
                   TimeoutMs: Integer; SplitErr: Boolean): TRunResult; forward;

function RunCaptured(const Exe: AnsiString; const Args: array of AnsiString;
                     const WorkDir, StdInput: AnsiString;
                     TimeoutMs: Integer): TRunResult;
begin
  Result := RunCaptured(Exe, Args, WorkDir, StdInput, [], TimeoutMs);
end;

function RunOnConsole(const Exe: AnsiString; const Args: array of AnsiString;
                      const WorkDir: AnsiString;
                      const ExtraEnv: array of AnsiString): Integer;
var
  P: TProcess;
  i: Integer;
begin
  Result := -1;
  P := TProcess.Create(nil);
  try
    try
      P.Executable := Exe;
      for i := Low(Args) to High(Args) do P.Parameters.Add(Args[i]);
      if WorkDir <> '' then P.CurrentDirectory := WorkDir;
      ApplyEnv(P, ExtraEnv);
      { No poUsePipes: the child gets the terminal the IDE just gave back. }
      P.Options := [];
      P.Execute;
      { Poll Running rather than calling WaitOnExit.  Reading the Running
        property is what reaps the child and decodes its wait status into
        ExitCode; WaitOnExit leaves ExitCode reading zero. }
      while P.Running do Sleep(10);
      Result := P.ExitCode;
    except
      Result := -1;
    end;
  finally
    P.Free;
  end;
end;

function RunFilter(const Exe: AnsiString; const Args: array of AnsiString;
                   const WorkDir, StdInput: AnsiString;
                   const ExtraEnv: array of AnsiString;
                   TimeoutMs: Integer): TRunResult;
begin
  Result := RunWorker(Exe, Args, WorkDir, StdInput, ExtraEnv, TimeoutMs, True);
end;

function RunCaptured(const Exe: AnsiString; const Args: array of AnsiString;
                     const WorkDir, StdInput: AnsiString;
                     const ExtraEnv: array of AnsiString;
                     TimeoutMs: Integer): TRunResult;
begin
  Result := RunWorker(Exe, Args, WorkDir, StdInput, ExtraEnv, TimeoutMs, False);
end;

function RunWorker(const Exe: AnsiString; const Args: array of AnsiString;
                   const WorkDir, StdInput: AnsiString;
                   const ExtraEnv: array of AnsiString;
                   TimeoutMs: Integer; SplitErr: Boolean): TRunResult;
var
  P       : TProcess;
  Buf     : array[0..8191] of Byte;
  Got     : LongInt;
  Avail   : LongInt;
  Started : QWord;
  Chunk   : AnsiString;
  i       : Integer;
  Total   : SizeInt;
begin
  Result.Output    := '';
  Result.ErrOutput := '';
  Result.ExitCode  := -1;
  Result.TimedOut  := False;
  Result.Launched  := False;
  Result.ErrMsg    := '';
  Result.Truncated := False;
  Total := 0;

  P := TProcess.Create(nil);
  try
    try
      P.Executable := Exe;
      for i := Low(Args) to High(Args) do
        P.Parameters.Add(Args[i]);
      if WorkDir <> '' then P.CurrentDirectory := WorkDir;
      ApplyEnv(P, ExtraEnv);
      { Merging stderr into stdout keeps warnings and output in the order
        the script produced them, which is what you want when reading a run
        log.  A filter needs them apart instead. }
      if SplitErr then
        P.Options := [poUsePipes]
      else
        P.Options := [poUsePipes, poStderrToOutPut];
      P.ShowWindow := swoHide;
      P.Execute;
      Result.Launched := True;
    except
      on E: Exception do
      begin
        Result.ErrMsg := E.Message;
        Exit;
      end;
    end;

    { Feed stdin, then close it so the child sees EOF rather than hanging. }
    try
      if StdInput <> '' then
        P.Input.Write(StdInput[1], Length(StdInput));
    except
      { a child that never reads stdin may already have gone away }
    end;
    try
      P.CloseInput;
    except
    end;

    Started := GetTickCount64;

    { Drain the pipes while the child lives, and keep draining afterwards so
      that nothing buffered at exit is lost.  When stderr has its own pipe it
      must be drained too, or a chatty child fills it and blocks forever. }
    while True do
    begin
      if SplitErr then
      begin
        Avail := P.Stderr.NumBytesAvailable;
        if Avail > 0 then
        begin
          if Avail > SizeOf(Buf) then Avail := SizeOf(Buf);
          Got := P.Stderr.Read(Buf, Avail);
          if Got > 0 then
          begin
            SetLength(Chunk, Got);
            Move(Buf, Chunk[1], Got);
            if Length(Result.ErrOutput) < MaxCaptureBytes then
              Result.ErrOutput := Result.ErrOutput + Chunk;
            Continue;
          end;
        end;
      end;

      Avail := P.Output.NumBytesAvailable;
      if Avail > 0 then
      begin
        if Avail > SizeOf(Buf) then Avail := SizeOf(Buf);
        Got := P.Output.Read(Buf, Avail);
        if Got > 0 then
        begin
          if Total + Got > MaxCaptureBytes then
          begin
            Got := MaxCaptureBytes - Total;
            Result.Truncated := True;
          end;
          if Got > 0 then
          begin
            SetLength(Chunk, Got);
            Move(Buf, Chunk[1], Got);
            Result.Output := Result.Output + Chunk;
            Inc(Total, Got);
          end;
          if Result.Truncated then
          begin
            P.Terminate(1);
            Break;
          end;
          Continue;             { there may be more waiting }
        end;
      end;

      if not P.Running then
      begin
        { One last look: the child may have written just before exiting. }
        if P.Output.NumBytesAvailable > 0 then Continue;
        if SplitErr and (P.Stderr.NumBytesAvailable > 0) then Continue;
        Break;
      end;

      if (TimeoutMs > 0) and (GetTickCount64 - Started > QWord(TimeoutMs)) then
      begin
        Result.TimedOut := True;
        P.Terminate(1);
        Break;
      end;

      Sleep(5);
    end;

    if not Result.TimedOut then
    begin
      try
        { The drain loop above already polled Running to completion, which
          is what decodes the child's wait status.  ExitCode then holds the
          value passed to exit(); ExitStatus would hand back the raw status
          from wait(), and WaitOnExit would leave ExitCode reading zero. }
        while P.Running do Sleep(5);
        Result.ExitCode := P.ExitCode;
      except
      end;
    end;
  finally
    P.Free;
  end;
end;

{ -------------------------------------------------------------------------- }
{  Diagnostics                                                                }
{ -------------------------------------------------------------------------- }

function IsDigitCh(C: Char): Boolean;
begin
  Result := (C >= '0') and (C <= '9');
end;

{ Find "at <file> line <n>" inside one line of perl output.

  We look for " line " followed by digits and then walk back to the nearest
  " at " before it, which is what introduces the file name.  The search runs
  left to right and stops at the first hit: "Died at t.pl line 20, <FH> line
  7." carries the source location first and a filehandle's input line number
  second, and it is the first one we want. }
procedure SplitLocation(const S: AnsiString; out FName: AnsiString;
                        out LineNo: Integer);
var
  i, j, NumStart, AtPos, N, Code: Integer;
  Cand: AnsiString;
begin
  FName  := '';
  LineNo := 0;

  for i := 1 to Length(S) - 6 do
  begin
    if Copy(S, i, 6) <> ' line ' then Continue;

    NumStart := i + 6;
    j := NumStart;
    while (j <= Length(S)) and IsDigitCh(S[j]) do Inc(j);
    if j = NumStart then Continue;

    { Nearest " at " to the left. }
    AtPos := 0;
    for N := i - 1 downto 1 do
      if Copy(S, N, 4) = ' at ' then
      begin
        AtPos := N;
        Break;
      end;
    if AtPos = 0 then Continue;

    Cand := Copy(S, AtPos + 4, i - (AtPos + 4));
    { A file name of "-" or "-e" means perl read the script from stdin or
      from the command line, so there is nothing to jump to. }
    if (Cand = '') or (Cand = '-') or (Cand = '-e') then Continue;

    Val(Copy(S, NumStart, j - NumStart), N, Code);
    if (Code <> 0) or (N <= 0) then Continue;

    FName  := Cand;
    LineNo := N;
    Exit;
  end;
end;

function ParseDiagnostics(const Output: AnsiString): TPerlMsgList;
var
  Lines  : TStringList;
  i, N   : Integer;
  Txt, F : AnsiString;
  LineNo : Integer;
  Low    : AnsiString;
begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    N := 0;
    SetLength(Result, Lines.Count);
    for i := 0 to Lines.Count - 1 do
    begin
      Txt := TrimRight(Lines[i]);
      if Trim(Txt) = '' then Continue;

      SplitLocation(Txt, F, LineNo);

      Low := LowerCase(Txt);
      { Perl's own wording is the most reliable signal we have: warnings
        are phrased as such, everything else with a location is an error. }
      Result[N].IsError :=
        (Pos('syntax error', Low) > 0) or
        (Pos('error', Low) > 0) or
        (Pos('can''t locate', Low) > 0) or
        (Pos('can''t ', Low) > 0) or
        (Pos('died', Low) > 0) or
        (Pos('aborted', Low) > 0) or
        ((LineNo > 0) and (Pos('warning', Low) = 0) and
                          (Pos('possible typo', Low) = 0) and
                          (Pos('used only once', Low) = 0) and
                          (Pos('uninitialized', Low) = 0) and
                          (Pos('deprecated', Low) = 0));

      Result[N].Text     := Txt;
      Result[N].FileName := F;
      Result[N].Line     := LineNo;
      Inc(N);
    end;
    SetLength(Result, N);
  finally
    Lines.Free;
  end;
end;

function DiagnosticsOnly(const M: TPerlMsgList): TPerlMsgList;
var
  i, N: Integer;
begin
  Result := nil;
  SetLength(Result, Length(M));
  N := 0;
  for i := 0 to High(M) do
    if M[i].Line > 0 then
    begin
      Result[N] := M[i];
      Inc(N);
    end;
  SetLength(Result, N);
end;

function SyntaxOK(const Output: AnsiString): Boolean;
begin
  Result := Pos(' syntax OK', Output) > 0;
end;

{ -------------------------------------------------------------------------- }

function WordAround(const Line: AnsiString; Col: Integer): AnsiString;
var
  A, B, L: Integer;

  function IsWordCh(C: Char): Boolean;
  begin
    Result := (C = '_') or ((C >= 'A') and (C <= 'Z')) or
              ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'));
  end;

begin
  Result := '';
  L := Length(Line);
  if L = 0 then Exit;
  if Col < 1 then Col := 1;
  if Col > L then Col := L;

  { If the cursor sits just past the end of a word, step back onto it. }
  if (not IsWordCh(Line[Col])) and (Col > 1) and IsWordCh(Line[Col - 1]) then
    Dec(Col);
  if not IsWordCh(Line[Col]) then Exit;

  A := Col;
  while (A > 1) and IsWordCh(Line[A - 1]) do Dec(A);
  B := Col;
  while (B < L) and IsWordCh(Line[B + 1]) do Inc(B);

  { Take in the :: of a package name if there is one on either side. }
  while (A > 2) and (Line[A - 1] = ':') and (Line[A - 2] = ':') do
  begin
    Dec(A, 2);
    while (A > 1) and IsWordCh(Line[A - 1]) do Dec(A);
  end;
  while (B + 2 <= L) and (Line[B + 1] = ':') and (Line[B + 2] = ':') do
  begin
    Inc(B, 2);
    while (B < L) and IsWordCh(Line[B + 1]) do Inc(B);
  end;

  Result := Copy(Line, A, B - A + 1);
end;

end.
