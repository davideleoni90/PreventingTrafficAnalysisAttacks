#! /bin/bash

TIMEOUT=5
PACKETS_TIME_MAX_DELTA=4.5

# name of this script
FILENAME="$(basename $0)"

# iteration
ITERATION="$2"

# interface to be monitored
INTERFACE="$3"

# the IP address of the Android device
DEVICE_IP="$4"

CAPTURE_FILTER="host ${DEVICE_IP}"
DISPLAY_FILTER="not arp and not bjnp and not dns and not ntp and not(ip.src==216.58.192.0/19 or ip.dst==216.58.192.0/19) and not tcp.analysis.retransmission and not tcp.analysis.fast_retransmission"

# the output pcap has the same name as the script
OUTPUT_PCAP="Traces/Twitter/${FILENAME%.*}"

# if the second parameter passed to the script is 0 the default network is being used, while if it's 1 the Tor network is being used: in this case add a suffix to the the .pcap and .csv files produced in order to distinguish the between the different configurations

if [ "$1" == 1 ]
then 
	OUTPUT_PCAP="${OUTPUT_PCAP}_tor"
fi

# also append the number of the iteration to the output files produced
OUTPUT_PCAP="${OUTPUT_PCAP}_${ITERATION}"

# the output csv has same name as the trace file
OUTPUT_CSV="${OUTPUT_PCAP}.csv"

# USER ACTION INIT

# start Twitter Main Activity
adb shell am start "com.twitter.android/com.twitter.app.main.MainActivity"

# wait for it to get loaded
sleep 2

# in case the Tor Network is to be used, set the proxy in the app
if [ "$1" == 1 ]
then

	echo "HEREEEEE"
	#first open the lateral menu
	adb shell input keyevent 82
	sleep 0.5
	
	# then select "Settings and Privacy" (suppress warning messages)
	adb shell input tap 600 2100 1>/dev/null
	sleep 0.5

	# then select the "Location and Proxy" (suppress warning messages)
	adb shell input tap 600 2400 1>/dev/null
	sleep 0.5

	# then select "Proxy"
	adb shell input tap 600 750 1>/dev/null
	sleep 0.5

	# and finally check the option "Enable HTTP Proxy" (PREREQUISITE: the proxy has to be already configured)
	adb shell input tap 600 450 1>/dev/null
	sleep 0.5

	# exit the menu
	adb shell input keyevent 4
	adb shell input keyevent 4
	adb shell input keyevent 4
fi

# go to the Home (suppress warning messages)
adb shell input tap 184 400 1>/dev/null
sleep 0.5

# start capturing; suppress statistics (with "-l") as well as messages to standard output and error
tshark -i "${INTERFACE}" -l -q -n -f "${CAPTURE_FILTER}" -w "${OUTPUT_PCAP}.pcap" > /dev/null 2>&1 &

# get the pid of the background process: this is needed to stop it as soon as the user action has finished
TSHARK_PID=$!

# wait for tshark to be ready to capture
sleep 5

# time at the moment when the capture starts (in seconds): we will consider only packet whose timestamp
# is greater than this, in order to be sure to analyse only the traffic generated by the user action.
# The format is "seconds since midnight of first january 1970
START_TIME=$(date -u '+%s.%N')

# USER ACTION STARTED

# open the lateral menu
adb shell input keyevent 82 1>/dev/null
sleep 0.5

# click on the "Following" label
adb shell input tap 300 700 1>/dev/null

# capture for TIMEOUT seconds
sleep $TIMEOUT

# stop capturing
kill "$TSHARK_PID"

# if the Tor network was used, reset the proxy configuration

if [ "$1" == 1 ]
then

	# first go back to the Home
	adb shell input keyevent 4
	sleep 0.5
	
	#then open the lateral menu
	adb shell input keyevent 82
	sleep 0.5

	# then select "Settings and Privacy" (suppress warning messages)
	adb shell input tap 600 2100 1>/dev/null
	sleep 0.5

	# then select the "Location and Proxy" (suppress warning messages)
	adb shell input tap 600 2400 1>/dev/null
	sleep 0.5

	# then select "Proxy"
	adb shell input tap 600 750 1>/dev/null
	sleep 0.5
	
	# and finally uncheck the option "Enable HTTP Proxy" (PREREQUISITE: the proxy has to be already configured)
	adb shell input tap 600 450 1>/dev/null
	sleep 0.5

	# exit the menu
	adb shell input keyevent 4
        adb shell input keyevent 4
        adb shell input keyevent 4
fi

# stop the app
adb shell am force-stop "com.twitter.android"

