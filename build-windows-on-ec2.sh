#!/usr/bin/env bash
# Builds and tests Windows Docker images on an ephemeral EC2 Windows instance.
#
# RECOMMENDED AMI
#   Use a Windows Server 2025 Base AMI (e.g. Windows_Server-2025-English-Core-Base-*).
#   EC2 Launch v2 on Base AMIs configures OpenSSH on first boot; Docker is installed
#   from GitHub releases by the script itself (version controlled via DOCKER_VERSION).
#   ECS-Optimized AMIs have Docker pre-installed but EC2 Launch v2 does NOT start
#   sshd on them, so they require extra user-data tweaks.
#
# LIFECYCLE
#   - On normal exit (success or failure): the EC2 instance is STOPPED (not terminated)
#     so it can be reused on the next run. VPC, subnet, IGW, route table, SG, and
#     EIC endpoint are kept; use --delete to remove everything.
#   - Pass an existing instance ID as the first argument to resume a stopped instance
#     instead of launching a new one.
#   - Use --delete <instance-id> to terminate the instance and remove all AWS resources
#     that were created in the same run (identified by the BuildRunId tag).
#
# When none of SECURITY_GROUP_ID / VPC_ID / SUBNET_ID are provided the script
# creates a minimal temporary VPC (CIDR 10.250.0.0/24) with one public subnet,
# an internet gateway, a route table, a security group, and an EC2 Instance Connect
# Endpoint — all tagged with the same BuildRunId so --delete can find them later.
# The EIC endpoint allows SSH to tunnel through AWS HTTPS so no inbound port 22 is
# required from the public internet.
#
# MODES
#   Build (new instance):
#     KEY_NAME=my-key AMI_ID=ami-... SSH_KEY_PATH=~/.ssh/my-key.pem \
#     ./build-windows-on-ec2.sh
#
#   Build (reuse existing stopped instance):
#     SSH_KEY_PATH=~/.ssh/my-key.pem \
#     ./build-windows-on-ec2.sh i-0abcdef1234567890
#
#   Delete instance + all associated resources created in the same run:
#     ./build-windows-on-ec2.sh --delete i-0abcdef1234567890
#
# REQUIRED environment variables (new-instance mode only):
#   KEY_NAME            EC2 key pair name
#   AMI_ID              Windows Server Base AMI (see above for AMI guidance)
#   SSH_KEY_PATH        Local path to the .pem key file
#
# OPTIONAL environment variables:
#   SECURITY_GROUP_ID   Existing SG allowing TCP 3389 from VPC CIDR. Created if unset.
#   VPC_ID              VPC for the temporary SG. Derived from SUBNET_ID, or created if unset.
#   SUBNET_ID           Subnet for the instance. Created if unset.
#   EIC_ENDPOINT_ID     Existing EC2 Instance Connect Endpoint to reuse (skip creation).
#                       Useful when relaunching a new instance in the same VPC.
#   INSTANCE_TYPE       EC2 instance type          (default: m5.xlarge)
#   SSH_USER            SSH user on the instance   (default: Administrator)
#   DOCKER_VERSION      Docker Engine version to install from GitHub releases
#                       (default: 27.5.1). Skipped if Docker is already installed.
#   IAM_INSTANCE_PROFILE IAM instance profile name (default: none)
#   AWS_PROFILE         AWS CLI profile to use     (default: none / current env)
#   AWS_REGION          AWS region                 (default: us-east-1)
#   BAKE_TARGET         Single bake target, e.g. "nanoserver-ltsc2025_jdk25" or
#                       "nanoserver-ltsc2022_jdk21".
#                       Overrides IMAGE_TYPES and JAVA_RELEASES when set.
#   IMAGE_TYPES         Space-separated list of Windows image flavors to build
#                       (default: "windowsservercore-ltsc2022 nanoserver-ltsc2022")
#   JAVA_RELEASES       Space-separated list of Java major versions to build
#                       (default: "21")

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Optional vars
# ──────────────────────────────────────────────────────────────────────────────
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.xlarge}"
SSH_USER="${SSH_USER:-Administrator}"
DOCKER_VERSION="${DOCKER_VERSION:-27.5.1}"
SUBNET_ID="${SUBNET_ID:-}"
VPC_ID="${VPC_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
EIC_ENDPOINT_ID="${EIC_ENDPOINT_ID:-}"
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
BAKE_TARGET="${BAKE_TARGET:-}"
IMAGE_TYPES="${IMAGE_TYPES:-windowsservercore-ltsc2022 nanoserver-ltsc2022}"
JAVA_RELEASES="${JAVA_RELEASES:-21}"

[[ -n "${AWS_PROFILE}" ]] && export AWS_PROFILE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_WORK_DIR='C:/docker-ssh-agent'
SCRIPT_NAME="build-windows-on-ec2.sh"

INSTANCE_ID=""
PUBLIC_IP=""
# EC2 Instance Connect Endpoint — created with VPC; used as SSH ProxyCommand so
# direct port-22 access from the internet is not required.
EIC_ENDPOINT_ID=""

# Exit code propagated through the cleanup trap.
# Set this before calling exit so cleanup exits with the right code.
_EXIT_CODE=0

# Unique ID that ties every AWS resource created in this run together.
# Stored as tag BuildRunId on all resources so --delete can find them.
RUN_ID="${SCRIPT_NAME}-$(date +%s)"

# Track what was created (for the resource summary printed early in the run)
SG_CREATED=false
SUBNET_CREATED=false
VPC_CREATED=false
EIC_CREATED=false

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }

_ssh_proxy_args() {
    # EIC supports remote ports 22 and 3389. EC2 Launch v2 on Windows Server
    # Base AMIs configures sshd on port 22, so we use --remote-port 22 here.
    # Returns array elements via nameref — must be called as: local -a arr; _ssh_proxy_args arr
    local -n _out=$1
    _out=()
    if [[ -n "${EIC_ENDPOINT_ID}" ]]; then
        local _cmd="aws ec2-instance-connect open-tunnel --instance-id ${INSTANCE_ID} --remote-port 22 --region ${AWS_REGION}"
        [[ -n "${AWS_PROFILE}" ]] && _cmd="${_cmd} --profile ${AWS_PROFILE}"
        _out=(-o "ProxyCommand=${_cmd}")
    fi
}

