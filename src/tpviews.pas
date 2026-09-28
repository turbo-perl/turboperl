{ ========================================================================== }
{  TurboPerl - Unit: TPViews                                                 }
{                                                                            }
{  The two panes that report back from perl:                                 }
{                                                                            }
{    Output   - whatever the script wrote, as plain scrollable text.         }
{    Messages - the diagnostics parsed out of it, one per line; pressing      }
{               Enter on one takes you to the offending source line.         }
{                                                                            }
{  Both windows hide rather than close, so the IDE can keep a pointer to     }
{  them for the lifetime of the session and the user never loses a run log   }
{  by pressing Alt-F3.                                                       }
{ ========================================================================== }
unit TPViews;

{$mode objfpc}{$H-}

interface

uses
  Objects, Drivers, Views, App,
  SysUtils, Classes,
  TPConst, TPPerl;

type
  { One parsed diagnostic, kept alongside its display text. }
  TMsgItem = class
  public
    Text     : AnsiString;
    FileName : AnsiString;
    Line     : Integer;
    IsError  : Boolean;
  end;

  { ---------------------------------------------------------------------- }

  POutputView = ^TOutputView;
  TOutputView = object(TScroller)
    Lines: TStringList;
    constructor Init(var Bounds: Objects.TRect; AHScrollBar, AVScrollBar: PScrollBar);
    destructor  Done; virtual;
    procedure   Draw; virtual;
    procedure   SetText(const S: AnsiString);
    procedure   AddText(const S: AnsiString);
    procedure   Clear;
    procedure   Recalc;
    function    AsText: AnsiString;
  end;

  POutputWindow = ^TOutputWindow;
  TOutputWindow = object(TWindow)
    View    : POutputView;
    Caption : String[64];
    constructor Init(var Bounds: Objects.TRect; const ATitle: String; ANumber: Integer);
    function    GetTitle(MaxSize: Sw_Integer): TTitleStr; virtual;
    procedure   Close; virtual;
    procedure   SetCaption(const S: String);
  end;

  { ---------------------------------------------------------------------- }

  PMsgView = ^TMsgView;
  TMsgView = object(TListViewer)
    Items: TStringList;            { Objects[i] is the TMsgItem }
    constructor Init(var Bounds: Objects.TRect; AHScrollBar, AVScrollBar: PScrollBar);
    destructor  Done; virtual;
    function    GetText(Item, MaxLen: Sw_Integer): String; virtual;
    procedure   SelectItem(Item: Sw_Integer); virtual;
    procedure   HandleEvent(var Event: TEvent); virtual;
    function    GetPalette: PPalette; virtual;
    procedure   SetMessages(const M: TPerlMsgList);
    procedure   Clear;
    function    Current: TMsgItem;
    function    ErrorCount: Integer;
    { Move the focus to the next or previous message that has a location. }
    function    StepLocated(Dir: Integer): Boolean;
  end;

  { ---------------------------------------------------------------------- }
  {  A plain list of lines, used for the debugger's watches, call stack and }
  {  variables.  Rows may carry a source location, in which case Enter on   }
  {  one goes there - the same gesture as the message list.                 }
  { ---------------------------------------------------------------------- }

  PInfoView = ^TInfoView;
  TInfoView = object(TListViewer)
    Items   : TStringList;   { what is shown }
    Targets : TStringList;   { 'file|line' per row, empty when not jumpable }
    constructor Init(var Bounds: Objects.TRect; AHScrollBar, AVScrollBar: PScrollBar);
    destructor  Done; virtual;
    function    GetText(Item, MaxLen: Sw_Integer): String; virtual;
    function    GetPalette: PPalette; virtual;
    procedure   SelectItem(Item: Sw_Integer); virtual;
    procedure   HandleEvent(var Event: TEvent); virtual;
    procedure   Clear;
    procedure   Add(const Text: AnsiString; const Target: AnsiString = '');
    procedure   Refreshed;
    function    CurrentTarget(out AFile: AnsiString; out ALine: Integer): Boolean;
  end;

  PInfoWindow = ^TInfoWindow;
  TInfoWindow = object(TWindow)
    View    : PInfoView;
    Caption : String[64];
    constructor Init(var Bounds: Objects.TRect; const ATitle: String; ANumber: Integer);
    function    GetTitle(MaxSize: Sw_Integer): TTitleStr; virtual;
    procedure   Close; virtual;
    procedure   SetCaption(const S: String);
  end;

  PMsgWindow = ^TMsgWindow;
  TMsgWindow = object(TWindow)
    View    : PMsgView;
    Caption : String[64];
    constructor Init(var Bounds: Objects.TRect; ANumber: Integer);
    function    GetTitle(MaxSize: Sw_Integer): TTitleStr; virtual;
    procedure   Close; virtual;
    procedure   SetCaption(const S: String);
  end;

implementation

{ TListViewer's own palette (26..29) indexes a dialog's, which a plain window
  does not have: every colour falls off the end and comes out as ErrorAttr,
  blinking white on red.  These lists live in windows, so map onto the
  window's palette instead - its scroller text (6) and selected text (7),
  the same colours as the Output window, with the active frame (2) for the
  column divider. }
const
  CWindowList = #6#6#7#6#2;


{ ========================================================================== }
{  TOutputView                                                               }
{ ========================================================================== }

constructor TOutputView.Init(var Bounds: Objects.TRect;
                             AHScrollBar, AVScrollBar: PScrollBar);
begin
  inherited Init(Bounds, AHScrollBar, AVScrollBar);
  Lines := TStringList.Create;
  GrowMode := gfGrowHiX + gfGrowHiY;
  Options  := Options or ofFramed;
  SetLimit(0, 0);
end;

destructor TOutputView.Done;
begin
  Lines.Free;
  inherited Done;
end;

procedure TOutputView.Recalc;
var
  i, W: Integer;
begin
  W := 0;
  for i := 0 to Lines.Count - 1 do
    if Length(Lines[i]) > W then W := Length(Lines[i]);
  SetLimit(W + 1, Lines.Count);
end;

procedure TOutputView.SetText(const S: AnsiString);
begin
  Lines.Text := S;
  Recalc;
  ScrollTo(0, 0);
  DrawView;
end;

procedure TOutputView.AddText(const S: AnsiString);
var
  Tmp: TStringList;
  i: Integer;
begin
  Tmp := TStringList.Create;
  try
    Tmp.Text := S;
    for i := 0 to Tmp.Count - 1 do Lines.Add(Tmp[i]);
  finally
    Tmp.Free;
  end;
  Recalc;
  DrawView;
end;

procedure TOutputView.Clear;
begin
  Lines.Clear;
  SetLimit(0, 0);
  ScrollTo(0, 0);
  DrawView;
end;

function TOutputView.AsText: AnsiString;
begin
  Result := Lines.Text;
end;

procedure TOutputView.Draw;
var
  B     : TDrawBuffer;
  Color : Byte;
  Y, Idx: Integer;
  S     : AnsiString;
  Vis   : String;
begin
  Color := GetColor(1);
  for Y := 0 to Size.Y - 1 do
  begin
    MoveChar(B, ' ', Color, Size.X);
    Idx := Delta.Y + Y;
    if (Idx >= 0) and (Idx < Lines.Count) then
    begin
      S := Lines[Idx];
      { Take the slice the horizontal scroll position asks for, then clip to
        a short string because that is what MoveStr accepts. }
      S := Copy(S, Delta.X + 1, Size.X);
      if Length(S) > 255 then SetLength(S, 255);
      Vis := S;
      MoveStr(B, Vis, Color);
    end;
    WriteLine(0, Y, Size.X, 1, B);
  end;
end;

{ ========================================================================== }
{  TOutputWindow                                                             }
{ ========================================================================== }

constructor TOutputWindow.Init(var Bounds: Objects.TRect; const ATitle: String;
                               ANumber: Integer);
var
  R: Objects.TRect;
  HS, VS: PScrollBar;
begin
  inherited Init(Bounds, ATitle, ANumber);
  Caption := ATitle;
  Options := Options or ofTileable;

  R.Assign(18, Size.Y - 1, Size.X - 2, Size.Y);
  HS := New(PScrollBar, Init(R));
  Insert(HS);

  R.Assign(Size.X - 1, 1, Size.X, Size.Y - 1);
  VS := New(PScrollBar, Init(R));
  Insert(VS);

  GetExtent(R);
  R.Grow(-1, -1);
  View := New(POutputView, Init(R, HS, VS));
  Insert(View);
end;

function TOutputWindow.GetTitle(MaxSize: Sw_Integer): TTitleStr;
begin
  Result := Caption;
  if Length(Result) > MaxSize then SetLength(Result, MaxSize);
end;

procedure TOutputWindow.SetCaption(const S: String);
begin
  Caption := S;
  if Frame <> nil then Frame^.DrawView;
end;

procedure TOutputWindow.Close;
begin
  { Keep the log around; the IDE holds a pointer to this window. }
  Hide;
end;

{ ========================================================================== }
{  TMsgView                                                                  }
{ ========================================================================== }

constructor TMsgView.Init(var Bounds: Objects.TRect;
                          AHScrollBar, AVScrollBar: PScrollBar);
begin
  inherited Init(Bounds, 1, AHScrollBar, AVScrollBar);
  Items := TStringList.Create;
  Items.OwnsObjects := True;
  GrowMode := gfGrowHiX + gfGrowHiY;
  SetRange(0);
end;

destructor TMsgView.Done;
begin
  Items.Free;
  inherited Done;
end;

procedure TMsgView.Clear;
begin
  Items.Clear;
  SetRange(0);
  FocusItem(0);
  DrawView;
end;

procedure TMsgView.SetMessages(const M: TPerlMsgList);
var
  i   : Integer;
  It  : TMsgItem;
  Disp: AnsiString;
begin
  Items.Clear;
  for i := 0 to High(M) do
  begin
    It := TMsgItem.Create;
    It.Text     := M[i].Text;
    It.FileName := M[i].FileName;
    It.Line     := M[i].Line;
    It.IsError  := M[i].IsError;

    if It.Line > 0 then
      Disp := Format('%s %s:%d: %s',
                     [BoolToStr(It.IsError, '*', ' '),
                      ExtractFileName(It.FileName), It.Line, It.Text])
    else
      Disp := '  ' + It.Text;

    Items.AddObject(Disp, It);
  end;
  SetRange(Items.Count);
  FocusItem(0);
  DrawView;
end;

function TMsgView.GetText(Item, MaxLen: Sw_Integer): String;
var
  S: AnsiString;
begin
  Result := '';
  if (Item < 0) or (Item >= Items.Count) then Exit;
  S := Items[Item];
  if Length(S) > MaxLen then SetLength(S, MaxLen);
  if Length(S) > 255 then SetLength(S, 255);
  Result := S;
end;

function TMsgView.GetPalette: PPalette;
const
  P: String[Length(CWindowList)] = CWindowList;
begin
  Result := PPalette(@P);
end;

function TMsgView.Current: TMsgItem;
begin
  Result := nil;
  if (Focused >= 0) and (Focused < Items.Count) then
    Result := TMsgItem(Items.Objects[Focused]);
end;

function TMsgView.ErrorCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Items.Count - 1 do
    if TMsgItem(Items.Objects[i]).IsError then Inc(Result);
end;

function TMsgView.StepLocated(Dir: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Items.Count = 0 then Exit;
  i := Focused + Dir;
  while (i >= 0) and (i < Items.Count) do
  begin
    if TMsgItem(Items.Objects[i]).Line > 0 then
    begin
      FocusItem(i);
      DrawView;
      Exit(True);
    end;
    Inc(i, Dir);
  end;
end;

procedure TMsgView.SelectItem(Item: Sw_Integer);
begin
  if (Item >= 0) and (Item < Items.Count) then
    Message(Application, evCommand, cmGotoError, @Self);
end;

procedure TMsgView.HandleEvent(var Event: TEvent);
begin
  { TListViewer maps a double click to SelectItem; make Enter do the same. }
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) and
     (Items.Count > 0) then
  begin
    SelectItem(Focused);
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
end;

{ ========================================================================== }
{  TInfoView / TInfoWindow                                                   }
{ ========================================================================== }

constructor TInfoView.Init(var Bounds: Objects.TRect;
                           AHScrollBar, AVScrollBar: PScrollBar);
begin
  inherited Init(Bounds, 1, AHScrollBar, AVScrollBar);
  Items   := TStringList.Create;
  Targets := TStringList.Create;
  GrowMode := gfGrowHiX + gfGrowHiY;
  SetRange(0);
end;

destructor TInfoView.Done;
begin
  Items.Free;
  Targets.Free;
  inherited Done;
end;

procedure TInfoView.Clear;
begin
  Items.Clear;
  Targets.Clear;
end;

procedure TInfoView.Add(const Text: AnsiString; const Target: AnsiString);
begin
  Items.Add(Text);
  Targets.Add(Target);
end;

{ Call once after a run of Add, to resize and repaint. }
procedure TInfoView.Refreshed;
begin
  SetRange(Items.Count);
  if Focused >= Items.Count then FocusItem(0);
  DrawView;
end;

function TInfoView.GetText(Item, MaxLen: Sw_Integer): String;
var
  S: AnsiString;
begin
  Result := '';
  if (Item < 0) or (Item >= Items.Count) then Exit;
  S := Items[Item];
  if Length(S) > MaxLen then SetLength(S, MaxLen);
  if Length(S) > 255 then SetLength(S, 255);
  Result := S;
end;

function TInfoView.CurrentTarget(out AFile: AnsiString; out ALine: Integer): Boolean;
var
  S: AnsiString;
  P: Integer;
begin
  AFile := '';
  ALine := 0;
  Result := False;
  if (Focused < 0) or (Focused >= Targets.Count) then Exit;
  S := Targets[Focused];
  if S = '' then Exit;
  P := LastDelimiter('|', S);
  if P = 0 then Exit;
  AFile := Copy(S, 1, P - 1);
  ALine := StrToIntDef(Copy(S, P + 1, Length(S)), 0);
  Result := (AFile <> '') and (ALine > 0);
end;

function TInfoView.GetPalette: PPalette;
const
  P: String[Length(CWindowList)] = CWindowList;
begin
  Result := PPalette(@P);
end;

procedure TInfoView.SelectItem(Item: Sw_Integer);
begin
  if (Item >= 0) and (Item < Items.Count) then
    Message(Application, evCommand, cmInfoSelect, @Self);
end;

procedure TInfoView.HandleEvent(var Event: TEvent);
begin
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) and
     (Items.Count > 0) then
  begin
    SelectItem(Focused);
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
end;

