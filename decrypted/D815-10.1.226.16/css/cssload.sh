#!/bin/sh

# We need to find out the index of the DSPG sound card, so that the correct
# card will be configured with amixer. To do this, we determine the number
# of currently available sound cards. The DSPG sound card is not available
# yet and will be added later. The index of the DSPG card is the index of the
# last card in /proc/asound/cards + 1.

STATE=
if [ -d /sys/bus/platform/devices/8200000.css ]
then
  STATE=`cat /sys/bus/platform/devices/8200000.css/state`
fi
if [ "$STATE" != "loaded" ]
then
  card=`grep -E dspgdvf99css /proc/asound/cards | tr -d '[:space:]' | cut -d '[' -f0`
  #Set AMPOUTSEL1 (22) register to 0x0 to avoid click/pop during css reload
  amixer -c$card sset 'Output Mux1' 'MUTE' >& /dev/null
  amixer -c$card sset 'Output Mux0' 'MUTE' >& /dev/null
  #Set AFEAMPEN register (register 14) to 0x0 to avoid click/pop during css reload
  amixer -c$card sset 'SINGIN0_EN' 'off' >& /dev/null
  amixer -c$card sset 'SINGIN1_EN' 'off' >& /dev/null
  amixer -c$card sset 'DIFFIN0_EN' 'off' >& /dev/null
  amixer -c$card sset 'DIFFIN1_EN' 'off' >& /dev/null
  amixer -c$card sset 'AMPOUT3_EN' 'off' >& /dev/null
  amixer -c$card sset 'AMPOUT2_EN' 'off' >& /dev/null
  amixer -c$card sset 'AMPOUT1_EN' 'off' >& /dev/null
  amixer -c$card sset 'AMPOUT0_EN' 'off' >& /dev/null
fi

#Kill app_dsp if it is already running
killall app_dsp >& /dev/null
sleep 2
killall cssd >& /dev/null
sleep 2

if grep "disable_css=on" /proc/cmdline 2>&1 > /dev/null ; then
  echo "CSS is disabled in uboot,exiting... "
  exit 0
fi

echo 1 > /sys/bus/platform/devices/8200000.css/load
sleep 2

# No udev to load firmware - do it manually
echo 1 > /sys/class/firmware/8200000.css/loading
cat /lib/firmware/css-loader > /sys/class/firmware/8200000.css/data
echo 0 > /sys/class/firmware/8200000.css/loading


STATE=

while :

do
  # check if CSS loaded
  if [ -d /sys/bus/platform/devices/8200000.css ]
  then
    STATE=`cat /sys/bus/platform/devices/8200000.css/state`
  fi

  if [ "$STATE" != "loaded" ]
  then
    #Wait for around 5ms for css to load
    usleep 5000

    continue
  else
    #Wait for css services to start running
    usleep 400000

    #Start app_dsp in background
    app_dsp &
    cssd -m 1 &

    #Wait for app_dsp to finish. Removing this
    #usleep may result in loud pop/click during
    #cssload
    usleep 50000

    break
  fi
done


card=`grep -E dspgdvf99css /proc/asound/cards | tr -d '[:space:]' | cut -d '[' -f0`
#Set AMPOUTSEL1 (22) register to 0x20
amixer -c$card sset 'Output Mux0' 'DAC0' >& /dev/null
amixer -c$card sset 'Output Mux1' 'DAC0_INV' >& /dev/null

#Set AMPOUTSEL2 (34)register to 0x31
amixer -c$card sset 'Output Mux2' 'DAC1' >& /dev/null
amixer -c$card sset 'Output Mux3' 'DAC1_INV' >& /dev/null

#Set LQSD_CFG1 register to 0x70
amixer -c$card sset 'AFE_DITHER_ON' 'off' >& /dev/null
amixer -c$card sset 'MUTE_REQ_INT_EN' 'off' >& /dev/null
amixer -c$card sset 'MUTE_STAT_EN' 'off' >& /dev/null
amixer -c$card sset 'ADC2_EN' 'off' >& /dev/null
amixer -c$card sset 'DAC0_EN' 'on' >& /dev/null
amixer -c$card sset 'DAC1_EN' 'on' >& /dev/null
amixer -c$card sset 'ADC0_EN' 'on' >& /dev/null
amixer -c$card sset 'ADC1_EN' 'off' >& /dev/null

#Set AFECFG1 register to 0xFE
amixer -c$card sset 'MICPWR0_EN' 'on' >& /dev/null
amixer -c$card sset 'MICPWR0_CURR_LIM_EN' 'off' >& /dev/null
amixer -c$card sset 'MICPWR1_EN' 'on' >& /dev/null
amixer -c$card sset 'MICPWR1_CURR_LIM_EN' 'on' >& /dev/null
amixer -c$card sset 'VREF_EN' 'on' >& /dev/null
amixer -c$card sset 'VREF_LVL' 'VCCA/2' >& /dev/null


#Set AFEAMPEN (14) register to 0xFF
amixer -c$card sset 'DIFFIN1_EN' 'on' >& /dev/null
amixer -c$card sset 'DIFFIN0_EN' 'on' >& /dev/null
amixer -c$card sset 'SINGIN1_EN' 'on' >& /dev/null
amixer -c$card sset 'SINGIN0_EN' 'on' >& /dev/null
amixer -c$card sset 'AMPOUT3_EN' 'on' >& /dev/null
amixer -c$card sset 'AMPOUT2_EN' 'on' >& /dev/null
amixer -c$card sset 'AMPOUT1_EN' 'on' >& /dev/null
amixer -c$card sset 'AMPOUT0_EN' 'on' >& /dev/null
