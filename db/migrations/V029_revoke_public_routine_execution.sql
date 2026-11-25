-- Keep every schema routine private to explicitly granted roles. This also
-- covers routines introduced by later migrations after the original hardening.
REVOKE ALL ON ALL ROUTINES IN SCHEMA bicycle_rental FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA bicycle_rental
    REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
