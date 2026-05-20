# Cluster bring-up

One-time setup for getting `hq` server + workers running on the DormLab minis.

## 0. Prereqs (Mac + each mini)

- macOS arm64.
- Tailscale (or any IP-routable network) between Mac and minis.
- Passwordless SSH from Mac → each mini.

## 1. Install Rust + cmake on each box

`hq` has no macOS binary release, so build from source. Each mini needs both
Rust and `cmake` (the `highs-sys` LP solver dep).

```sh
# On the Mac AND each mini:
brew install cmake
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source ~/.cargo/env
cargo install --locked --git https://github.com/It4innovations/hyperqueue hyperqueue
```

Build time: ~5–10 min per mini.

## 2. Start the server on the Mac

`hq server` listens on whatever address you bind. mDNS `.local` may not
resolve from the minis, so bind to a routable IP (e.g. the Tailscale 100.x):

```sh
hq server start --host <MAC_IP>
```

The server runs in the foreground; for a daemon, see step 4.

## 3. Copy access info to each mini

```sh
for h in lexie derek amelia; do
  scp -r ~/.hq-server $h:~/
done
```

The minis' workers will read `~/.hq-server/hq-current/access.json` to find
the server.

## 4. Start a worker on each mini

```sh
for h in lexie derek amelia; do
  ssh -f $h "~/.cargo/bin/hq worker start \
               --resource 'mem=sum(14)' \
               --resource 'mps=sum(1)' \
               </dev/null >/tmp/hqworker.log 2>&1"
done
```

Confirm:

```sh
hq worker list
# Should show 3 workers, all in state RUNNING.
```

## 5. Test

```sh
JID=$(submit -- /bin/sh -c 'echo "hi from $(hostname)"')
wait $JID
log  $JID
```

You should see `hi from Lexies-Mac-mini` (or derek/amelia).

## 6. (Optional) Persistence via launchd

To survive reboots, drop these plists:

**`~/Library/LaunchAgents/com.dormlab.hqserver.plist`** (Mac):
```xml
<plist><dict>
  <key>Label</key><string>com.dormlab.hqserver</string>
  <key>ProgramArguments</key><array>
    <string>/Users/you/.cargo/bin/hq</string>
    <string>server</string><string>start</string>
    <string>--host</string><string><MAC_IP></string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/you/.hq-server.out</string>
  <key>StandardErrorPath</key><string>/Users/you/.hq-server.err</string>
</dict></plist>
```

Register:
```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dormlab.hqserver.plist
```

**`~/Library/LaunchAgents/com.dormlab.hqworker.plist`** (each mini): same shape
but with `worker start --resource 'mem=sum(14)' --resource 'mps=sum(1)'` instead.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Cannot resolve server address X.local` | Mac's `.local` name doesn't resolve from minis. Restart server with `--host <ip>` and re-copy `~/.hq-server`. |
| `Cannot create stdout directory` | The `--cwd` you submitted with doesn't exist on the worker. Use `--cwd /tmp` or a path that exists on all minis. |
| Job in WAITING forever | All workers' MPS pool exhausted; another `--mps` job is holding the slot. `hq worker list` to confirm. |
| `error: failed to run custom build command for 'highs-sys'` | `cmake` not installed. `brew install cmake`. |
