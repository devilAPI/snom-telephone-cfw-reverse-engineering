#!/bin/sh

# Determine the type of firmware (SIP/UC) and write it to /tmp/pre_update
function checkForUCVersion() {
  local UC_FILE="/snom/html/ocs.htm"
  local UPD_FILE="/tmp/pre_update"

  if [ -f $UC_FILE ]; then
    echo "UC" > $UPD_FILE
  else
    echo "SIP" > $UPD_FILE
  fi
}

# Remove core dump files
function removeCoredumps() {
  rm -f /core*
  rm -f /debug.log
  rm -f /snom/core*
  rm -f /snom/debug.log
}

# Remove python
function removePython() {
  rm -f /usr/bin/python
  rm -rf /usr/lib/python2.5
}

# Remove root CA certificates
function removeRootCAs() {
  rm -f /snom/snomconfig/certificates/authority_certs/*
}

# Copy openvpn binary to new location if vpn is enabled, so it is still available
# after installing the new firmware update without bundled openvpn binary.
function copyOpenVPNBinary() {
  local OLD_VPN_LOCATION="/usr/sbin/openvpn"
  local NEW_VPN_LOCATION="/sbin/openvpn"
  if [ -e $OLD_VPN_LOCATION ]; then
    if grep -i -E "<vpn_on[^>]+>(on|yes|true|1)</vpn_on>" /snom/snomconfig/config.xml ; then
      cp $OLD_VPN_LOCATION $NEW_VPN_LOCATION
    fi
  fi
}

# Extract /usr/bin/bar which is attached uuencoded to this script
function extractBarBinary () {
  tail -n +$[ `grep -n '^BINARY' $0|cut -d ':' -f 1` + 1 ] $0 | uudecode -o /usr/bin/bar
}

# The main function. Everything is started from here!
function startUp () {
  checkForUCVersion
  removeCoredumps
  removeRootCAs
  if [ -e /usr/bin/python ]; then
      echo "Python binary found. Replacing bar binary and removing python."
      extractBarBinary
      removePython
  fi
  copyOpenVPNBinary
}

# Ignore SIGTERM, SIGQUIT, SIGINT, SIGHUP
trap "" SIGTERM
trap "" SIGQUIT
trap "" SIGINT
trap "" SIGHUP

startUp
exit

# The following commands were used to attach the binary to this script:
# echo "BINARY" >> preSystemUpdate.sh; uuencode ../../../rootfs/usr/bin/bar bar >> preSystemUpdate.sh
# uuencoded bar binary follows here
BINARY
begin 755 bar
M?T5,1@$!`0````````````(`*``!````=(0``#0```!T#````@``!#0`(``(
M`"@`&P`:``$``'#H"0``Z(D``.B)```(````"`````0````$````!@```#0`
M```T@```-(`````!`````0``!0````0````#````-`$``#2!```T@0``$P``
M`!,````$`````0````$``````````(````"```#T"0``]`D```4`````@```
M`0```/0)``#T"0$`]`D!`#P!``!$`0``!@````"````"``````H````*`0``
M"@$`Z````.@````&````!`````0```!(`0``2($``$B!```@````(`````0`
M```$````4>5T9```````````````````````````!@````0````O;&EB+VQD
M+6QI;G5X+G-O+C,```0````0`````0```$=.50```````@````8````.````
M`P````X````-````"@````@``````````````````````````P````$````%
M````!`````(````'````"0````8````+````#```````````````````````
M```:````Y(,``#`"```2````)@```/"#``"<`P``$@```%$```#\@P``,`(`
M`!(````Q````"(0``.@````2````8P```!2$``!D````$@```#<````P"P$`
M!````!$`%P!)````((0``#`````2````1````"R$``!D````$@```"$````X
MA```_````!(````L````1(0``&0````2````/@```%"$``!D````$@```&D`
M``!<A```L````!(````!```````````````@`````%]?9VUO;E]S=&%R=%]?
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
M_Q#___]L@0```2"@X0`0H.$#`*#CI?[_Z@3@+>4$T$WB!-"-X@"`O>@!``(`
M,3`P)0T````E:24E#0```(SZ_W\!`````````.R$``#0A`````````$````0
M````#````+R#```-````Q(D``!D```#T"0$`&P````0````:````^`D!`!P`
M```$````!````&B!```%````E((```8```"T@0``"@```'P````+````$```
M`!4``````````P```.@*`0`"````8````!0````1````%P```%R#```1````
M3(,``!(````0````$P````@```#^__]O+(,``/___V\!````\/__;Q"#````
M````````````````````````````````````````````````````````````
M````"@$```````````#0@P``T(,``-"#``#0@P``T(,``-"#``#0@P``T(,`
M`-"#``#0@P``T(,``-"#````````````````````1T-#.B`H0V]D95-O=7)C
M97)Y(%-O=7)C97)Y($<K*R!,:71E(#(P,#=Q,2TR,2D@-"XR+C`@,C`P-S`T
M,3,@*'!R97)E;&5A<V4I`$$3````865A8FD``0D````&!`@!`"YS:'-T<G1A
M8@`N:6YT97)P`"YN;W1E+D%"22UT86<`+FAA<V@`+F1Y;G-Y;0`N9'EN<W1R
M`"YG;G4N=F5R<VEO;@`N9VYU+G9E<G-I;VY?<@`N<F5L+F1Y;@`N<F5L+G!L
M=``N:6YI=``N=&5X=``N9FEN:0`N<F]D871A`"Y!4DTN97AI9'@`+F5H7V9R
M86UE`"YI;FET7V%R<F%Y`"YF:6YI7V%R<F%Y`"YJ8W(`+F1Y;F%M:6,`+F=O
M=``N9&%T80`N8G-S`"YC;VUM96YT`"Y!4DTN871T<FEB=71E<P``````````
M````````````````````````````````````````````"P````$````"````
M-($``#0!```3```````````````!`````````!,````'`````@```$B!``!(
M`0``(```````````````!``````````A````!0````(```!H@0``:`$``$P`
M```$``````````0````$````)P````L````"````M($``+0!``#@````!0``
M``$````$````$````"\````#`````@```)2"``"4`@``?```````````````
M`0`````````W````____;P(````0@P``$`,``!P````$``````````(````"
M````1````/[__V\"````+(,``"P#```@````!0````$````$`````````%,`
M```)`````@```$R#``!,`P``$`````0`````````!`````@```!<````"0``
M``(```!<@P``7`,``&`````$````"P````0````(````90````$````&````
MO(,``+P#```4```````````````$`````````&`````!````!@```-"#``#0
M`P``I```````````````!`````0```!K`````0````8```!TA```=`0``%`%
M``````````````0`````````<0````$````&````Q(D``,0)```0````````
M```````$`````````'<````!`````@```-2)``#4"0``%```````````````
M!`````````!_`````0``<((```#HB0``Z`D```@````,``````````0`````
M````B@````$````"````\(D``/`)```$```````````````$`````````)0`
M```.`````P```/0)`0#T"0``!```````````````!`````````"@````#P``
M``,```#X"0$`^`D```0```````````````0`````````K`````$````#````
M_`D!`/P)```$```````````````$`````````+$````&`````P`````*`0``
M"@``Z`````4`````````!`````@```"Z`````0````,```#H"@$`Z`H``$``
M``````````````0````$````OP````$````#````*`L!`"@+```(````````
M```````$`````````,4````(`````P```#`+`0`P"P``"```````````````
M!`````````#*`````0``````````````,`L``$T```````````````$`````
M````TP````,``'```````````'T+```4```````````````!``````````$`
F```#``````````````"1"P``XP```````````````0``````````
`
end
