#!/bin/bash

######################
###
### specific to armhf architecture (Pi 0 and 1) 
### WITH ReSpeaker 4-Mics Pi HAT 
### WITH a AHT sensor
###
### This script installs the seeed voicecard, rhasspy, and snapclient onto the system.
### There is also a python script that will automatically run for a AHT temperature
### and humidty sensor
###
######################
### Configurations ###
######################

host_id="XXX.XXX.XX.XXX"
base_url="/home/blueberry/"

# mqtt variables
broker_address = "XXX.XXX.XX.XXX"
broker_port = XXXX
username = "XXXXXXXXXXXX"
password = "XXXXXXXXXXXX"

rhasspy_deb="rhasspy_armel.deb"
seeed_git="HinTak/seeed-voicecard.git"
snapclient_deb="snapclient_0.27.0-1_armhf.deb"

#######################

# Setup logging and log file location
exec > >(tee -i $base_url/setup_log.txt) 2>&1
set -e

######################
###   Functions    ###
######################
# Function to update Avahi configuration
update_avahi_config() {
    local avahi_config="/etc/avahi/avahi-daemon.conf"
    echo "Updating Avahi configuration"
    # Check and update or append publish-hinfo
    if grep -q '^#publish-hinfo=' "$avahi_config"; then
        sudo sed -i 's/^#publish-hinfo=.*/publish-hinfo=yes/' "$avahi_config"
    elif grep -q '^publish-hinfo=' "$avahi_config"; then
        sudo sed -i 's/^publish-hinfo=.*/publish-hinfo=yes/' "$avahi_config"
    else
        echo "publish-hinfo=yes" | sudo tee -a "$avahi_config"
    fi
    # Check and update or append publish-workstation
    if grep -q '^#publish-workstation=' "$avahi_config"; then
        sudo sed -i 's/^#publish-workstation=.*/publish-workstation=yes/' "$avahi_config"
    elif grep -q '^publish-workstation=' "$avahi_config"; then
        sudo sed -i 's/^publish-workstation=.*/publish-workstation=yes/' "$avahi_config"
    else
        echo "publish-workstation=yes" | sudo tee -a "$avahi_config"
    fi
    echo "Avahi configuration updated. Restarting Avahi service."
    sudo systemctl restart avahi-daemon
}
enable_I2S_overlay() {
    # Enable I2S overlay in /boot/config.txt
    echo "Enabling I2S overlay for PCM5102A..."
    if grep -q "dtoverlay=hifiberry-dac" /boot/config.txt; then
        echo "I2S overlay already enabled."
    else
        echo "dtoverlay=hifiberry-dac" | sudo tee -a /boot/config.txt > /dev/null
        echo "I2S overlay enabled."
    fi
}

######################
###   Main Block   ###
######################
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y python3-full python3-pip dkms git avahi-utils mosquitto-clients portaudio19-dev libasound2 libasound2-plugins alsa-utils libatlas-base-dev libflac-dev libsoxr-dev libogg-dev libopus-dev libvorbis-dev expat libfftw3-dev libconfig-dev libasound2-dev libgconf-2-4 cmake

cd $base_url

echo " ---- Installing adafruit-circuitpython-ahtx0 ..."
sudo pip3 install adafruit-circuitpython-ahtx0
echo " ---- Installing paho-mqtt ..."
sudo pip3 install paho-mqtt

update_avahi_config
enable_I2S_overlay

### Setup the seeed-voicecard
echo "Setting up the Seeed-voicecard..."
git clone https://github.com/$seeed_git
cd seeed-voicecard
sudo ./install.sh
cd ..
echo "Removing Seeed-voicecard folder..."
sudo rm -r seeed-voicecard

### Setup Snapclient
echo "Setting up Snapclient ($snapclient_deb)..."
wget https://github.com/badaix/snapcast/releases/download/v0.27.0/$snapclient_deb
sudo apt-get install -y ./$snapclient_deb
sudo rm $snapclient_deb

### swaps the snapclient build that I fixed the white noise in
echo "Swapping out the snapclient build that fixes the white noise problem"
wget https://github.com/chaosoflife/ultrahouse/blob/main/snapclient_rhasspy_satalite/snapclient_armhf
sudo mv snapclient_armhf /usr/local/bin/snapclient

### Setup Rhasspy
echo "Setting up Rhasspy..."
wget https://github.com/rhasspy/rhasspy/releases/latest/download/$rhasspy_deb
sudo apt-get install -y ./$rhasspy_deb
sudo rm $rhasspy_deb


### Build the script to set the desired levels for the soundcard
echo "Creating script to keep proper alsa levels for the soundcard..."
cat << EOF | sudo tee /etc/alsa-restore.sh > /dev/null
#!/bin/bash
sleep 2
amixer -c 1 cset numid=13 121
amixer -c 1 cset numid=16 4
amixer -c 1 cset numid=15 4
EOF
sudo chmod +x /etc/alsa-restore.sh

