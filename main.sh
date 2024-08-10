#!/bin/bash

is_docker_installed() {
    # Checking for docker
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

install_docker() {
    echo "Installing Docker"
    curl -fsSL https://get.docker.com -o get-docker.sh | bash
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

is_port_open() {
    port=$1
    if netstat -tuln | grep ":$port" > /dev/null; then
        return 1
    else
        return 0
    fi
}



available_drives() {
    echo "Available drives and partitions:"
    echo "-----------------------------------"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    echo "-----------------------------------"
}

supported_filesystems() {
    i=0
    echo "Supported filesystem types:"
    echo "-----------------------------------"
    fs_list=($(ls /sbin/mkfs.* | sed -n 's|.*/mkfs\.||p'))
    # Print the array
    n=0
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

auto_mount() {
    part=$1
    drive_name=$2
    mount_point=$3
    fs_type=$4
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
    chmod 400 /root/.key
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

install_httpd() {
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
        if [[ ! $port =~ ^[0-9]+$ ]] || [ $port -lt 2 ] || [ $port -gt 65535 ]; then
            echo "Please enter a valid port number!"
        fi
        if is_port_open $port; then
            break
        else
            echo "${port} is occupied. Please retry!"
        fi
    done

    docker run -d \
        --name httpd-server \
        -p $port:80 \
        -v "$input":/usr/local/apache2/htdocs/ \
        --restart always httpd 
}

install_mysql() {
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
        if [[ ! $port =~ ^[0-9]+$ ]] || [ $port -lt 2 ] || [ $port -gt 65535 ]; then
            echo "Please enter a valid port number!"
        fi
        if is_port_open $port; then
            break
        else
            echo "${port} is occupied. Please retry!"
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
}

install_httpd
install_mysql