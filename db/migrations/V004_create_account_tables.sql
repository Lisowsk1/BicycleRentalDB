-- V004: Account supertype with Rider and Staff specializations.
-- Requirements: F-001, F-002, F-012, F-013, F-083, F-086, F-087, F-088.
-- Rider/Staff mirror the ERD: each carries a role column fixed by CHECK and a composite FK to Account.
-- Rules a constraint cannot express (mandatory subtype at commit, immutability, no delete) are in V005.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

CREATE TYPE bicycle_rental.account_role AS ENUM ('rider', 'staff');
CREATE TYPE bicycle_rental.rider_status AS ENUM ('active', 'blocked');

-- Trim ALL surrounding whitespace (not only spaces). Immutable so it can be used in checks and indexes.
CREATE FUNCTION bicycle_rental.trim_ws(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT regexp_replace(p_text, '^\s+|\s+$', '', 'g') $$;

-- F-002 equivalence: trimmed and case-insensitive. Dots and +suffixes stay significant.
CREATE FUNCTION bicycle_rental.normalize_email(p_email text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT lower(bicycle_rental.trim_ws(p_email)) $$;

CREATE TABLE bicycle_rental.account (
    account_id    bigint GENERATED ALWAYS AS IDENTITY,
    first_name    text NOT NULL,
    last_name     text NOT NULL,
    email         text NOT NULL,   -- display value: original capitalization kept (F-087)
    password_hash text NOT NULL,   -- bcrypt only; plaintext is never stored (F-005)
    role          bicycle_rental.account_role NOT NULL,
    CONSTRAINT pk_account PRIMARY KEY (account_id),
    -- ERD: UQ (account_id, role) is the target of the subtype foreign keys below.
    CONSTRAINT uq_account_id_role UNIQUE (account_id, role),
    CONSTRAINT ck_account_first_name_not_blank CHECK (bicycle_rental.trim_ws(first_name) <> ''),
    CONSTRAINT ck_account_last_name_not_blank  CHECK (bicycle_rental.trim_ws(last_name) <> ''),
    CONSTRAINT ck_account_email_trimmed_not_empty
        CHECK (email <> '' AND email = bicycle_rental.trim_ws(email)),
    CONSTRAINT ck_account_password_hash_bcrypt
        CHECK (password_hash ~ '^\$2[aby]\$[0-9]{2}\$.{53}$')
);

-- F-002: unique across riders AND staff, after normalization.
CREATE UNIQUE INDEX ux_account_email_normalized
    ON bicycle_rental.account (bicycle_rental.normalize_email(email));

CREATE TABLE bicycle_rental.rider (
    account_id   bigint NOT NULL,
    status       bicycle_rental.rider_status NOT NULL DEFAULT 'active',
    block_reason text,
    role         bicycle_rental.account_role NOT NULL DEFAULT 'rider',
    CONSTRAINT pk_rider PRIMARY KEY (account_id),
    -- ERD: CHECK role = 'rider' and FK (account_id, role) -> Account (account_id, role).
    -- Together they make a Rider row possible only for a rider-role account, and (with the
    -- staff table) make the two subtypes mutually exclusive.
    CONSTRAINT ck_rider_role CHECK (role = 'rider'),
    CONSTRAINT fk_rider_account FOREIGN KEY (account_id, role)
        REFERENCES bicycle_rental.account (account_id, role) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ck_rider_block_reason_not_blank
        CHECK (block_reason IS NULL OR bicycle_rental.trim_ws(block_reason) <> ''),
    -- Documented rule for F-088: a reason exists only while blocked; unblocking clears it.
    CONSTRAINT ck_rider_block_reason_only_when_blocked
        CHECK (status = 'blocked' OR block_reason IS NULL)
);

CREATE INDEX ix_rider_status ON bicycle_rental.rider (status);

CREATE TABLE bicycle_rental.staff (
    account_id bigint NOT NULL,
    role       bicycle_rental.account_role NOT NULL DEFAULT 'staff',
    CONSTRAINT pk_staff PRIMARY KEY (account_id),
    CONSTRAINT ck_staff_role CHECK (role = 'staff'),
    CONSTRAINT fk_staff_account FOREIGN KEY (account_id, role)
        REFERENCES bicycle_rental.account (account_id, role) ON UPDATE RESTRICT ON DELETE RESTRICT
);
