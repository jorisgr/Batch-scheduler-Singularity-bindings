#!/bin/bash

# Get system-specific bindings to use.
CONFIG=scheduler-bindings.conf
source ${CONFIG} || { echo ${CONFIG} not found. Make sure to correctly link or create it: "ln -sf <machine>.conf scheduler-bindings.conf"; exit; }
echo Will use: $(readlink scheduler-bindings.conf)

# Print host system information relevant for debugging.
echo linux kernel $(uname --kernel-release) || {}
sinfo --version || {}

# Check if Singularity is available.
singularity --version || { echo Singularity not found... exiting.; exit; }

# Get Singularity image path.
# https://stackoverflow.com/a/25535717

ORIGINAL_SINGULARITY_COMMAND="$@" # Optional.
echo Will execute: ${ORIGINAL_SINGULARITY_COMMAND}

# Parse Singularity command to find the image/sandbox
IMAGE=""
FOUND_SUBCOMMAND=false
SKIP_NEXT=false

for arg in "$@"; do
    if [[ "$SKIP_NEXT" == true ]]; then
        SKIP_NEXT=false
        continue
    fi
    
    # Skip singularity binary and flags
    if [[ "$arg" == "singularity" ]]; then
        continue
    elif [[ "$arg" == --* ]]; then
        # Check if this flag takes a value
        if [[ "$arg" == "--bind" || "$arg" == "--env-file" || "$arg" == "--cwd" ]]; then
            SKIP_NEXT=true
        fi
        continue
    elif [[ "$arg" == -* ]]; then
        continue
    fi
    
    # If we haven't found a subcommand yet, this is it
    if [[ "$FOUND_SUBCOMMAND" == false ]]; then
        FOUND_SUBCOMMAND=true
        continue
    fi
    
    # Next non-flag argument after subcommand should be the image
    if [[ -f "$arg" || -d "$arg" ]]; then
        IMAGE="$arg"
        break
    fi
done

# Verify it's a valid .sif file or sandbox directory
if [[ "$IMAGE" == *.sif ]]; then
    # Check if .sif file exists
    if [[ ! -f "$IMAGE" ]]; then
        echo "SIF file '$IMAGE' not found. Exiting..."; 
        exit 1; 
    fi
elif [[ -d "$IMAGE" ]]; then
    # It's a directory (sandbox)
    echo "Using sandbox directory: $IMAGE"
else
    echo "Last argument '$IMAGE' is not a valid .sif file or sandbox directory. Exiting..."; 
    exit 1; 
fi

echo Enable host SLURM user for: ${IMAGE}

# Prepare binding of the system-specific SLURM user.
#
# We'll filter the host system users and if there is a SLURM user, we'll add it to the
# /etc/passwd and /etc/group files used in the container.
# 
# This is done similar to how Singularity iself enables the calling user inside the container environment:
# First, get the /etc/passwd and /etc/groups from the container image,
# then append users and groups and bind these when the container is finally started.

# For the manually assembled /etc/passwd and /etc/group files we'll create a temporary directory
# that'll be deleted automatically once the script exists successfully.
TEMPDIR=$(mktemp -d $(pwd)/tmp.XXXXXXXX)
echo Temporary directory: ${TEMPDIR}
trap "echo Deleting: ${TEMPDIR}; rm -rf ${TEMPDIR}" 0

# Extract user and group info from container and (maybe) append the SLURM user.
singularity exec ${IMAGE} cp -p /etc/passwd ${TEMPDIR}/etc_passwd
singularity exec ${IMAGE} cp -p /etc/group ${TEMPDIR}/etc_group
grep slurm /etc/passwd >> ${TEMPDIR}/etc_passwd
grep slurm /etc/group >> ${TEMPDIR}/etc_group

# Note that if system users are not managed in /etc/... we could use getent:
# getent passwd | grep slurm >> ${TEMPDIR}/etc_passwd
# getent group | grep slurm >> ${TEMPDIR}/etc_group

# Relative bind paths are necessary because of how file system overlays are handled.
RTEMPDIR=$(basename $TEMPDIR)

MERGED_PASSWD_GROUP="\
${RTEMPDIR}/etc_passwd:/etc/passwd,\
${RTEMPDIR}/etc_group:/etc/group\
"

# Setup Singularity bind mount and (library) path environment.

if [[ ! -z "$SCHEDULER_PREPEND_PATH" ]]; then
export SINGULARITYENV_PREPEND_PATH=${SCHEDULER_PREPEND_PATH}${SINGULARITYENV_PREPEND_PATH:+:$SINGULARITYENV_PREPEND_PATH}
echo SINGULARITYENV_PREPEND_PATH: "${SINGULARITYENV_PREPEND_PATH}"
fi

if [[ ! -z "${SCHEDULER_LD_LIBRARY_PATH}" ]]; then
export SINGULARITYENV_LD_LIBRARY_PATH=${SCHEDULER_LD_LIBRARY_PATH}${SINGULARITYENV_LD_LIBRARY_PATH:+:$SINGULARITYENV_LD_LIBRARY_PATH}
echo SINGULARITYENV_LD_LIBRARY_PATH: "${SINGULARITYENV_LD_LIBRARY_PATH}"
fi

SINGULARITY_BIND=${SCHEDULER_COMMANDS},${SCHEDULER_SYSTEM_SPECS}
SINGULARITY_BIND=${SINGULARITY_BIND},${MERGED_PASSWD_GROUP}

# Add DNS resolution files for SLURM service discovery probably not necessary
# SINGULARITY_BIND=${SINGULARITY_BIND},/etc/resolv.conf,/etc/hosts

export SINGULARITY_BIND

echo SINGULARITY_BIND: "${SINGULARITY_BIND}"

# Execute original Singularity command.

${ORIGINAL_SINGULARITY_COMMAND}
