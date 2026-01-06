-- 1. Rename Columns (fin_year, fin_year_id -> financial_year)
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
    LOOP
        -- Safety Check: Don't rename if target 'financial_year' already exists
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = r.table_schema AND table_name = r.table_name AND column_name = 'financial_year'
        ) THEN
            RAISE NOTICE 'Renaming %.% column % to financial_year', r.table_schema, r.table_name, r.column_name;
            EXECUTE format('ALTER TABLE %I.%I RENAME COLUMN %I TO financial_year', r.table_schema, r.table_name, r.column_name);
        END IF;
    END LOOP;
END $$;