#!/bin/bash
# Simplified ZFS Restore Script
# Restores encrypted backups to target hardware
# Version: 1.0 - Simplified Edition

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Output functions
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo "$1"; }

# Configuration
MOUNT_POINT="/mnt/backup-source"
CREDENTIALS_FILE="/root/.zfs-backup-credentials"

# Global variables
BOOT_BACKUP=""
ZFS_BACKUP=""
TARGET_DISK=""
ENCRYPTION_PASS=""
ZFS_POOL="rpool"

# Cleanup
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    rm -f /tmp/.restore-creds 2>/dev/null || true
}
trap cleanup EXIT

# Check if running from live system
check_live_system() {
    # Detect Proxmox rescue mode or live system
    if [ -f /etc/proxmox-release ] && grep -q "rescue" /proc/cmdline 2>/dev/null; then
        info "Running from Proxmox Rescue mode (recommended)"
    elif [ -d /rw ] || grep -q "live" /proc/cmdline 2>/dev/null; then
        info "Running from Live system"
    else
        warn "Not running from live/rescue system - be careful!"
        echo "Recommended: Use Proxmox installer 'Advanced > Rescue Boot'"
        echo "Alternative: Use Ubuntu Live USB"
        read -p "Continue anyway? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            exit 1
        fi
    fi
    
    # Check for required tools
    local missing=""
    for tool in zfs zpool gpg sgdisk tar lz4; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    
    if [ -n "$missing" ]; then
        error "Missing tools:$missing"
        info "Install with: apt update && apt install -y zfsutils-linux gnupg gdisk liblz4-tool"
        exit 1
    fi
    
    # Check root
    if [ "$EUID" -ne 0 ]; then
        error "Must run as root (use sudo)"
        exit 1
    fi
}

