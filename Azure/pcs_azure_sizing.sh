#!/bin/bash

# Trap for cleanup on script exit
trap cleanup EXIT

function cleanup() {
    # Remove any temporary files
    rm -f /tmp/pcs_azure_*.tmp 2>/dev/null
    __stopspin
}

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires Azure CLI to execute"
    echo "* Requires JQ utility to be installed"
    echo "* Validated to run successfully from within Azure Cloud Shell"

    echo "Available flags:"
    echo " -c          Connect to VMs to inspect for databases in combination with DSPM mode"
    echo " -d          DSPM mode"
    echo "             This option will search for and count resources that are specific to data security"
    echo "             posture management (DSPM) licensing."
    echo " -h          Display the help info"
    echo " -n <region> Single region to scan"
    echo " -o          Organization mode"
    echo "             This option will scan all subscriptions in the tenant with the specified role."
    echo " -r <role>   Specify a role to use (default: Contributor)"
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
for cmd in az jq; do
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

# Ensure Azure CLI is logged in
if ! az account show > /dev/null 2>&1; then
    echo "Please log in to Azure CLI using 'az login' before running this script."
    exit 1
fi

# Initialize options
DSPM_MODE=false
STATE="running"
REGION=""
ORG_MODE=false
ROLE="Contributor"
CONNECT_MODE=false

# Get options
while getopts ":cdhn:or:s" opt; do
  case ${opt} in
    c) CONNECT_MODE=true ;;
    d) DSPM_MODE=true ;;
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="all" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp ;;
  esac
done
shift $((OPTIND-1))

# Function to handle Azure CLI calls with retries and rate limiting
function az_api_call() {
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
    
    echo "Error: Azure CLI call failed after $max_attempts attempts" >&2
    return 1
}

# Validate region if specified
if [[ "${REGION}" ]]; then
    valid_regions=$(az_api_call az account list-locations --query "[].name" -o tsv)
    if echo "$valid_regions" | grep -w "^${REGION}$" > /dev/null; then
        echo "Requested region is valid"
    else
        echo "Invalid region requested"
        exit 1
    fi
fi

if [ "$DSPM_MODE" == true ]; then
  echo "DSPM mode active"
fi

if [ "$ORG_MODE" == true ]; then
  echo "Organization mode active"
  echo "Role to use: $ROLE"
fi

if [ "$CONNECT_MODE" == true ]; then
  echo "Connect mode active"
fi

# Initialize counters
total_vm_count=0
total_node_count=0
total_sql_databases=0
total_mysql_databases=0
total_postgres_databases=0
total_cosmos_collections=0
total_storage_accounts=0
total_managed_disks=0
total_vm_databases=0

# Function to check for databases running on VMs with timeout
check_running_databases() {
    local subscription_id=$1
    local resource_group=$2
    local vm_name=$3
    local TIMEOUT=30
    
    # Get network security group rules for the VM with timeout
    local nsg_rules
    nsg_rules=$(timeout $TIMEOUT az_api_call az network nsg list \
        --subscription "$subscription_id" \
        --resource-group "$resource_group" \
        --query "[].securityRules[?direction=='Inbound'].[destinationPortRange]" \
        -o tsv) || return 1
    
    # Check for common database ports
    local db_ports=("3306" "5432" "27017" "1433" "33060")
    local db_port_found=false
    for port in "${db_ports[@]}"; do
        if echo "$nsg_rules" | grep -q "$port"; then
            echo "  Database port $port detected on VM: $vm_name"
            db_port_found=true
            break
        fi
    done

    if [ "$db_port_found" = true ] && [ "$CONNECT_MODE" = true ]; then
        echo "  Attempting direct inspection of VM: $vm_name"
        
        # Check if VM has Run Command enabled
        if timeout $TIMEOUT az_api_call az vm run-command list \
            --resource-group "$resource_group" \
            --vm-name "$vm_name" \
            --query "[].name" -o tsv &>/dev/null; then
            
            echo "    VM supports Run Command. Checking for database processes..."
            
            # Run command to check for database processes with timeout
            local cmd_output
            cmd_output=$(timeout $TIMEOUT az_api_call az vm run-command invoke \
                --resource-group "$resource_group" \
                --name "$vm_name" \
                --command-id RunShellScript \
                --scripts "ps aux | grep -E 'postgres|mongo|mysql|mariadb|sqlserver' | grep -v grep" \
                --query "value[0].message" \
                -o tsv 2>/dev/null)

            if [ $? -eq 0 ] && [ -n "$cmd_output" ]; then
                echo "    Database processes found:"
                echo "$cmd_output" | sed 's/^/      /'
                total_vm_databases=$((total_vm_databases + 1))
            else
                echo "    No database processes detected"
            fi
        else
            echo "    VM does not support Run Command"
        fi
    elif [ "$db_port_found" = true ]; then
        total_vm_databases=$((total_vm_databases + 1))
    fi
}

