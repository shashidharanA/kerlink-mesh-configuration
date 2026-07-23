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
sed -i \
  -e 's/log_to_syslog = false/log_to_syslog = true/' \
  -e 's/frequencies = \[868100000, 868300000, 868500000\]/frequencies = [865062500, 865402500, 865985000]/' \
  -e 's/tx_power = 16/tx_power = 36/' \
  $ETC/chirpstack-gateway-mesh.toml

# Channel plan / region setup
cp -r /etc/chirpstack-gateway-mesh/region_in865.toml /etc/chirpstack-gateway-mesh/channels.toml
cp -r /etc/chirpstack-concentratord/examples/channels_in865.toml /etc/chirpstack-concentratord/channels.toml
sed -i s/EU868/IN865/g /etc/chirpstack-concentratord/concentratord.toml

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
