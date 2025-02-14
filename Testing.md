# Testing Guide for Prisma Cloud Sizing Scripts

This guide explains how to use the test suites for validating the Azure, GCP, and AWS sizing scripts.

## Prerequisites

- Azure CLI installed and configured for Azure tests
- Google Cloud SDK installed and configured for GCP tests
- AWS CLI installed and configured for AWS tests
- `jq` utility installed
- Appropriate permissions in all cloud environments

## Test Suites

### Azure Test Suite (`Azure/test_azure_sizing.sh`)

Tests the following scenarios:

1. Basic Execution
   - Verifies script runs successfully
   - Validates basic resource counting

2. DSPM Mode
   - Tests data security posture management features
   - Validates database resource detection
   - Checks storage resource counting

3. Organization Mode
   - Tests multi-subscription scanning
   - Validates role-based access

4. Region Filtering
   - Tests single-region resource counting
   - Validates region validation logic

5. Connect Mode
   - Tests VM inspection capabilities
   - Validates database detection on VMs

6. Combined Options
   - Tests all features working together
   - Validates output consistency

7. Error Handling
   - Tests invalid region handling
   - Validates error messages

8. Large-Scale Environment Performance
   - Tests organization-wide scanning
   - Validates performance at scale

### GCP Test Suite (`GCP/test_gcp_sizing.sh`)

Tests the following scenarios:

1. Basic Execution
   - Verifies script runs successfully
   - Validates basic resource counting

2. DSPM Mode
   - Tests data security posture management features
   - Validates database resource detection
   - Checks storage resource counting

3. Organization Mode
   - Tests organization-wide scanning
   - Validates project enumeration

4. Service API Checks
   - Tests API enablement detection
   - Validates service availability checks

5. Connect Mode
   - Tests instance inspection capabilities
   - Validates database detection on instances

6. Combined Options
   - Tests all features working together
   - Validates output consistency

7. Resource Counting
   - Tests all resource type counting
   - Validates count accuracy

8. Authentication
   - Tests authentication requirements
   - Validates credential handling

9. Large-Scale Environment Performance
   - Tests organization-wide scanning
   - Validates performance at scale

### AWS Test Suite (`AWS/test_aws_sizing.sh`)

Tests the following scenarios:

1. Basic Execution
   - Verifies script runs successfully
   - Validates basic resource counting
   - Tests EC2 instance counting
   - Validates EKS node counting

2. DSPM Mode
   - Tests data security posture management features
   - Validates database resource detection
   - Tests S3 bucket counting
   - Validates EFS file system detection
   - Tests Aurora cluster counting
   - Validates RDS instance detection
   - Tests DynamoDB table counting
   - Validates Redshift cluster detection

3. Organization Mode
   - Tests multi-account scanning
   - Validates role assumption
   - Tests account enumeration
   - Validates cross-account access

4. Region Filtering
   - Tests single-region resource counting
   - Validates region validation logic
   - Tests global service handling (S3)
   - Validates region-specific resource detection

5. Connect Mode
   - Tests SSM connection capabilities
   - Validates database process detection
   - Tests security group port analysis
   - Validates EC2 database instance counting

6. Combined Options
   - Tests all features working together
   - Validates output consistency
   - Tests organization + DSPM mode
   - Validates region filter with other modes

7. Error Handling
   - Tests invalid region handling
   - Validates API error recovery
   - Tests role assumption failures
   - Validates retry mechanism
   - Tests rate limiting handling

8. Large-Scale Environment Performance
   - Tests organization-wide scanning
   - Validates performance at scale
   - Tests multi-region scanning efficiency
   - Validates resource counting accuracy

## Performance Monitoring

All test suites now include comprehensive performance monitoring capabilities:

### Metrics Tracked
- Execution Time (milliseconds)
- Memory Usage (KB)
- API Call Count
- Large-Scale Environment Performance
- CPU Usage Percentage
- Network I/O
- Rate Limit Tracking
- Error Rate
- Response Time Distribution

### Performance Test Scenarios
1. Basic Operations
   - Single subscription/project/account resource counting
   - Basic feature execution time
   - Resource enumeration speed

2. DSPM Operations
   - Database detection performance
   - Storage resource enumeration
   - Data scanning throughput

3. Organization-wide Scanning
   - Multi-subscription/project/account performance
   - Cross-account access timing
   - Parallel processing efficiency

4. Combined Feature Performance
   - All features enabled simultaneously
   - Resource counting with all options
   - Feature interaction impact

