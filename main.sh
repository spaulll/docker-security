#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
YELLOW_BOLD='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if docker is available
is_docker_installed() {
    if command -v docker > /dev/null 2>&1; then
        echo -e "${GREEN}Docker is installed${NC}"
        return 0
    else
        echo -e "${RED}Docker is not installed.${NC} Do you want to install Docker? [Y/n]: "
        read -r answer
        if [ "$answer" = "Y" ] || [ "$answer" = "y" ] || [ -z "$answer" ]; then
            install_docker
            return 0
        else
            echo -e "${YELLOW}Docker installation skipped.${NC}"
            return 1
        fi
    fi
}

# Installs docker
install_docker() {
    echo -e "${CYAN}Installing Docker${NC}"
    curl -fsSL https://get.docker.com | bash

    # Checking if docker daemon is running
    if systemctl is-active --quiet docker.service; then
        echo -e "${GREEN}Docker daemon is running${NC}"
    else
        echo -e "${YELLOW}Starting docker daemon..${NC}"
        if systemctl start docker.service > /dev/null 2>&1; then
            echo -e "${GREEN}Docker daemon started.${NC}"
        else
            echo -e "${RED}Failed to start docker daemon.${NC}"
            echo -e "${RED}Exiting...${NC}"
            exit 1
        fi        
    fi

    dockerd-rootless-setuptool.sh install
}

# Check if any port is open or not
is_port_open() {
    local port=$1
    if netstat -tuln | grep ":$port" > /dev/null; then
        return 1
    else
        return 0
    fi
}

# Prints available drives
available_drives() {
    echo -e "${CYAN}Available drives and partitions:${NC}"
    echo "-----------------------------------"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    echo "-----------------------------------"
}

# Prints supported FS types
supported_filesystems() {
    echo -e "${CYAN}Supported filesystem types:${NC}"
    echo "-----------------------------------"
    fs_list=($(ls /sbin/mkfs.* | sed -n 's|.*/mkfs\.||p'))
    # Print the array
    local n=0
    for i in "${fs_list[@]}"; do
        n=$((n+1))
        echo "${n}. $i" 
    done
    echo "-----------------------------------"
}

# Function to check if a filesystem type is valid
is_valid_fs_type() {
    local input_fs_type=$1
    for fs in "${fs_list[@]}"; do
        if [ "$fs" == "$input_fs_type" ]; then
            return 0
        fi
    done
    return 1
}

# For auto mount a LUKS encrypted drive 
auto_mount() {
    local part=$1
    local drive_name=$2
    local mount_point=$3
    local fs_type=$4
    while true; do
        read -sp "Please enter your password that you have used during encryption: " mount_key
        echo ""
        read -sp "Re-Type the password: " re_mount_key
        echo ""
        if [ "$mount_key" = "$re_mount_key" ]; then
            break
        else
            echo -e "${RED}Password not matched${NC}"
        fi
    done
    echo $mount_key > /root/.key
    chmod 440 /root/.key
    cryptsetup luksAddKey /dev/$part $drive_name
    # Adding UUID to crypttab
    UUID=$(blkid -s UUID -o value /dev/$part)
    if echo "${drive_name} UUID=${UUID} /root/.key luks" | tee -a /etc/crypttab > /dev/null; then
        echo -e "${GREEN}Successfully added UUID to crypttab.${NC}"
    else
        echo -e "${RED}Failed to add UUID to crypttab.${NC}"
    fi
    # Adding mount point to fstab
    echo "/dev/mapper/${drive_name} $mount_point $fs_type defaults 0 0" | tee -a /etc/fstab > /dev/null
    systemctl daemon-reload
    if mount -a; then
        echo -e "${GREEN}Successfully mounted $drive_name at $mount_point${NC}"
    else
        echo -e "${RED}Failed to mount $drive_name at $mount_point${NC}"
    fi
}

encrypt_dir() {

    local part mount_point fs_type

    # Checks if cryptsetup is present
    if ! command -v cryptsetup > /dev/null 2>&1; then
        echo -e "${RED}cryptsetup command not found.${NC}"
        echo -e "${RED}Exiting....${NC}"
        exit 1
    fi
    available_drives
    while true; do
        read -p "From the above drives choose a drive or partition: " part
        if lsblk | grep -qw "$part"; then
            echo -e "${GREEN}${part} is selected.${NC}"
            break
        else 
            echo -e "${RED}${part} is not present. Please retry!${NC}"
        fi
    done
    while true; do
        read -p "Enter the mount point (e.g., /mnt/encrypted): " mount_point
        if [ ! -d $mount_point ]; then
            echo -e "${RED}Mount point does not exist. Please create one and retry or enter an existing one!${NC}"
        else break
        fi
    done
    supported_filesystems
    while true; do
        read -p "Enter the filesystem type (e.g., ext4): " fs_type
        if is_valid_fs_type "$fs_type"; then
            break
        else
            echo -e "${RED}${fs_type} is not supported. Please retry!${NC}"
        fi
    done
    echo -e "${CYAN}Encrypting ${part}...${NC}"
    if ! cryptsetup luksFormat /dev/$part; then
        echo -e "${RED}Error while encrypting the drive. Please format the drive manually to continue.${NC}"
        echo -e "${RED}Exiting...${NC}"
        exit 1
    fi
    read -p "Enter the drive name: " drive_name
    cryptsetup luksOpen /dev/$part $drive_name

    echo -e "${CYAN}Formatting ${drive_name} to ${fs_type}${NC}"
    if mkfs.${fs_type} "/dev/mapper/$drive_name" 2> /dev/null; then
        echo -e "${GREEN}Formatting successful${NC}"
    else
        echo -e "${RED}Failed to format.${NC}"
        exit 1
    fi
    while true; do
        read -p "If you want $drive_name to auto mount at boot press 'Y' else 'C': " ch
        if [ "$ch" = 'Y' ] || [ "$ch" = 'y' ]; then
            auto_mount $part $drive_name $mount_point $fs_type
            break
        elif [ "$ch" = 'C' ] || [ "$ch" = 'c' ]; then
            break
        else
            echo -e "${RED}Invalid choice${NC}"
        fi
    done
}

