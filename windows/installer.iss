; EverLink Windows Installer — Inno Setup 6
;
; Compiles the `flutter build windows --release` output into
;   EverLink-{version}-windows-x64-setup.exe
;
; On the CI windows-latest runner, Inno Setup 6 is pre-installed at:
;   C:\Program Files (x86)\Inno Setup 6\ISCC.exe
;
; Local usage:
;   1) Install Inno Setup 6 from https://jrsoftware.org/isinfo.php
;   2) flutter build windows --release
;   3) "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\installer.iss /DMyAppVersion=1.1.4
;
; The /DMyAppVersion define overrides the default below; the /O switch
; (passed by CI) overrides OutputDir.

#ifndef MyAppVersion
#define MyAppVersion "1.1.4"
#endif

#define MyAppId "{{8F3E5A1C-2B7D-4C9A-9E6F-1D2A3B4C5E6F}"
#define MyAppName "EverLink"
#define MyAppPublisher "EverLink"
#define MyAppURL "https://github.com/bobocha214/everlink"
; Source tree produced by `flutter build windows --release`.
; Relative to this .iss file (windows/), so `..` is the repo root.
#define MySource "..\build\windows\x64\runner\Release"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=..\..\build\windows\installer
OutputBaseFilename=EverLink-{#MyAppVersion}-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\everlink.exe
UninstallDisplayName={#MyAppName}
; Install to Program Files (64-bit); standard admin install, app runs as normal user.
ArchitecturesInstallIn64BitMode=x64 arm64
ArchitecturesAllowed=x64 arm64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; The app stores its data under the user's AppData (path_provider), so a
; Program Files install needs no write access next to the executable.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Files]
Source: {#MySource}\*; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\everlink.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\everlink.exe"; Tasks: desktopicon; WorkingDir: "{app}"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\everlink.exe"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
