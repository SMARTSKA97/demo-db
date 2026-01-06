-- 2. Update Dependencies (Procedures, Functions, Views)
DO $$
DECLARE
    r RECORD;
BEGIN
    -- Fix Procedures
    FOR r IN
        SELECT n.nspname, c.proname, 
               regexp_replace(pg_get_functiondef(c.oid), '(fin_year|fin_year_id|financial_year_id)', 'financial_year', 'gi') AS def
        FROM pg_catalog.pg_proc c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.pronamespace
        WHERE c.prokind = 'p' AND n.nspname NOT IN ('public', 'master')
          AND pg_get_functiondef(c.oid) ~* '(fin_year|financial_year_id)'
    LOOP
        RAISE NOTICE 'Updating Procedure: %.%', r.nspname, r.proname;
        EXECUTE r.def;
    END LOOP;

    -- Fix Functions
    FOR r IN
        SELECT n.nspname, c.proname,
               regexp_replace(pg_get_functiondef(c.oid), '(fin_year|fin_year_id|financial_year_id)', 'financial_year', 'gi') AS def
        FROM pg_catalog.pg_proc c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.pronamespace
        WHERE c.prokind = 'f' AND n.nspname NOT IN ('public', 'master')
          AND pg_get_functiondef(c.oid) ~* '(fin_year|financial_year_id)'
    LOOP
        RAISE NOTICE 'Updating Function: %.%', r.nspname, r.proname;
        EXECUTE r.def;
    END LOOP;

    -- Fix Views
    FOR r IN
        SELECT n.nspname, c.relname,
               'CREATE OR REPLACE VIEW ' || n.nspname || '.' || c.relname || ' AS ' ||
               regexp_replace(pg_get_viewdef(c.oid, true), '(fin_year|fin_year_id|financial_year_id)', 'financial_year', 'gi') AS def
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'v' AND n.nspname NOT IN ('public', 'master')
          AND pg_get_viewdef(c.oid, true) ~* '(fin_year|financial_year_id)'
    LOOP
        RAISE NOTICE 'Updating View: %.%', r.nspname, r.relname;
        EXECUTE r.def;
    END LOOP;

    -- Fix Materialized Views
    FOR r IN
        SELECT n.nspname, c.relname,
               'CREATE MATERIALIZED VIEW ' || n.nspname || '.' || c.relname || ' AS ' ||
               regexp_replace(pg_get_viewdef(c.oid, true), '(fin_year|fin_year_id|financial_year_id)', 'financial_year', 'gi') AS def
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'm' AND n.nspname NOT IN ('public', 'master')
          AND pg_get_viewdef(c.oid, true) ~* '(fin_year|financial_year_id)'
    LOOP
        RAISE NOTICE 'Updating Materialized View: %.%', r.nspname, r.relname;
        EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS ' || r.nspname || '.' || r.relname || ' CASCADE';
        EXECUTE r.def;
    END LOOP;
END $$;