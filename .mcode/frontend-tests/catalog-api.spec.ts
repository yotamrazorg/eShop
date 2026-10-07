import { test, expect, type Page } from "@playwright/test";

/**
 * Catalog.API (milestone 1 native-host deployment, Production environment).
 * There is no HTML UI: the browser-visible surface is plain text, JSON, an image and
 * problem+json error bodies. Selectors/values come from the QA report.
 * All versioned routes need ?api-version=1.0.
 */

const V = "api-version=1.0";

/** Navigate like a user would and return the main-document response + its content type. */
async function open(page: Page, path: string) {
  const response = await page.goto(path);
  expect(response, `no response for ${path}`).not.toBeNull();
  const contentType = await page.evaluate(() => document.contentType);
  return { response: response!, contentType };
}

/** Chrome renders non-HTML text/JSON as a <pre> inside the body. */
async function bodyJson(page: Page) {
  const text = await page.evaluate(() => document.body.innerText);
  return JSON.parse(text);
}

test.describe("Health endpoints (opt-in switch ESHOP_EXPOSE_HEALTH_ENDPOINTS=true)", () => {
  for (const path of ["/health", "/alive"]) {
    test(`${path} renders 'Healthy' as text/plain with HTTP 200`, async ({ page }) => {
      const { response, contentType } = await open(page, path);
      expect(response.status()).toBe(200);
      expect(contentType).toBe("text/plain");
      expect(response.headers()["content-type"]).toContain("text/plain");
      expect((await page.evaluate(() => document.body.innerText)).trim()).toBe("Healthy");
    });

    test(`${path} is not cacheable`, async ({ page }) => {
      const response = await page.goto(path);
      expect(response!.headers()["cache-control"]).toContain("no-store");
    });
  }
});

test.describe("Catalog items JSON", () => {
  test("list honours pageSize and reports the seeded total of 101", async ({ page }) => {
    const { response, contentType } = await open(page, `/api/catalog/items?${V}&pageSize=3`);
    expect(response.status()).toBe(200);
    expect(contentType).toBe("application/json");
    const json = await bodyJson(page);
    expect(json).toMatchObject({ pageIndex: 0, pageSize: 3, count: 101 });
    expect(json.data).toHaveLength(3);
    expect(json.data[0]).toMatchObject({
      id: 99,
      name: "Adventurer GPS Watch",
      price: 199.99,
      pictureFileName: "99.webp",
      catalogBrand: { id: 7, brand: "Solstix" },
    });
  });

  test("default page size is 10", async ({ request }) => {
    const res = await request.get(`/api/catalog/items?${V}`);
    expect(res.status()).toBe(200);
    const json = await res.json();
    expect(json.pageSize).toBe(10);
    expect(json.count).toBe(101);
    expect(json.data).toHaveLength(10);
  });

  test("second page returns different items than the first", async ({ request }) => {
    const p0 = await (await request.get(`/api/catalog/items?${V}&pageIndex=0&pageSize=5`)).json();
    const p1 = await (await request.get(`/api/catalog/items?${V}&pageIndex=1&pageSize=5`)).json();
    expect(p1.pageIndex).toBe(1);
    const ids0 = p0.data.map((i: { id: number }) => i.id);
    const ids1 = p1.data.map((i: { id: number }) => i.id);
    expect(ids1.filter((id: number) => ids0.includes(id))).toEqual([]);
  });

  test("single item renders as JSON in the browser", async ({ page }) => {
    const { response, contentType } = await open(page, `/api/catalog/items/1?${V}`);
    expect(response.status()).toBe(200);
    expect(contentType).toBe("application/json");
    const json = await bodyJson(page);
    expect(json).toMatchObject({
      id: 1,
      name: "Wanderer Black Hiking Boots",
      price: 109.99,
      pictureFileName: "1.webp",
      catalogBrand: { id: 1, brand: "Daybird" },
      availableStock: 100,
    });
  });

  test("unknown item id returns 404", async ({ request }) => {
    const res = await request.get(`/api/catalog/items/9999?${V}`);
    expect(res.status()).toBe(404);
  });

  test("search by name finds the Adventurer GPS Watch", async ({ request }) => {
    const res = await request.get(`/api/catalog/items/by/Adventurer?${V}`);
    expect(res.status()).toBe(200);
    const json = await res.json();
    expect(json.count).toBeGreaterThanOrEqual(1);
    expect(json.data.map((i: { name: string }) => i.name)).toContain("Adventurer GPS Watch");
  });

  test("semantic search route is reachable and empty without an AI backend", async ({ request }) => {
    const res = await request.get(`/api/catalog/items/withsemanticrelevance/shoes?${V}`);
    expect(res.status()).toBe(200);
    expect(await res.json()).toMatchObject({ pageIndex: 0, pageSize: 10, count: 0, data: [] });
  });

  test("versioned routes without api-version return 400 ApiVersionUnspecified", async ({ request }) => {
    const res = await request.get("/api/catalog/items");
    expect(res.status()).toBe(400);
    expect(res.headers()["content-type"]).toContain("application/problem+json");
    expect(await res.json()).toMatchObject({ code: "ApiVersionUnspecified", title: "Unspecified API version", status: 400 });
  });
});

