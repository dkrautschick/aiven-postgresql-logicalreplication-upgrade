-- Run on the SOURCE. Produces one setval() statement per used sequence; apply the output on the TARGET.
-- Identity-column sequences are included (they live in pg_sequences like any other).
SELECT format('SELECT setval(%L, %s, true);',
              quote_ident(schemaname) || '.' || quote_ident(sequencename),
              last_value)
FROM pg_sequences
WHERE last_value IS NOT NULL
  AND schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;
