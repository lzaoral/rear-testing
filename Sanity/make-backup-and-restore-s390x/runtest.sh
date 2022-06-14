#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-s390x
#   Description: Test basic functionality of ReaR on s390x machines.
#   Author: Lukáš Zaoral <lzaoral@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2022 - 2023 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGES="rear s390utils"
REAR_LABEL="${REAR_LABEL:-REAR-000}"
REAR_LABEL_PATH="/dev/disk/by-label/$REAR_LABEL"
HOSTNAME_SHORT="$(hostname --short)"
NFS_SERVER="${NFS_SERVER:-""}"

check_and_submit_rear_log() {
    local path="/var/log/rear/rear-$HOSTNAME_SHORT.log"
    if [ "$1" = "recover" ]; then
        # recover log is only in /root and has a similar name like
        # rear-2022-05-18T01:03:48-04:00.log
        path="/root/rear-*.log"
    fi

    local log_prefix='\d{4}(-\d{2}){2} (\d{2}:){2}\d{2}\.\d{9}'

    local warnings errors
    warnings="$(grep -C 10 -P "$log_prefix WARNING:" $path)"
    errors="$(grep -C 10 -P "$log_prefix ERROR:" $path)"

    if [ -n "$warnings" ]; then
        rlFail "rear-$1.log contains some warnings"
        rlLog "$warnings"
    fi

    if [ -n "$errors" ]; then
        rlFail "rear-$1.log contains some errors"
        rlLog "$errors"
    fi

    rlFileSubmit $path "rear-$1.log"
}

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup "Assert that all required RPMs are installed"
            rlAssertRpm --all
        rlPhaseEnd

        rlPhaseStartSetup "Check that the NFS_SERVER variable is set"
            if [ -z "$NFS_SERVER" ]; then
                rlDie "NFS_SERVER was not specified!"
            fi

            if ! rlRun -l "ping -c1 '$NFS_SERVER'" 0 "Ping $NFS_SERVER"; then
                rlDie "$NFS_SERVER is not reachable!"
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Check that we are on an s390x machine"
            MACHINE="$(uname -m)"
            if [ "$MACHINE" != s390x ]; then
                rlDie "Not an s390x machine! Got: $MACHINE"
            fi
            rlPass "Got s390x machine!"
        rlPhaseEnd

        rlPhaseStartSetup "Create /etc/rear/local.conf"
            rlFileBackup "/etc/rear/local.conf"
            rlRun -l "echo 'OUTPUT=IPL
