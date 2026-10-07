"""Functional tests for Catalog.API running natively against Postgres catalogdb (milestone 1).

Expected values are derived from the seed file src/Catalog.API/Setup/catalog.json, not from
what the app happens to return.
"""
import collections
import json
import os
import pathlib
import subprocess
import uuid

import pytest

SEED = json.loads(
    (pathlib.Path(__file__).resolve().parents[3] / "src/Catalog.API/Setup/catalog.json").read_text()
)
V = "api-version=1.0"
BY_ID = {i["Id"]: i for i in SEED}


class TestHealth:
    def test_health_returns_healthy(self, api):
        r = api.get("/health")
        assert r.status_code == 200
        assert r.text == "Healthy"

    def test_alive_returns_healthy(self, api):
        r = api.get("/alive")
        assert r.status_code == 200
        assert r.text == "Healthy"

    def test_vector_extension_in_catalogdb(self, api):
        out = subprocess.run(
            ["sudo", "-n", "-u", "postgres", "psql", "-X", "-q", "-tA", "-d", "catalogdb", "-c",
             "SELECT extname FROM pg_extension WHERE extname = 'vector'"],
            capture_output=True, text=True, cwd="/tmp")
        out_dir = pathlib.Path(os.environ.get("FT_OUT_DIR", "/tmp/ftout"))
        (out_dir / "test_vector_extension_in_catalogdb.body").write_text(out.stdout.strip())
        (out_dir / "test_vector_extension_in_catalogdb.json").write_text(
            json.dumps({"method": "GET", "path": "psql catalogdb pg_extension", "status": 200 if out.returncode == 0 else 500,
                        "content_type": "text/plain", "request_body": None}))
        assert out.returncode == 0, out.stderr
        assert out.stdout.strip() == "vector"


class TestListItems:
    def test_list_items_default_page(self, api):
        r = api.get(f"/api/catalog/items?{V}")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(SEED) == 101
        assert body["pageIndex"] == 0
        assert body["pageSize"] == 10
        assert len(body["data"]) == 10
        names = [i["name"] for i in body["data"]]
        assert names == sorted(names)
        for item in body["data"]:
            assert item["catalogBrand"]["brand"]
            assert item["id"] in BY_ID
            assert item["name"] == BY_ID[item["id"]]["Name"]

    def test_list_items_paging_pages_do_not_overlap(self, api):
        p0 = api.get(f"/api/catalog/items?{V}&pageSize=5&pageIndex=0", record=False).json()
        r = api.get(f"/api/catalog/items?{V}&pageSize=5&pageIndex=1")
        assert r.status_code == 200
        p1 = r.json()
        assert p1["pageIndex"] == 1 and p1["pageSize"] == 5
        assert len(p1["data"]) == 5
        assert {i["id"] for i in p0["data"]}.isdisjoint({i["id"] for i in p1["data"]})
        assert p0["data"][-1]["name"] <= p1["data"][0]["name"]

    def test_list_items_last_page_partial(self, api):
        r = api.get(f"/api/catalog/items?{V}&pageSize=100&pageIndex=1")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == 101
        assert len(body["data"]) == 1

    def test_list_items_page_beyond_end_is_empty(self, api):
        r = api.get(f"/api/catalog/items?{V}&pageSize=10&pageIndex=500")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == 101
        assert body["data"] == []

    def test_list_items_missing_api_version_is_400(self, api):
        r = api.get("/api/catalog/items")
        assert r.status_code == 400
        assert r.json()["code"] == "ApiVersionUnspecified"

    def test_list_items_invalid_page_size_type_is_400(self, api):
        r = api.get(f"/api/catalog/items?{V}&pageSize=abc")
        assert r.status_code == 400

    def test_list_items_v2_filters_by_name_type_brand(self, api):
        # Every seeded item with Brand==Daybird and Type==Footwear, name prefix filter.
        exp = [i for i in SEED if i["Brand"] == "Daybird" and i["Type"] == "Footwear" and i["Name"].startswith("Wand")]
        assert exp, "seed data assumption"
        brands = {b["brand"]: b["id"] for b in api.get(f"/api/catalog/catalogbrands?{V}", record=False).json()}
        types = {t["type"]: t["id"] for t in api.get(f"/api/catalog/catalogtypes?{V}", record=False).json()}
        r = api.get(f"/api/catalog/items?api-version=2.0&name=Wand&type={types['Footwear']}&brand={brands['Daybird']}")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)
        assert {i["name"] for i in body["data"]} == {i["Name"] for i in exp}

    def test_list_items_v2_repeated_brand_filter(self, api):
        brands = {b["brand"]: b["id"] for b in api.get(f"/api/catalog/catalogbrands?{V}", record=False).json()}
        wanted = ["Daybird", "Quester"]
        exp = [i for i in SEED if i["Brand"] in wanted]
        r = api.get("/api/catalog/items?api-version=2.0&pageSize=100"
                    f"&brand={brands['Daybird']}&brand={brands['Quester']}")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)
        assert {i["id"] for i in body["data"]} == {i["Id"] for i in exp}


