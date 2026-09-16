# Kerlink Gateway Mesh Configuration

This repository contains the setup steps, scripts, and configuration required to configure a **Kerlink Gateway with ChirpStack Gateway Mesh**.

See `TROUBLESHOOTING.md` for the full debugging history behind the current state of `border_gw.sh`/`relay_gw.sh` (config drift that took the relay offline, the 37.5-minute reboot loop, the "Relay Gateways" tab showing offline despite a working relay), the remote time-sync-over-mesh mechanism, and a deployment checklist for a new relay. This README covers the setup steps only.

## Table of Contents

- [Gateway Setup](#gateway-setup)
  - [1. Factory Reset](#1-factory-reset)
  - [2. Install Needed pakages](#2-install-needed-pakages)
  - [3. disable lorad/lorafwd](#3disable-loradlorafwd)
  - [4. Install MQTT Forwarder - only in border gateway](#4-install-mqtt-forwarder---only-in-border-gateway)
- [Remote time-sync (relay gateways)](#remote-time-sync-relay-gateways)
  - [Node-RED flow files in this repo](#node-red-flow-files-in-this-repo)
- [Verifying a deployment](#verifying-a-deployment)

---

# Gateway Setup
(Follow the steps in both the gateway)
**Gateway OS: keros 5** 

If you are in keros 6 need to downgrade use this below command

```bash
curl --compressed -s https://upgrade.wanesy.com/DowngraderToFw5.12.0 | sudo sh
```
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

**On genuinely new hardware, `relay_gw.sh` needs to be run twice.** If `chirpstack-concentratord` isn't already installed, the script installs it and reboots partway through — SSH back in once it's back up and run `./relay_gw.sh` again to finish the rest (mesh config, `settime.sh`, monit units, disabling the connectivity watchdog). On a device that already has concentratord installed, one run is enough.

`relay_gw.sh` now also, automatically:
- Pins `root_key`/`signing_key`/`max_hop_count` explicitly (rather than trusting whatever the upstream config template happens to default to that day — this drifted before and took the relay offline for weeks; see `TROUBLESHOOTING.md`).
- Installs `/usr/local/bin/settime.sh` and wires it up as a ChirpStack Gateway Mesh proprietary command handler (type `129`), so the relay's clock can be corrected remotely over the mesh — it has no GPS and no internet, so this is its only path to accurate time. See "Remote time-sync" below.
- Disables KerOS's `networkmonitoring.py` connectivity watchdog. That service assumes every gateway always has internet and reboots the whole board when it can't reach `8.8.8.8` — which happens constantly on a relay by design, causing a reboot roughly every 37.5 minutes and dropping in-flight uplinks. This should stay disabled on relays; leave it enabled on border gateways, which do have real internet.

If VPN need to be installed (Optional)

you would need to install VPN in both gateways:
```bash
curl -s https://upgrade.wanesy.com/vpn | sh
```

---

## Remote time-sync (relay gateways)

The Wirnet iFemtoCell-evolution has no GPS and no RTC battery. A relay
(deployed with no internet) has no way to get accurate time on its own —
its clock free-runs from whatever it booted with. `relay_gw.sh` provisions
the relay side of a fix for this (see above); the other half runs in
**Node-RED**, publishing a time-sync command over MQTT every few hours,
which the border forwards to the relay over the LoRa mesh itself.

Setup (already done for the current deployment; needed again only when
adding a new relay or a new Node-RED instance):
1. Import `node-red-flow-relay-time-sync-ADDITION-ONLY.json` into Node-RED
   (Import menu). It reuses your existing ChirpStack MQTT broker node — no
   new credentials needed.
2. To add another relay to the sync schedule, open the **"Build relay
   time-sync command (protobuf)"** function node and add the new relay's ID
   to the `RELAY_IDS` array at the top.
3. Trigger the inject node manually once and confirm the **"relay-time-sync-ack"**
   debug output shows the relay's corrected time.

Full details — why this needed hand-rolled Protobuf encoding, the exact MQTT
topics/schema, and the BusyBox `date` quirk — are in `TROUBLESHOOTING.md`.

### Node-RED flow files in this repo

There are three Node-RED JSON files here — only one of them is meant to be imported:

- **`node-red-flow-relay-time-sync-ADDITION-ONLY.json`** — **import this one.**
  Contains only the 6 new time-sync nodes, nothing else. Safe to import into
  your existing Node-RED instance with no conflicts, since it doesn't touch
  any node you already have. If you update the time-sync logic again later
  (e.g. adding a relay to `RELAY_IDS`), re-importing this file will prompt
  that these 6 nodes already exist — choose **replace** in that case, since
  you're intentionally updating nodes you already own.
- **`node-red-flows-original.json`** — a saved snapshot of your Node-RED flow
  *before* the time-sync nodes were added. Reference/backup only — do not
  import this. It contains your entire pre-existing flow, so importing it
  back would conflict with (and risk overwriting) everything currently
  deployed.
- **`node-red-flows-relay-time-sync.json`** — your original flow plus the 6
  new nodes, combined into one file, kept for reference/diffing. Also do not
  import this into the same Node-RED instance you already deployed to — same
  reason as above, it would conflict with every node you already have.

If you're setting up Node-RED **from scratch** on a different instance (not
adding to the existing 24/7 one), `node-red-flows-relay-time-sync.json` is
the one to import instead, since it includes everything in one file.

---

## Verifying a deployment

```sh
# On either gateway: check mesh process health and key config
monit status
grep -nE 'root_key|signing_key|tx_power|frequencies|max_hop_count|log_to_syslog' \
  /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml

# Watch live mesh activity (log_to_syslog=true is set by both scripts now)
grep -i mesh /var/log/messages | tail -50

# On a relay: confirm the connectivity watchdog is disabled and not running
grep monitor_network /etc/network/networkmonitoring.conf
ps | grep networkmonitoring   # should show nothing but the grep itself
```

See `TROUBLESHOOTING.md` §7 for a full new-relay deployment checklist,
including the "don't trust it while Ethernet is still attached" trap for
verifying the connectivity-watchdog fix.