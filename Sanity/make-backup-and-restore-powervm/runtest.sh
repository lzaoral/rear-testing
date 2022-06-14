#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-powervm
#   Description: Test basic functionality of ReaR on Power{,K}VM machines.
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

PACKAGES="rear powerpc-utils xorriso"
REAR_LABEL="${REAR_LABEL:-RELAXRECOVER}"
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

        rlPhaseStartSetup "Check that we are on a PowerVM or PowerKVM machine"
            # We use the same procedure that ReaR uses for machine detection.
            MACHINE="$(uname -m)"
            if [ "$MACHINE" != ppc64le ]; then
                rlDie "Not a ppc64le machine! Got: $MACHINE"
            fi

            if [ "$(awk '/platform/ {print $NF}' < /proc/cpuinfo)" = PowerNV ]; then
                rlDie "Got PowerNV machine!"
            fi

            if grep -q "emulated by qemu" /proc/cpuinfo ; then
                rlPass "Got PowerKVM machine!"
            else
                rlPass "Got PowerVM machine!"
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Backup NVRAM entries"
            # TODO: backup whole /dev/nvram???
            rlRun -l "nvram --print-config | tee nvram.bak" \
                0 "Backup NVRAM entries"

            rlLog "Backup original boot order"
            rlRun -l "nvram --print-config=boot-device | tee bootorder.bak" \
                0 "Backup original boot order"

            rlLog "#######################################################"
            rlLog "#####                   WARNING!                  #####"
            rlLog "#######################################################"
            rlLog "Beware that the contents of 'boot-device' NVRAM entry  "
            rlLog "may become corrupted if ReaR or any tool it depends on "
            rlLog "does something unexpected!  In such case, fix it before"
            rlLog "the machine is returned back to Beaker, otherwise it   "
            rlLog "will be corrupted.                                     "
            rlLog "                                                       "
            rlLog "If you can boot to some working instance of RHEL, use  "
            rlLog "the following command to fix it:                       "
            rlLog "                                                       "
            rlLog "nvram -p common --update-config 'boot-device=$(cat bootorder.bak)'"
            rlLog "                                                       "
            rlLog "Otherwise, set it directly in the firmware to the      "
            rlLog "following value:                                       "
            rlLog "                                                       "
            rlLog " $(cat bootorder.bak) "
            rlLog "                                                       "
            rlLog "The whole NVRAM backup is also present in the submitted"
            rlLog "'bootorder.bak' file.                                  "

            rlAssertExists bootorder.bak
            rlAssertExists nvram.bak

            rlFileSubmit bootorder.bak
            rlFileSubmit nvram.bak
        rlPhaseEnd

        rlPhaseStartSetup "Create /etc/rear/local.conf"
            rlFileBackup "/etc/rear/local.conf"
            rlRun -l "echo $'OUTPUT=ISO
