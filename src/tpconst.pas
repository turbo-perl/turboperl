{ ========================================================================== }
{  TurboPerl - a Turbo Pascal style IDE for Perl, built with Free Pascal.    }
{                                                                            }
{  Unit:  TPConst                                                            }
{  Shared constants: version info, command codes and colour slots.           }
{ ========================================================================== }
unit TPConst;

{$mode objfpc}{$H-}

interface

const
  TPVersion   = '0.01';
  TPTitle     = 'TurboPerl';
  TPCopyright = 'A Turbo Pascal style IDE for Perl';

{ -------------------------------------------------------------------------- }
{  Command codes.                                                             }
{                                                                             }
{  Turbo Vision keeps the enabled/disabled command set in a "set of Byte", so  }
{  only commands 0..255 can be greyed out.  Commands that must follow the      }
{  context (they need an editor, or a message list) therefore live in          }
{  100..255; commands that are always available live at 1000 and up.          }
{ -------------------------------------------------------------------------- }
const
  { --- context sensitive (disable-able) --- }
  cmRunProgram    = 100;   { run the active script, capture its output }
  cmRunConsole    = 101;   { run it on the real terminal instead       }
  cmSyntaxCheck   = 102;   { perl -c                                   }
  cmPerlDocWord   = 103;   { perldoc for the word under the cursor     }
  cmPerlTidy      = 104;
  cmPerlCritic    = 105;
  cmDeparse       = 106;   { perl -MO=Deparse                          }
  cmNextError     = 107;
  cmPrevError     = 108;
  cmCommentBlock  = 109;
  cmUncommentBlock= 110;
  cmIndentBlock   = 111;
  cmUnindentBlock = 112;
  cmSaveOutput    = 113;
  cmClearOutput   = 114;
  cmRunArgs       = 115;
  cmGotoError     = 116;   { jump to the selected message              }
  cmStripTrailing = 117;
  cmDbgStepInto   = 118;   { F7  - trace into        }
  cmDbgStepOver   = 119;   { F8  - step over         }
  cmDbgStepOut    = 120;
  cmDbgRunTo      = 121;   { F4  - run to cursor     }
  cmDbgToggleBP   = 122;   { Ctrl-F8                 }
  cmDbgReset      = 123;   { Ctrl-F2 - program reset }
  cmDbgInterrupt  = 124;
  cmDbgEvaluate   = 125;   { Ctrl-F4                 }
  cmDbgAddWatch   = 126;   { Ctrl-F7                 }
  cmDbgClearBPs   = 127;
  cmInfoSelect    = 128;   { Enter on a watch / stack row }

  { --- always enabled --- }
  cmAboutBox      = 1000;
  cmOptEditor     = 1001;
  cmOptPerl       = 1002;
  cmOptColours    = 1003;
  cmSaveOptions   = 1004;
  cmShowOutput    = 1005;
  cmShowMessages  = 1006;
  cmPerlDocDlg    = 1007;
  cmToggleHilite  = 1008;
  cmUserScreen    = 1009;
  cmPerlVersion   = 1010;
  cmPerlIncPath   = 1011;
  cmToggleCapture = 1012;
  cmDbgCallStack  = 1013;  { Ctrl-F3 }
  cmDbgWatches    = 1014;
  cmDbgVariables  = 1015;

{ -------------------------------------------------------------------------- }
{  Syntax colour slots.                                                       }
{                                                                             }
{  Each slot holds a foreground colour only (0..15).  The background always    }
{  comes from the editor's own palette entry so that highlighting keeps        }
{  working if the window colours are changed.                                 }
{ -------------------------------------------------------------------------- }
type
  TPerlTok = (
    ptNormal,      { anything not otherwise classified }
    ptKeyword,     { if, while, my, sub, use ...       }
    ptBuiltin,     { print, push, defined ...          }
    ptPragma,      { strict, warnings, utf8 ...        }
    ptComment,     { # to end of line                  }
    ptPod,         { =pod .. =cut                      }
    ptString,      { '..' ".." q() qq()                }
    ptEscape,      { \n and friends inside strings     }
    ptNumber,      { 42  3.14  0xff  1_000             }
    ptScalar,      { $foo                              }
    ptArray,       { @foo                              }
    ptHash,        { %foo                              }
    ptRegex,       { m// s/// tr/// qr//               }
    ptSubName,     { the name in "sub name"            }
    ptPackage,     { the name in "package Foo::Bar"    }
    ptOperator,    { = + -> => etc.                    }
    ptData,        { after __END__ / __DATA__          }
    ptHeredoc      { heredoc body                      }
  );

const
  TokCount = Ord(High(TPerlTok)) + 1;

  { Human readable names, used by the colour dialog and the config file. }
  TokName : array[TPerlTok] of String[10] = (
    'Normal',  'Keyword', 'Builtin', 'Pragma',  'Comment', 'POD',
    'String',  'Escape',  'Number',  'Scalar',  'Array',   'Hash',
    'Regex',   'SubName', 'Package', 'Operator','Data',    'Heredoc');

  { Default scheme: foreground colours over the editor's own background. }
  DefaultScheme : array[TPerlTok] of Byte = (
    { Normal   } $7,   { light grey  }
    { Keyword  } $F,   { white       }
    { Builtin  } $E,   { yellow      }
    { Pragma   } $D,   { magenta     }
    { Comment  } $3,   { cyan        }
    { Pod      } $3,   { cyan        }
    { String   } $A,   { light green }
    { Escape   } $2,   { green       }
    { Number   } $D,   { magenta     }
    { Scalar   } $B,   { light cyan  }
    { Array    } $B,
    { Hash     } $B,
    { Regex    } $C,   { light red   }
    { SubName  } $E,
    { Package  } $E,
    { Operator } $7,
    { Data     } $8,   { dark grey   }
    { Heredoc  } $A);

  { --- debugger line markers ---
    Whole-line attributes, foreground and background together, because a
    marked line gives up its syntax colouring the way Turbo Pascal's did. }
  BreakpointAttr = $4F;   { white on red   }
  CurrentAttr    = $30;   { black on cyan  }

  { A second, quieter scheme. }
  MonoScheme : array[TPerlTok] of Byte = (
    $7, $F, $F, $F, $8, $8, $7, $7, $7, $7, $7, $7, $7, $F, $F, $7, $8, $7);

implementation

end.
