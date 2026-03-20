import pytest
from home_automation.somfy.client import TaHomaClient


BASE_URL = "https://tahoma.local:8443/enduser-mobile-web/1/enduserAPI"

SAMPLE_DEVICE_API_RESPONSE = [
    {
        "label": "Living Room Blind",
        "deviceURL": "rts://1234-5678/0",
        "definition": {"uiClass": "RollerShutter"},
        "states": [
            {"name": "core:ClosureState", "value": 50},
            {"name": "core:StatusState", "value": "available"},
        ],
    },
    {
        "label": "Bedroom Light",
        "deviceURL": "io://1234-5678/0",
        "definition": {"uiClass": "Light"},
        "states": [],
    },
]


@pytest.fixture
def client() -> TaHomaClient:
    return TaHomaClient(host="tahoma.local", token="test-token", verify_ssl=False)
