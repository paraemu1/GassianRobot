# OpenClaw Web UI over Tailscale (No Auth) — Working Notes

This document records the setup that **actually worked** on this machine after manual attempts burned a lot of time.

Context:
- Manual setup attempts were frustrating and time-consuming.
- Using the **Codex CLI tool** to work through the configuration got OpenClaw working in about an hour.
- The result is a local-only OpenClaw gateway, exposed to the tailnet with a lightweight reverse proxy, with **no OpenClaw auth** on the Web UI.

## Outcome

Working access pattern:
- OpenClaw gateway binds **only to loopback** on this machine.
- Tailscale provides reachability on the tailnet.
- A tiny Node proxy binds to the machine's `100.x.y.z` Tailscale IP and forwards traffic to the local gateway.
- The OpenClaw Web UI is reachable on the tailnet **without OpenClaw auth**.

At the time this was documented, the working endpoints were:
- OpenClaw UI: `http://100.65.59.46:8080/`
- Viewer proxy example: `http://100.65.59.46:8081/`
- Local gateway backend: `http://127.0.0.1:18789/`

## Why this pattern worked

Instead of binding the gateway directly to a public or tailnet-facing interface, the working pattern was:

1. Keep the OpenClaw gateway bound to loopback only.
2. Disable OpenClaw's own auth for this local/tailnet use case.
3. Explicitly allow the tailnet proxy origin in `controlUi.allowedOrigins`.
4. Use a tiny Tailscale-bound proxy process to expose the local loopback service on the `100.x` address.

This avoided the confusion of trying to make the gateway itself directly own every network-facing concern.

## Actual OpenClaw config that mattered

File:
- `~/.openclaw/openclaw.json`

Important working fields:

```json
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "controlUi": {
      "basePath": "/",
      "allowedOrigins": [
        "http://100.65.59.46:8080",
        "http://127.0.0.1:18789",
        "http://localhost:18789"
      ],
      "dangerouslyDisableDeviceAuth": true
    },
    "auth": {
      "mode": "none"
    },
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    }
  }
}
```

### Meaning of the important bits

- `"bind": "loopback"`
  - keeps the gateway local-only
- `"auth": { "mode": "none" }`
  - disables OpenClaw auth for the gateway UI/API
- `"dangerouslyDisableDeviceAuth": true`
  - disables the device-auth layer for the control UI
- `"allowedOrigins"`
  - must include the origin that the browser will actually use when hitting the Tailscale-facing proxy

## Gateway listener that was working

Observed listener state:
- `127.0.0.1:18789` → OpenClaw gateway
- `100.65.59.46:8080` → Tailscale-bound proxy for OpenClaw UI

## Proxy process that made it reachable on Tailscale

Proxy script:
- `~/.local/bin/openclaw-tailscale-proxy.mjs`

This script forwards HTTP and websocket traffic from a Tailscale-bound address to a local upstream.

### OpenClaw UI proxy environment

Observed working environment for the OpenClaw UI proxy process:

```bash
TARGET_HOST=127.0.0.1
TARGET_PORT=18789
LISTEN_PORT=8080
```

The script automatically binds to the host's Tailscale IPv4 if `LISTEN_HOST` is not set.

### Example launch pattern

```bash
nohup env \
  TARGET_HOST=127.0.0.1 \
  TARGET_PORT=18789 \
  LISTEN_PORT=8080 \
  /usr/bin/node ~/.local/bin/openclaw-tailscale-proxy.mjs \
  >/tmp/openclaw-tailscale-proxy.log 2>&1 &
```

This produced a tailnet-facing endpoint like:

```text
http://100.65.59.46:8080/
```

## Viewer proxy example

A second proxy instance was used successfully for the Nerfstudio viewer:

```bash
nohup env \
  TARGET_HOST=127.0.0.1 \
  TARGET_PORT=7007 \
  LISTEN_HOST=100.65.59.46 \
  LISTEN_PORT=8081 \
  /usr/bin/node ~/.local/bin/openclaw-tailscale-proxy.mjs \
  >/tmp/openclaw-splat-proxy.log 2>&1 &
```

That exposed:

```text
http://100.65.59.46:8081/
```

This exact root URL was re-validated after fixing the viewer relaunch regression on 2026-03-16.

## Important lesson: subpath proxying was a trap

One failed attempt was to mount the viewer under a subpath like:

```text
http://100.65.59.46:8080/splat/
```

This can return HTML but still render as a blank page because the current viewer frontend expects to live at `/` and uses absolute asset paths like `/assets/...`.

So the practical rule is:
- OpenClaw UI can live on its own proxied root
- Viewer should usually get its **own port at root** rather than a subpath under another app

## Tailscale state that mattered

At the time of validation:
- Tailscale was running
- Tailnet IPv4: `100.65.59.46`
- MagicDNS name: `integlia1.tail00387.ts.net`

This made the proxy reachable to other devices on the tailnet without exposing the service publicly.

## Security note

This setup is intentionally convenient, not hardened:
- OpenClaw auth is disabled
- device auth is disabled
- the UI is reachable to anything allowed on the tailnet path to this machine

That may be fine for a trusted personal tailnet, but it is **not** the same as a hardened public deployment.

## Why this should be remembered

The key lesson is not just the final config; it is the working architecture:

- **loopback-only gateway**
- **Tailscale for reachability**
- **tiny proxy for exposure**
- **allowedOrigins matched to the proxy URL**
- **no OpenClaw auth for the personal tailnet use case**

That combination worked when direct/manual approaches were confusing and easy to get wrong.

## Suggested future improvements

If this setup remains valuable, consider later:
- turning the proxy launch into a user service
- documenting restart commands explicitly
- optionally re-enabling auth if the threat model changes
- documenting the Codex CLI workflow used to converge on the final config, if command history is available
le for reachability**
- **tiny proxy for exposure**
- **allowedOrigins matched to the proxy URL**
- **no OpenClaw auth for the personal tailnet use case**

That combination worked when direct/manual approaches were confusing and easy to get wrong.

## Suggested future improvements

If this setup remains valuable, consider later:
- turning the proxy launch into a user service
- documenting restart commands explicitly
- optionally re-enabling auth if the threat model changes
- documenting the Codex CLI workflow used to converge on the final config, if command history is available