# Load encryption password
load_password() {
    # Try credentials file
    if [ -f "$CREDENTIALS_FILE" ]; then
        ENCRYPTION_PASS=$(grep "^encryption_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        if [ -n "$ENCRYPTION_PASS" ]; then
            info "Using password from credentials file"
            return 0
        fi
    fi
    
    # Ask user
    read -s -p "Enter encryption password: " ENCRYPTION_PASS
    echo
    
    if [ -z "$ENCRYPTION_PASS" ]; then
        return 1
    fi
    
    return 0
}

# Find backup files
find_backup_files() {
    local dir="$1"
    
    # Find all backup sets
    local dates=()
    for file in "$dir"/*.gpg; do
        if [ -f "$file" ]; then
            local date=$(basename "$file" | grep -o '[0-9]\{8\}-[0-9]\{4\}' | head -1)
            if [ -n "$date" ] && [[ ! " ${dates[@]} " =~ " ${date} " ]]; then
                dates+=("$date")
            fi
        fi
    done
    
    if [ ${#dates[@]} -eq 0 ]; then
        error "No backup files found"
        return 1
    fi
    
    # Display sets
    echo
    echo "Available backup sets:"
    local count=1
    local sets=()
    
    for date in "${dates[@]}"; do
        local boot_file=""
        local zfs_file=""
        
        # Find components
        for file in "$dir"/*${date}*.gpg; do
            if [ -f "$file" ]; then
                if [[ "$(basename "$file")" == boot-partition-* ]]; then
                    boot_file="$file"
                elif [[ "$(basename "$file")" == *backup* ]] || [[ "$(basename "$file")" == zfs-* ]]; then
                    zfs_file="$file"
                fi
            fi
        done
        
        # Only show complete sets
        if [ -n "$boot_file" ] && [ -n "$zfs_file" ]; then
            echo "$count) Backup set: $date"
            echo "   Boot: $(basename "$boot_file") ($(ls -lh "$boot_file" | awk '{print $5}'))"
            echo "   ZFS:  $(basename "$zfs_file") ($(ls -lh "$zfs_file" | awk '{print $5}'))"
            echo
            
            sets[$count]="$boot_file|$zfs_file"
            count=$((count + 1))
        fi
    done
    
    if [ $count -eq 1 ]; then
        error "No complete backup sets found"
        info "Need both boot-partition-*.tar.gz.gpg and zfs-backup-*.lz4.gpg files"
        return 1
    fi
    
    read -p "Select backup set (1-$((count-1))): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$count" ]; then
        local selected="${sets[$choice]}"
        BOOT_BACKUP="${selected%|*}"
        ZFS_BACKUP="${selected#*|}"
        
        success "Selected backup set"
        return 0
    else
        return 1
    fi
}

# Select target disk
select_target_disk() {
    echo
    echo "=== Target Disk Selection ==="
    warn "ALL DATA ON TARGET DISK WILL BE ERASED!"
    echo
    
    # List disks
    local count=1
    local disks=()
    
    echo "Available disks:"
    for device in /dev/sd[a-z] /dev/nvme[0-9]n[1-9]; do
        if [ -b "$device" ]; then
            local size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "?")
            local model=$(lsblk -d -n -o MODEL "$device" 2>/dev/null || echo "Unknown")
            
            echo "$count) $device ($size) - $model"
            disks[$count]="$device"
            count=$((count + 1))
        fi
    done
    
    if [ $count -eq 1 ]; then
        error "No disks found"
        return 1
    fi
    
    echo
    read -p "Select target disk (1-$((count-1))): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$count" ]; then
        TARGET_DISK="${disks[$choice]}"
        
        echo
        warn "Selected: $TARGET_DISK"
        warn "ALL DATA WILL BE LOST!"
        echo
        read -p "Type 'DESTROY' to confirm: " confirm
        
        if [ "$confirm" = "DESTROY" ]; then
            return 0
        fi
    fi
    
    return 1
}

# Prepare target disk
prepare_disk() {
    info "Preparing target disk..."
    
    # Wipe disk
    info "Wiping disk..."
    sgdisk --zap-all "$TARGET_DISK" >/dev/null 2>&1 || true
    wipefs -a "$TARGET_DISK" >/dev/null 2>&1 || true
    
    # Create partitions
    info "Creating partitions..."
    sgdisk -n 1:0:+512M -t 1:ef00 "$TARGET_DISK" >/dev/null
    sgdisk -n 2:0:0 -t 2:bf00 "$TARGET_DISK" >/dev/null
    
    # Wait for kernel
    sleep 2
    partprobe "$TARGET_DISK" 2>/dev/null || true
    
    # Determine partition names
    local efi_part="${TARGET_DISK}1"
    local zfs_part="${TARGET_DISK}2"
    
    if [[ "$TARGET_DISK" == *"nvme"* ]]; then
        efi_part="${TARGET_DISK}p1"
        zfs_part="${TARGET_DISK}p2"
    fi
    
    # Format EFI partition
    info "Formatting EFI partition..."
    mkfs.fat -F32 "$efi_part" >/dev/null
    
    # Export for other functions
    export EFI_PARTITION="$efi_part"
    export ZFS_PARTITION="$zfs_part"
    
    success "Disk prepared"
}

# Restore system
restore_system() {
    # Create ZFS pool
    info "Creating ZFS pool..."
    zpool create -f "$ZFS_POOL" "$ZFS_PARTITION" >/dev/null
    
    # Restore ZFS data
    info "Restoring ZFS data (this will take several minutes)..."
    echo -n "Progress: "
    
    (
        echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
            --passphrase-fd 0 "$ZFS_BACKUP" 2>/dev/null | \
            lz4 -d | zfs receive -F "$ZFS_POOL"
    ) &
    
    local restore_pid=$!
    
    while kill -0 $restore_pid 2>/dev/null; do
        echo -n "."
        sleep 5
    done
    echo " done"
    
    wait $restore_pid
    if [ $? -ne 0 ]; then
        error "ZFS restore failed"
        zpool destroy "$ZFS_POOL" 2>/dev/null || true
        return 1
    fi
    
    success "ZFS data restored"
    
    # Mount EFI partition
    mkdir -p /mnt/efi
    mount "$EFI_PARTITION" /mnt/efi
    
    # Restore boot files
    info "Restoring boot partition..."
    echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
        --passphrase-fd 0 "$BOOT_BACKUP" 2>/dev/null | \
        tar -xzf - -C /mnt/efi
    
    if [ $? -ne 0 ]; then
        error "Boot restore failed"
        umount /mnt/efi 2>/dev/null || true
        return 1
    fi
    
    success "Boot partition restored"
    
    # Set bootfs
    local root_dataset=$(zfs list -H -o name | grep "ROOT" | head -1)
    if [ -n "$root_dataset" ]; then
        info "Setting boot filesystem..."
        zpool set bootfs="$root_dataset" "$ZFS_POOL"
    fi
    
    # Install bootloader
    info "Installing bootloader..."
    
    # Mount restored system for chroot
    local mount_root="/mnt/restore-root"
    mkdir -p "$mount_root"
    
    # Mount root dataset
    zfs set mountpoint="$mount_root" "$root_dataset"
    zfs mount "$root_dataset"
    
    # Mount other datasets under root
    for dataset in $(zfs list -H -o name | grep "^$ZFS_POOL/" | grep -v "^$root_dataset$"); do
        zfs mount "$dataset" 2>/dev/null || true
    done
    
    # Mount necessary filesystems for chroot
    mount --bind /dev "$mount_root/dev"
    mount --bind /proc "$mount_root/proc"
    mount --bind /sys "$mount_root/sys"
    mount "$EFI_PARTITION" "$mount_root/boot/efi"
    
    # Try Proxmox bootloader first
    if [ -f "$mount_root/usr/sbin/proxmox-boot-tool" ]; then
        info "Installing Proxmox bootloader..."
        chroot "$mount_root" /usr/sbin/proxmox-boot-tool init "$TARGET_DISK" >/dev/null 2>&1 || true
        chroot "$mount_root" /usr/sbin/proxmox-boot-tool refresh >/dev/null 2>&1 || true
        success "Proxmox bootloader installed"
    elif [ -f "$mount_root/usr/sbin/grub-install" ]; then
        info "Installing GRUB bootloader..."
        chroot "$mount_root" /usr/sbin/grub-install "$TARGET_DISK" >/dev/null 2>&1 || true
        chroot "$mount_root" /usr/sbin/update-grub >/dev/null 2>&1 || true
        success "GRUB bootloader installed"
    else
        warn "No bootloader found - manual installation required"
    fi
    
    # Cleanup chroot
    umount "$mount_root/boot/efi" 2>/dev/null || true
    umount "$mount_root/sys" 2>/dev/null || true
    umount "$mount_root/proc" 2>/dev/null || true
    umount "$mount_root/dev" 2>/dev/null || true
    
    # Unmount ZFS
    zfs unmount -a 2>/dev/null || true
    zfs set mountpoint=/ "$root_dataset"
    
    success "Restore completed!"
}

# Main function
main() {
    echo "=== ZFS System Restore ==="
    echo
    warn "This will completely erase the target disk!"
    echo
    
    # Check environment
    check_live_system
    
    # Get backup source
    echo "Select backup source:"
    echo "1) Local directory"
    echo "2) Network share (mount first)"
    echo "3) USB drive"
    echo
    
    read -p "Select (1-3): " source
    
    case "$source" in
        1)
            read -p "Enter backup directory: " backup_dir
            if [ ! -d "$backup_dir" ]; then
                error "Directory not found"
                exit 1
            fi
            ;;
        2)
            echo
            echo "Available mounts:"
            df -h | grep -E "cifs|nfs" | nl
            echo
            read -p "Enter mount path: " backup_dir
            if [ ! -d "$backup_dir" ]; then
                error "Path not found"
                exit 1
            fi
            ;;
        3)
            # List USB devices
            echo
            echo "Available USB devices:"
            lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk|part" | grep -v "/$" | nl
            echo
            read -p "Enter USB mount point (or press Enter to mount): " backup_dir
            
            if [ -z "$backup_dir" ]; then
                # Mount USB
                read -p "Enter USB device (e.g., /dev/sdb1): " usb_device
                if [ ! -b "$usb_device" ]; then
                    error "Device not found"
                    exit 1
                fi
                
                mkdir -p "$MOUNT_POINT"
                if ! mount "$usb_device" "$MOUNT_POINT"; then
                    error "Failed to mount USB"
                    exit 1
                fi
                backup_dir="$MOUNT_POINT"
            fi
            ;;
        *)
            error "Invalid selection"
            exit 1
            ;;
    esac
    
    # Find backup files
    if ! find_backup_files "$backup_dir"; then
        exit 1
    fi
    
    # Load password
    if ! load_password; then
        error "No encryption password"
        exit 1
    fi
    
    # Quick password test
    echo -n "Testing encryption password... "
    if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
       --passphrase-fd 0 "$BOOT_BACKUP" 2>/dev/null | head -c 100 >/dev/null; then
        success "OK"
    else
        error "Wrong password"
        exit 1
    fi
    
    # Select target disk
    if ! select_target_disk; then
        info "Restore cancelled"
        exit 0
    fi
    
    # Final confirmation
    echo
    echo "=== Restore Summary ==="
    info "Boot backup: $(basename "$BOOT_BACKUP")"
    info "ZFS backup: $(basename "$ZFS_BACKUP")"
    info "Target disk: $TARGET_DISK"
    echo
    warn "This will ERASE $TARGET_DISK completely!"
    echo
    
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        info "Restore cancelled"
        exit 0
    fi
    
    # Prepare disk
    if ! prepare_disk; then
        error "Failed to prepare disk"
        exit 1
    fi
    
    # Restore system
    if ! restore_system; then
        error "Restore failed"
        exit 1
    fi
    
    echo
    success "System restored successfully!"
    echo
    echo "Next steps:"
    echo "1. Remove Live USB"
    echo "2. Reboot"
    echo "3. System should boot normally"
    echo
    echo "If system doesn't boot:"
    echo "- Check BIOS/UEFI boot order"
    echo "- May need to run: proxmox-boot-tool init $TARGET_DISK"
}

# Run main
main "$@"
