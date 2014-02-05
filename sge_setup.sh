#!/bin/bash

# Copyright 2014 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# This script is a generic cluster bring-up script.
#
# In its current implementation, there is an assumption that
# there is one or more "master" instances and one or more "worker"
# or "execution" instances.
#
# This script is intended as a sample and can be used for small cluster
# bring-up.  For larger clusters, the serial nature of this script is
# less desirable.
#
# * Disks can be created in parallel with "gcutil adddisk"
# * Instances can be started in parallel by backgrounding "gcutil addinstance"
#   calls
# * Instances can be configured on start using a startup-script,
#   rather than using "gcutil ssh" as is done here
#   (see https://developers.google.com/compute/docs/howtos/startupscript)
#
# The names of the hosts can be controlled with the MASTER_HOST_NAME_PATTERN
# and the EXECUTION_HOST_NAME_PATTERN.
#
# The number of hosts can be controlled with the MASTER_HOST_COUNT
# and the EXECUTION_HOST_COUNT.
#
# To use this script review and update the "readonly" parameters
# below. Then run:
#
#   ./sge_setup.sh up-full   # Full bring-up (including disks)
#   ./sge_setup.sh down-full # Full teardown (including disks)
#
#   ./sge_setup.sh up        # Bring-up assumes disks exist
#   ./sge_setup.sh down      # Teardown does not destroy disks
#
# So a common model would be:
#
# First bring up:
#   ./sge_setup.sh up-full
#
# Repeat:
#   Bring-down:
#     ./sge_setup.sh down
#
#   Bring-up:
#     ./sge_setup.sh up
#
# Note that this sample script does not create snapshots of disks, but
# simply brings down instances without destroying the disks.  Snapshot
# cost at present is just over 3x per GB versus disk costs.  So if your
# disks are at least 1/3 full, it is more cost effective to simply preserve
# disks across instance restarts, rather than create snasphots.
#

set -o errexit
set -o nounset

# Select a prefix for the instance names in your cluster
readonly CLUSTER_PREFIX=cosmos-sge

# Instance names will be of the form:
#   Master:     my-sge-mm
#   Exec hosts: my-sge-eh-<number>
#
readonly MASTER_HOST_NAME_PATTERN="${CLUSTER_PREFIX}-mm"
readonly EXECUTION_HOST_NAME_PATTERN="${CLUSTER_PREFIX}-eh-%d"
readonly ZONE=us-central1-b

# By default all hosts will be 4 core standard instances
# in the zone us-central1-a, running debian-7
readonly MASTER_HOST_MACHINE_TYPE=n1-highmem-4
readonly MASTER_HOST_ZONE=$ZONE
readonly MASTER_HOST_IMAGE=cosmos-master-4-v14
readonly MASTER_HOST_DISK_SIZE_GB=500

readonly EXECUTION_HOST_MACHINE_TYPE=n1-highmem-4
readonly EXECUTION_HOST_ZONE=$ZONE
readonly EXECUTION_HOST_IMAGE=cosmos-slave-v14
readonly EXECUTION_HOST_DISK_SIZE_GB=500

# The name of a snapshot to create an optional resource disk
# Leave empty (e.g., "" to skip), mounted as read only
readonly RESOURCE_DISK="gatk-bundle-v3"

# Specify the number of execution hosts (default 1)
readonly MASTER_HOST_COUNT=1
readonly EXECUTION_HOST_COUNT=3

### Begin functions

function master_host_name() {
  local instance_id="$1"
  printf $MASTER_HOST_NAME_PATTERN $instance_id
}
readonly -f master_host_name

function execution_host_name() {
  local instance_id="$1"
  printf $EXECUTION_HOST_NAME_PATTERN $instance_id
}
readonly -f execution_host_name

function master_host_list() {
  local list=""
  for ((i=0; i < $MASTER_HOST_COUNT; i++)); do
    local name=$(master_host_name $i)
    list="$list $name"
  done

  echo -n $list
}
readonly -f master_host_list

function execution_host_list() {
  local list=""
  for ((i=1; i <= $EXECUTION_HOST_COUNT; i++)); do
    local name=$(execution_host_name $i)
    list="$list $name"
  done

  echo -n $list
}
readonly -f execution_host_list