add_to_firewall() {
    local port=$1
    firewall-cmd --permanent --add-port=${port}/tcp
    firewall-cmd --permanent --add-port=${port}/udp
    firewall-cmd --reload
}

install_httpd() {

    local input port

    if ! is_docker_installed; then
        echo -e "${RED}Docker is not found.${NC}"
        echo -e "${RED}Exiting...${NC}"
        exit 1
    fi
    echo -e "${CYAN}Pulling httpd from registry server${NC}"
    docker pull httpd
    echo ""
    echo -e "${CYAN}================================================================================${NC}"
    echo ""
    while true; do
        read -p "${YELLOW_BOLD}Enter a directory to use on httpd server.${NC} You can also use a mount point along with LUKS encryption. To encrypt a drive and mount it enter 'YES' in capital letters, or enter a directory name to proceed: " input
        if [ "$input" = "YES" ]; then
            encrypt_dir
            break
        fi
        if [ -d "$input" ]; then
            break
        else
            echo -e "${RED}Invalid input. Please enter a valid directory or 'YES' to encrypt and mount!${NC}"
        fi
    done

    while true; do
        read -p "Enter a port number to use on httpd server: " port
        if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 2 ] && [ $port -le 65535 ] && is_port_open $port; then
            break
        else
            echo -e "${RED}$port is invalid or occupied. Please retry!${NC}"
        fi
    done

    docker run -d \
        --name httpd-server \
        -p $port:80 \
        -v "$input":/usr/local/apache2/htdocs/ \
        --restart always httpd 
    
    add_to_firewall $port
    echo ""
    echo -e "${CYAN}================================================================================${NC}"
    echo ""
}

install_mysql() {

    local port input user_mariadb user_pass_mariadb re_user_pass_mariadb db_name root_pass_mariadb

    if ! is_docker_installed; then
        echo -e "${RED}Docker is not found.${NC}"
        echo -e "${RED}Exiting...${NC}"
        exit 1
    fi
    echo -e "${CYAN}Pulling MySQL from registry server${NC}"
    docker pull mysql/mysql-server
    echo ""
    echo -e "${CYAN}================================================================================${NC}"
    echo ""
    while true; do
        read -p "${YELLOW_BOLD}Enter a directory to use on mariadb server.${NC} You can also use a mount point along with LUKS encryption. To encrypt a drive and mount it enter 'YES' in capital letters, or enter a directory name to proceed: " input
        if [ "$input" = "YES" ]; then
            encrypt_dir
            break
        fi
        if [ -d "$input" ]; then
            break
        else
            echo -e "${RED}Invalid input. Please enter a valid directory or 'YES' to encrypt and mount!${NC}"
        fi
    done

    while true; do
        read -p "Enter a port number to use on mariadb server: " port
        if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 2 ] && [ $port -le 65535 ] && is_port_open $port; then
            break
        else
            echo -e "${RED}$port is invalid or occupied. Please retry!${NC}"
        fi
    done
    read -p "Enter username for MariaDB: " user_mariadb

    while true; do
        read -sp "Enter password for user ${user_mariadb}: " user_pass_mariadb
        echo ""
        read -sp "Re-Type the password: " re_user_pass_mariadb
        echo ""
        if [ "$user_pass_mariadb" = "$re_user_pass_mariadb" ]; then
            break
        else
            echo -e "${RED}Password not matched${NC}"
        fi
    done

    while true; do
        read -sp "Enter MariaDB ROOT password: " root_pass_mariadb
        echo ""
        read -sp "Re-Type the password: " re_root_pass_mariadb
        echo ""
        if [ "$root_pass_mariadb" = "$re_root_pass_mariadb" ]; then
            break
        else
            echo -e "${RED}Password not matched${NC}"
        fi
    done

    read -p "Enter a database name: " db_name

    docker run --detach --name mariadb \
        --env MARIADB_USER=$user_mariadb \
        --env MARIADB_PASSWORD=$user_pass_mariadb \
        --env MARIADB_DATABASE=$db_name \
        --env MARIADB_ROOT_PASSWORD=$root_pass_mariadb \
        -p $port:3306  mariadb:latest
    
    add_to_firewall $port
    echo ""
    echo -e "${CYAN}================================================================================${NC}"
    echo ""
}

show_menu() {
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${CYAN}            MAIN MENU                ${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo "1. Install and configure HTTPD server"
    echo "2. Install and configure MySQL server"
    echo "3. Check if Docker is installed"
    echo "4. List available drives"
    echo "5. List supported filesystem types"
    echo "6. Encrypt and mount a drive"
    echo "7. Exit"
    echo -e "${CYAN}=====================================${NC}"
}

# Main script
if [ `whoami` != 'root' ]; then
    echo -e "${RED}Root privileges are required to run this script.${NC}"
    echo -e "${RED}Exiting...${NC}"
    exit 1
fi

while true; do
    show_menu
    read -p "Enter your choice [1-7]: " choice
    case $choice in
        1) install_httpd ;;
        2) install_mysql ;;
        3) is_docker_installed ;;
        4) available_drives ;;
        5) supported_filesystems ;;
        6) encrypt_dir ;;
        7) echo -e "${CYAN}Exiting...${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid choice, Try again!${NC}"; echo "" ;;
    esac
    echo ""
done
