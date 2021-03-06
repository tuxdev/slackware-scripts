#!/bin/sh
# vim:ft=sh:ff=unix:enc=utf8:ts=3:sw=3:et
#
# /etc/rc.d/rc.S:  System initialization script.
#
# Mostly written by:  Patrick J. Volkerding, <volkerdi@slackware.com>
#

PATH=/sbin:/usr/sbin:/bin:/usr/bin

# Mount /proc right away:
/sbin/mount -v proc /proc -n -t proc

# Mount sysfs next, if the kernel supports it:
if test -d /sys ; then
   if grep -wq sysfs /proc/filesystems ; then
      if ! grep -wq sysfs /proc/mounts ; then
         /sbin/mount -v sysfs /sys -n -t sysfs
      fi
   fi
fi

# Initialize udev to manage /dev entries and hotplugging for 2.6.x kernels.
# You may turn off udev by making the /etc/rc.d/rc.udev file non-executable
# or giving the "nohotplug" option at boot, but in the 2.6.x+ kernels udev
# has taken over the job of hotplug (finding hardware and loading the kernel
# modules for it, as well as creating device nodes in /dev).  Realize that
# if you turn off udev that you will have to load all the kernel modules
# that you need yourself (possibly in /etc/rc.d/rc.modules, which does not
# promise to list all of them), and make any additional device nodes that you
# need in the /dev directory.  Even USB and IEEE1394 devices will need to have
# the modules loaded by hand if udev is not used with a 2.6 kernel.  So use it.  :-)
if grep -wq sysfs /proc/mounts && grep -wq tmpfs /proc/filesystems ; then
   if ! grep -wq nohotplug /proc/cmdline ; then
      if test -x /etc/rc.d/rc.udev ; then
         /bin/sh /etc/rc.d/rc.udev start
      fi
   fi
fi

# Initialize the Logical Volume Manager.
# This won't start unless we find /etc/lvmtab (LVM1) or
# /etc/lvm/backup/ (LVM2).  This is created by /sbin/vgscan, so to
# use LVM you must run /sbin/vgscan yourself the first time (and
# create some VGs and LVs).
if test -r /etc/lvmtab || test -d /etc/lvm/backup ; then
   echo "Initializing LVM (Logical Volume Manager):"
   # Check for device-mapper support.
   if ! grep -wq device-mapper /proc/devices ; then
      # Try to load a device-mapper kernel module:
      /sbin/modprobe -q dm-mod
   fi
   # Scan for new volume groups:
   if /sbin/vgscan --mknodes --ignorelockingfailure 2> /dev/null ; then
      # Make volume groups available to the kernel.
      # This should also make logical volumes available.
      /sbin/vgchange -ay --ignorelockingfailure
   fi
fi

# Open any volumes created by cryptsetup:
if test -f /etc/crypttab && test -x /sbin/cryptsetup.static ; then
   # First, check for device-mapper support.
   if ! grep -wq device-mapper /proc/devices ; then
      # If device-mapper exists as a module, try to load it.
      # Try to load a device-mapper kernel module:
      /sbin/modprobe -q dm-mod
   fi
   # NOTE: we only support LUKS formatted volumes (except for swap)!
   grep -v "^#" /etc/crypttab |
   while read LUKS DEV PASS OPTS; do
      # Skip LUKS volumes that were already unlocked (in the initrd):
      if test "$LUKS" && ! /sbin/cryptsetup.static status "$LUKS" > /dev/null 2>&1 ; then
         LUKSOPTS=""
         if echo "$OPTS" | grep -wq ro ; then
            LUKSOPTS="$LUKSOPTS --readonly"
         fi
         if /sbin/cryptsetup.static isLuks "$DEV" 2> /dev/null ; then
            echo "Unlocking LUKS crypt volume '$LUKS' on device '$DEV':"
            if test "${PASS}" ; then
               if test -f "$PASS"; then
                  /sbin/cryptsetup.static $LUKSOPTS "--key-file=$PASS" luksOpen "$DEV" "$LUKS"
               elif test "$PASS" != "none" ; then
                  # A password field of 'none' indicates a line for swap:
                  echo "$PASS" | /sbin/cryptsetup.static $LUKSOPTS luksOpen "$DEV" "$LUKS"
               fi
            else
               for i in 1 2 3; do
                  /sbin/cryptsetup.static $LUKSOPTS luksOpen "$DEV" "$LUKS" < /dev/tty0 > /dev/tty0 2>&1 && break
               done
            fi
         elif echo $OPTS | grep -wq swap ; then
            # If any of the volumes is to be used as encrypted swap,
            # then encrypt it using a random key and run mkswap:
            echo "Creating encrypted swap on device '$DEV' mapped to '$LUKS':"
            /sbin/cryptsetup.static --cipher=aes --key-file=/dev/urandom --key-size=256 create "$LUKS" "$DEV"
            mkswap "/dev/mapper/$LUKS"
         fi
      fi
   done
