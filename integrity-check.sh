#!/bin/bash
# Simplified Backup Integrity Checker
# Tests encrypted ZFS backup files from any source
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
CREDENTIALS_FILE="${HOME:-/root}/.zfs-backup-credentials"
MOUNT_POINT="/mnt/integrity-test"

# Global variables
SELECTED_FILE=""
ENCRYPTION_PASS=""

# Cleanup
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Load encryption password
load_password() {
    # Try credentials file
    if [ -f "$CREDENTIALS_FILE" ]; then
        ENCRYPTION_PASS=$(grep "^encryption_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        if [ -n "$ENCRYPTION_PASS" ]; then
            return 0
        fi
    fi
    
    # Try environment
    if [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
        ENCRYPTION_PASS="$BACKUP_ENCRYPTION_PASSWORD"
        return 0
    fi
    
    # Ask user
    read -s -p "Enter encryption password: " ENCRYPTION_PASS
    echo
    
    if [ -z "$ENCRYPTION_PASS" ]; then
        return 1
    fi
    
    return 0
}

# Test single file
test_file() {
    local file="$1"
    local filename=$(basename "$file")
    
    echo
    echo "=== Testing: $filename ==="
    
    # Check file exists and size
    if [ ! -f "$file" ]; then
        error "File not found"
        return 1
    fi
    
    local size=$(ls -lh "$file" | awk '{print $5}')
    info "File size: $size"
    
    # Determine type and compression
    local compression="lz4"
    local file_type="zfs"
    
    if [[ "$filename" == boot-partition-* ]]; then
        compression="gzip"
        file_type="boot"
    elif [[ "$filename" == *.gz.gpg ]]; then
        compression="gzip"
    fi
    
    info "Type: $file_type backup"
    info "Compression: $compression"
    
    # Test 1: GPG decryption
    echo -n "Testing GPG decryption... "
    if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
       --passphrase-fd 0 "$file" 2>/dev/null | head -c 1K >/dev/null; then
        success "OK"
    else
        error "FAILED"
        return 1
    fi
    
    # Test 2: Compression
    echo -n "Testing $compression decompression... "
    case "$compression" in
        lz4)
            if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
               --passphrase-fd 0 "$file" 2>/dev/null | lz4 -t >/dev/null 2>&1; then
                success "OK"
            else
                error "FAILED"
                return 1
            fi
            ;;
        gzip)
            if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
               --passphrase-fd 0 "$file" 2>/dev/null | gunzip -t >/dev/null 2>&1; then
                success "OK"
            else
                error "FAILED"
                return 1
            fi
            ;;
    esac
    
    # Test 3: Content validation
    echo -n "Testing backup content... "
    case "$file_type" in
        boot)
            # Test tar archive
            if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
               --passphrase-fd 0 "$file" 2>/dev/null | gunzip | tar -tf - >/dev/null 2>&1; then
                success "OK (valid tar archive)"
            else
                error "FAILED"
                return 1
            fi
            ;;
        zfs)
            # Just check we can read some data
            if echo "$ENCRYPTION_PASS" | gpg --decrypt --batch --yes \
               --passphrase-fd 0 "$file" 2>/dev/null | lz4 -d 2>/dev/null | head -c 1M >/dev/null; then
                success "OK (readable ZFS stream)"
            else
                error "FAILED"
                return 1
            fi
            ;;
    esac
    
    success "All tests passed!"
    return 0
}

