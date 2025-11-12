; ===============================================
; Inno Setup script: Installs two EXE files and adds folder to user PATH
; ===============================================

[Setup]
AppName=Python Environment Tooling Scripts
AppVersion=1.0
DefaultDirName={localappdata}\Programs\scripts
DefaultGroupName=Python Environment Tooling Scripts
OutputDir=Output
OutputBaseFilename=python_env_tools_installer
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
DisableProgramGroupPage=yes

[Files]
Source: "ape.exe"; DestDir: "{localappdata}\Programs\scripts"; Flags: ignoreversion
Source: "spe.exe"; DestDir: "{localappdata}\Programs\scripts"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\Run ape"; Filename: "{app}\ape.exe"
Name: "{userdesktop}\Run spe"; Filename: "{app}\spe.exe"

[Code]
const
  WM_SETTINGCHANGE = $001A;
  SMTO_ABORTIFHUNG = $0002;

function SendMessageTimeout(
  hWnd: Integer;
  Msg: LongInt;
  wParam: LongInt;
  lParam: LongInt;
  fuFlags: LongInt;
  uTimeout: LongInt;
  var lpdwResult: LongInt
): LongInt;
  external 'SendMessageTimeoutW@user32.dll stdcall';

procedure BroadcastEnvironmentChange();
var
  ResultCode: LongInt;
begin
  ResultCode := 0;
  { HWND_BROADCAST is predefined by Inno Setup, so we don't redeclare it }
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, 0, 0, SMTO_ABORTIFHUNG, 5000, ResultCode);
end;

procedure AddToPath(NewPath: string);
var
  Path: string;
begin
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'PATH', Path) then
  begin
    if Pos(LowerCase(NewPath), LowerCase(Path)) = 0 then
    begin
      if Path <> '' then
        Path := Path + ';';
      Path := Path + NewPath;
      RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'PATH', Path);
      Log('Added "' + NewPath + '" to PATH');
      BroadcastEnvironmentChange();
    end;
  end
  else
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'PATH', NewPath);
    Log('Created PATH variable with "' + NewPath + '"');
    BroadcastEnvironmentChange();
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    AddToPath(ExpandConstant('{localappdata}\Programs\scripts'));
  end;
end;

