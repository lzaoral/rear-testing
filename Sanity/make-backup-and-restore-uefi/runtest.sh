#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-uefi
#   Description: Test basic functionality of ReaR on systems with UEFI.
#   Author: Lukáš Zaoral <lzaoral@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 - 2023 Red Hat, Inc.
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

PACKAGES="rear syslinux-extlinux grub2-tools-extra grub2-efi-x64-modules"
REAR_LABEL="${REAR_LABEL:-REAR-000}"
REAR_LABEL_PATH="/dev/disk/by-label/$REAR_LABEL"
HOSTNAME_SHORT="$(hostname --short)"

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

        rlPhaseStartSetup "Check that we are on a UEFI machine"
            rlRun "ls /sys/firmware/ | grep efi" \
                0 "Check that we are on UEFI machine"
            if [ $? -eq 1 ]; then
                rlDie "Machine without UEFI"
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Remove existing 'REAR' EFI boot entries"
            rlLog "Remove previous 'REAR' boot entries"
            for entry in $(efibootmgr | grep REAR | cut -c 5-8); do
                rlRun "efibootmgr -b $entry -B" 0 "Removing entry $entry"
            done

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: efibootmgr failed"
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Backup EFI boot variables"
            rlRun -l "efibootmgr | tee efibootmgr.bak" 0 "Create efibootmgr.bak"
            OLD_BOOT_ORDER="$(grep '^BootOrder' efibootmgr.bak | cut -d' ' -f2)"

            rlLog "#######################################################"
            rlLog "#####                   WARNING!                  #####"
            rlLog "#######################################################"
            rlLog "Beware that the BootOrder EFI variable may contain     "
            rlLog "unexpected values if ReaR or any tool it depends on    "
            rlLog "does something unexpected!  In such case, fix it before"
            rlLog "the machine is returned back to Beaker, otherwise it   "
            rlLog "will be corrupted.                                     "
            rlLog "                                                       "
            rlLog "If you can boot to some working instance of RHEL, use  "
            rlLog "the following command to fix it:                       "
            rlLog "                                                       "
            rlLog "efibootmgr --bootorder '$OLD_BOOT_ORDER'               "
            rlLog "                                                       "
            rlLog "Otherwise, set it directly in the firmware to the      "
            rlLog "following value:                                       "
            rlLog "                                                       "
            rlLog "$OLD_BOOT_ORDER                                        "

            rlAssertExists efibootmgr.bak
            rlFileSubmit efibootmgr.bak
        rlPhaseEnd

        rlPhaseStartSetup "Create /etc/rear/local.conf"
            rlFileBackup "/etc/rear/local.conf"
            rlRun -l "echo $'OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb://$REAR_LABEL_PATH
