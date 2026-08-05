import httpx

from pandapay_scraper.robots import RobotsChecker


def _client(robots_txt: str, status_code: int = 200) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(status_code, text=robots_txt)

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_disallowed_path_is_never_marked_allowed():
    checker = RobotsChecker(_client("User-agent: *\nDisallow: /reward-terms/\n"))
    result = checker.is_allowed("https://bank.example/reward-terms/millennia")
    assert result.allowed is False


def test_allowed_path_is_marked_allowed():
    checker = RobotsChecker(_client("User-agent: *\nDisallow: /admin/\n"))
    result = checker.is_allowed("https://bank.example/reward-terms/millennia")
    assert result.allowed is True


def test_missing_robots_txt_defaults_to_allowed_per_standard_semantics():
    checker = RobotsChecker(_client("Not Found", status_code=404))
    result = checker.is_allowed("https://bank.example/reward-terms/millennia")
    assert result.allowed is True


def test_network_failure_fetching_robots_txt_fails_closed_not_open():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    checker = RobotsChecker(httpx.Client(transport=httpx.MockTransport(handler)))
    result = checker.is_allowed("https://bank.example/reward-terms/millennia")
    assert result.allowed is False


def test_robots_txt_is_only_fetched_once_per_host_then_cached():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url)
        return httpx.Response(200, text="User-agent: *\nDisallow:\n")

    checker = RobotsChecker(httpx.Client(transport=httpx.MockTransport(handler)))
    checker.is_allowed("https://bank.example/page-one")
    checker.is_allowed("https://bank.example/page-two")
    assert len(calls) == 1
