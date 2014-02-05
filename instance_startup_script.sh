#!/bin/bash

# Key off existence of the "data" mount point to determine whether
# this is the first boot.
if [[ ! -e /mnt/data ]]; then
  # Basic setup - get the JRE installed
  apt-get update
  apt-get install --fix-broken
  #apt-get install --yes openjdk-6-jre
  #apt-get remove --yes openjdk*

  mkdir -p /mnt/data
fi

# If resource disk doesn't exist, create it
if [[ ! -e /mnt/resource ]]; then
   mkdir -p /mnt/resource
fi

# Get the master
MASTER=$(curl \
    "http://metadata/computeMetadata/v1/instance/attributes/cluster-master" \
    -H "X-Google-Metadata-Request: True")

# Get the device name of the "data" disk
DISK_DEV=$(basename $(readlink /dev/disk/by-id/google-$(hostname)-data))

# Get the device name of the "resource" disk
DISK_RES=$(basename $(readlink /dev/disk/by-id/google-$MASTER-resource))

# TO DO - add check here if resource disk exists
# Mount the data disk
/usr/share/google/safe_format_and_mount \
  -m "mkfs.ext4 -F" /dev/$DISK_DEV /mnt/data

# Mount the resource disk
/usr/share/google/safe_format_and_mount \
  -m "mkfs.ext4 -F" /dev/$DISK_RES /mnt/resource

chmod 777 /mnt/data
chmod 777 /mnt/resource

if [[ ! -e /mnt/share ]]; then
  HOSTNAME=$(hostname --short)
  if [[ "$MASTER" == "$HOSTNAME" ]]; then
    # Install gluster, create the volume, start the volume
    apt-get install --yes glusterfs-server
    /usr/sbin/gluster volume create share $MASTER:/mnt/data
    /usr/sbin/gluster volume start share
  else
    # Install glusterfs client
    apt-get install --yes glusterfs-client
  fi

  mkdir -p /mnt/share
fi

# All cluster members should mount the share in the same place for consistency
mount -t glusterfs $MASTER:/share /mnt/share

# Activate cosmos virtual environment
workon cosmos
