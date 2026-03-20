from urllib.parse import quote
from typing import Any
import requests

from .exceptions import TaHomaAPIError
from .models import Device


class TaHomaClient:
    def __init__(self, host: str, token: str, port: int = 8443, verify_ssl: bool = False) -> None:
        self._base_url = f"https://{host}:{port}/enduser-mobile-web/1/enduserAPI"
        self._session = requests.Session()
        self._session.headers["Authorization"] = f"Bearer {token}"
        self._session.verify = verify_ssl
        if not verify_ssl:
            import urllib3
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def _get(self, path: str) -> Any:
        r = self._session.get(f"{self._base_url}{path}")
        if not r.ok:
            raise TaHomaAPIError(r.status_code, r.text)
        return r.json()

    def _post(self, path: str, body: Any = None) -> Any:
        r = self._session.post(f"{self._base_url}{path}", json=body)
        if not r.ok:
            raise TaHomaAPIError(r.status_code, r.text)
        return r.json()

    def _delete(self, path: str) -> None:
        r = self._session.delete(f"{self._base_url}{path}")
        if not r.ok:
            raise TaHomaAPIError(r.status_code, r.text)

    @staticmethod
    def _action_payload(device_urls: str | list[str], action: str, params: list[Any] | None = None) -> dict:
        if isinstance(device_urls, str):
            device_urls = [device_urls]
        return {
            "label": action,
            "actions": [
                {
                    "deviceURL": url,
                    "commands": [{"name": action, "parameters": params or []}],
                }
                for url in device_urls
            ],
        }

    def api_version(self) -> str:
        return self._get("/apiVersion")["protocolVersion"]

    def get_devices(self) -> list[Device]:
        return [Device.from_api(d) for d in self._get("/setup/devices")]

    def get_device_state(self, device_url: str) -> dict:
        encoded = quote(device_url, safe="")
        states = self._get(f"/setup/devices/{encoded}/states")
        return {s["name"]: s.get("value") for s in states}

    def close(self, device_urls: str | list[str]) -> str:
        payload = self._action_payload(device_urls, "close")
        return self._post("/exec/apply", payload)["execId"]

    def open(self, device_urls: str | list[str]) -> str:
        payload = self._action_payload(device_urls, "open")
        return self._post("/exec/apply", payload)["execId"]

    def stop(self, exec_id: str) -> None:
        self._delete(f"/exec/current/setup/{exec_id}")

    def set_closure(self, device_urls: str | list[str], position: int) -> str:
        payload = self._action_payload(device_urls, "setClosure", [position])
        return self._post("/exec/apply", payload)["execId"]

    def register_listener(self) -> str:
        return self._post("/events/register")["id"]

    def fetch_events(self, listener_id: str) -> list:
        return self._post(f"/events/{listener_id}/fetch")

    def get_blinds(self) -> list[Device]:
        return [d for d in self.get_devices() if d.is_blind]

    def close_all(self) -> str:
        urls = [d.device_url for d in self.get_blinds()]
        return self.close(urls)

    def open_all(self) -> str:
        urls = [d.device_url for d in self.get_blinds()]
        return self.open(urls)
