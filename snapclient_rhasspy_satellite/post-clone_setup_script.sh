#!/bin/bash

######################
###
### This is the hostname change "Setup" script. It makes two scripts that run on
### the next boot. It looks over the network for 'base_hostname'XX, and finds the last
### number in the 'base_hostname'XX sequence, and changes the name of the computer to
### 'base_hostname'XX+1.
###
######################
### Configurations ###
######################

base_url="/home/blueberry"
base_hostname="blueberry"

######################
###   Main Block   ###
######################
### Build the script to change the host name on first boot
echo "Creating script to change the host name..."
echo "writting to /etc/hostname_change.sh..."
cat << EOF | sudo tee /etc/hostname_change.sh > /dev/null
#!/bin/bash

# Log file location
LOG_FILE="${base_url}/hostname_change.log"


# Function to log messages
log_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a \$LOG_FILE
}

# Function to scan the network and find used hostnames
find_used_hostnames() {
    log_message "Scanning local network for used ${base_hostname} hostnames"
    avahi-browse -a -t | grep -o '${base_hostname}[0-9]\{2\}' | sort -u
}
# Function to determine the next available hostname
next_hostname() {
    local hostnames
    hostnames=(\$(find_used_hostnames))
    local count=1
    while true; do
        local new_name="${base_hostname}\$(printf '%02d' \$count)"
        if [[ ! " \${hostnames[@]} " =~ " \${new_name} " ]]; then
            echo \$new_name
            return
        fi
        ((count++))
    done
}
# Function to update Rhasspy configuration
update_rhasspy_config() {
    local hostname
    hostname=\$1
    local rhasspy_config="${base_url}/rhasspy/en/profile.json"
    log_message "Looking at the Rhasspy profile.json at \$rhasspy_config"
    log_message "finding site_id location in Rhasspy profile.json and changing to \$hostname"
    if [[ -f "\$rhasspy_config" ]]; then
        sudo sed -i 's/"site_id": "[^"]*"/"site_id": "'"\$hostname"'"/' "\$rhasspy_config"
        log_message "Updated Rhasspy configuration with new site_id: \$new_hostname"
    else
        log_message "Rhasspy configuration file not found!!!!!!"
    fi
}
# Function to set the hostname
set_hostname() {
    local hostname
    hostname=\$1
    log_message "changing /etc/hosts file to include \$hostname"
    sudo sed -i "s/127\.0\.1\.1.*/127\.0\.1\.1\t\$hostname/g" /etc/hosts
    log_message "changing computer hostname to \$hostname"
    sudo hostnamectl set-hostname \$hostname
    sleep 1
    log_message "hostname changed to \$hostname in /etc/hosts and /etc/hotsname"
}
# Function to restart interfaces
restart_interfaces() {
    log_message "Restarting the network interfaces using interface: wlan0"
    sudo systemctl restart dhcpcd
    sleep 5
    log_message "Flushing IP addresses from the interface and renewing DHCP lease"
    sudo ip addr flush dev wlan0
    sudo dhclient -r wlan0
    sudo dhclient wlan0
    sudo systemctl restart dhcpcd
    sudo systemctl restart avahi-daemon
}
log_message "Running raspi-config --expand-rootfs to adjust the system size"
log_message "-------------------------------------------------------------"
sudo raspi-config --expand-rootfs
log_message "Starting hostname_change"
log_message "-------------------------------------------------------------"
new_hostname=\$(next_hostname)
sleep 1
log_message "New hostname determined: \$new_hostname"
update_rhasspy_config \$new_hostname
set_hostname \$new_hostname
export HOSTNAME=\$new_hostname
echo HOSTNAME=\$new_hostname | tee ${base_url}/.env > /dev/null
restart_interfaces
if [[ -f "${base_url}/docker-compose.yml" ]]; then
    log_message "starting up docker-compose"
    sudo docker-compose up -d
else
    log_message "No docker-compose.yml found, skipping container startup"
fi

sleep 1
log_message "-------------------------------------------------------------"
log_message "All files modified: The computer is now called \$new_hostname"
log_message "-------------------------------------------------------------"
EOF

echo "Creating script to clean up everything..."
echo "writting to /etc/cleanup.sh..."
cat << EOF | sudo tee /etc/cleanup.sh > /dev/null
#!/bin/bash

# Log file location
LOG_FILE="${base_url}/cleanup.log"


# Function to log messages
log_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a \$LOG_FILE
}

# Remove the systemd service file
log_message ""
log_message "Running the cleanup script..."
log_message "-------------------------------------------------------------"
log_message "Disabling the first_boot service..."
sudo systemctl disable first_boot.service
sleep 1
log_message "Removing the first_boot service systemd file..."
sudo rm /etc/systemd/system/first_boot.service
sleep 1
log_message "Reloading the daemon..."
sudo systemctl daemon-reload
sleep 1
log_message "Resetting the failed services to completely remove the first boot service..."
sudo systemctl reset-failed
sleep 1
log_message "Post-clone cleanup script completed"
log_message "The system will reboot in 1 seconds."
sleep 1
sudo reboot
EOF

echo "Changing the bash scripts to be exacutable"
sudo chmod +x /etc/hostname_change.sh
sudo chmod +x /etc/cleanup.sh

### Create a systemd service to run the script on the next boot
echo "Creating systemd service to run the script on the next boot..."
echo "Saving to /etc/systemd/system/first_boot.service..."
cat << EOF | sudo tee /etc/systemd/system/first_boot.service > /dev/null
[Unit]
Description=Run the hostname_change and cleanup on first boot (first_boot.service)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /etc/hostname_change.sh
ExecStopPost=/bin/bash /etc/cleanup.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Enabling first_boot systemd service"
sudo systemctl enable first_boot

echo "Script Complete! The computer will now change the hostname on the next boot"