function add_master_host() {
  local name="$1"
  local full="$2"
  local resource_disk="$3"

  local network=$(network_name)

  if [[ $full == 1 ]]; then
    gcutil adddisk "${name}" \
      --zone=$MASTER_HOST_ZONE \
      --source_image=$MASTER_HOST_IMAGE

    gcutil adddisk "${name}-data" \
      --zone=$MASTER_HOST_ZONE \
      --size_gb=$MASTER_HOST_DISK_SIZE_GB
    
    # If user has specified to attach a resource disk
    if ! [[ -z "$resource_disk" ]]; then
      gcutil adddisk "${name}-resource" \
        --zone=$MASTER_HOST_ZONE \
        --source_snapshot=$resource_disk
    fi
  fi

  # If we have a resource disk
  if ! [[ -z "$resource_disk" ]]; then
    gcutil addinstance "$name" \
      --zone=$MASTER_HOST_ZONE \
      --disk="${name},boot" \
      --disk="${name}-data" \
      --disk="${name}-resource,mode=READ_ONLY" \
      --machine_type=$MASTER_HOST_MACHINE_TYPE \
      --network=$network \
      --metadata="cluster-master:${name}" \
      --metadata_from_file=startup-script:instance_startup_script.sh \
      --service_account_scopes=https://www.googleapis.com/auth/devstorage.full_control
  
  else # if we don't have a resource disk
    gcutil addinstance "$name" \
      --zone=$MASTER_HOST_ZONE \
      --disk="${name},boot" \
      --disk="${name}-data" \
      --machine_type=$MASTER_HOST_MACHINE_TYPE \
      --network=$network \
      --metadata="cluster-master:${name}" \
      --metadata_from_file=startup-script:instance_startup_script.sh \
      --service_account_scopes=https://www.googleapis.com/auth/devstorage.full_control
  fi
}
readonly -f add_master_host

function add_execution_host() {
  local name="$1"
  local masters="$2"
  local full="$3"
  local resource_disk="$4"

  local network=$(network_name)

  if [[ $full == 1 ]]; then
    gcutil adddisk "${name}" \
      --zone=$EXECUTION_HOST_ZONE \
      --source_image=$EXECUTION_HOST_IMAGE

    gcutil adddisk "${name}-data" \
      --zone=$EXECUTION_HOST_ZONE \
      --size_gb=$EXECUTION_HOST_DISK_SIZE_GB
  fi

  # If we have a resource disk
  if ! [[ -z "$resource_disk" ]]; then
    gcutil addinstance "$name" \
      --zone=$EXECUTION_HOST_ZONE \
      --disk="${name},boot" \
      --disk="${name}-data" \
      --disk="${masters}-resource,mode=READ_ONLY" \
      --machine_type=$EXECUTION_HOST_MACHINE_TYPE \
      --network=$network \
      --metadata="cluster-master:${masters}" \
      --metadata_from_file=startup-script:instance_startup_script.sh \
      --service_account_scopes=https://www.googleapis.com/auth/devstorage.full_control
  else
    gcutil addinstance "$name" \
      --zone=$EXECUTION_HOST_ZONE \
      --disk="${name},boot" \
      --disk="${name}-data" \
      --machine_type=$EXECUTION_HOST_MACHINE_TYPE \
      --network=$network \
      --metadata="cluster-master:${masters}" \
      --metadata_from_file=startup-script:instance_startup_script.sh \
      --service_account_scopes=https://www.googleapis.com/auth/devstorage.full_control
  fi
}
readonly -f add_execution_host

function delete_host () {
  local name="$1"
  local full="$2"

  if ! gcutil deleteinstance "$name" --force --nodelete_boot_pd; then
    echo "Instance $name does not exist"
  fi

  if [[ $full == 1 ]]; then
    if ! gcutil deletedisk "$name" --force; then
      echo "Disk $name does not exist"
    fi
    if ! gcutil deletedisk "${name}-data" --force; then
      echo "Disk ${name}-data does not exist"
    fi
    if ! gcutil deletedisk "${name}-resource" --force; then
      echo "Disk ${name}-resource does not exist"
    fi
  fi
}
readonly -f delete_host

function network_name() {
  echo -n "default"  # Just use the default network
}
readonly -f network_name

### End functions

### Begin MAIN execution

# Grab the operation (up | down) from the command line
readonly OPERATION=${1:-}

readonly MASTER_HOST_LIST=$(master_host_list)
readonly EXECUTION_HOST_LIST=$(execution_host_list)

declare full=0
if [[ $OPERATION =~ -full$ ]]; then
  full=1
fi

if [[ $OPERATION =~ ^up ]]; then
  for host in $MASTER_HOST_LIST; do
    add_master_host "$host" "$full" "$RESOURCE_DISK"
  done

  for host in $EXECUTION_HOST_LIST; do
    add_execution_host "$host" "$MASTER_HOST_LIST" "$full" "$RESOURCE_DISK"
  done

  # Emit list of hosts in the cluster:
  gcutil listinstances --filter="name eq '.*"${CLUSTER_PREFIX}"-.*'"

elif [[ $OPERATION =~ ^down ]]; then
  
  # We must delete execs first, otherwise resource disk doesn't get deleted
  for host in $EXECUTION_HOST_LIST; do
    delete_host "$host" "$full"
  done

  for host in $MASTER_HOST_LIST; do
    delete_host "$host" "$full"
  done
else
  echo "Usage: $(basename $0) [up-full | up | down-full | down]"
  exit 1
fi

### End MAIN execution
