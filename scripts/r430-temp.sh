#!/bin/bash

# Enable or disable test mode
TEST_MODE=true  # Set to true to enable test mode, false for regular execution
LOG_OUTPUT_TO_CONSOLE=true  # Set to true to display output every 15 seconds for 2 minutes
FAN_MODE="Manual"  # Default fan mode, will be updated below based on user input or system setting

# Function to get the current temperature
get_temperature() {
    ipmitool sdr type temperature | grep degrees | grep -Po '\d{2}' | tail -1
}

# Function to get the current fan speed
get_fan_speed() {
    ipmitool sdr type fan | grep -Po '\d{3,4}' | tail -1
}

# Log temperature, fan speed, mode (manual/auto), and test mode to log file
log_to_file() {
    local temp=$1
    local fan_speed=$2
    local fan_mode=$3
    local test_mode=$4
    echo "$(date): Temp: $temp°C, Fan Speed: $fan_speed RPM, Mode: $fan_mode, Test Mode: $test_mode" >> $LOGFILE
}

# Show the current temperature and fan speed
TEMP=$(get_temperature)
FAN_SPEED=$(get_fan_speed)
LOGFILE="/var/scripts/templog.txt"
echo "Current Temp: $TEMP°C"
echo "Current Fan Speed: $FAN_SPEED RPM"
echo "System is in $FAN_MODE mode"
echo "Test Mode: $TEST_MODE"

# Log the initial values
log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE

# If in test mode, ask for manual or automatic fan mode
if [ "$TEST_MODE" = true ]; then
    read -p "Do you want the fans in Manual or Automatic mode? (M/A): " FAN_MODE
    if [[ "$FAN_MODE" == "M" || "$FAN_MODE" == "m" ]]; then
        FAN_MODE="Manual"
        echo "Test mode: Fans will be set to Manual mode."
        ipmitool raw 0x30 0x30 0x01 0x00
    elif [[ "$FAN_MODE" == "A" || "$FAN_MODE" == "a" ]]; then
        FAN_MODE="Automatic"
        echo "Test mode: Fans will be set to Automatic mode."
        ipmitool raw 0x30 0x30 0x01 0x01
    else
        echo "Invalid input. Defaulting to Automatic mode."
        FAN_MODE="Automatic"
        ipmitool raw 0x30 0x30 0x01 0x01
    fi

    # Monitor temperature and fan speed every 15 seconds for 2 minutes (8 iterations)
    echo "Monitoring temperature, fan speed, and mode every 15 seconds for 2 minutes..."
    for i in {1..8}; do
        TEMP=$(get_temperature)
        FAN_SPEED=$(get_fan_speed)
        echo "[$(date '+%H:%M:%S')] Current Temp: $TEMP°C, Fan Speed: $FAN_SPEED RPM, Mode: $FAN_MODE, Test Mode: $TEST_MODE"
        log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        sleep 15
    done
    echo "Temperature, fan speed, and mode monitoring complete."
else
    # Enable manual/static fan speed (if not in test mode)
    ipmitool raw 0x30 0x30 0x01 0x00
    FAN_MODE="Manual"

    # If LOG_OUTPUT_TO_CONSOLE is enabled, monitor temperature and fan speed every 15 seconds for 2 minutes
    if [ "$LOG_OUTPUT_TO_CONSOLE" = true ]; then
        echo "Monitoring temperature, fan speed, and mode every 15 seconds for 2 minutes..."
        for i in {1..8}; do
            TEMP=$(get_temperature)
            FAN_SPEED=$(get_fan_speed)
            echo "[$(date '+%H:%M:%S')] Current Temp: $TEMP°C, Fan Speed: $FAN_SPEED RPM, Mode: $FAN_MODE, Test Mode: $TEST_MODE"
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
            sleep 15
        done
        echo "Temperature, fan speed, and mode monitoring complete."
    fi
fi

# Define temperature and log file path
TEMP=$(get_temperature)
LAST_TEMP=0
MAX_LOG_SIZE=$((50 * 1024 * 1024))  # 50MB in bytes

