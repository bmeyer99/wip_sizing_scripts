#!/bin/bash

# Enhanced performance monitoring functions
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
    local duration=$(( (end_time - start_time) / 1000000 ))
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

function log_error() {
    error_count=$((error_count + 1))
    echo "❌ Error: $1" >&2
}

function track_api_call() {
    local start_call=$(date +%s%N)
    "$@"
    local status=$?
    local end_call=$(date +%s%N)
    local call_duration=$(( (end_call - start_call) / 1000000 ))
    
    api_calls=$((api_calls + 1))
    log_request_time $call_duration
    
    if [ $status -ne 0 ]; then
        log_error "API call failed: $@"
    fi
    
    return $status
}

# Test helper functions
function assert_success() {
    if [ $? -eq 0 ]; then
        echo "✅ Test passed: $1"
    else
        echo "❌ Test failed: $1"
        exit 1
    fi
}

function assert_contains() {
    if echo "$1" | grep -q "$2"; then
        echo "✅ Test passed: Output contains '$2'"
    else
        echo "❌ Test failed: Output does not contain '$2'"
        exit 1
    fi
}

function assert_count() {
    local actual=$1
    local expected=$2
    local message=$3
    if [ "$actual" -eq "$expected" ]; then
        echo "✅ Test passed: $message (count: $actual)"
    else
        echo "❌ Test failed: $message (expected: $expected, got: $actual)"
        exit 1
    fi
}

# Test scenarios
function test_basic_execution() {
    echo "Testing basic execution..."
    start_monitoring
    
    # Test basic script execution
    local output=$(track_api_call ../pcs_aws_sizing.sh)
    assert_success "Script executes successfully"
    assert_contains "$output" "EC2 instances:"
    assert_contains "$output" "EKS nodes:"
    
    stop_monitoring
}

function test_dspm_mode() {
    echo "Testing DSPM mode..."
    start_monitoring
    
    # Test DSPM features
    local output=$(track_api_call ../pcs_aws_sizing.sh -d)
    assert_success "DSPM mode executes successfully"
    assert_contains "$output" "S3 buckets:"
    assert_contains "$output" "EFS file systems:"
    assert_contains "$output" "Aurora clusters:"
    assert_contains "$output" "RDS instances:"
    assert_contains "$output" "DynamoDB tables:"
    assert_contains "$output" "Redshift clusters:"
    
    stop_monitoring
}

function test_organization_mode() {
    echo "Testing organization mode..."
    start_monitoring
    
    # Test organization-wide scanning
    local output=$(track_api_call ../pcs_aws_sizing.sh -o)
    assert_success "Organization mode executes successfully"
    assert_contains "$output" "Organization mode active"
    
    stop_monitoring
}

function test_region_filtering() {
    echo "Testing region filtering..."
    start_monitoring
    
    # Test single region scanning
    local output=$(track_api_call ../pcs_aws_sizing.sh -n us-east-1)
    assert_success "Region filtering executes successfully"
    assert_contains "$output" "Requested region is valid"
    
    # Test invalid region
    output=$(track_api_call ../pcs_aws_sizing.sh -n invalid-region 2>&1)
    if [ $? -eq 1 ]; then
        echo "✅ Test passed: Invalid region properly rejected"
    else
        echo "❌ Test failed: Invalid region not properly handled"
        exit 1
    fi
    
    stop_monitoring
}

function test_connect_mode() {
    echo "Testing connect mode..."
    start_monitoring
    
    # Test SSM connection capabilities
    local output=$(track_api_call ../pcs_aws_sizing.sh -c -d)
    assert_success "Connect mode executes successfully"
    assert_contains "$output" "EC2 DBs:"
    
    stop_monitoring
}

function test_combined_options() {
    echo "Testing combined options..."
    start_monitoring
    
    # Test multiple features together
    local output=$(track_api_call ../pcs_aws_sizing.sh -o -d -n us-east-1)
    assert_success "Combined options execute successfully"
    assert_contains "$output" "Organization mode active"
    assert_contains "$output" "DSPM mode active"
    assert_contains "$output" "Requested region is valid"
    
    stop_monitoring
}

function test_error_handling() {
    echo "Testing error handling..."
    start_monitoring
    
    # Test role assumption failure
    local output=$(track_api_call ../pcs_aws_sizing.sh -o -r InvalidRole 2>&1)
    if [ $? -eq 1 ]; then
        echo "✅ Test passed: Invalid role properly handled"
    else
        echo "❌ Test failed: Invalid role not properly handled"
        exit 1
    fi
    
    stop_monitoring
}

function test_large_scale() {
    echo "Testing large-scale environment..."
    start_monitoring
    
    # Test organization-wide scanning with all features
    local output=$(track_api_call ../pcs_aws_sizing.sh -o -d)
    assert_success "Large-scale scanning executes successfully"
    
    stop_monitoring
}

# Main test execution
echo "Starting AWS sizing script tests..."

# Check prerequisites
for cmd in aws jq bc; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

# Run test scenarios
test_basic_execution
test_dspm_mode
test_organization_mode
test_region_filtering
test_connect_mode
test_combined_options
test_error_handling
test_large_scale

echo "All tests completed successfully!"
