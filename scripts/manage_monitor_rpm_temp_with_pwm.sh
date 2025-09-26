#!/bin/bash
# manage_monitor_rpm_temp_with_pwm.sh
# Purpose: Monitor and/or manage server fans via IPMI, log metrics, and optionally send data to an n8n webhook.
# Notes:
# - Runs from any location: creates/uses a local subfolder "monitored-temp" next to this script for logs/config.
# - No dependency on 'bc' (all integer comparisons).
# - Dual-CPU safe: picks the highest CPU temperature detected.
# - Defensive: handles missing dependencies gracefully and logs warnings instead of crashing.

# ---------------------------
# Paths (relative to script)
# ---------------------------
# Resolve the absolute path of this script and derive directories.
SCRIPT_PATH="$(realpath "$0")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"
WORK_DIR="$BASE_DIR/monitored-temp"

# Files we keep inside the working subfolder
LOG_FILE="$WORK_DIR/combined-rpm-temp-log.txt"
CRON_LOG_FILE="$WORK_DIR/cron-log.txt"
CONFIG_FILE="$WORK_DIR/config.cfg"

# Ensure working directory and files exist
mkdir -p "$WORK_DIR"
touch "$LOG_FILE" "$CRON_LOG_FILE"
chmod 644 "$LOG_FILE" "$CRON_LOG_FILE"

# ---------------------------
# Defaults & runtime options
# ---------------------------
# Default behavior when no config is present.
DEFAULT_FAN_MODE="Automatic"
DEFAULT_TEMP_THRESHOLD=70     # Degrees Celsius
DEFAULT_OPERATION_MODE="Manage"
DEFAULT_PREFERRED_TEMP=55     # Degrees Celsius (target for "Manage" prompt)
API_CALL_ENABLED="yes"        # Session default (can be toggled interactively)

# ---------------------------
# Utilities & safe wrappers
# ---------------------------

# Append a line to the main log file
log_to_file() { echo "$1" >> "$LOG_FILE"; }

# Check that a command exists; warn if missing
req_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_to_file "WARN: missing dependency '$1'. Some features may not work."
    return 1
  fi
  return 0
}

# Run a command safely; suppress stderr and never crash the script
safe_run() { "$@" 2>/dev/null || true; }

# Return the maximum integer among args (empty => empty)
max_int() {
  local m="" x
  for x in "$@"; do
    [[ -z "$x" ]] && continue
    if [[ -z "$m" || $x -gt $m ]]; then m=$x; fi
  done
  echo "$m"
}

# ---------------------------
# Config load/save
# ---------------------------

# Persist the current runtime parameters to the config file
update_config() {
  echo "Updating configuration file..." >> "$CRON_LOG_FILE"
  {
    echo "FAN_MODE=$FAN_MODE"
    echo "TEMP_THRESHOLD=$TEMP_THRESHOLD"
    echo "OPERATION_MODE=$OPERATION_MODE"
    echo "PREFERRED_TEMP=$PREFERRED_TEMP"
    echo "API_CALL_ENABLED=$API_CALL_ENABLED"
  } > "$CONFIG_FILE"
  echo "Configuration file updated." >> "$CRON_LOG_FILE"
}

# Load config if present; otherwise use defaults
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
else
  FAN_MODE=$DEFAULT_FAN_MODE
  TEMP_THRESHOLD=$DEFAULT_TEMP_THRESHOLD
  OPERATION_MODE=$DEFAULT_OPERATION_MODE
  PREFERRED_TEMP=$DEFAULT_PREFERRED_TEMP
fi

# ---------------------------
# API/Webhook
# ---------------------------
# n8n endpoint (host changed as requested). Path preserved for compatibility.
API_URL="https://n8n.domain.com/webhook/pve-temp"

# Send a multipart POST with the current readings and state (if enabled)
trigger_api_call() {
  local HOSTNAME
  HOSTNAME=$(hostname)
  if [[ "$API_CALL_ENABLED" == "yes" ]]; then
    req_cmd curl >/dev/null || { log_to_file "API skipped: curl not available"; return; }
    curl -sS -H "Content-type: multipart/form-data" \
      -F title="Temp" \
      -F server="$HOSTNAME" \
      -F temp-now="${TEMP:-}" \
      -F temp-last="${LAST_TEMP:-}" \
      -F fan-speed="${FAN_SPEED:-}" \
      -F fan-mode="${FAN_MODE:-}" \
      -F power-instant="${INSTANT_POWER:-}" \
      -F log-entry="${LOG_MESSAGE:-}" \
      -X POST "$API_URL" >/dev/null || log_to_file "WARN: API call failed"
    log_to_file "API call sent: ${LOG_MESSAGE:-}"
  else
    log_to_file "API call is disabled for this session."
  fi
}

