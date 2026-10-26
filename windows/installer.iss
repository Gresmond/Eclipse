#ifndef AppVersion
  #define AppVersion "26.10.1"
#endif
#ifndef BuildNumber
  #define BuildNumber "35"
#endif

[Setup]
AppId={{D66C14BF-EAD8-43A2-B021-284621F38CE5}
AppName=Eclipse
AppVersion={#AppVersion}
AppVerName=Eclipse {#AppVersion}
VersionInfoVersion={#AppVersion}.{#BuildNumber}
DefaultDirName={localappdata}\Programs\Eclipse
DefaultGroupName=Eclipse
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build
OutputBaseFilename=Eclipse
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\eclipse.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
; Created by the app, to remember the tray notification was shown.
Root: HKCU; Subkey: "Software\Eclipse"; Flags: uninsdeletekey dontcreatekey

[Icons]
Name: "{group}\Eclipse"; Filename: "{app}\eclipse.exe"
Name: "{autodesktop}\Eclipse"; Filename: "{app}\eclipse.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\eclipse.exe"; Description: "Open Eclipse"; Flags: nowait postinstall skipifsilent
