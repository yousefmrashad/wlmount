#!/bin/bash
# mount-luks.sh - Safely decrypts and mounts LUKS drives inside WSL2

# Check if cryptsetup is installed
if ! command -v cryptsetup &> /dev/null; then
    echo -e "\e[31m[ERROR] cryptsetup is not installed.\e[0m"
    echo "Please install it using your package manager:"
    echo "  Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y cryptsetup"
    echo "  Arch Linux:    sudo pacman -S cryptsetup"
    echo "  Fedora:        sudo dnf install cryptsetup"
    exit 1
fi

# Find the normal non-root user (default UID 1000) to change ownership on mount
if [ -n "$SUDO_USER" ]; then
    NORMAL_USER="$SUDO_USER"
else
    NORMAL_USER=$(getent passwd | awk -F: '$3 == 1000 {print $1}')
    [ -z "$NORMAL_USER" ] && NORMAL_USER="root"
fi

MAPPING_NAME="wsl-luks"
MOUNT_POINT="/mnt/wsl/wsl-luks"

# --- Unmount Action ---
if [[ "$1" == "-u" || "$1" == "--unmount" ]]; then
    echo -e "\e[34m[INFO] Starting unmount process...\e[0m"
    
    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        echo -e "\e[33m[WARNING] This action requires root privileges. Elevating with sudo...\e[0m"
        exec sudo "$0" "$@"
    fi

    # Check if filesystem is mounted
    if mountpoint -q "$MOUNT_POINT"; then
        echo "Unmounting $MOUNT_POINT..."
        umount "$MOUNT_POINT"
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[ERROR] Failed to unmount $MOUNT_POINT. The drive may be busy.\e[0m"
            read -p "Would you like to force/lazy unmount? [y/N]: " force_choice
            if [[ "$force_choice" =~ ^[Yy]$ ]]; then
                umount -l "$MOUNT_POINT"
                echo -e "\e[32m[SUCCESS] Force/lazy unmount performed.\e[0m"
            else
                exit 1
            fi
        else
            echo -e "\e[32m[SUCCESS] Unmounted successfully.\e[0m"
        fi
    else
        echo "Nothing is currently mounted at $MOUNT_POINT."
    fi

    # Deactivate LVM Volume Groups
    if command -v vgchange &> /dev/null; then
        echo "Deactivating LVM Volume Groups..."
        vgchange -an &> /dev/null
    fi

    # Check if LUKS mapper device is open
    if [ -b "/dev/mapper/$MAPPING_NAME" ]; then
        echo "Closing LUKS container /dev/mapper/$MAPPING_NAME..."
        cryptsetup luksClose "$MAPPING_NAME"
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[ERROR] Failed to close LUKS mapper device.\e[0m"
            exit 1
        fi
        echo -e "\e[32m[SUCCESS] LUKS mapping closed successfully.\e[0m"
    else
        echo "No open LUKS container named $MAPPING_NAME found."
    fi

    echo -e "\e[32m========================================================\e[0m"
    echo -e "\e[32m LUKS container closed safely. Safe to detach disk!\e[0m"
    echo -e "\e[32m Run this in Windows PowerShell as Administrator:\e[0m"
    echo -e "   wsl.exe --unmount \\\\.\\PHYSICALDRIVE<N>"
    echo -e "\e[32m========================================================\e[0m"
    exit 0
fi

# --- Mount Action ---
# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[33m[WARNING] This action requires root privileges. Elevating with sudo...\e[0m"
    exec sudo "$0" "$@"
fi

# Scan for LUKS partitions
echo -e "\e[34m[INFO] Scanning for LUKS partitions...\e[0m"
partitions=()
while IFS= read -r line; do
    [ -n "$line" ] && partitions+=("$line")
done < <(lsblk -lnp -o NAME,FSTYPE,SIZE | awk '$2 == "crypto_LUKS" {print $1 "," $3}')

if [ ${#partitions[@]} -eq 0 ]; then
    echo -e "\e[31m[ERROR] No partitions with a 'crypto_LUKS' signature were found.\e[0m"
    echo "Ensure your physical disk is attached bare to WSL first by running this in Windows PowerShell:"
    echo "  wsl.exe --mount \\\\.\\PHYSICALDRIVE<N> --bare"
    echo ""
    echo "Attached block devices:"
    lsblk -p -o NAME,FSTYPE,SIZE,MOUNTPOINT
    exit 1
fi

selected_partition=""
if [ ${#partitions[@]} -eq 1 ]; then
    IFS=',' read -r path size <<< "${partitions[0]}"
    echo -e "\e[32mDetected LUKS Partition: $path ($size)\e[0m"
    read -p "Would you like to decrypt this partition? [Y/n]: " choice
    choice=${choice:-y}
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        selected_partition="$path"
    fi
else
    echo "Multiple LUKS partitions detected:"
    for i in "${!partitions[@]}"; do
        IFS=',' read -r path size <<< "${partitions[$i]}"
        echo "[$i] $path ($size)"
    done
    read -p "Select partition index [0-$(( ${#partitions[@]} - 1 ))]: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "${#partitions[@]}" ]; then
        IFS=',' read -r path size <<< "${partitions[$idx]}"
        selected_partition="$path"
    else
        echo -e "\e[31m[ERROR] Invalid selection.\e[0m"
        exit 1
    fi
fi

if [ -z "$selected_partition" ]; then
    echo "No partition selected. Exiting."
    exit 0
fi

# Open LUKS Mapping
if [ -b "/dev/mapper/$MAPPING_NAME" ]; then
    echo -e "\e[33m[WARNING] LUKS mapping /dev/mapper/$MAPPING_NAME is already open.\e[0m"
    read -p "Use existing mapping? [y/N]: " use_existing
    if [[ ! "$use_existing" =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "Decrypting partition $selected_partition..."
    cryptsetup luksOpen "$selected_partition" "$MAPPING_NAME"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR] Decryption failed.\e[0m"
        exit 1
    fi
    echo -e "\e[32m[SUCCESS] LUKS container opened.\e[0m"
fi

# Create mount point inside WSL shared mount space
mkdir -p "$MOUNT_POINT"

# Detect if the decrypted device is an LVM physical volume
fstype=$(lsblk -d -n -o FSTYPE "/dev/mapper/$MAPPING_NAME" 2>/dev/null | tr -d '[:space:]')
volume_to_mount="/dev/mapper/$MAPPING_NAME"
is_lvm=0

if [ "$fstype" = "LVM2_member" ]; then
    is_lvm=1
    echo -e "\e[34m[INFO] LVM volume layout detected inside LUKS container.\e[0m"
    
    # Check if LVM tools are installed
    if ! command -v vgchange &> /dev/null; then
        echo -e "\e[33m[WARNING] LVM2 tools (vgchange) are not installed.\e[0m"
        
        # Detect package managers
        pkg_manager=""
        install_cmd=""
        if command -v apt-get &> /dev/null; then
            pkg_manager="apt-get (Debian/Ubuntu)"
            install_cmd="apt-get update && apt-get install -y lvm2"
        elif command -v pacman &> /dev/null; then
            pkg_manager="pacman (Arch Linux)"
            install_cmd="pacman -Sy --noconfirm lvm2"
        elif command -v dnf &> /dev/null; then
            pkg_manager="dnf (Fedora)"
            install_cmd="dnf install -y lvm2"
        elif command -v apk &> /dev/null; then
            pkg_manager="apk (Alpine)"
            install_cmd="apk add lvm2"
        fi
        
        if [ -n "$pkg_manager" ]; then
            read -p "Detected package manager: $pkg_manager. Install lvm2 now? [Y/n]: " inst_choice
            inst_choice=${inst_choice:-y}
            if [[ "$inst_choice" =~ ^[Yy]$ ]]; then
                echo "Installing lvm2 using $pkg_manager..."
                eval "$install_cmd"
            else
                cryptsetup luksClose "$MAPPING_NAME"
                exit 1
            fi
        else
            echo -e "\e[31m[ERROR] LVM2 tools are missing. Please install lvm2 manually and try again.\e[0m"
            cryptsetup luksClose "$MAPPING_NAME"
            exit 1
        fi
    fi
    
    # Scan and activate VGs
    echo "Scanning and activating LVM Volume Groups..."
    vgscan
    vgchange -ay
    
    # List logical volumes inside the mapper device
    logical_volumes=()
    while IFS= read -r line; do
        [ -n "$line" ] && logical_volumes+=("$line")
    done < <(lsblk -lnp -o NAME,TYPE,FSTYPE,SIZE "/dev/mapper/$MAPPING_NAME" | awk '$2 == "lvm" {print $1 "," $3 "," $4}')
    
    if [ ${#logical_volumes[@]} -eq 0 ]; then
        echo -e "\e[33m[WARNING] No LVM logical volumes found. Trying to mount decrypted container directly.\e[0m"
    elif [ ${#logical_volumes[@]} -eq 1 ]; then
        IFS=',' read -r path fs sz <<< "${logical_volumes[0]}"
        echo -e "\e[32mDetected Logical Volume: $path ($fs, $sz)\e[0m"
        volume_to_mount="$path"
    else
        echo "Multiple Logical Volumes detected:"
        for i in "${!logical_volumes[@]}"; do
            IFS=',' read -r path fs sz <<< "${logical_volumes[$i]}"
            echo "[$i] $path ($fs, $sz)"
        done
        read -p "Select Logical Volume index [0-$(( ${#logical_volumes[@]} - 1 ))]: " lv_idx
        if [[ "$lv_idx" =~ ^[0-9]+$ ]] && [ "$lv_idx" -lt "${#logical_volumes[@]}" ]; then
            IFS=',' read -r path fs sz <<< "${logical_volumes[$lv_idx]}"
            volume_to_mount="$path"
        else
            echo -e "\e[31m[ERROR] Invalid selection.\e[0m"
            cryptsetup luksClose "$MAPPING_NAME"
            exit 1
        fi
    fi
fi

# Mount filesystem
if mountpoint -q "$MOUNT_POINT"; then
    echo -e "\e[33m[WARNING] $MOUNT_POINT is already mounted.\e[0m"
else
    echo "Mounting $volume_to_mount to $MOUNT_POINT..."
    mount "$volume_to_mount" "$MOUNT_POINT"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR] Mounting failed.\e[0m"
        if [ "$is_lvm" -eq 1 ]; then
            vgchange -an &> /dev/null
        fi
        cryptsetup luksClose "$MAPPING_NAME"
        exit 1
    fi
    echo -e "\e[32m[SUCCESS] Filesystem mounted.\e[0m"
fi

# Fix ownership so user can read/write without needing root/sudo permissions
if [ "$NORMAL_USER" != "root" ]; then
    if [ -d "$MOUNT_POINT/home" ]; then
        echo "System drive detected. Ownership changes skipped to preserve system integrity."
    else
        echo "No system layout detected. This appears to be a data drive."
        read -p "Would you like to recursively change the drive's root ownership to '$NORMAL_USER' for write access? [y/N]: " chown_choice
        chown_choice=${chown_choice:-n}
        if [[ "$chown_choice" =~ ^[Yy]$ ]]; then
            echo "Applying write permissions recursively..."
            chown "$NORMAL_USER":"$NORMAL_USER" "$MOUNT_POINT"
            chown -R "$NORMAL_USER":"$NORMAL_USER" "$MOUNT_POINT"
        else
            echo "Skipping ownership changes."
        fi
    fi
fi

# Display path results
echo -e "\e[32m========================================================\e[0m"
echo -e "\e[32m LUKS Partition Mounted Successfully!\e[0m"
echo -e "\e[32m========================================================\e[0m"
echo -e "WSL Path:      $MOUNT_POINT"
echo -e "Windows Path:  \\\\wsl.localhost\\$WSL_DISTRO_NAME${MOUNT_POINT//\//\\}"
echo -e "User Access:   $NORMAL_USER (Read/Write)"
echo -e "\e[32m========================================================\e[0m"
echo "To safely unmount later, run: $0 --unmount"
echo -e "\e[32m========================================================\e[0m"
