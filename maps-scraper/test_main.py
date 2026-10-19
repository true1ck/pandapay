import unittest
import asyncio
from unittest.mock import AsyncMock, patch

import main


class LookupTests(unittest.IsolatedAsyncioTestCase):
    async def test_keeps_results_when_one_category_fails(self):
        merchant = {
            "merchant_id": "gm_1",
            "distance_meters": 125,
        }
        with patch.object(
            main,
            "scrape_category",
            new=AsyncMock(side_effect=[[merchant], TimeoutError(), []]),
        ):
            merchants, failed_categories = await main.lookup(15.4, 74.0, 2000)

        self.assertEqual(merchants, [merchant])
        self.assertEqual(failed_categories, 1)

    async def test_fails_when_every_category_fails(self):
        with patch.object(
            main,
            "scrape_category",
            new=AsyncMock(side_effect=[TimeoutError(), RuntimeError(), OSError()]),
        ):
            with self.assertRaisesRegex(RuntimeError, "All Google Maps category searches failed"):
                await main.lookup(15.4, 74.0, 2000)

    async def test_overall_deadline_is_bounded(self):
        async def slow_category(*_args):
            await asyncio.sleep(1)

        with patch.object(main, "_lookup_timeout_seconds", 0.01), patch.object(
            main,
            "scrape_category",
            new=slow_category,
        ):
            with self.assertRaisesRegex(RuntimeError, "overall deadline"):
                await main.lookup(15.4, 74.0, 2000)


if __name__ == "__main__":
    unittest.main()
