#!/bin/bash

# Script Path
SCRIPT_PATH="/var/scripts/manage_monitor_rpm_temp_with_pwm.sh"

# Get the directory where the script is located
SCRIPT_DIR="/var/scripts"
LOG_FILE="$SCRIPT_DIR/combined-rpm-temp-log.txt"
CRON_LOG_FILE="$SCRIPT_DIR/cron-log.txt"
CONFIG_FILE="$SCRIPT_DIR/config.cfg"

# Ensure the script directory exists and is writable
mkdir -p "$SCRIPT_DIR"
touch "$LOG_FILE" "$CRON_LOG_FILE"
chmod 644 "$LOG_FILE" "$CRON_LOG_FILE"

# Default values if no config file is found
DEFAULT_FAN_MODE="Automatic"
DEFAULT_TEMP_THRESHOLD=70
DEFAULT_OPERATION_MODE="Manage"
DEFAULT_PREFERRED_TEMP=55  # Default preferred temp

# Initialize API_CALL_ENABLED to "yes" by default
API_CALL_ENABLED="yes"

# Function to update the config file with new values
update_config() {
    echo "Updating configuration file..." >> "$CRON_LOG_FILE"
    echo "FAN_MODE=$FAN_MODE" > "$CONFIG_FILE"
    echo "TEMP_THRESHOLD=$TEMP_THRESHOLD" >> "$CONFIG_FILE"
    echo "OPERATION_MODE=$OPERATION_MODE" >> "$CONFIG_FILE"
    echo "PREFERRED_TEMP=$PREFERRED_TEMP" >> "$CONFIG_FILE"
    echo "API_CALL_ENABLED=$API_CALL_ENABLED" >> "$CONFIG_FILE"
    echo "Configuration file updated." >> "$CRON_LOG_FILE"
}

# Load the configuration file if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    FAN_MODE=$DEFAULT_FAN_MODE
    TEMP_THRESHOLD=$DEFAULT_TEMP_THRESHOLD
    OPERATION_MODE=$DEFAULT_OPERATION_MODE
    PREFERRED_TEMP=$DEFAULT_PREFERRED_TEMP
fi

# API endpoint
API_URL="https://automate.domain.com/webhook/pve-temp"

# Function to log output to file
log_to_file() {
    echo "$1" >> "$LOG_FILE"
}

# Debugging: check if logging works
log_to_file "Script started at $(date)"

# Function to trigger the API call
trigger_api_call() {
    HOSTNAME=$(hostname)
    if [ "$API_CALL_ENABLED" = "yes" ]; then
        curl -H "Content-type: multipart/form-data" \
            -F title="Temp" \
            -F server="$HOSTNAME" \
            -F temp-now="$TEMP" \
            -F temp-last="$LAST_TEMP" \
            -F fan-speed="$FAN_SPEED" \
            -F fan-mode="$FAN_MODE" \
            -F power-instant="$INSTANT_POWER" \
            -F log-entry="$LOG_MESSAGE" \
            -X POST $API_URL
        log_to_file "API call sent: $LOG_MESSAGE"
    else
        log_to_file "API call is disabled for this session."
    fi
}

# Function to get fan RPM along with fan numbers and find the lowest and highest RPM
get_rpm_info() {
    FAN_DATA=$(ipmitool sdr type fan)
    MIN_RPM=100000
    MAX_RPM=0
    MIN_FAN=""
    MAX_FAN=""

    while IFS= read -r line; do
        FAN_NAME=$(echo "$line" | grep -Po 'Fan[0-9A-Z]+')
        RPM=$(echo "$line" | grep -Po '\d{3,5}(?= RPM)')
        if [[ -n "$RPM" ]]; then
            if [[ $RPM -lt $MIN_RPM ]]; then
                MIN_RPM=$RPM
                MIN_FAN=$FAN_NAME
            fi
            if [[ $RPM -gt $MAX_RPM ]]; then
                MAX_RPM=$RPM
                MAX_FAN=$FAN_NAME
            fi
        fi
    done <<< "$FAN_DATA"

    log_to_file "RPM Data Collected: MIN_RPM=$MIN_RPM, MAX_RPM=$MAX_RPM"
    echo "$MIN_RPM $MIN_FAN $MAX_RPM $MAX_FAN"
}

# Function to get Inlet and CPU Temperature
get_temp() {
    INLET_TEMP=$(ipmitool sdr type temperature | grep "Inlet Temp" | grep -Po '\d{1,3}(?= degrees)')
    CPU_TEMP=$(ipmitool sdr type temperature | grep -P '^Temp\s+\|\s+[0-9a-fA-F]{2}h' | grep -Po '\d{1,3}(?= degrees)')
    log_to_file "Temperature Data Collected: INLET_TEMP=$INLET_TEMP, CPU_TEMP=$CPU_TEMP"
    echo "$INLET_TEMP $CPU_TEMP"
}

