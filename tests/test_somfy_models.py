from home_automation.somfy.models import Device
from .conftest import SAMPLE_DEVICE_API_RESPONSE


def test_device_from_api_blind() -> None:
    data = SAMPLE_DEVICE_API_RESPONSE[0]
    device = Device.from_api(data)
    assert device.label == "Living Room Blind"
    assert device.device_url == "rts://1234-5678/0"
    assert device.protocol == "rts"
    assert device.device_type == "RollerShutter"
    assert device.states["core:ClosureState"] == 50
    assert device.states["core:StatusState"] == "available"


def test_device_from_api_light() -> None:
    data = SAMPLE_DEVICE_API_RESPONSE[1]
    device = Device.from_api(data)
    assert device.label == "Bedroom Light"
    assert device.protocol == "io"
    assert device.device_type == "Light"
    assert device.states == {}


def test_is_blind_by_ui_class() -> None:
    for ui_class in ("ExteriorScreen", "RollerShutter", "Awning", "Blind", "Screen", "Pergola"):
        device = Device.from_api({
            "label": "test",
            "deviceURL": "io://0/0",
            "definition": {"uiClass": ui_class},
            "states": [],
        })
        assert device.is_blind is True, f"Expected is_blind for uiClass={ui_class}"


def test_is_blind_by_rts_protocol() -> None:
    device = Device.from_api({
        "label": "RTS Blind",
        "deviceURL": "rts://1234/0",
        "definition": {"uiClass": "Unknown"},
        "states": [],
    })
    assert device.is_blind is True


def test_is_not_blind() -> None:
    device = Device.from_api({
        "label": "Light",
        "deviceURL": "io://1234/0",
        "definition": {"uiClass": "Light"},
        "states": [],
    })
    assert device.is_blind is False


def test_device_from_api_missing_fields() -> None:
    device = Device.from_api({})
    assert device.label == ""
    assert device.device_url == ""
    assert device.protocol == "unknown"
    assert device.device_type == ""
    assert device.states == {}