ssh_run() {
    local -a _proxy
    _ssh_proxy_args _proxy
    ssh -i "${SSH_KEY_PATH}" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=10 \
        -p 22 \
        "${_proxy[@]}" \
        "${SSH_USER}@${PUBLIC_IP}" "$@"
}

scp_to() {
    local -a _proxy
    _ssh_proxy_args _proxy
    scp -i "${SSH_KEY_PATH}" \
        -o StrictHostKeyChecking=no \
        -P 22 \
        "${_proxy[@]}" \
        "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# delete_instance: terminate and wait, then remove non-auto-deleted EBS volumes.
# ──────────────────────────────────────────────────────────────────────────────
delete_instance() {
    local instance_id="${1:?instance_id argument is required}"

    local volume_ids
    volume_ids=$(aws ec2 describe-volumes \
        --region "${AWS_REGION}" \
        --filters \
            "Name=attachment.instance-id,Values=${instance_id}" \
            "Name=attachment.delete-on-termination,Values=false" \
        --query "Volumes[].VolumeId" \
        --output text 2>/dev/null || true)

    log "Terminating instance ${instance_id}..."
    aws ec2 terminate-instances \
        --instance-ids "${instance_id}" \
        --region "${AWS_REGION}" > /dev/null

    log "Waiting for instance to reach 'terminated' state..."
    aws ec2 wait instance-terminated \
        --instance-ids "${instance_id}" \
        --region "${AWS_REGION}"
    log "Instance ${instance_id} terminated."

    for vol_id in ${volume_ids}; do
        log "Deleting orphaned EBS volume ${vol_id}..."
        if aws ec2 delete-volume \
                --volume-id "${vol_id}" \
                --region "${AWS_REGION}"; then
            log "  Volume ${vol_id} deleted."
        else
            log "  WARNING: could not delete volume ${vol_id}."
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# delete_run_resources: find and delete all AWS resources tagged with a BuildRunId.
# Order: SG -> subnet -> route table -> IGW -> VPC
# ──────────────────────────────────────────────────────────────────────────────
delete_run_resources() {
    local run_id="${1:?run_id argument is required}"
    local filter="Name=tag:BuildRunId,Values=${run_id}"
    log "Deleting AWS resources tagged BuildRunId=${run_id}..."

    # Security groups
    local sg_ids
    sg_ids=$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" \
        --filters "${filter}" \
        --query "SecurityGroups[].GroupId" \
        --output text 2>/dev/null || true)
    for sg_id in ${sg_ids}; do
        log "  Deleting security group ${sg_id}..."
        if aws ec2 delete-security-group \
                --group-id "${sg_id}" \
                --region "${AWS_REGION}" 2>/dev/null; then
            log "    ${sg_id} deleted."
        else
            log "    WARNING: could not delete ${sg_id}."
        fi
    done

    # EC2 Instance Connect Endpoints (must be deleted before subnet)
    local eice_ids
    eice_ids=$(aws ec2 describe-instance-connect-endpoints \
        --region "${AWS_REGION}" \
        --filters "${filter}" \
        --query "InstanceConnectEndpoints[].InstanceConnectEndpointId" \
        --output text 2>/dev/null || true)
    for eice_id in ${eice_ids}; do
        log "  Deleting EIC endpoint ${eice_id}..."
        if aws ec2 delete-instance-connect-endpoint \
                --instance-connect-endpoint-id "${eice_id}" \
                --region "${AWS_REGION}" 2>/dev/null; then
            log "    ${eice_id} deleted."
        else
            log "    WARNING: could not delete ${eice_id}."
        fi
    done

    # Subnets
    local subnet_ids
    subnet_ids=$(aws ec2 describe-subnets \
        --region "${AWS_REGION}" \
        --filters "${filter}" \
        --query "Subnets[].SubnetId" \
        --output text 2>/dev/null || true)
    for subnet_id in ${subnet_ids}; do
        log "  Deleting subnet ${subnet_id}..."
        if aws ec2 delete-subnet \
                --subnet-id "${subnet_id}" \
                --region "${AWS_REGION}" 2>/dev/null; then
            log "    ${subnet_id} deleted."
        else
            log "    WARNING: could not delete ${subnet_id}."
        fi
    done

    # Route tables — disassociate non-main associations before deleting
    local rt_ids
    rt_ids=$(aws ec2 describe-route-tables \
        --region "${AWS_REGION}" \
        --filters "${filter}" \
        --query "RouteTables[].RouteTableId" \
        --output text 2>/dev/null || true)
    for rt_id in ${rt_ids}; do
        local assoc_ids
        assoc_ids=$(aws ec2 describe-route-tables \
            --region "${AWS_REGION}" \
            --route-table-ids "${rt_id}" \
            --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" \
            --output text 2>/dev/null || true)
        for assoc_id in ${assoc_ids}; do
            aws ec2 disassociate-route-table \
                --association-id "${assoc_id}" \
                --region "${AWS_REGION}" 2>/dev/null || true
        done
        log "  Deleting route table ${rt_id}..."
        if aws ec2 delete-route-table \
                --route-table-id "${rt_id}" \
                --region "${AWS_REGION}" 2>/dev/null; then
            log "    ${rt_id} deleted."
        else
            log "    WARNING: could not delete ${rt_id}."
        fi
    done

    # Internet gateways — detach from VPC before deleting
    local igw_info
    igw_info=$(aws ec2 describe-internet-gateways \
        --region "${AWS_REGION}" \
        --filters "${filter}" \
        --query "InternetGateways[].[InternetGatewayId,Attachments[0].VpcId]" \
        --output text 2>/dev/null || true)
    while IFS=$'\t' read -r igw_id igw_vpc_id; do
        [[ -z "${igw_id}" ]] && continue
        if [[ -n "${igw_vpc_id}" && "${igw_vpc_id}" != "None" ]]; then
            aws ec2 detach-internet-gateway \
                --internet-gateway-id "${igw_id}" \
                --vpc-id "${igw_vpc_id}" \
                --region "${AWS_REGION}" 2>/dev/null || true
        fi
        log "  Deleting internet gateway ${igw_id}..."
        if aws ec2 delete-internet-gateway \
                --internet-gateway-id "${igw_id}" \
                --region "${AWS_REGION}" 2>/dev/null; then
            log "    ${igw_id} deleted."
        else
            log "    WARNING: could not delete ${igw_id}."
        fi
    done <<< "${igw_info}"

    # VPCs
    local vpc_ids
    vpc_ids=$(aws ec2 describe-vpcs \
        --region "${AWS_REGION}" \
        --filters "${filter}" \
        --query "Vpcs[].VpcId" \
        --output text 2>/dev/null || true)
    for vpc_id in ${vpc_ids}; do
        log "  Deleting VPC ${vpc_id}..."
        if aws ec2 delete-vpc \
                --vpc-id "${vpc_id}" \
                --region "${AWS_REGION}" 2>/dev/null; then
            log "    ${vpc_id} deleted."
        else
            log "    WARNING: could not delete ${vpc_id}."
        fi
    done

    log "Resource cleanup complete for BuildRunId=${run_id}."
}

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup on exit: stop the EC2 instance (keep all other resources).
# Use --delete to also terminate the instance and remove all AWS resources.
# ──────────────────────────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "${INSTANCE_ID}" ]]; then
        log "Stopping instance ${INSTANCE_ID} (reuse with: $0 ${INSTANCE_ID})..."
        aws ec2 stop-instances \
            --instance-ids "${INSTANCE_ID}" \
            --region "${AWS_REGION}" > /dev/null 2>&1 || \
            log "WARNING: could not stop ${INSTANCE_ID}."
    fi
    exit "${_EXIT_CODE}"
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--delete" ]]; then
    [[ -n "${2:-}" ]] || { echo "Usage: $0 --delete <instance-id>" >&2; _EXIT_CODE=1; exit 1; }
    _del_instance_id="${2}"

    # Retrieve the BuildRunId from the instance before terminating it
    _run_id=$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${_del_instance_id}" \
        --query "Reservations[0].Instances[0].Tags[?Key=='BuildRunId'].Value | [0]" \
        --output text 2>/dev/null || true)

    delete_instance "${_del_instance_id}"

    if [[ -n "${_run_id}" && "${_run_id}" != "None" ]]; then
        delete_run_resources "${_run_id}"
    else
        log "WARNING: No BuildRunId tag on ${_del_instance_id}. Cannot locate associated resources."
        log "  Search manually: aws ec2 describe-security-groups --region ${AWS_REGION} \\"
        log "    --filters 'Name=tag:CreatedBy,Values=${SCRIPT_NAME}'"
    fi
    exit 0
fi

# Resume an existing stopped instance when its ID is passed as the first argument.
# The instance ID takes precedence over AMI_ID/KEY_NAME for launch (no new instance).
RESUME_INSTANCE_ID=""
if [[ "${1:-}" =~ ^i-[0-9a-f]+$ ]]; then
    RESUME_INSTANCE_ID="${1}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Required (build mode only)
# ──────────────────────────────────────────────────────────────────────────────
: "${SSH_KEY_PATH:?SSH_KEY_PATH is required}"
if [[ -z "${RESUME_INSTANCE_ID}" ]]; then
    : "${KEY_NAME:?KEY_NAME is required (or pass an existing instance-id as first argument)}"
    : "${AMI_ID:?AMI_ID is required (or pass an existing instance-id as first argument)}"
fi

if [[ -n "${BAKE_TARGET}" ]]; then
    [[ "${BAKE_TARGET}" =~ ^(.+)_jdk([0-9]+)$ ]] \
        || { echo "ERROR: BAKE_TARGET '${BAKE_TARGET}' does not match '<flavor>-<version>_jdk<release>'." >&2; _EXIT_CODE=1; exit 1; }
    IMAGE_TYPES="${BASH_REMATCH[1]}"
    JAVA_RELEASES="${BASH_REMATCH[2]}"
fi

# Tee all output to a log file in /tmp for easier post-run inspection.
LOG_FILE="/tmp/build-windows-on-ec2-${RUN_ID}.log"
exec > >(tee "${LOG_FILE}") 2>&1
echo "Log: ${LOG_FILE}"

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ──────────────────────────────────────────────────────────────────────────────
log "Checking prerequisites..."
for cmd in aws ssh scp tar; do
    command -v "${cmd}" >/dev/null 2>&1 || { log "ERROR: '${cmd}' not found in PATH."; _EXIT_CODE=1; exit 1; }
done
[[ -f "${SSH_KEY_PATH}" ]] || { log "ERROR: SSH key not found: ${SSH_KEY_PATH}"; _EXIT_CODE=1; exit 1; }
aws sts get-caller-identity --region "${AWS_REGION}" > /dev/null
log "Prerequisites OK."

# ──────────────────────────────────────────────────────────────────────────────
# Resume mode: recover state from an existing stopped/running instance
# ──────────────────────────────────────────────────────────────────────────────
if [[ -n "${RESUME_INSTANCE_ID}" ]]; then
    log "Resuming instance ${RESUME_INSTANCE_ID}..."
    INSTANCE_ID="${RESUME_INSTANCE_ID}"

    _istate=$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${INSTANCE_ID}" \
        --query "Reservations[0].Instances[0].State.Name" \
        --output text)

    case "${_istate}" in
        stopped)
            log "  Instance is stopped — starting..."
            aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" > /dev/null
            log "  Waiting for instance to reach 'running' state..."
            aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
            log "  Waiting for instance status checks (2/2)..."
            aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
            ;;
        running) log "  Instance already running." ;;
        *)
            log "ERROR: Instance ${INSTANCE_ID} is in state '${_istate}' — cannot resume."
            _EXIT_CODE=1; exit 1
            ;;
    esac

    # Recover metadata from the running instance
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)
    log "  Instance at ${PUBLIC_IP}"

    RUN_ID=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query "Reservations[0].Instances[0].Tags[?Key=='BuildRunId'].Value | [0]" \
        --output text 2>/dev/null || true)
    [[ -n "${RUN_ID}" && "${RUN_ID}" != "None" ]] || RUN_ID="${SCRIPT_NAME}-resumed-$(date +%s)"
    log "Run ID: ${RUN_ID}"

    SUBNET_ID=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query "Reservations[0].Instances[0].SubnetId" \
        --output text)
    SECURITY_GROUP_ID=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
        --output text)
    VPC_ID=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query "Reservations[0].Instances[0].VpcId" \
        --output text)

    # Look up an existing EIC endpoint in the VPC (any create-complete one)
    EIC_ENDPOINT_ID=$(aws ec2 describe-instance-connect-endpoints \
        --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=create-complete" \
        --query "InstanceConnectEndpoints[0].InstanceConnectEndpointId" \
        --output text 2>/dev/null || true)
    [[ "${EIC_ENDPOINT_ID}" == "None" ]] && EIC_ENDPOINT_ID=""
    [[ -n "${EIC_ENDPOINT_ID}" ]] && log "  EIC endpoint: ${EIC_ENDPOINT_ID}"
else
    log "Run ID: ${RUN_ID}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# VPC — create a temporary one when no VPC/subnet/SG is provided
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${RESUME_INSTANCE_ID}" && -z "${SECURITY_GROUP_ID}" && -z "${VPC_ID}" && -z "${SUBNET_ID}" ]]; then
    log "No VPC/subnet/SG provided — creating a temporary VPC (10.250.0.0/24)..."

    VPC_ID=$(aws ec2 create-vpc \
        --region "${AWS_REGION}" \
        --cidr-block "10.250.0.0/24" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=wdb-tmp-vpc}]" \
        --query "Vpc.VpcId" \
        --output text)
    VPC_CREATED=true
    log "  VPC: ${VPC_ID}"

    aws ec2 modify-vpc-attribute \
        --region "${AWS_REGION}" \
        --vpc-id "${VPC_ID}" \
        --enable-dns-hostnames > /dev/null

    _igw_id=$(aws ec2 create-internet-gateway \
        --region "${AWS_REGION}" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=wdb-tmp-igw}]" \
        --query "InternetGateway.InternetGatewayId" \
        --output text)
    aws ec2 attach-internet-gateway \
        --region "${AWS_REGION}" \
        --internet-gateway-id "${_igw_id}" \
        --vpc-id "${VPC_ID}" > /dev/null
    log "  Internet gateway: ${_igw_id}"

    # Pick the first AZ that supports this instance type (avoids AZs that don't
    # offer the requested instance type for Windows workloads).
    _az=$(aws ec2 describe-instance-type-offerings \
        --region "${AWS_REGION}" \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
        --query "InstanceTypeOfferings[0].Location" \
        --output text)
    [[ -n "${_az}" && "${_az}" != "None" ]] \
        || { log "ERROR: No AZ found supporting ${INSTANCE_TYPE} in ${AWS_REGION}."; _EXIT_CODE=1; exit 1; }
    log "  Using availability zone: ${_az}"

    SUBNET_ID=$(aws ec2 create-subnet \
        --region "${AWS_REGION}" \
        --vpc-id "${VPC_ID}" \
        --cidr-block "10.250.0.0/24" \
        --availability-zone "${_az}" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=wdb-tmp-subnet}]" \
        --query "Subnet.SubnetId" \
        --output text)
    aws ec2 modify-subnet-attribute \
        --region "${AWS_REGION}" \
        --subnet-id "${SUBNET_ID}" \
        --map-public-ip-on-launch > /dev/null
    SUBNET_CREATED=true
    log "  Subnet: ${SUBNET_ID}"

    _rt_id=$(aws ec2 create-route-table \
        --region "${AWS_REGION}" \
        --vpc-id "${VPC_ID}" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=wdb-tmp-rtb}]" \
        --query "RouteTable.RouteTableId" \
        --output text)
    aws ec2 create-route \
        --region "${AWS_REGION}" \
        --route-table-id "${_rt_id}" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "${_igw_id}" > /dev/null
    aws ec2 associate-route-table \
        --region "${AWS_REGION}" \
        --route-table-id "${_rt_id}" \
        --subnet-id "${SUBNET_ID}" > /dev/null
    log "  Route table: ${_rt_id}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Security group — create a temporary one if not supplied (skip when resuming)
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${RESUME_INSTANCE_ID}" && -z "${SECURITY_GROUP_ID}" ]]; then
    if [[ -n "${SUBNET_ID}" && -z "${VPC_ID}" ]]; then
        VPC_ID=$(aws ec2 describe-subnets \
            --region "${AWS_REGION}" \
            --subnet-ids "${SUBNET_ID}" \
            --query "Subnets[0].VpcId" \
            --output text)
    fi
    [[ -n "${VPC_ID}" ]] \
        || { log "ERROR: provide SECURITY_GROUP_ID, VPC_ID, or SUBNET_ID."; _EXIT_CODE=1; exit 1; }

    log "Creating temporary security group in VPC ${VPC_ID}..."
    _sg_name="wdb-tmp-sg-$(date +%s)"
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --region "${AWS_REGION}" \
        --vpc-id "${VPC_ID}" \
        --group-name "${_sg_name}" \
        --description "Temporary: Windows Docker build SSH access (safe to delete)" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=${_sg_name}}]" \
        --query "GroupId" \
        --output text)
    # Allow SSH on port 22 from within the VPC only (EIC connects from VPC CIDR).
    # EC2 Launch v2 starts sshd on port 22; EIC tunnels to it via --remote-port 22.
    aws ec2 authorize-security-group-ingress \
        --region "${AWS_REGION}" \
        --group-id "${SECURITY_GROUP_ID}" \
        --protocol tcp --port 22 --cidr "10.250.0.0/24" > /dev/null
    SG_CREATED=true
    log "  Security group: ${SECURITY_GROUP_ID} (${_sg_name})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# EC2 Instance Connect Endpoint — created when we own the VPC (skip when resuming
