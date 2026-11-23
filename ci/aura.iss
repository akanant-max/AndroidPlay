; Inno Setup script for the AURA Windows installer (built in GitHub Actions).
#ifndef MyVersion
  #define MyVersion "1.0.0"
#endif

[Setup]
AppId={{6F2C8A41-3B7E-4D19-9A55-1E0C7B2D4F83}
AppName=AURA
AppVersion={#MyVersion}
AppPublisher=akanant-max
DefaultDirName={autopf}\AURA
DefaultGroupName=AURA
DisableProgramGroupPage=yes
OutputDir=..
OutputBaseFilename=AURA-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\AURA.exe
ChangesAssociations=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\AURA"; Filename: "{app}\AURA.exe"
Name: "{autodesktop}\AURA"; Filename: "{app}\AURA.exe"; Tasks: desktopicon

[Registry]
; AURA shows up in "Open with" for videos, and can be picked as the default player
Root: HKA; Subkey: "Software\Classes\AURA.video"; ValueType: string; ValueData: "Video (AURA)"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AURA.video\DefaultIcon"; ValueType: string; ValueData: """{app}\AURA.exe"",0"
Root: HKA; Subkey: "Software\Classes\AURA.video\shell\open\command"; ValueType: string; ValueData: """{app}\AURA.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Applications\AURA.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "AURA"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\AURA.exe\shell\open\command"; ValueType: string; ValueData: """{app}\AURA.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.wmv\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.m2ts\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.flv\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mpg\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mpeg\OpenWithProgids"; ValueType: string; ValueName: "AURA.video"; ValueData: ""; Flags: uninsdeletevalue

[Run]
Filename: "{app}\AURA.exe"; Description: "Launch AURA"; Flags: nowait postinstall skipifsilent
