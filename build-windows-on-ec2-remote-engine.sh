#!/usr/bin/env bash
# Builds Windows Docker images using a remote EC2 Windows Docker engine.
#
# How it differs from build-windows-on-ec2.sh:
#   - The remote EC2 is used as a Docker engine only — no yq, docker-compose, etc.
#     are needed for the build phase.
#   - An SSH tunnel exposes the remote Docker daemon locally.
#   - Local `docker buildx bake` drives the build; Docker sends the build context
#     automatically. No files are copied to the remote for the build phase.
#   - Built images stay on the remote daemon (Windows images cannot be pulled
#     to a Linux/macOS local daemon).
#   - Tests still run on the remote (build.ps1 test needs PowerShell + Pester).
#     Set SKIP_TESTS=true to skip the test phase entirely.
#
# LIFECYCLE
#   - On normal exit (success or failure): only the EC2 instance is terminated.
#     VPC, subnet, IGW, route table, and security group are kept so they can
#     be inspected or reused.
#   - Use --delete <instance-id> to also remove all other AWS resources that
#     were created in the same run (identified by the BuildRunId tag).
#
# When none of SECURITY_GROUP_ID / VPC_ID / SUBNET_ID are provided the script
# creates a minimal temporary VPC (CIDR 10.250.0.0/24) with one public subnet,
# an internet gateway, a route table, and a security group — all tagged with
# the same BuildRunId so --delete can find and remove them later.
#
# MODES
#   Build (default):
#     KEY_NAME=my-key AMI_ID=ami-... SSH_KEY_PATH=~/.ssh/my-key.pem \
#     BAKE_TARGET=nanoserver-ltsc2025_jdk25 \
#     ./build-windows-on-ec2-remote-engine.sh
#
#   Delete instance + all associated resources created in the same run:
#     ./build-windows-on-ec2-remote-engine.sh --delete i-0abcdef1234567890
#
# REQUIRED environment variables (build mode only):
#   KEY_NAME            EC2 key pair name
#   AMI_ID              Windows Server with Containers AMI
#   SSH_KEY_PATH        Local path to the .pem key file
#
# OPTIONAL environment variables:
#   SECURITY_GROUP_ID   Existing SG allowing TCP 22. Created if unset.
#   VPC_ID              VPC for the temporary SG. Derived from SUBNET_ID, or created if unset.
#   SUBNET_ID           Subnet for the instance. Created if unset.
#   INSTANCE_TYPE       EC2 instance type          (default: m5.xlarge)
#   SSH_USER            SSH user on the instance   (default: Administrator)
#   IAM_INSTANCE_PROFILE IAM instance profile name (default: none)
#   AWS_PROFILE         AWS CLI profile to use     (default: none / current env)
#   AWS_REGION          AWS region                 (default: us-east-1)
#   BAKE_TARGET         Single bake target, e.g. "nanoserver-ltsc2025_jdk25".
#                       Overrides IMAGE_TYPES and JAVA_RELEASES when set.
#   IMAGE_TYPES         Space-separated list of Windows image flavors to build
#                       (default: "windowsservercore-ltsc2022 nanoserver-ltsc2022")
#   JAVA_RELEASES       Space-separated list of Java major versions to build
#                       (default: "21")
#   SKIP_TESTS          Skip the test phase entirely   (default: false)

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Optional vars
# ──────────────────────────────────────────────────────────────────────────────
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.xlarge}"
SSH_USER="${SSH_USER:-Administrator}"
SUBNET_ID="${SUBNET_ID:-}"
VPC_ID="${VPC_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
BAKE_TARGET="${BAKE_TARGET:-}"
IMAGE_TYPES="${IMAGE_TYPES:-windowsservercore-ltsc2022 nanoserver-ltsc2022}"
JAVA_RELEASES="${JAVA_RELEASES:-21}"
SKIP_TESTS="${SKIP_TESTS:-false}"

[[ -n "${AWS_PROFILE}" ]] && export AWS_PROFILE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_WORK_DIR='C:/docker-ssh-agent'
SCRIPT_NAME="build-windows-on-ec2-remote-engine.sh"

INSTANCE_ID=""
PUBLIC_IP=""
SSH_TUNNEL_PID=""
DOCKER_CONTEXT_NAME=""
DOCKER_BUILDER_NAME=""
# Random high port for the local end of the SSH tunnel (avoids colliding with
# a local Docker daemon that may already use 2375)
LOCAL_DOCKER_PORT=$(( 40000 + RANDOM % 10000 ))

