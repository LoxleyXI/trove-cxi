# Trove

Ashita v4 addon for the [CatsEyeXI](https://catseyexi.com) private server.
In-game window over your Ephemeral Box, currencies, points, and Squire storage.

## Install

```
cd <Ashita>/addons
git clone git@github.com:LoxleyX/trove.git
```

Then in-game:

```
/addon load trove
```

`^z` toggles the window; `/trove` and `/box` also work. Anything else — e.g.
`/box cluster fire crystal` — passes through to the server's `!box` chat
command.

Requires the CatsEyeXI server; the protocol is specific to it.

MIT licensed.
