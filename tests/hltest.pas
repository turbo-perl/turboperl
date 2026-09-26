{ Headless exerciser for the TPHilite unit.

    hltest        FILE   - print the file with ANSI colours
    hltest -m     FILE   - print each line followed by its token map
    hltest -s     FILE   - print only the scanner state after each line

  The token map uses one letter per character:
    . normal   K keyword  B builtin  G pragma   C comment  P pod
    S string   E escape   # number   $ scalar   @ array    % hash
    R regex    U subname  A package  o operator D data     H heredoc }
program HLTest;

{$mode objfpc}{$H+}

uses SysUtils, Classes, TPConst, TPHilite;

const
  TokLetter : array[TPerlTok] of Char =
    ('.', 'K', 'B', 'G', 'C', 'P', 'S', 'E', '#', '$', '@', '%',
     'R', 'U', 'A', 'o', 'D', 'H');

  { xterm colour numbers standing in for the DOS palette. }
  TokAnsi : array[TPerlTok] of String =
    ('0',  '1;37', '1;33', '1;35', '36',   '36',
     '32', '1;32', '35',   '1;36', '1;36', '1;36',
     '1;31','1;33', '1;33', '37',  '1;30', '32');

var
  Lines : TStringList;
  S     : TPerlState;
  Toks  : TTokLine;
  Mode  : Char = 'c';
  FName : String = '';
  i, j  : Integer;
  Raw   : AnsiString;
  Cur, Want : TPerlTok;
  MapStr: String;
  Trunc : Boolean;

function StateName(const St: TPerlState): String;
begin
  case St.Mode of
    pmNormal : Result := 'normal';
    pmPod    : Result := 'pod';
    pmData   : Result := 'data';
    pmHeredoc: Result := 'heredoc(' + St.Here[0].Term + ')';
    pmQuote  : Result := 'quote(close=' + St.CloseDelim +
                         ',depth=' + IntToStr(St.Depth) + ')';
    pmSeek   : Result := 'seek';
  end;
  if St.HereCount > 0 then
    Result := Result + ' +' + IntToStr(St.HereCount) + 'here';
end;

begin
  for i := 1 to ParamCount do
    if ParamStr(i) = '-m' then Mode := 'm'
    else if ParamStr(i) = '-s' then Mode := 's'
    else FName := ParamStr(i);

  if FName = '' then
  begin
    WriteLn('usage: hltest [-m|-s] FILE');
    Halt(2);
  end;

  Lines := TStringList.Create;
  Lines.LoadFromFile(FName);
  InitPerlState(S);

  for i := 0 to Lines.Count - 1 do
  begin
    Raw := Lines[i];
    Trunc := Length(Raw) > MaxHiliteLine;
    if Trunc then SetLength(Raw, MaxHiliteLine);
    if Length(Raw) > 0 then
      HighlightLine(Raw[1], Length(Raw), S, Toks, Trunc)
    else
      HighlightLine(Raw, 0, S, Toks, Trunc);

    case Mode of
      'm':
        begin
          MapStr := '';
          for j := 0 to Length(Raw) - 1 do MapStr := MapStr + TokLetter[Toks[j]];
          WriteLn(Format('%4d| %s', [i + 1, Raw]));
          WriteLn(Format('    | %s', [MapStr]));
        end;
      's':
        WriteLn(Format('%4d| %-30s | %s', [i + 1, StateName(S), Raw]));
      'c':
        begin
          Cur := ptNormal;
          Write(#27'[0m');
          for j := 0 to Length(Raw) - 1 do
          begin
            Want := Toks[j];
            if Want <> Cur then
            begin
              Write(#27'[0m'#27'[', TokAnsi[Want], 'm');
              Cur := Want;
            end;
            Write(Raw[j + 1]);
          end;
          WriteLn(#27'[0m');
        end;
    end;
  end;

  Lines.Free;
end.
