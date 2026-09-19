# Manual checks

`kata test` runs everything that can be run from the host with no guest. This
file is the remainder — checks that need a **running guest**, a **second
machine**, or a **reboot**, and therefore cannot be a suite without lying about
what they cover.

The rule this whole directory is organised around: **an invariant with no
runnable check is a claim.** This file is the explicit list of claims that are
verified by hand, so that the absence of a test for them is a decision and not an
oversight. If you find a way to automate one, move it and delete the row.

Run this after first setup, after a kernel / qemu / podman upgrade, and after any
`kata gpu-mode` change (it rewrites the initramfs). `✗` in *expect* means **the
action must fail** — the gate doing its job looks like something not working.

Threat slugs refer to `knowledge/threat-model.md`.

---

## The emulated device surface — Q0 (`threat: qemu-device-surface`)

`tests/unit.sh` Q1–Q5 assert the flags are *present in the script*. Only a
running guest proves they are **harmless**, and only a live `qtree` proves the
device set is what we claim — a qemu upgrade can reintroduce a default without
touching our command line.

Re-run after **any qemu upgrade**. `smm=off` is the flag most likely to break a
boot; bisect the `QEMU_MACHINE` line from there.

```bash
kata vm --ssh                       # must boot; if it hangs, see smm=off
sudo cat /proc/$(pgrep -f 'qemu.*agent' | head -1)/cmdline | tr '\0' ' '
```

| # | invariant | run | expect |
| --- | --- | --- | --- |
| Q0a | the guest boots at all with the stripped machine | host: `kata vm --ssh` | ✓ shell |
| Q0b | …and with the GPU attached | host: `kata vm --gpu --ssh`, then guest: `nvidia-smi` | ✓ the 4090 |
| Q0c | no VGA device is on the bus | guest: `lspci -nn \| grep -Ei 'vga\|display'` | ✗ nothing (under `--gpu`: the 4090 **only**) |
| Q0d | no PS/2 keyboard or mouse | guest: `cat /sys/class/input/*/name` | `Power Button` only — **not** empty, see below |
| Q0e | no HPET | guest: `sudo dmesg \| grep -i hpet` | ✗ nothing |
| Q0f | the device count has not crept back up | host: `printf 'info qtree\nquit\n' \| qemu-system-x86_64 -nodefaults -machine "$QEMU_MACHINE" … -monitor stdio` | 14 device types |