# or when EIC_ENDPOINT_ID is provided via env; the resume block already looks one up).
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${RESUME_INSTANCE_ID}" && -z "${EIC_ENDPOINT_ID}" && "${VPC_CREATED}" == "true" && "${SG_CREATED}" == "true" ]]; then
    log "Creating EC2 Instance Connect Endpoint (SSH tunnel via AWS, no public port 22 needed from the internet)..."
    EIC_ENDPOINT_ID=$(aws ec2 create-instance-connect-endpoint \
        --region "${AWS_REGION}" \
        --subnet-id "${SUBNET_ID}" \
        --security-group-ids "${SECURITY_GROUP_ID}" \
        --tag-specifications "ResourceType=instance-connect-endpoint,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=wdb-tmp-eice}]" \
        --query "InstanceConnectEndpoint.InstanceConnectEndpointId" \
        --output text)
    EIC_CREATED=true
    log "  EIC endpoint: ${EIC_ENDPOINT_ID} (provisioning in background...)"
elif [[ -n "${EIC_ENDPOINT_ID}" && -z "${RESUME_INSTANCE_ID}" ]]; then
    log "Using existing EIC endpoint: ${EIC_ENDPOINT_ID}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Launch EC2 instance
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${RESUME_INSTANCE_ID}" ]]; then
    log "Launching Windows EC2 instance (type=${INSTANCE_TYPE}, AMI=${AMI_ID})..."