# Unique ID that ties every AWS resource created in this run together.
# Stored as tag BuildRunId on all resources so --delete can find them.
RUN_ID="${SCRIPT_NAME}-$(date +%s)"

# Track what was created (for the resource summary printed early in the run)
SG_CREATED=false
SUBNET_CREATED=false
VPC_CREATED=false

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }

ssh_run() {
    ssh -i "${SSH_KEY_PATH}" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=10 \
        "${SSH_USER}@${PUBLIC_IP}" "$@"
}

scp_to() {
    scp -i "${SSH_KEY_PATH}" \
        -o StrictHostKeyChecking=no \
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
# Cleanup on exit: close the local SSH tunnel and remove the local Docker
# context/builder. All AWS resources (instance, SG, VPC, etc.) are kept
# until --delete is explicitly called.
# ──────────────────────────────────────────────────────────────────────────────
cleanup() {
    local rc=$?
    [[ -n "${DOCKER_BUILDER_NAME}" ]] \
        && docker buildx rm "${DOCKER_BUILDER_NAME}" 2>/dev/null || true
    [[ -n "${DOCKER_CONTEXT_NAME}" ]] \
        && docker context rm "${DOCKER_CONTEXT_NAME}" 2>/dev/null || true
    if [[ -n "${SSH_TUNNEL_PID}" ]]; then
        kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
        log "SSH tunnel closed."
    fi
    exit "${rc}"
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--delete" ]]; then
    [[ -n "${2:-}" ]] || { echo "Usage: $0 --delete <instance-id>" >&2; exit 1; }
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

# ──────────────────────────────────────────────────────────────────────────────
# Required (build mode only)
# ──────────────────────────────────────────────────────────────────────────────
: "${KEY_NAME:?KEY_NAME is required}"
: "${AMI_ID:?AMI_ID is required}"
: "${SSH_KEY_PATH:?SSH_KEY_PATH is required}"

if [[ -n "${BAKE_TARGET}" ]]; then
    [[ "${BAKE_TARGET}" =~ ^(.+)_jdk([0-9]+)$ ]] \
        || { echo "ERROR: BAKE_TARGET '${BAKE_TARGET}' does not match '<flavor>-<version>_jdk<release>'." >&2; exit 1; }
    IMAGE_TYPES="${BASH_REMATCH[1]}"
    JAVA_RELEASES="${BASH_REMATCH[2]}"
fi

# Derive bake target names: IMAGE_TYPES x JAVA_RELEASES
read -ra _image_types_arr  <<< "${IMAGE_TYPES}"
read -ra _java_releases_arr <<< "${JAVA_RELEASES}"
BAKE_TARGETS=()
for _it in "${_image_types_arr[@]}"; do
    for _jr in "${_java_releases_arr[@]}"; do
        BAKE_TARGETS+=("${_it}_jdk${_jr}")
    done
done

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ──────────────────────────────────────────────────────────────────────────────
log "Checking prerequisites..."
for cmd in aws ssh scp docker tar; do
    command -v "${cmd}" >/dev/null 2>&1 || { log "ERROR: '${cmd}' not found in PATH."; exit 1; }
done
docker buildx version > /dev/null 2>&1 \
    || { log "ERROR: 'docker buildx' not available. Install Docker Buildx plugin."; exit 1; }
[[ -f "${SSH_KEY_PATH}" ]] || { log "ERROR: SSH key not found: ${SSH_KEY_PATH}"; exit 1; }
aws sts get-caller-identity --region "${AWS_REGION}" > /dev/null
log "Prerequisites OK."
log "Run ID: ${RUN_ID}"

# ──────────────────────────────────────────────────────────────────────────────
# VPC — create a temporary one when no VPC/subnet/SG is provided
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${SECURITY_GROUP_ID}" && -z "${VPC_ID}" && -z "${SUBNET_ID}" ]]; then
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
        || { log "ERROR: No AZ found supporting ${INSTANCE_TYPE} in ${AWS_REGION}."; exit 1; }
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
# Security group — create a temporary one if not supplied
# ──────────────────────────────────────────────────────────────────────────────
if [[ -z "${SECURITY_GROUP_ID}" ]]; then
    if [[ -n "${SUBNET_ID}" && -z "${VPC_ID}" ]]; then
        VPC_ID=$(aws ec2 describe-subnets \
            --region "${AWS_REGION}" \
            --subnet-ids "${SUBNET_ID}" \
            --query "Subnets[0].VpcId" \
            --output text)
    fi
    [[ -n "${VPC_ID}" ]] \
        || { log "ERROR: provide SECURITY_GROUP_ID, VPC_ID, or SUBNET_ID."; exit 1; }

    log "Creating temporary security group in VPC ${VPC_ID}..."
    _sg_name="wdb-tmp-sg-$(date +%s)"
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --region "${AWS_REGION}" \
        --vpc-id "${VPC_ID}" \
        --group-name "${_sg_name}" \
        --description "Temporary: Windows Docker engine SSH access (safe to delete)" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=${_sg_name}}]" \
        --query "GroupId" \
        --output text)
    aws ec2 authorize-security-group-ingress \
        --region "${AWS_REGION}" \
        --group-id "${SECURITY_GROUP_ID}" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null
    SG_CREATED=true
    log "  Security group: ${SECURITY_GROUP_ID} (${_sg_name})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Launch EC2 instance
