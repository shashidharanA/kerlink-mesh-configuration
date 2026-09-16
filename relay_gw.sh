#!/bin/sh
set -e

# Disable lorad and lorafwd
/etc/init.d/lorad stop
/etc/init.d/lorafwd stop
klk_apps_config --deactivate-cpf

# Disable KerOS's built-in connectivity watchdog (networkmonitoring.py).
#
# It assumes every gateway always has internet: after enough failed pings to
# 8.8.8.8 it escalates through restarting connman, restarting network
# servers, resetting modem/ethernet hardware, and finally rebooting the
# whole board. A relay is deliberately deployed with no Ethernet/cellular,
# so this was rebooting the device every ~37.5 minutes, resetting its clock
# and dropping in-flight uplinks on every cycle. Confirmed via bootcause=SW
# kernel boot events spaced 37m29s-37m33s apart in the relay's own logs.
#
# monitor_network=0 is the master switch - the daemon reads it and exits
# outright (confirmed: process disappears from `ps` within one check cycle
# after the config changes), not just skips the reboot action. Setting
# ping_error_before_board_reboot=0 too, for defense in depth, since that
# value has been observed to differ from its documented default on a live
# device for reasons we don't fully understand.
sed -i 's/^monitor_network=.*/monitor_network=0/' /etc/network/networkmonitoring.conf
sed -i 's/^ping_error_before_board_reboot=.*/ping_error_before_board_reboot=0/' /etc/network/networkmonitoring.conf
/etc/init.d/networkmonitoring restart

# Install ChirpStack Concentratord (skip if already present)
if [ ! -f /usr/bin/chirpstack-concentratord ]; then
  cd /user/.updates
  curl -sLO https://artifacts.chirpstack.io/downloads/chirpstack-concentratord/vendor/kerlink/ifemtocell/chirpstack-concentratord_4.7.1-r1_klkgw.ipk
  sync
  kerosd -u
  reboot
fi

# Install ChirpStack Gateway Mesh binary
cd /usr/bin
curl -sLO https://artifacts.chirpstack.io/downloads/chirpstack-gateway-mesh/chirpstack-gateway-mesh_4.1.3_linux_armv7hf.tar.gz
tar xzf chirpstack-gateway-mesh_4.1.3_linux_armv7hf.tar.gz
chmod +x chirpstack-gateway-mesh

# Gateway Mesh configuration
ETC=/etc/chirpstack-gateway-mesh
GITHUB=https://raw.githubusercontent.com/chirpstack/chirpstack-gateway-mesh/refs/heads/master/configuration/
mkdir -p $ETC
curl -sL $GITHUB/chirpstack-gateway-mesh.toml >$ETC/chirpstack-gateway-mesh.toml
for region in as9123 as923_2 as923_3 as923_4 au915 eu868 in865 kr920 ru864 us915; do
  curl -sL $GITHUB/region_${region}.toml >$ETC/region_${region}.toml
done

# Apply local overrides
#
# Note: these sed patterns assume the upstream template uses "key = value"
# (spaced). The template has silently changed format before (no spaces),
# which makes these substitutions no-ops with no error. The grep check below
# catches that immediately instead of leaving a half-configured gateway.
sed -i \
  -e 's/log_to_syslog = false/log_to_syslog = true/' \
  -e 's/frequencies = \[868100000, 868300000, 868500000\]/frequencies = [865062500, 865402500, 865985000]/' \
  -e 's/tx_power = 16/tx_power = 36/' \
  $ETC/chirpstack-gateway-mesh.toml

grep -q 'log_to_syslog = true' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: log_to_syslog override did not apply - check upstream template format" >&2; exit 1; }
grep -q 'tx_power = 36' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: tx_power override did not apply - check upstream template format" >&2; exit 1; }
grep -q '865062500' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: frequencies override did not apply - check upstream template format" >&2; exit 1; }

