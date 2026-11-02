-- One bulk INSERT of 2,000,000 rows generated inside ClickHouse = one more part (bigger, and cheaper per row).
INSERT INTO ${CH_DB}.b_sales
WITH [('Chimay','BE'), ('Leffe bruin','BE'), ('Duvel','BE'), ('Pilsner Urquell','CZ'), ('Budvar','CZ'), ('Koelsch','DE'),
      ('Weizen','DE'), ('Guinness','IE'), ('Heineken','NL'), ('Estrella Damm','ES'), ('Samuel Adams','US'), ('Moretti','IT')] AS beers,
     beers[1 + cityHash64(number) % length(beers)] AS b
SELECT b.1, b.2, round(0.3 + (cityHash64(number, 7) % 2400) / 100, 1), now() - toIntervalSecond(cityHash64(number, 3) % (90 * 86400))
FROM numbers(2000000);