### Create a systemd service to restore ALSA settings at startup
echo "Creating a systemd service to restore ALSA settings at startup..."
cat << EOF | sudo tee /etc/systemd/system/alsa-restore-user.service > /dev/null
[Unit]
Description=Restore ALSA mixer settings
After=sound.target dev-snd-controlC1.device
Requires=dev-snd-controlC1.device

[Service]
Type=oneshot
ExecStart=/bin/bash /etc/alsa-restore.sh

[Install]
WantedBy=multi-user.target
EOF

### Modify the SNAPCLIENT_OPTIONS to connect to the snapserver and use the alsa sound card configuration
echo "modifying the snapcast systemd service to have the proper host and soundcard..."
cat << EOF | sudo tee /etc/default/snapclient > /dev/null
# Start the client, used only by the init.d script
START_SNAPCLIENT=true
# For a list of available options, invoke "snapclient --help"
SNAPCLIENT_OPTS="-h "${host_id}" --player alsa -s playback"
EOF
sudo update-rc.d snapclient disable

### Create a systemd service to start Rhasspy at startup
echo "Creating a systemd service to start Rhasspy at startup..."
cat << EOF | sudo tee /etc/systemd/system/rhasspy-start.service > /dev/null
[Unit]
Description=Rhasspy Service
After=syslog.target network.target mosquitto.service

[Service]
Type=simple
ExecStart=/bin/rhasspy -p en --user-profiles ${base_url}/rhasspy
User=blueberry
Group=audio
RestartSec=10
Restart=on-failure
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=rhasspy

[Install]
WantedBy=multi-user.target
EOF


echo " ---- Writing python script to get temperature and humidity ..."
cat << EOF | sudo tee /usr/local/bin/AHTsensor.py > /dev/null
import time
import board
import adafruit_ahtx0
import paho.mqtt.client as mqtt
import socket
import json
import threading

def publish_sensor_data():
    while True:
        temperature = sensor.temperature
        temperature = (temperature * (9/5)) + 32
        temperature = round(temperature, 3)

        humidity = sensor.relative_humidity
        humidity = round(humidity, 3)

        client.publish(topic_temp, temperature)
        client.publish(topic_humidity, humidity)

        time.sleep(60)  # Adjust this interval as needed

def on_connect(client, userdata, flags, rc):
    print("Connected with result code "+str(rc))
    client.publish(discovery_temp, json.dumps(temp_config), retain=True)
    client.publish(discovery_humidity, json.dumps(humidity_config), retain=True)

hostname = socket.gethostname()
broker_address = "${broker_address}"
broker_port = ${broker_port}
username = "${username}"
password = "${password}"

topic_temp = f"home/{hostname}/temperature"
topic_humidity = f"home/{hostname}/humidity"
discovery_temp = f"homeassistant/sensor/{hostname}/temperature/config"
discovery_humidity = f"homeassistant/sensor/{hostname}/humidity/config"

# Sensor configuration for temperature
temp_config = {
    "name": f"{hostname} Temperature",
    "state_topic": topic_temp,
    "unit_of_measurement": "°F",
    "device_class": "temperature",
    "value_template": "{{ value }}"
}

# Sensor configuration for humidity
humidity_config = {
    "name": f"{hostname} Humidity",
    "state_topic": topic_humidity,
    "unit_of_measurement": "%",
    "device_class": "humidity",
    "value_template": "{{ value }}"
}

i2c = board.I2C()
sensor = adafruit_ahtx0.AHTx0(i2c)

client = mqtt.Client(hostname)
client.username_pw_set(username, password)
client.on_connect = on_connect

client.connect(broker_address, broker_port)
client.loop_start()

# Start a new thread for publishing sensor data
thread = threading.Thread(target=publish_sensor_data)
thread.start()
EOF
sudo chmod +x /usr/local/bin/AHTsensor.py

echo " --- Creating a systemd service to start the python script at startup..."
cat << EOF | sudo tee /etc/systemd/system/ahtsensor.service > /dev/null
[Unit]
Description=AHT20 Sensor Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/AHTsensor.py
WorkingDirectory=/usr/local/bin
StandardOutput=inherit
StandardError=inherit
Restart=always
User=blueberry

[Install]
WantedBy=multi-user.target
EOF

### Enable and start the services
echo " --- enabling the rhasspy-start.service..."
sudo systemctl enable rhasspy-start
echo " --- starting the rhasspy-start.service..."
sudo systemctl start rhasspy-start

echo " --- enabling the alsa-restore-user.service..."
sudo systemctl enable alsa-restore-user
echo " --- starting the alsa-restore-user.service..."
sudo systemctl start alsa-restore-user

echo " --- enabling the ahtsensor.service..."
sudo systemctl enable ahtsensor.service
echo " --- starting the ahtsensor.service..."
sudo systemctl start ahtsensor.service

echo " --- enabling the snapclient.service..."
sudo systemctl enable snapclient.service
echo " --- starting the snapclient.service..."
sudo systemctl start snapclient.service

echo " --- Autoremoving packages..."
sudo apt-get autoremove -fy
echo " --- SCRIPT IS DONE ---- "