# root_key / signing_key: the upstream template has dropped these fields
# entirely in some versions, leaving the mesh with no shared key at all.
# This MUST match the value configured in border_gw.sh, or the border will
# silently drop every packet this relay sends (looks fine locally, nothing
# ever reaches the network). Rotate this value in both scripts together if
# it's ever changed - it is not a secret worth protecting in this file, but
# it does need to be consistent across every gateway in the mesh.
MESH_ROOT_KEY="00000000000000000000000000000000"
if grep -q 'root_key' $ETC/chirpstack-gateway-mesh.toml; then
  sed -i "s/root_key=.*/root_key=\"${MESH_ROOT_KEY}\"/" $ETC/chirpstack-gateway-mesh.toml
  sed -i "s/signing_key=.*/signing_key=\"${MESH_ROOT_KEY}\"/" $ETC/chirpstack-gateway-mesh.toml
else
  sed -i "/^\[mesh\]/a\\  root_key=\"${MESH_ROOT_KEY}\"\\n  signing_key=\"${MESH_ROOT_KEY}\"" $ETC/chirpstack-gateway-mesh.toml
fi

# max_hop_count: upstream default has drifted between versions (seen as low
# as 1, which breaks anything beyond a single hop). Force it explicitly.
sed -i 's/max_hop_count = .*/max_hop_count = 5/' $ETC/chirpstack-gateway-mesh.toml

# Channel plan / region setup
cp -r /etc/chirpstack-gateway-mesh/region_in865.toml /etc/chirpstack-gateway-mesh/channels.toml
cp -r /etc/chirpstack-concentratord/examples/channels_in865.toml /etc/chirpstack-concentratord/channels.toml
sed -i s/EU868/IN865/g /etc/chirpstack-concentratord/concentratord.toml

# Remote time-sync command handler.
#
# This relay has no GPS and no internet, so its clock free-runs from
# whatever it booted with. A Node-RED flow periodically publishes a
# ChirpStack Gateway Mesh proprietary command (type 129) carrying the
# current UTC time; the border forwards it over the mesh, and this script
# is invoked with that time on stdin.
#
# Note: BusyBox `date -s` requires "YYYY-MM-DD HH:MM:SS" - NOT ISO-8601
# (tested: ISO-8601 with T/Z/fractional seconds is rejected as invalid).
mkdir -p /usr/local/bin
cat >/usr/local/bin/settime.sh <<'EOF'
#!/bin/sh
# Invoked by chirpstack-gateway-mesh on receipt of a proprietary command
# (commandType 129, mapped in [commands.commands] in chirpstack-gateway-mesh.toml).
# stdin carries a UTC timestamp in "YYYY-MM-DD HH:MM:SS" format (BusyBox
# date -s does not accept ISO-8601).
TS=$(cat)
date -u -s "$TS" 2>&1
EOF
chmod +x /usr/local/bin/settime.sh

# Wire commandType 129 to settime.sh. Some upstream template versions drop
# the [commands] section entirely; append it if it's missing.
if ! grep -q '^\[commands\]' $ETC/chirpstack-gateway-mesh.toml; then
  cat >>$ETC/chirpstack-gateway-mesh.toml <<'EOF'

# Commands configuration (Relay only).
[commands]
  [commands.commands]
  "129" = ["/usr/local/bin/settime.sh"]
EOF
fi

# set up sysV and monit scripts
sed s/concentratord/gateway-mesh/g /etc/init.d/chirpstack-concentratord >/etc/init.d/chirpstack-gateway-mesh
chmod +x /etc/init.d/chirpstack-gateway-mesh
sed -i s@/gateway-mesh.toml@/chirpstack-gateway-mesh.toml@ /etc/init.d/chirpstack-gateway-mesh
sed s/concentratord/gateway-mesh/g /etc/monit.d/chirpstack-concentratord >/etc/monit.d/chirpstack-gateway-mesh

# restart services
/etc/init.d/monit restart
for s in gateway-mesh concentratord; do
  monit restart chirpstack-${s}
done
