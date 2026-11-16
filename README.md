# pxe-debian-setup

One script that turns a fresh **Debian 13** machine with **two network cards** into a PXE deployment server for Windows PCs.

- **Internet NIC**: your office network. Used for SSH, updates and packages.
- **Deploy NIC**: a switch or cable to the PCs you want to image. Gets the fixed address `10.10.10.1/24` with **no gateway**.

The server never routes between the two cards, so imaged PCs cannot reach the office and your DHCP server never answers office PCs.

## What the script sets up

| Service | Job | Listens on |
| --- | --- | --- |
| dnsmasq | DHCP and TFTP | deploy NIC only |
| nginx | HTTP: boot script, WinPE files, images, drivers, apps, log uploads | `10.10.10.1:80` |
| Samba | SMB shares `deploy`, `publish`, `logs`, `boot` | deploy NIC only |

It also creates the `deploy`, `publisher` and `nciadmin` accounts, the folders under `/srv`, and the config files. It then starts the services and checks that nothing is exposed on the office card.

## Before you run it

1. Install Debian 13 (netinst, text installer). Select only **SSH server** and **standard system utilities**.
2. Connect the **internet NIC** to your office network. Connect the **deploy NIC** to the PC side.
3. Get the boot files from your own build onto the server, for example into `/root`:
   `ipxe-shim.efi`, `ipxe.efi`, `wimboot`, `BCD`, `boot.sdi`, `boot.wim`.
   They are not part of this repository.

## Run it

Download it, read it, test it with a dry run, then run it as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/jaystar1138/pxe-debian-setup/v1.0/pxe-setup.sh
less pxe-setup.sh
chmod +x pxe-setup.sh
./pxe-setup.sh --dry-run
./pxe-setup.sh
```

Do not pipe it straight into `bash`. It runs as root, so read it first.

## Options

| Option | Meaning |
| --- | --- |
| `--deploy-nic NAME` | the card facing the PCs (default: the one spare physical card) |
| `--inet-nic NAME` | the card facing the office (default: the one with the default route) |
| `--boot-files DIR` | where the six boot files are (default: `/root`) |
| `--data-disk DEVICE` | format an **empty** disk (erases it) and mount it at `/srv` |
| `--prompt-passwords` | type the Samba passwords instead of generating them |
| `--reset-passwords` | on a re-run, set new Samba passwords (default: keep existing ones) |
| `--yes` | do not ask for confirmation |
| `--dry-run` | show what would happen and change nothing |

## Safe to re-run

You can run it again, for example to add boot files later with `--boot-files`. It backs up any config file it changes (`*.bak-<timestamp>`) and keeps existing Samba passwords.

## Passwords

The script generates three Samba passwords, prints them once, and saves them to `/root/pxe-setup-passwords.txt` (readable by root only). The deployment engine needs the `deploy` password.

## What it refuses to do

- Run with IP forwarding on.
- Run with fewer than two physical network cards.
- Use a card that already has an address, or that carries the default route, as the deploy card.
- Erase a disk that is mounted or already has partitions.

## Test it on a PC

Connect a PC to the deploy NIC, open its boot menu (usually `F12`) and choose **UEFI: PXE IPv4**. Watch the server with:

```bash
journalctl -u dnsmasq -f
```

You should see `DHCPOFFER` and the shim being sent. The full log of the setup run is in `/var/log/pxe-setup.log`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Found 1 network card(s)" | Add a second card (a USB adapter works) and run again. |
| "More than one spare card" | Pass `--deploy-nic NAME`. List cards with `ip -br link`. |
| `nginx` will not start after a reboot | `ifup <deploy-nic>`, then `systemctl restart nginx`. |
| PC gets no address | Check the cable is on the deploy NIC; read `journalctl -u dnsmasq`. |
| PC loads the shim then stops | Try once with Secure Boot off; confirm both `.efi` files are in `/srv/tftp`. |
| Images list is empty | `/srv/images/list.json` is a placeholder (`[]`) until you replace it with your image list. |
