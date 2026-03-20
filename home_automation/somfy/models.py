from dataclasses import dataclass, field
from typing import Any


@dataclass
class Device:
    label: str
    device_url: str
    protocol: str
    device_type: str
    states: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_api(cls, data: dict[str, Any]) -> "Device":
        device_url: str = data.get("deviceURL", "")
        protocol = device_url.split("://")[0] if "://" in device_url else "unknown"
        states = {
            s["name"]: s.get("value")
            for s in data.get("states", [])
        }
        return cls(
            label=data.get("label", ""),
            device_url=device_url,
            protocol=protocol,
            device_type=data.get("definition", {}).get("uiClass", ""),
            states=states,
        )

    @property
    def is_blind(self) -> bool:
        blind_classes = {"ExteriorScreen", "RollerShutter", "Awning", "Blind", "Screen", "Pergola"}
        return self.device_type in blind_classes or self.protocol == "rts"
