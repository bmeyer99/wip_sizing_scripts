#!/bin/bash

# Test script for pcs_gcp_sizing.sh
# Tests various scenarios and validates output

# Enhanced performance monitoring
function start_monitoring() {
    echo "Starting performance monitoring..."
    start_time=$(date +%s%N)
    start_memory=$(ps -o rss= -p $$)
    start_cpu=$(ps -o %cpu= -p $$)
    api_calls=0
    error_count=0
    request_times=()
}

function log_request_time() {
    request_times+=($1)
}

function calculate_percentiles() {
    local sorted=($(printf "%s\n" "${request_times[@]}" | sort -n))
    local count=${#sorted[@]}
    
    if [ $count -eq 0 ]; then
        echo "No request times recorded"
        return
    }
    
    local p50_idx=$(( count * 50 / 100 ))
    local p90_idx=$(( count * 90 / 100 ))
    local p99_idx=$(( count * 99 / 100 ))
    
    echo "Response Time Distribution:"
    echo "- P50: ${sorted[$p50_idx]}ms"
    echo "- P90: ${sorted[$p90_idx]}ms"
    echo "- P99: ${sorted[$p99_idx]}ms"
}

function stop_monitoring() {
    local end_time=$(date +%s%N)
    local end_memory=$(ps -o rss= -p $$)
    local end_cpu=$(ps -o %cpu= -p $$)
    local duration=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
    local memory_used=$((end_memory - start_memory))
    local cpu_used=$(echo "$end_cpu - $start_cpu" | bc)
    local error_rate=$(echo "scale=2; $error_count / $api_calls * 100" | bc)
    
    echo "Performance Metrics:"
    echo "==================="
    echo "Execution Time: ${duration}ms"
    echo "Memory Usage: ${memory_used}KB"
    echo "API Calls: ${api_calls}"
    echo "CPU Usage: ${cpu_used}%"
    echo "Error Rate: ${error_rate}%"
    calculate_percentiles
    echo ""
}

# Enhanced error tracking
function log_error() {
    error_count=$((error_count + 1))
    echo "❌ Error: $1" >&2
}

# Enhanced API call tracking with timing
function gcloud() {
    local start_call=$(date +%s%N)
    api_calls=$((api_calls + 1))
    command gcloud "$@"
    local status=$?
    local end_call=$(date +%s%N)
    local call_duration=$(( (end_call - start_call) / 1000000 ))
    
    log_request_time $call_duration
    
    if [ $status -ne 0 ]; then
        log_error "API call failed: gcloud $@"
    fi
    
    return $status
}

function print_header() {
    echo "================================================"
    echo "🧪 $1"
    echo "================================================"
}

function validate_output() {
    local output=$1
    local expected_pattern=$2
    local test_name=$3
    
    if echo "$output" | grep -q "$expected_pattern"; then
        echo "✅ $test_name: PASSED"
    else
        echo "❌ $test_name: FAILED"
        echo "Expected pattern not found: $expected_pattern"
        echo "Output was:"
        echo "$output"
    fi
}

# Make sizing script executable
chmod +x ./pcs_gcp_sizing.sh

# Test 1: Basic Execution
print_header "Test 1: Basic Execution"
start_monitoring
output=$(./pcs_gcp_sizing.sh 123456789012)
stop_monitoring
validate_output "$output" "Prisma Cloud GCP inventory collection complete" "Basic execution"
validate_output "$output" "Compute Resources:" "Resource section present"

# Test 2: DSPM Mode
print_header "Test 2: DSPM Mode"
start_monitoring
output=$(./pcs_gcp_sizing.sh -d 123456789012)
stop_monitoring
validate_output "$output" "DSPM mode active" "DSPM mode flag"
validate_output "$output" "DSPM Resources:" "DSPM section present"
validate_output "$output" "Cloud SQL instances:" "SQL instances section"
validate_output "$output" "Storage buckets:" "Storage section"

# Test 3: Organization Mode
print_header "Test 3: Organization Mode"
start_monitoring
output=$(./pcs_gcp_sizing.sh -o 123456789012)
stop_monitoring
validate_output "$output" "Organization mode active" "Organization mode flag"
validate_output "$output" "Organization ID: .* identified" "Organization ID detection"

# Test 4: Service API Checks
print_header "Test 4: Service API Checks"
start_monitoring
output=$(./pcs_gcp_sizing.sh -d 123456789012)
stop_monitoring
validate_output "$output" "Compute Engine API" "Compute API check"
validate_output "$output" "Cloud SQL API" "SQL API check"
validate_output "$output" "Storage API" "Storage API check"

# Test 5: Connect Mode with DSPM
print_header "Test 5: Connect Mode with DSPM"
start_monitoring
output=$(./pcs_gcp_sizing.sh -c -d 123456789012)
stop_monitoring
validate_output "$output" "Connect mode active" "Connect mode flag"
validate_output "$output" "Instances with Database Ports:" "Database detection"

# Test 6: All Options Combined
print_header "Test 6: All Options Combined"
start_monitoring
output=$(./pcs_gcp_sizing.sh -c -d -o -s 123456789012)
stop_monitoring
validate_output "$output" "Connect mode active" "Connect mode"
validate_output "$output" "DSPM mode active" "DSPM mode"
validate_output "$output" "Organization mode active" "Organization mode"

# Test 7: Resource Counting
print_header "Test 7: Resource Counting"
start_monitoring
output=$(./pcs_gcp_sizing.sh -d 123456789012)
stop_monitoring
validate_output "$output" "Compute instances:" "Compute instances count"
validate_output "$output" "GKE container nodes:" "GKE nodes count"
validate_output "$output" "Cloud SQL instances:" "SQL instances count"
validate_output "$output" "Cloud Spanner instances:" "Spanner instances count"
validate_output "$output" "Cloud Bigtable instances:" "Bigtable instances count"
validate_output "$output" "Persistent Disks:" "Persistent disks count"

# Test 8: Authentication Check
print_header "Test 8: Authentication Check"
start_monitoring
# Temporarily unset GOOGLE_APPLICATION_CREDENTIALS to test auth check
OLD_CREDS=$GOOGLE_APPLICATION_CREDENTIALS
unset GOOGLE_APPLICATION_CREDENTIALS
output=$(./pcs_gcp_sizing.sh 123456789012 2>&1)
validate_output "$output" "Please authenticate with the gcloud CLI" "Authentication check"
export GOOGLE_APPLICATION_CREDENTIALS=$OLD_CREDS
stop_monitoring

# Test 9: Large-Scale Environment Performance
print_header "Test 9: Large-Scale Environment Performance"
echo "Testing performance with organization-wide scan..."
start_monitoring
output=$(./pcs_gcp_sizing.sh -o -d -c 123456789012)
stop_monitoring
validate_output "$output" "Prisma Cloud GCP inventory collection complete" "Large-scale execution"

echo ""
echo "Test Suite Complete"
echo "==================="
