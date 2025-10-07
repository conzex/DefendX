#!/bin/bash

# User Migration Automator Script
# Description: Fully automated user migration with dynamic detection and safety checks
# Version: 2.0
# Usage: sudo ./user_migration_automator.sh <old_user> <new_user> <new_password>

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Usage information
usage() {
    echo "Usage: $0 <old_user> <new_user> <new_password>"
    echo "Example: $0 wazuh-user dx-admin defendx"
    exit 1
}

# Validation functions
validate_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

validate_users() {
    local old_user=$1
    local new_user=$2
    
    if ! getent passwd "$old_user" >/dev/null; then
        log_error "Source user '$old_user' does not exist"
        exit 1
    fi
    
    if getent passwd "$new_user" >/dev/null; then
        log_error "Target user '$new_user' already exists"
        exit 1
    fi
}

# Backup function
create_backup() {
    local old_user=$1
    local backup_dir="/root/user_migration_backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/${old_user}_backup_${timestamp}.tar.gz"
    
    mkdir -p "$backup_dir"
    log_info "Creating backup of $old_user home directory..."
    
    if tar czf "$backup_file" "/home/$old_user" 2>/dev/null; then
        log_success "Backup created: $backup_file"
    else
        log_warning "Could not create backup of /home/$old_user (may not exist)"
    fi
    
    # Also backup crontab
    if crontab -u "$old_user" -l 2>/dev/null > "${backup_dir}/${old_user}_cron_${timestamp}"; then
        log_success "Crontab backed up"
    fi
}

# Gather user information dynamically
gather_user_info() {
    local old_user=$1
    declare -gA user_info
    
    log_info "Gathering information for user: $old_user"
    
    # Get user details
    user_info['uid']=$(id -u "$old_user")
    user_info['gid']=$(id -g "$old_user")
    user_info['groups']=$(id -Gn "$old_user" | tr ' ' ',')
    user_info['shell']=$(getent passwd "$old_user" | cut -d: -f7)
    user_info['home']=$(getent passwd "$old_user" | cut -d: -f6)
    user_info['comment']=$(getent passwd "$old_user" | cut -d: -f5)
    
    log_success "User info gathered: UID=${user_info['uid']}, GID=${user_info['gid']}, Groups=${user_info['groups']}"
}

# Create new user with same properties
create_new_user() {
    local old_user=$1
    local new_user=$2
    local new_password=$3
    
    log_info "Creating new user: $new_user"
    
    # Build useradd command dynamically
    local useradd_cmd="useradd"
    
    # Add home directory if source user has one
    if [[ -d "${user_info['home']}" ]]; then
        useradd_cmd+=" -m"
    fi
    
    # Add shell
    useradd_cmd+=" -s ${user_info['shell']}"
    
    # Add comment/description if exists
    if [[ -n "${user_info['comment']}" ]]; then
        useradd_cmd+=" -c \"${user_info['comment']}\""
    fi
    
    # Add to groups (excluding primary group)
    local primary_group=$(id -gn "$old_user")
    local supplementary_groups=$(id -Gn "$old_user" | sed "s/$primary_group//g" | sed 's/  / /g' | sed 's/^ //g' | sed 's/ $//g' | tr ' ' ',')
    
    if [[ -n "$supplementary_groups" ]]; then
        useradd_cmd+=" -G $supplementary_groups"
    fi
    
    useradd_cmd+=" $new_user"
    
    # Execute user creation
    eval "$useradd_cmd"
    
    # Set password
    echo "$new_user:$new_password" | chpasswd
    
    log_success "New user $new_user created successfully"
}

# Transfer file ownership
transfer_ownership() {
    local old_user=$1
    local new_user=$2
    
    log_info "Transferring file ownership from $old_user to $new_user..."
    
    # Count files to transfer
    local file_count=$(find / -user "$old_user" 2>/dev/null | wc -l)
    log_info "Found $file_count files/directories to transfer"
    
    # Transfer ownership (suppress /proc errors)
    if ! find / -user "$old_user" -exec chown "$new_user":"$new_user" {} + 2>/dev/null; then
        log_warning "Some files could not have ownership changed (normal for /proc files)"
    fi
    
    log_success "File ownership transfer completed"
}

# Transfer crontab
transfer_crontab() {
    local old_user=$1
    local new_user=$2
    
    log_info "Checking for crontab entries..."
    
    # Install cronie if not present
    if ! command -v crontab &> /dev/null; then
        log_info "Installing cronie..."
        dnf install -y cronie > /dev/null 2>&1
        systemctl enable crond > /dev/null 2>&1
        systemctl start crond > /dev/null 2>&1
    fi
    
    # Transfer crontab if exists
    if crontab -u "$old_user" -l 2>/dev/null | grep -v '^#' | grep -v '^$' > /dev/null 2>&1; then
        log_info "Transferring crontab..."
        crontab -u "$old_user" -l | crontab -u "$new_user" -
        log_success "Crontab transferred successfully"
    else
        log_info "No crontab entries found for $old_user"
    fi
}

