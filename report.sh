#!/bin/bash

: '
This script creates log reports using "goaccess" from a remote server.
The reports can be for today, yesterday or 7 past days based on argument for this script execution.
The report file is modified so it displays 3 links to according reports. You can serve the report .html files as you want.
'
check_config_variables() {
    local missing_variables=()
    local required_vars=("JOB_THREADS" "REMOTE_USER" "REMOTE_HOST" "REMOTE_LOG_DIRECTORY" "GOACCESS_HOME" "REPORT_DIRECTORY" "SCRIPT_LOG_FILE" "GOACCESS_CONFIG" "DATABASE_PATH")
    local optional_vars=("FILTERED_IP" "GEO_DB_ASN" "GEO_DB_CITY")  # These variables are optional

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then  # Indirect variable reference
            missing_variables+=("$var")
        fi
    done

    for var in "${optional_vars[@]}"; do
        if ! declare -p "$var" &> /dev/null; then  # Check if variable is declared
            missing_variables+=("$var (optional, but not declared)")
        fi
    done

    if [ ${#missing_variables[@]} -ne 0 ]; then
        echo "The following required configuration variables are not set:"
        printf ' - %s\n' "${missing_variables[@]}"
        exit 1
    fi

}

# Load the configuration file
CONFIG_FILE="report-config.cfg"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=report-config.cfg
    source "$CONFIG_FILE"
    check_config_variables
else
    echo "Configuration file '$CONFIG_FILE' not found."
    exit 1
fi

# System commands
awk=$(command -v awk)
echo=$(command -v echo)
touch=$(command -v touch)
mkdir=$(command -v mkdir)
rm=$(command -v rm)
ssh=$(command -v ssh)
sed=$(command -v sed)
goaccess=$(command -v goaccess)
zcat=$(command -v zcat)
grep=$(command -v grep)
test=$(command -v test)

# Check system utilities
if [ -z "$(command -v goaccess)" ]; then
    ${echo} "\"goaccess\" not installed on the system. Install it or check your \$PATH"
    exit 1
fi

# Help message function
display_help() {
    cat <<- EOF
    Usage: $0 [option]

    This script creates log reports using "goaccess" from a remote server.
    The reports can be for today, yesterday, or the past week.
    The report file is modified to display navigation links to corresponding reports.

    Options:
    ${argument_today}         Generate the report for today's log.
    ${argument_yesterday}     Generate the report for yesterday's log.
    ${argument_week}          Generate the report for the past week's logs.
    help          Display this help message and exit.

    Example:
    $0 ${argument_today}      # Generate today's log report.
EOF
}

handle_argument() {
    local argument=$1
    LOG_FILENAME="${CURRENT_LOG_FILENAME}"
    LOG_2_FILENAME="${PAST1_LOG_FILENAME}"
    CURR_REPORT_SUFFIX="${SUFFIX_TODAY}"
    REPORT_TITLE="${TODAY_LINK_NAME}"
    LOCK_FILE="${GOACCESS_HOME}/${argument}${LOCK_FILE_BASENAME}"
    PERSIST_RESTORE="no"
    case $argument in
        "${argument_today}")
            TODAY_LINK="<a href=\"${TODAY_LINK_ADDRESS}\" ${ACTIVE_LINK_STYLE}>${TODAY_LINK_NAME}</a>"
            ;;
        "${argument_yesterday}")
            LOG_FILENAME="${PAST1_LOG_FILENAME}"
            LOG_2_FILENAME="${PAST2_LOG_FILENAME}"
            CURR_REPORT_SUFFIX="${SUFFIX_YESTERDAY}"
            REPORT_TITLE="${YESTERDAY_LINK_NAME}"
            YESTERDAY_LINK="<a href=\"${YESTERDAY_LINK_ADDRESS}\" ${ACTIVE_LINK_STYLE}>${YESTERDAY_LINK_NAME}</a>"
            ;;
        "${argument_week}")
            LOG_FILENAME="${PAST1_LOG_FILENAME}"
            LOG_2_FILENAME="${PAST2_LOG_FILENAME}"
            CURR_REPORT_SUFFIX="${SUFFIX_WEEK}"
            REPORT_TITLE="${WEEK_LINK_NAME}"
            PERSIST_RESTORE="yes"
            WEEK_LINK="<a href=\"${WEEK_LINK_ADDRESS}\" ${ACTIVE_LINK_STYLE}>${WEEK_LINK_NAME}</a>"
            ;;
    esac
}

