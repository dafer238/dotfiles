; ===============================================
; Inno Setup script: Installs APE/SPE Python venv tools
; with shell wrappers for in-shell activation
; ===============================================

[Setup]
AppName=Python Environment Tooling Scripts
AppVersion=1.0.0
DefaultDirName={localappdata}\Programs\scripts
DefaultGroupName=Python Environment Tooling Scripts
OutputDir=Output
OutputBaseFilename=python_env_tools_installer
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
DisableProgramGroupPage=yes

[Files]
; Core Rust binaries
Source: "..\rust\target\release\ape-core.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\rust\target\release\spe-core.exe"; DestDir: "{app}"; Flags: ignoreversion
; CMD wrappers (for cmd.exe in-shell activation)
Source: "..\rust\ape.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\rust\spe.cmd"; DestDir: "{app}"; Flags: ignoreversion
; PowerShell wrapper (for pwsh in-shell activation)
Source: "..\rust\Invoke-PythonVenv.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Code]
const
  WM_SETTINGCHANGE = $001A;
  SMTO_ABORTIFHUNG = $0002;
  PROFILE_MARKER = '# [PythonVenvTools]';

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

procedure RemoveFromPath(OldPath: string);
var
  Path, NewPath: string;
  P: Integer;
begin
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'PATH', Path) then
  begin
    P := Pos(LowerCase(OldPath), LowerCase(Path));
    if P > 0 then
    begin
      NewPath := Path;
      Delete(NewPath, P, Length(OldPath));
      { Clean up leftover semicolons }
      StringChangeEx(NewPath, ';;', ';', True);
      if (Length(NewPath) > 0) and (NewPath[1] = ';') then
        Delete(NewPath, 1, 1);
      if (Length(NewPath) > 0) and (NewPath[Length(NewPath)] = ';') then
        Delete(NewPath, Length(NewPath), 1);
      RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'PATH', NewPath);
      Log('Removed "' + OldPath + '" from PATH');
      BroadcastEnvironmentChange();
    end;
  end;
end;

{ Add dot-source line to a PowerShell profile file }
procedure AddToProfile(ProfilePath: string; DotSourceLine: string);
var
  ProfileDir: string;
  Content: AnsiString;
  Lines: string;
begin
  ProfileDir := ExtractFilePath(ProfilePath);

  if not DirExists(ProfileDir) then
  begin
    ForceDirectories(ProfileDir);
    Log('Created profile directory: ' + ProfileDir);
  end;

  if FileExists(ProfilePath) then
  begin
    if LoadStringFromFile(ProfilePath, Content) then
    begin
      Lines := String(Content);
      if Pos('Invoke-PythonVenv.ps1', Lines) > 0 then
      begin
        Log('Profile already contains PythonVenvTools entry: ' + ProfilePath);
        Exit;
      end;
      { Append with marker comment }
      SaveStringToFile(ProfilePath, #13#10 + PROFILE_MARKER + #13#10 + DotSourceLine + #13#10, True);
      Log('Appended dot-source line to: ' + ProfilePath);
    end;
  end
  else
  begin
    SaveStringToFile(ProfilePath, PROFILE_MARKER + #13#10 + DotSourceLine + #13#10, False);
    Log('Created profile with dot-source line: ' + ProfilePath);
  end;
end;

{ Remove dot-source lines from a PowerShell profile file }
procedure RemoveFromProfile(ProfilePath: string);
var
  Content: AnsiString;
  Lines, NewContent, Line: string;
  P: Integer;
begin
  if not FileExists(ProfilePath) then
    Exit;

  if not LoadStringFromFile(ProfilePath, Content) then
    Exit;

  Lines := String(Content);
  NewContent := '';

  { Process line by line, skip lines containing our marker or our script }
  while Length(Lines) > 0 do
  begin
    P := Pos(#13#10, Lines);
    if P > 0 then
    begin
      Line := Copy(Lines, 1, P - 1);
      Delete(Lines, 1, P + 1);
    end
    else
    begin
      Line := Lines;
      Lines := '';
    end;

    if (Pos('[PythonVenvTools]', Line) = 0) and (Pos('Invoke-PythonVenv.ps1', Line) = 0) then
    begin
      if NewContent <> '' then
        NewContent := NewContent + #13#10;
      NewContent := NewContent + Line;
    end
    else
      Log('Removed profile line: ' + Line);
  end;

  SaveStringToFile(ProfilePath, AnsiString(NewContent), False);
  Log('Cleaned up profile: ' + ProfilePath);
end;

{ Query a PowerShell executable for its $PROFILE path }
function QueryPSProfilePath(PsExe: string): string;
var
  ResultCode: Integer;
  TmpFile, Line: string;
  Content: AnsiString;
begin
  Result := '';
  TmpFile := ExpandConstant('{tmp}\ps_profile_path.txt');
  { Run: <psexe> -NoProfile -NoLogo -Command "$PROFILE | Out-File -Encoding ascii '<tmpfile>'" }
  if Exec(PsExe, '-NoProfile -NoLogo -Command "$PROFILE | Out-File -Encoding ascii ''' + TmpFile + '''"',
           '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if (ResultCode = 0) and FileExists(TmpFile) then
    begin
      if LoadStringFromFile(TmpFile, Content) then
      begin
        Line := Trim(String(Content));
        if Line <> '' then
          Result := Line;
      end;
    end;
    DeleteFile(TmpFile);
  end;
  Log('QueryPSProfilePath(' + PsExe + ') = ' + Result);
end;

function GetPwsh7ProfilePath(): string;
begin
  Result := QueryPSProfilePath('pwsh');
  if Result = '' then
    Result := ExpandConstant('{userdocs}\PowerShell\Microsoft.PowerShell_profile.ps1');
end;

function GetPwsh5ProfilePath(): string;
begin
  Result := QueryPSProfilePath('powershell');
  if Result = '' then
    Result := ExpandConstant('{userdocs}\WindowsPowerShell\Microsoft.PowerShell_profile.ps1');
end;

procedure SetupPowerShellProfiles();
var
  InstallDir, DotSourceLine: string;
begin
  InstallDir := ExpandConstant('{app}');
  DotSourceLine := '. "' + InstallDir + '\Invoke-PythonVenv.ps1"';

  { PowerShell 7+ (pwsh) }
  AddToProfile(GetPwsh7ProfilePath(), DotSourceLine);

  { Windows PowerShell 5.1 }
  AddToProfile(GetPwsh5ProfilePath(), DotSourceLine);
end;

procedure CleanupPowerShellProfiles();
begin
  RemoveFromProfile(GetPwsh7ProfilePath());
  RemoveFromProfile(GetPwsh5ProfilePath());
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    AddToPath(ExpandConstant('{app}'));
    SetupPowerShellProfiles();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RemoveFromPath(ExpandConstant('{app}'));
    CleanupPowerShellProfiles();
  end;
end;
