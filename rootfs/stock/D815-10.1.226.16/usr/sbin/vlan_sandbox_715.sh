#! /bin/sh

 # Function can be used to enable or disable the so called "Guest VLAN sandbox scenario" for BCM11 switch.
 #
 # @param[in] enableSandbox  true: enable "Guest VLAN sandbox scenario", false: disable "Guest VLAN sandbox scenario"
 # @param[in] vlanId         VLAN ID according to IEEE802.1Q
 # @param[in] vlanPrio       priority of the VLAN tagged packet according to IEEE802.1P
 # @param[in] vlanIdCpu      priority of the CPU port based VLAN tagged packet according to IEEE802.1P
 # @param[in] vlanPrioCpu    CPU port based VLAN ID according to IEEE802.1Q
 #
 # Guest VLAN sandbox scenario example description
 #
 #  1. Packet flow from PC to LAN
 #     o Connected PC sends untagged packets to PC-Port (tagged packets are ignored by PC-Port)
 #     o PC-Port forwards them to NET-Port
 #     o NET-Port taggs packets (vid 20), adds QoS 5 and sends them out to the LAN
 #
 #  2. Packet flow from LAN to PC
 #    o LAN sends tagged packets (vid 20) to NET-Port
 #    o NET-Port forwards them to PC-Port (only vid 20 packets, others are forward to CPU port only, see 3.)
 #    o PC-Port untags the packets and sends them out to PC
 #
 #  3. Packet flow from NET-Port to CPU-Port
 #    o tagged and untagged packets go through unchanged
 #
 #  4. Packet flow from CPU-Port to NET-Port
 #    o tagged and untagged packets go through unchanged
 #
 #  5. Result:
 #    o PC resides in an untagged sandbox net (guest VLAN), which is VLAN 20 in the LAN net
 #    o CPU (CPU-Port) resides in tagged or untagged LAN, all packets regarding CPU-Port get forwarded to/from it.

 ##############################################################################################
 # bcmtools adjusted description:
 ##############################################################################################
 # Scenario A:
 #  - Port 1 (PC-Port) resides in an untagged sandbox net (guest VLAN), which is VLAN 20 in the LAN net
 #  - Port 8 (CPU-Port) resides in tagged VLAN 10 in the LAN net
 ##############################################################################################
 # Setup made with bcmtool WebUI see: SnomARM/platforms/BC/switch/sbox_pc20_cpu10.png
 ##############################################################################################
 # Port 0 (LAN-Port):
 #
 # ingress untagged packet .....
 #
 # - The untagged packet must not be forwarded to port 1.
 # - The untagged packet can be forwarded to port 8 as an untagged packet.
 #
 # ingress tagged packet with vid = n (except 20) .....
 #
 # - The tagged packet must not be forwarded to port 1.
 # - The tagged packet can be forwarded to port 8 as an tagged packet with vid = n.
 #
 # ingress tagged packet with vid = 20 ....
 #
 # - The tagged packet can be forwarded to port 1 as an untagged packet.
 # - The tagged packet can be forwarded to port 8 as an tagged packet with vid = 20.
 #
 #####
 # Port 1 (PC-Port):
 #
 # ingress untagged packet .....
 #
 # - The untagged packet can be forwarded to port 0 as an tagged packet with vid = 20.
 # - The untagged packet can be forwarded to port 8 as an tagged packet with vid = 20.
 #
 # ingress tagged packet with vid = 10 .....
 #
 # - The tagged packet must not be forwarded to port 0.
 # - The tagged packet can be forwarded to port 8 as an tagged packet with vid = 10.
 #
 # ingress tagged packet with vid = n (except 10) ....
 #
 # - The tagged packet must not be forwarded to port 0.
 # - The tagged packet must not be forwarded to port 8.
 #
 #####
 # Port 8 (CPU-Port):
 #
 # ingress untagged packet ..... 
 #
 # - Unlikely because only tagged packets with vid = 10 comming from linux, see Scenario B instead.
 #
 # ingress tagged packet with vid = 10 .....
 #
 # - The tagged packet can be forwarded to port 0 as an tagged packet with vid = 10.
 # - The tagged packet must not be forwarded to port 1.
 #
 # ingress tagged packet with vid = n (except 10) .... 
 #
 # - Unlikely because only tagged packets with vid = 10 comming from linux.
 #
 ##############################################################################################
 # Scenario B:
 #  - Port 1 (PC-Port) resides in an untagged sandbox net (guest VLAN), which is VLAN 20 in the LAN net
 #  - Port 8 (CPU-Port) resides in untagged LAN net
 ##############################################################################################
 # Setup made with bcmtool WebUI see: SnomARM/platforms/BC/switch/sbox_pc20_cpuUntagged.png
 ##############################################################################################
 # Port 0 (LAN-Port):
 #
 # ingress untagged packet .....
 #
 # - The untagged packet must not be forwarded to port 1.
 # - The untagged packet can be forwarded to port 8 as an untagged packet.
 #
 # ingress tagged packet with vid = 20 ....
 #
 # - The tagged packet can be forwarded to port 1 as an untagged packet.
 # - The tagged packet can be forwarded to port 8 as an tagged packet with vid = 20.
 #
 # ingress tagged packet with vid = n (except 20) .....
 #
 # - The tagged packet must not be forwarded to port 1.
 # - The tagged packet can be forwarded to port 8 as an tagged packet with vid = n.
 #####
 # Port 1 (PC-Port):
 #
 # ingress untagged packet .....
 #
 # - The untagged packet can be forwarded to port 0 as an tagged packet with vid = 20.
 # - The untagged packet can be forwarded to port 8 as an tagged packet with vid = 20.
 #
 # ingress tagged packet with vid = n .....
 #
 # - The tagged packet must not be forwarded to port 0.
 # - The tagged packet must not be forwarded to port 8.
 #####
 # Port 8 (CPU-Port):
 #
 # ingress untagged packet .....
 #
 # - The untagged packet can be forwarded to port 0 as an untagged packet.
 # - The untagged packet must not be forwarded to port 1.
 #
 # ingress tagged packet with vid = n ..... 
 #
 # - Unlikely because only untagged packets are comming from linux, see Scenario A instead.
 #
 ##############################################################################################

