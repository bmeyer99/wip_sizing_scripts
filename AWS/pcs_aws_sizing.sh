#!/bin/bash

# Trap for cleanup on script exit
trap cleanup EXIT

function cleanup() {
    if [ "$ORG_MODE" == true ]; then
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi
    # Remove any temporary files
    rm -f /tmp/pcs_aws_*.tmp 2>/dev/null
}

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires AWS CLI v2 to execute"
    echo "* Requires JQ utility to be installed"
    echo "* Validated to run successfully from within CSP console CLIs"

    echo "Available flags:"
    echo " -c          Connect via SSM to EC2 instances running DBs in combination with DSPM mode"
    echo " -d          DSPM mode"
    echo "             This option will search for and count resources that are specific to data security"
    echo "             posture management (DSPM) licensing."
    echo " -h          Display the help info"
    echo " -n <region> Single region to scan"
    echo " -o          Organization mode"
    echo "             This option will fetch all sub-accounts associated with an organization"
    echo "             and assume the default (or specified) cross account role in order to iterate through and"
    echo "             scan resources in each sub-account. This is typically run from the admin user in"
    echo "             the master account."
    echo " -r <role>   Specify a non default role to assume in combination with organization mode"
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
    { kill -9 $spinpid && wait; } 2>/dev/null
    set -m
    echo -en "\033[2K\r"
}

# Check for required utilities
for cmd in aws jq; do
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

# Ensure AWS CLI is configured
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "Please configure your AWS CLI using 'aws configure' before running this script."
    exit 1
fi

# Initialize options
ORG_MODE=false
DSPM_MODE=false
ROLE="OrganizationAccountAccessRole"
REGION=""
STATE="running"
SSM_MODE=false

# Get options
while getopts ":cdhn:or:s" opt; do
  case ${opt} in
    c) SSM_MODE=true ;;
    d) DSPM_MODE=true ;;
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="running,stopped" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp ;;
 esac
done
shift $((OPTIND-1))

# Get active regions
activeRegions=$(aws ec2 describe-regions --all-regions --query "Regions[].{Name:RegionName}" --output text)

# Validate region if specified
if [[ "${REGION}" ]]; then
    if echo "$activeRegions" | grep -w "^${REGION}$" > /dev/null; then
        echo "Requested region is valid"
    else
        echo "Invalid region requested"
        exit 1
    fi
fi

if [ "$ORG_MODE" == true ]; then
  echo "Organization mode active"
  echo "Role to assume: $ROLE"
fi
if [ "$DSPM_MODE" == true ]; then
  echo "DSPM mode active"
fi

# Initialize counters
total_ec2_instances=0
total_eks_nodes=0
total_s3_buckets=0
total_efs=0
total_aurora=0
total_rds=0
total_dynamodb=0
total_redshift=0
total_ec2_db=0
ec2_db_count=0

# Function to handle AWS API calls with retries and error handling
function aws_api_call() {
    local max_attempts=3
    local attempt=1
    local result
    
    while [ $attempt -le $max_attempts ]; do
        result=$("$@" 2>&1)
        if [ $? -eq 0 ]; then
            echo "$result"
            return 0
        fi
        echo "Attempt $attempt failed: $result" >&2
        sleep $((attempt * 2))
        ((attempt++))
    done
    
    echo "Error: AWS API call failed after $max_attempts attempts" >&2
    return 1
}

