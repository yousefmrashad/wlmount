# WSL2 LUKS Drive Mounter

A simple bash script to safely decrypt, mount, and manage LUKS-encrypted drives (including those with LVM layouts) directly inside **Windows Subsystem for Linux (WSL2)**.

WSL2 allows mounting physical drives, but manually managing cryptsetup, LVM volume groups, directory mounting, permissions, and paths can be tedious. This script automates that entire lifecycle.

---

## Features

- 🔍 **LUKS Partition Auto-Detection**: Scans and displays available LUKS partitions.
- 📦 **LVM Support**: Automatically detects and handles LVM Physical Volumes, Volume Groups, and Logical Volumes nested inside the LUKS container.
- 🔑 **Failsafe Automatic Permissions**: Automatically maps filesystem ownership to your normal non-root WSL user so you can read and write without `sudo`. For system/boot drives, it dynamically targets only your user's `/home/$USER` directory, preserving root permissions on system files (like `/usr/bin/sudo`) and preventing OS corruption. On data drives, it recursively grants access to the entire mount point.
- 📂 **Windows Interop Paths**: Prints the native WSL mount point and the Windows Explorer UNC path (`\\wsl.localhost\...`) for easy access.
- 🛡️ **Clean Teardown**: Automatically handles unmounting, deactivating LVM Volume Groups, and closing the LUKS mapper safely when you're done.

---

## Prerequisites

1. **WSL2** (Windows 11 or Windows 10 with the modern WSL store package).
2. **`cryptsetup`** installed inside your WSL2 Linux distribution:
   - **Ubuntu/Debian**: `sudo apt-get update && sudo apt-get install -y cryptsetup`
   - **Arch Linux**: `sudo pacman -S cryptsetup`
   - **Fedora**: `sudo dnf install cryptsetup`
3. (Optional) **`lvm2`** for LVM structures (the script will offer to install this automatically if LVM is detected).

---

## Usage Guide

### Step 1: Attach the Physical Disk to WSL2 (Windows PowerShell)
Before the WSL distribution can see the disk, you must attach it to WSL as a bare block device.

1. Open **PowerShell as Administrator** in Windows.
2. List your physical disks to find the correct disk number:
   ```powershell
   Get-Disk | Select-Object Number, FriendlyName, Size, OperationalStatus
   ```
3. Attach the target disk (e.g., `\\.\PHYSICALDRIVE1`) to WSL2 without mounting it to any standard filesystem:
   ```powershell
   wsl.exe --mount \\.\PHYSICALDRIVE1 --bare
   ```

### Step 2: Run the Script (WSL2 Terminal)
Once the disk is attached to WSL2, you can run the script inside your WSL terminal to decrypt and mount it.

1. Clone or copy [mount-luks.sh](mount-luks.sh) to your WSL instance.
2. Make it executable:
   ```bash
   chmod +x mount-luks.sh
   ```
3. Run the script:
   ```bash
   sudo ./mount-luks.sh
   ```
4. Follow the interactive prompts:
   - Select the detected LUKS partition.
   - Enter your decryption passphrase.
   - Select a Logical Volume (if using LVM).
5. The drive will be decrypted and mounted at `/mnt/wsl/wsl-luks`. The script will output a handy network path for accessing it from Windows Explorer:
   ```text
   \\wsl.localhost\Ubuntu\mnt\wsl\wsl-luks
   ```

---

## Safe Unmounting & Disconnect

To prevent data corruption, always unmount and lock the drive before detaching it from WSL2.

### Step 1: Run the Script Unmount Action (WSL2 Terminal)
Run the script with the `--unmount` or `-u` flag:
```bash
sudo ./mount-luks.sh --unmount
```
This will:
- Unmount the filesystem.
- Deactivate any LVM Volume Groups.
- Close the cryptsetup LUKS mapper device.

### Step 2: Detach the Disk (Windows PowerShell)
Go back to your Windows **PowerShell (Administrator)** session and run:
```powershell
wsl.exe --unmount \\.\PHYSICALDRIVE1
```
You can now safely unplug or spin down the physical drive.

---

## Disclaimers

### Security Disclaimer
> [!WARNING]
> This script performs operations that require root privileges (`sudo`), interacts directly with partition tables, mounts filesystems, and handles disk encryption passphrases. 
> - **Use at your own risk.** Improper use (e.g. targeting incorrect disk names) can lead to data loss. Always verify disk numbers/identifiers before mounting.
> - **Backup your data.** Keep backups of any critical data stored on your LUKS partitions.
> - **Passphrase Safety.** The script passes your input directly to standard `cryptsetup`. Never modify this script to hardcode or log passphrases.

### AI Disclaimer
> [!NOTE]
> This project—including its script, structure, and documentation—was completely written by an AI coding assistant. While it has been designed to follow standard system administration practices, you should inspect the script and test it in a safe environment before running it on production systems or invaluable drives.

---

## License

This project is open-source and available under the [GNU GPLv3 License](LICENSE.txt).