# ──────────────────────────────────────────────────────────────────────────────
log "Launching Windows EC2 instance (type=${INSTANCE_TYPE}, AMI=${AMI_ID})..."

# User-data: install Win32-OpenSSH (direct GitHub download, no Windows Update needed)
# and start sshd. EC2 Launch v2 injects the key pair public key automatically.
# This is a no-op if sshd is already running (idempotent).
# NOTE: pass raw text — the AWS CLI base64-encodes --user-data internally.
read -r -d '' _user_data <<'USERDATA_EOF' || true
<powershell>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# No-op if sshd is already installed and running
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') { exit 0 }

if (-not $svc) {
    # Install Win32-OpenSSH from GitHub (avoids Windows Update / capability store)
    $zip = 'C:\openssh.zip'
    Invoke-WebRequest -Uri 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v10.0.0.0p2-Preview/OpenSSH-Win64.zip' `
        -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath 'C:\Program Files' -Force
    Remove-Item $zip
    & 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1'
    New-NetFirewallRule -Name 'sshd' -DisplayName 'OpenSSH SSH Server' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Enabled True | Out-Null
}

New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -PropertyType String -Force | Out-Null

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
</powershell>
USERDATA_EOF

LAUNCH_ARGS=(
    --region "${AWS_REGION}"
    --image-id "${AMI_ID}"
    --instance-type "${INSTANCE_TYPE}"
    --key-name "${KEY_NAME}"
    --security-group-ids "${SECURITY_GROUP_ID}"
    --user-data "${_user_data}"
    --tag-specifications "ResourceType=instance,Tags=[{Key=BuildRunId,Value=${RUN_ID}},{Key=CreatedBy,Value=${SCRIPT_NAME}},{Key=Name,Value=windows-docker-engine}]"
    --query "Instances[0].InstanceId"
    --output text
)
[[ -n "${SUBNET_ID}" ]] && LAUNCH_ARGS+=(--subnet-id "${SUBNET_ID}")
[[ -n "${IAM_INSTANCE_PROFILE}" ]] && LAUNCH_ARGS+=(--iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}")

INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}")
DOCKER_CONTEXT_NAME="win-ec2-${INSTANCE_ID}"
DOCKER_BUILDER_NAME="win-builder-${INSTANCE_ID}"
log "Launched: ${INSTANCE_ID}"

# ──────────────────────────────────────────────────────────────────────────────
# Resource summary — printed early so the user can note IDs and the cleanup cmd
# ──────────────────────────────────────────────────────────────────────────────
log "──────────────────────────────────────────────────────"
log "AWS resources for this run (BuildRunId=${RUN_ID}):"
log "  EC2 instance   : ${INSTANCE_ID}  <- kept; pass to --delete to remove"
[[ "${SG_CREATED}"     == "true" ]] && log "  Security group : ${SECURITY_GROUP_ID}  <- kept; pass to --delete to remove"
[[ "${SUBNET_CREATED}" == "true" ]] && log "  Subnet         : ${SUBNET_ID}  <- kept; pass to --delete to remove"
[[ "${VPC_CREATED}"    == "true" ]] && log "  VPC            : ${VPC_ID}  <- kept; pass to --delete to remove"
log ""
log "  To remove all resources after this run:"
log "    $0 --delete ${INSTANCE_ID}"
log "──────────────────────────────────────────────────────"

