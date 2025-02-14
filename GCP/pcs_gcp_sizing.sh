#!/bin/bash

# Trap for cleanup on script exit
trap cleanup EXIT

function cleanup() {
    # Remove any temporary files
    rm -f /tmp/pcs_gcp_*.tmp 2>/dev/null
    __stopspin
}

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires gcloud CLI to execute"
    echo "* Requires JQ utility to be installed"
    echo "* Validated to run successfully from within CSP console CLIs"

    echo "Available flags:"
    echo " -c          Connect to instances to inspect for databases in combination with DSPM mode"
    echo " -d          DSPM mode"
    echo "             This option will search for and count resources that are specific to data security"
    echo "             posture management (DSPM) licensing."
    echo " -h          Display the help info"
    echo " -o          Organization mode"
    echo "             This option will scan all projects in the organization."
    echo " -s          Include stopped compute instances in addition to running"
    exit 1
}

spinpid=
function __startspin {
    # start the spinner
    set +m
    { while : ; do for X in '  •     ' '   •    ' '    •   ' '     •  ' '      • ' '     •  ' '    •   ' '   •    ' '  •     ' ' •      ' ; do echo -en "\b\b\b\b\b\b\b\b$X" ; sleep 0.1 ; done ; done & } 2>/dev/null
    spinpid=$!
}

function __stopspin {
    # stop the spinner
    if [ -n "$spinpid" ]; then
        { kill -9 $spinpid && wait; } 2>/dev/null
        set -m
        echo -en "\033[2K\r"
        spinpid=
    fi
}

# Check for required utilities
for cmd in gcloud jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

echo ''
echo '  ___     _                  ___ _             _  '
echo ' | _ \_ _(_)____ __  __ _   / __| |___ _  _ __| | '
echo ' |  _/ '\''_| (_-< '\''  \/ _` | | (__| / _ \ || / _` | '
echo ' |_| |_| |_/__/_|_|_\__,_|  \___|_\___/\_,_\__,_| '
echo ''

# Initialize options
ORG_MODE=false
DSPM_MODE=false
CONNECT_MODE=false
STATE="RUNNING"

# Get options
while getopts ":cdhos" opt; do
  case ${opt} in
    c) CONNECT_MODE=true ;;
    d) DSPM_MODE=true ;;
    h) printHelp ;;
    o) ORG_MODE=true ;;
    s) STATE="ALL" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp ;;
 esac
done
shift $((OPTIND-1))

# Ensure gcloud CLI is authenticated
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
    echo "Please authenticate with the gcloud CLI using 'gcloud auth login'."
    exit 1
fi

# Function to handle gcloud CLI calls with retries and rate limiting
function gcloud_api_call() {
    local max_attempts=3
    local attempt=1
    local result
    local delay=2
    
    while [ $attempt -le $max_attempts ]; do
        result=$("$@" 2>&1)
        if [ $? -eq 0 ]; then
            echo "$result"
            return 0
        fi
        echo "Attempt $attempt failed: $result" >&2
        sleep $((delay * attempt))
        ((attempt++))
    done
    
    echo "Error: gcloud CLI call failed after $max_attempts attempts" >&2
    return 1
}

# Attempt to fetch organization ID programatically
ORG_ID=$(gcloud_api_call gcloud organizations list --format="value(ID)")

if [[ $ORG_ID =~ ^[0-9]{12}$ ]]; then
    echo "Organization ID: $ORG_ID identified"
else
    echo "Organization ID not determined, reading input value"
    # Ensure the organization ID is set
    if [ -z "$1" ]; then
        echo "Usage: $0 <organization-id>"
        exit 1
    fi
    ORG_ID=$1
fi

# Initialize counters
total_compute_instances=0
total_gke_nodes=0
total_cloud_sql=0
total_cloud_spanner=0
total_bigtable=0
total_mongodb=0
total_storage_buckets=0
total_filestore=0
total_persistent_disks=0
total_instance_databases=0

# Function to check if a service is enabled with timeout
check_service() {
    local project=$1
    local service=$2
    local TIMEOUT=30
    
    if timeout $TIMEOUT gcloud_api_call gcloud services list \
        --project "$project" \
        --filter="config.name:$service" \
        --format="get(config.name)" 2>/dev/null | grep -q "$service"; then
        return 0
    else
        return 1
    fi
}

