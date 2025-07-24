#!/bin/bash
# Simplified ZFS Backup System
# Complete bare-metal backup for Proxmox VE on ZFS
# Version: 1.1 - Corrected

set -e

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# Colors (minimal set)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Output functions
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo "$1"; }

# Configuration defaults
ZFS_POOL="${ZFS_POOL:-rpool}"
COMPRESSION="lz4"
CREDENTIALS_FILE="${HOME:-/root}/.zfs-backup-credentials"
TEMP_MOUNT="/mnt/backup-target"

# Global variables
BACKUP_TARGET=""
ENCRYPTION_PASS=""
NAS_IP=""
NAS_SHARE=""
NAS_PATH=""
NAS_USER=""
NAS_PASSWORD=""

# Cleanup on exit
cleanup() {
    local exit_code=$?
    
    # Unmount if mounted
    if mountpoint -q "$TEMP_MOUNT" 2>/dev/null; then
        umount "$TEMP_MOUNT" 2>/dev/null || true
    fi
    
    # Remove temp files
    rm -f "/run/backup-creds-$$" 2>/dev/null || true
    
    exit $exit_code
}
trap cleanup EXIT INT TERM

# Load credentials
load_credentials() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        return 1
    fi
    
    ENCRYPTION_PASS=$(grep "^encryption_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
    NAS_IP=$(grep "^nas_ip=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
    NAS_SHARE=$(grep "^nas_share=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
    NAS_PATH=$(grep "^nas_backup_path=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
    NAS_USER=$(grep "^nas_username=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
    NAS_PASSWORD=$(grep "^nas_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
    
    # Validate minimum requirements
    if [ -z "$ENCRYPTION_PASS" ]; then
        return 1
    fi
    
    return 0
}

# Save credentials
save_credentials() {
    cat > "$CREDENTIALS_FILE" << EOF
# ZFS Backup Credentials
encryption_password=$ENCRYPTION_PASS
nas_ip=$NAS_IP
nas_share=$NAS_SHARE
nas_backup_path=$NAS_PATH
nas_username=$NAS_USER
nas_password=$NAS_PASSWORD
EOF
    chmod 600 "$CREDENTIALS_FILE"
}

# Setup wizard
setup_credentials() {
    echo "=== ZFS Backup Setup ==="
    echo
    
    # Encryption password
    local pass1=""
    local pass2=""
    while true; do
        read -s -p "Encryption password (min 12 chars): " pass1
        echo
        read -s -p "Confirm password: " pass2
        echo
        
        if [ "$pass1" != "$pass2" ]; then
            error "Passwords don't match"
            continue
        elif [ ${#pass1} -lt 12 ]; then
            error "Password too short"
            continue
        else
            ENCRYPTION_PASS="$pass1"
            break
        fi
    done
    
    echo
    echo "=== NAS Configuration (optional) ==="
    read -p "Configure NAS backup? (y/n): " setup_nas
    
    if [[ "$setup_nas" == "y" || "$setup_nas" == "Y" ]]; then
        read -p "NAS IP [192.168.1.100]: " NAS_IP
        NAS_IP="${NAS_IP:-192.168.1.100}"
        
        read -p "Share name [backups]: " NAS_SHARE
        NAS_SHARE="${NAS_SHARE:-backups}"
        
        read -p "Backup path [proxmox]: " NAS_PATH
        NAS_PATH="${NAS_PATH:-proxmox}"
        
        read -p "Username: " NAS_USER
        read -s -p "Password: " NAS_PASSWORD
        echo
    fi
    
    save_credentials
    success "Setup complete"
}

# Check system requirements
check_requirements() {
    local missing=""
    
    # Check commands
    for cmd in zfs zpool gpg tar lz4; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    
    if [ -n "$missing" ]; then
        error "Missing required commands:$missing"
        info "Install with: apt update && apt install -y zfsutils-linux gnupg liblz4-tool"
        return 1
    fi
    
    # Check ZFS pool
    if ! zpool list "$ZFS_POOL" >/dev/null 2>&1; then
        error "ZFS pool '$ZFS_POOL' not found"
        return 1
    fi
    
    # Check root
    if [ "$EUID" -ne 0 ]; then
        warn "Not running as root - some operations may fail"
    fi
    
    return 0
}

# Test NAS connectivity
test_nas() {
    if [ -z "$NAS_IP" ] || [ -z "$NAS_USER" ]; then
        return 1
    fi
    
    # Quick ping test
    if ! ping -c 1 -W 2 "$NAS_IP" >/dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# Mount NAS
mount_nas() {
    mkdir -p "$TEMP_MOUNT"
    
    # Create credentials file with a unique name in /run
    local creds_file="/run/backup-creds-$$"
    
    cat > "$creds_file" << EOF
username=$NAS_USER
password=$NAS_PASSWORD
EOF
    chmod 600 "$creds_file"
    
    # Mount
    if mount -t cifs "//$NAS_IP/$NAS_SHARE" "$TEMP_MOUNT" \
        -o credentials="$creds_file",uid=0,gid=0 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Lists ALL partitions and lets the user choose.
list_and_select_partition() {
    local count=1
    local partitions=()
    local selected_partition=""

    warn "WARNING: Showing ALL partitions. It is your responsibility to NOT select your system disk."
    info "Your Proxmox system is likely on a 'zfs_member' partition."
    echo

    local display_lines=()
    # Find all partitions and get their name, size, and filesystem type
    while read -r part_name size fstype; do
        # Just create the line for display
        display_lines+=("$(printf "%s) %s (%s, FSTYPE: %s)" "$count" "$part_name" "$size" "${fstype:-unknown}")")
        partitions[$count]="$part_name"
        count=$((count + 1))
    done < <(lsblk -n -p -o NAME,SIZE,FSTYPE)

    if [ ${#display_lines[@]} -eq 0 ]; then
        error "Could not find any partitions. Check if USB drive is connected."
        return 1
    fi
    
    printf '%s\n' "${display_lines[@]}"
    echo
    read -p "Select partition to mount (1-$((${#partitions[@]}))): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#partitions[@]}" ]; then
        selected_partition="${partitions[$choice]}"
        echo "$selected_partition"
        return 0
    else
        error "Invalid selection."
        return 1
    fi
}

# Mounts the selected partition
mount_partition() {
    local partition_to_mount="$1"
    
    mkdir -p "$TEMP_MOUNT"
    
    # Directly mount the selected partition.
    if mount "$partition_to_mount" "$TEMP_MOUNT" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Create backup
create_backup() {
    local target="$1"
    local backup_dir="$2"
    local date=$(date +%Y%m%d-%H%M)
    
    # Create snapshot
    local snapshot="${ZFS_POOL}@backup-${date}"
    info "Creating snapshot: $snapshot"
    
    if ! zfs snapshot -r "$snapshot" 2>/dev/null; then
        error "Failed to create snapshot"
        return 1
    fi
    
    # Ensure backup directory exists
    mkdir -p "$backup_dir"
    
    # Backup boot partition
    local boot_file="$backup_dir/boot-partition-${date}.tar.gz.gpg"
    info "Backing up boot partition..."
    
    if tar -czf - -C /boot/efi . 2>/dev/null | \
       gpg --cipher-algo AES256 --symmetric --batch --yes \
       --passphrase "$ENCRYPTION_PASS" > "$boot_file" 2>/dev/null; then
        success "Boot partition backed up: $(du -h "$boot_file" | cut -f1)"
    else
        error "Boot partition backup failed"
        zfs destroy -r "$snapshot" 2>/dev/null
        return 1
    fi
    
    # Backup ZFS pool
    local zfs_file="$backup_dir/zfs-backup-${date}.lz4.gpg"
    info "Backing up ZFS pool (this may take several minutes)..."
    
    # Start backup in background
    (
        zfs send -R "$snapshot" | lz4 | \
        gpg --cipher-algo AES256 --symmetric --batch --yes \
        --passphrase "$ENCRYPTION_PASS" > "$zfs_file"
    ) &
    
    local backup_pid=$!
    
    # Show progress
    echo -n "Progress: "
    while kill -0 "$backup_pid" 2>/dev/null; do
        echo -n "."
        sleep 5
    done
    echo " done"
    
    # Check if backup succeeded
    wait "$backup_pid"
    if [ $? -eq 0 ] && [ -s "$zfs_file" ]; then
        success "ZFS pool backed up: $(du -h "$zfs_file" | cut -f1)"
    else
        error "ZFS backup failed"
        zfs destroy -r "$snapshot" 2>/dev/null
        return 1
    fi
    
    # Verify backups
    info "Verifying backups..."
    
    # For NAS, ensure data is flushed
    if [ "$target" = "nas" ]; then
        sync
        sleep 5
    fi
    
    # Test decryption
    if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
       --passphrase-fd 0 "$boot_file" 2>/dev/null | \
       tar -tzf - >/dev/null 2>&1; then
        success "Boot backup verified"
    else
        error "Boot backup verification failed"
        zfs destroy -r "$snapshot" 2>/dev/null
        return 1
    fi
    
    if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
       --passphrase-fd 0 "$zfs_file" 2>/dev/null | \
       lz4 -d | head -c 1M >/dev/null 2>&1; then
        success "ZFS backup verified"
    else
        error "ZFS backup verification failed"
        zfs destroy -r "$snapshot" 2>/dev/null
        return 1
    fi
    
    # Create restore instructions
    local restore_file="$backup_dir/RESTORE-${date}.txt"
    cat > "$restore_file" << EOF
RESTORE INSTRUCTIONS
===================
Date: $(date)
Files: $(basename "$boot_file") + $(basename "$zfs_file")

1. Boot Proxmox VE installer USB and select 'Advanced > Rescue Boot'.
2. Install tools: apt update && apt install -y gnupg liblz4-tool
3. Mount backup location and run the 'restore.sh' script.
EOF
    
    # Cleanup snapshot
    info "Cleaning up..."
    zfs destroy -r "$snapshot" 2>/dev/null
    
    success "Backup completed successfully!"
    info "Location: $backup_dir"
    info "Restore instructions: $restore_file"
    
    return 0
}

# Main backup function
backup() {
    # Check requirements
    if ! check_requirements; then
        exit 1
    fi
    
    # Select target
    echo "=== Backup Target Selection ==="
    echo "1) NAS backup"
    echo "2) USB backup"
    echo
    
    # Check NAS availability
    if test_nas; then
        info "NAS is available at $NAS_IP"
    else
        warn "NAS is not available"
    fi
    
    read -p "Select target (1-2): " choice
    
    case "$choice" in
        1)
            if ! test_nas; then
                error "NAS is not available"
                exit 1
            fi
            
            info "Mounting NAS..."
            if ! mount_nas; then
                error "Failed to mount NAS"
                exit 1
            fi
            
            BACKUP_TARGET="nas"
            local backup_path="$TEMP_MOUNT/$NAS_PATH"
            ;;
        2)
            # The list function now handles user selection and returns the choice
            local partition_to_mount=$(list_and_select_partition)
            if [ -z "$partition_to_mount" ]; then
                exit 1
            fi

            info "Mounting partition $partition_to_mount..."
            if ! mount_partition "$partition_to_mount"; then
                error "Failed to mount partition. Did you install the exfat driver?"
                exit 1
            fi
            
            BACKUP_TARGET="usb"
            local backup_path="$TEMP_MOUNT"
            ;;
        *)
            error "Invalid selection"
            exit 1
            ;;
    esac
    
    # Check space
    local available=$(df -BG "$TEMP_MOUNT" | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$available" -lt 10 ]; then
        error "Insufficient space: ${available}GB available, need at least 10GB"
        exit 1
    fi
    info "Available space: ${available}GB"
    
    # Create backup
    create_backup "$BACKUP_TARGET" "$backup_path"
}

# Main function
main() {
    case "${1:-}" in
        setup)
            setup_credentials
            ;;
        test-nas)
            if ! load_credentials; then
                error "No credentials found. Run: $SCRIPT_NAME setup"
                exit 1
            fi
            
            if test_nas; then
                success "NAS connectivity test passed"
            else
                error "NAS connectivity test failed"
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME [COMMAND]"
            echo
            echo "Commands:"
            echo "  (none)    Run interactive backup"
            echo "  setup     Configure credentials"
            echo "  test-nas  Test NAS connectivity"
            echo
            exit 0
            ;;
        "")
            if ! load_credentials; then
                error "No credentials found. Run: $SCRIPT_NAME setup"
                exit 1
            fi
            
            backup
            ;;
        *)
            error "Unknown command: $1"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
}

# Run main
main "$@"
