#!/bin/sh
# vim:ff=unix:enc=utf8:ts=3:sw=3:et
#
# rc.M		This file is executed by init(8) when the system is being
#		initialized for one of the "multi user" run levels (i.e.
#		levels 1 through 6).  It usually does mounting of file
#		systems et al.
#
# Version:	@(#)/etc/rc.d/rc.M	2.23	Wed Feb 26 19:20:58 PST 2003
#
# Author:	Fred N. van Kempen, <waltje@uwalt.nl.mugnet.org>
#		Heavily modified by Patrick Volkerding <volkerdi@slackware.com>
#

# Tell the viewers what's going to happen.
echo "Going multiuser..."

# Update all the shared library links:
if [ -x /sbin/ldconfig ]; then
   echo "Updating shared library links:  /sbin/ldconfig &"
   /sbin/ldconfig &
fi

# Screen blanks after 15 minutes idle time, and powers down in one hour
# if the kernel supports APM or ACPI power management:
/bin/setterm -blank 15 -powersave powerdown -powerdown 60

# Set the hostname.
if [ -r /etc/HOSTNAME ]; then
   local HOSTNAME=""
   read HOSTNAME < "/etc/HOSTNAME"
   /bin/hostname "${HOSTNAME%%.*}"
else
   # fall back on this old default:
   echo "darkstar.example.net" > "/etc/HOSTNAME"
   /bin/hostname darkstar
fi

# Save the contents of 'dmesg':
/bin/dmesg -s 65536 > "/var/log/dmesg"

# Start the system logger.
if test -x "/etc/rc.d/rc.syslog" && test -x "/usr/sbin/syslogd" && test -d "/var/log" ; then
   /etc/rc.d/rc.syslog start
fi

# Update the X font indexes:
if test -x /usr/bin/fc-cache ; then
   echo "Updating X font indexes:  /usr/bin/fc-cache -f &"
   /usr/bin/fc-cache -f &
fi

# If we are returning from single-user mode we will need to restart
# udevd on systems that use udev:
if grep -wq sysfs /proc/mounts && grep -wq tmpfs /proc/filesystems ; then
   if ! grep -wq nohotplug /proc/cmdline ; then
      if test -x /etc/rc.d/rc.udev ; then
         /bin/sh /etc/rc.d/rc.udev start
      fi
   fi
fi

# Initialize the networking hardware.
if test -x /etc/rc.d/rc.inet1 ; then
   /etc/rc.d/rc.inet1 start
fi

# Look for additional USB/SCSI/IEEE1394/etc devices on multiple LUNs:
if test -x /etc/rc.d/rc.scanluns ; then
   /etc/rc.d/rc.scanluns
fi

# Start networking daemons:
if test -x /etc/rc.d/rc.inet2 ; then
   /etc/rc.d/rc.inet2
fi

# Mount any additional filesystem types that haven't already been mounted:
mount -a -v 2> /dev/null | grep -v "already mounted"

# Start the Network Time Protocol daemon:
if test -x /etc/rc.d/rc.ntpd ; then
   /etc/rc.d/rc.ntpd start
fi