fi

# Enable swapping:
/sbin/swapon -a

# Start FUSE, if requested:
if test -x /etc/rc.d/rc.fuse ; then
   /bin/sh /etc/rc.d/rc.fuse start
fi

# Set the system time from the hardware clock using hwclock --hctosys.
if test -x /sbin/hwclock ; then
   # Check for a broken motherboard RTC clock (where ioports for rtc are
   # unknown) to prevent hwclock causing a hang:
   if ! grep -q -w rtc /proc/ioports ; then
      CLOCK_OPT="--directisa"
   fi
   if grep -wq "^UTC" /etc/hardwareclock ; then
      echo "Setting system time from the hardware clock (UTC)."
      /sbin/hwclock $CLOCK_OPT --utc --hctosys
      else
      echo "Setting system time from the hardware clock (localtime)."
      /sbin/hwclock $CLOCK_OPT --localtime --hctosys
   fi
fi

# Test to see if the root partition is read-only, like it ought to be.
READWRITE=no
if touch /fsrwtestfile 2>/dev/null; then
   rm -f /fsrwtestfile
   READWRITE=yes
else
   echo "Testing root filesystem status:  read-only filesystem"
fi

# See if a forced filesystem check was requested at shutdown:
if test -r /etc/forcefsck ; then
   FORCEFSCK="-f"
fi

# Check the root filesystem:
if test "$READWRITE" != yes ; then
   RETVAL=0
   if ! test -r /etc/fastboot ; then
      echo "Checking root filesystem:"
      /sbin/fsck $FORCEFSCK -C -a /
      RETVAL="$?"
   fi
   # An error code of 2 or higher will require a reboot.
   if test "$RETVAL" -ge 2 ; then
      # An error code equal to or greater than 4 means that some errors
      # could not be corrected.  This requires manual attention, so we
      # offer a chance to try to fix the problem in single-user mode:
      if test $RETVAL -ge 4 ; then
         echo
         echo "***********************************************************"
         echo "*** An error occurred during the root filesystem check. ***"
         echo "*** You will now be given a chance to log into the      ***"
         echo "*** system in single-user mode to fix the problem.      ***"
         echo "***                                                     ***"
         echo "*** If you are using the ext2 filesystem, running       ***"
         echo "*** 'e2fsck -v -y <partition>' might help.              ***"
         echo "***********************************************************"
         echo
         echo "Once you exit the single-user shell, the system will reboot."
         echo
         export PS1="(Repair filesystem) #"
         sulogin
      else # With an error code of 2 or 3, reboot the machine automatically:
         echo
         echo "***********************************"
         echo "*** The filesystem was changed. ***"
         echo "*** The system will now reboot. ***"
         echo "***********************************"
         echo
      fi
      echo "Unmounting file systems."
      /sbin/umount -a -r
      /sbin/mount -n -o remount,ro /
      echo "Rebooting system."
      sleep 2
      reboot -f
   fi
   # Remount the root filesystem in read-write mode
   echo "Remounting root device with read-write enabled."
   if ! /sbin/mount -w -v -n -o remount / ; then
      echo
      echo "Attempt to remount root device as read-write failed!  This is going to"
      echo "cause serious problems."
      echo 
      echo "If you're using the UMSDOS filesystem, you **MUST** mount the root partition"
      echo "read-write!  You can make sure the root filesystem is getting mounted "
      echo "read-write with the 'rw' flag to Loadlin:"
      echo
      echo "loadlin vmlinuz root=/dev/hda1 rw   (replace /dev/hda1 with your root device)"
      echo
      echo "Normal bootdisks can be made to mount a system read-write with the rdev command:"
      echo
      echo "rdev -R /dev/fd0 0"
      echo
      echo "You can also get into your system by using a boot disk with a command like this"
      echo "on the LILO prompt line:  (change the root partition name as needed)"
      echo 
      echo "LILO: mount root=/dev/hda1 rw"
      echo
      echo "Please press ENTER to continue, then reboot and use one of the above methods to"
      echo -n "get into your machine and start looking for the problem. " 
      read junk
   fi