# Function to count resources in parallel within a subscription
count_subscription_resources() {
    local subscription_id=$1
    local region_filter=$2
    local resource_type=$3
    local query=$4
    
    if ! az_api_call az account set --subscription "$subscription_id" >/dev/null 2>&1; then
        echo "Error: Failed to switch to subscription $subscription_id"
        return 1
    fi
    
    local count
    count=$(az_api_call az $resource_type list $region_filter $query -o tsv 2>/dev/null) || count=0
    echo "$count"
}

# Function to check databases on VMs in parallel
check_vm_databases_parallel() {
    local subscription_id=$1
    local resource_group=$2
    local vm_name=$3
    local TIMEOUT=30
    
    # Get network security group rules for the VM with timeout
    local nsg_rules
    nsg_rules=$(timeout $TIMEOUT az_api_call az network nsg list \
        --subscription "$subscription_id" \
        --resource-group "$resource_group" \
        --query "[].securityRules[?direction=='Inbound'].[destinationPortRange]" \
        -o tsv 2>/dev/null) || return 1
    
    # Check for common database ports
    local db_ports=("3306" "5432" "27017" "1433" "33060")
    local db_port_found=false
    for port in "${db_ports[@]}"; do
        if echo "$nsg_rules" | grep -q "$port"; then
            echo "DB_FOUND:$vm_name:$port"
            db_port_found=true
            break
        fi
    done

    if [ "$db_port_found" = true ] && [ "$CONNECT_MODE" = true ]; then
        if timeout $TIMEOUT az_api_call az vm run-command list \
            --resource-group "$resource_group" \
            --vm-name "$vm_name" \
            --query "[].name" -o tsv &>/dev/null; then
            
            local cmd_output
            cmd_output=$(timeout $TIMEOUT az_api_call az vm run-command invoke \
                --resource-group "$resource_group" \
                --name "$vm_name" \
                --command-id RunShellScript \
                --scripts "ps aux | grep -E 'postgres|mongo|mysql|mariadb|sqlserver' | grep -v grep" \
                --query "value[0].message" \
                -o tsv 2>/dev/null)

            if [ $? -eq 0 ] && [ -n "$cmd_output" ]; then
                echo "PROCESS_FOUND:$vm_name"
            fi
        fi
    fi
}

