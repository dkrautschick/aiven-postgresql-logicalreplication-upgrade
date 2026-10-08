-- Demo schema: a tiny web shop. Deliberately contains the things that bite people
-- during logical replication: identity columns (sequences), a stored generated column,
-- foreign keys, and one table without a primary key.

CREATE TABLE customers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    full_name   text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE products (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         text NOT NULL UNIQUE,
    name        text NOT NULL,
    price_cents integer NOT NULL CHECK (price_cents >= 0)
);

CREATE TABLE orders (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers(id),
    status      text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'paid', 'shipped', 'cancelled')),
    ordered_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_status_idx ON orders (status) WHERE status = 'new';

CREATE TABLE order_items (
    order_id         bigint  NOT NULL REFERENCES orders(id),
    product_id       bigint  NOT NULL REFERENCES products(id),
    qty              integer NOT NULL CHECK (qty > 0),
    unit_price_cents integer NOT NULL,
    -- STORED generated column. PostgreSQL 15 does not publish it; the PostgreSQL 18 subscriber
    -- simply recomputes it. From 18 on, a publisher can send it (publish_generated_columns).
    line_total_cents integer GENERATED ALWAYS AS (qty * unit_price_cents) STORED,
    PRIMARY KEY (order_id, product_id)
);

-- No primary key on purpose. INSERTs replicate fine, UPDATE/DELETE need a replica identity.
CREATE TABLE audit_log (
    happened_at timestamptz NOT NULL DEFAULT now(),
    what        text NOT NULL
);

-- A standalone sequence: logical replication ignores it until PostgreSQL 19.
CREATE SEQUENCE invoice_number_seq START WITH 100000;