# Function to get power usage (Instant Watt)
get_power_usage() {
    POWER_DATA=$(ipmitool dcmi power reading)
    INSTANT_POWER=$(echo "$POWER_DATA" | grep "Instantaneous power reading" | grep -Po '\d+(?= Watts)')
    log_to_file "Power Data Collected: INSTANT_POWER=$INSTANT_POWER"
    echo "$INSTANT_POWER"
}

# Function to set fan speed to manual mode
set_fan_speed_manual() {
    PWM=$1
    log_to_file "Setting fan control mode to Manual and speed to $PWM% PWM"
    FAN_SPEED="$PWM%"
    # Set fan control mode to manual
    ipmitool raw 0x30 0x30 0x01 0x00
    # Set fan speed
    case $PWM in
        4)  ipmitool raw 0x30 0x30 0x02 0xff 0x04 ;;
        8)  ipmitool raw 0x30 0x30 0x02 0xff 0x08 ;;
        16) ipmitool raw 0x30 0x30 0x02 0xff 0x10 ;;
        32) ipmitool raw 0x30 0x30 0x02 0xff 0x20 ;;
        40) ipmitool raw 0x30 0x30 0x02 0xff 0x28 ;;
        64) ipmitool raw 0x30 0x30 0x02 0xff 0x40 ;;
        96) ipmitool raw 0x30 0x30 0x02 0xff 0x60 ;;
        *)  log_to_file "Invalid PWM value: $PWM" && exit 1 ;;
    esac
}

# Function to reset fans to automatic mode
reset_fan_to_auto() {
    log_to_file "Resetting fans to automatic mode"
    FAN_SPEED="Automatic"
    FAN_MODE="Automatic"
    ipmitool raw 0x30 0x30 0x01 0x01
}

# Fan management logic based on temperature analysis
manage_fan_speed() {
    TEMP=$1
    log_to_file "Managing fan speed for temperature: $TEMP"
    FAN_MODE="Manual"
    if [[ $TEMP -lt 40 ]]; then
        set_fan_speed_manual 4
    elif [[ $TEMP -ge 40 && $TEMP -lt 45 ]]; then
        set_fan_speed_manual 8
    elif [[ $TEMP -ge 45 && $TEMP -lt 50 ]]; then
        set_fan_speed_manual 16
    elif [[ $TEMP -ge 50 && $TEMP -lt 55 ]]; then
        set_fan_speed_manual 32
    elif [[ $TEMP -ge 55 && $TEMP -lt 60 ]]; then
        set_fan_speed_manual 40
    elif [[ $TEMP -ge 60 && $TEMP -lt 70 ]]; then
        set_fan_speed_manual 64
    else
        set_fan_speed_manual 96
    fi
}

# Function to monitor RPM, temperature, and power for 3 minutes, writing every 30 seconds
monitor_rpm_temp_power() {
    MODE="Monitoring"
    log_to_file "Monitoring for 3 minutes"
    for ((i=0; i<6; i++)); do
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        read -r MIN_RPM MIN_FAN MAX_RPM MAX_FAN <<< $(get_rpm_info)
        read -r INLET_TEMP CPU_TEMP <<< $(get_temp)
        INSTANT_POWER=$(get_power_usage)

        LOG_MESSAGE="$TIMESTAMP | LO RPM: $MIN_RPM ($MIN_FAN) | HIGH RPM: $MAX_RPM ($MAX_FAN) | PWM $FAN_SPEED | INLET TEMP: $INLET_TEMP°C | CPU TEMP: $CPU_TEMP°C | POWER: Instant: $INSTANT_POWER W | $MODE | $FAN_MODE Mode"
        echo "$LOG_MESSAGE"
        log_to_file "$LOG_MESSAGE"

        sleep 30
    done
}

# Ask user if they want to monitor the log file
monitor_log_file() {
    read -p "Do you want to monitor the log file (combined-rpm-temp-log.txt)? (y/n): " monitor_log
    if [[ "$monitor_log" == "y" || "$monitor_log" == "Y" ]]; then
        tail -f "$LOG_FILE"
    else
        log_to_file "Exiting without monitoring the log."
    fi
}

# Function to disable the cron job
disable_cron_job() {
    log_to_file "Disabling cron job"
    # Backup current crontab
    crontab -l > "$SCRIPT_DIR/crontab.bak"
    # Disable the cron job by commenting it out
    crontab -l | sed "\|$SCRIPT_PATH|s|^|#|" | crontab -
    log_to_file "Cron job disabled"
}

