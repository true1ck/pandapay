"""Coordinate-centred Google Maps web discovery for PandaPay's nearby UI."""

import asyncio
import hashlib
import logging
import math
import re
import time
from urllib.parse import quote

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from playwright.async_api import async_playwright

logger = logging.getLogger("pandapay.maps_scraper")
app = FastAPI(title="PandaPay nearby map discovery")
_browser = None
_cache: dict[str, tuple[float, list[dict], int]] = {}
_inflight: dict[str, asyncio.Task] = {}
_lock = asyncio.Lock()
_scrape_semaphore = asyncio.Semaphore(3)
_category_timeout_seconds = 12
_lookup_timeout_seconds = 55
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
        stage = "browser_context"
        context = await _browser.new_context(locale="en-IN", viewport={"width": 1365, "height": 900})
        page = await context.new_page()
        found = []
        try:
            search = quote(query, safe="")
            url = f"https://www.google.com/maps/search/{search}/@{lat},{lng},15z?hl=en"
            stage = "navigation"
            # Google Maps keeps loading a large client bundle after the first
            # response. Waiting for DOMContentLoaded can exceed the whole
            # search budget on a headless production host even though the
            # results page is already streaming. Continue at response commit
            # and wait explicitly for the results feed below.
            response = await page.goto(url, wait_until="commit", timeout=25000)
            if response is not None and response.status >= 400:
                logger.warning(
                    "Google Maps navigation failed category=%s http_status=%s",
                    category,
                    response.status,
                )
                raise RuntimeError("Google Maps navigation returned an error status")
            # Google can show its regional consent interstitial before Maps.
            # Accepting the site prompt lets the same browser continue to the
            # results feed; if the prompt is absent this is a quick no-op.
            try:
                stage = "consent"
                await page.get_by_role(
                    "button", name=re.compile(r"^(accept all|i agree)$", re.IGNORECASE)
                ).click(timeout=2500)
                await page.wait_for_timeout(500)
            except Exception:
                pass
            stage = "results_feed"
            feed = page.locator('div[role="feed"]')
            await feed.wait_for(timeout=25000)
            stage = "collect_results"
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
        except asyncio.CancelledError:
            logger.warning("Google Maps category scrape cancelled category=%s stage=%s", category, stage)
            raise
        except Exception as exc:
            logger.warning(
                "Google Maps category scrape failed category=%s stage=%s reason=%s",
                category,
                stage,
                type(exc).__name__,
            )
            raise
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
        logger.warning("Google Maps lookup failed reason=overall_timeout")
        raise RuntimeError("Google Maps lookup exceeded its overall deadline") from exc
    unique = {}
    failures = 0
    for (category, _query), outcome in zip(_queries, outcomes):
        if isinstance(outcome, Exception):
            failures += 1
            reason = "timeout" if isinstance(outcome, (TimeoutError, asyncio.TimeoutError)) else type(outcome).__name__
            logger.warning("Google Maps category lookup failed category=%s reason=%s", category, reason)
            continue
        result_set = outcome
        for merchant in result_set:
            unique.setdefault(merchant["merchant_id"], merchant)
    if failures == len(outcomes):
        logger.warning("Google Maps lookup failed reason=all_categories_failed")
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
