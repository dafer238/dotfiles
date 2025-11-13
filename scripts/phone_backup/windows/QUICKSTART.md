# Quick Start Guide - Android Backup for Windows

Get your Android device backed up in 5 minutes!

## Prerequisites Checklist

- [ ] Windows 10 or Windows 11
- [ ] Android device with USB cable
- [ ] ADB (Android Platform Tools) installed
- [ ] USB Debugging enabled on your device
- [ ] (Optional) BetterADBSync for direct device sync

## Step 1: Install ADB (2 minutes)

### Option A: Winget (Easiest)

```powershell
winget install Google.PlatformTools
```

### Option B: Chocolatey

```powershell
choco install adb
```

### Option C: Manual

1. Download from: https://developer.android.com/tools/releases/platform-tools
2. Extract to `C:\platform-tools`
3. Add to PATH:
   - Press `Win + X` → System
   - Advanced system settings → Environment Variables
   - Edit PATH → Add `C:\platform-tools`

**Verify installation:**

```powershell
adb version
```

## Step 2: (Optional) Install BetterADBSync (2 minutes)

For the best backup experience with direct device-to-destination sync (same as Linux version):

```powershell
pip install BetterADBSync --user
```

Or:

```powershell
python -m pip install BetterADBSync --user
```

**Verify installation:**

```powershell
adbsync --help
```

**Skip this step if:**

- You don't have Python installed
- You prefer the native Windows method (adb pull + robocopy)

The script will automatically use BetterADBSync if installed, otherwise falls back to adb pull + robocopy.

## Step 3: Enable USB Debugging (1 minute)

On your Android device:

1. **Settings** → **About Phone** → Tap **Build Number** 7 times
2. **Settings** → **Developer Options** → Enable **USB Debugging**
3. Connect USB cable
4. Tap **Allow** on the authorization popup

**Verify connection:**

```powershell
adb devices
```

Should show your device ID followed by "device".

## Step 4: Run the Backup Script (2 minutes setup)

### Download the Script

If you don't have it yet:

```powershell
cd C:\Users\YourName
git clone <your-dotfiles-repo>
cd dotfiles\scripts\phone_backup
```

### Run It

**Option 1: Double-click**

- Double-click `phone_backup.bat`

**Option 2: PowerShell**

```powershell
cd C:\Users\YourName\code\dotfiles\scripts\phone_backup
.\phone_backup.ps1
```

**Option 3: Command Prompt**

```cmd
cd C:\Users\YourName\code\dotfiles\scripts\phone_backup
phone_backup.bat
```

## Step 5: Follow the Prompts

The script will ask you:

1. **Backup location** (default: `C:\Users\YourName\backups\last_backup`)
   - Press Enter to accept default
   - Or type a custom path

2. **For each folder**, it will show:

   ```
   📂 DCIM
      Camera photos and videos
   Backup this location? [Y/n]:
   ```

   - Press Enter or type `Y` to backup
   - Type `n` to skip

3. **External drive backup** (optional)
   - At the end, it asks if you want to copy to USB/external drive
   - Type `Y` if you want an extra copy
   - Select the drive number

## Backup Methods

The script automatically chooses the best method:

**If BetterADBSync is installed:**

- ✅ Direct device-to-destination sync
- ✅ Incremental, resumable
- ✅ Lower disk space usage
- ✅ Same as Linux version

**If BetterADBSync is not installed:**

- ✅ ADB pull to temp + robocopy to destination
- ✅ Multi-threaded, faster
- ✅ Native Windows tools only
- ✅ Still incremental and resumable

Both methods work great! BetterADBSync is slightly safer and uses less disk space.

## Default Folders Backed Up

✅ DCIM (Camera)
✅ Pictures
✅ Downloads
✅ Documents
✅ WhatsApp Media (images, videos, documents, audio)
✅ Telegram Media
✅ Instagram Media
✅ Music, Movies, Audiobooks
✅ Recordings, Ringtones, Notifications, Alarms

## First Backup Tips

- **Time**: First backup may take 30-60 minutes depending on data size
- **Screen**: Keep your phone screen on during backup
- **Apps**: Close heavy apps on your phone
- **USB**: Use a good quality USB cable (USB 3.0+ recommended)
- **Space**: Ensure enough disk space on your PC

## Subsequent Backups

Good news! The next time you run the script:

- ⚡ Much faster (only new/changed files)
- 🔄 Automatically resumes if interrupted
- 💾 Skips files already backed up

Just run it again with the **same backup folder name**.

## Example Session

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📱 ANDROID BACKUP SCRIPT v3.0 (Windows Edition)
  Performance & Safety Optimized
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ ADB found: C:\platform-tools\adb.exe
✅ Device detected: ABC123456

Enter backup root directory [C:\Users\John\backups]: ⏎
Enter backup folder name [last_backup]: ⏎

📂 DCIM
   Camera photos and videos
Backup this location? [Y/n]: ⏎

ℹ️  Counting files on device...
Files to backup: 1,247
ℹ️  Pulling files from device...
[transfer progress shown]
✅ Finished: DCIM

... (continues for each folder) ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  BACKUP SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Backed up: 8
  Skipped: 2
  Failed: 0
  Location: C:\Users\John\backups\last_backup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Copy to external drive? [y/N]: y

Available drives:
1) D:\ [USB Drive] (Free: 45.2 GB / 64.0 GB)
2) E:\ [External HDD] (Free: 234.5 GB / 500.0 GB)
0) Cancel

Select drive number: 1

... (copies to external drive) ...

✅ ALL DONE!
```

## Troubleshooting

### "ADB not found"

- Install ADB (see Step 1)
- Restart PowerShell/Command Prompt after installing
- Verify with: `adb version`

### "BetterADBSync not found" (Warning, not error)

- This is just a warning - script will use adb pull + robocopy
- To install: `pip install BetterADBSync --user`
- Or skip it - the fallback method works perfectly fine!

### "No device detected"

- Check USB cable (try a different one)
- Enable USB Debugging again
- Disconnect and reconnect
- Run: `adb kill-server` then `adb start-server`
- Check phone for authorization popup

### "Script won't run"

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### "Path does not exist"

- Normal! Script skips folders that don't exist on your device
- Just press Enter to continue

## Customize What Gets Backed Up

Edit `backup_paths.ini`:

```ini
[DCIM]
path=DCIM
description=Camera photos and videos
enabled=true    ← Change to false to skip
```

Set `enabled=false` for folders you don't want to backup.

## Where Are My Files?

Default location:

```
C:\Users\YourName\backups\last_backup\
├── backup_20240115_143022.log
├── DCIM\
├── Pictures\
├── WhatsApp Images\
└── ...
```

You can open this folder directly:

```powershell
explorer C:\Users\YourName\backups\last_backup
```

## Backup to External Drive

When prompted at the end:

1. Type `Y` for external drive backup
2. Select your USB drive or external HDD
3. Each folder will be copied to: `X:\AndroidBackups\last_backup\`

## Automation (Optional)

Create a desktop shortcut:

1. Right-click Desktop → New → Shortcut
2. Location: `PowerShell -ExecutionPolicy Bypass -File "C:\path\to\phone_backup.ps1"`
3. Name it "Backup Phone"
4. Now just double-click to run!

## Schedule Weekly Backups (Optional)

Use Task Scheduler:

1. Win + R → `taskschd.msc`
2. Create Basic Task
3. Trigger: Weekly (Sunday at 2 AM)
4. Action: Start a program
   - Program: `PowerShell.exe`
   - Arguments: `-ExecutionPolicy Bypass -File "C:\path\to\phone_backup.ps1"`
5. Make sure phone is connected and authorized

## Need Help?

1. Check the log file: `C:\Users\YourName\backups\last_backup\backup_*.log`
2. Read the full documentation: `README_WINDOWS.md`
3. Common issues: See "Troubleshooting" section above

## What's Next?

After your first successful backup:

✅ Test a restore by copying a file back to your device
✅ (Optional) Install BetterADBSync for even better sync: `pip install BetterADBSync --user`
✅ Set up automatic weekly backups
✅ Keep an extra copy on an external drive
✅ Run incremental backups regularly (much faster!)

## Summary

```
1. Install ADB                    → 2 minutes
2. (Optional) Install BetterADBSync → 2 minutes
3. Enable USB Debugging           → 1 minute
4. Run script                     → 2 minutes setup
5. Wait for backup                → 30-60 minutes (first time)
6. Done! ✅
```

Next backup will be much faster (5-10 minutes typically).

Happy backing up! 📱💾✨