# Check for required argument
if [ $# -eq 0 ]; then
    echo "No argument provided."
    display_help
    exit 1
fi

# Parameterize differences based on argument
case $1 in
    "${argument_today}"|"${argument_yesterday}"|"${argument_week}")
        handle_argument "$1"
        ;;
    "help")
        display_help
        exit 0
        ;;
    *)
        echo "Invalid argument."
        display_help
        exit 1
        ;;
esac

# Functions to log messages
log_message() {
    ${echo} "$(date '+%Y-%m-%d %H:%M:%S') - INFO: \"${REPORT_TITLE}\" report: $1" >> "${SCRIPT_LOG_FILE}" || ${echo} "Write message logs to ${SCRIPT_LOG_FILE} failed."
}

log_error() {
    local custom_msg=$1
    shift  # Remove the first argument and shift the rest to the left
    local error_msg
    error_msg=$("$@" 2>&1)

    ${echo} "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: \"${REPORT_TITLE}\" report: $custom_msg - $error_msg" >> "${SCRIPT_LOG_FILE}" || ${echo} "Write error log to the ${SCRIPT_LOG_FILE} failed."
}

# Function to clean up resources and exit
cleanup() {
    local exit_code=$?

    ${rm} -f "${LOCK_FILE}" || log_error "Failed to remove ${LOCK_FILE}."
    exit $exit_code
}

delete_tmp_gz() {
    for gz_file in "${downloaded_files[@]}"; do
        ${rm} "${gz_file}" || log_error "Failed to delete ${gz_file}"
    done
}

# Function to check and create directory or file if not exists
check_and_create() {
    local path=$1
    local type=$2
    if [ "$type" = "dir" ]; then
        if [ ! -d "$path" ]; then
            ${mkdir} -p "$path" || { log_error "Failed to create directory $path"; exit 1; }
            ${echo} "Directory created: $path"
        fi
    elif [ "$type" = "file" ]; then
        if [ ! -f "$path" ]; then
            ${touch} "$path" || { log_error "Failed to create file $path"; exit 1; }
            ${echo} "File created: ${path}"
        fi
    else
        log_error "Invalid type specified in check_and_create function"
        cleanup
    fi
}

check_and_create "${GOACCESS_HOME}" "dir"
# Check for lock file to ensure only one instance runs at a time
if [ -f "${LOCK_FILE}" ]; then
    ${echo} "Another instance is running."
    exit 1
fi

# Create lock file
${touch} "${LOCK_FILE}" || { log_error "Failed to create ${LOCK_FILE}. The lock mechanism for this script may be broken. Exiting."; exit 1; }

# Function for downloading multiple log files
: << COMMENT
- chek for \$LOGS_FILENAME presence on remote server;
- create .gz archive of this log file. We can save about 90% of space using gzipping on log files usually
- download this file locally to \$GOACCESS_HOME
- remove this .gz file on remote server
COMMENT

