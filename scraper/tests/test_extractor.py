from pandapay_scraper.extractor import extract


def test_strips_boilerplate_tags_before_hashing():
    html = """
    <html><body>
      <nav>Home | About | Contact</nav>
      <header>Bank Corp</header>
      <main id="content"><p>Cashback rate: 5% on online spends, capped at Rs.1,000/cycle.</p></main>
      <footer>Copyright 2026</footer>
      <script>trackPageView();</script>
    </body></html>
    """
    result = extract(html)
    assert "Cashback rate" in result.text
    assert "Home | About | Contact" not in result.text
    assert "Copyright 2026" not in result.text
    assert "trackPageView" not in result.text


def test_selector_hint_scopes_to_a_specific_container():
    html = """
    <html><body>
      <div id="promo-banner">Limited time offer! Click now!</div>
      <div id="main-content"><p>Reward T&C: 2x points on dining.</p></div>
    </body></html>
    """
    result = extract(html, selector_hint="#main-content")
    assert "Reward T&C" in result.text
    assert "Limited time offer" not in result.text


def test_identical_content_produces_identical_hash_ignoring_whitespace_differences():
    html_a = "<html><body><p>Rate: 5%</p></body></html>"
    html_b = "<html><body><p>Rate:    5%   </p>\n\n</body></html>"
    assert extract(html_a).content_hash == extract(html_b).content_hash


def test_changed_content_produces_a_different_hash():
    html_a = "<html><body><p>Cap: Rs.1,000</p></body></html>"
    html_b = "<html><body><p>Cap: Rs.2,000</p></body></html>"
    assert extract(html_a).content_hash != extract(html_b).content_hash
