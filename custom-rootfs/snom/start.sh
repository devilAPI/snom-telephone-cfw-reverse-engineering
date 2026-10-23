#!/bin/sh

# the following settings for the serial port are neccessary for headset use
# with serial ehs box
/bin/stty -F /dev/ttyS0 -icanon
/bin/stty -F /dev/ttyS0 -echo
/bin/stty -F /dev/ttyS0 -icrnl
/bin/stty -F /dev/ttyS0 clocal
/bin/stty -F /dev/ttyS0 hupcl
/bin/stty -F /dev/ttyS0 9600

# Disable printing kernel log messages to serial console to avoid timing problems in phone software by defining loglevel
# in /proc/sys/kernel/printk.
#
# With the loglevel set in this file you can determine which log messages will be printed to the console. You can create
# log messages in kernel(-drivers) with the command printk([level], "message"). If no level is set, then the default
# loglevel is used.
#
# format and default values: "7 4 1 7"
#
# digits:
#
# 1: Current log level, default value is 7, means: all log messages will be printed to console
# 2: Default level for messages without explicit loglevel, default value is 4,
# 3: Minimum allowed loglevel, default value is 1
# 4: Boot time default loglevel, default value is 7
#
# There are 8 log levels, where the highest priority is 0 and the lowest 7. Only log messages equal to defined and higher
# prioritesy will be print to the console.
#
# loglevels: 0 - KERN_EMERG    system is unusable
#            1 - KERN_ALERT    action must be taken immediately
#            2 - KERN_CRIT     critical conditions
#            3 - KERN_ERR      error conditions
#            4 - KERN_WARNING  warning conditions
#            5 - KERN_NOTICE   normal but significant condition
#            6 - KERN_INFO     informational
#            7 - KERN_DEBUG    debug-level messages
#
# To prevent kernel log message output to the console, we set the current loglevel to the highest priority. So only
# emergency messages will be printed to the console now. All other values don't need to be changed. We will change back
# the loglevel to the default value in /etc/init.d/rcS after phone application has finished.
echo 0 > /proc/sys/kernel/printk

# Use TrueType interpreter version 35, as new version 40 used by FreeType 2.7 is a degradation for our fonts.
export FREETYPE_PROPERTIES="truetype:interpreter-version=35"

cd /snom
exec ./lid