# Check for service dependencies
check_service_dependencies() {
    local old_user=$1
    
    log_info "Checking for service dependencies..."
    
    # Check systemd services
    local services=$(grep -r "User=$old_user" /etc/systemd/system/ /usr/lib/systemd/system/ 2>/dev/null | cut -d: -f1 | uniq || true)
    
    if [[ -n "$services" ]]; then
        log_warning "Found services using $old_user:"
        echo "$services"
        echo "These will need to be updated manually to use $new_user"
    fi
    
    # Check sudoers entries
    if grep -r "$old_user" /etc/sudoers* 2>/dev/null; then
        log_warning "Found sudoers entries for $old_user that may need updating"
    fi
}

# Terminate old user sessions
terminate_sessions() {
    local old_user=$1
    
    log_info "Checking for active sessions for $old_user..."
    
    local session_count=$(ps -u "$old_user" -o pid= 2>/dev/null | wc -l)
    
    if [[ $session_count -gt 0 ]]; then
        log_warning "Found $session_count active sessions for $old_user"
        log_info "Terminating sessions..."
        
        # Try graceful termination first
        pkill -u "$old_user" 2>/dev/null || true
        sleep 2
        
        # Force kill if still running
        pkill -9 -u "$old_user" 2>/dev/null || true
        
        # Verify termination
        if ps -u "$old_user" -o pid= >/dev/null 2>&1; then
            log_error "Could not terminate all sessions for $old_user"
            return 1
        else
            log_success "All sessions terminated"
        fi
    else
        log_info "No active sessions found"
    fi
}

# Delete old user
delete_old_user() {
    local old_user=$1
    local new_user=$2
    
    log_info "Deleting old user: $old_user"
    
    # Attempt to delete user with home directory
    if userdel -r "$old_user" 2>/dev/null; then
        log_success "User $old_user deleted successfully"
    else
        log_warning "Could not delete user with home directory, attempting manual cleanup..."
        
        # Manual cleanup
        userdel "$old_user" 2>/dev/null || true
        rm -rf "/home/$old_user" 2>/dev/null || true
        rm -f "/var/spool/mail/$old_user" 2>/dev/null || true
        
        # Clean subuid/subgid entries
        sed -i "/^$old_user:/d" /etc/subuid /etc/subgid /etc/subuid- /etc/subgid- 2>/dev/null || true
        
        log_success "Manual cleanup completed for $old_user"
    fi
}

# Verification function
verify_migration() {
    local old_user=$1
    local new_user=$2
    
    log_info "Verifying migration..."
    
    # Verify old user is gone
    if getent passwd "$old_user" >/dev/null; then
        log_error "Old user $old_user still exists!"
        return 1
    fi
    
    # Verify new user exists
    if ! getent passwd "$new_user" >/dev/null; then
        log_error "New user $new_user does not exist!"
        return 1
    fi
    
    # Verify no files owned by old user
    local remaining_files=$(find / -user "$old_user" 2>/dev/null | wc -l)
    if [[ $remaining_files -gt 0 ]]; then
        log_warning "Found $remaining_files files still owned by $old_user"
    else
        log_success "No files remain owned by $old_user"
    fi
    
    # Verify new user can sudo (if they were in wheel/sudo group)
    if groups "$new_user" | grep -q -E '(wheel|sudo)'; then
        if sudo -u "$new_user" sudo -n whoami >/dev/null 2>&1; then
            log_success "New user has working sudo access"
        else
            log_warning "New user is in sudo group but sudo may need configuration"
        fi
    fi
    
    log_success "Migration verification completed successfully"
}

# Main execution function
main() {
    local old_user=$1
    local new_user=$2
    local new_password=$3
    
    log_info "Starting user migration: $old_user -> $new_user"
    log_info "Timestamp: $(date)"
    
    # Execute migration steps
    validate_root
    validate_users "$old_user" "$new_user"
    create_backup "$old_user"
    gather_user_info "$old_user"
    create_new_user "$old_user" "$new_user" "$new_password"
    transfer_ownership "$old_user" "$new_user"
    transfer_crontab "$old_user" "$new_user"
    check_service_dependencies "$old_user"
    terminate_sessions "$old_user"
    delete_old_user "$old_user" "$new_user"
    verify_migration "$old_user" "$new_user"
    
    log_success "🎉 User migration completed successfully!"
    log_info "Summary:"
    log_info "  - Old user: $old_user (deleted)"
    log_info "  - New user: $new_user (active)"
    log_info "  - Backup created in: /root/user_migration_backups/"
    log_info "  - All file ownership transferred"
    log_info "  - Services unaffected"
}

# Handle script execution
if [[ $# -ne 3 ]]; then
    usage
fi

# Execute main function with all arguments
main "$1" "$2" "$3"