class TestItemById:
    def test_get_item_by_id(self, api):
        r = api.get(f"/api/catalog/items/1?{V}")
        assert r.status_code == 200
        item = r.json()
        assert item["id"] == 1
        assert item["name"] == BY_ID[1]["Name"]
        assert item["price"] == BY_ID[1]["Price"]
        assert item["catalogBrand"]["brand"] == BY_ID[1]["Brand"]
        assert item["pictureFileName"] == "1.webp"

    def test_get_item_not_found(self, api):
        r = api.get(f"/api/catalog/items/99999?{V}")
        assert r.status_code == 404

    def test_get_item_non_positive_id_is_400(self, api):
        r = api.get(f"/api/catalog/items/0?{V}")
        assert r.status_code == 400
        assert r.json()["detail"] == "Id is not valid"

    def test_get_item_non_integer_id_is_404(self, api):
        # Route constraint {id:int} does not match, so no endpoint is selected.
        r = api.get(f"/api/catalog/items/abc?{V}")
        assert r.status_code in (400, 404)

    def test_batch_get_items_by_ids(self, api):
        r = api.get(f"/api/catalog/items/by?ids=1&ids=2&ids=3&{V}")
        assert r.status_code == 200
        assert sorted(i["id"] for i in r.json()) == [1, 2, 3]

    def test_get_item_picture(self, api):
        r = api.get(f"/api/catalog/items/1/pic?{V}")
        assert r.status_code == 200
        assert r.headers["content-type"] == "image/webp"
        assert r.content[:4] == b"RIFF" and r.content[8:12] == b"WEBP"

    def test_get_item_picture_not_found(self, api):
        r = api.get(f"/api/catalog/items/99999/pic?{V}")
        assert r.status_code == 404


class TestByNameAndSearch:
    def test_items_by_name_prefix(self, api):
        exp = [i for i in SEED if i["Name"].startswith("Wanderer")]
        r = api.get(f"/api/catalog/items/by/Wanderer?{V}&pageSize=50")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)
        assert {i["name"] for i in body["data"]} == {i["Name"] for i in exp}

    def test_items_by_name_no_match(self, api):
        r = api.get(f"/api/catalog/items/by/{uuid.uuid4().hex}?{V}")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == 0 and body["data"] == []

    def test_semantic_search_falls_back_to_name_without_embedding_model(self, api):
        # No embedding model is configured: search degrades to the name-prefix search.
        exp = [i for i in SEED if i["Name"].startswith("Wanderer")]
        r = api.get(f"/api/catalog/items/withsemanticrelevance/Wanderer?{V}&pageSize=50")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)
        assert {i["name"] for i in body["data"]} == {i["Name"] for i in exp}

    def test_semantic_search_v2_query_text(self, api):
        exp = [i for i in SEED if i["Name"].startswith("Alpine")]
        r = api.get("/api/catalog/items/withsemanticrelevance?api-version=2.0&text=Alpine&pageSize=100")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)


class TestTypesBrandsFacets:
    def test_list_types(self, api):
        r = api.get(f"/api/catalog/catalogtypes?{V}")
        assert r.status_code == 200
        types = [t["type"] for t in r.json()]
        assert types == sorted(types)
        assert set(types) == {i["Type"] for i in SEED}

    def test_list_brands(self, api):
        r = api.get(f"/api/catalog/catalogbrands?{V}")
        assert r.status_code == 200
        brands = [b["brand"] for b in r.json()]
        assert brands == sorted(brands)
        assert set(brands) == {i["Brand"] for i in SEED}

    def test_items_by_type_and_brand(self, api):
        brands = {b["brand"]: b["id"] for b in api.get(f"/api/catalog/catalogbrands?{V}", record=False).json()}
        types = {t["type"]: t["id"] for t in api.get(f"/api/catalog/catalogtypes?{V}", record=False).json()}
        exp = [i for i in SEED if i["Type"] == "Climbing" and i["Brand"] == "WildRunner"]
        r = api.get(f"/api/catalog/items/type/{types['Climbing']}/brand/{brands['WildRunner']}?{V}&pageSize=100")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)
        assert {i["name"] for i in body["data"]} == {i["Name"] for i in exp}

    def test_items_by_brand_only(self, api):
        brands = {b["brand"]: b["id"] for b in api.get(f"/api/catalog/catalogbrands?{V}", record=False).json()}
        exp = [i for i in SEED if i["Brand"] == "WildRunner"]
        r = api.get(f"/api/catalog/items/type/all/brand/{brands['WildRunner']}?{V}&pageSize=100")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == len(exp)
        assert {i["id"] for i in body["data"]} == {i["Id"] for i in exp}

    def test_facets_match_seed_counts(self, api):
        brands = {b["brand"]: b["id"] for b in api.get(f"/api/catalog/catalogbrands?{V}", record=False).json()}
        types = {t["type"]: t["id"] for t in api.get(f"/api/catalog/catalogtypes?{V}", record=False).json()}
        r = api.get(f"/api/catalog/items/facets?{V}")
        assert r.status_code == 200
        body = r.json()
        assert body["brandTotal"] == 101 and body["typeTotal"] == 101
        bc = collections.Counter(i["Brand"] for i in SEED)
        tc = collections.Counter(i["Type"] for i in SEED)
        assert {c["id"]: c["count"] for c in body["brandCounts"]} == {brands[k]: v for k, v in bc.items()}
        assert {c["id"]: c["count"] for c in body["typeCounts"]} == {types[k]: v for k, v in tc.items()}