else
   echo "Testing root filesystem status:  read-write filesystem"
   echo
   echo "*** ERROR: Root partition has already been mounted read-write. Cannot check!"
   echo
   echo "For filesystem checking to work properly, your system must initially mount"
   echo "the root partition as read only. Please modify your kernel with 'rdev' so that"
   echo "it does this. If you're booting with LILO, add a line:"
   echo
   echo "   read-only"
   echo
   echo "to the Linux section in your /etc/lilo.conf and type 'lilo' to reinstall it."
   echo
   echo "If you boot from a kernel on a floppy disk, put it in the drive and type:"
   echo "   rdev -R /dev/fd0 1"
   echo
   echo "If you boot from a bootdisk, or with Loadlin, you can add the 'ro' flag."
   echo
   echo "This will fix the problem *AND* eliminate this annoying message. :^)"
   echo
   echo -n "Press ENTER to continue. "
   read junk
fi # Done checking root filesystem

# Any /etc/mtab that exists here is old, so we delete it to start over:
/bin/rm -f /etc/mtab*
# Remounting the / partition will initialize the new /etc/mtab:
/sbin/mount -w -o remount /

# Read in the correct / filesystem complete with arguments so mount will
# show them correctly. This does not stop those arguments from functioning
# but does prevent a small bug with /etc/mtab.
/bin/grep ' / ' /proc/mounts | grep -v "^rootfs" > /etc/mtab

# Fix /etc/mtab to list sys and proc if they were not yet entered in
# /etc/mtab because / was still mounted read-only:
if test -d /proc/sys ; then
   /sbin/mount -f proc /proc -t proc
fi
if test -d /sys/bus ; then
   /sbin/mount -f sysfs /sys -t sysfs
fi

# Configure ISA Plug-and-Play devices:
if test -r /etc/isapnp.conf && test -x /sbin/isapnp ; then
   /sbin/isapnp /etc/isapnp.conf
fi

# This loads any kernel modules that are needed.  These might be required to
# use your ethernet card, sound card, or other optional hardware.
# Priority is given first to a script named "rc.modules.local", then
# to "rc.modules-$FULL_KERNEL_VERSION", and finally to the plain "rc.modules".
# Note that if /etc/rc.d/rc.modules.local is found, then that will be the ONLY
# rc.modules script the machine will run, so make sure it has everything in
# it that you need.
if test -r /proc/modules ; then
   if test -x /etc/rc.d/rc.modules.local ; then
      echo "Running /etc/rc.d/rc.modules.local:"
      /etc/rc.d/rc.modules.local
   elif test -x "/etc/rc.d/rc.modules-$(uname -r)" ; then
      echo "Running /etc/rc.d/rc.modules.local:"
      "/etc/rc.d/rc.modules-$(uname -r)"
   elif test -x /etc/rc.d/rc.modules ; then
      if test -L /etc/rc.d/rc.modules ; then
         echo "Running /etc/rc.d/rc.modules -> $(readlink /etc/rc.d/rc.modules):"
      else
         echo "Running /etc/rc.d/rc.modules:"
      fi
      /etc/rc.d/rc.modules
   fi
fi

# Configure runtime kernel parameters:
if test -x /sbin/sysctl && test -r /etc/sysctl.conf ; then
  /sbin/sysctl -e -p /etc/sysctl.conf