# Check if the log file exists and read only the last temperature value from the log
if [ -f "$LOGFILE" ]; then
    LAST_TEMP=$(grep -Po '\d{2}' "$LOGFILE" | tail -1)
fi

# Check if the log file exceeds 50MB and rotate if necessary
if [ -f "$LOGFILE" ]; then
    FILESIZE=$(stat -c%s "$LOGFILE")
    if [ $FILESIZE -ge $MAX_LOG_SIZE ]; then
        echo "Log file exceeds 50MB. Rotating log file..."
        if [ "$TEST_MODE" = false ]; then
            mv $LOGFILE "$LOGFILE.$(date +'%Y%m%d_%H%M%S')"  # Rotate the log file by renaming it with a timestamp
            touch $LOGFILE  # Create a new empty log file
        fi
    fi
fi

echo "Current Temp: $TEMP°C"
echo "Last Temp: $LAST_TEMP°C"

# Function to trigger the API call
trigger_api_call() {
    if [ "$TEST_MODE" = false ]; then
        curl -H "Content-type: multipart/form-data" \
            -F title=Temp \
            -F server=homelab \
            -F temp-now=$TEMP \
            -F temp-last=$LAST_TEMP \
            -F fan-speed=$FAN_SPEED \
            -F fan-mode=$FAN_MODE \
            -F test-mode=$TEST_MODE \
            -X POST https://automate.domain.com/webhook/pve-temp
    else
        echo "API call would have been triggered: Temp-now=$TEMP, Temp-last=$LAST_TEMP, Fan-speed=$FAN_SPEED, Mode: $FAN_MODE, Test Mode: $TEST_MODE"
    fi
}

# Fan speed control logic with updated thresholds
if [[ $TEMP -lt 40 ]]; then
    if [[ $LAST_TEMP -ge 40 ]]; then
        FAN_SPEED="4%"
        echo "Setting fan speed to $FAN_SPEED (Temp < 40°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x04
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 40 && $TEMP -lt 45 ]]; then
    if [[ $LAST_TEMP -lt 40 || $LAST_TEMP -ge 45 ]]; then
        FAN_SPEED="8%"
        echo "Setting fan speed to $FAN_SPEED (40°C <= Temp < 45°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x08
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 45 && $TEMP -lt 50 ]]; then
    if [[ $LAST_TEMP -lt 45 || $LAST_TEMP -ge 50 ]]; then
        FAN_SPEED="16%"
        echo "Setting fan speed to $FAN_SPEED (45°C <= Temp < 50°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x10
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 50 && $TEMP -lt 55 ]]; then
    if [[ $LAST_TEMP -lt 50 || $LAST_TEMP -ge 55 ]]; then
        FAN_SPEED="32%"
        echo "Setting fan speed to $FAN_SPEED (50°C <= Temp < 55°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x20
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 55 && $TEMP -lt 60 ]]; then
    if [[ $LAST_TEMP -lt 55 || $LAST_TEMP -ge 60 ]]; then
        FAN_SPEED="40%"
        echo "Setting fan speed to $FAN_SPEED (55°C <= Temp < 60°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x28
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 60 && $TEMP -lt 70 ]]; then
    if [[ $LAST_TEMP -lt 60 || $LAST_TEMP -ge 70 ]]; then
        FAN_SPEED="64%"
        echo "Setting fan speed to $FAN_SPEED (60°C <= Temp < 70°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x40
            log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 70 ]]; then
    FAN_SPEED="Automatic"
    echo "Temperature above 70°C, enabling automatic fan control"
    if [ "$TEST_MODE" = false ]; then
        ipmitool raw 0x30 0x30 0x01 0x01  # Enable automatic fan control
        log_to_file $TEMP $FAN_SPEED $FAN_MODE $TEST_MODE
        trigger_api_call  # Ensure API call is made every time the temp exceeds 70°C
    fi
else
    echo "Temperature out of expected range."
fi

# Display the last 5 logged temperatures, fan speeds, and modes
echo "Last 5 temperatures, fan speeds, and modes logged:"
tail -n 5 $LOGFILE