# ---------------------------
# Sensor collection (IPMI)
# ---------------------------

# Gather min/max fan RPM and their labels (if available)
get_rpm_info() {
  req_cmd ipmitool >/dev/null || { echo "0 NA 0 NA"; return; }
  local FAN_DATA MIN_RPM=100000 MAX_RPM=0 MIN_FAN="" MAX_FAN="" line FAN_NAME RPM
  FAN_DATA=$(safe_run ipmitool sdr type fan)
  while IFS= read -r line; do
    FAN_NAME=$(echo "$line" | grep -Po 'Fan[0-9A-Z]+')
    RPM=$(echo "$line" | grep -Po '\d{3,5}(?= RPM)')
    if [[ -n "$RPM" ]]; then
      (( RPM < MIN_RPM )) && { MIN_RPM=$RPM; MIN_FAN=$FAN_NAME; }
      (( RPM > MAX_RPM )) && { MAX_RPM=$RPM; MAX_FAN=$FAN_NAME; }
    fi
  done <<< "$FAN_DATA"

  # Fall back if nothing parsed
  [[ $MIN_RPM -eq 100000 ]] && MIN_RPM=0 && MIN_FAN="NA"
  [[ $MAX_RPM -eq 0 ]] && MAX_FAN="NA"

  log_to_file "RPM Data Collected: MIN_RPM=$MIN_RPM, MAX_RPM=$MAX_RPM"
  echo "$MIN_RPM $MIN_FAN $MAX_RPM $MAX_FAN"
}

# Grab Inlet Temp and CPU Temp; for multi-CPU, report the highest CPU temp
get_temp() {
  req_cmd ipmitool >/dev/null || { echo "0 0"; return; }
  local TDATA INLET_TEMP CPU_CANDIDATES CPU_TEMP

  TDATA=$(safe_run ipmitool sdr type temperature)

  INLET_TEMP=$(echo "$TDATA" | grep -F "Inlet Temp" | grep -Po '\d{1,3}(?= degrees)' | head -n1)
  [[ -z "$INLET_TEMP" ]] && INLET_TEMP=0

  # Collect likely CPU sensor lines and take the max (dual-CPU safe)
  CPU_CANDIDATES=$(echo "$TDATA" | grep -E 'CPU|^Temp\s+\|\s+[0-9a-fA-F]{2}h' | grep -Po '\d{1,3}(?= degrees)')
  if [[ -n "$CPU_CANDIDATES" ]]; then
    CPU_TEMP=$(max_int $CPU_CANDIDATES)
  else
    # Fallback: take the max of all degree numbers excluding inlet if possible
    CPU_TEMP=$(echo "$TDATA" | grep -Po '\d{1,3}(?= degrees)' | tail -n +2 | awk 'BEGIN{m=0}{if($1+0>m)m=$1}END{print m}')
    [[ -z "$CPU_TEMP" ]] && CPU_TEMP=0
  fi

  log_to_file "Temperature Data Collected: INLET_TEMP=$INLET_TEMP, CPU_TEMP=$CPU_TEMP"
  echo "$INLET_TEMP $CPU_TEMP"
}

# Instant power usage (Watts)
get_power_usage() {
  req_cmd ipmitool >/dev/null || { echo "0"; return; }
  local POWER_DATA INSTANT_POWER
  POWER_DATA=$(safe_run ipmitool dcmi power reading)
  INSTANT_POWER=$(echo "$POWER_DATA" | grep "Instantaneous power reading" | grep -Po '\d+(?= Watts)' | head -n1)
  [[ -z "$INSTANT_POWER" ]] && INSTANT_POWER=0
  log_to_file "Power Data Collected: INSTANT_POWER=$INSTANT_POWER"
  echo "$INSTANT_POWER"
}

# ---------------------------
# Fan control (IPMI RAW)
# ---------------------------

