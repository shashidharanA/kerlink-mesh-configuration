# Kerlink Relay Gateway — Debugging Notes & Time-Sync Setup

This document records how the Kerlink relay gateway went from "not sending any
data" to a working, remotely time-synced mesh node, and what to do the next
time a new relay of the same hardware variant is deployed. It assumes you've
read `CLAUDE.md` and `README.md` first for the general mesh topology and
setup steps.

Devices referenced throughout:

| Role | Model | Gateway ID |
|---|---|---|
| Border | Kerlink Wirnet iFemtoCell-evolution 868 | `7076ff0064050e55` |
| Relay | Kerlink Wirnet iFemtoCell-evolution 868 | `64050f40` |

SSH credentials for each device are per-unit and are **not** recorded in this
repo — check whatever your team uses to track device passwords.

## Table of Contents

- [1. Background: no GPS, no persistent clock](#1-background-no-gps-no-persistent-clock)
- [2. Root cause: why the relay went offline for weeks](#2-root-cause-why-the-relay-went-offline-for-weeks)
- [3. Root cause: reboot every ~37.5 minutes, dropping uplinks](#3-root-cause-reboot-every-375-minutes-dropping-uplinks)
- [4. Root cause: "Relay Gateways" tab shows Offline despite working relay](#4-root-cause-relay-gateways-tab-shows-offline-despite-working-relay)
- [5. Durable fix: remote time-sync over the mesh, via Node-RED](#5-durable-fix-remote-time-sync-over-the-mesh-via-node-red)
- [6. Known limitations / things to keep in mind](#6-known-limitations--things-to-keep-in-mind)
- [7. Checklist: deploying a new Kerlink relay gateway (same hardware variant)](#7-checklist-deploying-a-new-kerlink-relay-gateway-same-hardware-variant)
- [8. Quick reference: verifying things over SSH](#8-quick-reference-verifying-things-over-ssh)

---

## 1. Background: no GPS, no persistent clock

The Wirnet iFemtoCell-evolution is an **indoor nano gateway** — confirmed
against Semtech/Kerlink's own datasheet, product page, and the device's own
`/proc/device-tree/model` and device tree (no GPS node present anywhere).
Unlike Kerlink's outdoor base-station line (`IBTS`/`ISTATION` platforms), this
model has no GPS module, no PPS input, and no battery-backed RTC. Its only
designed time source is NTP over Ethernet/cellular backhaul — which this
relay deployment intentionally doesn't have (relays run with no internet,
per `README.md`).

Net effect: on every full power-off, the relay's clock resets to whatever
KerOS defaults to at boot and free-runs from there with no correction. This
turned out to matter more than expected (see §4).

For comparison: the Raspberry Pi 3 + Semtech SX1302 Corecell reference design
used as the other relay in this project also has **no onboard GPS** — per
Semtech's official Reference Design User Guide (Rev 1.3), GPS on that board
is an optional external module wired to the Pi's UART, not something
included by default. If that unit is a used a GPS, someone added it as an
add-on; confirm by physically checking for a small GPS board/antenna wired to
the Pi's GPIO header.

---

## 2. Root cause: why the relay went offline for weeks

Symptom: relay's local `chirpstack-concentratord` and `chirpstack-gateway-mesh`
processes both looked healthy (`monit status` = OK), but no device data ever
reached ChirpStack, and the relay showed no activity for weeks.

Diagnosis compared the relay's live config against the border's:

| Setting | Relay (broken) | Border (working) |
|---|---|---|
| `root_key` / `signing_key` | `00000000...0` | `00000000...0` (matched — not the cause) |
| `tx_power` | `32` | `36` |
| `log_to_syslog` | `false` (should be `true`) | `true` |
| File format | `key=value` (no spaces) | `key = value` (spaced) |

Root cause: **`border_gw.sh` and `relay_gw.sh` fetch `chirpstack-gateway-mesh.toml`
fresh from GitHub's `master` branch on every run, with no version pin.** The
upstream template's formatting and even its field set have changed over time
(root_key/signing_key were removed from the template entirely at some point;
`max_hop_count`'s default changed from `5` to `1`). The scripts' `sed`
overrides use `key = value` (spaced) patterns; when the relay was originally
provisioned, the template it fetched used `key=value` (no spaces), so the
`sed` substitutions **silently no-opped** — no error, just values that never
changed. `tx_power`/`frequencies` on the relay had been hand-corrected at
some point (explaining why those were closer to right, but still off), while
`log_to_syslog` was never touched, leaving **zero log visibility** into the
one process most likely to explain the failure.

With `log_to_syslog` still `false` and the process's stdout/stderr both
pointed at `/dev/null`, there was no way to see what `chirpstack-gateway-mesh`
was actually doing on the relay — the debugging blind spot that made this
take so long to pin down.

### Fix applied
Manually re-provisioned the relay's mesh config to match the border exactly
(same `tx_power`, `frequencies`, `max_hop_count`, `root_key`/`signing_key`,
`log_to_syslog=true`), then confirmed via live logs that the relay was
correctly relaying real uplinks and heartbeats, and that the border was
receiving and forwarding them to ChirpStack via MQTT.

**Both `relay_gw.sh` and `border_gw.sh` have since been updated** to bake
these fixes in permanently — see §7.

---

## 3. Root cause: reboot every ~37.5 minutes, dropping uplinks

Symptom (reported separately, confirmed from an on-device log bundle):
the relay would fully reboot roughly every 37.5 minutes when deployed with
no Ethernet connected (power only) — causing dropped uplinks and repeated
clock resets on top of everything in §1.

### Diagnosis
Extracted the log bundle and found `bootcause=SW` kernel boot events (a
deliberate software-triggered reboot, not a crash or hardware watchdog) at
timestamps 37m29s–37m33s apart, consistently, for as long as the log covered.
`var/log/networkmonitoring.log` from the same window showed the exact
escalation sequence for each cycle:

```
05:32:14  restarting connection using connman   (ping to 8.8.8.8 failing)
05:32:14  Failed... "No default network interface"
05:35:04  restarting network servers
05:40:05  modems and ethernet hardware reboot
05:48:25  action: board reboot                   <- full reboot
06:09:45  cycle restarts...
06:25:56  board reboot                            <- 37m31s later
```

Root cause: **KerOS's built-in connectivity watchdog, `networkmonitoring.py`,
assumes every gateway should always reach the internet.** It pings `8.8.8.8`
on an interval, and after enough consecutive failures escalates through
restarting connman, restarting network servers, power-cycling modem/Ethernet
hardware, and finally rebooting the entire board — controlled by
`/etc/network/networkmonitoring.conf`. A relay is *deliberately* deployed
with no Ethernet/cellular (that's the whole point of the mesh), so this ping
never succeeds, and the watchdog kept escalating all the way to a full board
reboot, forever, in a loop.

This is unrelated to the mesh config drift in §2 and to the time-sync
mechanism in §5 — it would happen on any Kerlink unit deployed without
Ethernet/cellular, from day one. It likely also contributed to the "offline
for weeks" symptom in §2, on top of the config drift: a full reboot every
37.5 minutes disrupts mesh routing continuity and restarts every process
constantly.

A subtlety that caused some confusion mid-investigation: while Ethernet was
connected to the relay for debugging (this whole session), `network
monitoring ok` logged continuously and no reboots occurred — because the
ping to 8.8.8.8 was genuinely succeeding over that bench connection, not
because the watchdog was disabled. This is exactly the failure mode to watch
for: "it's not rebooting" while Ethernet is attached proves nothing about
what happens once it's removed.

### Fix applied
Disabled the watchdog via its master switch, plus its reboot threshold for
defense in depth:
```sh
sed -i 's/^monitor_network=.*/monitor_network=0/' /etc/network/networkmonitoring.conf
sed -i 's/^ping_error_before_board_reboot=.*/ping_error_before_board_reboot=0/' /etc/network/networkmonitoring.conf
/etc/init.d/networkmonitoring restart
```
Confirmed on the live relay: the `networkmonitoring.py` process read the new
`monitor_network=0` on its next check cycle and **exited entirely** (not just
"ran but skipped the reboot action") — verified via `ps` showing no process
and the log's last line matching the pidfile's last-modified time, with no
further entries afterward. Since the process itself is gone, there is no
code path left that could trigger the reboot escalation. It will still start
briefly on every future boot (`rc5.d`), read the same disabled setting from
disk, and exit again almost immediately — harmless.

Note: the observed default for `ping_error_before_board_reboot` on a fresh
unit is `20` per the config file's own comments, though this relay's copy
was found already at `0` at one point during debugging for reasons never
fully explained (possibly a Kerlink Wanesy cloud config push during a
connected window — unconfirmed). Don't rely on an unexplained value staying
put — this is why `relay_gw.sh` now sets it explicitly every time.

**`relay_gw.sh` has been updated** to apply this automatically — see §7.

---

## 4. Root cause: "Relay Gateways" tab shows Offline despite working relay

After the fix in §2, ChirpStack's **Gateway Mesh → Relay Gateways** list
still showed the relay red/Offline, with a `Last seen` stuck weeks in the
past — even though device uplinks were visibly flowing through it.

Root cause: that specific ChirpStack UI reads `Last seen` from the
**self-reported timestamp embedded in the relay's own mesh heartbeat event**
(`SystemTime.tv_sec` in the `MeshEvent` protobuf), not from the border's
local receive time. Since the relay has no GPS/RTC (§1), that embedded
timestamp is whatever its free-running clock says — perpetually stale,
regardless of how healthy the actual RF link is. Regular device-uplink data
looked fine because *that* path stamps time using the **border's** (correct)
clock, not the relay's.

Confirmed by converting the `tv_sec` values seen in the border's logs to UTC
and finding they matched the relay's own broken `date` output exactly.

### Fix applied (stopgap)
Manually set the relay's clock once via SSH (`date -u -s`), pulling accurate
time from the border. This is not durable — no ongoing source means it drifts
and goes stale again. See §5 for the durable fix.

---

## 5. Durable fix: remote time-sync over the mesh, via Node-RED

Since the relay has no GPS and no IP path to an NTP server, the only way to
correct its clock is over the LoRa mesh link itself. ChirpStack Gateway Mesh
has a built-in mechanism for exactly this: **proprietary commands** (type
128–255), which the border forwards to a specific relay over the mesh, where
they invoke a locally-configured script with the command payload on stdin.

### Architecture
```
Node-RED (24/7, existing instance)
  -> publishes MeshCommand (protobuf) on MQTT topic
     in865/gateway/<border-id>/command/mesh
  -> border's chirpstack-mqtt-forwarder receives it, hands to chirpstack-gateway-mesh
  -> forwarded over LoRa mesh RF to the target relay
  -> relay's chirpstack-gateway-mesh executes /usr/local/bin/settime.sh,
     stdin = current UTC time
  -> settime.sh runs `date -u -s`, echoes the result
  -> relay's chirpstack-gateway-mesh sends the echoed output back as an
     Event (same commandType) on in865/gateway/<border-id>/event/mesh
  -> Node-RED's listener decodes it for confirmation/logging
```

### Two non-obvious gotchas discovered while building this
1. **The `command/mesh` MQTT topic expects raw Protobuf, not JSON.** The
   ChirpStack docs show a JSON example, but that only applies if the
   `chirpstack-mqtt-forwarder` config has `json=true` set — this deployment's
   border does not have that set (and per policy, we did not add it, since
   the border's config is otherwise working and shouldn't be touched
   casually). Sending JSON+base64 produced `Handling message error: failed
   to decode Protobuf message: buffer underflow` on the border. The fix was
   to hand-encode the `MeshCommand` protobuf message directly (see the
   Node-RED function node `Build relay time-sync command (protobuf)` for the
   ~30-line encoder — no external protobuf library needed for a message this
   small). Schema verified directly against
   `chirpstack/api/proto/gw/gw.proto`:
   ```
   Command { mesh = 5 (MeshCommand) }
   MeshCommand { gateway_id=1(string), relay_id=2(string), commands=3(repeated MeshCommandItem) }
   MeshCommandItem { proprietary=1(MeshCommandProprietary) }
   MeshCommandProprietary { command_type=1(uint32), payload=2(bytes) }
   ```
   The response event (`event/mesh`) is the mirror `MeshEvent` /
   `MeshEventProprietary` (`event_type` instead of `command_type`) — also raw
   protobuf, decoded in the `Decode settime.sh response (protobuf)` node.
2. **BusyBox's `date -s` rejects ISO-8601.** `date -u -s "2026-09-15T12:53:08Z"`
   fails with `date: invalid date`. It wants `"YYYY-MM-DD HH:MM:SS"`. The
   Node-RED function node formats the timestamp accordingly before sending.

### Files/nodes involved
- **Relay side** (`/usr/local/bin/settime.sh` + a `[commands]` block in
  `chirpstack-gateway-mesh.toml` mapping command type `129` to that script) —
  now provisioned automatically by `relay_gw.sh` (§7).
- **Node-RED side** — 6 nodes added to the existing `Mesh Setup - Chirpstack`
  tab, reusing the existing `chirpstack` MQTT broker node (no new broker/
  credentials needed):
  - `Every 8h - sync relay time` (inject, repeat interval)
  - `Build relay time-sync command (protobuf)` (function — encodes and fans
    out one command per relay ID listed in its `RELAY_IDS` array)
  - `Publish time-sync command` (mqtt out)
  - `Relay mesh events (heartbeat/ack)` (mqtt in, **datatype must be
    "buffer"**, not "auto" — otherwise the binary protobuf gets mangled)
  - `Decode settime.sh response (protobuf)` (function — ignores routine
    heartbeats, surfaces only the settime.sh echo)
  - `relay-time-sync-ack` (debug)

  Exported as `node-red-flow-relay-time-sync-ADDITION-ONLY.json` in this
  repo (import via Node-RED's Import menu — it only contains these 6 nodes,
  so it won't conflict with anything already deployed).

  **To add a new relay to the sync schedule:** open the
  `Build relay time-sync command (protobuf)` function node and add the new
  relay's ID (hex string, from ChirpStack's Relay Gateways list) to the
  `RELAY_IDS` array at the top. No other change needed — the function fans
  out one command per listed relay on every scheduled fire, and the decode
  node already reports whichever `relayId` responds.

### Recovery behavior after a power outage
Config (root_key, tx_power, settime.sh, networkmonitoring.conf, etc.) all
persist across power cycles — it's on flash, not RAM. Only the clock is
lost. On power-up: `monit` auto-starts `chirpstack-gateway-mesh`/
`concentratord` (`on reboot: start`), the relay sends a heartbeat
immediately, and the border learns it's reachable again within moments. The
clock itself won't be corrected until the *next* scheduled Node-RED inject
fires — worst case, up to the full interval (currently 8h) after power-up.
During that window the "Relay Gateways" tab will show Offline again even
though the relay is actually relaying data fine (§4). If faster recovery
after outages matters, either shorten the interval or make the sync
event-triggered off an implausible heartbeat timestamp (not implemented).

---

## 6. Known limitations / things to keep in mind

- **`root_key`/`signing_key` are still the insecure default placeholder**
  (`00000000000000000000000000000000`) on both gateways. This works because
  both sides match, but it provides no real security for the mesh. Rotating
  it to a real random key is a separate task — if done, it must be changed
  in **both** `relay_gw.sh` and `border_gw.sh` (and on any already-deployed
  device) together, or the mesh will break exactly the way it did before.
- **Node-RED is now a dependency for relay clock health.** If the Node-RED
  instance goes down for longer than the sync interval, relay clocks will
  drift stale and "Relay Gateways" will show them offline again (data still
  flows fine — this is cosmetic only, per §4).
- **`relay_gw.sh` still needs to be run twice on genuinely new hardware.**
  The `chirpstack-concentratord` install block ends in a `reboot` on first
  run (since the binary doesn't exist yet); the rest of the script (mesh
  binary, config, `settime.sh`, monit units, watchdog disable) only runs on
  a second pass after that reboot completes.
- **KerOS downgrade and factory reset are still manual**, done before
  `relay_gw.sh` is ever run — see `README.md`.
- This deployment is hardcoded to **IN865** throughout both scripts. Retargeting
  to another region means updating the `sed` overrides, region/channel file
  references, and frequency/power values together in both scripts (see
  `CLAUDE.md`).
- **Border gateways should keep `networkmonitoring.py` enabled** — the §3
  fix is only applied by `relay_gw.sh`, not `border_gw.sh`, since a border
  is supposed to have real internet and the watchdog is doing its intended
  job there.

---

## 7. Checklist: deploying a new Kerlink relay gateway (same hardware variant)

1. Factory reset via Web UI; downgrade KerOS to 5.11/5.12 if it ships on
   KerOS 6 (see `README.md`).
2. SSH in, `vim relay_gw.sh`, paste the current version of the script from
   this repo, run it.
3. **It will reboot partway through** (first-time `chirpstack-concentratord`
   install). SSH back in once it's back up and run `relay_gw.sh` again to
   complete the rest (mesh binary, config, `settime.sh`, `[commands]`
   mapping, monit units, watchdog disable).
4. Verify: `monit status` shows `chirpstack-gateway-mesh` and
   `chirpstack-concentratord` both `OK`; `grep -nE 'root_key|tx_power|max_hop_count' /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml`
   matches the border's values; `grep monitor_network /etc/network/networkmonitoring.conf`
   shows `0`.
5. **Before disconnecting Ethernet for a real deployment**, confirm the
   watchdog is actually disabled and stays that way — don't trust "no
   reboots happened" while Ethernet is still attached (see §3's note on
   this exact trap). Leave it connected a few minutes after the change,
   then physically pull the cable and watch `/var/log/networkmonitoring.log`
   and `uptime` for a while to be sure.
6. Confirm it shows up relaying traffic: check the border's
   `/var/log/messages` for `Unwrapping relayed uplink ... relay_id: <new-id>`
   lines, and/or check ChirpStack's UI once a device sends an uplink through
   it.
7. Add the new relay's ID to the Node-RED `RELAY_IDS` array (see §5) so its
   clock gets synced too.
8. Manually trigger the Node-RED inject node once to confirm the new relay's
   `settime.sh` responds correctly before walking away from the deployment.

---

## 8. Quick reference: verifying things over SSH

```sh
# Check mesh process health and config on either gateway
monit status
grep -nE 'root_key|signing_key|tx_power|frequencies|max_hop_count|log_to_syslog' \
  /etc/chirpstack-gateway-mesh/chirpstack-gateway-mesh.toml

# Watch live mesh activity (requires log_to_syslog=true, already the case
# after running the current relay_gw.sh/border_gw.sh)
grep -i mesh /var/log/messages | tail -50

# Check current clock
date

# On a relay: confirm the connectivity watchdog is disabled and not running
grep monitor_network /etc/network/networkmonitoring.conf
ps | grep networkmonitoring   # should show nothing but the grep itself
uptime                        # sanity check against unexpected reboots
```
