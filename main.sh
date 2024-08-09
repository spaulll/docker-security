#!/bin/bash

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
        ./loader.sh "systemctl start docker.service" "..." "Starting docker daemon"
    fi

    dockerd-rootless-setuptool.sh install
}

# Checking for docker
if command -v docker; then
    echo "Docker is installed"
else
    install_docker
fi
    
install_httpd() {
    echo "Pulling httpd from registry server"
    docker pull httpd
    while true; do
        read -p "Enter a directory to use on httpd server: " directory
        if [ -d "$directory" ]; then
            break
        else
            echo "Directory not found. Please retry!"
        fi
    done

    while true; do
        read -p "Enter a port number to use on httpd server: " port
        if is_port_open $port; then
            break
        else
            echo "${port} is occupied. Please retry!"
        fi
    done

    docker run --name httpd-server -p $port:80 -v "$directory":/usr/local/apache2/htdocs/ httpd
}

is_port_open() {
    port=$1
    if netstat -tuln | grep ":$port " > /dev/null; then
        return 1
    else
        return 0
    fi
}

install_httpd

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
    for fs in $(ls /sbin/mkfs.* 2>/dev/null); do
        fs_type=$(basename $fs | sed 's/^mkfs\.//')
        echo "$fs_type"
        fs_list[$i]=$fs_type
        i=$((i+1))
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

encrypt_dir() {

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

    read -p "Enter the mount point (e.g., /mnt/encrypted): " mount_point

    supported_filesystems
    while true; do
        read -p "Enter the filesystem type (e.g., ext4): " fs_type
        if is_valid_fs_type "$fs_type"; then
            break
        else
            echo "${fs_type} is not supported. Please retry!"
        fi
    done


}
encrypt_dir