# Set BMC fan mode to manual and apply a PWM setpoint
set_fan_speed_manual() {
  local PWM=$1
  log_to_file "Setting fan control mode to Manual and speed to ${PWM}% PWM"
  FAN_SPEED="${PWM}%"
  req_cmd ipmitool >/dev/null || { log_to_file "ERROR: ipmitool not available"; return; }
  ipmitool raw 0x30 0x30 0x01 0x00
  case $PWM in
    4)  ipmitool raw 0x30 0x30 0x02 0xff 0x04 ;;
    8)  ipmitool raw 0x30 0x30 0x02 0xff 0x08 ;;
    16) ipmitool raw 0x30 0x30 0x02 0xff 0x10 ;;
    32) ipmitool raw 0x30 0x30 0x02 0xff 0x20 ;;
    40) ipmitool raw 0x30 0x30 0x02 0xff 0x28 ;;
    64) ipmitool raw 0x30 0x30 0x02 0xff 0x40 ;;
    96) ipmitool raw 0x30 0x30 0x02 0xff 0x60 ;;
    *)  log_to_file "Invalid PWM value: $PWM"; return 1 ;;
  esac
}

# Return BMC fan mode to automatic
reset_fan_to_auto() {
  log_to_file "Resetting fans to automatic mode"
  FAN_SPEED="Automatic"
  FAN_MODE="Automatic"
  req_cmd ipmitool >/dev/null || { log_to_file "ERROR: ipmitool not available"; return; }
  ipmitool raw 0x30 0x30 0x01 0x01
}

# Temperature-driven fan policy (simple step function)
manage_fan_speed() {
  local TEMP=$1
  log_to_file "Managing fan speed for temperature: $TEMP"
  FAN_MODE="Manual"
  if   (( TEMP < 40 )); then set_fan_speed_manual 4
  elif (( TEMP < 50 )); then set_fan_speed_manual 8
  elif (( TEMP < 60 )); then set_fan_speed_manual 16
  elif (( TEMP < 70 )); then set_fan_speed_manual 32
  elif (( TEMP < 75 )); then set_fan_speed_manual 40
  elif (( TEMP < 80 )); then set_fan_speed_manual 64
  else                        set_fan_speed_manual 96
  fi
}

# ---------------------------
# Monitoring sweep (7 PWM steps)
# ---------------------------

monitor_rpm_temp_power() {
  local MODE="Monitoring"
  FAN_MODE="Manual"
  log_to_file "Starting monitoring, cycling through fan speeds"

  local FAN_SPEEDS=(4 8 16 32 40 64 96) FAN_PWM TIMESTAMP
  local MIN_RPM MIN_FAN MAX_RPM MAX_FAN INLET_TEMP CPU_TEMP

  for FAN_PWM in "${FAN_SPEEDS[@]}"; do
    set_fan_speed_manual "$FAN_PWM"
    log_to_file "Set fan speed to $FAN_PWM% PWM, starting 2-minute monitoring interval"

    for ((j=0; j<8; j++)); do
      TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

      read -r MIN_RPM MIN_FAN MAX_RPM MAX_FAN <<< "$(get_rpm_info)"
      read -r INLET_TEMP CPU_TEMP <<< "$(get_temp)"
      INSTANT_POWER="$(get_power_usage)"

      FAN_SPEED="${FAN_PWM}%"
      LOG_MESSAGE="$TIMESTAMP | LO RPM: $MIN_RPM ($MIN_FAN) | HIGH RPM: $MAX_RPM ($MAX_FAN) | PWM $FAN_SPEED | INLET TEMP: ${INLET_TEMP}°C | CPU TEMP: ${CPU_TEMP}°C | POWER: Instant: ${INSTANT_POWER} W | $MODE | $FAN_MODE Mode"
      echo "$LOG_MESSAGE"
      log_to_file "$LOG_MESSAGE"

      sleep 15
    done
  done

  reset_fan_to_auto
  log_to_file "Monitoring complete. Fans reset to automatic mode."
}

# ---------------------------
# Cron convenience functions
# ---------------------------

# Comment out any crontab line matching this script path (backup first)
disable_cron_job() {
  log_to_file "Disabling cron job"
  crontab -l > "$WORK_DIR/crontab.bak" 2>/dev/null || true
  crontab -l 2>/dev/null | sed "\|$SCRIPT_PATH|s|^|#|" | crontab - || true
  log_to_file "Cron job disabled"
}

# Restore previous crontab if backup exists
enable_cron_job() {
  log_to_file "Enabling cron job"
  if [[ -f "$WORK_DIR/crontab.bak" ]]; then
    crontab "$WORK_DIR/crontab.bak"
    rm -f "$WORK_DIR/crontab.bak"
    log_to_file "Cron job enabled"
  else
    log_to_file "No backup crontab found. Cron job not enabled."
  fi
}