# Remove stale locks and junk files (must be done after mount -a!)
/bin/rm -f /var/lock/* /var/spool/uucp/LCK..* /tmp/.X*lock /tmp/core /core 2> /dev/null

# Remove stale hunt sockets so the game can start.
if test -r /tmp/hunt || test -r /tmp/hunt.stats ; then
   echo "Removing your stale hunt sockets from /tmp."
   /bin/rm -f /tmp/hunt*
fi

# Ensure basic filesystem permissions sanity.
chmod 755 / 2> /dev/null
chmod 1777 /tmp /var/tmp

# Start ACPI daemon.
if test -x /etc/rc.d/rc.acpid ; then
   /etc/rc.d/rc.acpid start
fi

# Update any existing icon cache files:
if test -r /usr/share/icons/icon-theme.cache ; then
   echo "Deleting icon-theme.cache in /usr/share/icons..."
   #/usr/bin/gtk-update-icon-cache -t -f /usr/share/icons 1> /dev/null 2> /dev/null &
   rm -f /usr/share/icons/icon-theme.cache
fi
for theme_dir in $(find /usr/share/icons -name "icon-theme.cache") ; do
   echo "Updating icon-theme.cache in $theme_dir..."
   /usr/bin/gtk-update-icon-cache -t -f "$theme_dir" > /dev/null 2>&1 &
done

# Update mime database:
if test -x /usr/bin/update-mime-database && test -d /usr/share/mime ; then
   echo "Updating MIME database:  /usr/bin/update-mime-database /usr/share/mime &"
   /usr/bin/update-mime-database /usr/share/mime > /dev/null 2>&1 &
fi

# These GTK+/pango files need to be kept up to date for
# proper input method, pixbuf loaders, and font support.
if [ -x /usr/bin/update-gtk-immodules ]; then
   /usr/bin/update-gtk-immodules --verbose
fi
if [ -x /usr/bin/update-gdk-pixbuf-loaders ]; then
   /usr/bin/update-gdk-pixbuf-loaders --verbose
fi
if [ -x /usr/bin/update-pango-querymodules ]; then
   /usr/bin/update-pango-querymodules --verbose
fi

# Slackware-Mini-Quota-HOWTO:
# To really activate quotas, you'll need to add 'usrquota' and/or 'grpquota' to
# the appropriate partitions as listed in /etc/fstab.  Here's an example:
#
# /dev/hda2      /home      ext3     defaults,usrquota      1   1
#
# You'll then need to setup initial quota files at the top of the partitions
# to support quota, like this:
# touch /home/aquota.user /home/aquota.group
# chmod 600 /home/aquota.user /home/aquota.group
#
# Then, reboot to activate the system.
# To edit user quotas, use 'edquota'.  See 'man edquota'.  Also, the
# official Quota Mini-HOWTO has lots of useful information.  That can be found
# here:  /usr/doc/Linux-HOWTOs/Quota

# Check quotas and then turn quota system on:
if grep -q quota /etc/fstab ; then
  for quotafs in $(awk '/quota/ {print $2}' /etc/fstab) ; do
#   /bin/rm -f $quotafs/{a,}quota.{group,user}.new
    /bin/rm -f "$quotafs/aquota.group.new" "$quotafs/quota.group.new" "$quotafs/aquota.user.new" "$quotafs/quota.user.new"
  done
  if test -x /sbin/quotacheck ; then
    echo "Checking filesystem quotas:  /sbin/quotacheck -avugm"
    /sbin/quotacheck -avugm
  fi
  if test -x /sbin/quotaon ; then
    echo "Activating filesystem quotas:  /sbin/quotaon -avug"
    /sbin/quotaon -avug
  fi
fi

while read service ; do
   if test -x "/etc/rc.d/rc.$service" ; then
      "/etc/rc.d/rc.$service" start
   fi
done < /etc/rc.d/services

# If we're using udev, make /dev/cdrom and any other optical drive symlinks
# if some udev rule hasn't made them already:
#if grep -wq sysfs /proc/mounts && grep -wq tmpfs /proc/filesystems; then
#  if ! grep -wq nohotplug /proc/cmdline ; then
#    if [ -x /lib/udev/rc.optical-symlinks -a -x /etc/rc.d/rc.udev ]; then
#      /bin/sh /lib/udev/rc.optical-symlinks
#    fi
#  fi
#fi

# Monitor the UPS with genpowerd.
# To use this, uncomment this section and edit your settings in
# /etc/genpowerd.conf (serial device, UPS type, etc).  For more information,
# see "man genpowerd" or the extensive documentation in the
# /usr/doc/genpower-*/ directory.
# You'll also need to configure a similar block in /etc/rc.d/rc.6 if you want
# support for stopping the UPS's inverter after the machine halts.
#if [ -x /sbin/genpowerd ]; then
#  echo "Starting genpowerd daemon..."
#  /sbin/genpowerd
#fi

# Turn on process accounting.  To enable process accounting, make sure the
# option for BSD process accounting is enabled in your kernel, and then
# create the file /var/log/pacct (touch /var/log/pacct).  By default, process
# accounting is not enabled (since /var/log/pacct does not exist).  This is
# because the log file can get VERY large.
#if [ -x /sbin/accton -a -r /var/log/pacct ]; then
#  chmod 640 /var/log/pacct
#  /sbin/accton /var/log/pacct
#fi

# Start crond (Dillon's crond):
# If you want cron to actually log activity to /var/log/cron, then change
# -l10 to -l8 to increase the logging level.
if test -x /usr/sbin/crond ; then
   /usr/sbin/crond -l8 >> /var/log/cron 2>&1
fi

# Start atd (manages jobs scheduled with 'at'):
if test -x /usr/sbin/atd ; then
   /usr/sbin/atd -b 15 -l 1
fi

# If there are SystemV init scripts for this runlevel, run them.
if test -x /etc/rc.d/rc.sysvinit ; then
   /etc/rc.d/rc.sysvinit
fi

# Start the local setup procedure.
if test -x /etc/rc.d/rc.local ; then
   /etc/rc.d/rc.local
fi

# All done.
