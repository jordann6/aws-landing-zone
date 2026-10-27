-- The password-auth consumer that rotation exists for (run by
-- scripts/rotation-bootstrap.sh as the RDS master, against the orders database,
-- after release-guard's bootstrap.sql has created the orders schema).
--
-- orders_reporting stands in for a BI tool or third party that cannot use IAM
-- database authentication. It reads, nothing else, and it is deliberately NOT
-- granted rds_iam: it is the password path. The app keeps IAM tokens (release-guard
-- ADR-0004). The rotation function creates orders_reporting_clone on its first run
-- and grants it this role, so both alternating users carry the same rights.
--
-- The initial password arrives in the REPORTING_PW environment variable (from a
-- short-lived Secret), so it is never on a command line.
\getenv pw REPORTING_PW

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'orders_reporting') THEN
        CREATE ROLE orders_reporting LOGIN;
    END IF;
END
$$;

-- Set every run, so a re-bootstrap re-seeds the user and the secret together.
ALTER ROLE orders_reporting WITH LOGIN PASSWORD :'pw';

GRANT CONNECT ON DATABASE orders TO orders_reporting;
GRANT USAGE ON SCHEMA orders TO orders_reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA orders TO orders_reporting;

-- Tables a later release adds stay readable without re-running this. Defaults
-- apply to objects the migrator creates, which is every table in the schema.
GRANT orders_migrator TO appadmin;
ALTER DEFAULT PRIVILEGES FOR ROLE orders_migrator IN SCHEMA orders
    GRANT SELECT ON TABLES TO orders_reporting;
REVOKE orders_migrator FROM appadmin;
