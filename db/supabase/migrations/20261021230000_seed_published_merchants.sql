-- Seed standard published merchants from merchant_category_rules and top brands
-- so that public merchant search and recommendation have real merchants to match.

insert into merchants (vpa, display_name, category_id, is_published, confidence, confidence_score, confirmation_count)
select 
  (mcr.pattern || '@upi')::citext as vpa,
  case 
    when mcr.pattern = 'amazonpay' then 'Amazon Pay'
    when mcr.pattern = 'paytmwallet' then 'Paytm'
    when mcr.pattern = 'mobikwik' then 'MobiKwik'
    when mcr.pattern = 'swiggyinstamart' then 'Swiggy Instamart'
    when mcr.pattern = 'blinkit' then 'Blinkit'
    when mcr.pattern = 'zepto' then 'Zepto'
    when mcr.pattern = 'bigbasket' then 'BigBasket'
    when mcr.pattern = 'jiomart' then 'JioMart'
    when mcr.pattern = 'dmart' then 'DMart'
    when mcr.pattern = 'reliancefresh' then 'Reliance Fresh'
    when mcr.pattern = 'moreretail' then 'More Retail'
    when mcr.pattern = 'swiggy' then 'Swiggy'
    when mcr.pattern = 'zomato' then 'Zomato'
    when mcr.pattern = 'dominos' then 'Domino''s Pizza'
    when mcr.pattern = 'mcdonald' then 'McDonald''s'
    when mcr.pattern = 'starbucks' then 'Starbucks'
    when mcr.pattern = 'kfc' then 'KFC'
    when mcr.pattern = 'eazydiner' then 'EazyDiner'
    when mcr.pattern = 'amazon' then 'Amazon'
    when mcr.pattern = 'flipkart' then 'Flipkart'
    when mcr.pattern = 'myntra' then 'Myntra'
    when mcr.pattern = 'ajio' then 'AJIO'
    when mcr.pattern = 'nykaa' then 'Nykaa'
    when mcr.pattern = 'meesho' then 'Meesho'
    when mcr.pattern = 'tatacliq' then 'Tata CLiQ'
    when mcr.pattern = 'irctc' then 'IRCTC'
    when mcr.pattern = 'makemytrip' then 'MakeMyTrip'
    when mcr.pattern = 'goibibo' then 'Goibibo'
    when mcr.pattern = 'cleartrip' then 'Cleartrip'
    when mcr.pattern = 'yatra' then 'Yatra'
    when mcr.pattern = 'indigo' then 'IndiGo'
    when mcr.pattern = 'airindia' then 'Air India'
    when mcr.pattern = 'vistara' then 'Vistara'
    when mcr.pattern = 'oyorooms' then 'OYO Rooms'
    when mcr.pattern = 'ubereats' then 'Uber Eats'
    when mcr.pattern = 'uber' then 'Uber'
    when mcr.pattern = 'olacabs' then 'Ola'
    when mcr.pattern = 'rapido' then 'Rapido'
    when mcr.pattern = 'indianoil' then 'Indian Oil'
    when mcr.pattern = 'bharatpetroleum' then 'Bharat Petroleum'
    when mcr.pattern = 'hindustanpetroleum' then 'Hindustan Petroleum'
    when mcr.pattern = 'hpcl' then 'HPCL'
    when mcr.pattern = 'bpcl' then 'BPCL'
    when mcr.pattern = 'shell' then 'Shell'
    when mcr.pattern = 'netflix' then 'Netflix'
    when mcr.pattern = 'hotstar' then 'Disney+ Hotstar'
    when mcr.pattern = 'spotify' then 'Spotify'
    when mcr.pattern = 'bookmyshow' then 'BookMyShow'
    when mcr.pattern = 'primevideo' then 'Amazon Prime Video'
    when mcr.pattern = 'sonyliv' then 'SonyLIV'
    else initcap(mcr.pattern)
  end as display_name,
  mcr.category_id,
  true as is_published,
  'high'::record_confidence as confidence,
  0.950 as confidence_score,
  10 as confirmation_count
from merchant_category_rules mcr
where mcr.is_active = true
on conflict (vpa) do update set
  display_name = excluded.display_name,
  category_id = excluded.category_id,
  is_published = true,
  confidence = 'high';