OUTPUT_URL=null
BACKUP=NETFS
BACKUP_URL=iso://backup
USER_INPUT_TIMEOUT=10
ISO_DEFAULT=automatic
POST_RECOVERY_SCRIPT=(
    \"test -c /dev/nvram || modprobe nvram;\"
    \"nvram -p common --update-config \'boot-device=$(cat bootorder.bak)\';\"
)
AUTOEXCLUDE_MULTIPATH=n
MIGRATION_MODE=${MIGRATION_MODE-n}
ISO_RECOVER_MODE=unattended' | tee /etc/rear/local.conf" \
                0 "Creating basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartSetup "Select and prepare empty disk drive"
            # TODO: disk selection
            REAR_ROOT="/dev/sdb"
            rlLog "Selected $REAR_ROOT"
            rlAssertExists "$REAR_ROOT"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_ROOT does not exist."
            fi

            # Use --raw as the size column would otherwise have a different
            # width after the ISO was applied to $REAR_ROOT.  Even though the
            # output would be still correct.
            rlRun -l "lsblk --raw | tee drive_layout.old" \
                0 "Store lsblk output in recovery image"
            rlAssertExists drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest "Run rear mkbackup"
            rlRun -l "rear -d mkbackup" 0 "Creating backup ISO"
            check_and_submit_rear_log mkbackup
            rlAssertExists "/var/lib/rear/output/rear-$HOSTNAME_SHORT.iso"

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
        rlPhaseStartSetup "Force ReaR rescue system to run unattended and apply the image to $REAR_ROOT"
            rlRun "xorriso -dev '/var/lib/rear/output/rear-$HOSTNAME_SHORT.iso' \
                           -osirrox on -cpx /boot/grub/grub.cfg $PWD/grub.cfg" \
                0 "Get grub.cfg from the ISO image"
            rlRun "sed -i '/^[[:blank:]]*linux/s/$/ unattended/' grub.cfg" \
                0 "Add 'unattended' to kernel cmdline"
            rlRun "xorriso -indev '/var/lib/rear/output/rear-$HOSTNAME_SHORT.iso' \
                           -update $PWD/grub.cfg /boot/grub/grub.cfg -outdev - | \
                      dd of=$REAR_ROOT" \
                0 "Update grub.cfg and apply ISO to $REAR_ROOT"

            rlRun "sync" 0 "Sync all writes"
            rlRun "udevadm settle" 0 "Wait for udev"

            rlAssertExists "$REAR_LABEL_PATH"
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: Applying ISO to $REAR_ROOT failed"
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Force the machine to autoboot the ReaR rescue system"
            OFPATH_REAR="$(ofpathname "$REAR_ROOT")"
            rlLog "$REAR_ROOT Open Firmware path: $OFPATH_REAR"

            if grep -q "emulated by qemu" /proc/cpuinfo ; then
                # PowerKVM
                :
                # you have to boot manually at the moment :(

                # PowerKVM completely ignores boot-device nvram variable!!!
                # TODO: Is always boot-device in 'common' partition?
                # rlRun "nvram -p common --update-config boot-device='$OFPATH_REAR'" \
                #    0 "Set boot-device to $OFPATH_REAR"
            else
                # PowerVM
                BOOTLIST_CMD="bootlist -m normal -r"

                OFPATH_LAST_BOOTED="$(nvram --print-config=ibm,last-booted)"
                rlLog "Last booted path: $OFPATH_LAST_BOOTED"

                # Let bootlist to load the new boot order from a file
                # so that we don't have to deal with whitespaces.
                rlRun -l "$BOOTLIST_CMD | \
                          sed 's|$OFPATH_LAST_BOOTED|$OFPATH_REAR\n$OFPATH_LAST_BOOTED|' | \
                          tee expected_new_boot_order" \
                    0 "Generate new boot order"

                # LAN has to be first! If ReaR corrupted the machine and haven't
                # changed the boot order yet, the machine would remain broken as
                # Beaker expects the machine to always boot from LAN first.
                rlRun -l "$BOOTLIST_CMD -f expected_new_boot_order" \
                    0 "Set new bootorder"

                # Sanity check that bootlist did not botch setting the new boot
                # order. Happens on all RHEL 7 releases at the moment.
                rlRun -l "$BOOTLIST_CMD | tee current_boot_order" \
                    0 "Get the new bootorder"
                if ! rlAssertNotDiffer current_boot_order expected_new_boot_order; then
                    rlLogWarning "Bootlist botched the bootorder entry!"
                    rlRun -l "diff -u expected_new_boot_order current_boot_order" \
                        1 "Diff current and expected boot order"

                    # If powerpc-utils-1.3.4-14.el7 or newer are used, there
                    # will be only a minor difference in the network
                    # configuration.  It will contain the following extra
                    # suffix:
                    #
                    # :speed=auto,duplex=auto,0.0.0.0,,0.0.0.0,0.0.0.0
                    #
                    # This difference does not influence booting from disks
                    # in any way.  However, it's enough to completely break
                    # booting from the network!
                    if ! grep -q "^$(head -n 1 expected_new_boot_order)" \
                                <(head -n 1 current_boot_order)          \
                    || ! cmp -s <(tail -n +2 expected_new_boot_order)    \
                                <(tail -n +2 current_boot_order); then
                        rlRun "nvram -p common --update-config \
                                     'boot-device=$(cat bootorder.bak)'" \
                            0 "Set original boot-device"

                        rlDie "Bootlist binary is broken! Stopping so that ReaR does not destroy this VM."
                    fi

                    rlLogWarning "#######################################################"
                    rlLogWarning "#####                   WARNING!                  #####"
                    rlLogWarning "#######################################################"
                    rlLogWarning "The difference made by bootlist only breaks booting    "
                    rlLogWarning "from the network.  Therefore, test will continue.      "
                    rlLogWarning "                                                       "
                    rlLogWarning "However, if something unexpected happens, be sure to   "
                    rlLogWarning "check and restore the 'boot-list' NVRAM entry to its   "
                    rlLogWarning "original state as ReaR rescue image uses bootlist to   "
                    rlLogWarning "manipulate the boot order!                             "
                    rlLogWarning "                                                       "
                    rlLogWarning "The original contents and the guide how to restore them"
                    rlLogWarning "are present in a warning printed at the beginning of   "
                    rlLogWarning "this test.                                             "

                    # Use nvram instead of bootlist to minimise the risk of destroying this VM
                    rlRun "nvram -p common --update-config \
                                 'boot-device=$(paste -d ' ' -s expected_new_boot_order)'" \
                        0 "Set expected boot-device using nvram"
                fi
            fi
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # ReaR hopefully recovered the OS
        rlPhaseStartTest "Assert that the recovery was successful"
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists bootorder.bak
            rlAssertExists nvram.bak
            rlAssertExists drive_layout.old
            rlAssertExists /root/rear*.log

            # check that ReaR did not overwrite itself
            rlAssertExists "$REAR_LABEL_PATH"
            REAR_DEV="$(realpath "$REAR_LABEL_PATH" | xargs basename)"

            # dd changes disk layout so skip $REAR_DEV as we already know that
            # ReaR did not overwrite itself
            rlLog "ReaR is on $REAR_DEV, $REAR_DEV will be skipped in the following comparison"

            # Use --raw as the size column would otherwise have a different
            # width after the ISO was applied to $REAR_ROOT.  Even though the
            # output would be still correct.
            rlRun -l "lsblk --raw | grep -v '^$REAR_DEV' | tee drive_layout.new" \
                0 "Get current lsblk output"
            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            check_and_submit_rear_log recover
        rlPhaseEnd

        rlPhaseStartCleanup
            if grep -q "emulated by qemu" /proc/cpuinfo ; then
                # PowerKVM
                # TODO: Do nothing?
                :
            else
                # PowerVM
                rlRun "nvram -p common --update-config \
                             'boot-device=$(cat bootorder.bak)'" \
                       0 "Set original boot-device"
            fi

            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f bootorder.bak" 0 "Remove bootorder backup"
            rlRun "rm -f nvram.bak" 0 "Remove NVRAM variables backup"
            rlRun "rm -rf /root/rear*.log /var/log/rear/*" 0 "Remove ReaR logs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
