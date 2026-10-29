# StandUpSitDown

macOS menu bar app that reminds you to change posture. Every N minutes (default 40) it covers all screens with an overlay that stays on top of everything, including full-screen apps, until you confirm that you are now sitting, standing or moving. You can also skip with a reason. The UI is in German.

## Install

Requires macOS 14+ and Xcode command line tools.

```sh
./install.sh            # build, sign ad-hoc, copy to ~/Applications, register LaunchAgent (autostart)
./install.sh --build-only
SIGN_IDENTITY="Apple Development" ./install.sh   # sign with your own certificate
```

## Usage

- Menu bar: current posture and time left. Click for posture correction, interval (5 to 120 min) and stats for today and the last 7 days.
- Overlay: pick a posture with a click or keys 1 to 3. Your current posture is disabled. "Geht gerade nicht …" skips until the next interval and records the reason.
- While the overlay is shown, Cmd-Q, Cmd-Tab, Dock and menu bar are blocked.

## Data

Events are appended to `~/Library/Application Support/StandUpSitDown/log.csv`:

```
timestamp,event,from,to,reason,interval_min,response_sec
```

`event` is one of `start`, `change`, `skip`, `manual`, `quit`.

For testing, `STANDUP_INTERVAL_SECONDS=10` overrides the interval.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/io.github.derveloper.standupsitdown
rm -rf ~/Applications/StandUpSitDown.app ~/Library/LaunchAgents/io.github.derveloper.standupsitdown.plist
```
