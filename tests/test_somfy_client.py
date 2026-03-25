import responses as resp
import pytest
from home_automation.somfy.client import TaHomaClient
from home_automation.somfy.exceptions import TaHomaAPIError
from .conftest import BASE_URL, SAMPLE_DEVICE_API_RESPONSE


@resp.activate
def test_api_version(client: TaHomaClient) -> None:
    resp.add(resp.GET, f"{BASE_URL}/apiVersion", json={"protocolVersion": "2.1"})
    assert client.api_version() == "2.1"


@resp.activate
def test_get_devices(client: TaHomaClient) -> None:
    resp.add(resp.GET, f"{BASE_URL}/setup/devices", json=SAMPLE_DEVICE_API_RESPONSE)
    devices = client.get_devices()
    assert len(devices) == 2
    assert devices[0].label == "Living Room Blind"
    assert devices[1].label == "Bedroom Light"


@resp.activate
def test_open(client: TaHomaClient) -> None:
    resp.add(resp.POST, f"{BASE_URL}/exec/apply", json={"execId": "exec-open-1"})
    exec_id = client.open("rts://1234-5678/0")
    assert exec_id == "exec-open-1"
    body = resp.calls[0].request.body
    assert b'"open"' in body


@resp.activate
def test_close(client: TaHomaClient) -> None:
    resp.add(resp.POST, f"{BASE_URL}/exec/apply", json={"execId": "exec-close-1"})
    exec_id = client.close("rts://1234-5678/0")
    assert exec_id == "exec-close-1"
    body = resp.calls[0].request.body
    assert b'"close"' in body


@resp.activate
def test_set_closure(client: TaHomaClient) -> None:
    resp.add(resp.POST, f"{BASE_URL}/exec/apply", json={"execId": "exec-closure-1"})
    exec_id = client.set_closure("rts://1234-5678/0", 75)
    assert exec_id == "exec-closure-1"
    import json
    body = json.loads(resp.calls[0].request.body)
    assert body["actions"][0]["commands"][0]["parameters"] == [75]


@resp.activate
def test_get_blinds(client: TaHomaClient) -> None:
    resp.add(resp.GET, f"{BASE_URL}/setup/devices", json=SAMPLE_DEVICE_API_RESPONSE)
    blinds = client.get_blinds()
    assert len(blinds) == 1
    assert blinds[0].label == "Living Room Blind"


@resp.activate
def test_get_devices_error(client: TaHomaClient) -> None:
    resp.add(resp.GET, f"{BASE_URL}/setup/devices", status=401, body="Unauthorized")
    with pytest.raises(TaHomaAPIError) as exc_info:
        client.get_devices()
    assert exc_info.value.status_code == 401


@resp.activate
def test_api_version_server_error(client: TaHomaClient) -> None:
    resp.add(resp.GET, f"{BASE_URL}/apiVersion", status=500, body="Internal Server Error")
    with pytest.raises(TaHomaAPIError) as exc_info:
        client.api_version()
    assert exc_info.value.status_code == 500
