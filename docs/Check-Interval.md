# Check Interval and the Other "Intervals"

PinPoint has a **Check interval** setting: how often Nagios checks each device and service. Four
different timers sit behind what you see on the dashboard, and people often mix them up. This page
explains each one, what the installer guarantees, and how to check it.

## The four timers

| Timer | What it controls | Who sets it | Default |
|---|---|---|---|
| **Check interval** | How often Nagios checks each device and service that PinPoint generated. | Administrator, in Settings → System. Choices: 1, 2, 5, 10 or 15 minutes. | 5 minutes |
| **Discovery scan frequency** | How often PinPoint scans the network for new devices and open ports. It does not run Nagios checks and does not decide how fresh a result is. | Administrator, in the system settings. | See the PinPoint settings page |
| **Status poll** | How often PinPoint reads the latest results from Nagios. | Fixed at 60 seconds. Not a setting. | 60 seconds |
| **Dashboard refresh rate** | How often your own browser asks PinPoint for new data. | Each user, in Settings → General. Choices: Manual, 1, 5 or 15 minutes. | Per user |

Changing one of these does not change the others. In particular:

- Changing the **dashboard refresh rate** only changes how often your browser reloads. It does not
  make Nagios check any faster.
- Changing the **check interval** changes how often Nagios checks. It does not change the status poll
  or anyone's dashboard refresh rate.

## How fresh is what I see?

A result can be as old as the check interval, plus up to 60 seconds for the status poll, plus your
browser refresh rate. With the defaults, a change on a device can take up to about 5 minutes to be
checked and a further minute to be read. Pinpoint treats a result as stale after the check interval
plus up to 60 seconds. To see changes sooner, lower the **check interval**, not the dashboard refresh
rate.

## What the setting changes, and what it does not

The check interval applies to the hosts and services that PinPoint generates (the devices found by
Network Discovery and the plugin services). PinPoint writes them to
`/usr/local/nagios/etc/objects/hosts.cfg` and the plugin services file, and reloads Nagios.

It does **not** change the checks that come with stock Nagios in `localhost.cfg`. Those keep their own
intervals.

When you save a new value, PinPoint validates the new Nagios configuration first and keeps a backup of
the old one. If validation or the Nagios reload fails, PinPoint shows an error, keeps the old setting
and old configuration, and Nagios keeps running with the old cadence.

## What the installer guarantees

The installer prepares the server so the setting works. It does not own the setting itself; the
PinPoint application does.

### 1. Nagios counts in minutes

Nagios measures intervals in units. The `interval_length` option in `nagios.cfg` says how many seconds
one unit lasts. PinPoint writes the check interval in minutes, so `interval_length` must be **60**. If
it were 30, "2 minutes" would really be 1 minute; if it were 1, it would be 2 seconds.

The installer makes sure it is 60, on a new install and on every upgrade:

- If the value is 60, or missing (Nagios then uses 60), nothing changes.
- If it is anything else, the installer saves a timestamped copy of `nagios.cfg`
  (`nagios.cfg.interval-length.<date>.bak`), sets one line `interval_length=60`, checks the file with
  `nagios -v`, and reloads Nagios so the change takes effect.
- If `nagios -v` rejects the file, the installer puts the saved copy back and stops with an error.
  During an upgrade, nothing else has been changed at that point.

This is done by `setup/ensure-nagios-interval.sh`, which both `configure-nagios.sh` (install) and
`deploy-pinpoint-web.sh` (install and upgrade) run.

### 2. PinPoint may reload or restart Nagios, and nothing else

The `pinpoint` service account can run exactly two privileged commands on Nagios:
`sudo -n systemctl reload nagios` and `sudo -n systemctl restart nagios`. The second is used by
proactive resolution and comes from `/etc/sudoers.d/pinpoint-restart`. It can also validate a
configuration with `nagios -v` and replace the PinPoint-generated config files.

It cannot stop or start Nagios, and it cannot restart any other service. PinPoint validates every new
configuration with `nagios -v` before it asks for a reload, and puts its backup back if validation or
the reload fails. Configuration changes only need reload, so a mistake there cannot stop the service. `configure-pinpoint-privileges.sh` checks all of this
during install, without reloading Nagios, and stops with an error if `pinpoint` has any extra rights over
Nagios. It rewrites its own sudoers file (`/etc/sudoers.d/pinpoint-nagios-reload`) every time it runs, so
a hand edit to that one file is repaired silently. A rule added in a different file is reported as an
error.

### 3. The database has the setting

The setting is stored in `SYSTEM_SETTINGS.Check_Interval` and is added by the PinPoint migration. After
the migration, the installer checks, without changing anything, that:

- the `Check_Interval` column exists, and
- every value is one of 1, 2, 5, 10 or 15, and
- if the column was just added by this upgrade, every existing row holds 5.

If a check fails, the install stops, or the upgrade is rolled back to the previous version, including
its database.

## How to check a server

Run these on the PinPoint server.

| Check | Command | Expected |
|---|---|---|
| Nagios counts in minutes | `grep -E '^interval_length' /usr/local/nagios/etc/nagios.cfg` | `interval_length=60` (or no line) |
| Config is valid | `sudo /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg` | 0 errors |
| PinPoint can reload | `sudo -u pinpoint sudo -n -l systemctl reload nagios` | Prints the command |
| PinPoint can restart Nagios only | `sudo -u pinpoint sudo -n -l systemctl restart nagios`, then the same with `sshd` | First prints the command, second refused |
| PinPoint cannot stop | `sudo -u pinpoint sudo -n -l systemctl stop nagios` | Refused (non-zero exit) |
| Installer logs | `/var/log/pinpoint-configure.log`, `/var/log/pinpoint-web.log`, `/var/log/pinpoint-privileges.log` | Lines starting with `✓` |

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| Checks run at the wrong speed after you change the interval | `interval_length` is not 60 | Run the installer again, or set `interval_length=60`, validate with `nagios -v`, then `sudo systemctl reload nagios`. |
| Saving the interval shows "could not be applied" | Nagios rejected the new config, or the reload was refused | The old setting is kept. Check `nagios -v` and the `pinpoint` sudo rule. |
| Install stops with "interval_length is not 60 and could not be fixed" | `nagios -v` rejected the file after the change | The saved copy was restored. Fix the reported error in `nagios.cfg`, then run again. |
| Upgrade stops with "Check_Interval is missing or invalid" | The PinPoint migration did not apply, or a value is out of range | The upgrade is rolled back. Check `/var/log/pinpoint-web.log` and the PinPoint version. |
| The dashboard still feels slow after a faster check interval | The status poll (60 s) and your browser refresh rate still apply | Lower your dashboard refresh rate. |
