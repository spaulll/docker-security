#!/bin/bash

# Check if docker is available
is_docker_installed() {
    if command -v docker > /dev/null 2>&1; then
        echo "Docker is installed"
        return 0
    else
        echo "Docker is not installed. Do you want to install Docker? [Y/n]: "
        read -r answer
        if [ "$answer" = "Y" ] || [ "$answer" = "y" ] || [ -z "$answer" ]; then
            install_docker
            return 0
        else
            echo "Docker installation skipped."
            return 1
        fi
    fi
}

# Installs docker
install_docker() {
    echo "Installing Docker"
    curl -fsSL https://get.docker.com | bash
    # chmod +x get-docker.sh
    # sudo ./get-docker.sh

    # Checking is docker daemon if running
    if systemctl is-active --quiet docker.service; then
        echo "Docker daemon is running"
    else
        echo "Starting docker daemon.."
        if systemctl start docker.service > /dev/null 2>&1; then
            echo "Docker daemon started."
        else
            echo "Failed to start docker daemon."
            echo "Exiting..."
            exit 1
        fi        
    fi

    dockerd-rootless-setuptool.sh install
}

# Check if any port is occered or not
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
    echo "Available drives and partitions:"
    echo "-----------------------------------"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    echo "-----------------------------------"
}

# Prints supported FS types
supported_filesystems() {
    echo "Supported filesystem types:"
    echo "-----------------------------------"
    local fs_list=($(ls /sbin/mkfs.* | sed -n 's|.*/mkfs\.||p'))
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
        if [ "$mount_key" = "$re_mount_key" ]; then
            break
        else
            echo "Password not matched"
        fi
    done
    echo $mount_key > /root/.key
    chmod 440 /root/.key
    cryptsetup luksAddKey /dev/$part $drive_name
    # Adding UUID to crypttab
    UUID=$(blkid -s UUID -o value /dev/$part)
    if echo "${drive_name} UUID=${UUID} /root/.key luks" | tee -a /etc/crypttab > /dev/null; then
        echo "Successfully added UUID to crypttab."
    else
        echo "Failed to add UUID to crypttab."
    fi
    # Adding mount point to fstab
    echo "/dev/mapper/${drive_name} $mount_point $fs_type defaults 0 0" | tee -a /etc/fstab > /dev/null
    if mount -a; then
        echo "Successfully mounted $drive_name at $mount_point"
    else
        echo "Failed to mount $drive_name at $mount_point"
    fi
}

encrypt_dir() {

    local part mount_point fs_type

    # Checks if cryptsetup is present
    if ! command -v cryptsetup > /dev/null 2>&1; then
        echo "cryptsetup command not found."
        echo "Exiting...."
        exit 1
    fi
    available_drives
    while true; do
        read -p "From the above drives choose a drive or partition: " part
        if lsblk | grep -qw "$part"; then
            echo "${part} is selected."
            break
        else 
            echo "${part} is not present. Please retry!"
        fi
    done
    while true; do
        read -p "Enter the mount point (e.g., /mnt/encrypted): " mount_point
        if [ ! -d $mount_point ]; then
            echo "Mount point does not exist. Please create one and retry or enter existing one!"
        else break
        fi
    done
    supported_filesystems
    while true; do
        read -p "Enter the filesystem type (e.g., ext4): " fs_type
        if is_valid_fs_type "$fs_type"; then
            break
        else
            echo "${fs_type} is not supported. Please retry!"
        fi
    done
    echo "Encrypting ${part}..."
    cryptsetup luksFormat /dev/$part
    read -p "Enter the drive name: " drive_name
    cryptsetup luksOpen /dev/$part $drive_name

    echo "Formatting ${drive_name} to ${fs_type}"
    if mkfs.${fs_type} "/dev/mapper/$drive_name" 2> /dev/null; then
        echo "Formatting successful"
    else
        echo "Failed to format."
        exit 1
    fi
    while true; do
        read -p "If you want $drive_name to auto mount at boot press 'Y' else 'C': " ch
        if [ $ch = 'Y' ] || [ $ch = 'y' ]; then
            auto_mount $part $drive_name $mount_point $fs_type
            break
        elif [ $ch = 'C' ] || [ $ch = 'c' ]; then
            break
        else
            echo "Invalid choice"
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
        echo "Docker is not found."
        echo "Exiting..."
        exit 1
    fi
    echo "Pulling httpd from registry server"
    docker pull httpd
    while true; do
        read -p "Enter a directory to use on httpd server. You can also use a mount point along with LUKS encryption. To encrypt a drive and mount it enter 'yes' in capital letter, or enter a direcory name to proceed: " input
        if [ "$input" = "YES" ]; then
            encrypt_dir
            break
        fi
        if [ -d "$input" ]; then
            break
        else
            echo "Invalid input. Please enter a valid directory or 'YES' to encrypt and mount!"
        fi
    done

    while true; do
        read -p "Enter a port number to use on httpd server: " port
        if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 2 ] && [ $port -le 65535 ] && is_port_open $port; then
            break
        else
            echo "$port is invalid or occupied. Please retry!"
        fi
    done

    docker run -d \
        --name httpd-server \
        -p $port:80 \
        -v "$input":/usr/local/apache2/htdocs/ \
        --restart always httpd 
    
    add_to_firewall $port
}

install_mysql() {

    local port input user_mariadb user_pass_mariadb re_user_pass_mariadb db_name root_pass_mariadb

    if ! is_docker_installed; then
        echo "Docker is not found."
        echo "Exiting..."
        exit 1
    fi
    echo "Pulling MySQL from registry server"
    docker pull mysql/mysql-server

    while true; do
        read -p "Enter a directory to use on mariadb server. You can also use a mount point along with LUKS encryption. To encrypt a drive and mount it enter 'yes' in capital letter, or enter a direcory name to proceed: " input
        if [ "$input" = "YES" ]; then
            encrypt_dir
            break
        fi
        if [ -d "$input" ]; then
            break
        else
            echo "Invalid input. Please enter a valid directory or 'YES' to encrypt and mount!"
        fi
    done

    while true; do
        read -p "Enter a port number to use on mariadb server: " port
        if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 2 ] && [ $port -le 65535 ] && is_port_open $port; then
            break
        else
            echo "$port is invalid or occupied. Please retry!"
        fi
    done
    read -p "Enter username for MariaDB: " user_mariadb

    while true; do
        read -sp "Enter password for user ${user_mariadb}: " user_pass_mariadb
        echo ""
        read -sp "Re-Type the password: " re_user_pass_mariadb
        if [ "$user_pass_mariadb" = "$re_user_pass_mariadb" ]; then
            break
        else
            echo "Password not matched"
        fi
    done

    while true; do
        read -sp "Enter MariaDB ROOT password: " root_pass_mariadb
        echo ""
        read -sp "Re-Type the password: " re_root_pass_mariadb
        if [ "$root_pass_mariadb" = "$re_root_pass_mariadb" ]; then
            break
        else
            echo "Password not matched"
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
}

# Main script
if [ `whoami` != 'root' ]; then
    echo "Root privileges are required to run this script."
    echo "Exiting..."
    exit 1
fi

install_httpd
install_mysql