fi

# User-data: minimal — sshd is intentionally NOT configured here.
#
# User-data: installs Win32-OpenSSH from GitHub and starts sshd on port 22.
#
# Windows_Server-2025-English-Core-Base AMI has Win32-OpenSSH pre-installed in
# C:\Windows\System32\OpenSSH\ but requires configuration on first boot:
#   - sshd_config must have NO 'Match Group administrators' block (causes Win32-OpenSSH
#     9.x to close connections when evaluating group membership)
#   - Host key files must be OWNED by SYSTEM (not just have SYSTEM in ACL)
#   - Use IMDSv2 to fetch the EC2 key pair (IMDSv1 returns empty on this AMI)
#   - sftp-server.exe requires the full path
# sshd_config written as ASCII (not UTF-8 BOM) to avoid silent sshd startup failure.
# EIC connects via --remote-port 22.
#
# NOTE: pass raw text — the AWS CLI base64-encodes --user-data internally.
read -r -d '' _user_data <<'USERDATA_EOF' || true
<powershell>
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$sshDir = 'C:\ProgramData\ssh'

$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host 'sshd not found — installing via Windows capability...'
    try {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
        $svc = Get-Service sshd -ErrorAction SilentlyContinue
    } catch {
        Write-Host "WARNING: Add-WindowsCapability failed: $_ — trying GitHub fallback..."
        try {
            $zip = 'C:\openssh.zip'
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 `
                -Uri 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip' `
                -OutFile $zip
            Expand-Archive $zip -DestinationPath 'C:\Program Files' -Force
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            & 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1' 2>&1 | ForEach-Object { Write-Host "  install: $_" }
            $svc = Get-Service sshd -ErrorAction SilentlyContinue
        } catch {
            Write-Host "ERROR: OpenSSH install failed: $_"
        }
    }
}