OUTPUT_URL=file://\$ISO_DIR
BACKUP=NETFS
BACKUP_URL=nfs://$NFS_SERVER/mnt/rear
USER_INPUT_TIMEOUT=10
POST_RECOVERY_SCRIPT=( \"chreipl \${TARGET_FS_ROOT}/boot\" )
PROGS+=( chreipl )' | tee /etc/rear/local.conf" \
                0 "Creating basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartSetup "Backup boot order"
            rlRun -l "lsreipl | tee bootorder.bak" 0 "Backup bootorder"

            rlAssertExists bootorder.bak
            rlFileSubmit bootorder.bak
        rlPhaseEnd

        rlPhaseStartSetup "Select and prepare empty disk device"
            # TODO: disk selection
            REAR_DEVICE="0.0.0121"
            rlRun "grep -v $REAR_DEVICE /etc/dasd.conf" \
                0 "Assert that $REAR_DEVICE is unused"

            rlRun -l "echo $REAR_DEVICE | tee -a /etc/dasd.conf" \
                0 "Add $REAR_DEVICE to dasd.conf"
            rlRun "cio_ignore -r $REAR_DEVICE" \
                0 "Make $REAR_DEVICE visible to Linux"
            rlRun "udevadm settle" 0 "Wait for udev"

            rlAssertExists "/dev/disk/by-path/ccw-$REAR_DEVICE"
            REAR_ROOT="$(realpath /dev/disk/by-path/ccw-$REAR_DEVICE)"
            rlLog "Selected $REAR_ROOT"
            rlAssertExists "$REAR_ROOT"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: disk selection failed!"
            fi

            # TODO: this is just a work-around for the fact that ReaR formats
            # every DASD it finds and wipefs does not remove partition table
            # on DASDs, so remove any trace of partitions on $REAR_ROOT from
            # the lsblk output.  Otherwise, the comparison after successful
            # recovery would have failed.
            #
            # Ideally, this check should be performed after we prepare the
            # drive for ReaR.
            rlRun -l "lsblk | \
                      grep -v -E '$(basename "$REAR_ROOT")[[:digit:]]+' | \
                      tee drive_layout.old" \
                0 "Store lsblk output in the recovery image"
            rlAssertExists drive_layout.old

            rlRun "fdasd -a '$REAR_ROOT'" 0 "Erase $REAR_ROOT"
            rlRun "mkfs.ext3 '${REAR_ROOT}1' -L '$REAR_LABEL'" \
                0 "Format ${REAR_ROOT}1 with ext3 and $REAR_LABEL label"
            rlRun "udevadm settle" 0 "Wait for udev"

            rlAssertExists "$REAR_LABEL_PATH"
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: formatting $REAR_ROOT failed!"
            fi
        rlPhaseEnd

        rlPhaseStartTest "Run rear mkbackup"
            rlRun -l "rear -d mkbackup" \
                0 "Creating rescue image and backup"
            check_and_submit_rear_log mkbackup

            RESCUE_IMAGE_PATH="/var/lib/rear/output/$HOSTNAME_SHORT"
            rlAssertExists "$RESCUE_IMAGE_PATH/"vmlinuz-*.el*.s390x
            rlAssertExists "$RESCUE_IMAGE_PATH/initrd.cgz"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -d mkbackup failed. See rear-mkbackup.log for details."
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Create dummy file"
            rlRun "touch recovery_will_remove_me" \
                0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartSetup "Force the machine to autoboot the ReaR rescue system"
            rlRun "mkdir /mnt/rear" 0 "Create /mnt/rear"
            rlRun "mount LABEL=$REAR_LABEL /mnt/rear" \
                0 "Mount $REAR_LABEL_PATH"

            rlRun "cp $RESCUE_IMAGE_PATH/* /mnt/rear" \
                0 "Copy rescue image to $REAR_LABEL_PATH"

            rlRun "zipl -t /mnt/rear \
                        -i /mnt/rear/vmlinuz-*.el*.s390x \
                        -r /mnt/rear/initrd.cgz \
                        -P 'root=/dev/ram0 ro unattended'" \
                0 "Install bootloader to $REAR_ROOT"
            rlRun -l "chreipl /mnt/rear" \
                0 "Set $REAR_LABEL_PATH as the reboot device"

            rlRun "umount -R /mnt/rear" \
                0 "Unmount $REAR_LABEL_PATH"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: Failed to create rescue image at $REAR_LABEL_PATH"
            fi
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # ReaR hopefully recovered the OS
        rlPhaseStartTest "Assert that the recovery was successful"
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists bootorder.bak
            rlAssertExists drive_layout.old
            rlAssertExists /root/rear*.log

            # FIXME: at the moment, rear recover wipes every DASD :(
            # check that ReaR did not overwrite itself
            # rlAssertExists "$REAR_LABEL_PATH"

            rlRun -l "lsblk | tee drive_layout.new" \
                0 "Get current lsblk output"
            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            check_and_submit_rear_log recover
        rlPhaseEnd

        rlPhaseStartCleanup
            rlRun "chreipl /boot" 0 "Restore reboot device"

            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f bootorder.bak" 0 "Remove bootorder backup"
            rlRun "rm -rf /root/rear*.log /var/log/rear/*" 0 "Remove ReaR logs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
