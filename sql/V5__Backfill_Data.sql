-- sql/V3__Backfill_Data.sql

-- Set a lock timeout so we don't hang the DB if a table is busy
SET lock_timeout = '5s';

DO $$
DECLARE
    r RECORD;
    found_col text;
    -- Priority: Date columns to calculate financial_year from
    priority_cols text[] := ARRAY['created_at', 'voucher_date', 'invoice_date', 'event_taken_at', 'entrydate', 'generated_at', 'txn_at'];
    col_name text;
    rows_updated int;
BEGIN
    FOR r IN
        SELECT n.nspname as table_schema, c.relname as table_name
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE (c.relkind = 'r') -- Only base tables (no need to update partitions separately if parent is handled, or vice versa depending on setup)
          AND n.nspname NOT IN ('information_schema', 'pg_catalog', 'public', 'master')
          -- Only process tables that HAVE financial_year column
          AND EXISTS (
              SELECT 1 FROM pg_catalog.pg_attribute a
              WHERE a.attrelid = c.oid AND a.attname = 'financial_year' AND NOT a.attisdropped
          )
    LOOP
        -- Find the best column to use for calculation
        found_col := NULL;
        FOREACH col_name IN ARRAY priority_cols LOOP
            PERFORM 1 FROM information_schema.columns 
            WHERE table_schema = r.table_schema AND table_name = r.table_name AND column_name = col_name;
            IF FOUND THEN
                found_col := col_name;
                EXIT;
            END IF;
        END LOOP;

        -- Run Update
        IF found_col IS NOT NULL THEN
            RAISE NOTICE 'Updating %.% using % (Batched)', r.table_schema, r.table_name, found_col;
            
            LOOP
                EXECUTE format('UPDATE %I.%I SET financial_year = (
                        ((EXTRACT(YEAR FROM %I)::int - (CASE WHEN EXTRACT(MONTH FROM %I) < 4 THEN 1 ELSE 0 END)) %% 100) * 100 + 
                        ((EXTRACT(YEAR FROM %I)::int - (CASE WHEN EXTRACT(MONTH FROM %I) < 4 THEN 1 ELSE 0 END) + 1) %% 100)
                    )::smallint 
                    WHERE ctid IN (
                        SELECT ctid FROM %I.%I 
                        WHERE financial_year IS NULL AND %I IS NOT NULL 
                        LIMIT 50000
                    )', 
                    r.table_schema, r.table_name, 
                    found_col, found_col, found_col, found_col,
                    r.table_schema, r.table_name, found_col
                );
                
                GET DIAGNOSTICS rows_updated = ROW_COUNT;
                RAISE NOTICE '  -> Updated rows: %', rows_updated;
                
                -- Exit loop when no more rows need updating
                EXIT WHEN rows_updated < 50000;
            END LOOP;
        END IF;
    END LOOP;
END $$;