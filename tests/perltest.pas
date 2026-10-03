{ Headless exerciser for the TPPerl unit. }
program PerlTest;
{$mode objfpc}{$H+}
uses SysUtils, Classes, TPPerl;

procedure ShowDiag(const Title, Output: AnsiString);
var
  M: TPerlMsgList;
  i: Integer;
begin
  WriteLn('--- ', Title, ' ---');
  M := ParseDiagnostics(Output);
  for i := 0 to High(M) do
    WriteLn(Format('  [%s] %s:%d  %s',
      [BoolToStr(M[i].IsError, 'ERR', 'wrn'), M[i].FileName, M[i].Line, M[i].Text]));
end;

var
  R: TRunResult;
  Perl: AnsiString;
{$ifdef MSWINDOWS}
  Bat: AnsiString;
  Lines: TStringList;
{$endif}
begin
  Perl := FindOnPath('perl');
  WriteLn('perl found at: ', Perl);
  { The rest only prints, for reading; without a perl it would print
    nothing useful and still pass. }
  if Perl = '' then
  begin
    WriteLn('FAIL no perl on the PATH');
    Halt(1);
  end;

  R := RunCaptured(Perl, ['-e', 'print "hello from perl\n"; warn "a warning\n"; exit 3'],
                   '', '', 5000);
  WriteLn(Format('launched=%s exit=%d timedout=%s', [BoolToStr(R.Launched, True),
          R.ExitCode, BoolToStr(R.TimedOut, True)]));
  if not R.Launched then
  begin
    WriteLn('FAIL perl did not start: ', R.ErrMsg);
    Halt(1);
  end;
  Write('output: ', R.Output);

  { Windows passes a command line, not a list, so quotes, backslashes and
    empty arguments all have to survive being joined up and split again.
    On Unix an empty argument sends the command through the shell, so the
    quote in it's has to survive that. }
  R := RunCaptured(Perl, ['-e', 'print join(q{|}, map { "[$_]" } @ARGV)',
                          'has space', 'say "hi"', '', 'back\slash\', 'a\"b',
                          'it''s', 'last'],
                   '', '', 5000);
  WriteLn('arguments: ', R.Output);
  if R.Output <> '[has space]|[say "hi"]|[]|[back\slash\]|[a\"b]|[it''s]|[last]' then
  begin
    WriteLn('FAIL arguments did not arrive as given');
    Halt(1);
  end;

{$ifdef MSWINDOWS}
  { Perl programs installed on Windows - perltidy, perlcritic, perldoc -
    are .bat files made by pl2bat, and cmd.exe would read & and % in their
    arguments as its own. }
  Bat := GetTempDir + 'perltest-args.bat';
  Lines := TStringList.Create;
  Lines.Add('@rem = ''--*-Perl-*--');
  Lines.Add('@perl -x -S %0 %*');
  Lines.Add('@goto endofperl');
  Lines.Add('@rem '';');
  Lines.Add('#!perl');
  Lines.Add('print join(q{|}, map { "[$_]" } @ARGV);');
  Lines.Add('__END__');
  Lines.Add(':endofperl');
  Lines.SaveToFile(Bat);
  Lines.Free;
  R := RunCaptured(Bat, ['R&D', '100%', '%PATH%', 'a "b" c', '^', ''], '', '', 5000);
  DeleteFile(Bat);
  WriteLn('pl2bat arguments: ', R.Output);
  if R.Output <> '[R&D]|[100%]|[%PATH%]|[a "b" c]|[^]|[]' then
  begin
    WriteLn('FAIL arguments did not reach a pl2bat program as given');
    Halt(1);
  end;
{$endif}

  R := RunCaptured(Perl, ['-e', 'print scalar <STDIN>'], '', 'fed via stdin'#10, 5000);
  WriteLn('stdin round trip: ', TrimRight(R.Output));

  R := RunCaptured(Perl, ['-e', 'while(1){}'], '', '', 700);
  WriteLn(Format('runaway: timedout=%s', [BoolToStr(R.TimedOut, True)]));

  R := RunCaptured(Perl, ['-e', 'print "x" for 1..300000'], '', '', 20000);
  WriteLn(Format('bulk output: %d bytes, truncated=%s',
          [Length(R.Output), BoolToStr(R.Truncated, True)]));

  R := RunCaptured('/nonexistent/binary', [], '', '', 1000);
  WriteLn('missing binary: launched=', BoolToStr(R.Launched, True), ' msg=', R.ErrMsg);

  ShowDiag('syntax error',
    'syntax error at demo.pl line 12, near "my $"'#10 +
    'Global symbol "$x" requires explicit package name (did you forget to declare "my $x"?) at demo.pl line 5.'#10 +
    'Execution of demo.pl aborted due to compilation errors.'#10);

  ShowDiag('runtime',
    'Use of uninitialized value $n in addition (+) at /tmp/a b/script.pl line 9.'#10 +
    'Name "main::zz" used only once: possible typo at script.pl line 4.'#10 +
    'Can''t locate Nope.pm in @INC (you may need to install the Nope module) at script.pl line 3.'#10 +
    'Died at script.pl line 20, <FH> line 7.'#10 +
    'plain text with no location at all'#10);

  WriteLn('--- WordAround ---');
  WriteLn('  ', WordAround('my $x = List::Util::sum(@nums);', 12));
  WriteLn('  ', WordAround('print sprintf("%d", 1);', 8));
  WriteLn('  [', WordAround('    ', 2), ']');
  WriteLn('  ', WordAround('use Data::Dumper;', 17));
end.