if ($svc) {
    if (-not (Test-Path $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
    }

    # Write sshd_config as ASCII — UTF-8 BOM causes silent sshd startup failure.
    # No 'Match Group administrators' block: Win32-OpenSSH 9.x closes the connection
    # when evaluating group membership on incoming connects; global AuthorizedKeysFile works.
    $config = @(
        'Port 22',
        'ListenAddress 0.0.0.0',
        'HostKey __PROGRAMDATA__/ssh/ssh_host_rsa_key',
        'HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key',
        'AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys',
        'PubkeyAuthentication yes',
        'PasswordAuthentication no',
        'Subsystem sftp C:/Windows/System32/OpenSSH/sftp-server.exe'
    )
    [System.IO.File]::WriteAllLines("$sshDir\sshd_config", $config)
    Write-Host 'sshd_config written (ASCII, port 22, no Match block).'

    # Find ssh-keygen — prefer built-in Windows OpenSSH
    $keygen = if (Test-Path 'C:\Windows\System32\OpenSSH\ssh-keygen.exe') {
        'C:\Windows\System32\OpenSSH\ssh-keygen.exe'
    } elseif (Test-Path 'C:\Program Files\OpenSSH-Win64\ssh-keygen.exe') {
        'C:\Program Files\OpenSSH-Win64\ssh-keygen.exe'
    } else { 'ssh-keygen' }

    if (-not (Test-Path "$sshDir\ssh_host_ed25519_key")) {
        Write-Host 'Generating host keys...'
        & $keygen -A 2>&1 | ForEach-Object { Write-Host "  keygen: $_" }
    }

    # Fix host key ownership — Win32-OpenSSH 9.x requires SYSTEM as file owner,
    # not just SYSTEM in the ACL. icacls only sets ACEs; SetOwner() sets the owner SID.
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    foreach ($keyFile in (Get-ChildItem "$sshDir\ssh_host_*_key" -ErrorAction SilentlyContinue)) {
        $acl = Get-Acl $keyFile.FullName
        $acl.SetOwner($systemSid)
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $systemSid, 'FullControl', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $adminsSid, 'FullControl', 'Allow')))
        Set-Acl -Path $keyFile.FullName -AclObject $acl
        Write-Host "  Fixed ownership: $($keyFile.Name)"
    }

    # Inject EC2 key pair via IMDSv2 (IMDSv1 returns empty content on this AMI)
    try {
        $token = (Invoke-WebRequest -UseBasicParsing -Method PUT `
            -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='60'} `
            -TimeoutSec 10).Content
        $pubKey = (Invoke-WebRequest -UseBasicParsing `
            -Uri 'http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key' `
            -Headers @{'X-aws-ec2-metadata-token'=$token} `
            -TimeoutSec 10).Content.Trim()
        if ($pubKey -match '^ssh-') {
            $akFile = "$sshDir\administrators_authorized_keys"
            [System.IO.File]::WriteAllLines($akFile, @($pubKey))
            # Same SYSTEM-owner requirement applies to administrators_authorized_keys
            $akAcl = Get-Acl $akFile
            $akAcl.SetOwner($systemSid)
            $akAcl.SetAccessRuleProtection($true, $false)
            $akAcl.Access | ForEach-Object { $akAcl.RemoveAccessRule($_) }
            $akAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $systemSid, 'FullControl', 'Allow')))
            $akAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminsSid, 'FullControl', 'Allow')))
            Set-Acl -Path $akFile -AclObject $akAcl
            Write-Host 'EC2 public key injected (IMDSv2).'
        } else {
            Write-Host "WARNING: IMDSv2 pubkey response unexpected: $pubKey"
        }
    } catch { Write-Host "WARNING: key fetch failed: $_" }

    # PowerShell as default SSH shell
    $regPath = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    New-ItemProperty -Path $regPath -Name DefaultShell `
        -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -PropertyType String -Force | Out-Null

    # Firewall rule for port 22
    Remove-NetFirewallRule -Name 'sshd-22' -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'sshd-22' -DisplayName 'OpenSSH sshd (port 22)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Enabled True | Out-Null

    Set-Service  -Name sshd -StartupType Automatic
    Restart-Service sshd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $status = (Get-Service sshd -ErrorAction SilentlyContinue).Status
    Write-Host "sshd status: $status"

    # Install Windows Containers feature (required for Docker Engine).
    # Must happen after sshd is configured so SSH is available after the reboot.
    # The build script detects whether a reboot is still needed and re-polls SSH.
    $feat = Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue
    if ($feat -and -not $feat.Installed) {
        Write-Host 'Installing Windows Containers feature (will reboot)...'
        Install-WindowsFeature -Name Containers -ErrorAction SilentlyContinue
        Write-Host 'Containers feature installation queued. Rebooting...'
        Restart-Computer -Force
    } else {
        Write-Host 'Containers feature already installed (no reboot needed).'
    }

    Write-Host 'Setup complete.'
} else {
    Write-Host 'ERROR: sshd service not available after install attempt.'
}
</powershell>
USERDATA_EOF

if [[ -z "${RESUME_INSTANCE_ID}" ]]; then
    LAUNCH_ARGS=(
        --region "${AWS_REGION}"
        --image-id "${AMI_ID}"
        --instance-type "${INSTANCE_TYPE}"
        --key-name "${KEY_NAME}"
        --security-group-ids "${SECURITY_GROUP_ID}"
        --user-data "${_user_data}"
        --tag-specifications "ResourceType=instance,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=windows-docker-build}]"
        --query "Instances[0].InstanceId"
        --output text
    )
    [[ -n "${SUBNET_ID}" ]] && LAUNCH_ARGS+=(--subnet-id "${SUBNET_ID}")
    [[ -n "${IAM_INSTANCE_PROFILE}" ]] && LAUNCH_ARGS+=(--iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}")

    INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}")
    log "Launched: ${INSTANCE_ID}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Resource summary — printed early so the user can note IDs and the cleanup cmd