# Function to count resources in parallel with timeout
count_project_resources() {
    local project=$1
    local resource_type=$2
    local format=$3
    local filter=$4
    local TIMEOUT=30
    
    timeout $TIMEOUT gcloud_api_call gcloud $resource_type list \
        --project "$project" \
        --format="$format" \
        --filter="$filter" 2>/dev/null | wc -l
}

# Function to check databases on instances in parallel with timeout
check_instance_databases_parallel() {
    local project=$1
    local instance=$2
    local zone=$3
    local TIMEOUT=30
    
    # Get firewall rules for the instance with timeout
    local network_tags
    network_tags=$(timeout $TIMEOUT gcloud_api_call gcloud compute instances describe "$instance" \
        --project "$project" \
        --zone "$zone" \
        --format="get(tags.items)" 2>/dev/null) || return 1
    
    local has_db_port=false
    
    # Check for common database ports in firewall rules
    local db_ports=("3306" "5432" "27017" "1433" "33060")
    for port in "${db_ports[@]}"; do
        if timeout $TIMEOUT gcloud_api_call gcloud compute firewall-rules list \
            --project "$project" \
            --filter="allowed.ports~$port" \
            --format="get(name)" 2>/dev/null | grep -q .; then
            echo "DB_FOUND:$instance:$port"
            has_db_port=true
            break
        fi
    done
    
    if [ "$has_db_port" = true ] && [ "$CONNECT_MODE" = true ]; then
        if timeout $TIMEOUT gcloud_api_call gcloud compute instances get-guest-attributes "$instance" \
            --project "$project" \
            --zone "$zone" &>/dev/null; then
            
            local cmd_output
            cmd_output=$(timeout $TIMEOUT gcloud_api_call gcloud compute ssh "$instance" \
                --project "$project" \
                --zone "$zone" \
                --command="ps aux | grep -E 'postgres|mongo|mysql|mariadb|sqlserver' | grep -v grep" \
                2>/dev/null)
            
            if [ $? -eq 0 ] && [ -n "$cmd_output" ]; then
                echo "PROCESS_FOUND:$instance"
            fi
        fi
    fi
}

