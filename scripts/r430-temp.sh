#!/bin/bash

# Enable or disable test mode
TEST_MODE=true  # Set to true to enable test mode, false for regular execution
LOG_OUTPUT_TO_CONSOLE=true  # Set to true to display output every 15 seconds for 2 minutes

# Function to get the current temperature
get_temperature() {
    ipmitool sdr type temperature | grep degrees | grep -Po '\d{2}' | tail -1
}

# Function to get the current fan speed
get_fan_speed() {
    ipmitool sdr type fan | grep -Po '\d{3,4}' | tail -1
}

# Function to get the current fan PWM value
get_fan_pwm() {
ipmitool sdr type fan | grep 'Fan1A' | awk '{print $7}'
}

# Log temperature, fan speed, and fan PWM to log file
log_to_file() {
    local temp=$1
    local fan_speed=$2
    local fan_pwm=$3
    echo "$(date): Temp: $temp°C, Fan Speed: $fan_speed RPM, Fan PWM: $fan_pwm%" >> $LOGFILE
}

# Show the current temperature, fan speed, and PWM
TEMP=$(get_temperature)
FAN_SPEED=$(get_fan_speed)
FAN_PWM=$(get_fan_pwm)
LOGFILE="/var/scripts/templog.txt"
echo "Current Temp: $TEMP°C"
echo "Current Fan Speed: $FAN_SPEED RPM"
echo "Current Fan PWM: $FAN_PWM%"

# Log the initial values
log_to_file $TEMP $FAN_SPEED $FAN_PWM

# If in test mode, ask for manual or automatic fan mode
if [ "$TEST_MODE" = true ]; then
    read -p "Do you want the fans in Manual or Automatic mode? (M/A): " FAN_MODE
    if [[ "$FAN_MODE" == "M" || "$FAN_MODE" == "m" ]]; then
        echo "Test mode: Fans will be set to Manual mode."
        ipmitool raw 0x30 0x30 0x01 0x00
    elif [[ "$FAN_MODE" == "A" || "$FAN_MODE" == "a" ]]; then
        echo "Test mode: Fans will be set to Automatic mode."
        ipmitool raw 0x30 0x30 0x01 0x01
    else
        echo "Invalid input. Defaulting to Manual mode."
        FAN_MODE="M"
        ipmitool raw 0x30 0x30 0x01 0x00
    fi

    # Monitor temperature, fan speed, and PWM every 15 seconds for 2 minutes (8 iterations)
    echo "Monitoring temperature, fan speed, and PWM every 15 seconds for 2 minutes..."
    for i in {1..8}; do
        TEMP=$(get_temperature)
        FAN_SPEED=$(get_fan_speed)
        FAN_PWM=$(get_fan_pwm)
        echo "[$(date '+%H:%M:%S')] Current Temp: $TEMP°C, Fan Speed: $FAN_SPEED RPM, Fan PWM: $FAN_PWM%"
        log_to_file $TEMP $FAN_SPEED $FAN_PWM
        sleep 15
    done
    echo "Temperature, fan speed, and PWM monitoring complete."
else
    # Enable manual/static fan speed (if not in test mode)
    ipmitool raw 0x30 0x30 0x01 0x00

    # If LOG_OUTPUT_TO_CONSOLE is enabled, monitor temperature, fan speed, and PWM every 15 seconds for 2 minutes
    if [ "$LOG_OUTPUT_TO_CONSOLE" = true ]; then
        echo "Monitoring temperature, fan speed, and PWM every 15 seconds for 2 minutes..."
        for i in {1..8}; do
            TEMP=$(get_temperature)
            FAN_SPEED=$(get_fan_speed)
            FAN_PWM=$(get_fan_pwm)
            echo "[$(date '+%H:%M:%S')] Current Temp: $TEMP°C, Fan Speed: $FAN_SPEED RPM, Fan PWM: $FAN_PWM%"
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
            sleep 15
        done
        echo "Temperature, fan speed, and PWM monitoring complete."
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
            -F fan-pwm=$FAN_PWM \
            -X POST https://automate.domain.com/webhook/pve-temp
    else
        echo "API call would have been triggered: Temp-now=$TEMP, Temp-last=$LAST_TEMP, Fan-speed=$FAN_SPEED, Fan-pwm=$FAN_PWM"
    fi
}

# Fan speed control logic with updated thresholds
if [[ $TEMP -lt 40 ]]; then
    if [[ $LAST_TEMP -ge 40 ]]; then
        FAN_SPEED="4%"
        FAN_PWM=$(get_fan_pwm)
        echo "Setting fan speed to $FAN_SPEED (Temp < 40°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x04
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 40 && $TEMP -lt 45 ]]; then
    if [[ $LAST_TEMP -lt 40 || $LAST_TEMP -ge 45 ]]; then
        FAN_SPEED="8%"
        FAN_PWM=$(get_fan_pwm)
        echo "Setting fan speed to $FAN_SPEED (40°C <= Temp < 45°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x08
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 45 && $TEMP -lt 50 ]]; then
    if [[ $LAST_TEMP -lt 45 || $LAST_TEMP -ge 50 ]]; then
        FAN_SPEED="16%"
        FAN_PWM=$(get_fan_pwm)
        echo "Setting fan speed to $FAN_SPEED (45°C <= Temp < 50°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x10
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 50 && $TEMP -lt 55 ]]; then
    if [[ $LAST_TEMP -lt 50 || $LAST_TEMP -ge 55 ]]; then
        FAN_SPEED="32%"
        FAN_PWM=$(get_fan_pwm)
        echo "Setting fan speed to $FAN_SPEED (50°C <= Temp < 55°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x20
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 55 && $TEMP -lt 60 ]]; then
    if [[ $LAST_TEMP -lt 55 || $LAST_TEMP -ge 60 ]]; then
        FAN_SPEED="40%"
        FAN_PWM=$(get_fan_pwm)
        echo "Setting fan speed to $FAN_SPEED (55°C <= Temp < 60°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x28
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 60 && $TEMP -lt 70 ]]; then
    if [[ $LAST_TEMP -lt 60 || $LAST_TEMP -ge 70 ]]; then
        FAN_SPEED="64%"
        FAN_PWM=$(get_fan_pwm)
        echo "Setting fan speed to $FAN_SPEED (60°C <= Temp < 70°C)"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x02 0xff 0x40
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
elif [[ $TEMP -ge 70 ]]; then
    if [[ $LAST_TEMP -lt 70 ]]; then
        FAN_SPEED="Automatic"
        FAN_PWM=$(get_fan_pwm)
        echo "Temperature above 70°C, enabling automatic fan control"
        if [ "$TEST_MODE" = false ]; then
            ipmitool raw 0x30 0x30 0x01 0x01  # Enable automatic fan control
            log_to_file $TEMP $FAN_SPEED $FAN_PWM
        fi
        trigger_api_call
    fi
else
    echo "Temperature out of expected range."
fi

# Display the last 5 logged temperatures, fan speeds, and PWM values
echo "Last 5 temperatures, fan speeds, and PWM values logged:"
tail -n 5 $LOGFILE
