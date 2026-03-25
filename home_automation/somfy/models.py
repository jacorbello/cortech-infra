from dataclasses import dataclass, field
from typing import Any, ClassVar


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

    BLIND_CLASSES: ClassVar[frozenset[str]] = frozenset(
        {"ExteriorScreen", "RollerShutter", "Awning", "Blind", "Screen", "Pergola"}
    )

    @property
    def is_blind(self) -> bool:
        return self.device_type in self.BLIND_CLASSES or self.protocol == "rts"
