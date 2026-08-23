import urllib.request
import re
import json

def fetch_cards(url, regexes):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
        html = urllib.request.urlopen(req).read().decode('utf-8')
        matches = []
        for r in regexes:
            matches.extend(re.findall(r, html, re.IGNORECASE))
        
        unique_cards = set()
        for m in matches:
            if isinstance(m, tuple):
                m = m[0]
            m = re.sub(r'<[^>]+>', '', m).strip()
            # Clean up encoded chars
            m = m.replace('&#8211;', '-').replace('&amp;', '&').replace('&#038;', '&')
            
            # Simple heuristic
            if 'card' in m.lower() and 5 < len(m) < 60:
                unique_cards.add(m)
        return list(unique_cards)
    except Exception as e:
        print(f"Error fetching {url}: {e}")
        return []

sbi_cards = fetch_cards('https://cardinsider.com/sbi-card/', [
    r'title=\"(.*?)\"',
    r'alt=\"(.*?)\"',
    r'<h3.*?>(.*?)</h3>',
    r'<a.*?>(.*? SBI Card.*?)</a>'
])

print("SBI Cards Found on CardInsider:", len(sbi_cards))
for c in sorted(sbi_cards):
    print("-", c)