# Function to count resources in a subscription
count_resources() {
    local subscription_id=$1
    __startspin
    
    echo "Processing subscription: $subscription_id"
    if ! az_api_call az account set --subscription "$subscription_id" >/dev/null 2>&1; then
        echo "Error: Failed to access subscription $subscription_id. Skipping..."
        __stopspin
        return 1
    fi

    # Set region filter if specified
    local region_filter=""
    if [[ "${REGION}" ]]; then
        region_filter="--location ${REGION}"
    fi

    # Count VMs and resources in parallel
    local vm_filter="--query \"[?powerState!='VM stopped']\""
    if [ "$STATE" == "all" ]; then
        vm_filter=""
    fi
    
    # Start parallel resource counting
    local vm_count_file=$(mktemp /tmp/pcs_azure_vm.XXXXXX)
    local node_count_file=$(mktemp /tmp/pcs_azure_node.XXXXXX)
    
    # VM counting in background
    count_subscription_resources "$subscription_id" "$region_filter" "vm list" "$vm_filter" > "$vm_count_file" &
    local vm_pid=$!
    
    # AKS node counting in background
    {
        local total_nodes=0
        local clusters
        clusters=$(az_api_call az aks list $region_filter --query "[].{name:name, resourceGroup:resourceGroup}" -o tsv 2>/dev/null) || clusters=""
        if [ -n "$clusters" ]; then
            while IFS=$'\t' read -r cluster_name resource_group; do
                local node_count
                node_count=$(az_api_call az aks show --name "$cluster_name" --resource-group "$resource_group" \
                    --query "agentPoolProfiles[].count | sum(@)" -o tsv 2>/dev/null) || continue
                echo "  AKS cluster '$cluster_name' nodes: $node_count"
                total_nodes=$((total_nodes + node_count))
            done <<< "$clusters"
        fi
        echo "$total_nodes" > "$node_count_file"
    } &
    local aks_pid=$!

    if [ "$DSPM_MODE" == true ]; then
        # Create temporary files for each resource count
        local sql_count_file=$(mktemp /tmp/pcs_azure_sql.XXXXXX)
        local mysql_count_file=$(mktemp /tmp/pcs_azure_mysql.XXXXXX)
        local postgres_count_file=$(mktemp /tmp/pcs_azure_postgres.XXXXXX)
        local cosmos_count_file=$(mktemp /tmp/pcs_azure_cosmos.XXXXXX)
        local storage_count_file=$(mktemp /tmp/pcs_azure_storage.XXXXXX)
        local disk_count_file=$(mktemp /tmp/pcs_azure_disk.XXXXXX)
        local vm_db_count_file=$(mktemp /tmp/pcs_azure_vmdb.XXXXXX)
        
        # Start parallel resource counting with rate limiting
        count_subscription_resources "$subscription_id" "$region_filter" "sql db list" "--query length(@)" > "$sql_count_file" &
        local sql_pid=$!
        sleep 1  # Rate limiting
        
        count_subscription_resources "$subscription_id" "$region_filter" "mysql server list" "--query length(@)" > "$mysql_count_file" &
        local mysql_pid=$!
        sleep 1  # Rate limiting
        
        count_subscription_resources "$subscription_id" "$region_filter" "postgres server list" "--query length(@)" > "$postgres_count_file" &
        local postgres_pid=$!
        sleep 1  # Rate limiting
        
        count_subscription_resources "$subscription_id" "$region_filter" "cosmosdb list" "--query length(@)" > "$cosmos_count_file" &
        local cosmos_pid=$!
        sleep 1  # Rate limiting
        
        count_subscription_resources "$subscription_id" "$region_filter" "storage account list" "--query length(@)" > "$storage_count_file" &
        local storage_pid=$!
        sleep 1  # Rate limiting
        
        count_subscription_resources "$subscription_id" "$region_filter" "disk list" "--query length(@)" > "$disk_count_file" &
        local disk_pid=$!

        # Check for databases on VMs in parallel
        {
            local db_vm_count=0
            local vms
            vms=$(az_api_call az vm list $region_filter --query "[].{name:name, resourceGroup:resourceGroup}" -o tsv 2>/dev/null) || vms=""
            if [ -n "$vms" ]; then
                # Create a temporary directory for VM check results
                local vm_results_dir=$(mktemp -d /tmp/pcs_azure_vm_results.XXXXXX)
                local vm_pids=()
                
                while IFS=$'\t' read -r vm_name resource_group; do
                    check_vm_databases_parallel "$subscription_id" "$resource_group" "$vm_name" > "$vm_results_dir/$vm_name" &
                    vm_pids+=($!)
                    
                    # Limit concurrent VM checks and implement rate limiting
                    if [ ${#vm_pids[@]} -ge 5 ]; then
                        wait "${vm_pids[0]}"
                        vm_pids=("${vm_pids[@]:1}")
                        sleep 1  # Rate limiting
                    fi
                done <<< "$vms"
                
                # Wait for all VM checks to complete
                wait "${vm_pids[@]}" 2>/dev/null
                
                # Process results
                for result in "$vm_results_dir"/*; do
                    if [ -f "$result" ] && grep -q "DB_FOUND\|PROCESS_FOUND" "$result"; then
                        db_vm_count=$((db_vm_count + 1))
                    fi
                done
                
                rm -rf "$vm_results_dir"
            fi
            echo "$db_vm_count" > "$vm_db_count_file"
        } &
        local vm_db_pid=$!

        # Wait for all resource counting to complete
        wait $sql_pid $mysql_pid $postgres_pid $cosmos_pid $storage_pid $disk_pid $vm_db_pid 2>/dev/null
        
        # Read and display results
        if [ -f "$sql_count_file" ]; then
            total_sql_databases=$((total_sql_databases + $(cat "$sql_count_file")))
            echo "  Azure SQL Databases: $(cat "$sql_count_file")"
        fi
        if [ -f "$mysql_count_file" ]; then
            total_mysql_databases=$((total_mysql_databases + $(cat "$mysql_count_file")))
            echo "  Azure MySQL Servers: $(cat "$mysql_count_file")"
        fi
        if [ -f "$postgres_count_file" ]; then
            total_postgres_databases=$((total_postgres_databases + $(cat "$postgres_count_file")))
            echo "  Azure PostgreSQL Servers: $(cat "$postgres_count_file")"
        fi
        if [ -f "$cosmos_count_file" ]; then
            total_cosmos_collections=$((total_cosmos_collections + $(cat "$cosmos_count_file")))
            echo "  Cosmos DB Accounts: $(cat "$cosmos_count_file")"
        fi
        if [ -f "$storage_count_file" ]; then
            total_storage_accounts=$((total_storage_accounts + $(cat "$storage_count_file")))
            echo "  Storage Accounts: $(cat "$storage_count_file")"
        fi
        if [ -f "$disk_count_file" ]; then
            total_managed_disks=$((total_managed_disks + $(cat "$disk_count_file")))
            echo "  Managed Disks: $(cat "$disk_count_file")"
        fi
        if [ -f "$vm_db_count_file" ]; then
            total_vm_databases=$((total_vm_databases + $(cat "$vm_db_count_file")))
            echo "  VMs with Database Ports: $(cat "$vm_db_count_file")"
        fi
    fi

    # Wait for VM and AKS counting to complete
    wait $vm_pid $aks_pid 2>/dev/null
    
    # Read and display results
    if [ -f "$vm_count_file" ]; then
        total_vm_count=$((total_vm_count + $(cat "$vm_count_file")))
        echo "  VM instances: $(cat "$vm_count_file")"
    fi
    if [ -f "$node_count_file" ]; then
        total_node_count=$((total_node_count + $(cat "$node_count_file")))
    fi

    __stopspin
}

echo "Counting resources across all subscriptions in the tenant..."

# Get all subscription IDs with error handling
subscriptions=$(az_api_call az account list --query "[].id" -o tsv)
if [ $? -ne 0 ] || [ -z "$subscriptions" ]; then
    echo "Error: Failed to retrieve subscription list"
    exit 1
fi

# Process subscriptions in parallel with rate limiting
subscription_pids=()
for subscription_id in $subscriptions; do
    count_resources "$subscription_id" &
    subscription_pids+=($!)
    
    # Limit concurrent subscription processing and implement rate limiting
    if [ ${#subscription_pids[@]} -ge 3 ]; then
        wait "${subscription_pids[0]}"
        subscription_pids=("${subscription_pids[@]:1}")
        sleep 2  # Rate limiting
    fi
done

# Wait for all subscription processing to complete
wait "${subscription_pids[@]}" 2>/dev/null

echo ""
echo "##########################################"
echo "Prisma Cloud Azure inventory collection complete."
echo ""
echo "Summary:"
echo "==============================="
echo "Compute Resources:"
echo "  VM instances: $total_vm_count"
echo "  AKS nodes: $total_node_count"

if [ "$DSPM_MODE" == true ]; then
    echo ""
    echo "DSPM Resources:"
    echo "  Azure SQL Databases: $total_sql_databases"
    echo "  MySQL Servers: $total_mysql_databases"
    echo "  PostgreSQL Servers: $total_postgres_databases"
    echo "  Cosmos DB Accounts: $total_cosmos_collections"
    echo "  Storage Accounts: $total_storage_accounts"
    echo "  Managed Disks: $total_managed_disks"
    echo "  VMs with Database Ports: $total_vm_databases"
fi
