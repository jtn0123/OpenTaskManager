; OpenTaskManager's Windows installer (Inno Setup 6). It installs for the
; current account without administrator rights, in %LOCALAPPDATA%\Programs,
; with a Start menu entry and, if asked, start at sign-in. Uninstalling quits
; the running copy and removes its sign-in entry; settings stay.
;
; scripts\package-windows.ps1 builds it:
;   iscc /DVersion=0.1.0 /DSource=<folder with opentaskmanager.exe> /DOutputDir=<folder> opentaskmanager.iss

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef Source
  #define Source "..\..\target\release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{0FFF48D4-883B-4B97-AF75-A9F791D7CE58}
AppName=OpenTaskManager
AppVersion={#Version}
AppVerName=OpenTaskManager {#Version}
AppPublisher=OpenTaskManager
AppPublisherURL=https://github.com/jtn0123/OpenTaskManager
AppSupportURL=https://github.com/jtn0123/OpenTaskManager/issues
VersionInfoVersion={#Version}
DefaultDirName={autopf}\OpenTaskManager
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\..\..\LICENSE
SetupIconFile=..\..\app\icons\opentaskmanager.ico
UninstallDisplayIcon={app}\opentaskmanager.exe
UninstallDisplayName=OpenTaskManager
OutputDir={#OutputDir}
OutputBaseFilename=OpenTaskManager-{#Version}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "signin"; Description: "Start OpenTaskManager when I sign in, hidden in the tray"; Flags: unchecked

[Files]
Source: "{#Source}\opentaskmanager.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\OpenTaskManager"; Filename: "{app}\opentaskmanager.exe"

; The same value the app's own Start at sign-in writes, so either can turn it off.
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "OpenTaskManager"; ValueData: """{app}\opentaskmanager.exe"" --hidden"; Tasks: signin

[Run]
Filename: "{app}\opentaskmanager.exe"; Description: "Open OpenTaskManager"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\opentaskmanager.exe"; Parameters: "--quit"; Flags: runhidden waituntilterminated; RunOnceId: "QuitRunningCopy"

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

// A copy already running holds its program file open: ask it to quit first.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Existing: String;
  Code: Integer;
begin
  Existing := ExpandConstant('{app}\opentaskmanager.exe');
  if FileExists(Existing) then
    Exec(Existing, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

// Whoever turned it on (this installer or the app), a removed program shouldn't start at sign-in.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, 'OpenTaskManager');
    RegDeleteValue(HKEY_CURRENT_USER, ApprovedKey, 'OpenTaskManager');
  end;
end;
