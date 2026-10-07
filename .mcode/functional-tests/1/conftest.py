import json
import os
import pathlib
import subprocess
import time

import pytest
import requests

BASE = os.environ.get("CATALOG_BASE_URL", "http://127.0.0.1:5222")
OUT = pathlib.Path(os.environ.get("FT_OUT_DIR", "/tmp/ftout"))
HERE = pathlib.Path(__file__).parent
LAUNCHER = HERE / "launch_catalog_instance.sh"
OUT.mkdir(parents=True, exist_ok=True)


class Recorder:
    """requests wrapper that stores the last recorded response of each test under FT_OUT_DIR."""

    def __init__(self, name, base):
        self.name = name
        self.base = base

    def record(self, method, path, status, content_type, body, request_body=None):
        (OUT / f"{self.name}.json").write_text(json.dumps({
            "method": method, "path": path, "status": status,
            "content_type": content_type, "request_body": request_body}))
        (OUT / f"{self.name}.body").write_text(body)

    def request(self, method, path, record=True, base=None, **kw):
        kw.setdefault("timeout", 30)
        url = (base or self.base) + path
        r = requests.request(method, url, **kw)
        if record:
            ctype = r.headers.get("content-type", "")
            if ctype.startswith("image/"):
                body = f"<binary {ctype}, {len(r.content)} bytes, magic={r.content[:4]!r}>"
            else:
                body = r.text
            self.record(method, path, r.status_code, ctype, body, kw.get("json"))
        return r

    def get(self, path, **kw):
        return self.request("GET", path, **kw)


def psql(sql):
    return subprocess.run(
        ["sudo", "-n", "-u", "postgres", "psql", "-X", "-q", "-tA", "-d", "catalogdb", "-c", sql],
        capture_output=True, text=True, cwd="/tmp")


@pytest.fixture
def api(request):
    return Recorder(request.node.name, BASE)


@pytest.fixture(scope="session")
def catalog_ids():
    """(brands, types) name -> id maps read from the live API; not recorded."""
    brands = requests.get(f"{BASE}/api/catalog/catalogbrands?api-version=1.0", timeout=30).json()
    types = requests.get(f"{BASE}/api/catalog/catalogtypes?api-version=1.0", timeout=30).json()
    return ({b["brand"]: b["id"] for b in brands}, {t["type"]: t["id"] for t in types})


@pytest.fixture(scope="session", autouse=True)
def app_healthy():
    deadline = time.time() + 60
    last = None
    while time.time() < deadline:
        try:
            r = requests.get(BASE + "/health", timeout=5)
            if r.status_code == 200:
                return
            last = r.status_code
        except requests.RequestException as e:
            last = e
        time.sleep(1)
    pytest.fail(f"Catalog.API not healthy at {BASE}: {last}")


def _start_instance(port, overrides):
    proc = subprocess.Popen(
        ["sudo", "-n", "-u", "eshop", "env", "HOME=/var/lib/eshop", "bash",
         str(LAUNCHER), str(port), *overrides],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    return proc


def _wait_api(port, proc, timeout=90):
    """Wait until the API itself (not the health endpoint) answers; returns True when up."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            r = requests.get(f"http://127.0.0.1:{port}/api/catalog/items?api-version=1.0&pageSize=1", timeout=5)
            if r.status_code == 200:
                return True
        except requests.RequestException:
            pass
        time.sleep(1)
    return False


def _stop_instance(port, proc):
    # The instance runs as the eshop user; it is identified by its --urls argument.
    pids = subprocess.run(["pgrep", "-u", "eshop", "-f", f"Catalog.API.dll.*--urls http://127.0.0.1:{port}$"],
                          capture_output=True, text=True).stdout.split()
    for pid in pids:
        subprocess.run(["sudo", "-n", "kill", pid])
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        for pid in pids:
            subprocess.run(["sudo", "-n", "kill", "-9", pid])


@pytest.fixture(scope="module")
def instance_factory():
    started = []

    def make(port, overrides):
        proc = _start_instance(port, overrides)
        started.append((port, proc))
        assert _wait_api(port, proc), f"extra Catalog.API instance on {port} did not come up"
        return f"http://127.0.0.1:{port}"

    yield make
    for port, proc in started:
        _stop_instance(port, proc)
