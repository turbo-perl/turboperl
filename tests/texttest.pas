{ Headless exerciser for the TPText block operations. }
program TextTest;
{$mode objfpc}{$H+}
uses SysUtils, TPText;

var Fails: Integer = 0;

procedure Check(const What, Got, Want: AnsiString);
  function Vis(const S: AnsiString): AnsiString;
  var i: Integer;
  begin
    Result := '';
    for i := 1 to Length(S) do
      case S[i] of
        #10: Result := Result + '\n';
        #13: Result := Result + '\r';
        #9 : Result := Result + '\t';
      else   Result := Result + S[i];
      end;
  end;
begin
  if Got = Want then
    WriteLn('ok   ', What)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', What);
    WriteLn('       got:  [', Vis(Got), ']');
    WriteLn('       want: [', Vis(Want), ']');
  end;
end;

procedure TestSplit;
var
  A: TStringArray;
  N: Integer;

  procedure Sp(const What, Input, Want: AnsiString);
  var
    j: Integer;
    Joined: AnsiString;
  begin
    SplitArgs(Input, A, N);
    Joined := '';
    for j := 0 to N - 1 do
    begin
      if j > 0 then Joined := Joined + '|';
      Joined := Joined + A[j];
    end;
    Check(What, IntToStr(N) + ':' + Joined, Want);
  end;

begin
  Sp('plain',                  'a b c',        '3:a|b|c');
  Sp('extra spaces',           '  a   b  ',    '2:a|b');
  Sp('empty',                  '',             '0:');
  Sp('double quotes',          'a "b c" d',    '3:a|b c|d');
  Sp('single quotes',          'a ''b c'' d',  '3:a|b c|d');
  Sp('explicit empty arg',     'a "" b',       '3:a||b');
  Sp('escaped space',          'a b\ c',       '2:a|b c');
  Sp('escape inside dquotes',  'a "b\"c"',     '2:a|b"c');
  Sp('squotes keep backslash', '''a\b''',      '1:a\b');
  Sp('adjacent quoting',       'a"b"c',        '1:abc');
  Sp('unterminated quote',     'a "b c',       '2:a|b c');
  Sp('tabs separate',          'a'#9'b',       '2:a|b');
end;

const
  Src   = 'my $x = 1;'#10'    if ($x) {'#10#10'        print $x;'#10'    }'#10;
  NoEOL = 'a'#10'b';
  CRLF  = 'a'#13#10'b'#13#10;
begin
  Check('comment',
    CommentLines(Src, True),
    '# my $x = 1;'#10'#     if ($x) {'#10#10'#         print $x;'#10'#     }'#10);

  Check('comment round trip', CommentLines(CommentLines(Src, True), False), Src);

  Check('uncomment without space',
    CommentLines('#foo'#10'  #bar'#10, False), 'foo'#10'  bar'#10);

  Check('uncomment leaves non comments',
    CommentLines('foo'#10, False), 'foo'#10);

  Check('indent',
    IndentLines('a'#10'  b'#10#10, True, 4, False),
    '    a'#10'      b'#10#10);

  Check('unindent', IndentLines('    a'#10'      b'#10, False, 4, False),
    'a'#10'  b'#10);

  Check('unindent stops at text', IndentLines('  a'#10, False, 4, False), 'a'#10);

  Check('unindent tab', IndentLines(#9'a'#10, False, 4, False), 'a'#10);

  Check('indent tab char', IndentLines('a'#10, True, 4, True), #9'a'#10);

  Check('strip trailing',
    StripTrailing('a   '#10'b'#9#9#10'   '#10), 'a'#10'b'#10''#10);

  Check('no final newline preserved', CommentLines(NoEOL, True), '# a'#10'# b');

  Check('crlf preserved', CommentLines(CRLF, True), '# a'#13#10'# b'#13#10);

  Check('crlf strip', StripTrailing('a  '#13#10), 'a'#13#10);

  Check('empty', CommentLines('', True), '');

  WriteLn;
  TestSplit;
  WriteLn;
  if Fails = 0 then WriteLn('all text tests passed')
  else begin WriteLn(Fails, ' FAILURES'); Halt(1); end;
end.
