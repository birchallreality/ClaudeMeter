# ClaudeMeter

A tiny macOS menu bar item that shows your Claude Code usage limits.

In the menu bar you'll see two small bars, then your session percentage (for example `70%`).

- **Left bar:** your 5-hour session. **Right bar** (thinner): your weekly limit.
- **Fill:** each bar fills from the bottom. It's green below 60%, amber from 60%, and red from 85%. A bar also turns amber early if you're more than 10 points ahead of the clock.
- **Pace line:** the thin line across the session bar marks how far through the 5-hour window you are. If the fill is above the line, you're using quota faster than the clock is running down.
- **Signed out:** faint bars and `—`. If it can't reach Anthropic or is rate-limited, the item dims and keeps showing the last value.

Click it to see a Session section and a Week section. Each has a meter, when it resets, and a pace note: *On pace*, *Ahead of pace*, *High usage*, or *Limit in ~51m*. Below them are Refresh, Open at Login and Quit.

## Install

```sh
./build.sh            # builds ClaudeMeter.app in this folder
./build.sh --install  # builds, copies to ~/Applications, relaunches
```

Then choose **Open at Login** from its menu. The app has no Dock icon.

You need to be signed in to Claude Code with a Pro or Max account. There's no API key to set up.

## How it works

- **Data:** it reads the login token Claude Code already keeps in the Keychain (`Claude Code-credentials`). It uses that token to call the same usage endpoint behind Claude Code's `/usage` command. The token only goes to `api.anthropic.com`, and it's never stored.
- **Updates:** it fetches once a minute.
- **Backoff:** if a request fails or gets rate-limited (HTTP 429), it waits 2m, then 4m, 8m, up to 15m, and never retries sooner than the server's `Retry-After` header. The menu shows when the next retry is. **Refresh** (⌘R) retries right away.
- **Caveat:** the endpoint isn't a public API, so it could change without notice.

To see failed or rate-limited fetches:

```sh
log show --last 1d --predicate 'subsystem == "com.isaac.claudemeter"'
```

## Uninstall

Turn off Open at Login, quit the app, and delete `~/Applications/ClaudeMeter.app`.