fi

# Check all the non-root filesystems:
if ! test -r /etc/fastboot ; then
   echo "Checking non-root filesystems:"
   /sbin/fsck $FORCEFSCK -C -R -A -a
fi

# Mount usbfs:
if grep -wq usbfs /proc/filesystems ; then
   if ! grep -wq usbfs /proc/mounts ; then
      if ! grep -wq usbfs /etc/fstab ; then
         /sbin/mount -v usbfs /proc/bus/usb -t usbfs
      else
         /sbin/mount -v /proc/bus/usb
      fi
   fi
fi

# Mount non-root file systems in fstab, but not NFS or SMB 
# because TCP/IP is not yet configured, and not proc or sysfs
# because those have already been mounted.  Also check that
# devpts is not already mounted before attempting to mount
# it.  With a 2.6.x or newer kernel udev mounts devpts.
# We also need to wait a little bit to let USB and other
# hotplugged devices settle (sorry to slow down the boot):
echo "Mounting non-root local filesystems:"
sleep 3
if /bin/grep -wq devpts /proc/mounts ; then
   /sbin/mount -a -v -t nonfs,nosmbfs,nocifs,noproc,nosysfs,nodevpts
else
   /sbin/mount -a -v -t nonfs,nosmbfs,nocifs,noproc,nosysfs
fi

# Enable swapping again.  This is needed in case a swapfile is used,
# as it can't be enabled until the filesystem it resides on has been
# mounted read-write.
/sbin/swapon -a

# Clean up some temporary files:
rm -f /var/run/* /var/run/*/* /var/run/*/*/* /etc/nologin \
   /etc/dhcpc/*.pid /etc/forcefsck /etc/fastboot \
   /var/state/saslauthd/saslauthd.pid \
   /tmp/.Xauth* 2> /dev/null
( cd /var/log/setup/tmp && rm -rf * )
( cd /tmp && rm -rf kde-[a-zA-Z]* ksocket-[a-zA-Z]* hsperfdata_[a-zA-Z]* plugtmp* )

# Create /tmp/{.ICE-unix,.X11-unix} if they are not present:
if ! test -e /tmp/.ICE-unix ; then
   mkdir -p /tmp/.ICE-unix
   chmod 1777 /tmp/.ICE-unix
fi
if ! test -e /tmp/.X11-unix ; then
   mkdir -p /tmp/.X11-unix
   chmod 1777 /tmp/.X11-unix
fi

# Create a fresh utmp file:
touch /var/run/utmp
chown root:utmp /var/run/utmp
chmod 664 /var/run/utmp

# Update the current kernel level in the /etc/motd (Message Of The Day) file,
# if the first line of that file begins with the word 'Linux'.
# You are free to modify the rest of the file as you see fit.
if test -x /bin/sed ; then
   /bin/sed -i "{1s/^Linux.*/$(/bin/uname -sr)\./}" /etc/motd
fi

# If there are SystemV init scripts for this runlevel, run them.
if test -x /etc/rc.d/rc.sysvinit ; then
   /etc/rc.d/rc.sysvinit
fi

# Run serial port setup script:
# CAREFUL!  This can make some systems hang if the rc.serial script isn't
# set up correctly.  If this happens, you may have to edit the file from a
# boot disk, and/or set it as non-executable:
if test -x /etc/rc.d/rc.serial ; then
   sh /etc/rc.d/rc.serial start
fi

# Carry an entropy pool between reboots to improve randomness.
if [ -f /etc/random-seed ]; then
   echo "Using /etc/random-seed to initialize /dev/urandom."
   cat /etc/random-seed > /dev/urandom
fi
# Use the pool size from /proc, or 512 bytes:
if [ -r /proc/sys/kernel/random/poolsize ]; then
   read POOLSIZE < /proc/sys/kernel/random/poolsize
   dd if=/dev/urandom of=/etc/random-seed count=1 bs="$POOLSIZE" 2> /dev/null
else
   dd if=/dev/urandom of=/etc/random-seed count=1 bs=512 2> /dev/null
fi
chmod 600 /etc/random-seed
