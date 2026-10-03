; Inno Setup script for TurboPerl, after plicease/win32-wineyes's.
;
; Built by perl build.pl installer, which lays the files out in a staging
; directory and runs
;
;   iscc /DAppVersion=<version> /DStage=<staging directory> turboperl.iss
;
; Output goes to packages\turboperl-<version>-setup.exe.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef Stage
  #error Stage must name the staging directory; build with perl build.pl installer
#endif

[Setup]
AppId={{647B154F-FD29-4E62-86E8-21D2046946A7}
AppName=TurboPerl
AppVersion={#AppVersion}
AppVerName=TurboPerl {#AppVersion}
AppPublisher=Graham Ollis
AppPublisherURL=https://github.com/turbo-perl/turboperl
AppSupportURL=https://github.com/turbo-perl/turboperl/issues
DefaultDirName={autopf}\TurboPerl
; Start menu entry only; no program group page and nothing on the desktop.
DisableProgramGroupPage=yes
DisableDirPage=auto
LicenseFile=LICENSE
UninstallDisplayIcon={app}\turboperl.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Installs per-user without elevation by default; the user can choose an
; all-users install from the dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; The PATH task changes the environment, and running programs are told so.
ChangesEnvironment=yes
OutputDir=packages
OutputBaseFilename=turboperl-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
; turboperl is a command line program, so it is most use on the PATH.
Name: addtopath; Description: "Add TurboPerl to the &PATH, to run turboperl from any console"

[Files]
; The layout DetectLibDir looks for beside the binary, as in the zip.
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
; Started in Documents, not in the install directory, which a per-machine
; install cannot write to.
Name: "{autoprograms}\TurboPerl"; Filename: "{app}\turboperl.exe"; WorkingDir: "{userdocs}"

[Registry]
Root: HKA; Subkey: "{code:EnvironmentKey}"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}"; Tasks: addtopath; Check: NotOnPath(ExpandConstant('{app}'))

[Run]
Filename: "{app}\turboperl.exe"; WorkingDir: "{userdocs}"; Description: "Start TurboPerl"; \
  Flags: nowait postinstall skipifsilent unchecked

[Code]
{ The user's own PATH for a per-user install, the machine's for an
  all-users one: HKA is HKCU or HKLM to match. }
function EnvironmentKey(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function PathRoot: Integer;
begin
  if IsAdminInstallMode then Result := HKEY_LOCAL_MACHINE
  else Result := HKEY_CURRENT_USER;
end;

{ Whether Dir is already one of the PATH's entries, so that installing
  again does not add it twice. }
function NotOnPath(Dir: String): Boolean;
var
  Path: String;
begin
  if not RegQueryStringValue(PathRoot, EnvironmentKey(''), 'Path', Path) then
    Result := True
  else
    Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') = 0;
end;

{ Uninstalling takes the directory back off the PATH, wherever in it it is,
  and leaves every other entry as it was. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path, Dir: String;
  P: Integer;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  if not RegQueryStringValue(PathRoot, EnvironmentKey(''), 'Path', Path) then Exit;
  Dir := ExpandConstant('{app}');
  Path := ';' + Path + ';';
  P := Pos(';' + Uppercase(Dir) + ';', Uppercase(Path));
  if P = 0 then Exit;
  Delete(Path, P, Length(Dir) + 1);
  Path := Copy(Path, 2, Length(Path) - 2);
  RegWriteExpandStringValue(PathRoot, EnvironmentKey(''), 'Path', Path);
end;
