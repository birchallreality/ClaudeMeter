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

You need a Pro or Max account and the Claude Code **command-line tool** installed and signed in (run `claude` in Terminal once). There's no API key to set up. This applies even if you use Claude Code through the Claude desktop app: the desktop app keeps its own login and doesn't renew the one ClaudeMeter reads, so ClaudeMeter uses the command-line tool to renew it (see below).

## How it works

- **Data:** it reads the login token Claude Code already keeps in the Keychain (`Claude Code-credentials`), including when that token expires. It uses that token to call the same usage endpoint behind Claude Code's `/usage` command. The token only goes to `api.anthropic.com`, and it's never stored.
- **Keeping the login fresh:** the token lasts about 8 hours, and only the terminal `claude` tool renews it. When it has expired, ClaudeMeter runs `claude -p ""` in the background, which renews the token and then exits before calling the model, so it uses none of your quota. It tries at most once every 10 minutes. ClaudeMeter never renews or saves the token itself.
- **Updates:** it fetches every 5 minutes. The pace line still moves every minute between fetches.
- **Backoff:** if a request fails it waits 10m, 20m, 40m, then 1h (the cap). A rate limit (HTTP 429) is held until the server's `Retry-After` has passed, plus a minute so the retry doesn't land on the window boundary; that wait survives a restart and a failed token read. The menu shows when the next retry is. **Refresh** (⌘R) retries right away.
- **Signed out vs rate limited:** the endpoint answers HTTP 429 to an expired token as well as to real throttling, so the two look identical from the outside. The app checks the token's own expiry first and says *Run claude in Terminal to sign in* rather than sending a request that would come back as a misleading 429. If a rate limit does outlast an hour, the dropdown starts suggesting you check you're signed in.
- **Caveat:** the endpoint isn't a public API, so it could change without notice.

To see failed or rate-limited fetches:

```sh
log show --last 1d --predicate 'subsystem == "com.isaac.claudemeter"'
```

## Uninstall

Turn off Open at Login, quit the app, and delete `~/Applications/ClaudeMeter.app`.