downloaded_files=()
download_logfiles() {
    local log_files=("$@")
    for log_file in "${log_files[@]}"; do
        local remote_file_path="${REMOTE_LOG_DIRECTORY}/${log_file}"

        if [[ "${log_file}" == *".gz" ]]; then
            local local_file_path="${GOACCESS_HOME}/${log_file}"
            # Use 'cat' for already gzipped files to transfer binary data
            ${ssh} -n "${REMOTE_USER}@${REMOTE_HOST}" "cat ${remote_file_path}" > "${local_file_path}" || { log_error "Failed to download gzipped log file ${log_file}."; cleanup; }
        else
            local gz_file="${log_file}.gz"
            local local_file_path="${GOACCESS_HOME}/${gz_file}"
            # Compress and download for non-gzipped files
            ${ssh} -n "${REMOTE_USER}@${REMOTE_HOST}" "gzip -c ${remote_file_path}" > "${local_file_path}" || { log_error "Failed to compress and download log file ${log_file}."; cleanup; }
        fi

        # Append the local file path to the array
        downloaded_files+=("${local_file_path}")

        log_message "Log file ${log_file} copied to local machine."
    done
    log_message "All specified log files processed."
}

# Validate filtered addresses variable
validate_ip() {
    local ips=("$@")
    local valid_ip_regex
    valid_ip_regex="^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"

    # Check if ips array is empty
    if [ -z "${ips[*]}" ]; then
       # If the array is empty, there's nothing to validate
       return 0
    fi

    for ip in "${ips[@]}"; do
        if [[ ! $ip =~ $valid_ip_regex ]]; then
            log_error "Invalid IP address: $ip"
            cleanup
        fi
    done
    return 0
}

# Function to extract and validate the date from the log file
extract_and_validate_date() {
    local gz_file=$1
    local -a dates
    local valid_date_regex='^(0[1-9]|[12][0-9]|3[01])\/(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\/[0-9]{4}'
    local date


    # Extract dates from multiple lines for validation
    for i in {2..5}; do
        date="$(${zcat} "$gz_file" | ${awk} -v line_num="${i}" 'NR==line_num{print $4}' | ${sed} 's/\[//g;s/:.*//g')"
        if [[ $date =~ $valid_date_regex ]]; then
            dates+=("${date//[[]/}")
        else
            log_error "Invalid date format found: $date"
            return 1
        fi
    done

    # Compare the extracted dates
    for ((i = 0; i < ${#dates[@]} - 1; i++)); do
        if [[ "${dates[$i]}" != "${dates[$i + 1]}" ]]; then
            log_error "Mismatched dates found: ${dates[$i]} and ${dates[$i + 1]}"
            return 1
        fi
    done

    # If all checks pass, return the validated date without brackets
    echo "${dates[0]}"
    return 0
}

# Function to generate reports
: << COMMENT
- check if the archived log file is present
- generate report with "goaccess" utility
- insert navigation links for TODAY, YESTERDAY and WEEK report
COMMENT

generate_report() {
    local local_report_file="${REPORT_DIRECTORY}/${CURR_REPORT_SUFFIX}${REPORT_BASENAME}"
    local nav_links_html="<div style=\"text-align: center; margin-top: 20px;\">${TODAY_LINK}${YESTERDAY_LINK}${WEEK_LINK}</div>"
    local gz_log_files=("${downloaded_files[@]}")
    local zcat_command="${zcat}"
    local func_argument=""
    local exclude_command=""

    # Check if an argument for persist and restore was provided
    case "${PERSIST_RESTORE}" in
        "yes")
            func_argument="--persist --restore"
            ;;
        "no")
            func_argument=""
            ;;
        *)
            log_message "Specify \"PERSIST_RESTORE\" as \"yes\" or \"no\". Now assuming it is \"no\"."
            func_argument=""
            ;;
    esac

    # Check if $FILTERED_IP is specified
    case "${FILTERED_IP[@]}" in
        "")
           exclude_command=""
            ;;
        *)
            for ip in "${FILTERED_IP[@]}"; do
                exclude_command+="-e $ip "
            done
            ;;
    esac

    local goaccess_command_args="- -j ${JOB_THREADS} -a --keep-last=${DAYS_TO_KEEP} --config-file=${GOACCESS_CONFIG} -o ${local_report_file} --db-path ${DATABASE_PATH} ${func_argument} ${exclude_command}"

    # Append GeoIP database arguments if the files are specified and exist
    if [ -n "${GEO_DB_ASN}" ] && [ -f "${GEO_DB_ASN}" ]; then
        goaccess_command_args+=" --geoip-database=${GEO_DB_ASN}"
    fi

    if [ -n "${GEO_DB_CITY}" ] && [ -f "${GEO_DB_CITY}" ]; then
        goaccess_command_args+=" --geoip-database=${GEO_DB_CITY}"
    fi

    if [ -n "${gz_log_files[0]}" ]; then
        local first_downloaded_file="${gz_log_files[0]}"
        local validated_report_date
        validated_report_date=$(extract_and_validate_date "${first_downloaded_file}") || log_error "Date validation failed for ${first_downloaded_file}"
    else
        log_error "No downloaded files available. Cannot proceed with date validation."
    fi

    # Construct the zcat command with all downloaded files
    for gz_file in "${gz_log_files[@]}"; do
        if ${test} -f "${gz_file}"; then
            zcat_command+=" \"${gz_file}\""
        else
            log_error "File ${gz_file} does not exist. Skipping for zcat command."
        fi
    done

    # Generate Goaccess report based on first log file
    if [[ -z "$validated_report_date" ]]; then
        log_error "Could not validate date. Proceeding without date filtering."
    else
        # Proceed with date filtering
        log_message "Validated date: $validated_report_date. Proceeding with date filtering."
        zcat_command+=" | ${grep} \"$validated_report_date\""
    fi

    if ! eval "${zcat_command}" | ${goaccess} ${goaccess_command_args}; then
        log_error "Failed to generate report with goaccess."
        delete_tmp_gz
        cleanup
    fi

    log_message "Successfully generated report."

    # Add navigation links to top
    ${sed} -i "0,/<body>/s|<body>|<body>\n${nav_links_html}\n|" "${local_report_file}" || log_message "Warning! Failed to add navigation links to the top."

    # Add navigation links to bottom
    ${echo} -e "${nav_links_html}\n" >> "${local_report_file}" || log_message "Warning! Failed to add navigation links to the bottom."

    log_message "Links added."

    # Clean up temporary file
    delete_tmp_gz

    log_message "Report finished to ${local_report_file}."
}

