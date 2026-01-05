-- Migration script to overhaul financial_year columns and dependencies
-- Equivalent to prepare-db-for-partitioning.ps1

-- 1. Rename Columns (fin_year, fin_year_id, financial_year_id -> financial_year)
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.table_schema, c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t ON c.table_schema = t.table_schema AND c.table_name = t.table_name
        WHERE c.column_name IN ('financial_year_id','fin_year_id','fin_year')
          AND t.table_type = 'BASE TABLE'
          AND c.table_schema NOT IN ('information_schema', 'pg_catalog', 'public', 'master')
          AND NOT EXISTS (
              SELECT 1
              FROM information_schema.columns c2
              WHERE c2.table_schema = c.table_schema
                AND c2.table_name = c.table_name
                AND c2.column_name = 'financial_year'
          )
    LOOP
        -- Double check if financial_year exists
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = r.table_schema AND table_name = r.table_name AND column_name = 'financial_year'
        ) THEN
            RAISE NOTICE 'Skipping rename for %.% because financial_year exists', r.table_schema, r.table_name;
            CONTINUE;
        END IF;

        RAISE NOTICE 'Renaming column %.% (%) to financial_year', r.table_schema, r.table_name, r.column_name;
        EXECUTE format('ALTER TABLE %I.%I RENAME COLUMN %I TO financial_year', r.table_schema, r.table_name, r.column_name);
    END LOOP;
END $$;


-- 2. Update Dependencies (Procedures, Functions, Views, Materialized Views)
DO $$
DECLARE
    r RECORD;
