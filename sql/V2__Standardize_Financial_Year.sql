-- sql/V2__Standardize_Financial_Year.sql

DO $$
DECLARE
    r RECORD;
BEGIN
    -- Loop through all columns that match your "incorrect" names
    FOR r IN
        SELECT table_schema, table_name, column_name
        FROM information_schema.columns c
        WHERE column_name IN ('financial_year_id','fin_year_id','fin_year')
          -- Safety check: Ensure the target name 'financial_year' doesn't already exist in that table
          AND NOT EXISTS (
              SELECT 1
              FROM information_schema.columns c2
              WHERE c2.table_schema = c.table_schema
                AND c2.table_name = c.table_name
                AND c2.column_name = 'financial_year'
          )
    LOOP
        -- Double check inside loop (Good practice for concurrency)
		IF NOT EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = r.table_schema
              AND table_name   = r.table_name
              AND column_name  = 'financial_year'
        ) THEN
            -- Log what is happening (Optional but helpful for debug)
            RAISE NOTICE 'Renaming column in %.%', r.table_schema, r.table_name;
            
	        EXECUTE format(
	            'ALTER TABLE %I.%I RENAME COLUMN %I TO financial_year;',
	            r.table_schema,
	            r.table_name,
	            r.column_name
	        );
		END IF;
    END LOOP;
END $$;