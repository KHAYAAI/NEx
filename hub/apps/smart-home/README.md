# smart-home

A real MCP "App" with a mock backend: `get_device_state` /
`set_device_state` over three fixed devices, persisted to a JSON file.
**Not** the real Home Assistant integration `CLAUDE.md`'s Phase 2
bring-up list calls for — there's no real IoT hardware in this
environment. Built so Phase 5's simulated week (`CLAUDE.md` §5, which
names "home automation" as an interaction type) exercises a genuine
tool call instead of skipping that category. See `hub/apps/README.md`
and the module docstring in `server.py`.

## Running standalone

```sh
python3 server.py --store /path/to/devices.json
```

Speaks MCP over stdio; meant to be launched by `hub/agent/agent.py`
(a `home: get <device>` or `home: set <device> <state>` question
routes here).
