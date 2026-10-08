-- Seed data, small enough to copy in seconds, large enough to look like a database.
INSERT INTO customers (email, full_name)
SELECT format('customer%s@example.com', g), format('Customer %s', g)
FROM generate_series(1, 2000) g;

INSERT INTO products (sku, name, price_cents)
SELECT 'SKU-' || lpad(g::text, 4, '0'), format('Product %s', g), (random() * 20000)::int + 100
FROM generate_series(1, 50) g;

INSERT INTO orders (customer_id, status, ordered_at)
SELECT (random() * 1999)::int + 1,
       (ARRAY['new','paid','shipped','cancelled'])[(random() * 3)::int + 1],
       now() - (random() * interval '365 days')
FROM generate_series(1, 20000) g;

INSERT INTO order_items (order_id, product_id, qty, unit_price_cents)
SELECT o.id, p.id, (random() * 4)::int + 1, p.price_cents
FROM orders o
CROSS JOIN LATERAL (SELECT id, price_cents FROM products ORDER BY random() LIMIT (random() * 2)::int + 1) p
ON CONFLICT DO NOTHING;

INSERT INTO audit_log (what)
SELECT format('seeded order %s', id) FROM orders WHERE id % 100 = 0;

SELECT nextval('invoice_number_seq') FROM generate_series(1, 250);