USER_INPUT_TIMEOUT=10
USB_UEFI_PART_SIZE=1024
POST_RECOVERY_SCRIPT=(
    \"efibootmgr -n \\\$(efibootmgr | grep BootOrder | cut -d\' \' -f2 | cut -d\',\' -f1);\"
    \"efibootmgr --bootorder \'$OLD_BOOT_ORDER\';\"
)' | tee /etc/rear/local.conf" \
                0 "Creating basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartTest "Select and prepare empty disk drive"
            # TODO: Reliable selection
            if [ "$(systemd-detect-virt)" = "kvm" ]; then
                REAR_ROOT=/dev/vdb
            else
                REAR_ROOT=/dev/sdb
            fi

            rlLog "Selected $REAR_ROOT"
            rlAssertExists "$REAR_ROOT"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_ROOT does not exist."
            fi

            rlRun -l "rear -d format -- -y --efi $REAR_ROOT" \
                0 "Partition and format $REAR_ROOT"

            rlAssertExists "$REAR_LABEL_PATH"
            rlAssertExists "/dev/disk/by-label/REAR-EFI"
            check_and_submit_rear_log format

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -d format -- -y --efi $REAR_ROOT failed. See rear-format.log for details."
            fi

            rlRun -l "lsblk | tee drive_layout.old" \
                0 "Store lsblk output in recovery image"
            rlAssertExists drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest "Run rear mkbackup"
            rlRun -l "rear -d mkbackup" \
                0 "Creating backup to $REAR_LABEL_PATH"
            check_and_submit_rear_log mkbackup
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -d mkbackup failed. See rear-mkbackup.log for details."
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Create dummy file"
            rlRun "touch recovery_will_remove_me" \
                0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        # TODO: should be configurable in /etc/rear/local.conf!!!
        rlPhaseStartSetup "Force ReaR rescue system to run unattended"
            rlRun "mkdir /mnt/rear" 0 "Create /mnt/rear"
            rlRun "mount LABEL=REAR-EFI /mnt/rear" \
                0 "Mount /dev/disk/by-label/REAR-EFI"

            # TODO: Will this work with SecureBoot?
            # Grub uses different default boot entry:
            # set default="0" -> set default="1"
            rlRun "sed -i '/^[ ]*linux/ s/$/ unattended/' \
                       /mnt/rear/EFI/BOOT/grub.cfg" \
                0 "Append 'unattended' to kernel command-line"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: failed to make the recovery unattended"
            fi
        rlPhaseEnd

        CONSOLE_DEVICE="$(cat /sys/class/tty/console/active)"
        rlPhaseStartSetup "Redirect ReaR output to $CONSOLE_DEVICE"
            KERNEL_CMDLINE="$(grubby --info="$(grubby --default-kernel)" | \
                              grep -Po '(?<=^args=").*(?="$)')"
            CONSOLE_CMDLINE="$(grep -Eo "console=$CONSOLE_DEVICE(,\w+)?" \
                               <<< "$KERNEL_CMDLINE")"

            # Workaround for machines that have an unused serial device
            # attached because by default ReaR will still try to use it for
            # output.
            NEW_CONSOLE_CMDLINE="$CONSOLE_CMDLINE"
            if [ -z "$NEW_CONSOLE_CMDLINE" ]; then
                NEW_CONSOLE_CMDLINE="console=$CONSOLE_DEVICE"
            fi

            rlRun "sed -i '/unattended/s/$/ $NEW_CONSOLE_CMDLINE/' \
                       /mnt/rear/EFI/BOOT/grub.cfg" \
                0 "Append '$NEW_CONSOLE_CMDLINE' to kernel command-line"

            rlRun "umount -R /mnt/rear" \
                0 "Unmount /dev/disk/by-label/REAR-EFI"
        rlPhaseEnd

        rlPhaseStartSetup "Force the machine to autoboot the ReaR rescue system"
            rlRun -l "efibootmgr --create --gpt --disk $REAR_ROOT --part 1 \
                                 --write-signature --label REAR \
                                 --loader '\EFI\BOOT\BOOTX64.efi'" \
                0 "Add 'REAR' entry to EFI"
            rlRun -l "efibootmgr --bootorder '$OLD_BOOT_ORDER'" \
                0 "Restore old boot order"

            # will find BootXXXX* REAR
            REAR_BOOT_ENTRY="$(efibootmgr | grep REAR | cut -c 5-8)"
            rlRun -l "efibootmgr --bootnext '$REAR_BOOT_ENTRY'" \
                0 "Set next boot entry to $REAR_BOOT_ENTRY"
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: efibootmgr failed"
            fi
        rlPhaseEnd

        # TODO: rhts-reboot sets BootNext
        reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # ReaR hopefully recovered the OS
        rlPhaseStartTest "Assert that the recovery was successful"
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists drive_layout.old
            rlAssertExists /root/rear*.log

            # check that ReaR did not overwrite itself
            rlAssertExists "$REAR_LABEL_PATH"
            rlAssertExists "/dev/disk/by-label/REAR-EFI"

            rlRun -l "lsblk | tee drive_layout.new" \
                0 "Get current lsblk output"
            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            check_and_submit_rear_log recover
        rlPhaseEnd

        rlPhaseStartCleanup
            rlLog "Remove created 'REAR' boot entries"
            for entry in $(efibootmgr | grep REAR | cut -c 5-8); do
                rlRun "efibootmgr -b $entry -B" 0 "Removing entry $entry"
            done

            OLD_BOOT_ORDER="$(grep '^BootOrder' efibootmgr.bak | cut -d' ' -f2)"
            rlRun -l "efibootmgr --bootorder '$OLD_BOOT_ORDER'" \
                0 "Restore old boot order"

            # TODO: Compare efibootmgr output?
            # ReaR creates a fresh EFI variable for the recovered system so the
            # output will not be a perfect match.

            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f efibootmgr.bak" 0 "Remove efibootmgr backup"
            rlRun "rm -rf /root/rear*.log /var/log/rear/*" 0 "Remove ReaR logs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