**`/dev/input/` is not empty, and must not be.** An earlier draft of Q0d
expected nothing there. `event0` is the **ACPI power button**, which is
load-bearing: `kata vm --stop` presses it over HMP and the guest's logind reacts
to that input event to shut down. An empty `/dev/input/` would mean `--stop` had
silently become a hard kill — i.e. no clean poweroff, and therefore **no `--to`
bake**, which only shows up as a warm base that mysteriously never updates.
`mice` is the mousedev aggregate node; the kernel creates it whether or not a
mouse exists. Check the *names*, not the count. (This is the over-claiming check
the rest of this repo keeps warning about, caught on Q0d's first live run.)

## Egress, from inside the guest — T1–T4 (`threat: dns-raw-exfil`)

The host cannot answer these on the guest's behalf, which is the entire reason
`scripts/audit-egress.sh` is not in `kata test`.

```bash
kata ssh
audit-egress.sh          # must print: 4 passed, 0 failed
```

| # | invariant | expect |
| --- | --- | --- |
| T1 | no DNS to a public resolver | ✗ no reply |
| T2 | no direct TCP — egress is proxy-only | ✗ refused |
| T3 | no raw / AF_PACKET sockets | ✗ denied |
| T4 | the proxy *is* reachable (positive control) | ✓ 2xx/3xx |

Re-run it with `--gpu` attached. The GPU is a PCI device, not a network path, so
the result must be **identical**; a difference means passthrough widened
something.

Two more from inside, which the host's 403 probe explicitly does **not** prove
(it is issued host→loopback and never traverses the bridge):

```bash
HTTP_PROXY= HTTPS_PROXY= curl --max-time 4 https://1.1.1.1/   # ✗ fails anyway
curl https://example.com/                                     # ✗ 403 from the gate
curl https://pypi.org/simple/                                 # ✓ 200, no cert error
sudo apt-get update                                           # ✓ (it ignores HTTP_PROXY;
                                                              #    /etc/apt/apt.conf.d does it)
```

## The interchange is one-way — G1–G6 (`threat: git-interchange`)

`tests/host.sh` covers G4 (bridge binding) automatically. The rest need a guest.

| # | invariant | run | expect |
| --- | --- | --- | --- |
| G1 | the ingress repo refuses pushes | guest: `git push git://$HOST_IP:9418/<name>.git HEAD:refs/heads/x` | ✗ `service not enabled` |
| G2 | the egress repo accepts them (control) | guest: `git push origin HEAD` | ✓ lands in `<name>-agent.git` |
| G3 | non-exported repos are invisible | guest: `git ls-remote git://$HOST_IP:9418/other.git` | ✗ `repository not exported` |
| G5 | unreachable from the LAN / tailnet | **another host**: `git ls-remote git://<tailnet-ip>:9418/x.git` | ✗ refused |
| G6 | `kata down` closes the port even with the daemon up | host: `kata down`, then guest: `git ls-remote …` | ✗ no route |

G2 is the one people skip, and it is the one that makes G1 mean anything: without
it, a daemon that refuses *everything* passes G1 and G3 while the workflow is
broken.

Also worth doing once per repo pair, since it cannot be inferred from a running
daemon — the append-only settings on the egress side:

```bash
git -C /mnt/shared-storage/src/<name>-agent.git config --get receive.denyDeletes
git -C /mnt/shared-storage/src/<name>-agent.git config --get receive.denyNonFastForwards
# both: true. Repos created before 2026-08-02 need these backfilled by hand.
```

## Local search stays local — S2–S6 (`threat: searxng-host-netns`)

`tests/host.sh` covers S1. The rest:

| # | invariant | run | expect |
| --- | --- | --- | --- |
| S2 | unreachable from the LAN / tailnet | **another host**: `curl http://<tailnet-ip>:8131/` | ✗ refused |
| S3 | the JSON API answers (control) | guest: `curl "http://$HOST_IP:8131/search?q=test&format=json"` | ✓ 200 + JSON |
| S4 | no cred / tailnet path is used | guest: `enap search …` with `SEARXNG_URL` unset | ✗ resolve failure, never a VPS hit |
| S5 | unprivileged in-container | host: `sudo podman inspect agent-searxng -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}}'` | `977:977 true` |
| S6 | `kata down` closes the port | host: `kata down`, then guest: `curl …:8131` | ✗ no route |

S3 is asserted by `kata web up` itself on every start, because the image ships
`search.formats: [html]` and answers **403** to `format=json` without the
override — a working web UI proves nothing.

## GPU passthrough widens nothing (`threat: kernel-cve`)

| invariant | run | expect |
| --- | --- | --- |
| interrupt remapping is on | host: `kata doctor --gpu` | ✓ supported — **never** `allow_unsafe_interrupts=1` |
| the IOMMU group holds only the GPU + its audio function | host: `kata gpu-mode status` | exactly 2 devices |
| `--gpu` refuses while the host owns the card | host, in host mode: `kata vm --gpu` | ✗ refuses with instructions |
| the egress audit is identical with the GPU attached | guest: `audit-egress.sh` | ✓ 4 passed |

Recheck the group after any firmware update: VFIO binds at group granularity, so
a group that grew a bridge/NIC/NVMe would hand those to the guest too.

## Storage and process posture

`tests/host.sh` H1–H4 and `tests/guards.sh` W4 cover the automatable half. These
need a mounted key or a live session:

| invariant | run | expect |
| --- | --- | --- |
| the agent cannot enter or list snapshots (`threat: storage-persistence`) | host: `sudo -u agent ls /mnt/snapshots` | ✗ permission denied |
| a pre-session snapshot was actually taken | host: `kata disk mount`, then `sudo ls /mnt/snapshots` | ✓ a read-only snapshot exists |
| `@bases`/`@snapshots` are siblings of the home, not nested | host: `kata disk status` | separate subvolumes, you-/root-owned |
| the home really is the share, not the image (`nofail` cuts both ways) | guest: `mount \| grep virtiofs` | ✓ mounted at `/home/agent` |

That last one is the "my files are gone" check. `nofail` means a failed share
boots the guest into the image's empty `/home/agent` instead of stopping.

## After a `kata gpu-mode` switch — not security, but it will confuse you

Switching modes **renames your display connector** (two DRM cards vs one, so the
Intel panel is `eDP-2` in host mode and `eDP-1` in sandbox mode). Anything keyed
to the connector name silently stops matching: monitor scale rules, `hyprpaper`,
waybar's `output`. Match on `desc:` instead — stable in both modes.

Not a katastrophe bug, but `gpu-mode` causes it, so it belongs on this list.