# ──────────────────────────────────────────────────────────────────────────────
log "──────────────────────────────────────────────────────"
log "AWS resources for this run (BuildRunId=${RUN_ID}):"
log "  EC2 instance   : ${INSTANCE_ID}  (stop on exit; --delete to remove all)"
[[ "${SG_CREATED}"     == "true" ]] && log "  Security group : ${SECURITY_GROUP_ID}  <- pass to --delete to remove"
[[ "${SUBNET_CREATED}" == "true" ]] && log "  Subnet         : ${SUBNET_ID}  <- pass to --delete to remove"
[[ "${VPC_CREATED}"    == "true" ]] && log "  VPC            : ${VPC_ID}  <- pass to --delete to remove"
[[ "${EIC_CREATED}"    == "true" ]] && log "  EIC endpoint   : ${EIC_ENDPOINT_ID}  <- pass to --delete to remove"
log ""
log "  To reuse this instance next run:"
log "    $0 ${INSTANCE_ID} ..."
log "  To remove all resources after this run:"
log "    $0 --delete ${INSTANCE_ID}"
log "──────────────────────────────────────────────────────"

# ──────────────────────────────────────────────────────────────────────────────
# Wait for instance running + status checks (skip when resuming — already done)
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${RESUME_INSTANCE_ID}" ]]; then
    log "Waiting for instance to reach 'running' state..."
    aws ec2 wait instance-running \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}"

    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)
    log "Instance running at ${PUBLIC_IP}"

    log "Waiting for instance status checks (2/2)..."
    aws ec2 wait instance-status-ok \
        --instance-ids "${INSTANCE_ID}" \
        --region "${AWS_REGION}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Wait for EIC endpoint to be ready (if we created one)
