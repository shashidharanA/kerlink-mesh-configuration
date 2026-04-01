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
sed -i 's/border_gateway = true/border_gateway = false/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml
freqs=$(awk '$1=="]" {p--} p{print} /multi_sf_channels/{p++}' /etc/chirpstack-concentratord/channels.toml | tr -d \\n | sed s/,$//)
sed -i "s/frequencies =.*/frequencies = [$freqs]/" /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml
sed -i 's/tx_power = 16/tx_power = 36/' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml

# set up sysV and monit scripts
sed s/concentratord/gateway-mesh/g /etc/init.d/chirpstack-concentratord >/etc/init.d/chirpstack-gateway-mesh
chmod +x /etc/init.d/chirpstack-gateway-mesh
sed -i s@/gateway-mesh.toml@/chirpstack-gateway-mesh.toml@ /etc/init.d/chirpstack-gateway-mesh
sed s/concentratord/gateway-mesh/g /etc/monit.d/chirpstack-concentratord >/etc/monit.d/chirpstack-gateway-mesh

# set up local config (regional parameters)
ln -fs /etc/chirpstack-gateway-mesh/region_in865.toml /etc/chirpstack-gateway-mesh/channels.toml
ln -fs /etc/chirpstack-concentratord/examples/channels_in865.toml /etc/chirpstack-concentratord/channels.toml
sed -i s/EU868/IN865/g /etc/chirpstack-concentratord/concentratord.toml

# restart services
/etc/init.d/monit restart
for s in gateway-mesh concentratord; do
  monit restart chirpstack-${s}
done