# USER ACTION FINISHED

# COLLECT TRACE -> get a CSV out of the trace

# we have to consider only the packets whose timestamp is bigger than "START_TIME", i.e. those generated by the user action
# also we expect that two successive packets in the flow generated by the user action are at most PACKETS_TIME_MAX_DELTA seconds far from each other
# => read each packet from the trace and copy to the CSV only those which are PACKETS_TIME_MAX_DELTA seconds far from each other

PACKET_INDEX=-1
LAST_PACKET_TIME=0
DISCARDED=0

while read line
do
	# just copy the headers to the CSV

	if [ "$PACKET_INDEX" == -1 ]
	then
		echo "$line" > "$OUTPUT_CSV"
		PACKET_INDEX=$((PACKET_INDEX +1))
		continue
	fi

	# get the absolute time of the packet

	TIME_STAMP=$(echo $line | awk '{print $9}')
	
	# transform into the same format as START_TIME: they are easier to compare in this way
	# in case the time-zone is not UTC, set it to UTC, to make it comparable with the start time, by adding 3600 (one hour) to the
	# counter of seconds

	TIME_ZONE=`date -d "${TIME_STAMP}" | awk '{split($0,a,", ")} END {print a[3]}'`
	if [ "$TIME_ZONE" != "UTC" ]
	then
		SECONDS_NOT_UTC=$(date -d "${TIME_STAMP}" '+%s.%N' | awk '{split($0,a,".")} END {print a[1]}')
		NANOSECONDS=$(date -d "${TIME_STAMP}" '+%s.%N' | awk '{split($0,a,".")} END {print a[2]}')
		SECONDS_UTC=$((SECONDS_NOT_UTC+3600))
		TIME_STAMP="$SECONDS_UTC.$NANOSECONDS"
	fi

	# if PACKET_INDEX is zero, no packet from the flow generated by the user action has been seen yet => check if the timestamp of the packet
	# is at most PACKETS_TIME_MAX_DELTA seconds after START_TIME

	if [ "$PACKET_INDEX" == 0 ]
	then
 		COMPARE=$( echo $TIME_STAMP-$START_TIME'>'0 | bc -l )
		if [ "$COMPARE" == 0 ]
		then
			# this packet is not part of the flow from the user action, so go to next one
			DISCARDED=$((DISCARDED +1))
			continue
		else
			# this packet may belong to the flow because came after START_TIME: it belongs to the flow if is at most PACKETS_TIME_MAX_DELTAseconds far from START_TIME
			COMPARE=$( echo $TIME_STAMP-$START_TIME'<'$PACKETS_TIME_MAX_DELTA | bc -l ) 
			if [ "$COMPARE" == 0 ]
			then
				# this packet is not part of the flow generated by the user action: since no packet has been seen yet (PACKET_INDEX is zero) there's no hope that next packets will be part of the flow, so stop reading the trace
				break
			else
				# this packet is the first from the flow generated by the user action: store it into the CSV, increment the packet index and set its time stamp into $LAST_PACKET_TIME

				PACKET_INDEX=$((PACKET_INDEX +1))
				LAST_PACKET_TIME=$TIME_STAMP
				echo "$line" >> "$OUTPUT_CSV"
				continue
			fi
		fi
	
	# if PACKET_INDEX is greater than zero, at least one packet from the flow has been captured => check if the current packet came after at most PACKETS_TIME_MAX_DELTA seconds after the last one: if so, store it in the CSV and keep reading the trace, otherwise stop
	
	else
		COMPARE=$( echo $TIME_STAMP-$LAST_PACKET_TIME'<'$PACKETS_TIME_MAX_DELTA | bc -l )
		if [ "$COMPARE" == 0 ]
		then
			# this packet is not part of the flow, so stop reading the trace
			break
		else
			# this packet is part of the flow: store it into the CSV, increment the packet index and set its time stamp into $LAST_PACKET_TIME
			PACKET_INDEX=$((PACKET_INDEX +1))
			LAST_PACKET_TIME=$TIME_STAMP
			echo "$line" >> "$OUTPUT_CSV"
			continue
		fi
	fi
done < <(tshark -i "${INTERFACE}" -e "_ws.col.Time" -e "frame.number" -e "ip.src" -e "ip.dst" -e "tcp.srcport" -e "tcp.dstport" -e "frame.len" -e "_ws.col.Protocol" -e "_ws.col.Absolute time" -T "fields" -r "${OUTPUT_PCAP}.pcap" -E header=y -Y "${DISPLAY_FILTER}")