# Find backup sets
find_backup_sets() {
    local dir="$1"
    local sets=()
    local dates=()
    
    # Find unique dates
    for file in "$dir"/*.gpg; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            local date=$(echo "$basename" | grep -o '[0-9]\{8\}-[0-9]\{4\}' | head -1)
            
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
    echo "Found backup sets:"
    echo
    
    local count=1
    for date in "${dates[@]}"; do
        echo "$count) Backup set: $date"
        
        # Find components
        for file in "$dir"/*${date}*.gpg; do
            if [ -f "$file" ]; then
                local basename=$(basename "$file")
                local size=$(ls -lh "$file" | awk '{print $5}')
                echo "   - $basename ($size)"
            fi
        done
        
        echo
        sets[$count]="$date"
        count=$((count + 1))
    done
    
    # Let user select
    read -p "Select backup set (1-$((count-1))) or specific file (f): " choice
    
    if [ "$choice" = "f" ]; then
        # Select specific file
        echo
        echo "Available files:"
        local file_count=1
        local files=()
        
        for file in "$dir"/*.gpg; do
            if [ -f "$file" ]; then
                local basename=$(basename "$file")
                local size=$(ls -lh "$file" | awk '{print $5}')
                echo "$file_count) $basename ($size)"
                files[$file_count]="$file"
                file_count=$((file_count + 1))
            fi
        done
        
        echo
        read -p "Select file (1-$((file_count-1))): " file_choice
        
        if [[ "$file_choice" =~ ^[0-9]+$ ]] && [ "$file_choice" -ge 1 ] && [ "$file_choice" -lt "$file_count" ]; then
            echo "${files[$file_choice]}"
            return 0
        fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$count" ]; then
        # Test all files in set
        local selected_date="${sets[$choice]}"
        echo "SET:$selected_date"
        return 0
    fi
    
    return 1
}

# Main function
main() {
    echo "=== Backup Integrity Checker ==="
    echo
    
    # Handle command line file
    if [ $# -eq 1 ] && [ -f "$1" ]; then
        SELECTED_FILE="$1"
        info "Testing file: $(basename "$SELECTED_FILE")"
    else
        # Select source
        echo "Select backup source:"
        echo "1) Local directory"
        echo "2) Mounted USB/NAS"
        echo
        
        read -p "Select (1-2): " source
        
        case "$source" in
            1)
                read -p "Enter directory path: " dir_path
                if [ ! -d "$dir_path" ]; then
                    error "Directory not found"
                    exit 1
                fi
                
                local result=$(find_backup_sets "$dir_path")
                if [ -z "$result" ]; then
                    exit 1
                fi
                
                if [[ "$result" == SET:* ]]; then
                    local date="${result#SET:}"
                    SELECTED_FILE="SET"
                    local test_files=("$dir_path"/*${date}*.gpg)
                else
                    SELECTED_FILE="$result"
                fi
                ;;
            2)
                # List mounted filesystems
                echo
                echo "Mounted filesystems:"
                df -h | grep -E "^/dev/(sd|nvme)" | nl
                
                echo
                read -p "Enter mount point path: " mount_path
                
                if [ ! -d "$mount_path" ]; then
                    error "Mount point not found"
                    exit 1
                fi
                
                local result=$(find_backup_sets "$mount_path")
                if [ -z "$result" ]; then
                    exit 1
                fi
                
                if [[ "$result" == SET:* ]]; then
                    local date="${result#SET:}"
                    SELECTED_FILE="SET"
                    local test_files=("$mount_path"/*${date}*.gpg)
                else
                    SELECTED_FILE="$result"
                fi
                ;;
            *)
                error "Invalid selection"
                exit 1
                ;;
        esac
    fi
    
    # Load password
    if ! load_password; then
        error "No encryption password available"
        exit 1
    fi
    
    # Run tests
    local all_passed=true
    
    if [ "$SELECTED_FILE" = "SET" ]; then
        # Test all files in set
        for file in "${test_files[@]}"; do
            if [ -f "$file" ]; then
                if ! test_file "$file"; then
                    all_passed=false
                fi
            fi
        done
    else
        # Test single file
        if ! test_file "$SELECTED_FILE"; then
            all_passed=false
        fi
    fi
    
    # Summary
    echo
    echo "=== Summary ==="
    
    if [ "$all_passed" = true ]; then
        success "All integrity tests passed!"
        info "Backup is ready for restore"
    else
        error "Some tests failed!"
        warn "Backup may be corrupted"
    fi
}

# Run main
main "$@"
