# Kerlink Gateway Mesh Configuration

This repository contains the setup steps, scripts, and configuration required to configure a **Kerlink Gateway with ChirpStack Gateway Mesh**.

---

# Gateway Setup
(Follow the steps in both the gateway)
**Gateway OS: keros 5** 
### 1.) Factory Reset

Performed a simple factory reset through the **Web UI**.

**Path:**

Administration → Gateway → Reset Gateway → Reboot Gateway



### 2.) Install Needed pakages

#### Via SSH

```bash
cd /user/.updates

wget https://wikikerlink.fr/wirnet-productline/lib/exe/fetch.php?media=resources_multi_hardware:keros_5.11.0_klkgw-signed.ipk

sync
kerosd -u

wget https://artifacts.chirpstack.io/downloads/chirpstack-concentratord/vendor/kerlink/ifemtocell/chirpstack-concentratord_4.7.0-r1_klkgw.ipk

sync
kerosd -u

wget https://artifacts.chirpstack.io/downloads/chirpstack-gateway-mesh/chirpstack-gateway-mesh_4.1.0_linux_armv7hf.tar.gz

sync
kerosd -u

reboot
```
### 3.disable lorad/lorafwd
```bash
klk_apps_config --deactivate-cpf
```
### 4 Install MQTT Forwarder - only in border gateway
```bash
cd /user/.updates
wget https://artifacts.chirpstack.io/downloads/chirpstack-mqtt-forwarder/vendor/kerlink/klkgw/chirpstack-mqtt-forwarder_4.5.1-r1_klkgw.ipk
sync
kerosd -u
reboot
```
Then run the border_gw.sh in border gateway (with internet)
```bash
ssh root@192.168.1.110
vim border_gw.sh #copy and past the script in the border_gw.sh and adapt the ChirpStack MQTT hostname and some regional settings (I used IN865) save it and run it
./border_gw.sh
```
Then run the relay_gw.sh in relay gateway (After this installation remove the internet)
```bash
ssh root@192.168.1.111
vim relay_gw.sh #copy and past the script in the relay_gw.sh and adapt the ChirpStack MQTT hostname and some regional settings (I used IN865) save it and run it
./relay_gw.sh
```
If VPN need to be installed (Optional)

you would need to install VPN in both gateways:
```bash
curl -s https://upgrade.wanesy.com/vpn | sh
```