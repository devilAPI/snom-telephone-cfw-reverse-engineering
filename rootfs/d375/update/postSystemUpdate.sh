#!/bin/sh

# Set the given setting for an identity in config.xml
#  $1 - setting name
#  $2 - setting value
#  $3 - identity index (1..12)
#  $4 - setting permission
#  $5 - only update a setting when already existing
#
function setConfigArraySetting() {
    local settingName=$1
    local settingValue=$2
    local settingIndex="idx=\"$3\""
    local settingPerm="perm=\"$4\""
    local updateOnly=$5
    local org="/snom/snomconfig/config.xml"
    local tmp="/tmp/config.xml"
    local didIt=0

    while read -r i; do
        if [ "${i#</phone-settings>}" != "$i" ] && [ -z $updateOnly ] && [ $didIt -eq 0 ]; then
            echo "<$settingName $settingIndex $settingPerm c=\"1\">$settingValue</$settingName>"
            echo "$i"
            didIt=1
        elif [ "${i#<$settingName}" != "$i" ] && [ "${i/$settingIndex/}" != "$i" ]; then
            echo "<$settingName $settingIndex $settingPerm c=\"1\">$settingValue</$settingName>"
            didIt=1
        else
            echo "$i"
        fi
    done < $org > $tmp
    cp $tmp $org
    rm -f $tmp
}

# When upgrading from a non-UC to a UC firmware version, the codec_priority_list setting
# for each identity must be set to UC-specific default values. New phones are delivered
# with a non-UC firmware version and then get updated. This can lead to problems with
# wrong codecs being used in Lync environments.
#
function repairCodecPriorityList() {
  # Default codec list for 715
  local CODEC_LIST="g722,pcmu,pcma,gsm,g729,telephone-event"
  # Check which version (SIP/UC) was installed prior to update
  local preType=`cat /tmp/pre_update 2>/dev/null`
  # Check updated version
  local postType=""
  if [ -f /snom/html/ocs.htm ]; then
    postType="UC"
  else
    postType="SIP"
  fi

  # Update path SIP -> UC needs correction...
  if [ "$preType" = "SIP" ] && [ "$postType" = "UC" ]; then
    for i in {1..12}; do
      # setting default codec prio list for 720/760
      setConfigArraySetting "codec_priority_list" $CODEC_LIST $i "" "1"
    done
  fi
}

# Update openvpn binary only if openvpn binary already exists.
# As we don't want to include an executable openvpn binary to phones which don't use
# openvpn, the openvpn binary is stored uuencoded as /usr/container.
function updateOpenVPNBinary() {
  local VPN_CONTAINER="/usr/container"
  local VPN_BINARY="/sbin/openvpn"
  if [ -e $VPN_CONTAINER ]; then
    if [ -e $VPN_BINARY ]; then
      uudecode -o $VPN_BINARY $VPN_CONTAINER
      chmod 755 $VPN_BINARY
    fi
    # Always remove container file.
    rm -f $VPN_CONTAINER
  fi
}

# As we produced Broadcom devices without using the special 8-Bit BCH ECC for the boot1 paritition as required by
# boot0 (ROM), we have to check ECC for the boot1 partition and reflash the partition with the correct ECC in case
# the wrong one is currently used.
function fixBoot1Ecc() {
  local BOOT1_DEVICE="/dev/mtd0"
  local BOOT1_UPDATE_IMG="/update/boot1_update.bin"
  local BOOT1_DUMP_FILE="/tmp/boot1_page0.bin"
  local UBOOT_ENV_OFFSET="0x180000"
  if [ -e $BOOT1_UPDATE_IMG ]; then
    # Dump page 0 from boot1 partition into file.
    nanddump -o -n -f $BOOT1_DUMP_FILE -l 0x2000 $BOOT1_DEVICE
    # Check dump.
    boot1check $BOOT1_DUMP_FILE $UBOOT_ENV_OFFSET
    result=$?
    if [ $result -eq 0 ]; then
      echo "Boot1 partition already uses correct 8-Bit BCH ECC"
    elif [ $result -eq 1 ] || [ $result -eq 2 ]; then
      echo "Boot1 partition uses the wrong ECC, reflash boot1 partition"
      flash_eraseall $BOOT1_DEVICE
      nandwrite -o -n -N $BOOT1_DEVICE $BOOT1_UPDATE_IMG
    else
      echo "boot1check returned error code $result"
    fi
  else
    echo "Boot1 update image $BOOT1_UPDATE_IMG is missing"
  fi
}

# The main function. Everything is started from here!
function startUp () {
  repairCodecPriorityList
  updateOpenVPNBinary
  fixBoot1Ecc
}

# Ignore SIGTERM, SIGQUIT, SIGINT, SIGHUP
trap "" SIGTERM
trap "" SIGQUIT
trap "" SIGINT
trap "" SIGHUP

startUp