# Function to count resources in a project
count_resources() {
    local project=$1
    __startspin
    
    echo "Processing project: $project"
    if ! gcloud_api_call gcloud config set project "$project" >/dev/null 2>&1; then
        echo "Error: Failed to access project $project. Skipping..."
        __stopspin
        return 1
    fi

    # Create temporary files for resource counts
    local compute_count_file=$(mktemp /tmp/pcs_gcp_compute.XXXXXX)
    local gke_count_file=$(mktemp /tmp/pcs_gcp_gke.XXXXXX)
    local instance_db_count_file=$(mktemp /tmp/pcs_gcp_instance_db.XXXXXX)
    
    # Start parallel resource counting for compute instances with rate limiting
    {
        if check_service "$project" "compute.googleapis.com"; then
            local instance_filter="status = RUNNING"
            if [ "$STATE" == "ALL" ]; then
                instance_filter=""
            fi
            
            local instances
            instances=$(gcloud_api_call gcloud compute instances list \
                --filter="$instance_filter" \
                --format="table(name,zone.basename())" 2>/dev/null) || instances=""
            
            local compute_count=0
            if [ -n "$instances" ]; then
                compute_count=$(echo "$instances" | grep -v "^$" | wc -l)
                if [ $compute_count -gt 0 ]; then
                    compute_count=$((compute_count-1))  # Subtract header line
                fi
            fi
            echo "$compute_count" > "$compute_count_file"
            
            if [ "$DSPM_MODE" == true ] && [ $compute_count -gt 0 ]; then
                # Create temporary directory for instance check results
                local instance_results_dir=$(mktemp -d /tmp/pcs_gcp_instance_results.XXXXXX)
                local instance_pids=()
                
                echo "$instances" | tail -n +2 | while read -r instance zone; do
                    check_instance_databases_parallel "$project" "$instance" "$zone" > "$instance_results_dir/$instance" &
                    instance_pids+=($!)
                    
                    # Limit concurrent instance checks and implement rate limiting
                    if [ ${#instance_pids[@]} -ge 5 ]; then
                        wait "${instance_pids[0]}"
                        instance_pids=("${instance_pids[@]:1}")
                        sleep 1  # Rate limiting
                    fi
                done
                
                # Wait for all instance checks to complete
                wait "${instance_pids[@]}" 2>/dev/null
                
                # Process results
                local db_instance_count=0
                for result in "$instance_results_dir"/*; do
                    if [ -f "$result" ] && grep -q "DB_FOUND\|PROCESS_FOUND" "$result"; then
                        db_instance_count=$((db_instance_count + 1))
                    fi
                done
                
                echo "$db_instance_count" > "$instance_db_count_file"
                rm -rf "$instance_results_dir"
            fi
        else
            echo "0" > "$compute_count_file"
            echo "  Compute Engine API not enabled"
        fi
    } &
    local compute_pid=$!
    
    # Start parallel resource counting for GKE nodes with rate limiting
    {
        local total_nodes=0
        if check_service "$project" "container.googleapis.com"; then
            local clusters
            clusters=$(gcloud_api_call gcloud container clusters list \
                --format="table(name,zone)" 2>/dev/null) || clusters=""
            
            if [ -n "$clusters" ]; then
                echo "$clusters" | tail -n +2 | while read -r cluster zone; do
                    local node_count
                    node_count=$(gcloud_api_call gcloud container clusters describe "$cluster" \
                        --zone "$zone" \
                        --format="get(currentNodeCount)" 2>/dev/null) || continue
                    
                    echo "  GKE cluster '$cluster' nodes: $node_count"
                    total_nodes=$((total_nodes + node_count))
                    sleep 1  # Rate limiting
                done
            fi
        else
            echo "  GKE API not enabled"
        fi
        echo "$total_nodes" > "$gke_count_file"
    } &
    local gke_pid=$!

    if [ "$DSPM_MODE" == true ]; then
        # Create temporary files for DSPM resource counts
        local sql_count_file=$(mktemp /tmp/pcs_gcp_sql.XXXXXX)
        local spanner_count_file=$(mktemp /tmp/pcs_gcp_spanner.XXXXXX)
        local bigtable_count_file=$(mktemp /tmp/pcs_gcp_bigtable.XXXXXX)
        local bucket_count_file=$(mktemp /tmp/pcs_gcp_bucket.XXXXXX)
        local filestore_count_file=$(mktemp /tmp/pcs_gcp_filestore.XXXXXX)
        local disk_count_file=$(mktemp /tmp/pcs_gcp_disk.XXXXXX)
        
        # Start parallel resource counting for each service with rate limiting
        {
            if check_service "$project" "sqladmin.googleapis.com"; then
                count_project_resources "$project" "sql instances" "get(name)" "" > "$sql_count_file"
            else
                echo "0" > "$sql_count_file"
                echo "  Cloud SQL API not enabled"
            fi
        } &
        local sql_pid=$!
        sleep 1  # Rate limiting
        
        {
            if check_service "$project" "spanner.googleapis.com"; then
                count_project_resources "$project" "spanner instances" "get(name)" "" > "$spanner_count_file"
            else
                echo "0" > "$spanner_count_file"
                echo "  Cloud Spanner API not enabled"
            fi
        } &
        local spanner_pid=$!
        sleep 1  # Rate limiting
        
        {
            if check_service "$project" "bigtable.googleapis.com"; then
                count_project_resources "$project" "bigtable instances" "get(name)" "" > "$bigtable_count_file"
            else
                echo "0" > "$bigtable_count_file"
                echo "  Cloud Bigtable API not enabled"
            fi
        } &
        local bigtable_pid=$!
        sleep 1  # Rate limiting
        
        {
            if check_service "$project" "storage-api.googleapis.com"; then
                gsutil ls -p "$project" 2>/dev/null | wc -l > "$bucket_count_file"
            else
                echo "0" > "$bucket_count_file"
                echo "  Storage API not enabled"
            fi
        } &
        local bucket_pid=$!
        sleep 1  # Rate limiting
        
        {
            if check_service "$project" "file.googleapis.com"; then
                count_project_resources "$project" "filestore instances" "get(name)" "" > "$filestore_count_file"
            else
                echo "0" > "$filestore_count_file"
                echo "  Filestore API not enabled"
            fi
        } &
        local filestore_pid=$!
        sleep 1  # Rate limiting
        
        {
            if check_service "$project" "compute.googleapis.com"; then
                count_project_resources "$project" "compute disks" "get(name)" "" > "$disk_count_file"
            else
                echo "0" > "$disk_count_file"
            fi
        } &
        local disk_pid=$!
        
        # Wait for all DSPM resource counting to complete
        wait $sql_pid $spanner_pid $bigtable_pid $bucket_pid $filestore_pid $disk_pid 2>/dev/null
        
        # Read and update totals
        if [ -f "$sql_count_file" ]; then
            total_cloud_sql=$((total_cloud_sql + $(cat "$sql_count_file")))
            echo "  Cloud SQL instances: $(cat "$sql_count_file")"
        fi
        if [ -f "$spanner_count_file" ]; then
            total_cloud_spanner=$((total_cloud_spanner + $(cat "$spanner_count_file")))
            echo "  Cloud Spanner instances: $(cat "$spanner_count_file")"
        fi
        if [ -f "$bigtable_count_file" ]; then
            total_bigtable=$((total_bigtable + $(cat "$bigtable_count_file")))
            echo "  Cloud Bigtable instances: $(cat "$bigtable_count_file")"
        fi
        if [ -f "$bucket_count_file" ]; then
            total_storage_buckets=$((total_storage_buckets + $(cat "$bucket_count_file")))
            echo "  Storage buckets: $(cat "$bucket_count_file")"
        fi
        if [ -f "$filestore_count_file" ]; then
            total_filestore=$((total_filestore + $(cat "$filestore_count_file")))
            echo "  Filestore instances: $(cat "$filestore_count_file")"
        fi
        if [ -f "$disk_count_file" ]; then
            total_persistent_disks=$((total_persistent_disks + $(cat "$disk_count_file")))
            echo "  Persistent Disks: $(cat "$disk_count_file")"
        fi
        
        # Cleanup temporary files
        rm -f "$sql_count_file" "$spanner_count_file" "$bigtable_count_file" \
              "$bucket_count_file" "$filestore_count_file" "$disk_count_file"
    fi
    
    # Wait for compute and GKE counting to complete
    wait $compute_pid $gke_pid 2>/dev/null
    
    # Read and update totals
    if [ -f "$compute_count_file" ]; then
        total_compute_instances=$((total_compute_instances + $(cat "$compute_count_file")))
        echo "  Compute Engine instances: $(cat "$compute_count_file")"
    fi
    if [ -f "$gke_count_file" ]; then
        total_gke_nodes=$((total_gke_nodes + $(cat "$gke_count_file")))
    fi
    if [ "$DSPM_MODE" == true ] && [ -f "$instance_db_count_file" ]; then
        total_instance_databases=$((total_instance_databases + $(cat "$instance_db_count_file")))
        echo "  Instances with Database Ports: $(cat "$instance_db_count_file")"
    fi
    
    # Cleanup temporary files
    rm -f "$compute_count_file" "$gke_count_file" "$instance_db_count_file"
    
    __stopspin
}

if [ "$ORG_MODE" == true ]; then
    echo "Organization mode active"
fi

if [ "$DSPM_MODE" == true ]; then
    echo "DSPM mode active"
fi

if [ "$CONNECT_MODE" == true ]; then
    echo "Connect mode active"
fi

# Get the list of projects in the organization with error handling
projects=$(gcloud_api_call gcloud projects list \
    --filter="parent.id=$ORG_ID" \
    --format="value(projectId)")

if [ $? -ne 0 ] || [ -z "$projects" ]; then
    echo "No projects found in the organization or error occurred."
    exit 1
fi

# Process projects in parallel with rate limiting
project_pids=()
for project in $projects; do
    count_resources "$project" &
    project_pids+=($!)
    
    # Limit concurrent project processing and implement rate limiting
    if [ ${#project_pids[@]} -ge 3 ]; then
        wait "${project_pids[0]}"
        project_pids=("${project_pids[@]:1}")
        sleep 2  # Rate limiting
    fi
done

# Wait for all project processing to complete
wait "${project_pids[@]}" 2>/dev/null

echo ""
echo "##########################################"
echo "Prisma Cloud GCP inventory collection complete."
echo ""
echo "Summary:"
echo "==============================="
echo "Compute Resources:"
echo "  Compute instances: $total_compute_instances"
echo "  GKE container nodes: $total_gke_nodes"

if [ "$DSPM_MODE" == true ]; then
    echo ""
    echo "DSPM Resources:"
    echo "  Cloud SQL instances: $total_cloud_sql"
    echo "  Cloud Spanner instances: $total_cloud_spanner"
    echo "  Cloud Bigtable instances: $total_bigtable"
    echo "  Storage buckets: $total_storage_buckets"
    echo "  Filestore instances: $total_filestore"
    echo "  Persistent Disks: $total_persistent_disks"
    echo "  Instances with Database Ports: $total_instance_databases"
fi