test.describe("Catalog lookups", () => {
  test("brands: 13 brands including Daybird and AirStrider", async ({ page }) => {
    await page.goto(`/api/catalog/catalogbrands?${V}`);
    const brands = await bodyJson(page);
    expect(brands).toHaveLength(13);
    const names = brands.map((b: { brand: string }) => b.brand);
    expect(names).toEqual(expect.arrayContaining(["AirStrider", "B&R", "Daybird"]));
  });

  test("types: the eight seeded product types", async ({ request }) => {
    const res = await request.get(`/api/catalog/catalogtypes?${V}`);
    expect(res.status()).toBe(200);
    const names = (await res.json()).map((t: { type: string }) => t.type).sort();
    expect(names).toEqual(["Bags", "Climbing", "Cycling", "Footwear", "Jackets", "Navigation", "Ski/boarding", "Trekking"]);
  });
});

test.describe("Item picture", () => {
  test("item 1 pic renders as a 600x600 webp image", async ({ page }) => {
    const { response, contentType } = await open(page, `/api/catalog/items/1/pic?${V}`);
    expect(response.status()).toBe(200);
    expect(contentType).toBe("image/webp");
    expect(response.headers()["content-type"]).toContain("image/webp");
    const img = page.locator("img");
    await expect(img).toHaveCount(1);
    const size = await img.evaluate((el: HTMLImageElement) => ({ w: el.naturalWidth, h: el.naturalHeight }));
    expect(size).toEqual({ w: 600, h: 600 });
    expect((await response.body()).length).toBeGreaterThan(10_000);
  });

  test("pic without api-version is 400 problem+json", async ({ page }) => {
    const { response } = await open(page, "/api/catalog/items/1/pic");
    expect(response.status()).toBe(400);
    expect(response.headers()["content-type"]).toContain("application/problem+json");
    expect(await bodyJson(page)).toMatchObject({ code: "ApiVersionUnspecified" });
  });

  test("pic for a missing item is 404 problem+json", async ({ page }) => {
    const { response } = await open(page, `/api/catalog/items/9999/pic?${V}`);
    expect(response.status()).toBe(404);
    expect(response.headers()["content-type"]).toContain("application/problem+json");
    expect(await bodyJson(page)).toMatchObject({ title: "Not Found", status: 404 });
  });
});

test.describe("OpenAPI document and Production-only surface", () => {
  test("/openapi/v1.json describes the Catalog HTTP API", async ({ page }) => {
    const { response, contentType } = await open(page, "/openapi/v1.json");
    expect(response.status()).toBe(200);
    expect(contentType).toBe("application/json");
    const doc = await bodyJson(page);
    expect(doc.openapi).toMatch(/^3\./);
    expect(doc.info).toMatchObject({ title: "eShop - Catalog HTTP API", version: "1.0" });
    expect(Object.keys(doc.paths)).toEqual(
      expect.arrayContaining(["/api/catalog/items", "/api/catalog/items/{id}", "/api/catalog/items/{id}/pic"]),
    );
  });

  test("/openapi/v2.json is served too", async ({ request }) => {
    const res = await request.get("/openapi/v2.json");
    expect(res.status()).toBe(200);
  });

  // Scalar UI and the "/" redirect are Development-only (OpenApi.Extensions.cs), so they must
  // be absent in this Production deployment.
  for (const path of ["/", "/scalar/v1", "/scalar", "/swagger", "/metrics"]) {
    test(`${path} is 404 problem+json in Production`, async ({ page }) => {
      const { response } = await open(page, path);
      expect(response.status()).toBe(404);
      expect(response.headers()["content-type"]).toContain("application/problem+json");
      expect(await bodyJson(page)).toMatchObject({ title: "Not Found", status: 404 });
    });
  }
});