# ---------------------------
# Main
# ---------------------------

log_to_file "Script started at $(date)"

if [[ -t 1 ]]; then
  # Interactive mode: prompt user for action & options
  log_to_file "Interactive mode started"

  echo "Choose an operation:"
  echo "1. Monitor RPM and Temperature (7-step sweep)"
  echo "2. Manage Fan Speeds (temperature-based)"
  read -p "Enter your choice (1 or 2): " choice

  read -p "Enable API calls during this session? (y/n): " enable_api
  if [[ "$enable_api" == [yY] ]]; then API_CALL_ENABLED="yes"; else API_CALL_ENABLED="no"; fi

  if [[ "$choice" -eq 1 ]]; then
    FAN_MODE="Monitoring"
    OPERATION_MODE="Monitor"

    read -p "Disable the cron job during the monitoring session? (y/n): " disable_cron
    if [[ "$disable_cron" == [yY] ]]; then
      disable_cron_job; CRON_WAS_DISABLED="yes"
    else
      log_to_file "Cron job remains enabled during this session."
      CRON_WAS_DISABLED="no"
    fi

    monitor_rpm_temp_power
    update_config

    if [[ "$CRON_WAS_DISABLED" == "yes" ]]; then enable_cron_job; fi

  elif [[ "$choice" -eq 2 ]]; then
    MODE="Management"
    OPERATION_MODE="Manage"
    FAN_MODE=""

    read -p "Use manual fan control (M) or automatic (A)? " fan_mode
    if [[ "$fan_mode" == [mM] ]]; then
      FAN_MODE="Manual"
      read -p "Enter the preferred CPU temperature to manage: " PREFERRED_TEMP
      PREFERRED_TEMP=$(( PREFERRED_TEMP + 0 ))  # coerce to integer
      manage_fan_speed "$PREFERRED_TEMP"

      read -p "Set a temperature threshold for API trigger (default ${TEMP_THRESHOLD}°C): " TEMP_THRESHOLD_INPUT
      [[ -n "$TEMP_THRESHOLD_INPUT" ]] && TEMP_THRESHOLD=$(( TEMP_THRESHOLD_INPUT + 0 ))

      # No 'bc': integer compare
      if (( PREFERRED_TEMP > TEMP_THRESHOLD )); then
        LAST_TEMP=${TEMP:-}
        read -r INLET_TEMP TEMP <<< "$(get_temp)"
        INSTANT_POWER="$(get_power_usage)"
        LOG_MESSAGE="Threshold exceeded during management session."
        trigger_api_call
      fi
    else
      FAN_MODE="Automatic"
      reset_fan_to_auto
      LAST_TEMP=${TEMP:-}
      read -r INLET_TEMP TEMP <<< "$(get_temp)"
      INSTANT_POWER="$(get_power_usage)"
      LOG_MESSAGE="Fan mode set to automatic during management session."
      trigger_api_call
    fi

    update_config
    # Optional tail -f of the log
    read -p "Tail the log file now (combined-rpm-temp-log.txt)? (y/n): " monitor_log
    if [[ "$monitor_log" == [yY] ]]; then
      tail -f "$LOG_FILE"
    else
      log_to_file "Exiting without monitoring the log."
    fi

  else
    echo "Invalid choice."
    exit 1
  fi

else
  # Cron mode: non-interactive run controlled by the config file
  log_to_file "Running script via cron at $(date)"
  API_CALL_ENABLED="yes"  # in cron we default to sending alerts (if thresholds trip)

  read -r INLET_TEMP TEMP <<< "$(get_temp)"
  INSTANT_POWER="$(get_power_usage)"
  LAST_TEMP=$TEMP

  if [[ "$OPERATION_MODE" == "Manage" ]]; then
    if [[ "$FAN_MODE" == "Manual" ]]; then
      manage_fan_speed "$TEMP"
    else
      reset_fan_to_auto
    fi
    # Thresholded alert (no 'bc')
    if (( TEMP > TEMP_THRESHOLD )); then
      LOG_MESSAGE="Temperature threshold exceeded in cron mode."
      trigger_api_call
    fi
  else
    log_to_file "Monitoring mode is disabled when running via cron."
  fi

  log_to_file "Cron job completed at $(date)"
fi