### Performance Baselines

#### Small Environment (<100 resources)
```
Expected Metrics:
- Execution Time: <30s
- Memory Usage: <100MB
- API Calls: <50
- CPU Usage: <20%
- Error Rate: <1%
```

#### Medium Environment (100-1000 resources)
```
Expected Metrics:
- Execution Time: <2m
- Memory Usage: <200MB
- API Calls: <200
- CPU Usage: <40%
- Error Rate: <2%
```

#### Large Environment (>1000 resources)
```
Expected Metrics:
- Execution Time: <5m
- Memory Usage: <500MB
- API Calls: <500
- CPU Usage: <60%
- Error Rate: <5%
```

### Interpreting Results
Performance metrics are displayed after each test:
```
Performance Metrics:
===================
Execution Time: XXXms
Memory Usage: XXXKB
API Calls: XXX
CPU Usage: XX%
Network I/O: XX MB
Rate Limits: XX/YY
Error Rate: XX%
Response Time Distribution:
- P50: XXms
- P90: XXms
- P99: XXms
```

## Running the Tests

### Azure Tests
```bash
cd Azure
chmod +x test_azure_sizing.sh
./test_azure_sizing.sh
```

### GCP Tests
```bash
cd GCP
chmod +x test_gcp_sizing.sh
./test_gcp_sizing.sh <organization-id>
```

### AWS Tests
```bash
cd AWS
chmod +x test_aws_sizing.sh
./test_aws_sizing.sh
```

## Performance Optimization Guidelines

1. API Call Optimization
   - Monitor API call counts
   - Look for opportunities to batch requests
   - Identify redundant API calls
   - Implement smart caching where appropriate
   - Use parallel API requests when possible

2. Memory Management
   - Track memory usage patterns
   - Identify memory leaks
   - Optimize data structure usage
   - Implement garbage collection
   - Use streaming for large datasets

3. Execution Time
   - Analyze timing patterns
   - Identify slow operations
   - Look for parallelization opportunities
   - Implement concurrent processing
   - Use asynchronous operations

4. Large-Scale Considerations
   - Monitor performance degradation at scale
   - Identify bottlenecks in organization mode
   - Optimize cross-account operations
   - Implement pagination handling
   - Use incremental processing

5. Error Handling and Recovery
   - Implement exponential backoff
   - Handle rate limiting gracefully
   - Provide detailed error reporting
   - Add automatic retry logic
   - Monitor error patterns

6. Network Optimization
   - Minimize data transfer
   - Implement request batching
   - Use compression where possible
   - Monitor bandwidth usage
   - Optimize payload sizes

## Performance Monitoring Implementation

Add these functions to test scripts:

```bash
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

# Enhanced API call tracking
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
```

## Test Output Analysis

Each test produces detailed output for analysis:

1. Basic Metrics
   - Overall execution time
   - Memory consumption
   - API call frequency
   - CPU utilization

2. Performance Patterns
   - Response time distribution
   - Error rate patterns
   - Resource usage trends
   - Scaling characteristics

3. Bottleneck Identification
   - Slow API calls
   - Memory spikes
   - CPU bottlenecks
   - Network constraints

4. Optimization Opportunities
   - Batch operation potential
   - Parallelization options
   - Caching possibilities
   - Resource usage optimization

## Best Practices

1. Test Environment Setup
   - Use representative data volumes
   - Mirror production configurations
   - Isolate test environments
   - Document environment details

2. Test Execution
   - Run tests multiple times
   - Vary input parameters
   - Test at different scales
   - Monitor system resources

3. Performance Analysis
   - Collect comprehensive metrics
   - Analyze trends over time
   - Document performance baselines
   - Track optimization impacts

4. Documentation
   - Maintain detailed test logs
   - Record environment configurations
   - Document performance thresholds
   - Update optimization findings

5. Continuous Improvement
   - Regular performance reviews
   - Iterative optimizations
   - Feedback incorporation
   - Documentation updates

## Next Steps

1. Implement Enhanced Monitoring
   - Add new metrics collection
   - Update test scripts
   - Validate monitoring accuracy

2. Establish Baselines
   - Run tests in various environments
   - Document baseline metrics
   - Set performance targets

3. Optimize Performance
   - Analyze test results
   - Implement improvements
   - Validate optimizations
   - Update documentation

4. Production Deployment
   - Verify improvements
   - Document changes
   - Update guidelines
   - Monitor results
