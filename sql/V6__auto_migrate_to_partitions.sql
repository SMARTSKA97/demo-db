-- Migration V3: Auto-partition tables with financial_year
-- Replicates logic from migrate-to-partitions.ps1

DO $$
DECLARE
    r RECORD;
    c RECORD;
    idx RECORD;
    
    -- Config
    archive_schema text := 'old';
    partition_key text := 'financial_year';
    
    -- State
    candidates_list text[] := ARRAY[]::text[]; -- List of "schema.table"
    candidate_map jsonb := '{}'::jsonb; -- Map "schema.table" -> true
    
    -- Vars
    src_schema text;
    src_table text;
    arc_table text;
    def text;
    new_def text;
    const_name text;
    ref_table_clean text;
    
BEGIN
    -- 1. Setup Archive Schema
    EXECUTE 'CREATE SCHEMA IF NOT EXISTS ' || archive_schema;

    -- 2. Identify Candidates
    -- Must have 'financial_year', not be a partition, not in excluded schemas
    FOR r IN
        SELECT n.nspname, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid
        WHERE a.attname = partition_key
          AND c.relkind = 'r'
          AND NOT c.relispartition
          AND n.nspname NOT IN ('information_schema', 'pg_catalog', 'master', 'public')
          AND n.nspname NOT LIKE 'old_%' -- Avoid re-processing if multiple old schemas existed (though we use 'old')
          AND n.nspname != archive_schema
    LOOP
        candidates_list := array_append(candidates_list, r.nspname || '.' || r.relname);
        candidate_map := jsonb_set(candidate_map, ARRAY[r.nspname || '.' || r.relname], 'true'::jsonb);
    END LOOP;

    RAISE NOTICE 'Found % candidates for partitioning.', array_length(candidates_list, 1);

    -- 3. Move & Rename to Archive
    FOREACH r IN ARRAY candidates_list LOOP
        src_schema := split_part(r, '.', 1);
        src_table := split_part(r, '.', 2);
        arc_table := src_schema || '_' || src_table;
        
        -- Check if already archived (idempotency check)
        PERFORM 1 FROM pg_tables WHERE schemaname = archive_schema AND tablename = arc_table;
        IF FOUND THEN
            RAISE WARNING 'Table %.% already archived as %.%. Skipping move.', src_schema, src_table, archive_schema, arc_table;
        ELSE
            RAISE NOTICE 'Archiving %.% to %.%', src_schema, src_table, archive_schema, arc_table;
            EXECUTE format('ALTER TABLE %I.%I SET SCHEMA %I', src_schema, src_table, archive_schema);
            EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', archive_schema, src_table, arc_table);
        END IF;
    END LOOP;

    -- 4. Create New Partitioned Tables
    FOREACH r IN ARRAY candidates_list LOOP
        src_schema := split_part(r, '.', 1);
        src_table := split_part(r, '.', 2);
        arc_table := src_schema || '_' || src_table;
        
        -- Check if new table exists
        PERFORM 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = src_schema AND c.relname = src_table;
        IF FOUND THEN
            RAISE NOTICE 'Partitioned table %.% already exists. Skipping create.', src_schema, src_table;
        ELSE
            RAISE NOTICE 'Creating partitioned table %.%', src_schema, src_table;
            -- Copy structure (Defaults, Comments) but PARTITION BY
            EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING COMMENTS) PARTITION BY LIST (%I)', 
                           src_schema, src_table, archive_schema, arc_table, partition_key);
        END IF;
    END LOOP;

    -- 5. Recreate Primary Keys & Unique Constraints (Must include partition key)
    FOREACH r IN ARRAY candidates_list LOOP
        src_schema := split_part(r, '.', 1);
        src_table := split_part(r, '.', 2);
        arc_table := src_schema || '_' || src_table;

        FOR c IN
            SELECT pg_get_constraintdef(con.oid) as def, con.conname, con.contype
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            WHERE nsp.nspname = archive_schema AND rel.relname = arc_table
              AND con.contype IN ('p', 'u') -- PK or Unique
        LOOP
            -- Check if constraint already exists on new table (idempotency)
            PERFORM 1 FROM pg_constraint con 
            JOIN pg_class rel ON rel.oid = con.conrelid 
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace 
            WHERE nsp.nspname = src_schema AND rel.relname = src_table AND con.conname = c.conname;
            
            IF FOUND THEN 
                CONTINUE; 
            END IF;

            def := c.def;
            -- Append partition key if missing
            -- Definition format: "PRIMARY KEY (col1, col2)"
            IF def NOT LIKE '%' || partition_key || '%' THEN
                 -- Regex replace ')' with ', financial_year)'
                 -- Using simpler logic: replace last ')'
                 -- Ensure we target the column list part.
                 def := regexp_replace(def, '\)$', ', ' || partition_key || ')');
                 RAISE NOTICE '  --> Modified % to include partition key: %', c.conname, def;
            END IF;
            
            BEGIN
                EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', src_schema, src_table, c.conname, def);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '  !! Failed to recreate constraint % on %.%: %', c.conname, src_schema, src_table, SQLERRM;
            END;
        END LOOP;
    END LOOP;

    -- 6. Recreate Foreign Keys 
    -- (Must point to new tables, and ideally assume composite PKs if target was partitioned)
    FOREACH r IN ARRAY candidates_list LOOP
        src_schema := split_part(r, '.', 1);
        src_table := split_part(r, '.', 2);
        arc_table := src_schema || '_' || src_table;

        FOR c IN
            SELECT pg_get_constraintdef(con.oid) as def, con.conname, 
                   fn.nspname as foreign_schema, ft.relname as foreign_table
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            JOIN pg_class ft ON ft.oid = con.confrelid
            JOIN pg_namespace fn ON fn.oid = ft.relnamespace
            WHERE nsp.nspname = archive_schema AND rel.relname = arc_table
              AND con.contype = 'f'
        LOOP
             -- Check exist
            PERFORM 1 FROM pg_constraint con 
            JOIN pg_class rel ON rel.oid = con.conrelid 
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace 
            WHERE nsp.nspname = src_schema AND rel.relname = src_table AND con.conname = c.conname;
            
            IF FOUND THEN CONTINUE; END IF;

            -- Only proceed if target table is in our 'candidates' list (meaning it was partitioned)
            -- OR if we just want to point to the new location.
            
            -- We need to find the "active" name of the referenced table.
            -- The FK currently points to 'old.referenced_table_archive_name' (wait, usually FKs distinct updates automatically if they are in same schema? No, we moved tables, preventing drop.)
            -- Actually, when we 'ALTER TABLE SET SCHEMA', the FKs pointing TO it and FROM it move with it. 
            -- So 'old.arc_table' has FKs pointing to 'old.other_arc_table' (if both moved).
            
            -- Constraint Def: "FOREIGN KEY (col) REFERENCES old.other_arc_table(col)"
            
            -- Logic:
            -- 1. Identify Target Table Name.
            --    referenced table is currently in 'old' schema.
            --    Its name is 'schema_table'.
            --    We want to point to 'schema.table'.
            
            -- Parse the referenced table from the catalogue, stored in c.foreign_schema, c.foreign_table.
            
            -- If foreign table is in 'old' schema, we infer it was migrated.
            -- Original schema/table name?
            -- archive format: "{Schema}_{Table}"
            -- So we need to reverse map or just check if it's in our candidates.
            
            -- Actually, simpler: check if 'foreign_table' starts with a schema name prefix?
            -- Wait, generic logic: The user follows 'schema_table' convention for archive.
            -- But we have the list of candidates which are 'OriginalSchema.OriginalTable'.
            -- The archived version is 'old.{OriginalSchema}_{OriginalTable}'.
            
            -- Finding the candidate key for the referenced table:
            -- If c.foreign_schema = 'old', then check candidates.
            
            def := c.def;
            
            IF c.foreign_schema = archive_schema THEN
                 -- Attempt to resolve back to original
                 -- We iterate candidates to match the archive name
                 -- (INEFFICIENT but safe)
                 DECLARE
                     cand text;
                     cand_sch text; 
                     cand_tbl text;
                     found_target boolean := false;
                 BEGIN
                     FOREACH cand IN ARRAY candidates_list LOOP
                         cand_sch := split_part(cand, '.', 1);
                         cand_tbl := split_part(cand, '.', 2);
                         IF (cand_sch || '_' || cand_tbl) = c.foreign_table THEN
                             -- FOUND IT.
                             -- Target is cand_sch.cand_tbl
                             
                             -- Replace "REFERENCES old.the_archived_table" with "REFERENCES new_schema.new_table"
                             -- Regex replacement of table name
                             -- NOTE: pg_get_constraintdef output matches identifiers. 
                             
                             -- Simple string replace might be risky but likely valid given naming.
                             -- "REFERENCES old.billing_bill (id)" -> "REFERENCES billing.bill (id)"
                             
                             -- Let's reconstruct definition carefully.
                             -- Extract columns part.
                             -- Def: "FOREIGN KEY (cols) REFERENCES old.tbl(cols)"
                             -- We want: "FOREIGN KEY (cols, financial_year) REFERENCES new_sch.new_tbl(cols, financial_year)"
                             
                             -- 1. Replace Table Ref
                             def := replace(def, 'REFERENCES ' || quote_ident(c.foreign_schema) || '.' || quote_ident(c.foreign_table), 
                                                 'REFERENCES ' || quote_ident(cand_sch) || '.' || quote_ident(cand_tbl));
                             
                             -- 2. Append Partition Key to BOTH sides (Composite FK)
                             -- Only if cols don't already have it.
                             IF def NOT LIKE '%' || partition_key || '%' THEN
                                  -- Replace first column list closing paren ? No, FK list.
                                  -- Format: FOREIGN KEY (a,b) REFERENCES x(c,d)
                                  -- Replace first ) with , fy)
                                  -- Replace last ) with , fy)
                                  
                                  -- Use Regex to be robust. 
                                  -- Replace first occurrence of ')' with ', financial_year)'
                                  def := regexp_replace(def, '\)', ', ' || partition_key || ')');
                                  -- Replace second occurrence (which is now likely the end, or part of REFERENCES)
                                  -- Actually regexp_replace replaces first match by default.
                                  -- So calling it again replaces the next one? No, the string is new.
                                  -- "FOREIGN KEY (a, fy) REFERENCES x(b)"
                                  -- We need to replace the ')' inside REFERENCES (...)
                                  def := regexp_replace(def, '\)$', ', ' || partition_key || ')');
                             END IF;
                             
                             found_target := true;
                             EXIT; -- break inner loop
                         END IF;
                     END LOOP;
                     
                     IF NOT found_target THEN
                        -- Referenced table in 'old' but not in candidates? Maybe previously migrated?
                        -- Retarget to assumed original schema?
                        -- For safety, warn and skip modification (other than maybe schema fix)
                        RAISE NOTICE 'FK % references % which was is in old schema but not in current batch. Skipping composite upgrade.', c.conname, c.foreign_table;
                     END IF;
                 END;
            END IF;
            
            -- Remove 'NOT VALID'
            def := replace(def, ' NOT VALID', '');
            
            BEGIN
                EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', src_schema, src_table, c.conname, def);
            EXCEPTION WHEN OTHERS THEN
                 RAISE WARNING '  !! Failed to recreate FK % on %.%: %', c.conname, src_schema, src_table, SQLERRM;
            END;

        END LOOP;
    END LOOP;

    -- 7. Recreate Indexes (Unique must assume partition key)
    -- Non-unique indexes just retargeted.
    FOREACH r IN ARRAY candidates_list LOOP
        src_schema := split_part(r, '.', 1);
        src_table := split_part(r, '.', 2);
        arc_table := src_schema || '_' || src_table;
        
        FOR idx IN
            SELECT indexdef, indexname 
            FROM pg_indexes 
            WHERE schemaname = archive_schema AND tablename = arc_table
        LOOP
             -- Skip indexes that come from Constraints (PK/Unique) as we already created them.
             -- How to detect? Check if index name matches a constraint name?
             -- (Heuristic, Postgres often names them same)
             PERFORM 1 FROM pg_constraint WHERE conname = idx.indexname AND conrelid = (archive_schema || '.' || arc_table)::regclass;
             IF FOUND THEN CONTINUE; END IF;

             def := idx.indexdef;
             -- Def: "CREATE [UNIQUE] INDEX name ON old.table USING btree (col)"
             
             -- 1. Replace ON clause
             def := replace(def, 'ON ' || quote_ident(archive_schema) || '.' || quote_ident(arc_table), 
                                 'ON ' || quote_ident(src_schema) || '.' || quote_ident(src_table));
             
             -- 2. If UNIQUE, append partition key
             IF def LIKE '%UNIQUE%' AND def NOT LIKE '%' || partition_key || '%' THEN
                 -- "USING btree (col)" -> "USING btree (col, financial_year)"
                 -- Replace last ')'
                 def := regexp_replace(def, '\)$', ', ' || partition_key || ')');
             END IF;
             
             BEGIN
                 EXECUTE def;
             EXCEPTION WHEN OTHERS THEN
                 RAISE WARNING '  !! Failed to recreate index % on %.%: %', idx.indexname, src_schema, src_table, SQLERRM;
             END;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Partition migration loop complete.';
END $$;