# Function to clean up old log entries in a single file
cleanup_old_log_entries() {
    local log_file="$1"
    local days_old="$2"
    #local current_epoch
    #current_epoch=$(date +%s)
    local cutoff_epoch
    cutoff_epoch=$(date -d "$days_old days ago" +%s)
    local tmp_file
    tmp_file=$(mktemp)

    # Process the log file, keeping entries that are newer than the cutoff date
    # Convert log timestamp to epoch time
    # Print the line if it's newer than the cutoff
    awk -v cutoff="$cutoff_epoch" '{
        split($1" "$2, arr, /[-: ]/)
        log_time=mktime(arr[1]" "arr[2]" "arr[3]" "arr[4]" "arr[5]" "arr[6])
        if (log_time >= cutoff) {
            print $0
        }
    }' "$log_file" > "$tmp_file"

    # Replace the old log file with the cleaned version
    mv "$tmp_file" "$log_file"
}

# --------------------------------ENTRY POINT----------------------------------------

# Trap SIGINT and SIGTERM
trap cleanup SIGINT SIGTERM
validate_ip "${FILTERED_IP[@]}"
check_and_create "${DATABASE_PATH}" "dir"
check_and_create "${GOACCESS_HOME}/logs" "dir"
check_and_create "${REPORT_DIRECTORY}" "dir"
check_and_create "${GOACCESS_CONFIG}" "file"

download_logfiles "${LOG_FILENAME}" "${LOG_2_FILENAME}"
generate_report
# Leave last 8 days in log file
cleanup_old_log_entries "${SCRIPT_LOG_FILE}" 8

log_message "Script finished."

# Remove lock file
${rm} -f "${LOCK_FILE}" || { log_message "Failed to remove ${LOCK_FILE}. The lock mechanism for this script may be broken"; exit 1; }

# End of script
