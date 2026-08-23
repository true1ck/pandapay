import re

with open('ALL_CARDS_LIST.md', 'r', encoding='utf-8') as f:
    all_cards = f.read()

with open('CARDS_BY_ISSUER_INDIA.md', 'r', encoding='utf-8') as f:
    cards_india = f.read()

# Helper to extract a section from ALL_CARDS_LIST.md
def extract_section(text, header_start, next_header):
    # Regex to find everything between header_start and next_header
    pattern = re.compile(re.escape(header_start) + r'(.*?)(?=' + re.escape(next_header) + r'|\Z)', re.DOTALL)
    match = pattern.search(text)
    if match:
        return header_start + match.group(1).rstrip() + '\n\n'
    return None

# Mapping of Bank Header in CARDS_BY_ISSUER_INDIA.md to next header
banks_to_update = [
    ('### State Bank of India (SBI Card)', '### Bank of Baroda'),
    ('### HDFC Bank', '### ICICI Bank'),
    ('### ICICI Bank', '### Axis Bank'),
    ('### Axis Bank', '### Kotak Mahindra Bank'),
    ('### Kotak Mahindra Bank', '### IndusInd Bank'),
    ('### IndusInd Bank', '### Yes Bank'),
    ('### IDFC FIRST Bank', '### RBL Bank'),
    ('### RBL Bank', '### Federal Bank'),
    ('### Standard Chartered', '### HSBC')
]

for start, nxt in banks_to_update:
    # Get exhaustive content
    exhaustive_content = extract_section(all_cards, start, nxt)
    if not exhaustive_content:
        print(f"Could not find exhaustive content for {start}")
        continue
    
    # Replace in CARDS_BY_ISSUER_INDIA.md
    # We find the section in CARDS_BY_ISSUER_INDIA.md to replace
    pattern = re.compile(re.escape(start) + r'(.*?)(?=' + re.escape(nxt) + r')', re.DOTALL)
    
    match = pattern.search(cards_india)
    if match:
        cards_india = cards_india[:match.start()] + exhaustive_content + cards_india[match.end():]
        print(f"Successfully replaced {start}")
    else:
        print(f"Could not find section in CARDS_BY_ISSUER_INDIA.md for {start}")

# Write back
with open('CARDS_BY_ISSUER_INDIA.md', 'w', encoding='utf-8') as f:
    f.write(cards_india)
