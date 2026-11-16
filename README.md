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

It also creates the `deploy`, `publisher` and an admin account (default `pxeadmin`, change with `--admin-user`), the folders under `/srv`, and the config files. It then starts the services and checks that nothing is exposed on the office card.

## Before you run it

1. Install Debian 13 (netinst, text installer). Select only **SSH server** and **standard system utilities**.
2. Connect the **internet NIC** to your office network. Connect the **deploy NIC** to the PC side.
3. Get the boot files from your own build onto the server, for example into `/root`:
   `ipxe-shim.efi`, `ipxe.efi`, `wimboot`, `BCD`, `boot.sdi`, `boot.wim`.
   They are not part of this repository.

## Run it

Download it, read it, test it with a dry run, then run it as root:

```bash
wget https://raw.githubusercontent.com/jaystar1138/pxe-debian-setup/v1.2.0/pxe-setup.sh
less pxe-setup.sh
chmod +x pxe-setup.sh
./pxe-setup.sh --dry-run
./pxe-setup.sh
```

`wget` is already on a fresh Debian install (`curl` is not). Do not pipe the script straight into `bash`: it runs as root, so read it first.

## Unattended install (optional)

Want to skip the Debian installer questions as well? `unattended/build-unattended-iso.sh` builds a Debian 13 installer ISO that installs itself with no input (like a Windows `autounattend.xml`) and runs `pxe-setup.sh` on first boot.

> **The ISO erases a disk without asking.** Boot it only on a machine you mean to wipe. After a short countdown (10 s by default) the unattended entry starts by itself; pick another entry in the menu to cancel.

Build it on any Linux machine (Debian, Ubuntu, WSL):

```bash
sudo apt install xorriso cpio openssl wget
wget https://raw.githubusercontent.com/jaystar1138/pxe-debian-setup/v1.2.0/unattended/build-unattended-iso.sh
chmod +x build-unattended-iso.sh
./build-unattended-iso.sh --boot-files ~/boot-files
```

It asks for the root and admin passwords (only hashes go on the ISO), downloads and checks the Debian netinst ISO, and writes `pxe-debian-unattended.iso`. Write that to a USB stick (Balena Etcher, or Rufus in "DD mode"), plug the **internet** cable into the server, leave the deploy cable out, and boot from the stick. The server installs, powers off, and on its first boot runs the setup. Plug in the deploy cable and read `/etc/motd` when you log in.

Every choice is an option:

| Choice | Options |
| --- | --- |
| Boot files | `--boot-files DIR` (copied onto the ISO), `--boot-files-url URL` (downloaded on first boot), or neither (set up without them) |
| Disk to erase | `--disk smallest` (default, with `--disk-min-gb` / `--disk-max-gb` size guard), `--disk /dev/sdX`, or `--disk ask` |
| Passwords | `--passwords prompt` (default), `generate`, or `hash-file` with `--hash-file FILE` |
| Admin account | `--admin-user NAME` (default `pxeadmin`), `--ssh-key FILE` to allow a key |
| After the install | `--finish poweroff` (default) or `reboot`; `--no-first-boot` to install Debian only |
| Setup | `--setup-args "..."` passed to `pxe-setup.sh`, `--script FILE`, `--script-url URL` |
| Machine | `--hostname`, `--timezone`, `--keyboard`, `--locale`, `--mirror`, `--menu-timeout` |

Notes:

- With `--disk smallest` the installer never picks the USB stick it started from or a removable disk, and it stops without erasing anything if the smallest disk is outside the size range.
  When it stops, the screen stays on "Starting up the partitioner" and the machine powers off after 60 seconds. The reason is in the installer log: press Alt+F4 during that minute.
- `--finish reboot` can start the install again if the USB stick is still plugged in. The default, power off, avoids that.
- If the first-boot setup fails, `/etc/motd` and `/root/PXE-SETUP-RESULT.txt` say so, and the logs are `/var/log/pxe-firstboot.log` and `/var/log/pxe-setup.log`. It retries on the next two boots, then stops. You can always run `/root/pxe-setup.sh` by hand.
- Do not put the ISO in a public place if you used `--boot-files`: it then contains your boot files.

## Options

| Option | Meaning |
| --- | --- |
| `--deploy-nic NAME` | the card facing the PCs (default: the one spare physical card) |
| `--inet-nic NAME` | the card facing the office (default: the one with the default route) |
| `--admin-user NAME` | the administrator account: SSH login and Samba admin (default: `pxeadmin`) |
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

## Licence

[MIT](LICENSE). Use, copy, modify and share it freely. Earlier tags up to `v1.0.2` were released under the PolyForm Internal Use License 1.0.0; from `v1.1.0` onward the licence is MIT.