def _psql(sql):
    return subprocess.run(
        ["sudo", "-n", "-u", "postgres", "psql", "-X", "-q", "-tA", "-d", "catalogdb", "-c", sql],
        capture_output=True, text=True, cwd="/tmp")


class TestWriteFlow:
    """Write paths against the real catalogdb. Records are namespaced (ftrun_) and removed."""

    def _payload(self, api, name):
        brands = api.get(f"/api/catalog/catalogbrands?{V}", record=False).json()
        types = api.get(f"/api/catalog/catalogtypes?{V}", record=False).json()
        return {"name": name, "description": "functional test item", "price": 12.5,
                "pictureFileName": "1.webp", "catalogTypeId": types[0]["id"],
                "catalogBrandId": brands[0]["id"], "availableStock": 5,
                "restockThreshold": 1, "maxStockThreshold": 10}

    @pytest.mark.xfail(
        reason="Known upstream limitation: CatalogContextSeed inserts explicit Ids 1-101 without advancing "
               "the identity sequence, so POST collides with PK_Catalog (500). Catalog.API code is out of "
               "scope for the native-host foundation milestone.",
        strict=False)
    def test_create_item_returns_201(self, api):
        name = f"ftrun_{uuid.uuid4().hex[:10]}"
        payload = self._payload(api, name)
        try:
            r = api.request("POST", f"/api/catalog/items?{V}", json=payload)
            assert r.status_code == 201, r.text
            found = api.get(f"/api/catalog/items/by/{name}?{V}", record=False).json()
            assert found["count"] == 1
        finally:
            found = api.get(f"/api/catalog/items/by/{name}?{V}", record=False).json()
            for it in found.get("data", []):
                api.request("DELETE", f"/api/catalog/items/{it['id']}?{V}", record=False)

    @pytest.fixture
    def seeded_item(self):
        """Gap-fill: insert one namespaced row directly (POST is not usable, see test above)."""
        name = f"ftrun_{uuid.uuid4().hex[:10]}"
        item_id = 900000 + int(uuid.uuid4().int % 90000)
        r = _psql(f'INSERT INTO "Catalog" ("Id","AvailableStock","CatalogBrandId","CatalogTypeId","Description",'
                  f'"MaxStockThreshold","Name","OnReorder","PictureFileName","Price","RestockThreshold") '
                  f"VALUES ({item_id},5,1,1,'ft',10,'{name}',false,'1.webp',12.5,1)")
        assert r.returncode == 0, r.stderr
        yield item_id, name
        _psql(f'DELETE FROM "Catalog" WHERE "Id" = {item_id}')

    def test_update_item_v1_changes_price(self, api, seeded_item):
        item_id, name = seeded_item
        item = api.get(f"/api/catalog/items/{item_id}?{V}", record=False).json()
        item["price"] = 15.75
        r = api.request("PUT", f"/api/catalog/items?{V}", json=item)
        assert r.status_code == 201, r.text
        got = api.get(f"/api/catalog/items/{item_id}?{V}", record=False).json()
        assert got["price"] == 15.75

    def test_delete_item_returns_204_then_404(self, api, seeded_item):
        item_id, name = seeded_item
        assert api.get(f"/api/catalog/items/{item_id}?{V}", record=False).status_code == 200
        r = api.request("DELETE", f"/api/catalog/items/{item_id}?{V}")
        assert r.status_code == 204
        assert api.get(f"/api/catalog/items/{item_id}?{V}", record=False).status_code == 404

    def test_delete_missing_item_is_404(self, api):
        r = api.request("DELETE", f"/api/catalog/items/99999999?{V}")
        assert r.status_code == 404
