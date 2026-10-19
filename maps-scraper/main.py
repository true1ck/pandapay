"""Coordinate-centred Google Maps web discovery for PandaPay's nearby UI."""

import asyncio
import hashlib
import math
import re
import time
from urllib.parse import quote

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from playwright.async_api import async_playwright

app = FastAPI(title="PandaPay nearby map discovery")
_browser = None
_cache: dict[str, tuple[float, list[dict], int]] = {}
_inflight: dict[str, asyncio.Task] = {}
_lock = asyncio.Lock()
_scrape_semaphore = asyncio.Semaphore(3)
_category_timeout_seconds = 18
_lookup_timeout_seconds = 25
_queries = (
    ("groceries", "supermarkets grocery stores"),
    ("fuel", "petrol pumps fuel stations"),
    ("dining", "restaurants cafes"),
)


class NearbyRequest(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    radius_m: int = Field(default=2000, ge=1, le=2000)


@app.on_event("startup")
async def startup():
    global _browser
    playwright = await async_playwright().start()
    app.state.playwright = playwright
    _browser = await playwright.chromium.launch(headless=True)


@app.on_event("shutdown")
async def shutdown():
    if _browser:
        await _browser.close()
    playwright = getattr(app.state, "playwright", None)
    if playwright:
        await playwright.stop()


@app.get("/ready")
async def ready():
    return {"ready": _browser is not None}


def distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lng2 - lng1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371000 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def coordinates_from_url(url: str):
    # Google Maps place links commonly encode the place point as !3dLAT!4dLNG.
    match = re.search(r"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)", url)
    if not match:
        match = re.search(r"/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)", url)
    if not match:
        return None
    lat, lng = float(match.group(1)), float(match.group(2))
    if -90 <= lat <= 90 and -180 <= lng <= 180:
        return lat, lng
    return None


async def scrape_category(lat: float, lng: float, radius_m: int, category: str, query: str):
    async with _scrape_semaphore:
        context = await _browser.new_context(locale="en-IN", viewport={"width": 1365, "height": 900})
        page = await context.new_page()
        found = []
        try:
            search = quote(query, safe="")
            url = f"https://www.google.com/maps/search/{search}/@{lat},{lng},15z?hl=en"
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            feed = page.locator('div[role="feed"]')
            await feed.wait_for(timeout=18000)
            previous = -1
            for _ in range(4):
                await feed.evaluate("el => el.scrollTo(0, el.scrollHeight)")
                await page.wait_for_timeout(900)
                count = await page.locator('div[role="feed"] a[href*="/maps/place/"]').count()
                if count == previous:
                    break
                previous = count
            cards = page.locator('div[role="feed"] a.hfpxzc, div[role="feed"] a[href*="/maps/place/"]')
            count = min(await cards.count(), 30)
            for index in range(count):
                card = cards.nth(index)
                try:
                    href = await card.get_attribute("href") or ""
                    name = (await card.get_attribute("aria-label") or "").strip()
                    coords = coordinates_from_url(href)
                    if not name or not href or not coords:
                        continue
                    place_lat, place_lng = coords
                    distance = distance_m(lat, lng, place_lat, place_lng)
                    if distance > radius_m:
                        continue
                    place_id = re.search(r"!1s([^!/?]+)", href)
                    stable_key = place_id.group(1) if place_id else href
                    merchant_id = "gm_" + hashlib.sha1(stable_key.encode()).hexdigest()[:20]
                    found.append({
                        "merchant_id": merchant_id,
                        "display_name": name,
                        "category_id": category,
                        "address": None,
                        "grid_lat": place_lat,
                        "grid_lng": place_lng,
                        "source": "google_maps_scrape",
                        "confidence": "medium",
                        "distance_meters": round(distance),
                    })
                except Exception:
                    continue
        finally:
            await context.close()
        return found

async def lookup(lat: float, lng: float, radius_m: int):
    async def scrape_all_categories():
        return await asyncio.gather(*(
            asyncio.wait_for(
                scrape_category(lat, lng, radius_m, category, query),
                timeout=_category_timeout_seconds,
            )
            for category, query in _queries
        ), return_exceptions=True)

    try:
        outcomes = await asyncio.wait_for(
            scrape_all_categories(), timeout=_lookup_timeout_seconds
        )
    except asyncio.TimeoutError as exc:
        raise RuntimeError("Google Maps lookup exceeded its overall deadline") from exc
    unique = {}
    failures = 0
    for outcome in outcomes:
        if isinstance(outcome, Exception):
            failures += 1
            continue
        result_set = outcome
        for merchant in result_set:
            unique.setdefault(merchant["merchant_id"], merchant)
    if failures == len(outcomes):
        raise RuntimeError("All Google Maps category searches failed")
    return sorted(unique.values(), key=lambda item: item["distance_meters"]), failures


@app.post("/nearby")
async def nearby(request: NearbyRequest):
    if _browser is None:
        raise HTTPException(status_code=503, detail="Browser is starting")
    key = f"{request.lat:.4f}:{request.lng:.4f}:{request.radius_m}"
    async with _lock:
        cached = _cache.get(key)
        if cached and cached[0] > time.monotonic():
            return {
                "merchants": cached[1],
                "cached": True,
                "partial": cached[2] > 0,
                "failed_categories": cached[2],
            }
        task = _inflight.get(key)
        if task is None:
            task = asyncio.create_task(lookup(request.lat, request.lng, request.radius_m))
            _inflight[key] = task
    try:
        merchants, failed_categories = await task
        async with _lock:
            _cache[key] = (time.monotonic() + 600, merchants, failed_categories)
        return {
            "merchants": merchants,
            "cached": False,
            "partial": failed_categories > 0,
            "failed_categories": failed_categories,
        }
    except Exception as exc:
        raise HTTPException(status_code=502, detail="Google Maps lookup failed") from exc
    finally:
        async with _lock:
            if _inflight.get(key) is task:
                del _inflight[key]
