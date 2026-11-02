-- Usage: psql -v rows=200000 -f sql/01_pg_seed.sql
-- Random but repeatable beer sales over the last 90 days.
SELECT setseed(0.42) \gset
INSERT INTO beer_sales (sold_at, country, beer_name, channel, customer_id, liters, price_eur)
SELECT now() - random() * interval '90 days',
       c.countries[r.i], c.names[r.i], c.channels[1 + floor(random() * 4 + g * 0)::int],
       (random() * 100000)::int,
       round((0.3 + random() * 24)::numeric, 1),
       round((1 + random() * 60)::numeric, 2)
FROM generate_series(1, :rows) AS g
CROSS JOIN LATERAL (SELECT 1 + floor(random() * 12 + g * 0)::int AS i) AS r
CROSS JOIN (SELECT ARRAY['Chimay', 'Leffe bruin', 'Duvel', 'Pilsner Urquell', 'Budvar', 'Koelsch',
                         'Weizen', 'Guinness', 'Heineken', 'Estrella Damm', 'Samuel Adams', 'Moretti'] AS names,
                   ARRAY['BE', 'BE', 'BE', 'CZ', 'CZ', 'DE', 'DE', 'IE', 'NL', 'ES', 'US', 'IT'] AS countries,
                   ARRAY['bar', 'shop', 'online', 'festival'] AS channels) AS c;
