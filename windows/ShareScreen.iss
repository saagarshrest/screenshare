; Inno Setup script for ShareScreen-Setup.exe. Built by .github/workflows/release.yml:
;   iscc /DAppVersion=1.1.0 /DSourceDir=..\dist\ShareScreen windows\ShareScreen.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\ShareScreen"
#endif

[Setup]
AppId={{6B0F3B2E-8C2B-4C7A-9E0E-5A51C0A8D3F1}
AppName=ShareScreen
AppVersion={#AppVersion}
AppPublisher=Saagar Shrestha
AppPublisherURL=https://github.com/saagarshrest/screenshare
AppSupportURL=https://github.com/saagarshrest/screenshare/issues
DefaultDirName={autopf}\ShareScreen
DefaultGroupName=ShareScreen
DisableProgramGroupPage=yes
; Admin is needed only to add the Windows Firewall rule.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
OutputDir=..
OutputBaseFilename=ShareScreen-Setup
SetupIconFile=ShareScreen.ico
UninstallDisplayIcon={app}\ShareScreen.exe
LicenseFile=..\LICENSE
InfoAfterFile=..\THIRD_PARTY_NOTICES.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "autostart"; Description: "Start ShareScreen when I sign in"; GroupDescription: "Options:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"
Source: "..\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}"
Source: "..\LICENSES\GPL-3.0.txt"; DestDir: "{app}\LICENSES"

[Icons]
Name: "{group}\ShareScreen"; Filename: "{app}\ShareScreen.exe"
Name: "{group}\Uninstall ShareScreen"; Filename: "{uninstallexe}"
Name: "{autodesktop}\ShareScreen"; Filename: "{app}\ShareScreen.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; \
  ValueName: "ShareScreen"; ValueData: """{app}\ShareScreen.exe"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
; Let phones reach ShareScreen on private networks (home Wi-Fi, phone hotspot).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ShareScreen"""; \
  Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""ShareScreen"" dir=in action=allow program=""{app}\ShareScreen.exe"" profile=private enable=yes"; \
  Flags: runhidden
Filename: "{app}\ShareScreen.exe"; Description: "Start ShareScreen now"; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM ShareScreen.exe"; Flags: runhidden; RunOnceId: "StopApp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ShareScreen"""; Flags: runhidden; RunOnceId: "DelFirewall"