# Function to enable the cron job
enable_cron_job() {
    log_to_file "Enabling cron job"
    # Restore crontab from backup
    if [[ -f "$SCRIPT_DIR/crontab.bak" ]]; then
        crontab "$SCRIPT_DIR/crontab.bak"
        rm "$SCRIPT_DIR/crontab.bak"
        log_to_file "Cron job enabled"
    else
        log_to_file "No backup crontab found. Cron job not enabled."
    fi
}

# Main logic to choose between monitoring or managing fans
if [[ -t 1 ]]; then
    # If running in interactive mode (user present)
    log_to_file "Interactive mode started"

    echo "Choose an operation:"
    echo "1. Monitor RPM and Temperature"
    echo "2. Manage Fan Speeds"
    read -p "Enter your choice (1 or 2): " choice

    # Ask the user if they want to enable API calls during this session
    read -p "Do you want to enable API calls during this session? (y/n): " enable_api
    if [[ "$enable_api" == "y" || "$enable_api" == "Y" ]]; then
        API_CALL_ENABLED="yes"
    else
        API_CALL_ENABLED="no"
    fi

    if [ "$choice" -eq 1 ]; then
        FAN_MODE="Monitoring"
        OPERATION_MODE="Monitor"

        # Ask if the user wants to disable the cron job
        read -p "Do you want to disable the cron job during the monitoring session? (y/n): " disable_cron
        if [[ "$disable_cron" == "y" || "$disable_cron" == "Y" ]]; then
            disable_cron_job
            CRON_WAS_DISABLED="yes"
        else
            log_to_file "Cron job remains enabled during this session."
            CRON_WAS_DISABLED="no"
        fi

        monitor_rpm_temp_power
        update_config  # Save config changes
        monitor_log_file  # Ask user if they want to monitor the log

        # Re-enable the cron job if it was disabled
        if [[ "$CRON_WAS_DISABLED" == "yes" ]]; then
            enable_cron_job
        fi

    elif [ "$choice" -eq 2 ]; then
        MODE="Management"
        OPERATION_MODE="Manage"
        FAN_MODE=""

        read -p "Do you want to use manual fan control (M) or automatic (A)? " fan_mode
        if [[ "$fan_mode" == "M" || "$fan_mode" == "m" ]]; then
            FAN_MODE="Manual"
            read -p "Enter the preferred CPU temperature to manage: " PREFERRED_TEMP
            manage_fan_speed $PREFERRED_TEMP
            read -p "Set a temperature threshold for API trigger (default 70°C): " TEMP_THRESHOLD_INPUT
            TEMP_THRESHOLD=${TEMP_THRESHOLD_INPUT:-$TEMP_THRESHOLD}
            if (( $(echo "$PREFERRED_TEMP > $TEMP_THRESHOLD" | bc -l) )); then
                # Initialize variables used in trigger_api_call
                LAST_TEMP=$TEMP
                read -r INLET_TEMP TEMP <<< $(get_temp)
                INSTANT_POWER=$(get_power_usage)
                LOG_MESSAGE="Threshold exceeded during management session."
                trigger_api_call
            fi
        else
            FAN_MODE="Automatic"
            reset_fan_to_auto
            # Initialize variables used in trigger_api_call
            LAST_TEMP=$TEMP
            read -r INLET_TEMP TEMP <<< $(get_temp)
            INSTANT_POWER=$(get_power_usage)
            LOG_MESSAGE="Fan mode set to automatic during management session."
            trigger_api_call
        fi
        update_config  # Save config changes
        monitor_log_file  # Ask user if they want to monitor the log
    else
        echo "Invalid choice."
        exit 1
    fi

else
    # If running in cron mode (no user input)
    log_to_file "Running script via cron at $(date)"

    # Ensure API calls are enabled in cron mode
    API_CALL_ENABLED="yes"

    # Only perform fan management tasks in cron mode
    read -r INLET_TEMP TEMP <<< $(get_temp) # Assume $CPU_TEMP is the second value in get_temp
    INSTANT_POWER=$(get_power_usage)
    LAST_TEMP=$TEMP  # You may need to store and retrieve LAST_TEMP from a file if required

    if [ "$OPERATION_MODE" = "Manage" ]; then
        if [ "$FAN_MODE" = "Manual" ]; then
            manage_fan_speed $TEMP  # Manage fans according to config settings
        else
            reset_fan_to_auto  # Use automatic fan mode if set in config
        fi
        if (( $(echo "$TEMP > $TEMP_THRESHOLD" | bc -l) )); then
            LOG_MESSAGE="Temperature threshold exceeded in cron mode."
            trigger_api_call
        fi
    else
        log_to_file "Monitoring mode is disabled when running via cron."
    fi
    log_to_file "Cron job completed at $(date)"
fi
