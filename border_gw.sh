#!/bin/sh
set -e

# Disable lorad and lorafwd
/etc/init.d/lorad stop
/etc/init.d/lorafwd stop
klk_apps_config --deactivate-cpf

# Install ChirpStack Concentratord (skip if already present)
if [ ! -f /usr/bin/chirpstack-concentratord ]; then
  cd /user/.updates
  curl -sLO https://artifacts.chirpstack.io/downloads/chirpstack-concentratord/vendor/kerlink/ifemtocell/chirpstack-concentratord_4.7.1-r1_klkgw.ipk
  curl -sLO https://artifacts.chirpstack.io/downloads/chirpstack-mqtt-forwarder/vendor/kerlink/klkgw/chirpstack-mqtt-forwarder_4.6.0-r1_klkgw.ipk
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
  -e 's/border_gateway = false/border_gateway = true/' \
  -e 's/border_gateway_ignore_direct_uplinks = false/border_gateway_ignore_direct_uplinks = true/' \
  -e 's/frequencies = \[868100000, 868300000, 868500000\]/frequencies = [865062500, 865402500, 865985000]/' \
  -e 's/tx_power = 16/tx_power = 36/' \
  $ETC/chirpstack-gateway-mesh.toml

grep -q 'log_to_syslog = true' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: log_to_syslog override did not apply - check upstream template format" >&2; exit 1; }
grep -q 'border_gateway = true' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: border_gateway override did not apply - check upstream template format" >&2; exit 1; }
grep -q 'border_gateway_ignore_direct_uplinks = true' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: border_gateway_ignore_direct_uplinks override did not apply - check upstream template format" >&2; exit 1; }
grep -q 'tx_power = 36' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: tx_power override did not apply - check upstream template format" >&2; exit 1; }
grep -q '865062500' $ETC/chirpstack-gateway-mesh.toml || { echo "ERROR: frequencies override did not apply - check upstream template format" >&2; exit 1; }

# root_key / signing_key: the upstream template has dropped these fields
# entirely in some versions, leaving the mesh with no shared key at all.
# This MUST match the value configured in relay_gw.sh on every relay, or
# every relayed packet will be silently dropped here (border looks fine,
# relay looks fine, nothing reaches the network). Rotate this value in both
# scripts together if it's ever changed - it is not a secret worth
# protecting in this file, but it does need to be consistent mesh-wide.
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
sed -i s/eu868/in865/ /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml
sed -i s@/tmp/concentratord@/tmp/gateway_relay@g /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml
sed -i 's/enabled="semtech_udp"/enabled="concentratord"/' /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml

sed -i s@tcp://127.0.0.1:1883@tcp://chirpstack.mcci.io:1883@ /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml

# set up sysV and monit scripts
sed s/concentratord/gateway-mesh/g /etc/init.d/chirpstack-concentratord >/etc/init.d/chirpstack-gateway-mesh
chmod +x /etc/init.d/chirpstack-gateway-mesh
sed -i s@/gateway-mesh.toml@/chirpstack-gateway-mesh.toml@ /etc/init.d/chirpstack-gateway-mesh
sed s/concentratord/gateway-mesh/g /etc/monit.d/chirpstack-concentratord >/etc/monit.d/chirpstack-gateway-mesh

# restart services
/etc/init.d/monit restart
for s in mqtt-forwarder gateway-mesh concentratord; do
  monit restart chirpstack-${s}
done