enableSandbox=$1
vlanId=$2
vlanPrio=$3
vlanIdCpu=$4
vlanPrioCpu=$5

if [ "$enableSandbox" != "1" ] && [ "$enableSandbox" != "0" ]; then
    exit 255;
fi

# Initialize and en-/disable VLAN
eth vlan init
eth vlan en "$enableSandbox"

# Clear all previous VLAN configs
eth vlan table clr

# Clear all previous CFP rules
eth cfp rule clr

if [ "$enableSandbox" != "1" ]; then
    exit 0;
fi

if [ "$vlanId" -lt 0 ] || [ "$vlanId" -gt 4093 ]; then
    exit 254;
fi

if [ "$vlanPrio" -lt 0 ] || [ "$vlanPrio" -gt 7 ]; then
    exit 253;
fi

if [ "$vlanIdCpu" -lt 0 ] || [ "$vlanIdCpu" -gt 4093 ]; then
    exit 252;
fi

if [ "$vlanPrioCpu" -lt 0 ] || [ "$vlanPrioCpu" -gt 7 ]; then
    exit 251;
fi

# CPU isn't using VLAN, mark it as special VID=0xffe for "Scenario B"
if [ "$vlanIdCpu" -eq 0 ]; then
    vlanIdCpu=4094
fi

if [ "$vlanPrioCpu" -eq 0 ]; then
    vlanPrioCpu=5
fi

# Disable special VID=0xfff forwarding
eth vlan en0xfff 0

# Do not replace tagged frame with port VID
eth vlan replace 0

# Don't preserve the untagged and priority tagged frames on egress
eth vlan enPreserveNon1Q 0

# Set port VID (LAN port 0 is using special VID=0xfff/=0xffe)
if [ "$vlanIdCpu" -eq 4094 ]; then
  eth vlan port vid 0 0xffe
else
  eth vlan port vid 0 0xfff
fi
eth vlan port vid 1 "$vlanId"
eth vlan port vid 8 "$vlanIdCpu"

# Set port priority
eth vlan port prio 0 0
eth vlan port prio 1 "$vlanPrio"
eth vlan port prio 8 "$vlanPrioCpu"

#Configure the VLAN table
eth vlan table create all

#remove current pbmp-ubmp and add new setting for special VID=0xfff/=0xffe
if [ "$vlanIdCpu" -eq 4094 ]; then
  eth vlan table add all 0x100 0x000
  eth vlan table remove 0xffe 0x103
  eth vlan table add 0xffe 0x101 0x101
else
  eth vlan table add all 0x101 0x000
  eth vlan table remove 0xfff 0x103
  eth vlan table add 0xfff 0x100 0x100
fi

#remove current pbmp-ubmp and add new setting
eth vlan table remove "$vlanId" 0x103
eth vlan table add "$vlanId" 0x103 0x002

#using CFP rules to block not allowed connections between ports respectively
#####
# Port 1 (PC-Port):
#
# ingress tagged packet with vid = n
#
# - The tagged packet must not be forwarded to port 0. -----|                                                        
# - The tagged packet must not be forwarded to port 8. -----|   [CONFLICT] these two rules have to be achieved by CFP rules.
if [ "$vlanIdCpu" -eq 4094 ]; then

  # Scenario B:

  eth cfp en 0 0
  eth cfp en 1 1
  eth cfp en 8 0
  eth cfp rule struct init
  eth cfp rule struct en 1
  eth cfp rule struct portmap 0x2
  eth cfp rule struct framing 7
  eth cfp rule struct sliceid 0
  eth cfp rule struct ctag 3 0 0x0
  eth cfp rule struct actiondrop
  eth cfp rule add -1

else

  # Scenario A:

  eth cfp en 0 0
  eth cfp en 1 1
  eth cfp en 8 0
  
  eth cfp rule struct init
  eth cfp rule struct en 1
  eth cfp rule struct portmap 0x2
  eth cfp rule struct framing 7
  eth cfp rule struct sliceid 0
  eth cfp rule struct ctag 3 "$vlanIdCpu" 0xfff
  eth cfp rule struct actiontype r r
  eth cfp rule struct actiondst 0x40 0x40
  eth cfp rule struct Kbps 64 16
  eth cfp rule add -1
  
  eth cfp rule struct init
  eth cfp rule struct en 1
  eth cfp rule struct portmap 0x2
  eth cfp rule struct framing 7
  eth cfp rule struct sliceid 0
  eth cfp rule struct ctag 3 0 0x0
  eth cfp rule struct actiondrop
  eth cfp rule add -1
fi