# Functions
check_running_databases() {
    local DATABASE_PORTS=(3306 5432 27017 1433 33060)
    local TIMEOUT=30

    echo "Fetching all running EC2 instances..."
    local instances
    if [[ "${REGION}" ]]; then
        instances=$(aws_api_call aws ec2 describe-instances \
        --region "$REGION" --filters "Name=instance-state-name,Values=$STATE" \
        --query "Reservations[*].Instances[*].{ID:InstanceId,IP:PrivateIpAddress,Name:Tags[?Key=='Name']|[0].Value}" \
        --output json)
    else
        instances=$(aws_api_call aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=$STATE" \
        --query "Reservations[*].Instances[*].{ID:InstanceId,IP:PrivateIpAddress,Name:Tags[?Key=='Name']|[0].Value}" \
        --output json)
    fi

    if [ $? -ne 0 ] || [[ -z "$instances" || "$instances" == "[]" ]]; then
        echo "No running EC2 instances found or error occurred."
        return 0
    fi

    echo "  Found running EC2 instances. Checking each instance for database activity..."

    for instance in $(echo "$instances" | jq -c '.[][]'); do
        local instance_id=$(echo "$instance" | jq -r '.ID')
        local private_ip=$(echo "$instance" | jq -r '.IP')
        local instance_name=$(echo "$instance" | jq -r '.Name // "Unnamed Instance"')

        echo "  Checking instance: $instance_name (ID: $instance_id, IP: $private_ip)"

        # Fetch security group details with timeout
        local sg_ids
        sg_ids=$(timeout $TIMEOUT aws_api_call aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
            --output text) || continue

        echo "    Security Groups: $sg_ids"

        local db_port_found=false
        for sg_id in $sg_ids; do
            local open_ports
            open_ports=$(timeout $TIMEOUT aws_api_call aws ec2 describe-security-groups \
                --group-ids "$sg_id" \
                --query "SecurityGroups[0].IpPermissions[*].FromPort" \
                --output text | tr '\t' ',') || continue

            echo "      Open Ports: $open_ports"

            for port in "${DATABASE_PORTS[@]}"; do
                if echo "$open_ports" | grep -q "^$port$"; then
                    echo "      Database port $port detected in Security Group $sg_id"
                    db_port_found=true
                fi
            done
        done

        if [ "$db_port_found" = true ] && [ "$SSM_MODE" = true ]; then
            if timeout $TIMEOUT aws_api_call aws ssm describe-instance-information \
                --filters "Key=InstanceIds,Values=$instance_id" \
                --query "InstanceInformationList[*]" --output text &>/dev/null; then
                
                echo "    Instance is managed by Systems Manager. Checking for database processes..."
                local running_processes
                running_processes=$(timeout $TIMEOUT aws_api_call aws ssm send-command \
                    --instance-ids "$instance_id" \
                    --document-name "AWS-RunShellScript" \
                    --comment "Check for running database processes" \
                    --parameters 'commands=["ps aux | grep -E \"postgres|mongo|mysql|mariadb|sqlserver\" | grep -v grep"]' \
                    --query "Command.CommandId" --output text)

                if [ $? -eq 0 ]; then
                    sleep 2
                    local output
                    output=$(timeout $TIMEOUT aws_api_call aws ssm list-command-invocations \
                        --command-id "$running_processes" \
                        --details --query "CommandInvocations[0].CommandPlugins[0].Output" \
                        --output text)

                    if [[ -n "$output" ]]; then
                        echo "    Database processes detected:"
                        echo "    $output"
                        echo "    Total EC2 DBs incremented"
                        ec2_db_count=$((ec2_db_count + 1))
                    else
                        echo "    No database processes detected."
                    fi
                fi
            else
                echo "    Instance is not managed by Systems Manager. Skipping process check."
            fi
        elif [ "$db_port_found" = true ]; then
            ec2_db_count=$((ec2_db_count + 1))
        fi
    done

    echo "  Database scan complete."
    echo "  EC2 DB instances: $ec2_db_count"
    total_ec2_db=$((total_ec2_db + ec2_db_count))
}

# Function to count resources in a single account
count_resources() {
    local account_id=$1
    local temp_creds_file
    
    if [ "$ORG_MODE" == true ]; then
        temp_creds_file=$(mktemp /tmp/pcs_aws_creds.XXXXXX)
        
        # Assume role in the account with error handling
        local creds
        creds=$(aws_api_call aws sts assume-role \
            --role-arn "arn:aws:iam::$account_id:role/$ROLE" \
            --role-session-name "OrgSession" \
            --query "Credentials" --output json)

        if [ $? -ne 0 ] || [ -z "$creds" ]; then
            echo "  Unable to assume role in account $account_id. Skipping..."
            return 1
        fi

        # Export temporary credentials
        {
            echo "export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r ".AccessKeyId")"
            echo "export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r ".SecretAccessKey")"
            echo "export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r ".SessionToken")"
        } > "$temp_creds_file"
        
        source "$temp_creds_file"
        rm -f "$temp_creds_file"
    fi

    if [ "$DSPM_MODE" == false ]; then
        echo "Counting Cloud Security resources in account: $account_id"
        
        # Count EC2 instances with error handling
        local ec2_count=0
        if [[ "${REGION}" ]]; then
            ec2_count=$(aws_api_call aws ec2 describe-instances \
                --region "$REGION" \
                --filters "Name=instance-state-name,Values=$STATE" \
                --query "length(Reservations[*].Instances[*][])" \
                --output text) || ec2_count=0
        else
            ec2_count=0
            for region in $activeRegions; do
                local region_count
                region_count=$(aws_api_call aws ec2 describe-instances \
                    --region "$region" \
                    --filters "Name=instance-state-name,Values=$STATE" \
                    --query "length(Reservations[*].Instances[*][])" \
                    --output text) || continue
                ec2_count=$((ec2_count + region_count))
            done
        fi
        echo "  EC2 instances: $ec2_count"
        total_ec2_instances=$((total_ec2_instances + ec2_count))

        # Count EKS nodes with error handling
        local clusters
        if [[ "${REGION}" ]]; then
            clusters=$(aws_api_call aws eks list-clusters \
                --region "$REGION" \
                --query "clusters[]" \
                --output text) || clusters=""
        else
            clusters=$(aws_api_call aws eks list-clusters \
                --query "clusters[]" \
                --output text) || clusters=""
        fi

        for cluster in $clusters; do
            local node_groups
            node_groups=$(aws_api_call aws eks list-nodegroups \
                --cluster-name "$cluster" \
                --query "nodegroups[]" \
                --output text) || continue

            for node_group in $node_groups; do
                local node_count
                node_count=$(aws_api_call aws eks describe-nodegroup \
                    --cluster-name "$cluster" \
                    --nodegroup-name "$node_group" \
                    --query "nodegroup.scalingConfig.desiredSize" \
                    --output text) || continue
                
                echo "  EKS cluster '$cluster' nodegroup $node_group nodes: $node_count"
                total_eks_nodes=$((total_eks_nodes + node_count))
            done
        done
    fi

    if [ "$DSPM_MODE" == true ]; then
        echo "Counting DSPM Security resources in account: $account_id"
        
        # Count resources with error handling
        if [[ "${REGION}" ]]; then
            # S3 buckets (S3 is global, region parameter is ignored)
            local s3_count
            s3_count=$(aws_api_call aws s3api list-buckets \
                --query "length(Buckets[])" \
                --output text) || s3_count=0
            echo "  S3 buckets: $s3_count"
            total_s3_buckets=$((total_s3_buckets + s3_count))

            # EFS file systems
            local efs_count
            efs_count=$(aws_api_call aws efs describe-file-systems \
                --region "$REGION" \
                --query "length(FileSystems[])" \
                --output text) || efs_count=0
            echo "  EFS file systems: $efs_count"
            total_efs=$((total_efs + efs_count))

            # Aurora clusters
            local aurora_count
            aurora_count=$(aws_api_call aws rds describe-db-clusters \
                --region "$REGION" \
                --query "length(DBClusters[?Engine=='aurora'])" \
                --output text) || aurora_count=0
            echo "  Aurora clusters: $aurora_count"
            total_aurora=$((total_aurora + aurora_count))

            # RDS instances
            local rds_count
            rds_count=$(aws_api_call aws rds describe-db-instances \
                --region "$REGION" \
                --query "length(DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'])" \
                --output text) || rds_count=0
            echo "  RDS instances (MySQL, MariaDB, PostgreSQL): $rds_count"
            total_rds=$((total_rds + rds_count))

            # DynamoDB tables
            local dynamodb_count
            dynamodb_count=$(aws_api_call aws dynamodb list-tables \
                --region "$REGION" \
                --query "length(TableNames)" \
                --output text) || dynamodb_count=0
            echo "  DynamoDB tables: $dynamodb_count"
            total_dynamodb=$((total_dynamodb + dynamodb_count))

            # Redshift clusters
            local redshift_count
            redshift_count=$(aws_api_call aws redshift describe-clusters \
                --region "$REGION" \
                --query "length(Clusters[])" \
                --output text) || redshift_count=0
            echo "  Redshift clusters: $redshift_count"
            total_redshift=$((total_redshift + redshift_count))
        else
            # Process all regions
            for region in $activeRegions; do
                echo "Processing region: $region"
                
                # EFS file systems
                local efs_count
                efs_count=$(aws_api_call aws efs describe-file-systems \
                    --region "$region" \
                    --query "length(FileSystems[])" \
                    --output text) || efs_count=0
                total_efs=$((total_efs + efs_count))

                # Aurora clusters
                local aurora_count
                aurora_count=$(aws_api_call aws rds describe-db-clusters \
                    --region "$region" \
                    --query "length(DBClusters[?Engine=='aurora'])" \
                    --output text) || aurora_count=0
                total_aurora=$((total_aurora + aurora_count))

                # RDS instances
                local rds_count
                rds_count=$(aws_api_call aws rds describe-db-instances \
                    --region "$region" \
                    --query "length(DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'])" \
                    --output text) || rds_count=0
                total_rds=$((total_rds + rds_count))

                # DynamoDB tables
                local dynamodb_count
                dynamodb_count=$(aws_api_call aws dynamodb list-tables \
                    --region "$region" \
                    --query "length(TableNames)" \
                    --output text) || dynamodb_count=0
                total_dynamodb=$((total_dynamodb + dynamodb_count))

                # Redshift clusters
                local redshift_count
                redshift_count=$(aws_api_call aws redshift describe-clusters \
                    --region "$region" \
                    --query "length(Clusters[])" \
                    --output text) || redshift_count=0
                total_redshift=$((total_redshift + redshift_count))
            done

            # S3 buckets (global service)
            local s3_count
            s3_count=$(aws_api_call aws s3api list-buckets \
                --query "length(Buckets[])" \
                --output text) || s3_count=0
            total_s3_buckets=$((total_s3_buckets + s3_count))
        fi

        if [ "$SSM_MODE" == true ]; then
            check_running_databases
        fi
    fi

    if [ "$ORG_MODE" == true ]; then
        # Unset temporary credentials
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi
}

# Main logic
if [ "$ORG_MODE" == true ]; then
    # Get the list of all accounts in the AWS Organization
    accounts=$(aws_api_call aws organizations list-accounts \
        --query "Accounts[].Id" \
        --output text)

    if [ $? -ne 0 ] || [ -z "$accounts" ]; then
        echo "No accounts found in the organization or error occurred."
        exit 1
    fi

    # Loop through each account in the organization
    for account_id in $accounts; do
        count_resources "$account_id"
    done
else
    # Run for the standalone account
    current_account=$(aws sts get-caller-identity --query "Account" --output text)
    count_resources "$current_account"
fi

# Print summary
echo ""
echo "##########################################"
echo "Prisma Cloud AWS inventory collection complete."
echo ""
echo "Summary:"
echo "==============================="
if [ "$DSPM_MODE" == false ]; then
    echo "Compute Resources:"
    echo "  EC2 instances: $total_ec2_instances"
    echo "  EKS nodes: $total_eks_nodes"
fi

if [ "$DSPM_MODE" == true ]; then
    echo "DSPM Resources:"
    echo "  S3 buckets: $total_s3_buckets"
    echo "  EFS file systems: $total_efs"
    echo "  Aurora clusters: $total_aurora"
    echo "  RDS instances: $total_rds"
    echo "  DynamoDB tables: $total_dynamodb"
    echo "  Redshift clusters: $total_redshift"
    echo "  EC2 DBs: $total_ec2_db"
fi
