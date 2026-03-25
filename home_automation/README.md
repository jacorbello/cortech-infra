# home_automation

Python library for controlling home devices. Currently supports Somfy TaHoma hubs via the local REST API.

## Installation

```bash
pip install -e /path/to/cortech-infra/home_automation
```

This requires the `pyproject.toml` included in this directory. Alternatively, install
the dependency directly:

```bash
pip install requests
```

## Quick Start

Token is stored in Infisical as `SOMFY_TAHOMA_TOKEN`.

```python
import os
import subprocess
from home_automation import TaHomaClient

token = subprocess.check_output(
    ["infisical", "secrets", "get", "SOMFY_TAHOMA_TOKEN", "--env", "prod", "--plain"],
    text=True,
).strip()

host = os.environ.get("TAHOMA_HOST", "192.168.1.x")
client = TaHomaClient(host=host, token=token, verify_ssl=False)

# List all blinds
blinds = client.get_blinds()
for blind in blinds:
    print(blind.label, blind.device_url)

# Close all blinds
exec_id = client.close_all()

# Open specific blinds
exec_id = client.open(["rts://1234567890/1", "rts://1234567890/2"])

# Set position (0=open, 100=closed)
exec_id = client.set_closure("rts://1234567890/1", 50)

# Stop an in-progress execution
client.stop(exec_id)
```

## API Reference

### `TaHomaClient(host, token, port=8443, verify_ssl=True, request_timeout=10.0)`

| Method | Description |
|---|---|
| `api_version() -> str` | Returns the hub API version |
| `get_devices() -> list[Device]` | Returns all paired devices |
| `get_device_state(device_url) -> dict` | Returns current state for a device |
| `get_blinds() -> list[Device]` | Returns only blind/shade devices |
| `open(device_urls) -> str` | Opens one or more blinds, returns exec ID |
| `close(device_urls) -> str` | Closes one or more blinds, returns exec ID |
| `open_all() -> str` | Opens all blinds |
| `close_all() -> str` | Closes all blinds |
| `set_closure(device_urls, position) -> str` | Sets position: 0=open, 100=closed |
| `stop(exec_id)` | Cancels an in-progress execution |
| `register_listener() -> str` | Registers an event listener, returns listener ID |
| `fetch_events(listener_id) -> list` | Fetches pending events for a listener |

### `Device`

| Field | Type | Description |
|---|---|---|
| `label` | `str` | Human-readable device name |
| `device_url` | `str` | Unique device identifier (e.g., `rts://...`) |
| `protocol` | `str` | Protocol: `rts`, `io`, `zigbee`, `internal` |
| `device_type` | `str` | UI class from the TaHoma definition |
| `states` | `dict` | Current state map from the hub |
| `is_blind` | `bool` | True if device is a blind or shade |

## Hub Details

> **Note:** These are internal/lab-specific defaults. Replace with your own hub configuration.

- **IP:** Set via `TAHOMA_HOST` environment variable
- **Port:** 8443
- **SSL:** Self-signed cert on local hubs — pass `verify_ssl=False` to disable verification