BEGIN
    -- Procedures
    FOR r IN
        SELECT regexp_replace(regexp_replace(regexp_replace(pg_get_functiondef(c.oid), '(^|[^a-zA-Z0-9_])financial_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi') AS def
        FROM pg_catalog.pg_proc c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.pronamespace
        WHERE c.prokind = 'p' AND c.pronamespace NOT IN (11,14751,99,2200) AND n.nspname NOT IN ('public', 'master')
          AND (pg_get_functiondef(c.oid) ILIKE '%fin_year%' OR pg_get_functiondef(c.oid) ILIKE '%financial_year_id%' OR pg_get_functiondef(c.oid) ILIKE '%fin_year_id%')
    LOOP
        EXECUTE r.def;
    END LOOP;

    -- Functions
    FOR r IN
        SELECT regexp_replace(regexp_replace(regexp_replace(pg_get_functiondef(c.oid), '(^|[^a-zA-Z0-9_])financial_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi') AS def
        FROM pg_catalog.pg_proc c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.pronamespace
        WHERE c.prokind = 'f' AND c.pronamespace NOT IN (11,14751,99,2200) AND n.nspname NOT IN ('public', 'master')
          AND (pg_get_functiondef(c.oid) ILIKE '%fin_year%' OR pg_get_functiondef(c.oid) ILIKE '%financial_year_id%' OR pg_get_functiondef(c.oid) ILIKE '%fin_year_id%')
    LOOP
        EXECUTE r.def;
    END LOOP;

    -- Views
    FOR r IN
        SELECT 'CREATE OR REPLACE VIEW ' || n.nspname || '.' || c.relname || E'\nAS\n' ||
            regexp_replace(regexp_replace(regexp_replace(pg_get_viewdef(c.oid, true), '(^|[^a-zA-Z0-9_])financial_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi') AS def
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'v' AND c.relnamespace NOT IN (11,14751,99,2200) AND n.nspname NOT IN ('public', 'master')
          AND (pg_get_viewdef(c.oid,true) ILIKE '%fin_year%' OR pg_get_viewdef(c.oid,true) ILIKE '%financial_year_id%' OR pg_get_viewdef(c.oid,true) ILIKE '%fin_year_id%')
    LOOP
        EXECUTE r.def;
    END LOOP;

    -- Materialized Views
    FOR r IN
        SELECT n.nspname, c.relname,
            'CREATE MATERIALIZED VIEW ' || n.nspname || '.' || c.relname || E'\nAS\n' ||
            regexp_replace(regexp_replace(regexp_replace(pg_get_viewdef(c.oid, true), '(^|[^a-zA-Z0-9_])financial_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year_id([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi'), '(^|[^a-zA-Z0-9_])fin_year([^a-zA-Z0-9_]|$)', '\1financial_year\2', 'gi') AS def
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'm' AND c.relnamespace NOT IN (11,14751,99,2200) AND n.nspname NOT IN ('public', 'master')
          AND (pg_get_viewdef(c.oid,true) ILIKE '%fin_year%' OR pg_get_viewdef(c.oid,true) ILIKE '%financial_year_id%' OR pg_get_viewdef(c.oid,true) ILIKE '%fin_year_id%')
    LOOP
        EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS ' || r.nspname || '.' || r.relname || ' CASCADE';
        EXECUTE r.def;
    END LOOP;
END $$;


-- 3 & 4. Add financial_year column and Backfill
SET lock_timeout = '10s';

DO $$
DECLARE
    r RECORD;
    child RECORD;
    found_col text;
    priority_cols text[] := ARRAY['created_at', 'voucher_date', 'invoice_date', 'event_taken_at', 'entrydate', 'generated_at', 'txn_at'];
    col_name text;
    rows_updated int;
BEGIN
    FOR r IN
        SELECT n.nspname as table_schema, c.relname as table_name, c.relkind, c.oid
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE (c.relkind = 'r' OR c.relkind = 'p')
          AND NOT c.relispartition
          AND n.nspname NOT IN ('information_schema', 'pg_catalog', 'public', 'master')
          AND c.relname NOT IN ('queue_master')
          AND NOT EXISTS (
              SELECT 1
              FROM pg_catalog.pg_attribute a
              WHERE a.attrelid = c.oid
                AND a.attname = 'financial_year'
                AND NOT a.attisdropped
          )
    LOOP
        RAISE NOTICE 'Processing %.% (Type: %)', r.table_schema, r.table_name, r.relkind;

        -- Add Column
        BEGIN
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS financial_year smallint', r.table_schema, r.table_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed to add column to %.%: %', r.table_schema, r.table_name, SQLERRM;
            CONTINUE;
        END;

        -- Backfill Logic
        IF r.relkind = 'p' THEN
            -- Partitioned Table: Iterate children
            FOR child IN
                SELECT n.nspname, c.relname
                FROM pg_inherits i
                JOIN pg_class c ON i.inhrelid = c.oid
                JOIN pg_namespace n ON c.relnamespace = n.oid
                WHERE i.inhparent = r.oid
            LOOP
                -- Find timestamp column for child (or parent schema)
                found_col := NULL;
                FOREACH col_name IN ARRAY priority_cols LOOP
                    PERFORM 1 FROM information_schema.columns 
                    WHERE table_schema = child.nspname AND table_name = child.relname AND column_name = col_name;
                    IF FOUND THEN
                        found_col := col_name;
                        EXIT;
                    END IF;
                END LOOP;

                IF found_col IS NOT NULL THEN
                    RAISE NOTICE 'Updating %.% using % (Batched)', child.nspname, child.relname, found_col;
                    -- Disable triggers
                    BEGIN
                        EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER ALL', child.nspname, child.relname);
                        
                        -- Batched Update Loop
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
                                child.nspname, child.relname, 
                                found_col, found_col, found_col, found_col,
                                child.nspname, child.relname, found_col
                            );
                            
                            GET DIAGNOSTICS rows_updated = ROW_COUNT;
                            RAISE NOTICE '  -> Updated rows: %', rows_updated;
                            EXIT WHEN rows_updated < 50000;
                        END LOOP;

                        -- Enable triggers
                        EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER ALL', child.nspname, child.relname);
                    EXCEPTION WHEN OTHERS THEN
                         RAISE WARNING 'Failed to update %.%: %', child.nspname, child.relname, SQLERRM;
                         EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER ALL', child.nspname, child.relname);
                    END;
                END IF;
            END LOOP;
        ELSE
            -- Regular Table
            found_col := NULL;
            FOREACH col_name IN ARRAY priority_cols LOOP
                PERFORM 1 FROM information_schema.columns 
                WHERE table_schema = r.table_schema AND table_name = r.table_name AND column_name = col_name;
                IF FOUND THEN
                    found_col := col_name;
                    EXIT;
                END IF;
            END LOOP;

            IF found_col IS NOT NULL THEN
                RAISE NOTICE 'Updating %.% using % (Batched)', r.table_schema, r.table_name, found_col;
                BEGIN
                    EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER ALL', r.table_schema, r.table_name);
                    
                    -- Batched Update Loop
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
                        EXIT WHEN rows_updated < 50000;
                    END LOOP;
                        
                    EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER ALL', r.table_schema, r.table_name);
                EXCEPTION WHEN OTHERS THEN
                    RAISE WARNING 'Failed to update %.%: %', r.table_schema, r.table_name, SQLERRM;
                    EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER ALL', r.table_schema, r.table_name);
                END;
            END IF;
        END IF;
    END LOOP;
END $$;
