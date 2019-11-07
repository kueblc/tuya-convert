#!/bin/bash
bold=$(tput bold)
normal=$(tput sgr0)
screen_minor=`screen --version | cut -d . -f 2`
if [ $screen_minor -gt 5 ]; then
    screen_with_log="sudo screen -L -Logfile"
elif [ $screen_minor -eq 5 ]; then
    screen_with_log="sudo screen -L"
else
    screen_with_log="sudo screen -L -t"
fi
. ./config.txt

./stop_flash.sh >/dev/null

pushd scripts >/dev/null

if [ ! -f eula_accepted ]; then
	echo "======================================================"
	echo "${bold}TUYA-CONVERT${normal}"
	echo
	echo "https://github.com/ct-Open-Source/tuya-convert"
	echo "TUYA-CONVERT was developed by Michael Steigerwald from the IT security company VTRUST (https://www.vtrust.de/) in collaboration with the techjournalists Merlin Schumacher, Pina Merkert, Andrijan Moecker and Jan Mahn at c't Magazine. (https://www.ct.de/)"
	echo 
	echo 
	echo "======================================================"
	echo "${bold}PLEASE READ THIS CAREFULLY!${normal}"
	echo "======================================================"
	echo "TUYA-CONVERT creates a fake update server environment for ESP8266/85 based tuya devices. It enables you to backup your devices firmware and upload an alternative one (e.g. ESPEasy, Tasmota, Espurna) without the need to open the device and solder a serial connection (OTA, Over-the-air)."
	echo "Please make sure that you understand the consequences of flashing an alternative firmware, since you might lose functionality!"
	echo
	echo "Flashing an alternative firmware can cause unexpected device behavior and/or render the device unusable. Be aware that you do use this software at YOUR OWN RISK! Please acknowledge that VTRUST and c't Magazine (or Heise Medien GmbH & Co. KG) CAN NOT be held accountable for ANY DAMAGE or LOSS OF FUNCTIONALITY by typing ${bold}yes + Enter${normal}"
	echo 
	read
	if [ "$REPLY" != "yes" ]; then
		exit
	fi
	touch eula_accepted
fi
echo "======================================================"
echo -n "  Starting AP in a screen"
$screen_with_log smarthack-wifi.log -S smarthack-wifi -m -d ./setup_ap.sh
while ! ping -c 1 -W 1 -n $GATEWAY &> /dev/null; do
	printf .
done
echo
echo "  Stopping any apache web server"
sudo service apache2 stop >/dev/null 2>&1
echo "  Starting web server in a screen"
$screen_with_log smarthack-web.log -S smarthack-web -m -d ./fake-registration-server.py
echo "  Starting Mosquitto in a screen"
sudo service mosquitto stop >/dev/null 2>&1
sudo pkill mosquitto
$screen_with_log smarthack-mqtt.log -S smarthack-mqtt -m -d mosquitto -v
echo "  Starting PSK frontend in a screen"
$screen_with_log smarthack-psk.log -S smarthack-psk -m -d ./psk-frontend.py -v
echo
REPLY=y
while [[ $REPLY =~ ^[Yy]$ ]]; do
echo "======================================================"
echo
echo "IMPORTANT"
echo "1. Connect any other device (a smartphone or something) to the WIFI $AP"
echo "   This step is IMPORTANT otherwise the smartconfig will not work!"
echo "2. Put your IoT device in autoconfig/smartconfig/pairing mode (LED will blink fast). This is usually done by pressing and holding the primary button of the device"
echo "3. Press ${bold}ENTER${normal} to continue"
read x
echo ""
echo "======================================================"

echo "Starting smart config pairing procedure"
./smartconfig/main.py &

echo "Waiting for the device to install the intermediate firmware"

i=60
while ! ping -c 1 -W 1 -n 10.42.42.42 &> /dev/null; do
	printf .
	if (( --i == 0 )); then
		echo
		echo "Device did not appear with the intermediate firmware"
		echo "Check the *.log files in the scripts folder"
		pkill -f smartconfig/main.py && echo "Stopping smart config"
		read -p "Do you want to flash another device? [y/N] " -n 1 -r
		echo
		continue 2
	fi
done

echo
echo "IoT-device is online with ip 10.42.42.42"

pkill -f smartconfig/main.py && echo "Stopping smart config"

echo "Fetching firmware backup"
sleep 2
timestamp=`date +%Y%m%d_%H%M%S`
mkdir -p "../backups/$timestamp"
pushd "../backups/$timestamp" >/dev/null
curl -JO http://10.42.42.42/backup

echo "======================================================"
echo "Getting Info from IoT-device"
curl -s http://10.42.42.42 | tee device-info.txt
popd >/dev/null

echo "======================================================"
echo "Ready to flash custom firmware"
echo "A basic build of Sonoff-Tasmota v6.5.0 is already included in this repository."
echo "To flash a different firmware, replace files/thirdparty.bin"
echo "BE SURE THE FIRMWARE FITS THE DEVICE!"
echo "${bold}MAXIMUM SIZE IS 512KB${normal}"

echo "======================================================"
read -p "Do you wish to continue? (answering no will revert your firmware to stock) [y/N] " -n 1 -r
echo
echo "======================================================"
if [[ $REPLY =~ ^[Yy]$ ]]; then
	if grep -q user1 device-info.txt; then
		echo "Detected intermediate firmware on userspace 1"
		echo "Two stage flash required"
		echo "Requesting device to flash user2.bin"
		echo "Please wait for flashing to complete. Do not unplug your device."
		curl -s http://10.42.42.42/flash2
		sleep 2
		echo "Making sure device is back online"
		while ! ping -c 1 -W 1 -n 10.42.42.42 &> /dev/null; do printf .; done
		echo
		sleep 2
	fi
	echo "Requesting device to flash thirdparty.bin"
	echo "Please wait for flashing to complete. Do not unplug your device."
	curl -s http://10.42.42.42/flash3
	sleep 2
	echo "The included thirdparty.bin will spawn an access point you can connect to and configure"
	echo "Look for the SSID sonoff-**** where **** is four unique numbers"
	echo "Remember to configure your new firmware for proper function"
	echo
	echo "HAVE FUN!"
	popd >/dev/null
else
	echo "Shutting down web server"
	sudo pkill -f fake-registration-server.py
	echo "Requesting device to revert to stock firmware"
	curl -s http://10.42.42.42/undo
	sleep 2
	echo "You will need to put the device back into pairing mode and register to use"
	echo "Unplug the device and press ${bold}ENTER${normal} to continue"
	read
	popd >/dev/null
	echo "Restarting web server"
	$screen_with_log smarthack-web.log -S smarthack-web -m -d ./fake-registration-server.py
fi

echo "======================================================"
read -p "Do you want to flash another device? [y/N] " -n 1 -r
echo
done

echo "Exiting..."

popd >/dev/null

