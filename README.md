# ultrahouse
The main repositiory for all things ultrahouse


The docker-compose folder has the docker-compose files I use to run my services on the server.


The snapclient_rhasspy_satellite folder has the scripts to build a working snapclient/rhasspy satellite image for a raspberry pi zero and zero2.
setup_zero.sh only has snapclient. This is for the raspberry pi zero and not zero2. I found out that I cannot run both snapclient and rhasspy on the limited hardware of the zero. The rest of the scripts are for zero2.

If it says 2mic, it is for the "ReSpeaker 2-Mics Pi HAT"

If it says 4mic, it is for the "ReSpeaker 4-Mic Array"

There is a script in there that uses docker containers for rhasspy and snapclient (setup-dock_2mic). But I moved away from that to limit the resource load on the pi by not running docker.