# ──────────────────────────────────────────────────────────────────────────────
# Wait for instance running + status checks
# ──────────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────────
# Wait for SSH
# ──────────────────────────────────────────────────────────────────────────────
log "Waiting for SSH (Windows boot takes several minutes after status check)..."
SSH_READY=false
for attempt in $(seq 1 40); do
    if ssh_run "echo ready" > /dev/null 2>&1; then
        SSH_READY=true
        break
    fi
    log "  SSH attempt ${attempt}/40 — retrying in 30s..."
    sleep 30
done
${SSH_READY} || { log "ERROR: SSH never became available."; exit 1; }
log "SSH is ready."

# ──────────────────────────────────────────────────────────────────────────────
# Configure remote Docker daemon to also listen on TCP loopback,
# then open an SSH tunnel so local Docker CLI can reach it.
# ──────────────────────────────────────────────────────────────────────────────
log "Configuring remote Docker daemon for TCP access on localhost..."
ssh_run "powershell -NonInteractive -NoProfile -Command \"\
    \$ErrorActionPreference = 'Stop'; \
    \$cfg = 'C:/ProgramData/docker/config/daemon.json'; \
    New-Item -ItemType Directory -Force -Path (Split-Path \$cfg) | Out-Null; \
    '{\"hosts\":[\"npipe://\",\"tcp://127.0.0.1:2375\"]}' | Set-Content -Path \$cfg; \
    Restart-Service docker; \
    Start-Sleep 5; \
    Write-Host 'Docker daemon restarted with TCP listener.'\""

log "Opening SSH tunnel: localhost:${LOCAL_DOCKER_PORT} -> remote:2375..."
ssh -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    -N -L "${LOCAL_DOCKER_PORT}:127.0.0.1:2375" \
    "${SSH_USER}@${PUBLIC_IP}" &
SSH_TUNNEL_PID=$!

# Give the tunnel a moment to establish, then verify it works
sleep 3
DOCKER_HOST="tcp://127.0.0.1:${LOCAL_DOCKER_PORT}" docker info > /dev/null \
    || { log "ERROR: Docker TCP tunnel could not reach the remote daemon."; exit 1; }
log "Docker tunnel established (local port ${LOCAL_DOCKER_PORT})."

# ──────────────────────────────────────────────────────────────────────────────
# Create Docker context + buildx builder backed by the remote engine
# ──────────────────────────────────────────────────────────────────────────────
log "Creating Docker context '${DOCKER_CONTEXT_NAME}'..."
docker context create "${DOCKER_CONTEXT_NAME}" \
    --docker "host=tcp://127.0.0.1:${LOCAL_DOCKER_PORT}"

log "Creating buildx builder '${DOCKER_BUILDER_NAME}'..."
docker buildx create \
    --name "${DOCKER_BUILDER_NAME}" \
    --driver docker \
    --platform windows/amd64 \
    "${DOCKER_CONTEXT_NAME}"

# ──────────────────────────────────────────────────────────────────────────────
# Build — docker sends the local repo as build context to the remote engine
# ──────────────────────────────────────────────────────────────────────────────
log "Building targets: ${BAKE_TARGETS[*]}"
log "(build context is sent from $(pwd) to the remote engine)"
BUILD_EXIT=0
docker buildx bake \
    --builder "${DOCKER_BUILDER_NAME}" \
    --file "${REPO_DIR}/docker-bake.hcl" \
    "${BAKE_TARGETS[@]}" || BUILD_EXIT=$?

if [[ ${BUILD_EXIT} -ne 0 ]]; then
    log "ERROR: Build failed (exit ${BUILD_EXIT}). See output above."
    exit "${BUILD_EXIT}"
fi
log "Build complete. Images are available on the remote engine."

# ──────────────────────────────────────────────────────────────────────────────
# Test phase — runs build.ps1 test on the remote
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_TESTS}" == "true" ]]; then
    log "SKIP_TESTS=true — skipping test phase."
