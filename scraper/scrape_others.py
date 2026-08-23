import urllib.request
import re

def fetch_cards(bank, url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        html = urllib.request.urlopen(req).read().decode('utf-8')
        
        matches = []
        matches.extend(re.findall(r'title=\"(.*?)\"', html, re.IGNORECASE))
        matches.extend(re.findall(r'alt=\"(.*?)\"', html, re.IGNORECASE))
        matches.extend(re.findall(r'<h3.*?>(.*?)</h3>', html, re.IGNORECASE))
        matches.extend(re.findall(r'<a.*?>(.*? Credit Card.*?)</a>', html, re.IGNORECASE))
        
        unique_cards = set()
        for m in matches:
            if isinstance(m, tuple): m = m[0]
            m = re.sub(r'<[^>]+>', '', m).strip()
            m = m.replace('&#8211;', '-').replace('&amp;', '&').replace('&#038;', '&').replace('', "'")
            if 'card' in m.lower() and 5 < len(m) < 60 and not m.lower().startswith('best') and '?' not in m and 'Card Insider' not in m and 'feed' not in m.lower():
                unique_cards.add(m)
        print(f"\n{bank} Cards Found:", len(unique_cards))
        for c in sorted(unique_cards):
            print("-", c)
    except Exception as e:
        print(f"Error for {bank}: {e}")

fetch_cards('HDFC', 'https://cardinsider.com/hdfc-bank-credit-card/')
fetch_cards('ICICI', 'https://cardinsider.com/icici-bank-credit-card/')
fetch_cards('Axis', 'https://cardinsider.com/axis-bank-credit-card/')
fetch_cards('Kotak', 'https://cardinsider.com/kotak-bank-credit-card/')
fetch_cards('IndusInd', 'https://cardinsider.com/indusind-bank-credit-card/')
fetch_cards('IDFC FIRST', 'https://cardinsider.com/idfc-first-bank-credit-card/')
fetch_cards('RBL', 'https://cardinsider.com/rbl-bank-credit-card/')
