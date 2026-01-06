-- 3. Add 'financial_year' column to tables that are missing it entirely
DO $$
DECLARE
    r RECORD;
BEGIN
    -- Fail fast if locks cannot be acquired
    SET lock_timeout = '5s';
    
    FOR r IN
        SELECT n.nspname as table_schema, c.relname as table_name
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE (c.relkind = 'r' OR c.relkind = 'p') -- Tables and Partitions
          AND c.relispartition = false -- Exclude declarative child partitions
          AND NOT EXISTS ( -- Exclude inheritance-based child partitions
              SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid
          )
          AND n.nspname NOT IN ('information_schema', 'pg_catalog', 'public', 'master', 'flyway')
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_attribute a
              WHERE a.attrelid = c.oid AND a.attname = 'financial_year' AND NOT a.attisdropped
          )
    LOOP
        RAISE NOTICE 'Adding financial_year to %.%', r.table_schema, r.table_name;
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS financial_year smallint', r.table_schema, r.table_name);
    END LOOP;
END $$;