else
    log "Installing test dependencies on remote (yq, docker-compose, docker buildx)..."
    TEST_SETUP_PS1=$(mktemp /tmp/test-setup-XXXXXX.ps1)
    cat > "${TEST_SETUP_PS1}" << 'PS1_EOF'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Install-IfMissing {
    param([string]$Name, [string]$Url, [string]$Dest)
    if (-not (Test-Path $Dest)) {
        Write-Host "==> Installing $Name..."
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    } else {
        Write-Host "==> $Name already present."
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

Write-Host '==> Test dependencies ready.'
PS1_EOF
    scp_to "${TEST_SETUP_PS1}" "${SSH_USER}@${PUBLIC_IP}:C:/test-setup.ps1"
    rm -f "${TEST_SETUP_PS1}"
    ssh_run "powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:/test-setup.ps1"
    ssh_run "powershell -NonInteractive -NoProfile -Command \"Remove-Item -Force C:/test-setup.ps1\""

    log "Uploading repository for test phase..."
    TMPTAR=$(mktemp /tmp/docker-ssh-agent-XXXXXX.tar.gz)
    tar \
        --exclude='.git' \
        --exclude='target' \
        --exclude='bats' \
        --exclude='*.tar.gz' \
        -czf "${TMPTAR}" \
        -C "${REPO_DIR}" .
    scp_to "${TMPTAR}" "${SSH_USER}@${PUBLIC_IP}:C:/repo.tar.gz"
    rm -f "${TMPTAR}"
    ssh_run "powershell -NonInteractive -NoProfile -Command \"\
        \$ErrorActionPreference='Stop'; \
        if (Test-Path '${REMOTE_WORK_DIR}') { Remove-Item -Recurse -Force '${REMOTE_WORK_DIR}' }; \
        New-Item -ItemType Directory -Path '${REMOTE_WORK_DIR}' | Out-Null; \
        tar -xzf C:/repo.tar.gz -C '${REMOTE_WORK_DIR}'; \
        Remove-Item -Force C:/repo.tar.gz\""

    read -ra _image_types_arr  <<< "${IMAGE_TYPES}"
    read -ra _java_releases_arr <<< "${JAVA_RELEASES}"
    image_types_ps1=$(printf ", '%s'" "${_image_types_arr[@]}"  | cut -c3-)
    java_releases_ps1=$(printf ", '%s'" "${_java_releases_arr[@]}" | cut -c3-)

    TEST_PS1=$(mktemp /tmp/test-orchestrate-XXXXXX.ps1)
    cat > "${TEST_PS1}" << PS1_EOF
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
        Write-Host "TEST  image_type=\$imageType  java_release=\$javaRelease"
        Write-Host ('=' * 60)

        \$env:IMAGE_TYPE            = \$imageType
        \$env:JAVA_RELEASE_OVERRIDE = \$javaRelease

        & "\$workDir\build.ps1" test
        if (\$LASTEXITCODE -ne 0) {
            Write-Host "ERROR: tests failed for \$imageType jdk\$javaRelease"
            \$failed = \$true
        }
    }
}

if (\$failed) { Write-Error 'One or more test steps failed.'; exit 1 }
Write-Host 'All tests completed successfully.'
exit 0
PS1_EOF
    scp_to "${TEST_PS1}" "${SSH_USER}@${PUBLIC_IP}:C:/test-orchestrate.ps1"
    rm -f "${TEST_PS1}"

    log "Running tests on remote..."
    TEST_EXIT=0
    ssh_run "powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:/test-orchestrate.ps1" \
        || TEST_EXIT=$?
    ssh_run "powershell -NonInteractive -NoProfile -Command \"Remove-Item -Force C:/test-orchestrate.ps1\"" \
        || true

    log "Retrieving test results..."
    mkdir -p "${REPO_DIR}/target"
    scp_to -r \
        "${SSH_USER}@${PUBLIC_IP}:${REMOTE_WORK_DIR}/target/." \
        "${REPO_DIR}/target/" 2>/dev/null \
        || log "WARNING: No test results to retrieve."

    if [[ ${TEST_EXIT} -ne 0 ]]; then
        log "ERROR: Tests failed. See output above."
        exit 1
    fi
fi

log "Done. Images built on remote engine: ${BAKE_TARGETS[*]}"
[[ "${SKIP_TESTS}" != "true" ]] && log "Test results: ${REPO_DIR}/target/"
log "To clean up remaining AWS resources: $0 --delete ${INSTANCE_ID}"