# ──────────────────────────────────────────────────────────────────────────────
if [[ -n "${EIC_ENDPOINT_ID}" ]]; then
    log "Waiting for EIC endpoint ${EIC_ENDPOINT_ID}..."
    for _i in $(seq 1 40); do
        _eice_state=$(aws ec2 describe-instance-connect-endpoints \
            --region "${AWS_REGION}" \
            --instance-connect-endpoint-ids "${EIC_ENDPOINT_ID}" \
            --query "InstanceConnectEndpoints[0].State" \
            --output text 2>/dev/null || echo "unknown")
        if [[ "${_eice_state}" == "create-complete" ]]; then
            log "  EIC endpoint ready."
            break
        elif [[ "${_eice_state}" == "create-failed" ]]; then
            log "ERROR: EIC endpoint ${EIC_ENDPOINT_ID} failed to create."
            _EXIT_CODE=1; exit 1
        fi
        if [[ "${_i}" -eq 40 ]]; then
            log "ERROR: EIC endpoint not ready after 10 minutes."
            _EXIT_CODE=1; exit 1
        fi
        log "  EIC state: ${_eice_state} — waiting 15s... (${_i}/40)"
        sleep 15
    done
fi

# ──────────────────────────────────────────────────────────────────────────────
# Wait for SSH
# ──────────────────────────────────────────────────────────────────────────────
log "Waiting for SSH (Windows boot takes several minutes after status check)..."
SSH_READY=false
for attempt in $(seq 1 60); do
    if ssh_run "echo ready" > /dev/null 2>&1; then
        SSH_READY=true
        break
    fi
    log "  SSH attempt ${attempt}/60 — retrying in 30s..."
    sleep 30
done
${SSH_READY} || { log "ERROR: SSH never became available."; _EXIT_CODE=1; exit 1; }
log "SSH is ready."

# ──────────────────────────────────────────────────────────────────────────────
# Ensure Windows Containers feature is installed (required for Docker Engine)
# ──────────────────────────────────────────────────────────────────────────────
log "Checking Windows Containers feature..."
_containers_state=$(ssh_run "powershell -NonInteractive -NoProfile -Command \
    \"try { if ((Get-WindowsFeature -Name Containers -ErrorAction Stop).Installed) {'yes'} else {'no'} } catch { 'unknown' }\"" \
    2>/dev/null || echo "unknown")
if [[ "${_containers_state}" != *yes* ]]; then
    log "  Containers feature not installed (state=${_containers_state}) — installing and rebooting..."
    ssh_run "powershell -NonInteractive -NoProfile -Command \
        \"Install-WindowsFeature -Name Containers -ErrorAction Stop; Restart-Computer -Force\"" \
        || true
    log "  Waiting 90s for instance to restart..."
    sleep 90
    SSH_READY=false
    for attempt in $(seq 1 40); do
        if ssh_run "echo ready" > /dev/null 2>&1; then
            SSH_READY=true
            break
        fi
        log "    SSH attempt ${attempt}/40 after Containers reboot — retrying in 30s..."
        sleep 30
    done
    ${SSH_READY} || { log "ERROR: SSH did not return after Containers reboot."; _EXIT_CODE=1; exit 1; }
    log "  Instance back after Containers reboot."
else
    log "  Containers feature already installed."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Install build dependencies
# ──────────────────────────────────────────────────────────────────────────────
log "Installing build dependencies (Docker ${DOCKER_VERSION}, yq, docker-compose, docker buildx)..."

SETUP_PS1=$(mktemp /tmp/setup-XXXXXX.ps1)
cat > "${SETUP_PS1}" << 'PS1_EOF'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Install-IfMissing {
    param([string]$Name, [string]$Url, [string]$Dest)
    if (-not (Test-Path $Dest)) {
        Write-Host "==> Installing $Name..."
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
        Write-Host "    installed: $Dest"
    } else {
        Write-Host "==> $Name already present: $Dest"
    }
}

