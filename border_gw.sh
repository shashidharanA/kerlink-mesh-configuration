set -e

# disable lorad/lorafwd
klk_apps_config --deactivate-cpf

# install gw mesh binary
latest=$(curl -s https://artifacts.chirpstack.io/downloads/chirpstack-gateway-mesh/|grep -oE chirpstack-gateway-mesh_4.[0-9.]+_linux_armv7hf.tar.gz|sort|uniq|tail -n 1)
curl -sL https://artifacts.chirpstack.io/downloads/chirpstack-gateway-mesh/$latest | tar xz
mv -v chirpstack-gateway-mesh /usr/bin

# download gw mesh config files
ETC=/etc/chirpstack-gateway-mesh
GITHUB=https://raw.githubusercontent.com/chirpstack/chirpstack-gateway-mesh/refs/heads/master/configuration/
mkdir -p $ETC
curl -sL $GITHUB/chirpstack-gateway-mesh.toml >$ETC/chirpstack-gateway-mesh.toml
for region in as9123 as923_2 as923_3 as923_4 au915 eu868 in865 kr920 ru864 us915; do
  curl -sL $GITHUB/region_${region}.toml >$ETC/region_${region}.toml
done
sed -i 's/border_gateway = false/border_gateway = true/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml
sed -i 's/868100000, 868300000, 868500000/865062500, 865402500, 865985000/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml
sed -i 's/tx_power = 16/tx_power = 36/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml
sed -i 's/concentratord_event/gateway_relay_event/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml
sed -i 's/concentratord_command/gateway_relay_command/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml

# set up sysV and monit scripts
sed s/concentratord/gateway-mesh/g /etc/init.d/chirpstack-concentratord >/etc/init.d/chirpstack-gateway-mesh
chmod +x /etc/init.d/chirpstack-gateway-mesh
sed -i s@/gateway-mesh.toml@/chirpstack-gateway-mesh.toml@ /etc/init.d/chirpstack-gateway-mesh
sed s/concentratord/gateway-mesh/g /etc/monit.d/chirpstack-concentratord >/etc/monit.d/chirpstack-gateway-mesh

# config MQTT forwarder
sed -i s@/tmp/concentratord@/tmp/gateway_relay@g /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml
sed -i 's/enabled="semtech_udp"/enabled="concentratord"/' /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml

# set up local config (regional parameters)
ln -fs /etc/chirpstack-gateway-mesh/region_in865.toml /etc/chirpstack-gateway-mesh/channels.toml
ln -fs /etc/chirpstack-concentratord/examples/channels_in865.toml /etc/chirpstack-concentratord/channels.toml
sed -i s/eu868/in865/ /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml
sed -i s/EU868/IN865/g /etc/chirpstack-concentratord/concentratord.toml

sed -i s@tcp://127.0.0.1:1883@tcp://example.com:1883@ /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml

# restart services
/etc/init.d/monit restart
for s in mqtt-forwarder gateway-mesh concentratord; do
  monit restart chirpstack-${s}
done
