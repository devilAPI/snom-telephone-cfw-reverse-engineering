#!/bin/sh
# This script restarts the obuspa process with no database file intended to use if TopologyHealthChecker::isHealthy() failed.

OBUSPA_DB_FILE="$1"
if [ -z "$OBUSPA_DB_FILE" ];then
  logger -t obuspa -p user.error 'obuspa_repair.sh: no DB file path provided'
  exit 1
fi

is_obuspa_running() {
  pgrep /snom/obuspa > /dev/null
  return $?
}

logger -t obuspa -p user.info 'Obuspa agent restart triggered...'

i=1
while [ "$i" -le 30 ] && is_obuspa_running; do
  sleep 1
  i=$((i+1))
done

if is_obuspa_running; then
  logger -t obuspa -p user.error 'Failed to restart obuspa, the process is still running'
  exit 1
fi

rm -f "$OBUSPA_DB_FILE"
/etc/init.d/S99obuspa start