# Install Docker Engine from GitHub releases (if not already present)
$dockerVersion = '__DOCKER_VERSION__'
$dockerPath = "$env:ProgramFiles\docker"
if (-not (Test-Path "$dockerPath\dockerd.exe")) {
    Write-Host "==> Installing Docker $dockerVersion..."
    $dockerZip = 'C:\docker.zip'
    Invoke-WebRequest -UseBasicParsing "https://download.docker.com/win/static/stable/x86_64/docker-$dockerVersion.zip" -OutFile $dockerZip
    Expand-Archive $dockerZip -DestinationPath $env:ProgramFiles -Force
    Remove-Item $dockerZip
    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($currentPath -notlike "*$dockerPath*") {
        [Environment]::SetEnvironmentVariable('Path', "$currentPath;$dockerPath", 'Machine')
    }
    $env:PATH = "$env:PATH;$dockerPath"
    & "$dockerPath\dockerd" --register-service
    Set-Service -Name docker -StartupType Automatic
    Start-Service docker
    Write-Host "    Docker $dockerVersion installed and started."
} else {
    Write-Host "==> Docker already present: $dockerPath"
    if ((Get-Service docker -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Start-Service docker
        Write-Host "    Docker service started."
    }
}

Install-IfMissing `
    -Name 'yq' `
    -Url 'https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_windows_amd64.exe' `
    -Dest 'C:\Windows\System32\yq.exe'

Install-IfMissing `
    -Name 'docker-compose' `
    -Url 'https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-windows-x86_64.exe' `
    -Dest 'C:\Windows\System32\docker-compose.exe'

$buildxDir = "$env:ProgramData\docker\cli-plugins"
New-Item -ItemType Directory -Force -Path $buildxDir | Out-Null
Install-IfMissing `
    -Name 'docker buildx' `
    -Url 'https://github.com/docker/buildx/releases/download/v0.20.1/buildx-v0.20.1.windows-amd64.exe' `
    -Dest "$buildxDir\docker-buildx.exe"

# Pre-install NuGet provider so Install-Module works in NonInteractive SSH sessions.
# Without this, Install-Module (used by build.ps1 for Pester) triggers an interactive
# ShouldContinue prompt that fails with "Windows PowerShell is in NonInteractive mode."
Write-Host '==> Installing NuGet package provider...'
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
Write-Host '    NuGet provider ready.'

Write-Host ''
Write-Host '==> Verifying tools...'
docker version | Select-Object -First 4
Write-Host ''
docker-compose version
docker buildx version
yq --version
Write-Host ''
Write-Host '==> All dependencies ready.'
PS1_EOF

# Inject the Docker version (portable: bash string substitution, no sed quirks)
_content=$(<"${SETUP_PS1}")
_content="${_content//__DOCKER_VERSION__/${DOCKER_VERSION}}"
printf '%s' "${_content}" > "${SETUP_PS1}"

scp_to "${SETUP_PS1}" "${SSH_USER}@${PUBLIC_IP}:C:/setup-deps.ps1"
rm -f "${SETUP_PS1}"
ssh_run "powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:/setup-deps.ps1"
ssh_run "powershell -NonInteractive -NoProfile -Command \"Remove-Item -Force C:/setup-deps.ps1\""

# ──────────────────────────────────────────────────────────────────────────────
# Package and upload repository
# ──────────────────────────────────────────────────────────────────────────────
log "Packaging repository..."
TMPTAR=$(mktemp /tmp/docker-ssh-agent-XXXXXX.tar.gz)
tar \
    --exclude='.git' \
    --exclude='target' \
    --exclude='bats' \
    --exclude='*.tar.gz' \
    -czf "${TMPTAR}" \
    -C "${REPO_DIR}" .
log "Repository packaged: $(du -sh "${TMPTAR}" | cut -f1)"

log "Uploading to ${PUBLIC_IP}..."
scp_to "${TMPTAR}" "${SSH_USER}@${PUBLIC_IP}:C:/repo.tar.gz"
rm -f "${TMPTAR}"

log "Extracting on remote..."
ssh_run "powershell -NonInteractive -NoProfile -Command \"\
    \$ErrorActionPreference='Stop'; \
    if (Test-Path '${REMOTE_WORK_DIR}') { Remove-Item -Recurse -Force '${REMOTE_WORK_DIR}' }; \
    New-Item -ItemType Directory -Path '${REMOTE_WORK_DIR}' | Out-Null; \
    tar -xzf C:/repo.tar.gz -C '${REMOTE_WORK_DIR}'; \
    Remove-Item -Force C:/repo.tar.gz; \
    Write-Host 'Repository extracted.'\""

# ──────────────────────────────────────────────────────────────────────────────
# Write build orchestrator script
# ──────────────────────────────────────────────────────────────────────────────
ORCHESTRATOR_PS1=$(mktemp /tmp/orchestrate-XXXXXX.ps1)

read -ra _image_types_arr  <<< "${IMAGE_TYPES}"
read -ra _java_releases_arr <<< "${JAVA_RELEASES}"
image_types_ps1=$(printf ", '%s'" "${_image_types_arr[@]}"  | cut -c3-)
java_releases_ps1=$(printf ", '%s'" "${_java_releases_arr[@]}" | cut -c3-)

cat > "${ORCHESTRATOR_PS1}" << PS1_EOF
\$ErrorActionPreference = 'Stop'
\$ProgressPreference  = 'SilentlyContinue'

\$imageTypes   = @(${image_types_ps1})
\$javaReleases = @(${java_releases_ps1})
\$workDir      = '${REMOTE_WORK_DIR}'
\$failed       = \$false

Set-Location \$workDir

foreach (\$imageType in \$imageTypes) {
    foreach (\$javaRelease in \$javaReleases) {
        Write-Host ''
        Write-Host ('=' * 60)
        Write-Host "BUILD  image_type=\$imageType  java_release=\$javaRelease"
        Write-Host ('=' * 60)

        \$env:IMAGE_TYPE            = \$imageType
        \$env:JAVA_RELEASE_OVERRIDE = \$javaRelease

        & "\$workDir\build.ps1" build
        if (\$LASTEXITCODE -ne 0) {
            Write-Host "ERROR: build failed for \$imageType jdk\$javaRelease"
            \$failed = \$true
            continue
        }

        Write-Host ''
        Write-Host ('=' * 60)
        Write-Host "TEST   image_type=\$imageType  java_release=\$javaRelease"
        Write-Host ('=' * 60)

        & "\$workDir\build.ps1" test
        if (\$LASTEXITCODE -ne 0) {
            Write-Host "ERROR: tests failed for \$imageType jdk\$javaRelease"
            \$failed = \$true
        }
    }
}

if (\$failed) {
    Write-Error 'One or more build/test steps failed.'
    exit 1
}

Write-Host ''
Write-Host 'All builds and tests completed successfully.'
exit 0
PS1_EOF

scp_to "${ORCHESTRATOR_PS1}" "${SSH_USER}@${PUBLIC_IP}:C:/orchestrate.ps1"
rm -f "${ORCHESTRATOR_PS1}"

# ──────────────────────────────────────────────────────────────────────────────
# Run builds and tests
# ──────────────────────────────────────────────────────────────────────────────
log "Starting build + test loop (IMAGE_TYPES='${IMAGE_TYPES}', JAVA_RELEASES='${JAVA_RELEASES}')..."
BUILD_EXIT=0
ssh_run "powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:/orchestrate.ps1" || BUILD_EXIT=$?
ssh_run "powershell -NonInteractive -NoProfile -Command \"Remove-Item -Force C:/orchestrate.ps1\"" || true

# ──────────────────────────────────────────────────────────────────────────────
# Retrieve test results
# ──────────────────────────────────────────────────────────────────────────────
log "Retrieving test results from remote..."
mkdir -p "${REPO_DIR}/target"
scp_to -r \
    "${SSH_USER}@${PUBLIC_IP}:${REMOTE_WORK_DIR}/target/." \
    "${REPO_DIR}/target/" 2>/dev/null \
    || log "WARNING: No test results to retrieve."

if [[ ${BUILD_EXIT} -ne 0 ]]; then
    log "ERROR: Build or tests failed (exit ${BUILD_EXIT}). See output above."
    _EXIT_CODE="${BUILD_EXIT}"; exit 1
fi

log "Done. Test results are in ${REPO_DIR}/target/"
log "To clean up remaining AWS resources: $0 --delete ${INSTANCE_ID}"