constructor TInfoWindow.Init(var Bounds: Objects.TRect; const ATitle: String;
                             ANumber: Integer);
var
  R: Objects.TRect;
  HS, VS: PScrollBar;
begin
  inherited Init(Bounds, ATitle, ANumber);
  Caption := ATitle;
  Options := Options or ofTileable;

  R.Assign(18, Size.Y - 1, Size.X - 2, Size.Y);
  HS := New(PScrollBar, Init(R));
  Insert(HS);

  R.Assign(Size.X - 1, 1, Size.X, Size.Y - 1);
  VS := New(PScrollBar, Init(R));
  Insert(VS);

  GetExtent(R);
  R.Grow(-1, -1);
  View := New(PInfoView, Init(R, HS, VS));
  Insert(View);
end;

function TInfoWindow.GetTitle(MaxSize: Sw_Integer): TTitleStr;
begin
  Result := Caption;
  if Length(Result) > MaxSize then SetLength(Result, MaxSize);
end;

procedure TInfoWindow.SetCaption(const S: String);
begin
  Caption := S;
  if Frame <> nil then Frame^.DrawView;
end;

procedure TInfoWindow.Close;
begin
  Hide;
end;

{ ========================================================================== }
{  TMsgWindow                                                                }
{ ========================================================================== }

constructor TMsgWindow.Init(var Bounds: Objects.TRect; ANumber: Integer);
var
  R: Objects.TRect;
  HS, VS: PScrollBar;
begin
  inherited Init(Bounds, 'Messages', ANumber);
  Caption := 'Messages';
  Options := Options or ofTileable;

  R.Assign(18, Size.Y - 1, Size.X - 2, Size.Y);
  HS := New(PScrollBar, Init(R));
  Insert(HS);

  R.Assign(Size.X - 1, 1, Size.X, Size.Y - 1);
  VS := New(PScrollBar, Init(R));
  Insert(VS);

  GetExtent(R);
  R.Grow(-1, -1);
  View := New(PMsgView, Init(R, HS, VS));
  Insert(View);
end;

function TMsgWindow.GetTitle(MaxSize: Sw_Integer): TTitleStr;
begin
  Result := Caption;
  if Length(Result) > MaxSize then SetLength(Result, MaxSize);
end;

procedure TMsgWindow.SetCaption(const S: String);
begin
  Caption := S;
  if Frame <> nil then Frame^.DrawView;
end;

procedure TMsgWindow.Close;
begin
  Hide;
end;

end.
