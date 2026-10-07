"""Health endpoint exposure in Production: off by default, on with the opt-in switch.

Each case starts an extra Catalog.API instance (published binary, same /etc/eshop env files as the
service, ASPNETCORE_ENVIRONMENT=Production) on its own loopback port with the switch overridden.
"""
import pytest

from conftest import Recorder

ENV_VAR = "ESHOP_EXPOSE_HEALTH_ENDPOINTS"


@pytest.fixture
def prod(request, instance_factory):
    def start(port, overrides):
        base = instance_factory(port, ["ASPNETCORE_ENVIRONMENT=Production", *overrides])
        return Recorder(request.node.name, base)
    return start


class TestHealthExposure:
    def test_switch_unset_hides_health_and_alive(self, prod):
        rec = prod(5291, [f"-{ENV_VAR}"])
        alive = rec.get("/alive", record=False)
        r = rec.get("/health")
        assert r.status_code == 404
        assert alive.status_code == 404
        # The API itself keeps working with health endpoints hidden.
        assert rec.get("/api/catalog/items?api-version=1.0&pageSize=1", record=False).status_code == 200

    def test_switch_false_hides_health_and_alive(self, prod):
        rec = prod(5292, [f"{ENV_VAR}=false"])
        alive = rec.get("/alive", record=False)
        r = rec.get("/health")
        assert r.status_code == 404
        assert alive.status_code == 404

    def test_switch_env_true_exposes_health_and_alive(self, prod):
        rec = prod(5293, [f"{ENV_VAR}=true"])
        alive = rec.get("/alive", record=False)
        r = rec.get("/health")
        assert r.status_code == 200 and r.text == "Healthy"
        assert alive.status_code == 200 and alive.text == "Healthy"

    def test_config_key_true_exposes_health_and_alive(self, prod):
        # ServiceDefaults:ExposeHealthEndpoints via the double-underscore env form.
        rec = prod(5294, [f"-{ENV_VAR}", "ServiceDefaults__ExposeHealthEndpoints=true"])
        alive = rec.get("/alive", record=False)
        r = rec.get("/health")
        assert r.status_code == 200 and r.text == "Healthy"
        assert alive.status_code == 200

    def test_development_always_exposes_health(self, request, instance_factory):
        base = instance_factory(5295, ["ASPNETCORE_ENVIRONMENT=Development", f"-{ENV_VAR}"])
        rec = Recorder(request.node.name, base)
        r = rec.get("/health")
        assert r.status_code == 200
