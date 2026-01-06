
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;
SET check_function_bodies = false;

--
-- TOC entry 6 (class 2615 OID 920173)
-- Name: bantan; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS bantan;


ALTER SCHEMA bantan OWNER TO postgres;

--
-- TOC entry 7 (class 2615 OID 920174)
-- Name: billing; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS billing;


ALTER SCHEMA billing OWNER TO postgres;

--
-- TOC entry 8 (class 2615 OID 920175)
-- Name: billing_log; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS billing_log;


ALTER SCHEMA billing_log OWNER TO postgres;

--
-- TOC entry 9 (class 2615 OID 920176)
-- Name: billing_master; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS billing_master;


ALTER SCHEMA billing_master OWNER TO postgres;

--
-- TOC entry 10 (class 2615 OID 920177)
-- Name: cts; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS cts;


ALTER SCHEMA cts OWNER TO postgres;

--
-- TOC entry 11 (class 2615 OID 920178)
-- Name: jit; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS jit;


ALTER SCHEMA jit OWNER TO postgres;

--
-- TOC entry 12 (class 2615 OID 920179)
-- Name: master; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS master;


ALTER SCHEMA master OWNER TO postgres;

--
-- TOC entry 13 (class 2615 OID 920180)
-- Name: message_queue; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS message_queue;


ALTER SCHEMA message_queue OWNER TO postgres;

--
-- TOC entry 14 (class 2615 OID 920181)
-- Name: report; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS report;


ALTER SCHEMA report OWNER TO postgres;

--
-- TOC entry 484 (class 1255 OID 920182)
-- Name: adjust_allotment_by_billid(bigint); Type: FUNCTION; Schema: bantan; Owner: postgres
--

CREATE OR REPLACE FUNCTION  bantan.adjust_allotment_by_billid(p_bill_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$

BEGIN

	-- Update Sanction Provisional Balance
	-- UPDATE jit.jit_sanction_transaction_provisional p 
	-- SET provisional_amt = provisional_amt - adj_amount
	-- FROM
	-- (
	-- 	select  sanction_no, ddo_code, sum(booked_amt) as adj_amount from jit.jit_fto_sanction_booking sb 
	-- 	where ref_no =  ANY(SELECT jit_ref_no from billing.ebill_jit_int_map where bill_id=p_bill_id)
	-- 	GROUP BY(sanction_no, ddo_code)
	-- )b 
	-- WHERE p.sanction_no = b.sanction_no AND p.ddo_code = b.ddo_code;  
	
	
	--Update ddo transaction provisional balance
	UPDATE bantan.ddo_allotment_transactions t  
	set provisional_released_amount=provisional_released_amount-adj_amount
	from(
		select allotment_id, sum(amount) as adj_amount from billing.ddo_allotment_booked_bill
		where bill_id=p_bill_id group by allotment_id
	)b 
	WHERE t.allotment_id = b.allotment_id;

	--Update ddo wallet provisional balance
	UPDATE bantan.ddo_wallet w
	set provisional_released_amount=provisional_released_amount-adj_amount
	FROM(
		select ddo_code,active_hoa_id, sum(amount) as adj_amount from billing.ddo_allotment_booked_bill
		where bill_id=p_bill_id group by ddo_code,active_hoa_id
	)b
	where w.sao_ddo_code = b.ddo_code and w.active_hoa_id=b.active_hoa_id;
	
	RETURN NULL;
	END;
$$;


ALTER FUNCTION bantan.adjust_allotment_by_billid(p_bill_id bigint) OWNER TO postgres;

--
-- TOC entry 442 (class 1255 OID 920183)
-- Name: adjust_allotment_by_general_bill(bigint); Type: FUNCTION; Schema: bantan; Owner: postgres
--

CREATE OR REPLACE FUNCTION  bantan.adjust_allotment_by_general_bill(p_bill_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$

BEGIN
	
	--Update ddo transaction provisional balance
	UPDATE bantan.ddo_allotment_transactions t  
	set provisional_released_amount=provisional_released_amount-adj_amount
	from(
		select allotment_id, sum(amount) as adj_amount from billing.ddo_allotment_booked_bill
		where bill_id=p_bill_id group by allotment_id
	)b 
	WHERE t.allotment_id = b.allotment_id;

	--Update ddo wallet provisional balance
	UPDATE bantan.ddo_wallet w
	set provisional_released_amount=provisional_released_amount-adj_amount
	FROM(
		select ddo_code,active_hoa_id, sum(amount) as adj_amount from billing.ddo_allotment_booked_bill
		where bill_id=p_bill_id group by ddo_code,active_hoa_id
	)b
	where w.sao_ddo_code = b.ddo_code and w.active_hoa_id=b.active_hoa_id;
	
	RETURN NULL;
	END;
$$;


ALTER FUNCTION bantan.adjust_allotment_by_general_bill(p_bill_id bigint) OWNER TO postgres;

--
-- TOC entry 490 (class 1255 OID 920184)
-- Name: bill_status_send_to_jit(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.bill_status_send_to_jit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    jit_ref_bill_status jsonb;
BEGIN
    -- CTE to fetch relevant bill status data
    WITH bill_data AS (
        SELECT 
            status.bill_id, 
            array_agg(imap.jit_ref_no) AS ref_nos, 
            status.status_id, 
            status.created_at
        FROM billing.ebill_jit_int_map imap
        INNER JOIN billing.bill_status_info status ON status.bill_id = imap.bill_id
        WHERE status.bill_id = NEW.bill_id
        AND status.status_id = NEW.status_id
        AND NEW.send_to_jit = false
		GROUP BY status.bill_id, status.status_id, status.created_at
    )
    SELECT json_agg(json_build_object(
        'BillId', bill_data.bill_id,
        'JitRefNos', bill_data.ref_nos,
        'Status', bill_data.status_id,
        'CreatedAt', bill_data.created_at
    )) INTO jit_ref_bill_status FROM bill_data;

    -- Insert data into the queue if valid
    IF jit_ref_bill_status IS NOT NULL THEN
        PERFORM message_queue.insert_message_queue(
            'bill_jit_bill_status', jit_ref_bill_status
        );
		
		-- Update `send_to_jit` column only for matching records in `bill_data`
		UPDATE billing.bill_status_info
		SET send_to_jit = true
		WHERE bill_id = NEW.bill_id
		AND status_id = NEW.status_id
		AND send_to_jit = false;
    END IF;
	
    RETURN NULL;
END;
$$;


ALTER FUNCTION billing.bill_status_send_to_jit() OWNER TO postgres;

--
-- TOC entry 505 (class 1255 OID 920185)
-- Name: cpin_regenerate_bill(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.cpin_regenerate_bill(IN billing_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying)
    LANGUAGE plpgsql
    AS $$
Declare 
    _bill_id bigint;
 	_tmp_ref_no character varying;
    _current_month integer;
    _financial_year_id smallint;
    _financial_year text;
    _form_version smallint;
    _treasury_code character(3);
    _ddo_code character(9);
    _hoa_id bigint;
	_bill_no bigint;
	_application_type character varying;

BEGIN
	_application_type = '01';  ----- FOR JIT BILL ---------

    -- Get Current Financial Year
    SELECT  id,financial_year into _financial_year_id,_financial_year from master.financial_year_master where is_active=true;
	-- Get Treasury Code from DDO Code ??
    SELECT treasury_code, ddo_code into _treasury_code, _ddo_code from master.ddo where ddo_code= (billing_details_payload->>'DdoCode')::character(9);
	
	-- GET Bill Id from sequence     
	EXECUTE format('SELECT nextval(%L)', 'billing.bill_details_bill_id_seq') INTO _bill_id;
	
	-- GET Bill No from sequence     
	EXECUTE format('SELECT nextval(%L)', 'billing.sys_generated_bill_no_seq') INTO _bill_no;

    -- Get Month from Current Date	
    SELECT EXTRACT(MONTH FROM CURRENT_DATE) INTO _current_month;
	
	-- Generate REFERENCENO
	
	IF (billing_details_payload->>'BillId')::bigint IS NOT NULL THEN 
		SELECT form_version,reference_no from billing.bill_details
		where bill_id = (billing_details_payload->>'BillId')::bigint into _form_version, _tmp_ref_no;
		--Need to update version +1 not static 2
		_form_version := _form_version + 1;

		UPDATE billing.bill_details
		SET 
		   is_cpin_regenerated = true
		WHERE bill_id = (billing_details_payload->>'BillId')::bigint;
		
		--MARK MAPPED FTO AS INACTIVE
		UPDATE billing.ebill_jit_int_map set is_active=false where bill_id= (billing_details_payload->>'BillId')::bigint;
	END IF;
	    	
	-- STEP 1. INSERT Common Bill Deatils INTO BillDetails from JSON to Bill Table
		INSERT INTO billing.bill_details(
			bill_id, bill_no, bill_date, bill_mode, reference_no, tr_master_id, payment_mode, 
			financial_year, demand, major_head, sub_major_head, minor_head, plan_status, scheme_head,
			detail_head, voted_charged, gross_amount, net_amount, bt_amount, ag_bt,
			treasury_bt, gst_amount,is_gst, sanction_no, sanction_amt, sanction_date,
			sanction_by, remarks, ddo_code, treasury_code, is_gem, status,
			created_by_userid, form_version,sna_grant_type,css_ben_type, aafs_project_id,
			scheme_code, scheme_name, bill_type, payee_count)
		SELECT _bill_id, (_application_type || 0 || LPAD(_bill_no::text, 8, '0')),
		-- to_date(billing_details_payload->>'BillDate', 'DD-MM-YYYY')
		(billing_details_payload->>'BillDate')::date
		, bill_mode, _tmp_ref_no, tr_master_id,
		payment_mode, _financial_year_id, demand, major_head, sub_major_head, minor_head,
		plan_status, scheme_head, detail_head, voted_charged, gross_amount, net_amount,
		bt_amount, ag_bt, treasury_bt,gst_amount,is_gst,
		sanction_no, sanction_amt, sanction_date, sanction_by,
		(billing_details_payload->>'Remarks')::character varying, _ddo_code, _treasury_code,
		is_gem,(billing_details_payload->>'Status')::smallint,
		(billing_details_payload->>'CreatedByUserid')::bigint,_form_version,
		sna_grant_type, css_ben_type, aafs_project_id, scheme_code, scheme_name, bill_type, payee_count
		FROM  billing.bill_details
		WHERE bill_id = (billing_details_payload->>'BillId')::bigint;
		
	--STEP 2. INSERT SUBDetail into Table  
	INSERT INTO billing.bill_subdetail_info(
		bill_id, active_hoa_id, amount, status, created_by_userid, financial_year,ddo_code, treasury_code)

	SELECT _bill_id, active_hoa_id, amount, (billing_details_payload->>'Status')::smallint,
	(billing_details_payload->>'CreatedByUserid')::bigint,_financial_year_id, _ddo_code, _treasury_code
	FROM billing.bill_subdetail_info
	WHERE bill_id = (billing_details_payload->>'BillId')::bigint;

	------------ Insert Map table data ---------------		
	INSERT INTO billing.ebill_jit_int_map (ebill_ref_no, jit_ref_no, bill_id, financial_year)
	SELECT 
		_tmp_ref_no, 
		ftos_element::text,
		_bill_id, _financial_year_id
	FROM 
		jsonb_array_elements_text(billing_details_payload->'JitRefs') AS ftos_element;
		
	-- Get Bill Reference No and Bill Id 
	_out_ref_no:= _tmp_ref_no || '-' || _form_version;
	inserted_id = _bill_id;
	
	-- --STEP 3. Insert tr_26a details
	INSERT INTO billing.tr_26a_detail(bill_id, bill_mode, tr_master_id, is_scheduled,
	topup_amount, reissue_amount, total_amt_for_cs_calc_sc, total_amt_for_cs_calc_scoc, total_amt_for_cs_calc_sccc, total_amt_for_cs_calc_scsal, total_amt_for_cs_calc_st, 
	total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_stcc, total_amt_for_cs_calc_stsal, 
	total_amt_for_cs_calc_ot, total_amt_for_cs_calc_otoc, total_amt_for_cs_calc_otcc,
	total_amt_for_cs_calc_otsal, hoa_id, voucher_details_object, category_code)
	SELECT _bill_id, bill_mode, tr_master_id, is_scheduled,
			topup_amount, reissue_amount, total_amt_for_cs_calc_sc,
			total_amt_for_cs_calc_scoc, total_amt_for_cs_calc_sccc,
			total_amt_for_cs_calc_scsal, total_amt_for_cs_calc_st,
			total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_stcc, 
			total_amt_for_cs_calc_stsal, total_amt_for_cs_calc_ot, 
			total_amt_for_cs_calc_otoc, total_amt_for_cs_calc_otcc,
			total_amt_for_cs_calc_otsal, hoa_id, voucher_details_object, category_code
	FROM billing.tr_26a_detail
	WHERE bill_id = (billing_details_payload->>'BillId')::bigint;
	
	--UPDATE GST TABLE WITH BILL ID
	UPDATE jit.gst
	set bill_id=_bill_id, is_mapped = false, cpin_id = null,
		old_cpin_id = cpin_id,
		old_bill_id = bill_id
	WHERE bill_id= (billing_details_payload->>'BillId')::bigint;

	 --insert into bill status info table
    INSERT INTO billing.bill_status_info( bill_id, status_id, created_by, created_at)
        VALUES (_bill_id, (billing_details_payload->>'Status')::smallint, -- Status for approver(2) or operator(1)
		   (billing_details_payload->>'CreatedByUserid')::bigint, now()
        );
 END;
$$;


ALTER PROCEDURE billing.cpin_regenerate_bill(IN billing_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying) OWNER TO postgres;

--
-- TOC entry 506 (class 1255 OID 920187)
-- Name: enforce_unique_id(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.enforce_unique_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM billing.tr_detail WHERE id = NEW.id) THEN
    RAISE EXCEPTION 'Duplicate ID value detected';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION billing.enforce_unique_id() OWNER TO postgres;

--
-- TOC entry 476 (class 1255 OID 920188)
-- Name: fetch_cpin_failed_record(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.fetch_cpin_failed_record(IN in_payload jsonb, OUT _out_failed_ben jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_gross_amount_diff numeric;
    v_net_amount_diff numeric;
	v_gst_amount_diff numeric;
	ecs_detail jsonb;
    cpin_detail jsonb;
BEGIN
    -- Fetch aggregate values
	SELECT 
		COALESCE(SUM(CASE WHEN c.is_gst <> true THEN b.gross_amount ELSE c.amount END), 0),
		-- COALESCE(SUM(CASE WHEN c.is_gst <> true THEN b.net_amount ELSE c.amount END), 0),
		COALESCE(SUM(a.gst_amount), 0)
	INTO v_gross_amount_diff, v_gst_amount_diff
	FROM billing.bill_details a
	JOIN billing.bill_ecs_neft_details c ON a.bill_id = c.bill_id
	LEFT JOIN billing.jit_ecs_additional b ON c.id = b.ecs_id
	WHERE c.bank_account_number = ANY (
			SELECT *
			FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
		)
	  AND c.is_gst = true;

    -- Fetch ECS detail
	SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'payeeName', ecs.payee_name,
        'beneficiaryId', ecs.beneficiary_id,
        'panNo', ecs.pan_no,
        'ifscCode', ecs.ifsc_code,
        'bankName', ecs.bank_name,
        'bankAccountNumber', ecs.bank_account_number,
        'netAmount', ecs.amount,
		'endToEndId', failed_ben.end_to_end_id
    )), '[]'::jsonb)
	INTO ecs_detail
	FROM billing.bill_ecs_neft_details ecs
	JOIN cts.failed_transaction_beneficiary failed_ben
	    ON failed_ben.account_no = ecs.bank_account_number
	WHERE failed_ben.account_no = ANY (
			SELECT * 
			FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
		)
	  AND ecs.is_gst = true;

	-- Fetch CPIN + vendor detail
	-- SELECT COALESCE(jsonb_agg(jsonb_build_object(
 --        'vendorName', vendor.vendorname,
 --        'vendorgstin', vendor.vendorgstin,
 --        'invoiceNo', vendor.invoiceno,
 --        'invoiceDate', vendor.invoicedate,
 --        'invoiceValue', vendor.invoicevalue,
 --        'amountPart1', vendor.amountpart1,
 --        'amountPart2', vendor.amountpart2,
 --        'total', vendor.total,
	-- 	'benRefId', ecs.id,
	-- 	'cpinType', cpin.cpin_type
 --    )), '[]'::jsonb)
	-- INTO cpin_detail
	-- FROM billing_master.cpin_master AS cpin
	-- INNER JOIN billing.bill_ecs_neft_details AS ecs 
	--     ON cpin.cpin_id = ecs.bank_account_number
	-- INNER JOIN cts.failed_transaction_beneficiary failed_ben
	--     ON failed_ben.account_no = ecs.bank_account_number
	-- INNER JOIN billing_master.cpin_vender_mst AS vendor
	--     ON cpin.id = vendor.cpinmstid
	-- WHERE failed_ben.account_no = ANY (
	-- 		SELECT * 
	-- 		FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
	-- 	)
	--   AND ecs.is_gst = true
	--   AND cpin.cpin_type = (in_payload->>'CpinType')::smallint;

	-- Fetch CPIN + vendor detail grouped by vendorgstin and invoiceNo
	WITH vendor_aggregated AS (
	    SELECT 
	        vendor.vendorgstin,
	        vendor.invoiceno,
			MIN(ecs.bill_id) AS oldBillId,
			MIN(vendor.cpinmstid) AS cpinId,
			MIN(vendor.ben_ref_id) AS benRefId,
	        MIN(vendor.vendorname) AS vendorname,
	        MIN(vendor.invoicedate) AS invoicedate,
	        SUM(vendor.invoicevalue) AS invoicevalue,
	        SUM(vendor.amountpart1) AS amountpart1,
	        SUM(vendor.amountpart2) AS amountpart2,
	        SUM(vendor.total) AS total,
	        MAX(cpin.cpin_type) AS cpin_type
	    FROM billing_master.cpin_master AS cpin
	    INNER JOIN billing.bill_ecs_neft_details AS ecs 
	        ON cpin.cpin_id = ecs.bank_account_number
	    INNER JOIN cts.failed_transaction_beneficiary failed_ben
	        ON failed_ben.account_no = ecs.bank_account_number
	    INNER JOIN billing_master.cpin_vender_mst AS vendor
	        ON cpin.id = vendor.cpinmstid
	    WHERE failed_ben.account_no = ANY (
	            SELECT * 
	            FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
	        )
	      AND ecs.is_gst = true
	      AND cpin.cpin_type = (in_payload->>'CpinType')::smallint
	    GROUP BY vendor.vendorgstin, vendor.invoiceno
	)
	
	-- Now build the JSON
	SELECT COALESCE(jsonb_agg(jsonb_build_object(
		'cpinMstId', va.cpinId,
		'oldBillId', va.oldBillId,
	    'vendorgstin', va.vendorgstin,
		'benRefId', va.benRefId,
	    'invoiceNo', va.invoiceno,
	    'vendorName', va.vendorname,
	    'invoiceDate', va.invoicedate,
	    'invoiceValue', va.invoicevalue,
	    'amountPart1', va.amountpart1,
	    'amountPart2', va.amountpart2,
	    'total', va.total,
	    'cpinType', va.cpin_type
	)), '[]'::jsonb)
	INTO cpin_detail
	FROM vendor_aggregated va;

    -- Final output
    _out_failed_ben := jsonb_build_object(
        'grossAmount', COALESCE(v_gross_amount_diff, 0),
        'netAmount', COALESCE((v_gross_amount_diff - v_gst_amount_diff), 0),
        'gstAmount', COALESCE(v_gst_amount_diff, 0),
        'ecsDetail', ecs_detail,
        'vendorDetails', cpin_detail
    );
END;
$$;


ALTER PROCEDURE billing.fetch_cpin_failed_record(IN in_payload jsonb, OUT _out_failed_ben jsonb) OWNER TO postgres;

--
-- TOC entry 477 (class 1255 OID 920189)
-- Name: fetch_cpin_failed_record_bk(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.fetch_cpin_failed_record_bk(IN in_payload jsonb, OUT _out_failed_ben jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_gross_amount_diff numeric;
    v_net_amount_diff numeric;
	v_gst_amount_diff numeric;
	ecs_detail jsonb;
    cpin_detail jsonb;
BEGIN
    -- Fetch aggregate values
	SELECT 
		COALESCE(SUM(CASE WHEN c.is_gst <> true THEN b.gross_amount ELSE c.amount END), 0),
		COALESCE(SUM(CASE WHEN c.is_gst <> true THEN b.net_amount ELSE c.amount END), 0),
		COALESCE(SUM(a.gst_amount), 0)
	INTO v_gross_amount_diff, v_net_amount_diff, v_gst_amount_diff
	FROM billing.bill_details a
	JOIN billing.bill_ecs_neft_details c ON a.bill_id = c.bill_id
	LEFT JOIN billing.jit_ecs_additional b ON c.id = b.ecs_id
	WHERE c.bank_account_number = ANY (
			SELECT *
			FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
		)
	  AND c.is_gst = true;

    -- Fetch ECS detail
	SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'payeeName', ecs.payee_name,
        'beneficiaryId', ecs.beneficiary_id,
        'panNo', ecs.pan_no,
        'ifscCode', ecs.ifsc_code,
        'bankName', ecs.bank_name,
        'bankAccountNumber', ecs.bank_account_number,
        'netAmount', ecs.amount,
		'endToEndId', failed_ben.end_to_end_id
    )), '[]'::jsonb)
	INTO ecs_detail
	FROM billing.bill_ecs_neft_details ecs
	JOIN cts.failed_transaction_beneficiary failed_ben
	    ON failed_ben.account_no = ecs.bank_account_number
	WHERE failed_ben.account_no = ANY (
			SELECT * 
			FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
		)
	  AND ecs.is_gst = true;

	-- Fetch CPIN + vendor detail
	SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'vendorName', vendor.vendorname,
        'vendorgstin', vendor.vendorgstin,
        'invoiceNo', vendor.invoiceno,
        'invoiceDate', vendor.invoicedate,
        'invoiceValue', vendor.invoicevalue,
        'amountPart1', vendor.amountpart1,
        'amountPart2', vendor.amountpart2,
        'total', vendor.total,
		'benRefId', ecs.id,
		'cpinType', cpin.cpin_type
    )), '[]'::jsonb)
	INTO cpin_detail
	FROM billing_master.cpin_master AS cpin
	INNER JOIN billing.bill_ecs_neft_details AS ecs 
	    ON cpin.cpin_id = ecs.bank_account_number
	INNER JOIN cts.failed_transaction_beneficiary failed_ben
	    ON failed_ben.account_no = ecs.bank_account_number
	INNER JOIN billing_master.cpin_vender_mst AS vendor
	    ON cpin.id = vendor.cpinmstid
	WHERE failed_ben.account_no = ANY (
			SELECT * 
			FROM jsonb_array_elements_text(in_payload->'OldCpinIds')
		)
	  AND ecs.is_gst = true
	  AND cpin.cpin_type = (in_payload->>'CpinType')::smallint;

    -- Final output
    _out_failed_ben := jsonb_build_object(
        'grossAmount', COALESCE(v_gross_amount_diff, 0),
        'netAmount', COALESCE((v_gross_amount_diff - v_gst_amount_diff), 0),
        'gstAmount', COALESCE(v_gst_amount_diff, 0),
        'ecsDetail', ecs_detail,
        'vendorDetails', cpin_detail
    );
END;
$$;


ALTER PROCEDURE billing.fetch_cpin_failed_record_bk(IN in_payload jsonb, OUT _out_failed_ben jsonb) OWNER TO postgres;

--
-- TOC entry 502 (class 1255 OID 920190)
-- Name: fetch_cpin_failed_record_by_billids(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.fetch_cpin_failed_record_by_billids(IN in_payload jsonb, OUT _out_failed_ben jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_gross_amount_diff numeric;
    v_net_amount_diff numeric;
	v_gst_amount_diff numeric;
	ecs_detail jsonb;
    cpin_detail jsonb;
	end_to_end_id character varying;
BEGIN
    --- Query to get GrossAmount and NetAmount differences
	
	SELECT 
		SUM(CASE WHEN(c.is_gst <> true) then b.gross_amount else c.amount END ) AS gross_amount ,
		SUM(CASE WHEN(c.is_gst <> true) then b.net_amount else c.amount END ) AS net_amount,
		SUM(a.gst_amount) AS gst_amount
		
	INTO v_gross_amount_diff, v_net_amount_diff, v_gst_amount_diff
	FROM billing.bill_details a
	JOIN billing.bill_ecs_neft_details c
		ON a.bill_id = c.bill_id
	LEFT JOIN billing.jit_ecs_additional b
		ON c.id = b.ecs_id
	WHERE a.bill_id = ANY (SELECT value::bigint FROM 
            jsonb_array_elements(in_payload->'BillIds')) and c.is_gst = true;
	
    --- Query to get Ecs Details
	
	SELECT 
        jsonb_agg(jsonb_build_object(
            'payeeName', ecs.payee_name,
            'beneficiaryId', ecs.beneficiary_id,
            'panNo', ecs.pan_no,
            'ifscCode', ecs.ifsc_code,
            'bankName', ecs.bank_name,
            'bankAccountNumber', ecs.bank_account_number,
            'netAmount', ecs.amount,
			'endToEndId', failed_ben.end_to_end_id
        )) AS ecs_details
    INTO ecs_detail
    FROM billing.bill_ecs_neft_details ecs
	JOIN 
		cts.failed_transaction_beneficiary failed_ben
    ON failed_ben.account_no = ecs.bank_account_number
    WHERE ecs.bill_id = ANY (SELECT value::bigint FROM 
            jsonb_array_elements(in_payload->'BillIds'))
      AND ecs.is_gst = true;
	  
	  	SELECT jsonb_agg(
           jsonb_build_object(
               'vendorName', vendor.vendorname,
               'vendorgstin', vendor.vendorgstin,
               'invoiceNo', vendor.invoiceno,
               'invoiceDate', vendor.invoicedate,
               'invoiceValue', vendor.invoicevalue,
               'amountPart1', vendor.amountpart1,
               'amountPart2', vendor.amountpart2,
               'total', vendor.total,
			   'benRefId', ecs.id,
			   'cpinType', cpin.cpin_type
           )
       ) AS vendor_details
		INTO cpin_detail
		FROM billing_master.cpin_master AS cpin
		INNER JOIN billing.bill_ecs_neft_details AS ecs 
		    ON cpin.cpin_id = ecs.bank_account_number
		JOIN cts.failed_transaction_beneficiary failed_ben
		    ON failed_ben.account_no = ecs.bank_account_number
		INNER JOIN billing_master.cpin_vender_mst AS vendor
		    ON cpin.id = vendor.cpinmstid
		WHERE ecs.bill_id = ANY (
		          SELECT value::bigint 
		          FROM jsonb_array_elements(in_payload->'BillIds')
		      )
		  AND ecs.is_gst = true
		  AND cpin.cpin_type = (in_payload->>'CpinType')::smallint;
	
    -- Construct the JSONB output
    _out_failed_ben := jsonb_build_object(
        'grossAmount', v_gross_amount_diff,
        'netAmount', v_net_amount_diff,
		'gstAmount', v_gst_amount_diff,
		'ecsDetail', ecs_detail,
		'vendorDetails', cpin_detail
    );
END;
$$;


ALTER PROCEDURE billing.fetch_cpin_failed_record_by_billids(IN in_payload jsonb, OUT _out_failed_ben jsonb) OWNER TO postgres;

--
-- TOC entry 414 (class 1255 OID 920191)
-- Name: fetch_failed_ben_record_old(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.fetch_failed_ben_record_old(IN in_payload jsonb, OUT _out_failed_ben jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_gross_amount_diff numeric;
    v_net_amount_diff numeric;
	ecs_detail jsonb;
    cpin_detail jsonb;
	end_to_end_id character varying;
BEGIN
    --- Query to get GrossAmount and NetAmount differences
	
	SELECT 
		SUM(CASE WHEN(c.is_gst <> true) then b.gross_amount else c.amount END ) AS gross_amount ,
		SUM(CASE WHEN(c.is_gst <> true) then b.net_amount else c.amount END ) AS net_amount
		
	INTO v_gross_amount_diff, v_net_amount_diff
	FROM billing.bill_details a
	JOIN billing.bill_ecs_neft_details c
		ON a.bill_id = c.bill_id
	LEFT JOIN billing.jit_ecs_additional b
		ON c.id = b.ecs_id
	WHERE a.bill_id = (in_payload->>'BillId')::bigint and c.is_gst = true;
	
    --- Query to get Ecs Details
	
	SELECT 
        jsonb_agg(jsonb_build_object(
            'payeeName', ecs.payee_name,
            'beneficiaryId', ecs.beneficiary_id,
            'panNo', ecs.pan_no,
            'ifscCode', ecs.ifsc_code,
            'bankName', ecs.bank_name,
            'bankAccountNumber', ecs.bank_account_number,
            'netAmount', ecs.amount,
			'endToEndId', failed_ben.end_to_end_id
        )) AS ecs_details
    INTO ecs_detail
    FROM billing.bill_ecs_neft_details ecs
	JOIN 
		cts.failed_transaction_beneficiary failed_ben
    ON failed_ben.account_no = ecs.bank_account_number
    WHERE ecs.bill_id = (in_payload->>'BillId')::bigint
      AND ecs.is_gst = true;
	  
	  	SELECT jsonb_agg(
           jsonb_build_object(
               'cpinDate', cpin.cpin_date,
               'cpinAmount', cpin.cpin_amount,
               'accNo', cpin.cpin_id,
               'vendorDetails', cpin_vendor.vendor_details
           )
       ) AS cpin_vendor_details
		INTO cpin_detail
		FROM billing_master.cpin_master AS cpin
		INNER JOIN billing.bill_ecs_neft_details AS ecs 
			ON cpin.cpin_id = ecs.bank_account_number
		JOIN cts.failed_transaction_beneficiary failed_ben
    		ON failed_ben.account_no = ecs.bank_account_number
		INNER JOIN (
			SELECT cpinmstid,
				   jsonb_agg(
					   jsonb_build_object(
						   'vendorName', vendor.vendorname,
						   'vendorgstin', vendor.vendorgstin,
						   'invoiceNo', vendor.invoiceno,
						   'invoiceDate', vendor.invoicedate,
						   'invoiceValue', vendor.invoicevalue,
						   'amountPart1', vendor.amountpart1,
						   'amountPart2', vendor.amountpart2,
						   'total', vendor.total
					   )
				   ) AS vendor_details
			FROM billing_master.cpin_vender_mst AS vendor
			GROUP BY cpinmstid
		) AS cpin_vendor
		ON cpin.id = cpin_vendor.cpinmstid
		WHERE ecs.bill_id = (in_payload->>'BillId')::bigint
		  AND ecs.is_gst = true;

	  
-- 	  SELECT 
-- 	  jsonb_agg(jsonb_build_object(
-- 		'vendorName', vendor.vendorname,
-- 		'vendorgstin', vendor.vendorgstin,
-- 		'invoiceNo', vendor.invoiceno,
-- 		'invoiceDate', vendor.invoicedate,
-- 		'invoiceValue', vendor.invoicevalue,
-- 		'amountPart1', vendor.amountpart1,
-- 		'amountPart2', vendor.amountpart2,
-- 		'total', vendor.total,
-- 		'cpinDate', cpin.cpin_date,
-- 		'cpinAmount', cpin.cpin_amount,
-- 		'accNo', cpin.cpin_id
--         )) AS cpin_details
--     INTO cpin_detail
-- 	FROM billing_master.cpin_vender_mst vendor
-- 	JOIN 
-- 		billing_master.cpin_master cpin
-- 		ON vendor.cpinmstid = cpin.id
-- 	JOIN 
-- 		cts.failed_transaction_beneficiary failed_ben
--     ON failed_ben.account_no = cpin.cpin_id
-- 	JOIN 
-- 		billing.bill_ecs_neft_details ecs
--     ON cpin.cpin_id = ecs.bank_account_number
-- 	WHERE ecs.bill_id = (in_payload->>'BillId')::bigint
--       AND ecs.is_gst = true;
	
    -- Construct the JSONB output
    _out_failed_ben := jsonb_build_object(
        'grossAmount', v_gross_amount_diff,
        'netAmount', v_net_amount_diff,
		'ecsDetail', ecs_detail,
		'cpinDetail', cpin_detail
-- 		'endToEndId', end_to_end_id
    );
END;
$$;


ALTER PROCEDURE billing.fetch_failed_ben_record_old(IN in_payload jsonb, OUT _out_failed_ben jsonb) OWNER TO postgres;

--
-- TOC entry 488 (class 1255 OID 920192)
-- Name: forward_treasury_jit_bill(bigint, bigint, smallint); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.forward_treasury_jit_bill(IN _bill_id bigint, IN _forwarded_by_userid bigint, IN _forwarded_status smallint)
    LANGUAGE plpgsql
    AS $$
Declare 
	bill_payload jsonb;
BEGIN
	update billing.bill_details set status = _forwarded_status, updated_by_userid=_forwarded_by_userid, updated_at=now() where bill_id=_bill_id;
	
	INSERT INTO billing.bill_status_info(bill_id, status_id, created_at, created_by) VALUES(_bill_id, _forwarded_status, now(),_forwarded_by_userid);

	SELECT billing.get_bill_payload(_bill_id) into bill_payload;


	PERFORM message_queue.insert_message_queue(
		'bill_to_treasury', bill_payload
	);
	
END;
$$;


ALTER PROCEDURE billing.forward_treasury_jit_bill(IN _bill_id bigint, IN _forwarded_by_userid bigint, IN _forwarded_status smallint) OWNER TO postgres;

--
-- TOC entry 475 (class 1255 OID 920193)
-- Name: get_bill_details_report(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_bill_details_report(IN in_payload jsonb, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN
WITH bill_info AS (
    SELECT 
        bd.bill_id,
        bd.bill_no,
		bd.bill_date,
        CONCAT(TRIM(bd.reference_no), '-', bd.form_version) AS bill_reference_no,
        bd.scheme_code,
        bd.scheme_name,
        (bd.net_amount + bd.gst_amount) AS bill_net,
        bd.demand,
        bd.ddo_code,
        bd.treasury_code,
        billsub.active_hoa_id,
        CONCAT(hoa.demand_no, '-', hoa.major_head, '-',
               hoa.submajor_head, '-', hoa.minor_head, '-', hoa.scheme_head, '-', hoa.detail_head,
               '-', hoa.subdetail_head, '-', hoa.voted_charged) AS hoa,
        COUNT(bend.id) AS actual_ben,
		hoa.description as description
    FROM billing.bill_details bd
    JOIN billing.bill_ecs_neft_details bend 
        ON bend.bill_id = bd.bill_id
    LEFT JOIN billing.bill_subdetail_info AS billsub
        ON billsub.bill_id = bd.bill_id
    LEFT JOIN billing_master.bill_status_master bsm 
        ON bsm.status_id = bd.status
    LEFT JOIN master.active_hoa_mst hoa
        ON hoa.id = billsub.active_hoa_id
		WHERE bd.ddo_code = (in_payload->>'DdoCode')
		AND (
            (in_payload->>'FromBillDate')::DATE IS NULL 
            OR (in_payload->>'ToBillDate')::DATE IS NULL 
            OR bd.bill_date BETWEEN (in_payload->>'FromBillDate')::DATE 
            AND (in_payload->>'ToBillDate')::DATE
        )
        AND (
			(in_payload->>'Department')::character varying IS NULL
			OR
			bd.demand = (in_payload->>'Department')::character varying
		)
	  GROUP BY 
        bd.bill_id,
        bd.bill_no,
		bd.bill_date,
        bd.reference_no,
        bd.form_version,
        bd.scheme_code,
        bd.scheme_name,
        bd.net_amount,
        bd.gst_amount,
        bd.ddo_code,
        bd.treasury_code,
		bd.demand,
        billsub.active_hoa_id,
        hoa.demand_no, hoa.major_head,
        hoa.submajor_head, hoa.minor_head, hoa.scheme_head, hoa.detail_head,
        hoa.subdetail_head, hoa.voted_charged, hoa.description
),
success_ben AS (
    SELECT 
        ecs.bill_id,
        SUM(sben.amount) AS total_paid,
        COUNT(sben.id) AS success_count
    FROM billing.bill_ecs_neft_details ecs
    LEFT JOIN cts.success_transaction_beneficiary sben 
        ON ecs.id = sben.ecs_id
    GROUP BY ecs.bill_id
),
failed_ben AS (
    SELECT 
        f.bill_id AS bill_id,
        COUNT(f.id) AS failed_count,
        SUM(f.failed_transaction_amount) AS failed_amount
    FROM cts.failed_transaction_beneficiary f
    GROUP BY f.bill_id
),
final_data AS (
    SELECT 
        bi.bill_id,
		bi.bill_date,
        bi.hoa AS HOA,
		bi.description AS description,
        CONCAT(tre.code, '-', tre.treasury_name) AS treasury_name,
        ddo.designation AS ddo_name,
        ddo.ddo_code AS ddo_code,
        dept.name AS "Department",
        bi.bill_no AS bill_no,
        bi.bill_reference_no AS reference_no,
        bi.scheme_code AS scheme_code,
        bi.scheme_name AS scheme_name,
        COALESCE(bi.actual_ben, 0) AS "Total Beneficiary Count",
        bi.bill_net AS "Total Amount",
        COALESCE(sb.success_count, 0) AS "Payment Success Count",
        COALESCE(sb.total_paid, 0) AS "Amount Paid",
        COALESCE(fb.failed_count, 0) AS "Failed Count",
        COALESCE(fb.failed_amount, 0) AS "Failed Amount"
    FROM bill_info bi
    LEFT JOIN success_ben sb 
        ON bi.bill_id = sb.bill_id
    LEFT JOIN failed_ben fb 
        ON bi.bill_id = fb.bill_id
    LEFT JOIN master.department dept
        ON dept.demand_code = bi.demand 
    LEFT JOIN master.ddo ddo
        ON ddo.ddo_code = bi.ddo_code
    LEFT JOIN master.treasury tre
        ON tre.code = bi.treasury_code
    ORDER BY bi.bill_id
)
SELECT json_agg(
    json_build_object(
        'BillId', bill_id,
		'BillDate', bill_date,
        'HOA', HOA,
		'Description', description,
        'TreasuryName', treasury_name,
        'DdoName', ddo_name,
        'DdoCode', ddo_code,
        'Department', "Department",
        'BillNo', trim(bill_no),
        'ReferenceNo', reference_no,
        'SchemeCode', scheme_code,
        'SchemeName', scheme_name,
        'TotalBeneficiaryCount', "Total Beneficiary Count",
        'TotalAmount', "Total Amount",
        'PaymentSuccessCount', "Payment Success Count",
        'AmountPaid', "Amount Paid",
        'FailedCount', "Failed Count",
        'FailedAmount', "Failed Amount"
    )
) INTO out_payload
FROM final_data;
END;
$$;


ALTER PROCEDURE billing.get_bill_details_report(IN in_payload jsonb, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 468 (class 1255 OID 920194)
-- Name: get_bill_payload(bigint); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.get_bill_payload(p_bill_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_bill_payload JSON;
BEGIN
	SELECT 
	jsonb_build_object(
		'BillId', t.bill_id,
		'BillNo', trim(bill_no),
		'BillDate', bill_date,
		'BillMode', COALESCE(bill_mode, 0),
		'ReferenceNo', trim(reference_no),
		'FormVersion', form_version,
		'FormRevisionNo', form_revision_no,
		'TrMasterId', tr_master_id,
		'PaymentMode', payment_mode,
		'FinancialYear', financial_year,
		'Demand', demand,
		'MajorHead', major_head,
		'SubMajorHead', sub_major_head,
		'MinorHead', minor_head,
		'PlanStatus', plan_status,
		'SchemeHead', scheme_head,
		'DetailHead', detail_head,
		'VotedCharged', voted_charged,
		'GrossAmount', gross_amount,
		'NetAmount', net_amount,
		'BtAmount', bt_amount,
		'TreasuryBt', treasury_bt,
		'AgBt', ag_bt
	)||	
	jsonb_build_object(
		'SanctionNo', sanction_no,
		'SanctionAmt', sanction_amt,
		'SanctionDate', sanction_date,
		'SanctionBy', sanction_by,
		'Remarks', remarks,
		'DdoCode', ddo_code,
		'TreasuryCode', treasury_code,
		'IsGem', is_gem,
		'Status', status,
		'CreatedByUserid', created_by_userid,
		'CreatedAt', created_at,
		'SnaGrantType', sna_grant_type,
		'CssBenType', css_ben_type,
		'AafsProjectId', aafs_project_id,
		'SchemeCode', trim(scheme_code),
		'SchemeName', trim(scheme_name),
		'BillType', bill_type,
		'IsGst', is_gst,
		'GstAmount', gst_amount,
		'JitBillBtdetails', COALESCE(b1.json_agg,'[]'),
		'JitBillEcsNeftDetails', b2.json_agg,
		'JitBillSubdetailInfos', b3.json_agg,
		'JitDdoAllotmentBookedBills', COALESCE(j4.json_agg,'[]'),
		'JitTr26aDetails', COALESCE(t0.json_agg,'[]'),
		'JitTr10Details', COALESCE(t1.json_agg,'[]'),
		'JitTr12Details', COALESCE(j2.json_agg,'[]'),
		'JitEcsAdditionals', COALESCE(j.json_agg,'[]'),
		'BillJitComponents', b4.json_agg,
		'JitCpinDetails', COALESCE(j1.json_agg,'[]')
    ) AS bill_payload into v_bill_payload
	  FROM (
          SELECT b.bill_id, b.aafs_project_id, b.ag_bt, b.bill_components, b.bill_date, b.bill_mode, b.bill_no, 
		  b.bill_type, b.bt_amount, b.created_at, b.created_by_userid, b.css_ben_type, b.ddo_code, b.demand, 
		  b.detail_head, b.financial_year, b.form_revision_no, b.form_version, b.gross_amount, 
		  b.gst_amount, b.is_cancelled, b.is_deleted, b.is_extended_part_filled, b.is_gem, b.is_gst,
		  b.major_head, b.minor_head, b.net_amount, b.payment_mode, b.plan_status, b.reference_no, 
		  b.remarks, b.sanction_amt, b.sanction_by, b.sanction_date, b.sanction_no, b.scheme_code, 
		  b.scheme_head, b.scheme_name, b.sna_grant_type, b.status, b.sub_major_head, b.tr_master_id, 
		  b.treasury_bt, b.treasury_code, b.updated_at, b.updated_by_userid, b.voted_charged
          FROM billing.bill_details AS b
          WHERE b.bill_id = p_bill_id
          LIMIT 1
      ) AS t
	  LEFT JOIN
      (select bill_id,json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BtSerial', bt_serial,
								'BtType', bt_type,
								'DDoCode', ddo_code,
								'TreasuryCode', treasury_code,
								'Amount', amount,
								'FinancialYear', financial_year,
								'CreatedBy', created_by,
								'CreatedAt', created_at
	  					)) from billing.bill_btdetail group by bill_id having bill_id=p_bill_id) AS b1 ON b1.bill_id= t.bill_id
	  LEFT JOIN 					  
      (select bill_id, json_agg(json_build_object(
                                'Id', id,
							  	'BillId', bill_id,
								'PayeeName', payee_name,
								'BeneficiaryId', beneficiary_id,
								'PayeeType', beneficiary_type,
								'PanNo', trim(pan_no),
								'ContactNumber', contact_number,
								'BeneficiaryType', payee_type,
								'Address', address,
								'Email', email,
								'IfscCode', ifsc_code,
								'AccountType', account_type,
								'BankAccountNumber', trim(bank_account_number),
								'BankName', trim(bank_name),
								'Amount', amount,
                                'Status', status,
                                'IsActive', is_active,
                                'CreatedByUserid', created_by_userid,
                                'CreatedAt', created_at,
								'EPradanId', e_pradan_id,
								'FinancialYear', financial_year,
								'IsGst', is_gst
	  					))from billing.bill_ecs_neft_details  group by bill_id having bill_id=p_bill_id) AS b2 ON b2.bill_id= t.bill_id
      LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id',id,
								'BillId',bill_id,
								'ActiveHoaId',active_hoa_id,
								'Amount',amount,
                                'Status',status,
                                'CreatedByUserid',created_by_userid,
                                'CreatedAt',created_at,   
								'FinancialYear',financial_year,
								'DdoCode',ddo_code,
								'TreasuryCode',treasury_code
	  					)) from billing.bill_subdetail_info group by bill_id having bill_id=p_bill_id) AS b3 ON b3.bill_id= t.bill_id
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id', id,
					            'EcsId', ecs_id,
					            'BillId', bill_id,
					            'BeneficiaryId', beneficiary_id,
					            'Aadhar', aadhar,
					            'GrossAmount', gross_amount,
					            'NetAmount', net_amount,
					            'ReissueAmount', reissue_amount,
					            'TopUp', top_up,
					            'EndToEndId', end_to_end_id,
					            'AgencyCode', trim(agency_code),
					            'AgencyName', trim(agency_name),
					            'Districtcodelgd', districtcodelgd,
					            'JitReferenceNo', jit_reference_no,
								'FinancialYear', financial_year,
								'UrbanRuralFlag', urban_rural_flag,
								'StateCodeLgd', state_code_lgd,
								'BlockLgd', block_lgd,
								'PanchayatLgd', panchayat_lgd,
								'VillageLgd', village_lgd,
								'TehsilLgd', tehsil_lgd,
								'WardLgd', ward_lgd,
								'TownLgd', town_lgd)) from billing.jit_ecs_additional group by bill_id having bill_id=p_bill_id ) AS j  ON j.bill_id= t.bill_id 
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id',id,
								'BillId',bill_id,
								'BillMode',bill_mode,
								'TrMasterId',tr_master_id,
                                'CreatedByUserid',created_by_userid,
                                'CreatedAt',created_at,
                                'IsScheduled',is_scheduled,
								'VoucherDetailsObject',voucher_details_object::JSONB ::TEXT,
								'PlDetailObject',pl_detail_object,
                                'IsTopup',(topup_amount>0)::boolean, 
								'ReissueAmount',reissue_amount,
								'TopupAmount',topup_amount,
								'TotalAmtForCsCalcSc',total_amt_for_cs_calc_sc,
								'TotalAmtForCsCalcScoc',total_amt_for_cs_calc_scoc,
								'TotalAmtForCsCalcSccc',total_amt_for_cs_calc_sccc,
								'TotalAmtForCsCalcScsal',total_amt_for_cs_calc_scsal,
								'TotalAmtForCsCalcSt',total_amt_for_cs_calc_st,
								'TotalAmtForCsCalcStoc',total_amt_for_cs_calc_stoc,
								'TotalAmtForCsCalcStcc',total_amt_for_cs_calc_stcc,
								'TotalAmtForCsCalcStsal',total_amt_for_cs_calc_stsal,
								'TotalAmtForCsCalcOt',total_amt_for_cs_calc_ot,
								'TotalAmtForCsCalcOtoc',total_amt_for_cs_calc_otoc,
								'TotalAmtForCsCalcOtcc',total_amt_for_cs_calc_otcc,
								'TotalAmtForCsCalcOtsal',total_amt_for_cs_calc_otsal,
								'HoaId',hoa_id,
								'CategoryCode',category_code)) from billing.tr_26a_detail group by bill_id having bill_id=p_bill_id) AS t0  ON t0.bill_id= t.bill_id
      LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BillMode', bill_mode,
								'TrMasterId', tr_master_id,
								'IsScheduled', is_scheduled,
								'Status', status,
								'IsDeleted', is_deleted,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'EmployeeDetailsObject', employee_details_object::JSONB::text
	  							)) from billing.tr_10_detail group by bill_id having bill_id=p_bill_id) AS t1  ON t1.bill_id= t.bill_id
	  LEFT JOIN      
	  (select bill_id, json_agg(json_build_object(
							    'BillId', bill_id,
							    'PayeeId', payee_id,
							    'Componentcode', trim(componentcode),
							    'Componentname', trim(componentname),
							    'Amount', amount,
							    'Slscode', slscode,
								'FinancialYear', financial_year)) from billing.bill_jit_components group by bill_id having bill_id=p_bill_id) AS b4  ON b4.bill_id= t.bill_id
      LEFT JOIN
      (select 
	  g.bill_id, json_agg(json_build_object(
                                'BillId',  g.bill_id,
                                'CpinNo', trim(c.cpin_id),
                                'Amount', c.cpin_amount,
                                'CpinDate', c.cpin_date,
								'FinancialYear', c.financial_year
      ))FROM (select * from billing.bill_gst where bill_id=p_bill_id and is_deleted=false) g, billing_master.cpin_master c
where g.cpin_id=c.id and is_active=true group by g.bill_Id) AS j1  ON j1.bill_id= t.bill_id      
	
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BillMode', bill_mode,
								'TrMasterId', tr_master_id,
								'IsScheduled', is_scheduled,
								'Status', status,
								'IsDeleted', is_deleted,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'EmployeeDetailsObject', employee_details_object::JSONB::text
	  							)) from billing.tr_12_detail group by bill_id having bill_id=p_bill_id) AS j2  ON j2.bill_id= t.bill_id		
		LEFT JOIN
		(select bill_id, json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'AllotmentId', allotment_id,
								'Amount', amount,
								'DdoUserId', ddo_user_id,
								'DdoCode', ddo_code,
								'TreasuryCode', treasury_code,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'FinancialYear', financial_year,
								'ActiveHoaId', active_hoa_id
		))from billing.ddo_allotment_booked_bill group by bill_id having bill_id=p_bill_id) AS j4  ON j4.bill_id= t.bill_id;	
						

		RETURN v_bill_payload;
END;
$$;


ALTER FUNCTION billing.get_bill_payload(p_bill_id bigint) OWNER TO postgres;

--
-- TOC entry 499 (class 1255 OID 920196)
-- Name: get_bill_payload_last_working(bigint); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.get_bill_payload_last_working(p_bill_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_bill_payload JSON;
BEGIN
	SELECT 
	jsonb_build_object(
		'BillId', t.bill_id,
		'BillNo', trim(bill_no),
		'BillDate', bill_date,
		'BillMode', COALESCE(bill_mode, 0),
		'ReferenceNo', trim(reference_no),
		'FormVersion', form_version,
		'FormRevisionNo', form_revision_no,
		'TrMasterId', tr_master_id,
		'PaymentMode', payment_mode,
		'FinancialYear', financial_year,
		'Demand', demand,
		'MajorHead', major_head,
		'SubMajorHead', sub_major_head,
		'MinorHead', minor_head,
		'PlanStatus', plan_status,
		'SchemeHead', scheme_head,
		'DetailHead', detail_head,
		'VotedCharged', voted_charged,
		'GrossAmount', gross_amount,
		'NetAmount', net_amount,
		'BtAmount', bt_amount,
		'TreasuryBt', treasury_bt,
		'AgBt', ag_bt
	)||	
	jsonb_build_object(
		'SanctionNo', sanction_no,
		'SanctionAmt', sanction_amt,
		'SanctionDate', sanction_date,
		'SanctionBy', sanction_by,
		'Remarks', remarks,
		'DdoCode', ddo_code,
		'TreasuryCode', treasury_code,
		'IsGem', is_gem,
		'Status', status,
		'CreatedByUserid', created_by_userid,
		'CreatedAt', created_at,
		'SnaGrantType', sna_grant_type,
		'CssBenType', css_ben_type,
		'AafsProjectId', aafs_project_id,
		'SchemeCode', trim(scheme_code),
		'SchemeName', trim(scheme_name),
		'BillType', bill_type,
		'IsGst', is_gst,
		'GstAmount', gst_amount,
		'BillBtdetails', COALESCE(b1.json_agg,'[]'),
		'BillEcsNeftDetails', b2.json_agg,
		'BillChequeDetails', COALESCE(j3.json_agg,'[]'),
		'BillSubdetailInfos', b3.json_agg,
		'DdoAllotmentBookedBills', COALESCE(j4.json_agg,'[]'),
		'Tr26aDetails', COALESCE(t0.json_agg,'[]'),
		'Tr10Details', COALESCE(t1.json_build_object,'[]'),
		'Tr12Details', COALESCE(j2.json_build_object,'[]'),
		'JitEcsAdditionals', COALESCE(j.json_agg,'[]'),
		'BillJitComponents', b4.json_agg,
		'CpinDetails', COALESCE(j1.json_agg,'[]')
    ) AS bill_payload into v_bill_payload
	  FROM (
          SELECT b.bill_id, b.aafs_project_id, b.ag_bt, b.bill_components, b.bill_date, b.bill_mode, b.bill_no, 
		  b.bill_type, b.bt_amount, b.created_at, b.created_by_userid, b.css_ben_type, b.ddo_code, b.demand, 
		  b.detail_head, b.financial_year, b.form_revision_no, b.form_version, b.gross_amount, 
		  b.gst_amount, b.is_cancelled, b.is_deleted, b.is_extended_part_filled, b.is_gem, b.is_gst,
		  b.major_head, b.minor_head, b.net_amount, b.payment_mode, b.plan_status, b.reference_no, 
		  b.remarks, b.sanction_amt, b.sanction_by, b.sanction_date, b.sanction_no, b.scheme_code, 
		  b.scheme_head, b.scheme_name, b.sna_grant_type, b.status, b.sub_major_head, b.tr_master_id, 
		  b.treasury_bt, b.treasury_code, b.updated_at, b.updated_by_userid, b.voted_charged
          FROM billing.bill_details AS b
          WHERE b.bill_id = p_bill_id
          LIMIT 1
      ) AS t
	  LEFT JOIN
      (select bill_id,json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BtSerial', bt_serial,
								'BtType', bt_type,
								'DDoCode', ddo_code,
								'TreasuryCode', treasury_code,
								'Amount', amount,
								'FinancialYear', financial_year,
								'CreatedBy', created_by,
								'CreatedAt', created_at
	  					)) from billing.bill_btdetail group by bill_id having bill_id=p_bill_id) AS b1 ON b1.bill_id= t.bill_id
	  LEFT JOIN 					  
      (select bill_id, json_agg(json_build_object(
                                'Id', id,
							  	'BillId', bill_id,
								'PayeeName', payee_name,
								'BeneficiaryId', beneficiary_id,
								'PayeeType', beneficiary_type,
								'PanNo', trim(pan_no),
								'ContactNumber', contact_number,
								'BeneficiaryType', payee_type,
								'Address', address,
								'Email', email,
								'IfscCode', ifsc_code,
								'AccountType', account_type,
								'BankAccountNumber', trim(bank_account_number),
								'BankName', trim(bank_name),
								'Amount', amount,
                                'Status', status,
                                'IsActive', is_active,
                                'CreatedByUserid', created_by_userid,
                                'CreatedAt', created_at,
								'EPradanId', e_pradan_id,
								'FinancialYear', financial_year,
								'IsGst', is_gst
	  					))from billing.bill_ecs_neft_details  group by bill_id having bill_id=p_bill_id) AS b2 ON b2.bill_id= t.bill_id
      LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id',id,
								'BillId',bill_id,
								'ActiveHoaId',active_hoa_id,
								'Amount',amount,
                                'Status',status,
                                'CreatedByUserid',created_by_userid,
                                'CreatedAt',created_at,   
								'FinancialYear',financial_year,
								'DdoCode',ddo_code,
								'TreasuryCode',treasury_code
	  					)) from billing.bill_subdetail_info group by bill_id having bill_id=p_bill_id) AS b3 ON b3.bill_id= t.bill_id
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id', id,
					            'EcsId', ecs_id,
					            'BillId', bill_id,
					            'BeneficiaryId', beneficiary_id,
					            'Aadhar', aadhar,
					            'GrossAmount', gross_amount,
					            'NetAmount', net_amount,
					            'ReissueAmount', reissue_amount,
					            'TopUp', top_up,
					            'EndToEndId', end_to_end_id,
					            'AgencyCode', trim(agency_code),
					            'AgencyName', trim(agency_name),
					            'Districtcodelgd', districtcodelgd,
					            'JitReferenceNo', jit_reference_no)) from billing.jit_ecs_additional group by bill_id having bill_id=p_bill_id ) AS j  ON j.bill_id= t.bill_id
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id',id,
								'BillId',bill_id,
								'BillMode',bill_mode,
								'TrMasterId',tr_master_id,
                                'CreatedByUserid',created_by_userid,
                                'CreatedAt',created_at,
                                'IsScheduled',is_scheduled,
								'VoucherDetailsObject',voucher_details_object::JSONB ::TEXT,
								'PlDetailObject',pl_detail_object,
                                'IsTopup',(topup_amount>0)::boolean, 
								'ReissueAmount',reissue_amount,
								'TopupAmount',topup_amount,
								'TotalAmtForCsCalcSc',total_amt_for_cs_calc_sc,
								'TotalAmtForCsCalcScoc',total_amt_for_cs_calc_scoc,
								'TotalAmtForCsCalcSccc',total_amt_for_cs_calc_sccc,
								'TotalAmtForCsCalcScsal',total_amt_for_cs_calc_scsal,
								'TotalAmtForCsCalcSt',total_amt_for_cs_calc_st,
								'TotalAmtForCsCalcStoc',total_amt_for_cs_calc_stoc,
								'TotalAmtForCsCalcStcc',total_amt_for_cs_calc_stcc,
								'TotalAmtForCsCalcStsal',total_amt_for_cs_calc_stsal,
								'TotalAmtForCsCalcOt',total_amt_for_cs_calc_ot,
								'TotalAmtForCsCalcOtoc',total_amt_for_cs_calc_otoc,
								'TotalAmtForCsCalcOtcc',total_amt_for_cs_calc_otcc,
								'TotalAmtForCsCalcOtsal',total_amt_for_cs_calc_otsal,
								'HoaId',hoa_id,
								'CategoryCode',category_code)) from billing.tr_26a_detail group by bill_id having bill_id=p_bill_id) AS t0  ON t0.bill_id= t.bill_id
      LEFT JOIN
	  (select bill_id, json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BillMode', bill_mode,
								'TrMasterId', tr_master_id,
								'IsScheduled', is_scheduled,
								'Status', status,
								'IsDeleted', is_deleted,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'EmployeeDetailsObject', employee_details_object
	  							) from billing.tr_10_detail where bill_id=p_bill_id) AS t1  ON t1.bill_id= t.bill_id
-- 	  LEFT JOIN      
-- 	  (select bill_id, json_agg(json_build_object(
-- 								'BillId', bill_id,
-- 								'VoucherNo', voucher_no,
-- 								'Amount', amount,
-- 								'VoucherDate', voucher_date,
-- 								'DescCharges', desc_charges,
-- 								'Authority', authority))from billing.jit_fto_voucher group by bill_id having bill_id=p_bill_id) AS j0  ON j0.bill_id= t.bill_id
	  LEFT JOIN      
	  (select bill_id, json_agg(json_build_object(
							    'BillId', bill_id,
							    'PayeeId', payee_id,
							    'Componentcode', trim(componentcode),
							    'Componentname', trim(componentname),
							    'Amount', amount,
							    'Slscode', slscode)) from billing.bill_jit_components group by bill_id having bill_id=p_bill_id) AS b4  ON b4.bill_id= t.bill_id
      LEFT JOIN
      (select 
	  g.bill_id, json_agg(json_build_object(
                                'BillId',  g.bill_id,
                                'CpinNo', trim(c.cpin_id),
                                'Amount', c.cpin_amount,
                                'CpinDate', c.cpin_date      
      ))FROM (select * from billing.bill_gst where bill_id=p_bill_id) g, billing_master.cpin_master c
where g.cpin_id=c.id group by g.bill_Id) AS j1  ON b4.bill_id= t.bill_id      
	
	  LEFT JOIN
	  (select bill_id, json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BillMode', bill_mode,
								'TrMasterId', tr_master_id,
								'IsScheduled', is_scheduled,
								'Status', status,
								'IsDeleted', is_deleted,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'EmployeeDetailsObject', employee_details_object
	  							) from billing.tr_12_detail where bill_id=p_bill_id) AS j2  ON t1.bill_id= t.bill_id
		LEFT JOIN
		(select bill_id, json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'PayeeName', payee_name,
								'ChequeNumber', cheque_number,
								'Amount', amount,
								'ChequeDate', cheque_date,
								'PayMode', pay_mode,
								'Status', status,
								'CreatedAt', created_at,
								'CreatedByUserid', created_by_userid,
								'IsActive', is_active,
								'FinancialYear', financial_year,
								'EPradanId', e_pradan_id
		))from billing.bill_cheque_details group by bill_id having bill_id=p_bill_id) AS j3  ON j3.bill_id= t.bill_id
		
		LEFT JOIN
		(select bill_id, json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'AllotmentId', allotment_id,
								'Amount', amount,
								'DdoUserId', ddo_user_id,
								'DdoCode', ddo_code,
								'TreasuryCode', treasury_code,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'FinancialYear', financial_year,
								'ActiveHoaId', active_hoa_id
		))from billing.ddo_allotment_booked_bill group by bill_id having bill_id=p_bill_id) AS j4  ON j4.bill_id= t.bill_id;	
						

		RETURN v_bill_payload;
END;
$$;


ALTER FUNCTION billing.get_bill_payload_last_working(p_bill_id bigint) OWNER TO postgres;

--
-- TOC entry 495 (class 1255 OID 920198)
-- Name: get_bill_payload_old(bigint); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.get_bill_payload_old(p_bill_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_bill_payload JSON;
BEGIN
	SELECT 
	jsonb_build_object(
		'BillId', t.bill_id,
		'BillNo', trim(bill_no),
		'BillDate', bill_date,
		'BillMode', COALESCE(bill_mode, 0),
		'ReferenceNo', trim(reference_no),
		'FormVersion', form_version,
		'FormRevisionNo', form_revision_no,
		'TrMasterId', tr_master_id,
		'PaymentMode', payment_mode,
		'FinancialYear', financial_year,
		'Demand', demand,
		'MajorHead', major_head,
		'SubMajorHead', sub_major_head,
		'MinorHead', minor_head,
		'PlanStatus', plan_status,
		'SchemeHead', scheme_head,
		'DetailHead', detail_head,
		'VotedCharged', voted_charged,
		'GrossAmount', gross_amount,
		'NetAmount', net_amount,
		'BtAmount', bt_amount,
		'TreasuryBt', treasury_bt,
		'AgBt', ag_bt
	)||	
	jsonb_build_object(
		'SanctionNo', sanction_no,
		'SanctionAmt', sanction_amt,
		'SanctionDate', sanction_date,
		'SanctionBy', sanction_by,
		'Remarks', remarks,
		'DdoCode', ddo_code,
		'TreasuryCode', treasury_code,
		'IsGem', is_gem,
		'Status', status,
		'CreatedByUserid', created_by_userid,
		'CreatedAt', created_at,
		'SnaGrantType', sna_grant_type,
		'CssBenType', css_ben_type,
		'AafsProjectId', aafs_project_id,
		'SchemeCode', trim(scheme_code),
		'SchemeName', trim(scheme_name),
		'BillType', bill_type,
		'IsGst', is_gst,
		'GstAmount', gst_amount,
		'BillBtdetails', b1.json_agg,
		'BillEcsNeftDetails', b2.json_agg,
		'BillChequeDetails', j3.json_agg,
		'BillSubdetailInfos', b3.json_agg,
		'JitSanctionBookings', j4.json_agg,
		'Tr26aDetails', t0.json_agg,
		'Tr10Details', t1.json_build_object,
		'Tr12Details', j2.json_build_object,
		'JitEcsAdditionals', j.json_agg,
		'BillJitComponents', b4.json_agg,
		'CpinDetails', j1.json_agg
    ) AS bill_payload into v_bill_payload
	  FROM (
          SELECT b.bill_id, b.aafs_project_id, b.ag_bt, b.bill_components, b.bill_date, b.bill_mode, b.bill_no, 
		  b.bill_type, b.bt_amount, b.created_at, b.created_by_userid, b.css_ben_type, b.ddo_code, b.demand, 
		  b.detail_head, b.financial_year, b.form_revision_no, b.form_version, b.gross_amount, 
		  b.gst_amount, b.is_cancelled, b.is_deleted, b.is_extended_part_filled, b.is_gem, b.is_gst,
		  b.major_head, b.minor_head, b.net_amount, b.payment_mode, b.plan_status, b.reference_no, 
		  b.remarks, b.sanction_amt, b.sanction_by, b.sanction_date, b.sanction_no, b.scheme_code, 
		  b.scheme_head, b.scheme_name, b.sna_grant_type, b.status, b.sub_major_head, b.tr_master_id, 
		  b.treasury_bt, b.treasury_code, b.updated_at, b.updated_by_userid, b.voted_charged
          FROM billing.bill_details AS b
          WHERE b.bill_id = p_bill_id
          LIMIT 1
      ) AS t
	  LEFT JOIN
      (select bill_id,json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BtSerial', bt_serial,
								'BtType', bt_type,
								'DDoCode', ddo_code,
								'TreasuryCode', treasury_code,
								'Amount', amount,
								'FinancialYear', financial_year,
								'CreatedBy', created_by,
								'CreatedAt', created_at
	  					)) from billing.bill_btdetail group by bill_id having bill_id=p_bill_id) AS b1 ON b1.bill_id= t.bill_id
	  LEFT JOIN 					  
      (select bill_id, json_agg(json_build_object(
                                'Id', id,
							  	'BillId', bill_id,
								'PayeeName', payee_name,
								'BeneficiaryId', beneficiary_id,
								'PayeeType', beneficiary_type,
								'PanNo', trim(pan_no),
								'ContactNumber', contact_number,
								'BeneficiaryType', payee_type,
								'Address', address,
								'Email', email,
								'IfscCode', ifsc_code,
								'AccountType', account_type,
								'BankAccountNumber', trim(bank_account_number),
								'BankName', trim(bank_name),
								'Amount', amount,
                                'Status', status,
                                'IsActive', is_active,
                                'CreatedByUserid', created_by_userid,
                                'CreatedAt', created_at,
								'EPradanId', e_pradan_id,
								'FinancialYear', financial_year,
								'IsGst', is_gst
	  					))from billing.bill_ecs_neft_details  group by bill_id having bill_id=p_bill_id) AS b2 ON b2.bill_id= t.bill_id
      LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id',id,
								'BillId',bill_id,
								'ActiveHoaId',active_hoa_id,
								'Amount',amount,
                                'Status',status,
                                'CreatedByUserid',created_by_userid,
                                'CreatedAt',created_at,   
								'FinancialYear',financial_year,
								'DdoCode',ddo_code,
								'TreasuryCode',treasury_code
	  					)) from billing.bill_subdetail_info group by bill_id having bill_id=p_bill_id) AS b3 ON b3.bill_id= t.bill_id
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id', id,
					            'EcsId', ecs_id,
					            'BillId', bill_id,
					            'BeneficiaryId', beneficiary_id,
					            'Aadhar', aadhar,
					            'GrossAmount', gross_amount,
					            'NetAmount', net_amount,
					            'ReissueAmount', reissue_amount,
					            'TopUp', top_up,
					            'EndToEndId', end_to_end_id,
					            'AgencyCode', trim(agency_code),
					            'AgencyName', trim(agency_name),
					            'Districtcodelgd', districtcodelgd,
					            'JitReferenceNo', jit_reference_no)) from billing.jit_ecs_additional group by bill_id having bill_id=p_bill_id ) AS j  ON j.bill_id= t.bill_id
	  LEFT JOIN
	  (select bill_id, json_agg(json_build_object(
                                'Id',id,
								'BillId',bill_id,
								'BillMode',bill_mode,
								'TrMasterId',tr_master_id,
                                'CreatedByUserid',created_by_userid,
                                'CreatedAt',created_at,
                                'IsScheduled',is_scheduled,
								'VoucherDetailsObject',voucher_details_object::JSONB ::TEXT,
								'PlDetailObject',pl_detail_object,
                                'IsTopup',(topup_amount>0)::boolean, 
								'ReissueAmount',reissue_amount,
								'TopupAmount',topup_amount,
								'TotalAmtForCsCalcSc',total_amt_for_cs_calc_sc,
								'TotalAmtForCsCalcScoc',total_amt_for_cs_calc_scoc,
								'TotalAmtForCsCalcSccc',total_amt_for_cs_calc_sccc,
								'TotalAmtForCsCalcScsal',total_amt_for_cs_calc_scsal,
								'TotalAmtForCsCalcSt',total_amt_for_cs_calc_st,
								'TotalAmtForCsCalcStoc',total_amt_for_cs_calc_stoc,
								'TotalAmtForCsCalcStcc',total_amt_for_cs_calc_stcc,
								'TotalAmtForCsCalcStsal',total_amt_for_cs_calc_stsal,
								'TotalAmtForCsCalcOt',total_amt_for_cs_calc_ot,
								'TotalAmtForCsCalcOtoc',total_amt_for_cs_calc_otoc,
								'TotalAmtForCsCalcOtcc',total_amt_for_cs_calc_otcc,
								'TotalAmtForCsCalcOtsal',total_amt_for_cs_calc_otsal,
								'HoaId',hoa_id,
								'CategoryCode',category_code)) from billing.tr_26a_detail group by bill_id having bill_id=p_bill_id) AS t0  ON t0.bill_id= t.bill_id
      LEFT JOIN
	  (select bill_id, json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BillMode', bill_mode,
								'TrMasterId', tr_master_id,
								'IsScheduled', is_scheduled,
								'Status', status,
								'IsDeleted', is_deleted,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'EmployeeDetailsObject', employee_details_object
	  							) from billing.tr_10_detail where bill_id=p_bill_id) AS t1  ON t1.bill_id= t.bill_id
	  LEFT JOIN      
	  (select bill_id, json_agg(json_build_object(
								'BillId', bill_id,
								'VoucherNo', voucher_no,
								'Amount', amount,
								'VoucherDate', voucher_date,
								'DescCharges', desc_charges,
								'Authority', authority))from billing.jit_fto_voucher group by bill_id having bill_id=p_bill_id) AS j0  ON j0.bill_id= t.bill_id
	  LEFT JOIN      
	  (select bill_id, json_agg(json_build_object(
							    'BillId', bill_id,
							    'PayeeId', payee_id,
							    'Componentcode', trim(componentcode),
							    'Componentname', trim(componentname),
							    'Amount', amount,
							    'Slscode', slscode)) from billing.bill_jit_components group by bill_id having bill_id=p_bill_id) AS b4  ON b4.bill_id= t.bill_id
      LEFT JOIN
      (select 
	  g.bill_id, json_agg(json_build_object(
                                'BillId',  g.bill_id,
                                'CpinNo', trim(c.cpin_id),
                                'Amount', c.cpin_amount,
                                'CpinDate', c.cpin_date      
      ))FROM (select * from billing.bill_gst where bill_id=p_bill_id) g, billing_master.cpin_master c
where g.cpin_id=c.id group by g.bill_Id) AS j1  ON b4.bill_id= t.bill_id      
	
	  LEFT JOIN
	  (select bill_id, json_build_object(
								'Id', id,
								'BillId', bill_id,
								'BillMode', bill_mode,
								'TrMasterId', tr_master_id,
								'IsScheduled', is_scheduled,
								'Status', status,
								'IsDeleted', is_deleted,
								'CreatedByUserid', created_by_userid,
								'CreatedAt', created_at,
								'EmployeeDetailsObject', employee_details_object
	  							) from billing.tr_12_detail where bill_id=p_bill_id) AS j2  ON t1.bill_id= t.bill_id
		LEFT JOIN
		(select bill_id, json_agg(json_build_object(
								'Id', id,
								'BillId', bill_id,
								'PayeeName', payee_name,
								'ChequeNumber', cheque_number,
								'Amount', amount,
								'ChequeDate', cheque_date,
								'PayMode', pay_mode,
								'Status', status,
								'CreatedAt', created_at,
								'CreatedByUserid', created_by_userid,
								'IsActive', is_active,
								'FinancialYear', financial_year,
								'EPradanId', e_pradan_id
		))from billing.bill_cheque_details group by bill_id having bill_id=p_bill_id) AS j3  ON j3.bill_id= t.bill_id
		
		LEFT JOIN
		(SELECT bill_id,
				json_agg(json_build_object(
				'Id', book.id,
				'BillId', bill_id,
				'SanctionNo', sanction_no,
				'BookedAmt', booked_amt::Numeric::Bigint))
			FROM 
				jit.jit_fto_sanction_booking book,
				billing.ebill_jit_int_map maps
			WHERE  
				book.ref_no = maps.jit_ref_no group by maps.bill_id having bill_id=p_bill_id) AS j4 ON j4.bill_id= t.bill_id;

	
		RETURN v_bill_payload;
END;
$$;


ALTER FUNCTION billing.get_bill_payload_old(p_bill_id bigint) OWNER TO postgres;

--
-- TOC entry 446 (class 1255 OID 920200)
-- Name: get_failed_success_ben_report(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_failed_success_ben_report(IN in_payload jsonb, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN
WITH bill_info AS (
    SELECT 
        bd.bill_id,
        bd.bill_no,
		bd.financial_year,
		bd.bill_date,
		bd.bill_type,
		bd.demand,
        CONCAT(TRIM(bd.reference_no), '-', bd.form_version) AS bill_reference_no,
        bd.scheme_code,
        bd.scheme_name,
        (bd.net_amount + bd.gst_amount) AS bill_net,
        billsub.active_hoa_id,
        CONCAT(hoa.demand_no, '-', hoa.major_head, '-',
               hoa.submajor_head, '-', hoa.minor_head, '-', hoa.scheme_head, '-', hoa.detail_head,
               '-', hoa.subdetail_head, '-', hoa.voted_charged) AS hoa,
		hoa.description as description,
		ecs_add.agency_code,
		ecs_add.agency_name,
		ecs_add.jit_reference_no,
		bend.is_gst,
		t.token_number,
		CONCAT(v.major_head, '/', v.voucher_no) as tv_no,
		v.voucher_date
    FROM billing.bill_details bd
    JOIN billing.bill_ecs_neft_details bend 
        ON bend.bill_id = bd.bill_id
	JOIN billing.jit_ecs_additional ecs_add 
        ON ecs_add.ecs_id = bend.id
    LEFT JOIN billing.bill_subdetail_info AS billsub
        ON billsub.bill_id = bd.bill_id
    LEFT JOIN billing_master.bill_status_master bsm 
        ON bsm.status_id = bd.status
    LEFT JOIN master.active_hoa_mst hoa
        ON hoa.id = billsub.active_hoa_id
	LEFT JOIN cts.token t
        ON t.entity_id = bd.bill_id
	LEFT JOIN cts.voucher v
        ON v.token_id = t.id
		WHERE bd.ddo_code = (in_payload->>'DdoCode')
        AND (
			(in_payload->>'SlsCode')::character varying IS NULL
			OR
			bd.scheme_code = (in_payload->>'SlsCode')::character varying
		)
		AND (
			(in_payload->>'FinYear')::smallint IS NULL
			OR
			bd.financial_year = (in_payload->>'FinYear')::smallint
		)
		AND (
			(in_payload->>'AgencyCode') IS NULL
			OR
			ecs_add.agency_code = (in_payload->>'AgencyCode')
		)
		AND (
			(in_payload->>'HoaId')::bigint IS NULL
			OR
			billsub.active_hoa_id = (in_payload->>'HoaId')::bigint
		)
		AND (
			(in_payload->>'BillType') IS NULL
			OR
			bd.bill_type = (in_payload->>'BillType')
		)
		AND bd.is_cancelled = false
	  GROUP BY 
        bd.bill_id,
		bd.bill_type,
        bd.bill_no,
		bd.bill_date,
        bd.reference_no,
        bd.form_version,
        bd.scheme_code,
        bd.scheme_name,
		bd.demand,
        billsub.active_hoa_id,
        hoa.demand_no, hoa.major_head,
        hoa.submajor_head, hoa.minor_head, hoa.scheme_head, hoa.detail_head,
        hoa.subdetail_head, hoa.voted_charged, hoa.description,ecs_add.agency_code,
		ecs_add.agency_name, ecs_add.jit_reference_no, t.token_number, bend.is_gst,
		v.major_head, v.voucher_no, v.voucher_date
),
failed_success_ben AS (
    SELECT
        ecs.bill_id,
		sben.is_active AS succ_is_active,
		f.is_active AS f_is_active,
        sben.payee_name AS success_payee_name,
		f.payee_name AS failed_payee_name,
        sben.end_to_end_id AS success_end_to_end_id,
        f.end_to_end_id AS failed_end_to_end_id,
		SUM(sben.amount) AS total_paid,
        COUNT(sben.id) AS success_count,
		COUNT(f.id) AS failed_count,
		SUM(f.failed_transaction_amount) AS failed_amount
    FROM billing.bill_ecs_neft_details ecs
    LEFT JOIN cts.success_transaction_beneficiary sben 
        ON ecs.id = sben.ecs_id
	 LEFT JOIN cts.failed_transaction_beneficiary f 
	        ON ecs.id = f.beneficiary_id
	        AND f.end_to_end_id NOT IN (
	            SELECT DISTINCT end_to_end_id 
	            FROM billing.jit_ecs_additional
	            WHERE end_to_end_id IS NOT NULL
	        )
		WHERE sben.is_active = 1 OR f.is_active = 1
    GROUP BY ecs.bill_id
	, sben.end_to_end_id, f.end_to_end_id, 
	sben.id, f.id
),
final_data AS (
    SELECT 
        bi.bill_id,
		bi.bill_type,
		bi.bill_date,
        bi.hoa AS HOA,
		bi.description AS description,
        dept.name AS "Department",
        bi.bill_no AS bill_no,
        bi.bill_reference_no AS reference_no,
        bi.scheme_code AS scheme_code,
        bi.scheme_name AS scheme_name,
        bi.bill_net AS "Total Amount",
		sb.success_payee_name AS  "SuccessPayeeName",
		sb.success_end_to_end_id AS  "SuccessPayeeEndtoEnd",
		sb.failed_payee_name AS  "FailedPayeeName",
		sb.failed_end_to_end_id AS  "FailedPayeeEndtoEnd",
        COALESCE(sb.total_paid, 0) AS "Amount Paid",
        COALESCE(sb.failed_amount, 0) AS "Failed Amount",
		COALESCE(sb.success_count, 0) AS "Payment Success Count",
        COALESCE(sb.failed_count, 0) AS "Failed Count",
		CASE 
			WHEN sb.total_paid != 0 THEN sb.total_paid
			WHEN sb.failed_amount != 0 THEN sb.failed_amount
		END AS ben_amount,
		CASE 
			WHEN sb.success_payee_name IS NOT NULL THEN sb.success_payee_name
			WHEN sb.failed_payee_name IS NOT NULL THEN sb.failed_payee_name
		END AS payee_name,
		CASE 
			WHEN sb.success_end_to_end_id IS NOT NULL THEN sb.success_end_to_end_id
			WHEN sb.failed_end_to_end_id IS NOT NULL THEN sb.failed_end_to_end_id
		END AS payee_end_to_end_id,
		CASE 
            WHEN sb.failed_count > 0 AND sb.f_is_active = 1 THEN 'FAILED'
            WHEN sb.success_count > 0 AND sb.succ_is_active = 1 THEN 'SUCCESS'
        END AS "Status",
		bi.agency_code,
		bi.agency_name,
		CASE WHEN bi.is_gst = false THEN bi.jit_reference_no
			 WHEN bi.is_gst = true THEN 'NA'
		END AS "jit_reference_no",
		fy.financial_year AS "FinYear",
		bi.financial_year AS "FinYearId",
		bi.token_number,
		bi.tv_no,
		bi.voucher_date
    FROM bill_info bi
    LEFT JOIN failed_success_ben sb 
        ON bi.bill_id = sb.bill_id
    LEFT JOIN master.department dept
        ON dept.demand_code = bi.demand 
	LEFT JOIN master.financial_year_master fy
        ON bi.financial_year = fy.id 
	WHERE COALESCE(sb.success_count, 0) > 0 OR COALESCE(sb.failed_count, 0) > 0
    ORDER BY bi.bill_id
)
SELECT json_agg(
    json_build_object(
        'BillId', bill_id,
		'BillType', bill_type,
		'BillDate', bill_date,
		'FinYear', "FinYear",
		'FinYearId', "FinYearId",
        'HOA', HOA,
		'Description', description,
        'Department', "Department",
        'BillNo', trim(bill_no),
        'ReferenceNo', reference_no,
        'SchemeCode', scheme_code,
        'SchemeName', scheme_name,
		'AgencyCode', agency_code,
        'AgencyName', agency_name,
		'JitRefNo', "jit_reference_no",
        'BenAmount', "ben_amount",
		'PayeeName', "payee_name",
        'PayeeEndToEnd', "payee_end_to_end_id",
		'Status', "Status",
		'TokenNo', token_number,
		'TVNo', tv_no,
		'TVDate', voucher_date
    )
) INTO out_payload
FROM final_data
WHERE (in_payload->>'Status') IS NULL 
      OR "Status" = in_payload->>'Status';
END;
$$;


ALTER PROCEDURE billing.get_failed_success_ben_report(IN in_payload jsonb, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 492 (class 1255 OID 920202)
-- Name: get_failed_success_ben_report_bk(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_failed_success_ben_report_bk(IN in_payload jsonb, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN
WITH bill_info AS (
    SELECT 
        bd.bill_id,
        bd.bill_no,
		bd.financial_year,
		bd.bill_date,
		bd.bill_type,
		bd.demand,
        CONCAT(TRIM(bd.reference_no), '-', bd.form_version) AS bill_reference_no,
        bd.scheme_code,
        bd.scheme_name,
        (bd.net_amount + bd.gst_amount) AS bill_net,
        billsub.active_hoa_id,
        CONCAT(hoa.demand_no, '-', hoa.major_head, '-',
               hoa.submajor_head, '-', hoa.minor_head, '-', hoa.scheme_head, '-', hoa.detail_head,
               '-', hoa.subdetail_head, '-', hoa.voted_charged) AS hoa,
		hoa.description as description,
		ecs_add.agency_code,
		ecs_add.agency_name,
		ecs_add.jit_reference_no,
		t.token_number
    FROM billing.bill_details bd
    JOIN billing.bill_ecs_neft_details bend 
        ON bend.bill_id = bd.bill_id
	JOIN billing.jit_ecs_additional ecs_add 
        ON ecs_add.ecs_id = bend.id
    LEFT JOIN billing.bill_subdetail_info AS billsub
        ON billsub.bill_id = bd.bill_id
    LEFT JOIN billing_master.bill_status_master bsm 
        ON bsm.status_id = bd.status
    LEFT JOIN master.active_hoa_mst hoa
        ON hoa.id = billsub.active_hoa_id
	LEFT JOIN cts.token t
        ON t.entity_id = bd.bill_id
		WHERE bd.ddo_code = (in_payload->>'DdoCode')
        AND (
			(in_payload->>'SlsCode')::character varying IS NULL
			OR
			bd.scheme_code = (in_payload->>'SlsCode')::character varying
		)
		AND (
			(in_payload->>'FinYear')::smallint IS NULL
			OR
			bd.financial_year = (in_payload->>'FinYear')::smallint
		)
		AND (
			(in_payload->>'AgencyCode') IS NULL
			OR
			ecs_add.agency_code = (in_payload->>'AgencyCode')
		)
		AND (
			(in_payload->>'HoaId')::bigint IS NULL
			OR
			billsub.active_hoa_id = (in_payload->>'HoaId')::bigint
		)
		AND bd.is_cancelled = false
	  GROUP BY 
        bd.bill_id,
		bd.bill_type,
        bd.bill_no,
		bd.bill_date,
        bd.reference_no,
        bd.form_version,
        bd.scheme_code,
        bd.scheme_name,
		bd.demand,
        billsub.active_hoa_id,
        hoa.demand_no, hoa.major_head,
        hoa.submajor_head, hoa.minor_head, hoa.scheme_head, hoa.detail_head,
        hoa.subdetail_head, hoa.voted_charged, hoa.description,ecs_add.agency_code,
		ecs_add.agency_name, ecs_add.jit_reference_no, t.token_number
),
failed_success_ben AS (
    SELECT
        ecs.bill_id,
		sben.is_active AS succ_is_active,
		f.is_active AS f_is_active,
        sben.payee_name AS success_payee_name,
		f.payee_name AS failed_payee_name,
        sben.end_to_end_id AS success_end_to_end_id,
        f.end_to_end_id AS failed_end_to_end_id,
		SUM(sben.amount) AS total_paid,
        COUNT(sben.id) AS success_count,
		COUNT(f.id) AS failed_count,
		SUM(f.failed_transaction_amount) AS failed_amount
    FROM billing.bill_ecs_neft_details ecs
    LEFT JOIN cts.success_transaction_beneficiary sben 
        ON ecs.id = sben.ecs_id
	LEFT JOIN cts.failed_transaction_beneficiary f
        ON ecs.bill_id = f.bill_id  
		AND trim(f.account_no) = trim(ecs.bank_account_number)
		WHERE sben.is_active = 1 OR f.is_active = 1
    GROUP BY ecs.bill_id, sben.end_to_end_id, f.end_to_end_id, 
	sben.id, f.id
),
final_data AS (
    SELECT 
        bi.bill_id,
		bi.bill_type,
		bi.bill_date,
        bi.hoa AS HOA,
		bi.description AS description,
        dept.name AS "Department",
        bi.bill_no AS bill_no,
        bi.bill_reference_no AS reference_no,
        bi.scheme_code AS scheme_code,
        bi.scheme_name AS scheme_name,
        bi.bill_net AS "Total Amount",
		sb.success_payee_name AS  "SuccessPayeeName",
		sb.success_end_to_end_id AS  "SuccessPayeeEndtoEnd",
		sb.failed_payee_name AS  "FailedPayeeName",
		sb.failed_end_to_end_id AS  "FailedPayeeEndtoEnd",
        COALESCE(sb.total_paid, 0) AS "Amount Paid",
        COALESCE(sb.failed_amount, 0) AS "Failed Amount",
		COALESCE(sb.success_count, 0) AS "Payment Success Count",
        COALESCE(sb.failed_count, 0) AS "Failed Count",
		CASE 
			WHEN sb.total_paid != 0 THEN sb.total_paid
			WHEN sb.failed_amount != 0 THEN sb.failed_amount
		END AS ben_amount,
		CASE 
			WHEN sb.success_payee_name IS NOT NULL THEN sb.success_payee_name
			WHEN sb.failed_payee_name IS NOT NULL THEN sb.failed_payee_name
		END AS payee_name,
		CASE 
			WHEN sb.success_end_to_end_id IS NOT NULL THEN sb.success_end_to_end_id
			WHEN sb.failed_end_to_end_id IS NOT NULL THEN sb.failed_end_to_end_id
		END AS payee_end_to_end_id,
		CASE 
            WHEN sb.failed_count > 0 AND sb.f_is_active = 1 THEN 'FAILED'
            WHEN sb.success_count > 0 AND sb.succ_is_active = 1 THEN 'SUCCESS'
        END AS "Status",
		bi.agency_code,
		bi.agency_name,
		bi.jit_reference_no,
		fy.financial_year AS "FinYear",
		bi.financial_year AS "FinYearId",
		bi.token_number
    FROM bill_info bi
    LEFT JOIN failed_success_ben sb 
        ON bi.bill_id = sb.bill_id
    LEFT JOIN master.department dept
        ON dept.demand_code = bi.demand 
	LEFT JOIN master.financial_year_master fy
        ON bi.financial_year = fy.id 
	WHERE COALESCE(sb.success_count, 0) > 0 OR COALESCE(sb.failed_count, 0) > 0
    ORDER BY bi.bill_id
)
SELECT json_agg(
    json_build_object(
        'BillId', bill_id,
		'BillType', bill_type,
		'BillDate', bill_date,
		'FinYear', "FinYear",
		'FinYearId', "FinYearId",
        'HOA', HOA,
		'Description', description,
        'Department', "Department",
        'BillNo', trim(bill_no),
        'ReferenceNo', reference_no,
        'SchemeCode', scheme_code,
        'SchemeName', scheme_name,
		'AgencyCode', agency_code,
        'AgencyName', agency_name,
		'JitRefNo', jit_reference_no,
        'BenAmount', "ben_amount",
		'PayeeName', "payee_name",
        'PayeeEndToEnd', "payee_end_to_end_id",
		'Status', "Status",
		'TokenNo', token_number
    )
) INTO out_payload
FROM final_data
WHERE (in_payload->>'Status') IS NULL 
      OR "Status" = in_payload->>'Status';
END;
$$;


ALTER PROCEDURE billing.get_failed_success_ben_report_bk(IN in_payload jsonb, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 443 (class 1255 OID 920204)
-- Name: get_non_salary_tds_details_report(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_non_salary_tds_details_report(IN in_payload jsonb, OUT is_done boolean, OUT message_out text, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
 v_ddo_code text;
    v_designation text;
    v_office text;
	v_ddo_tan_no text;
	v_start_date DATE;
    v_end_date DATE;
BEGIN
    v_start_date := (in_payload->>'FromBillDate')::DATE;  
    v_end_date := (in_payload->>'ToBillDate')::DATE; 
    -- Fetch DDO details
    SELECT ddo_code, designation, ddo_tan_no, office_name
    INTO v_ddo_code, v_designation, v_ddo_tan_no, v_office
    FROM master.ddo 
    WHERE ddo_code = (in_payload->>'DdoCode');

    -- Fetch Employee TDS Data
	SELECT json_build_object(
	    'DdoCode', v_ddo_code,
		'DdoTanNo', v_ddo_tan_no,
	    'Designation', v_designation,
	    'Office', v_office,
		'StartingDate', TO_CHAR(v_start_date, 'dd/mm/yyyy'),
        'EndingDate', TO_CHAR(v_end_date, 'dd/mm/yyyy'),
	    'Employees', json_agg(
	        json_build_object(
	            'BillNo', trim(emp_data.bill_no),
		        'BillDate', TO_CHAR(emp_data.bill_date, 'dd/mm/yyyy'),
	            'Name', emp_data.payee_name,
	            'PanNo', trim(emp_data.pan_no),
				'GrossAmount', emp_data.total_gross,
				'Tds', emp_data.total_tds,
				'TVNo', CONCAT(emp_data.major_head, '/',emp_data.voucher_no),
				'TVDate', TO_CHAR(emp_data.voucher_date, 'dd/mm/yyyy'),
				'VoucherNo', emp_data.voucher_no
	        )
	    )
	) INTO out_payload
	FROM (
	    SELECT DISTINCT
			emp.value->>'EmployeeName' AS payee_name,
            emp.value->>'PAN' AS pan_no,
	        bd.bill_no AS bill_no,
	        bd.bill_date AS bill_date,
			v.voucher_no AS voucher_no,
			v.voucher_date AS voucher_date,
			v.major_head AS major_head,
			SUM((emp.value->>'GrossClaim')::numeric) AS total_gross,
            SUM((emp.value->>'AmtDeducted')::numeric) AS total_tds
	    FROM billing.bill_details bd
	    JOIN billing.bill_subdetail_info billsub ON billsub.bill_id = bd.bill_id
	    JOIN master.active_hoa_mst hoa ON hoa.id = billsub.active_hoa_id
		JOIN billing.tr_10_detail tr ON tr.bill_id = bd.bill_id
		JOIN LATERAL jsonb_array_elements(tr.employee_details_object) AS emp(value) ON TRUE
		JOIN cts.voucher v ON v.bill_id = bd.bill_id
	    WHERE bd.ddo_code = (in_payload->>'DdoCode')
	        AND (
	            v.voucher_date BETWEEN (in_payload->>'FromBillDate')::DATE 
	            AND (in_payload->>'ToBillDate')::DATE
	        )
			AND bd.is_cancelled = false
			AND hoa.is_salary_component=false 
		GROUP BY emp.value->>'EmployeeName', emp.value->>'PAN', bd.bill_no,
	        bd.bill_date, v.voucher_no, v.voucher_date, v.major_head
	) AS emp_data;

	-- Check if data exists
    IF out_payload IS NULL OR out_payload = '{}' THEN
        is_done := FALSE;
        message_out := 'Data not found.';
        out_payload := '{}';
        RETURN;
    END IF;

    -- Set success
    is_done := TRUE;
    message_out := 'Data generated successfully.';

EXCEPTION
    WHEN OTHERS THEN
        is_done := FALSE;
        message_out := SQLERRM;
        out_payload := '{}';
END;
$$;


ALTER PROCEDURE billing.get_non_salary_tds_details_report(IN in_payload jsonb, OUT is_done boolean, OUT message_out text, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 423 (class 1255 OID 920205)
-- Name: get_pfms_process_log_status(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_pfms_process_log_status(IN in_payload jsonb, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT json_agg(pfms_result)
    INTO out_payload
    FROM (
        SELECT 
            sub.bill_id AS "BillId",
            sub.file_name AS "FileName",
            COALESCE(sub.payment_status, '') AS "PaymentStatus",
            COALESCE(sub.sanction_status, '') AS "SanctionStatus",
            CASE
                WHEN sub.created_at IS NOT NULL
                THEN TO_CHAR(sub.created_at, 'DD/MM/YYYY hh12:MIAM')
                ELSE ''
            END AS "StatusReceivedAt"
        FROM (
            SELECT * FROM (
				SELECT 
	                t.bill_id,
	                t.file_name,
	                t.payment_status,
	                t.sanction_status,
	                t.created_at,
					ROW_NUMBER() OVER(PARTITION BY t.payment_status, t.sanction_status ORDER BY created_at DESC) AS rn
	            FROM billing.billing_pfms_file_status_details t
	            WHERE t.bill_id = (in_payload->>'BillId')::bigint
			) AS t
			WHERE rn = 1
			ORDER BY t.created_at DESC
        ) sub
        -- ORDER BY "StatusReceivedAt"
    ) pfms_result;
END;
$$;


ALTER PROCEDURE billing.get_pfms_process_log_status(IN in_payload jsonb, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 447 (class 1255 OID 920206)
-- Name: get_tds_details_report(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_tds_details_report(IN in_payload jsonb, OUT is_done boolean, OUT message_out text, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_ddo_code text;
    v_designation text;
    v_detail_head text;
    v_ddo_tan_no text;
    v_start_date DATE;
    v_end_date DATE;
    v_financial_year text;

    -- Dynamic month numbers
    v_month1 int;
    v_month2 int;
    v_month3 int;

    -- Dynamic month names
    v_month_name1 text;
    v_month_name2 text;
    v_month_name3 text;
BEGIN
    -- Read payload dates
    v_start_date := (in_payload->>'FromBillDate')::DATE;
    v_end_date := (in_payload->>'ToBillDate')::DATE;

    v_month1 := EXTRACT(MONTH FROM v_start_date);
    v_month2 := EXTRACT(MONTH FROM v_start_date + INTERVAL '1 month');
    v_month3 := EXTRACT(MONTH FROM v_start_date + INTERVAL '2 month');

    v_month_name1 := TO_CHAR(v_start_date, 'Month');
    v_month_name2 := TO_CHAR(v_start_date + INTERVAL '1 month', 'Month');
    v_month_name3 := TO_CHAR(v_start_date + INTERVAL '2 month', 'Month');

    -- Fetch DDO details
    SELECT ddo_code, designation, ddo_tan_no
    INTO v_ddo_code, v_designation, v_ddo_tan_no
    FROM master.ddo 
    WHERE ddo_code = (in_payload->>'DdoCode');

    -- Fetch Detail Head
    SELECT DISTINCT hoa.detail_head 
    INTO v_detail_head
    FROM billing.bill_details bd
    JOIN billing.bill_subdetail_info billsub ON billsub.bill_id = bd.bill_id
    JOIN master.active_hoa_mst hoa ON hoa.id = billsub.active_hoa_id
    WHERE bd.ddo_code = v_ddo_code;

    -- Get active financial year
    SELECT financial_year
    INTO v_financial_year
    FROM master.financial_year_master
    WHERE is_active = true;

    -- Generate Report Payload
    SELECT json_build_object(
        'DdoCode', v_ddo_code,
        'DdoTanNo', v_ddo_tan_no,
        'Designation', v_designation,
        'DetailHead', v_detail_head,
        'FinancialYear', v_financial_year,
        'StartingDate', TO_CHAR(v_start_date, 'yyyy-MM-dd'),
        'EndingDate', TO_CHAR(v_end_date, 'yyyy-MM-dd'),
        'FirstMonthName', TRIM(v_month_name1),
        'SecondMonthName', TRIM(v_month_name2),
        'ThirdMonthName', TRIM(v_month_name3),
        'Employees', json_agg(
            json_build_object(
                'EmployeeName', emp_data.employee_name,
                'EmployeeId', emp_data.employee_id,
                'PAN', emp_data.pan,
                'FirstMonth', json_build_object(
                    'Gross', emp_data.fm_gross,
                    'ITDeducted', emp_data.fm_it
                ),
                'SecondMonth', json_build_object(
                    'Gross', emp_data.sm_gross,
                    'ITDeducted', emp_data.sm_it
                ),
                'ThirdMonth', json_build_object(
                    'Gross', emp_data.tm_gross,
                    'ITDeducted', emp_data.tm_it
                ),
                'Total', json_build_object(
                    'Gross', emp_data.total_gross,
                    'ITDeducted', emp_data.total_it
                )
            )
        )
    ) INTO out_payload
    FROM (
        SELECT 
            emp.value->>'EmployeeName' AS employee_name,
            emp.value->>'EmployeeId' AS employee_id,
            emp.value->>'PAN' AS pan,
            SUM(CASE WHEN EXTRACT(MONTH FROM v.voucher_date) = v_month1 THEN (emp.value->>'GrossClaim')::numeric ELSE 0 END) AS fm_gross,
            SUM(CASE WHEN EXTRACT(MONTH FROM v.voucher_date) = v_month1 THEN (emp.value->>'AmtDeducted')::numeric ELSE 0 END) AS fm_it,
            SUM(CASE WHEN EXTRACT(MONTH FROM v.voucher_date) = v_month2 THEN (emp.value->>'GrossClaim')::numeric ELSE 0 END) AS sm_gross,
            SUM(CASE WHEN EXTRACT(MONTH FROM v.voucher_date) = v_month2 THEN (emp.value->>'AmtDeducted')::numeric ELSE 0 END) AS sm_it,
            SUM(CASE WHEN EXTRACT(MONTH FROM v.voucher_date) = v_month3 THEN (emp.value->>'GrossClaim')::numeric ELSE 0 END) AS tm_gross,
            SUM(CASE WHEN EXTRACT(MONTH FROM v.voucher_date) = v_month3 THEN (emp.value->>'AmtDeducted')::numeric ELSE 0 END) AS tm_it,
            SUM((emp.value->>'GrossClaim')::numeric) AS total_gross,
            SUM((emp.value->>'AmtDeducted')::numeric) AS total_it
        FROM billing.bill_details bd
        JOIN billing.bill_subdetail_info billsub ON billsub.bill_id = bd.bill_id
        JOIN master.active_hoa_mst hoa ON hoa.id = billsub.active_hoa_id
        JOIN billing.tr_10_detail tr ON tr.bill_id = bd.bill_id
        JOIN cts.voucher v ON v.bill_id = tr.bill_id
        JOIN LATERAL jsonb_array_elements(tr.employee_details_object) AS emp(value) ON TRUE
        WHERE bd.ddo_code = (in_payload->>'DdoCode')
          AND v.voucher_date BETWEEN v_start_date AND v_end_date
          AND bd.is_cancelled = false
        GROUP BY emp.value->>'EmployeeName', emp.value->>'EmployeeId', emp.value->>'PAN'
    ) AS emp_data;

    IF out_payload IS NULL OR out_payload = '{}' THEN
        is_done := FALSE;
        message_out := 'Data not found.';
        out_payload := '{}';
    ELSE
        is_done := TRUE;
        message_out := 'Data generated successfully.';
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        is_done := FALSE;
        message_out := SQLERRM;
        out_payload := '{}';
END;
$$;


ALTER PROCEDURE billing.get_tds_details_report(IN in_payload jsonb, OUT is_done boolean, OUT message_out text, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 471 (class 1255 OID 920207)
-- Name: get_tds_on_gst_details_report(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.get_tds_on_gst_details_report(IN in_payload jsonb, OUT is_done boolean, OUT message_out text, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
 v_ddo_code text;
    v_designation text;
    v_office text;
	v_ddo_gstin text;
	v_start_date DATE;
    v_end_date DATE;
BEGIN
    v_start_date := (in_payload->>'FromBillDate')::DATE;  
    v_end_date := (in_payload->>'ToBillDate')::DATE; 
    -- Fetch DDO details
    SELECT ddo_code, designation, gstin, office_name
    INTO v_ddo_code, v_designation, v_ddo_gstin, v_office
    FROM master.ddo 
    WHERE ddo_code = (in_payload->>'DdoCode');

    -- Fetch Employee TDS Data
	SELECT json_build_object(
	    'DdoCode', v_ddo_code,
		'DdoGstIn', v_ddo_gstin,
	    'Designation', v_designation,
	    'Office', v_office,
		'StartingDate', TO_CHAR(v_start_date, 'dd/mm/yyyy'),
        'EndingDate', TO_CHAR(v_end_date, 'dd/mm/yyyy'),
	    'SGSTEmployees', json_agg(
	        json_build_object(
	            'EmployeeName', emp_data.vendorname,
	            'GSTIN', emp_data.vendorgstin,
	            'InvoiceNo', emp_data.invoiceno,
		        'InvoiceDate', TO_CHAR(emp_data.invoicedate, 'dd/mm/yyyy'),
				'InvoiceAmt', emp_data.invoicevalue,
				'SGST', emp_data.amountpart1,
				'CGST', emp_data.amountpart2,
				'Total', emp_data.total,
				'PaymentDate', COALESCE(TO_CHAR(emp_data.payment_date, 'dd/mm/yyyy'), 'NA'),
				'VoucherNo', emp_data.voucher_no,
				'VoucherDate', TO_CHAR(emp_data.voucher_date, 'dd/mm/yyyy'),
				'Cpin', emp_data.cpin,
				'CpinType', emp_data.cpin_type
	        )
	    ) FILTER (WHERE cpin_type = 1),
		'IGSTEmployees', json_agg(
	        json_build_object(
	            'EmployeeName', emp_data.vendorname,
	            'GSTIN', emp_data.vendorgstin,
	            'InvoiceNo', emp_data.invoiceno,
		        'InvoiceDate', TO_CHAR(emp_data.invoicedate, 'dd/mm/yyyy'),
				'InvoiceAmt', emp_data.invoicevalue,
				'IGST', emp_data.amountpart1,
				'Total', emp_data.total,
				'PaymentDate', TO_CHAR(emp_data.payment_date, 'dd/mm/yyyy'),
				'VoucherNo', emp_data.voucher_no,
				'VoucherDate', TO_CHAR(emp_data.voucher_date, 'dd/mm/yyyy'),
				'Cpin', emp_data.cpin,
				'CpinType', emp_data.cpin_type
	        )
	    ) FILTER (WHERE cpin_type = 2)
	) INTO out_payload
	FROM (
	    SELECT DISTINCT
	        cvm.vendorname AS vendorname,
	        cvm.vendorgstin AS vendorgstin,
	        cvm.invoiceno AS invoiceno,
	        cvm.invoicedate AS invoicedate,
			cvm.invoicevalue AS invoicevalue,
			cvm.amountpart1 AS amountpart1,
			cvm.amountpart2 AS amountpart2,
			cvm.total AS total,
			stb.accepted_date_time As payment_date,
			v.voucher_no AS voucher_no,
			v.voucher_date AS voucher_date,
			cm.cpin_id AS cpin,
			cm.cpin_type AS cpin_type
	    FROM billing.bill_details bd
	    JOIN billing.bill_subdetail_info billsub ON billsub.bill_id = bd.bill_id
	    JOIN master.active_hoa_mst hoa ON hoa.id = billsub.active_hoa_id
		JOIN billing.bill_ecs_neft_details ecs ON ecs.bill_id = bd.bill_id
	    JOIN billing.bill_gst gst ON gst.bill_id = bd.bill_id
		JOIN billing_master.cpin_master cm ON cm.id = gst.cpin_id
		JOIN billing_master.cpin_vender_mst cvm ON gst.cpin_id = cvm.cpinmstid
		LEFT JOIN cts.success_transaction_beneficiary stb ON ecs.id = stb.ecs_id
		JOIN cts.voucher v ON v.bill_id = ecs.bill_id
	    WHERE bd.ddo_code = (in_payload->>'DdoCode')
	        AND (
	            v.voucher_date BETWEEN v_start_date AND v_end_date
	        )
			AND bd.is_cancelled = false
			AND ecs.is_gst = false
			AND gst.is_deleted = false
	) AS emp_data;

	-- Check if data exists
    IF out_payload IS NULL OR out_payload = '{}' THEN
        is_done := FALSE;
        message_out := 'Data not found.';
        out_payload := '{}';
        RETURN;
    END IF;

    -- Set success
    is_done := TRUE;
    message_out := 'Data generated successfully.';

EXCEPTION
    WHEN OTHERS THEN
        is_done := FALSE;
        message_out := SQLERRM;
        out_payload := '{}';
END;
$$;


ALTER PROCEDURE billing.get_tds_on_gst_details_report(IN in_payload jsonb, OUT is_done boolean, OUT message_out text, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 427 (class 1255 OID 920208)
-- Name: insert_bill_allotment_details(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_bill_allotment_details(IN bill_allotment_details_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    _financial_year_id smallint;
BEGIN
    -- Fetch active financial year ID
    SELECT id INTO _financial_year_id 
    FROM master.financial_year_master 
    WHERE is_active = true 
    LIMIT 1;
    
    -- Update existing records
    UPDATE bantan.ddo_allotment_transactions AS d
    SET 
        transaction_id = (item->>'transaction_id')::bigint,
        sanction_id = (item->>'sanction_id')::bigint,
        memo_number = item->>'memo_number',
        memo_date = (item->>'memo_date')::date,
        from_allotment_id = (item->>'from_allotment_id')::bigint,
        financial_year = _financial_year_id,
        sender_user_type = (item->>'sender_user_type')::smallint,
        sender_sao_ddo_code = item->>'sender_sao_ddo_code',
        receiver_user_type = (item->>'receiver_user_type')::smallint,
        receiver_sao_ddo_code = item->>'receiver_sao_ddo_code',
        dept_code = item->>'dept_code',
        demand_no = item->>'demand_no',
        major_head = item->>'major_head',
        submajor_head = item->>'submajor_head',
        minor_head = item->>'minor_head',
        plan_status = item->>'plan_status',
        scheme_head = item->>'scheme_head',
        detail_head = item->>'detail_head',
        subdetail_head = item->>'subdetail_head',
        voted_charged = item->>'voted_charged',
        budget_alloted_amount = (item->>'budget_alloted_amount')::bigint,
        reappropriated_amount = (item->>'reappropriated_amount')::bigint,
        augment_amount = (item->>'augment_amount')::bigint,
        surrender_amount = (item->>'surrender_amount')::bigint,
        revised_amount = (item->>'revised_amount')::bigint,
        ceiling_amount = (item->>'ceiling_amount')::bigint,
        provisional_released_amount = (item->>'provisional_released_amount')::bigint,
        actual_released_amount = (item->>'actual_released_amount')::numeric,
        updated_at = NOW(),
        updated_by_userid = (item->>'updated_by_userid')::bigint,
        treasury_code = item->>'treasury_code',
        map_type = (item->>'map_type')::smallint,
        sanction_type = (item->>'sanction_type')::smallint,
        status = (item->>'status')::smallint,
        allotment_date = (item->>'allotment_date')::date,
        remarks = item->>'remarks',
        uo_id = (item->>'uo_id')::bigint
    FROM jsonb_array_elements(bill_allotment_details_payload) AS item
    WHERE d.allotment_id = (item->>'allotment_id')::bigint;

    -- Insert new records if they don’t exist
    INSERT INTO bantan.ddo_allotment_transactions (
        transaction_id, sanction_id, memo_number, memo_date, from_allotment_id, 
        financial_year, sender_user_type, sender_sao_ddo_code, receiver_user_type, 
        receiver_sao_ddo_code, dept_code, demand_no, major_head, submajor_head, 
        minor_head, plan_status, scheme_head, detail_head, subdetail_head, 
        voted_charged, budget_alloted_amount, reappropriated_amount, augment_amount, 
        surrender_amount, revised_amount, ceiling_amount, provisional_released_amount, 
        actual_released_amount, map_type, sanction_type, status, allotment_date, 
        remarks, created_by_userid, created_at, updated_by_userid, updated_at, 
        active_hoa_id, treasury_code, grant_in_aid_type, is_send, uo_id
    )
    SELECT 
        (item->>'transaction_id')::bigint,
        (item->>'sanction_id')::bigint,
        item->>'memo_number',
        (item->>'memo_date')::date,
        (item->>'from_allotment_id')::bigint,
        _financial_year_id,
        (item->>'sender_user_type')::smallint,
        item->>'sender_sao_ddo_code',
        (item->>'receiver_user_type')::smallint,
        item->>'receiver_sao_ddo_code',
        item->>'dept_code',
        item->>'demand_no',
        item->>'major_head',
        item->>'submajor_head',
        item->>'minor_head',
        item->>'plan_status',
        item->>'scheme_head',
        item->>'detail_head',
        item->>'subdetail_head',
        item->>'voted_charged',
        (item->>'budget_alloted_amount')::bigint,
        (item->>'reappropriated_amount')::bigint,
        (item->>'augment_amount')::bigint,
        (item->>'surrender_amount')::bigint,
        (item->>'revised_amount')::bigint,
        (item->>'ceiling_amount')::bigint,
        (item->>'provisional_released_amount')::bigint,
        (item->>'actual_released_amount')::numeric,
        (item->>'map_type')::smallint,
        (item->>'sanction_type')::smallint,
        (item->>'status')::smallint,
        (item->>'allotment_date')::date,
        item->>'remarks',
        (item->>'created_by_userid')::bigint,
        NOW(),
        NULL,
        NULL,
        (item->>'active_hoa_id')::bigint,
        item->>'treasury_code',
        NULL,
        TRUE,
        (item->>'uo_id')::bigint
    FROM jsonb_array_elements(bill_allotment_details_payload) AS item
    WHERE NOT EXISTS (
        SELECT 1 FROM bantan.ddo_allotment_transactions d
        WHERE d.allotment_id = (item->>'allotment_id')::bigint
    );

    -- Insert or update the ddo_wallet table
    INSERT INTO bantan.ddo_wallet (
     sao_ddo_code, dept_code, demand_no, major_head, submajor_head, minor_head, 
     plan_status, scheme_head, detail_head, subdetail_head, voted_charged, 
     budget_alloted_amount, reappropriated_amount, augment_amount, surrender_amount, 
     revised_amount, ceiling_amount, provisional_released_amount, actual_released_amount, 
     created_at, created_by, updated_at, updated_by, active_hoa_id, 
     treasury_code, financial_year, is_active
 )
 SELECT 
     item->>'receiver_sao_ddo_code',
     item->>'dept_code',
     item->>'demand_no',
     item->>'major_head',
     item->>'submajor_head',
     item->>'minor_head',
     item->>'plan_status',
     item->>'scheme_head',
     item->>'detail_head',
     item->>'subdetail_head',
     item->>'voted_charged',
     (item->>'budget_alloted_amount')::bigint,
     (item->>'reappropriated_amount')::bigint,
     (item->>'augment_amount')::bigint,
     (item->>'surrender_amount')::bigint,
     (item->>'revised_amount')::bigint,
     (item->>'ceiling_amount')::bigint,
     (item->>'provisional_released_amount')::bigint,
     (item->>'actual_released_amount')::numeric,
     NOW(),
     (item->>'created_by_userid')::integer,
     NULL,
     NULL,
     (item->>'active_hoa_id')::bigint,
     item->>'treasury_code',
     _financial_year_id,
     TRUE
 FROM jsonb_array_elements(bill_allotment_details_payload) AS item

 WHERE NOT EXISTS (
     SELECT 1 FROM bantan.ddo_wallet d
     WHERE d.sao_ddo_code = item->>'receiver_sao_ddo_code'
     AND d.active_hoa_id = (item->>'active_hoa_id')::bigint
 );

 -- Update existing records separately
 UPDATE bantan.ddo_wallet w
SET 
    budget_alloted_amount = st.budget_alloted_amount,
    reappropriated_amount = st.reappropriated_amount,
    augment_amount = st.augment_amount,
    surrender_amount = st.surrender_amount,
    revised_amount = st.revised_amount,
    ceiling_amount = st.ceiling_amount,
    provisional_released_amount = st.provisional_released_amount,
    actual_released_amount = st.actual_released_amount,
    updated_at = NOW(),
    updated_by = (item->>'created_by_userid')::integer
FROM jsonb_array_elements(bill_allotment_details_payload) AS item
LEFT JOIN (
    SELECT 
        receiver_sao_ddo_code, 
        active_hoa_id,
        SUM(budget_alloted_amount) AS budget_alloted_amount,
        SUM(reappropriated_amount) AS reappropriated_amount,
        SUM(augment_amount) AS augment_amount,
        SUM(surrender_amount) AS surrender_amount,
        SUM(revised_amount) AS revised_amount,
        SUM(ceiling_amount) AS ceiling_amount,
        SUM(provisional_released_amount) AS provisional_released_amount,
        SUM(actual_released_amount) AS actual_released_amount
    FROM bantan.ddo_allotment_transactions
    GROUP BY receiver_sao_ddo_code, active_hoa_id
) st 
ON st.receiver_sao_ddo_code = item->>'receiver_sao_ddo_code'
AND st.active_hoa_id = (item->>'active_hoa_id')::bigint
WHERE w.sao_ddo_code = item->>'receiver_sao_ddo_code'
AND w.active_hoa_id = (item->>'active_hoa_id')::bigint;
		
END;
$$;


ALTER PROCEDURE billing.insert_bill_allotment_details(IN bill_allotment_details_payload jsonb) OWNER TO postgres;

--
-- TOC entry 503 (class 1255 OID 920210)
-- Name: insert_bill_status_details(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_bill_status_details(IN bill_status_details_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    existing_record billing.bill_status_info%ROWTYPE;
	jit_ref_bill_status jsonb;
BEGIN
	
      -- Check if record already exists
    SELECT * INTO existing_record
    FROM billing.bill_status_info
    WHERE billing.bill_status_info.bill_id = (bill_status_details_payload->>'BillId')::bigint
    AND billing.bill_status_info.status_id = (bill_status_details_payload->>'StatusId')::smallint;

    IF FOUND THEN
        -- Update existing record if found
        UPDATE billing.bill_status_info
        SET 
            created_by = (bill_status_details_payload->>'UserId')::bigint, 
            created_at = (bill_status_details_payload->>'Time')::timestamp without time zone
        WHERE billing.bill_status_info.bill_id = (bill_status_details_payload->>'BillId')::bigint
        AND billing.bill_status_info.status_id = (bill_status_details_payload->>'StatusId')::smallint;
    ELSE
        -- Insert new record if not found
        INSERT INTO billing.bill_status_info(
            bill_id, status_id, created_by, created_at)
        VALUES (
            (bill_status_details_payload->>'BillId')::bigint, 
            (bill_status_details_payload->>'StatusId')::smallint,
            (bill_status_details_payload->>'UserId')::bigint, 
            (bill_status_details_payload->>'Time')::timestamp without time zone
        );
    END IF;
END;
$$;


ALTER PROCEDURE billing.insert_bill_status_details(IN bill_status_details_payload jsonb) OWNER TO postgres;

--
-- TOC entry 441 (class 1255 OID 920211)
-- Name: insert_cpin_ecs(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.insert_cpin_ecs() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	WITH rbi_details AS(
		SELECT id, ifsc, name, bank_name, remitting_bank
		FROM billing_master.rbi_gst_master where is_active = true
	)
	INSERT INTO billing.bill_ecs_neft_details( bill_id, payee_name, ifsc_code, bank_account_number, bank_name, amount, financial_year, is_gst)
	SELECT NEW.bill_id, rbi_details.name, rbi_details.ifsc, cpin.cpin_id, rbi_details.bank_name, cpin.cpin_amount,cpin.financial_year,true         
	FROM billing_master.cpin_master as cpin, rbi_details where cpin.id=NEW.cpin_id;
    
    RETURN NULL;
END;
$$;


ALTER FUNCTION billing.insert_cpin_ecs() OWNER TO postgres;

--
-- TOC entry 449 (class 1255 OID 920212)
-- Name: insert_cpin_failed_bill(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_cpin_failed_bill(IN cpin_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying)
    LANGUAGE plpgsql
    AS $$
Declare 
    _bill_id bigint;
    _tmp_ref_no character varying;
    _form_version smallint;
    _ddo_code character(9);
    new_cpin_id bigint;
    _ddo_gst_in character varying;
    _tr_master_id smallint; 
    _bill_no bigint;
    _application_type character varying;
    _financial_year_id smallint;
    _current_month integer;
	v_old_cpin_id bigint;
	v_vendor_ben_ref_id bigint;
	v_invoice_no text;
	v_vendor_gst_in character varying;
	v_old_bill_id bigint;
	cpin_detail jsonb;
	_already_mapped_count bigint;
	_already_mapped_list text[];
BEGIN
    _application_type = '01';  ----- FOR JIT BILL ---------

	WITH resolved_cpin_ids AS (
	  SELECT c.id AS old_cpin_id
	  FROM billing_master.cpin_master c
	  WHERE c.cpin_id = ANY (
		        SELECT jsonb_array_elements_text(cpin_details_payload->'OldCpinIds')
		    )
			AND c.is_active = false
	),
	already_mapped_vendors AS (
	  SELECT g.id, g.old_cpin_id, g.payee_name, g.invoice_no, g.payee_gst_in
	  FROM resolved_cpin_ids r
	  JOIN jit.gst g ON g.old_cpin_id = r.old_cpin_id
	  WHERE g.is_regenerated = true
	)
	SELECT COUNT(1), 
	       array_agg(format('Vendor Name: %s, Invoice: %s, Vendor Gst In: %s is already generated.',
	                        payee_name, invoice_no, payee_gst_in))
	INTO _already_mapped_count, _already_mapped_list
	FROM already_mapped_vendors;
	
	-- Step 2: Raise exception if any vendor is already mapped
	IF _already_mapped_count > 0 THEN
	  RAISE EXCEPTION 'The following vendors are already mapped: %', _already_mapped_list;
	ELSE
	    
	   SELECT  id into _financial_year_id
	   from master.financial_year_master where is_active=true;
	   
	    -- Get Month from Current Date	
	    SELECT EXTRACT(MONTH FROM CURRENT_DATE) INTO _current_month;
		
	    -- GET Bill Id from sequence     
	    EXECUTE format('SELECT nextval(%L)', 'billing.bill_details_bill_id_seq') INTO _bill_id;
	    
	    -- GET Bill No from sequence     
	    EXECUTE format('SELECT nextval(%L)', 'billing.sys_generated_bill_no_seq') INTO _bill_no;
	    
	    -- Generate REFERENCENO
	    _tmp_ref_no := _financial_year_id || LPAD(_current_month::text, 2, '0') || LPAD(_bill_id::text, 7, '0');
	    _form_version := 1;

		---- Update map table is_active column false for old bill_id
		UPDATE billing.ebill_jit_int_map maps
		SET is_active = false
		WHERE bill_id = ANY (
	                  SELECT value::bigint 
	                  FROM jsonb_array_elements(cpin_details_payload->'BillIds')
	                  );
	    -- STEP 1. INSERT Common Bill Details INTO BillDetails from JSON to Bill Table
	    WITH Fto_Detail AS(
	        select h.id, h.demand_no, h.major_head, h.submajor_head, h.minor_head, 
	        h.plan_status, h.scheme_head, h.detail_head, h.subdetail_head, 
	        h.voted_charged, t.sls_code, t.scheme_name, t.ddo_code, t.treas_code, t.is_reissue, t.is_top_up,
	        CASE 
	                WHEN (t.is_reissue = false AND t.is_top_up = false) THEN 0
	                WHEN (t.is_reissue = true AND t.is_top_up = false) THEN 1
	                WHEN (t.is_reissue = false AND t.is_top_up = true) THEN 2
	                WHEN (t.is_reissue = true AND t.is_top_up = true) THEN 3
	            END AS fto_type
	        from (select hoa_id, is_reissue, is_top_up,treas_code, ddo_code, sls_code, scheme_name
			from jit.tsa_exp_details 
	        where ref_no = ANY(SELECT jit_ref_no FROM billing.ebill_jit_int_map
	        where bill_id = ANY (
	                  SELECT value::bigint 
	                  FROM jsonb_array_elements(cpin_details_payload->'BillIds')
	                  )) group by hoa_id,is_reissue, is_top_up, treas_code,
					  ddo_code, sls_code, scheme_name) t, 
	        master.active_hoa_mst h where t.hoa_id = h.id and h.isactive = true
	    ),
		amount_details AS(
		SELECT 
				SUM(CASE WHEN(c.is_gst <> true) then b.gross_amount else c.amount END ) AS gross_amount ,
				SUM(a.gst_amount) AS gst_amount			
			FROM billing.bill_details a
			JOIN billing.bill_ecs_neft_details c
				ON a.bill_id = c.bill_id
			LEFT JOIN billing.jit_ecs_additional b
				ON c.id = b.ecs_id
			WHERE c.bank_account_number = ANY (
				SELECT *
				FROM jsonb_array_elements_text(cpin_details_payload->'OldCpinIds')
			)
		),
	    INSERT_Bill_DETAILS AS(
	        -- STEP 1. INSERT Common Bill Details INTO BillDetails from JSON to Bill Table
	        INSERT INTO billing.bill_details(
	            bill_id, bill_no, bill_date, bill_mode, reference_no, tr_master_id, 
	            payment_mode, financial_year, demand, major_head, sub_major_head, 
	            minor_head, plan_status, scheme_head, detail_head, voted_charged, 
	            gross_amount, net_amount, gst_amount, sanction_no, sanction_amt, 
	            sanction_date, sanction_by, remarks, ddo_code, treasury_code, is_gem, 
	            status, created_by_userid, form_version, sna_grant_type, css_ben_type,
	            aafs_project_id, scheme_code, scheme_name, bill_type, is_gst)
	        (SELECT _bill_id, (_application_type || h.fto_type || LPAD(_bill_no::text, 8, '0')),(cpin_details_payload->>'BillDate')::date, 1,_tmp_ref_no, 29, 1, _financial_year_id, 
			h.demand_no, h.major_head, h.submajor_head, h.minor_head, h.plan_status, 
			h.scheme_head, h.detail_head, h.voted_charged, a.gross_amount, 
			(a.gross_amount - a.gst_amount), a.gst_amount, (cpin_details_payload->>'SanctionNo'), 
			(cpin_details_payload->>'SanctionAmount')::bigint, 
			NULLIF(cpin_details_payload->>'SanctionDate', '')::date,
			(cpin_details_payload->>'SanctionBy')::character varying,
			(cpin_details_payload->>'Remarks')::character varying, h.ddo_code, h.treas_code,
	         false, (cpin_details_payload->>'Status')::smallint, 
			 (cpin_details_payload->>'CreatedByUserid')::bigint, _form_version,
			 1, 1, null, h.sls_code,h.scheme_name,'CPIN-REISSUE', true
	        FROM Fto_Detail h, amount_details a)
	        RETURNING bill_id
	    )
	    --STEP 2. INSERT SUBDetail into Table  
	    INSERT INTO billing.bill_subdetail_info(
	        bill_id, active_hoa_id, amount, status, created_by_userid, financial_year,ddo_code, treasury_code)
	    SELECT _bill_id, h.id, a.gst_amount, (cpin_details_payload->>'Status')::smallint,
	    (cpin_details_payload->>'CreatedByUserid')::bigint, _financial_year_id, h.ddo_code, h.treas_code
	    FROM Fto_Detail h, amount_details a;
		
		------------ Insert Map table data ---------------		
		WITH bill_details AS(
			SELECT gst.ref_no
			FROM jit.gst gst
			WHERE gst.bill_id = ANY (SELECT value::bigint FROM 
		            jsonb_array_elements(cpin_details_payload->'BillIds'))
			GROUP BY gst.ref_no
		)
		INSERT INTO billing.ebill_jit_int_map (ebill_ref_no, jit_ref_no, bill_id, financial_year)
		SELECT _tmp_ref_no, bd.ref_no, _bill_id, _financial_year_id
		FROM bill_details bd;

	    -- Get Bill Reference No and Bill Id 
	    _out_ref_no:= CONCAT(_tmp_ref_no,'-',_form_version);
	    inserted_id = _bill_id;
	   
	    --insert into bill status info table
	    INSERT INTO billing.bill_status_info(
	        bill_id, status_id, created_by, created_at)
	        VALUES (
	            _bill_id, (cpin_details_payload->>'Status')::smallint,
	           (cpin_details_payload->>'CreatedByUserid')::bigint, now()
	        );

		 ---- Insert tr_26a details
		INSERT INTO billing.tr_26a_detail(bill_id, bill_mode, tr_master_id, is_scheduled, 
		total_amt_for_cs_calc_sc, 
		total_amt_for_cs_calc_scoc, total_amt_for_cs_calc_st,
		total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_ot,
		total_amt_for_cs_calc_otoc, hoa_id, voucher_details_object, category_code)
		SELECT _bill_id,
				0, --
				29, -- 29 for TR26a
				false,
				total_amt_for_cs_calc_sc, 
				total_amt_for_cs_calc_scoc, total_amt_for_cs_calc_st, 
				total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_ot, 
				total_amt_for_cs_calc_otoc, hoa_id,voucher_dtl.voucher,category_code
		FROM 
		(select 
			COALESCE(CASE 
				WHEN tr.category_code = 'SC' 
				THEN sum(ftb.failed_transaction_amount) 
			END, 0) as total_amt_for_cs_calc_sc, 
			COALESCE(CASE 
				WHEN tr.category_code = 'SC' 
				THEN sum(ftb.failed_transaction_amount) 
			END, 0) as total_amt_for_cs_calc_scoc,
			COALESCE(CASE 
				WHEN tr.category_code = 'ST' 
				THEN COALESCE(sum(ftb.failed_transaction_amount),0) 
			END, 0) as total_amt_for_cs_calc_st, 
			COALESCE(CASE 
				WHEN tr.category_code = 'ST' 
				THEN COALESCE(sum(ftb.failed_transaction_amount),0) 
			END, 0) as total_amt_for_cs_calc_stoc,
			COALESCE(CASE 
				WHEN tr.category_code = 'OT' 
				THEN COALESCE(sum(ftb.failed_transaction_amount), 0)
			END, 0) as total_amt_for_cs_calc_ot, 
			COALESCE(CASE 
				WHEN tr.category_code = 'OT' 
				THEN sum(ftb.failed_transaction_amount)
			END, 0) as total_amt_for_cs_calc_otoc, hoa_id, category_code
		from billing.tr_26a_detail tr
		join cts.failed_transaction_beneficiary ftb
		on ftb.bill_id = tr.bill_id
		WHERE ftb.bill_id = ANY (SELECT value::bigint 
	                  FROM jsonb_array_elements(cpin_details_payload->'BillIds')) 
		group by category_code, hoa_id) tr , (select jsonb_agg(
	jsonb_build_object( 'VoucherNo',cancel_certificate_no,'VoucherDate',cancel_certificate_date,
	'DescCharges','Cancellation Certificate','Authority','ETreasury',
	'Amount',(failed_transaction_amount::NUMERIC::BigInt))) as voucher
	from cts.failed_transaction_beneficiary
	where is_active=1
	and bill_id = ANY (SELECT value::bigint 
	                  FROM jsonb_array_elements(cpin_details_payload->'BillIds')))as voucher_dtl;
	    
	    -- Get DDO code and TR master ID
	    SELECT ddo_code, tr_master_id into _ddo_code, _tr_master_id
	    from billing.bill_details
	    where bill_id = ANY (
	              SELECT value::bigint 
	              FROM jsonb_array_elements(cpin_details_payload->'BillIds')
	              )
	    group by ddo_code, tr_master_id;
	
	    -- Get DDO GSTIN
	    SELECT gstin INTO _ddo_gst_in
	    FROM master.ddo 
	    WHERE ddo_code = _ddo_code;
	
	    -- Insert into cpin_master and retrieve the new CPIN ID (separate from CTE)
	    INSERT INTO billing_master.cpin_master (
	        cpin_id,
	        cpin_amount,
	        cpin_date,
			cpin_type,
	        created_by_userid,
	        created_at,
	        vendor_data,
			financial_year
	    )
	    SELECT
	        gst_item->>'CpinId',
	        (gst_item->>'CpinAmount')::numeric::bigint,
	        (gst_item->>'CpinDate')::date,
			(gst_item->>'CpinType')::smallint,
	        (cpin_details_payload->>'CreatedByUserid')::bigint,
	        now(),
	        (gst_item->>'VendorData')::jsonb,
			_financial_year_id
	    FROM
	        jsonb_array_elements(cpin_details_payload->'CpinDetails') AS gst_item
	    RETURNING id INTO new_cpin_id;
	
	    -- Insert vendor details
	    INSERT INTO billing_master.cpin_vender_mst (
	        cpinmstid,
	        vendorname,
	        vendorgstin,
	        invoiceno,
	        invoicedate,
	        invoicevalue,
	        amountpart1,
	        amountpart2,
	        total,
			ben_ref_id,
	        created_by_userid,
	        created_at
	    )
	    SELECT
	        new_cpin_id,
	        vendor_item->>'VendorName',
	        vendor_item->>'VendorGstIn',
	        vendor_item->>'InvoiceNo',
	        (vendor_item->>'InvoiceDate')::timestamp without time zone,
	        (vendor_item->>'InvoiceValue')::DOUBLE PRECISION,
	        (vendor_item->>'AmountPart1')::DOUBLE PRECISION,
	        (vendor_item->>'AmountPart2')::DOUBLE PRECISION,
	        (vendor_item->>'Total')::DOUBLE PRECISION,
			(vendor_item->>'BenRefId')::bigint,
	        (cpin_details_payload->>'CreatedByUserid')::bigint,
	        now()
	    FROM
	        jsonb_array_elements(cpin_details_payload->'CpinDetails') AS gst_item,
	        jsonb_array_elements(gst_item->'VendorData') AS vendor_item;
	
	    -- Insert into bill_gst with the new CPIN ID
	    INSERT INTO billing.bill_gst (
	        bill_id,
	        cpin_id,
	        ddo_code,
	        created_at,
	        tr_id,
	        ddo_gstn,
			created_by_userid,
			financial_year
	    )
	    SELECT
	        inserted_id,
	        new_cpin_id,
	        _ddo_code,
	        now(),
	        _tr_master_id,
	        _ddo_gst_in,
			(cpin_details_payload->>'CreatedByUserid')::bigint,
			_financial_year_id
	    FROM
	        jsonb_array_elements(cpin_details_payload->'CpinDetails') AS gst_item;
	
			----------- Get GST Vendors record -------------
	
			WITH vendor_data AS (
			  SELECT 
			    gst.payee_id AS ben_ref_id,
			    gst.bill_id,
			    cpin.id AS cpin_mstid,
			    gst.cpin_id as cpin_id,
			    vendor.invoiceno,
			    vendor.vendorgstin
			  FROM billing_master.cpin_master AS cpin
			  JOIN billing.bill_ecs_neft_details AS ecs
			  	ON cpin.cpin_id = ecs.bank_account_number
			  JOIN cts.failed_transaction_beneficiary failed_ben
			  	ON failed_ben.account_no = ecs.bank_account_number
			  JOIN billing_master.cpin_vender_mst AS vendor
			  	ON cpin.id = vendor.cpinmstid
			  JOIN jit.gst AS gst ON gst.cpin_id = cpin.id
			  WHERE ecs.is_gst = true
			  	-- AND gst.is_regenerated = false
			    AND failed_ben.account_no::text = ANY (
			        SELECT jsonb_array_elements_text(cpin_details_payload->'OldCpinIds')
			    )
			)
			UPDATE jit.gst
			SET 
			  is_mapped = true,
			  is_regenerated = true,
			  cpin_id = new_cpin_id,
			  bill_id = inserted_id,
			  old_cpin_id = vendor_data.cpin_id,
			  old_bill_id = vendor_data.bill_id,
			  updated_at = now(),
			  updated_by = (cpin_details_payload->>'CreatedByUserid')::bigint
			FROM vendor_data
			WHERE 
			  jit.gst.payee_id = vendor_data.ben_ref_id
			  AND jit.gst.invoice_no = vendor_data.invoiceno
			  AND jit.gst.payee_gst_in = vendor_data.vendorgstin;
			  -- AND jit.gst.is_regenerated = false;
	
	    -- Update cpin_master, failed_transaction_beneficiary deactivate the Old CPIN
	
			UPDATE billing_master.cpin_master 
			SET is_active = false
			WHERE cpin_id = ANY (
				SELECT *
				FROM jsonb_array_elements_text(cpin_details_payload->'OldCpinIds')
			);
	
			-- -- UPDATE billing.bill_ecs_neft_details
			-- -- SET old_gst_end_to_end_id = (cpin_details_payload->'OldCpinIds')::jsonb
			-- -- WHERE bill_id = inserted_id;
			
			UPDATE cts.failed_transaction_beneficiary
			SET is_corrected = true,
			gst_bill_id = inserted_id,
			corrected_at = now(), 
			corrected_by = (cpin_details_payload->>'CreatedByUserid')::bigint
			WHERE account_no = ANY (
				SELECT *
				FROM jsonb_array_elements_text(cpin_details_payload->'OldCpinIds')
			);
		END IF;
END;
$$;


ALTER PROCEDURE billing.insert_cpin_failed_bill(IN cpin_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying) OWNER TO postgres;

--
-- TOC entry 433 (class 1255 OID 920214)
-- Name: insert_cpin_failed_bill_old(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_cpin_failed_bill_old(IN cpin_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying)
    LANGUAGE plpgsql
    AS $$
Declare 
    _bill_id bigint;
 	_tmp_ref_no character varying;
    _form_version smallint;
    _ddo_code character(9);
	new_cpin_id bigint;
	_ddo_gst_in character varying;
    _tr_master_id smallint; 
	_bill_no bigint;
	_application_type character varying;
BEGIN
	_application_type = '01';  ----- FOR JIT BILL ---------
	
	-- GET Bill Id from sequence     
	EXECUTE format('SELECT nextval(%L)', 'billing.bill_details_bill_id_seq') INTO _bill_id;
	
	-- GET Bill No from sequence     
	EXECUTE format('SELECT nextval(%L)', 'billing.sys_generated_bill_no_seq') INTO _bill_no;
	
	-- Generate REFERENCENO
	
	IF (cpin_details_payload->>'BillId')::bigint IS NOT NULL THEN
		SELECT form_version, reference_no into
		_form_version, _tmp_ref_no 
		from billing.bill_details where bill_id = (cpin_details_payload->>'BillId')::bigint;
		--Need to update version +1 not static 2
		_form_version := _form_version + 1;
	END IF;
 
	-- STEP 1. INSERT Common Bill Deatils INTO BillDetails from JSON to Bill Table
	WITH Fto_Detail AS(
		select t.is_reissue, t.is_top_up,
		CASE 
				WHEN (t.is_reissue = false AND t.is_top_up = false) THEN 0
				WHEN (t.is_reissue = true AND t.is_top_up = false) THEN 1
				WHEN (t.is_reissue = false AND t.is_top_up = true) THEN 2
				WHEN (t.is_reissue = true AND t.is_top_up = true) THEN 3
			END AS fto_type
		from 
		billing.ebill_jit_int_map m join jit.tsa_exp_details t
		on t.ref_no = m.jit_ref_no
		where m.bill_id = (cpin_details_payload->>'BillId')::bigint
		group by t.is_reissue, t.is_top_up
	),
	Bill_Detail AS(
			select h.bill_id, h.bill_no, h.bill_date, h.bill_mode, h.reference_no,h.tr_master_id, h.payment_mode, h.demand, h.major_head, h.sub_major_head,
			 h.minor_head, h.plan_status, h.scheme_head, h.detail_head, h.voted_charged, h.gst_amount, h.sanction_no,
			 h.sanction_amt, h.sanction_date, h.sanction_by, h.remarks, h.ddo_code, h.treasury_code, h.is_gem, h.created_by_userid, h.scheme_code, h.scheme_name, h.financial_year
			from billing.bill_details h
		where h.bill_id = (cpin_details_payload->>'BillId')::bigint
	),
	 Bill_Sub_Detail AS(
			select sub.active_hoa_id
			from billing.bill_subdetail_info sub
		where sub.bill_id = (cpin_details_payload->>'BillId')::bigint
	),
	INSERT_Bill_DETAILS AS(
		-- STEP 1. INSERT Common Bill Deatils INTO BillDetails from JSON to Bill Table
		INSERT INTO billing.bill_details(
			bill_id, bill_no, bill_date, bill_mode, reference_no, tr_master_id, payment_mode, financial_year, 
			demand, major_head, sub_major_head, minor_head, plan_status, scheme_head, detail_head, voted_charged, 
			gross_amount, net_amount, gst_amount, sanction_no, sanction_amt, sanction_date, sanction_by, 
			remarks, ddo_code, treasury_code, is_gem, status, created_by_userid,form_version,sna_grant_type,css_ben_type,
			aafs_project_id, scheme_code, scheme_name, bill_type)
		(SELECT _bill_id, (_application_type || t.fto_type || LPAD(_bill_no::text, 8, '0')),h.bill_date, h.bill_mode,_tmp_ref_no,h.tr_master_id, h.payment_mode, h.financial_year, h.demand, h.major_head, h.sub_major_head,
		 h.minor_head, h.plan_status, h.scheme_head, h.detail_head, h.voted_charged, h.gst_amount, h.gst_amount,
		 h.gst_amount, h.sanction_no, h.sanction_amt, h.sanction_date, h.sanction_by, h.remarks, h.ddo_code, h.treasury_code,
		 h.is_gem, 2, h.created_by_userid, _form_version, 1, 1, null, h.scheme_code,h.scheme_name,'CPIN-REISSUE'
		FROM Bill_Detail h, Fto_Detail t
		WHERE h.bill_id = (cpin_details_payload->>'BillId')::bigint)
		returning bill_id
	)
		--STEP 2. INSERT SUBDetail into Table  
		INSERT INTO billing.bill_subdetail_info(
			bill_id, active_hoa_id, amount, status, created_by_userid, financial_year,ddo_code, treasury_code)

		SELECT _bill_id, sub.active_hoa_id, h.gst_amount, 2,
		(cpin_details_payload->>'CreatedByUserid')::bigint,h.financial_year,h.ddo_code, h.treasury_code
		FROM
		Bill_Detail h, Bill_Sub_Detail sub;
  
	  -- Get Bill Reference No and Bill Id 
		_out_ref_no:= CONCAT(_tmp_ref_no,'-',_form_version);
		inserted_id = _bill_id;
   
    --insert into bill status info table
    INSERT INTO billing.bill_status_info(
		bill_id, status_id, created_by, created_at)
        VALUES (
            _bill_id, 2,
		   (cpin_details_payload->>'CreatedByUserid')::bigint, now()
        );
		
		SELECT ddo_code, tr_master_id into _ddo_code, _tr_master_id from billing.bill_details
		where bill_id = (cpin_details_payload->>'BillId')::bigint;
				
		SELECT gstin into _ddo_gst_in
		FROM master.ddo 
		WHERE ddo_code = _ddo_code;

		-- Insert into cpin_master and retrieve the new CPIN ID
		INSERT INTO billing_master.cpin_master (
			cpin_id,
			cpin_amount,
			cpin_date,
			created_by_userid,
			created_at,
			vendor_data
		)
		SELECT
			gst_item->>'Cpin',
			(gst_item->>'CpinAmount')::numeric::bigint,
			(gst_item->>'CpinRegDate')::date,
			(cpin_details_payload->>'CreatedByUserid')::bigint,
			now(),
			(gst_item->>'VendorDetails')::jsonb
		FROM
			jsonb_array_elements(cpin_details_payload->'GstDetails') AS gst_item
		RETURNING id INTO new_cpin_id;

		INSERT INTO billing_master.cpin_vender_mst (
			cpinmstid,
			vendorname,
			vendorgstin,
			invoiceno,
			invoicedate,
			invoicevalue,
			amountpart1,
			amountpart2,
			total,
			created_by_userid,
			created_at
		)
		SELECT
			new_cpin_id, -- Use the newly inserted CPIN ID
			vendor_item->>'PayeeName',
			vendor_item->>'VendorGstIn',
			vendor_item->>'InvoiceNo',
			(vendor_item->>'InvoiceDate')::timestamp without time zone,
			(vendor_item->>'InvoiceValue')::DOUBLE PRECISION,
			(vendor_item->>'AmountPart1')::DOUBLE PRECISION,
			(vendor_item->>'AmountPart2')::DOUBLE PRECISION,
			(vendor_item->>'Total')::DOUBLE PRECISION,
			(cpin_details_payload->>'CreatedByUserid')::bigint,
			now()
		FROM
			jsonb_array_elements(cpin_details_payload->'GstDetails') AS gst_item,
			jsonb_array_elements(gst_item->'VendorDetails') AS vendor_item;

		-- Insert into bill_gst with the new CPIN ID
		INSERT INTO billing.bill_gst (
			bill_id,
			cpin_id,
			ddo_code,
			created_at,
			tr_id,
			ddo_gstn
		)
		SELECT
			inserted_id,
			new_cpin_id,
			_ddo_code,
			now(),
			_tr_master_id,
			_ddo_gst_in
		FROM
			jsonb_array_elements(cpin_details_payload->'GstDetails') AS gst_item;

	--Update cpin_master deactive the old CPIN
	
	UPDATE billing_master.cpin_master 
	SET is_active=false
	from jsonb_array_elements(cpin_details_payload->'GstDetails') AS gst_item
	WHERE cpin_id=gst_item->>'OldCpin';

	--Update failed_transaction_beneficiary as already generated.
	UPDATE cts.failed_transaction_beneficiary
	SET is_corrected = true
	from jsonb_array_elements(cpin_details_payload->'GstDetails') AS gst_item
	WHERE account_no=gst_item->>'OldCpin' and bill_id=(cpin_details_payload->>'BillId')::bigint;

 END;
$$;


ALTER PROCEDURE billing.insert_cpin_failed_bill_old(IN cpin_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying) OWNER TO postgres;

--
-- TOC entry 504 (class 1255 OID 920216)
-- Name: insert_ddo_details_json_array(character varying, jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_ddo_details_json_array(IN ddocode character varying, IN jsonarray jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    single_item jsonb;
BEGIN
    -- Archive existing records to log table
    INSERT INTO billing_log.ddo_log(
        treasury_code, ddo_code, ddo_type, valid_upto, designation, address, 
        phone_no1, phone_no2, fax, e_mail, pin, active_flag, created_by_userid, 
        created_at, updated_by_userid, updated_at, ddo_tan_no, int_dept_id, 
        office_name, station, controlling_officer, enrolement_no, 
        nps_registration_no, int_dept_id_hrms, gstin, parent_treasury_code, ref_code
    )
    SELECT 
        treasury_code, ddo_code, ddo_type, valid_upto, designation, address, 
        phone_no1, phone_no2, fax, e_mail, pin, active_flag, created_by_userid, 
        created_at, updated_by_userid, updated_at, ddo_tan_no, int_dept_id, 
        office_name, station, controlling_officer, enrolement_no, 
        nps_registration_no, int_dept_id_hrms, gstin, parent_treasury_code, ref_code
    FROM master.ddo
    WHERE ddo_code = ddoCode;

    -- Extract single JSON object from array
    single_item := jsonArray->0;

    -- Update with direct assignment from JSON object
    UPDATE master.ddo
    SET 
        treasury_code = COALESCE(single_item->>'TreasuryCode', treasury_code),
        ddo_type = COALESCE((single_item->>'DdoType')::CHAR, ddo_type),
        valid_upto = COALESCE((single_item->>'ValidUpto')::DATE, valid_upto),
        designation = COALESCE(single_item->>'Designation', designation),
        address = COALESCE(single_item->>'Address', address),
        phone_no1 = COALESCE(single_item->>'PhoneNo1', phone_no1),
        phone_no2 = COALESCE(single_item->>'PhoneNo2', phone_no2),
        fax = COALESCE(single_item->>'Fax', fax),
        e_mail = COALESCE(single_item->>'EMail', e_mail),
        pin = COALESCE(single_item->>'Pin', pin),
        active_flag = COALESCE((single_item->>'ActiveFlag')::BOOLEAN, active_flag),
        created_by_userid = COALESCE((single_item->>'CreatedByUserid')::BIGINT, created_by_userid),
        updated_at = NOW(),
        updated_by_userid = (single_item->>'UpdatedByUserid')::BIGINT,
        ddo_tan_no = COALESCE(single_item->>'DdoTanNo', ddo_tan_no),
        int_dept_id = COALESCE((single_item->>'IntDeptId')::BIGINT, int_dept_id),
        office_name = COALESCE(single_item->>'OfficeName', office_name),
        station = COALESCE(single_item->>'Station', station),
        controlling_officer = COALESCE(single_item->>'ControllingOfficer', controlling_officer),
        enrolement_no = COALESCE(single_item->>'EnrolementNo', enrolement_no),
        nps_registration_no = COALESCE(single_item->>'NpsRegistrationNo', nps_registration_no),
        int_dept_id_hrms = COALESCE(single_item->>'IntDeptIdHrms', int_dept_id_hrms),
        gstin = COALESCE(single_item->>'Gstin', gstin),
        parent_treasury_code = COALESCE(single_item->>'ParentTreasuryCode', parent_treasury_code),
        ref_code = COALESCE((single_item->>'RefCode')::NUMERIC(6,0), ref_code)
    WHERE ddo_code = ddoCode;
END;
$$;


ALTER PROCEDURE billing.insert_ddo_details_json_array(IN ddocode character varying, IN jsonarray jsonb) OWNER TO postgres;

--
-- TOC entry 410 (class 1255 OID 920217)
-- Name: insert_jit_bill(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_jit_bill(IN billing_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying)
    LANGUAGE plpgsql
    AS $$
Declare 
    _bill_id bigint;
	_count_tr10 smallint;
	_count_tr12 smallint;
	_annex_tr10 jsonb;
	_annex_tr12 jsonb;
	
 	_tmp_ref_no character varying;
    _current_month integer;
    _financial_year_id smallint;
    _financial_year text;
    _form_version smallint;
    _treasury_code character(3);
    _ddo_code character(9);
    _hoa_id bigint;
	-- _total_ag_bt bigint;
	-- _total_treasury_bt bigint;
    _tmp_ref_no_jit character varying[];

	_bill_no bigint;
	_application_type character varying;

BEGIN
	_application_type = '01';  ----- FOR JIT BILL ---------

    -- Get Current Financial Year
    SELECT  id,financial_year into _financial_year_id,_financial_year from master.financial_year_master where is_active=true;
	-- Get Treasury Code from DDO Code ??
    SELECT treasury_code, ddo_code into _treasury_code, _ddo_code from master.ddo where ddo_code= (billing_details_payload->>'DdoCode')::character(9);
	
	-- GET Bill Id from sequence     
	EXECUTE format('SELECT nextval(%L)', 'billing.bill_details_bill_id_seq') INTO _bill_id;
	
	-- GET Bill No from sequence     
	EXECUTE format('SELECT nextval(%L)', 'billing.sys_generated_bill_no_seq') INTO _bill_no;

    -- Get Month from Current Date	
    SELECT EXTRACT(MONTH FROM CURRENT_DATE) INTO _current_month;
	
	-- Generate REFERENCENO
	
	IF (billing_details_payload->>'BillId')::bigint IS NULL THEN 
		-- _tmp_ref_no := REPLACE(_financial_year::varchar, '-', '') || LPAD(_current_month::text, 2, '0') || LPAD(_bill_id::text, 7, '0');
		_tmp_ref_no := _financial_year_id || LPAD(_current_month::text, 2, '0') || LPAD(_bill_id::text, 7, '0');
		_form_version := 1;
	ELSE
		SELECT form_version,reference_no from billing.bill_details
		where bill_id = (billing_details_payload->>'BillId')::bigint into _form_version, _tmp_ref_no;
		--Need to update version +1 not static 2
		_form_version := _form_version + 1;

		UPDATE billing.bill_details
		SET 
		   is_regenerated = true
		WHERE bill_id = (billing_details_payload->>'BillId')::bigint;
		--MARK MAPPED FTO AS INACTIVE
		update billing.ebill_jit_int_map set is_active=false where bill_id= (billing_details_payload->>'BillId')::bigint;

		-- -- In case of Bill UPDATE/ Bill Regeneration except status 8, 56, 57, 10 Update Allotment

		-- PERFORM bantan.adjust_allotment_by_billid(bill_id) 
		-- FROM billing.bill_details WHERE bill_id=(billing_details_payload->>'BillId')::bigint and status!=ANY(ARRAY[8, 56, 57, 106]);
	END IF;
	    	

	WITH HOA_DETAIL AS(
		select h.id, h.demand_no, h.major_head, h.submajor_head, h.minor_head, h.plan_status, h.scheme_head,
		h.detail_head, h.subdetail_head, h.voted_charged, t.is_reissue, t.is_top_up,
		CASE 
				WHEN (t.is_reissue = false AND t.is_top_up = false) THEN 0
				WHEN (t.is_reissue = true AND t.is_top_up = false) THEN 1
				WHEN (t.is_reissue = false AND t.is_top_up = true) THEN 2
				WHEN (t.is_reissue = true AND t.is_top_up = true) THEN 3
			END AS hoa_flag
		from (select hoa_id, is_reissue, is_top_up from jit.tsa_exp_details 
		where ref_no = ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs')) group by hoa_id,is_reissue, is_top_up) t, 
		master.active_hoa_mst h where t.hoa_id = h.id and h.isactive = true
	),
	TSA_EXP_DTL AS(
		select sls_code, scheme_name,hoa_id, sum(gross_amount) as gross_amount,sum(net_amount) as net_amount,
		sum(total_treasury_bt) as total_treasury_bt, sum(total_ag_bt) as total_ag_bt, sum(total_bt) as total_bt,
		sum(total_gst) as total_gst,
		fto_type as fto_type,
		sum(payee_count) as payee_count
		from jit.tsa_exp_details 
		where ref_no = ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
		group by hoa_id, sls_code, scheme_name, fto_type
	),
	INSERT_Bill_DETAILS AS(
		-- STEP 1. INSERT Common Bill Deatils INTO BillDetails from JSON to Bill Table
		INSERT INTO billing.bill_details(
			bill_id, bill_no, bill_date, bill_mode, reference_no, tr_master_id, payment_mode, financial_year, 
			demand, major_head, sub_major_head, minor_head, plan_status, scheme_head, detail_head, voted_charged, 
			gross_amount, net_amount, bt_amount, ag_bt, treasury_bt, gst_amount,is_gst, sanction_no,
			sanction_amt, sanction_date, sanction_by, remarks, ddo_code, treasury_code, is_gem, status,
			created_by_userid,form_version,sna_grant_type,css_ben_type,
			aafs_project_id, scheme_code, scheme_name, bill_type, payee_count, is_reissued)
		(SELECT _bill_id, (_application_type || h.hoa_flag || LPAD(_bill_no::text, 8, '0')),
		(billing_details_payload->>'BillDate')::date,
		(billing_details_payload->>'BillMode')::smallint,_tmp_ref_no,29,1,_financial_year_id,
			h.demand_no, h.major_head, h.submajor_head, h.minor_head, h.plan_status,
			h.scheme_head, h.detail_head, h.voted_charged, gross_amount,net_amount,
			total_bt,total_ag_bt,total_treasury_bt,total_gst,(total_gst > 0),(billing_details_payload->>'SanctionNo'), 
			(billing_details_payload->>'SanctionAmount')::decimal,
			NULLIF(billing_details_payload->>'SanctionDate', '')::date,
			(billing_details_payload->>'SanctionBy')::character varying,
			(billing_details_payload->>'Remarks')::character varying,
			_ddo_code,_treasury_code,true,(billing_details_payload->>'Status')::smallint,
			(billing_details_payload->>'CreatedByUserid')::bigint,_form_version,1,1,null,sls_code,
			scheme_name,fto_type, t.payee_count, h.is_reissue
		FROM HOA_DETAIL h, TSA_EXP_DTL t WHERE h.id = t.hoa_id)
		returning bill_id
	),
	SUBDTL AS(
		--STEP 2. INSERT SUBDetail into Table  
		INSERT INTO billing.bill_subdetail_info(
			bill_id, active_hoa_id, amount, status, created_by_userid, financial_year,ddo_code, treasury_code)

		SELECT _bill_id, h.id,t.gross_amount, (billing_details_payload->>'Status')::smallint,
		(billing_details_payload->>'CreatedByUserid')::bigint,_financial_year_id, _ddo_code, _treasury_code
		FROM
		HOA_DETAIL h, TSA_EXP_DTL t 
		returning id
	)
   -- STEP 4. Map generated eBill Reference Number to JIT Reference Number
	INSERT INTO billing.bill_btdetail(
			bill_id, bt_serial, bt_type, amount, ddo_code, treasury_code, status, created_by, created_at, financial_year
		)
		SELECT _bill_id, bt_code, bt_code::smallint, total_bt_amount, _ddo_code, _treasury_code,
			(billing_details_payload->>'Status')::smallint,  -- Bill Status as Draft Approver/Draft
			(billing_details_payload->>'CreatedByUserid')::bigint, now(), _financial_year_id
		FROM 
		(SELECT bt.bt_code, bt.bt_type, SUM(bt.amount) AS total_bt_amount
		FROM (select * FROM  jit.payee_deduction where ref_no=ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs'))) bt GROUP BY bt.bt_code, bt.bt_type) bill_bt;
	SELECT 
		COUNT(1) FILTER(WHERE bt_code=67),
		jsonb_agg(jsonb_build_object('EmployeeId', m.payee_code,
					'EmployeeName', m.payee_name,
					'PAN', m.pan_no,
					'GrossClaim', m.gross_amount,
					'AmtDeducted', d.amount,
					'Designation', null)) FILTER (WHERE bt_code = 67),	
		COUNT(1) FILTER(WHERE bt_code=1),
		jsonb_agg(jsonb_build_object('EmployeeId', m.payee_code,
					'EmployeeName', m.payee_name,
					'PAN', m.pan_no,
					'GrossClaim', m.gross_amount,
					'AmtDeducted', d.amount,
					'Designation', null)) FILTER (WHERE bt_code = 1)
	INTO _count_tr10, _annex_tr10, _count_tr12, _annex_tr12
	FROM jit.payee_deduction d, jit.tsa_payeemaster m
	where d.payee_id=m.id and m.ref_id = d.ref_id and m.ref_no = ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs'));
			
	IF _count_tr10 > 0	THEN
	-- 	-- tr_10_detail
		INSERT INTO billing.tr_10_detail (bill_id, tr_master_id, is_scheduled, created_by_userid, employee_details_object)
		VALUES(_bill_id, 29, true, (billing_details_payload->>'CreatedByUserid')::bigint, _annex_tr10);
	END IF;			
	IF _count_tr12 > 0	THEN
	-- 	-- tr_12_detail
		INSERT INTO billing.tr_12_detail (bill_id, tr_master_id, is_scheduled, created_by_userid, employee_details_object)
		VALUES(_bill_id, 29, true, (billing_details_payload->>'CreatedByUserid')::bigint, _annex_tr12);
	END IF;
	
	-- Get Bill Reference No and Bill Id 
	_out_ref_no:= _tmp_ref_no || '-' || _form_version;
	inserted_id = _bill_id;

	-- -- -- RAISE NOTICE 'Inserted Ref# : % - tmp %  - version %, inserted bill id: %', _out_ref_no,_tmp_ref_no,_form_version, inserted_id;

	---   STEP 5. Insert ECS neft details
	WITH insert_ecs AS (
		INSERT INTO billing.bill_ecs_neft_details( bill_id, payee_name, beneficiary_id, pan_no,
		beneficiary_type, ifsc_code, bank_account_number, amount, status, is_active,
		created_by_userid, financial_year)
			SELECT _bill_id, p.payee_name, p.payee_code, p.pan_no, p.payee_type, p.ifsc_code, p.acc_no,
			p.net_amount, (billing_details_payload->>'Status')::smallint, 1 as is_active, 
			(billing_details_payload->>'CreatedByUserid')::bigint AS created_by_userid,
			_financial_year_id
			FROM jit.tsa_payeemaster p 
			where ref_no =ANY (SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs'))
			RETURNING id, bill_id, beneficiary_id
	)
	INSERT INTO billing.jit_ecs_additional(ecs_id, bill_id, beneficiary_id, aadhar, gross_amount, 
	net_amount, reissue_amount, end_to_end_id, agency_code, agency_name, jit_reference_no, financial_year,
	districtcodelgd,  state_code_lgd, urban_rural_flag, block_lgd, panchayat_lgd,
	village_lgd, tehsil_lgd, town_lgd, ward_lgd)
	SELECT e.id AS ecs_id, _bill_id, c.payee_code, c.aadhaar_no, c.gross_amount, c.net_amount, 
	c.reissue_amount, c.last_end_to_end_id, c.agency_code, c.agency_name, c.ref_no, _financial_year_id,
	CASE WHEN c.district_code_lgd IS NOT NULL THEN c.district_code_lgd ELSE ex.district_code_lgd END,
	CASE WHEN c.state_code_lgd IS NOT NULL THEN c.state_code_lgd ELSE '19' END,
	c.urban_rural_flag, c.block_lgd, c.panchayat_lgd, c.village_lgd, c.tehsil_lgd, c.town_lgd, c.ward_lgd
	FROM 
		insert_ecs e	
	LEFT JOIN (select * FROM jit.tsa_payeemaster where ref_no = ANY (SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')))c 
	ON e.beneficiary_id = c.payee_code
	LEFT JOIN jit.tsa_exp_details ex ON ex.id = c.ref_id;
		
	-- --STEP 9. Update is_mapped flag on jit.tsa_exp_details table
	WITH ref_numbers AS (
	  SELECT (jsonb_array_elements(billing_details_payload->'JitRefs')->>'RefNo')::character varying AS ref_no
	  FROM jit.tsa_exp_details
	),
	UPDATE_EXP AS(
		UPDATE jit.tsa_exp_details SET is_mapped = true WHERE ref_no =ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs'))
	)
	,
	COMPONENT AS(
		--STEP 6. Insert Component Details
		INSERT INTO billing.bill_jit_components ( bill_id, payee_id, componentcode, componentname,
		amount, slscode, financial_year )
	    SELECT 
	        _bill_id AS bill_id, payee_code, componentcode, componentname, amount, slscode,
			_financial_year_id
	    FROM 
			 jit.exp_payee_components 
			 WHERE ref_no =ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
		returning bill_id
	)
	,
	ben_agency AS(
		--STEP 7. Insert Agency Details
		INSERT INTO billing.jit_ben_agency_map (
	        bill_id, payee_id, agencycode, agencyname
	    )
	    SELECT 
	        _bill_id AS bill_id,
	        payee_code,
	        agency_code,
	        agency_name
	    from jit.tsa_payeemaster WHERE ref_no =ANY (SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs'))
		returning bill_id
	)
	-- --STEP 8. Insert tr_26a details
	INSERT INTO billing.tr_26a_detail(bill_id, bill_mode, tr_master_id, is_scheduled, topup_amount,
	reissue_amount, total_amt_for_cs_calc_sc, total_amt_for_cs_calc_scoc,
	total_amt_for_cs_calc_sccc, total_amt_for_cs_calc_scsal, total_amt_for_cs_calc_st,
	total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_stcc, total_amt_for_cs_calc_stsal,
	total_amt_for_cs_calc_ot, total_amt_for_cs_calc_otoc, total_amt_for_cs_calc_otcc,
	total_amt_for_cs_calc_otsal, hoa_id, voucher_details_object, category_code)
	SELECT _bill_id,
			0, --
			29, -- 29 for TR26a
			false,
			topup_amount, reissue_amount, total_amt_for_cs_calc_sc, total_amt_for_cs_calc_scoc,
			total_amt_for_cs_calc_sccc, total_amt_for_cs_calc_scsal, total_amt_for_cs_calc_st,
			total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_stcc, total_amt_for_cs_calc_stsal,
			total_amt_for_cs_calc_ot, total_amt_for_cs_calc_otoc, total_amt_for_cs_calc_otcc,
			total_amt_for_cs_calc_otsal, hoa_id, voucher_dtl.voucher ,category_code
	FROM 
	(select 
			sum(topup_amount) as topup_amount, sum(reissue_amount) as reissue_amount,
			sum(total_amt_for_cs_calc_sc) as total_amt_for_cs_calc_sc,
			sum(total_amt_for_cs_calc_scoc) as total_amt_for_cs_calc_scoc,
			sum(total_amt_for_cs_calc_sccc) as total_amt_for_cs_calc_sccc,
			sum(total_amt_for_cs_calc_scsal) as total_amt_for_cs_calc_scsal,
			sum(total_amt_for_cs_calc_st) as total_amt_for_cs_calc_st, 
			sum(total_amt_for_cs_calc_stoc) as total_amt_for_cs_calc_stoc,
			sum(total_amt_for_cs_calc_stcc) as total_amt_for_cs_calc_stcc, 
			sum(total_amt_for_cs_calc_stsal) as total_amt_for_cs_calc_stsal,
			sum(total_amt_for_cs_calc_ot) as total_amt_for_cs_calc_ot, 
			sum(total_amt_for_cs_calc_otoc) as total_amt_for_cs_calc_otoc,
			sum(total_amt_for_cs_calc_otcc) as total_amt_for_cs_calc_otcc, 
			sum(total_amt_for_cs_calc_otsal) as total_amt_for_cs_calc_otsal, hoa_id, category_code
	from jit.tsa_exp_details WHERE ref_no =ANY(SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
	group by category_code, hoa_id) tr , (select jsonb_agg(
	jsonb_build_object( 'VoucherNo',voucher_no,'VoucherDate',voucher_date,'DescCharges',desc_charges,'Authority',authority,'Amount',(amount::NUMERIC::BigInt))) as voucher
	from jit.fto_voucher where ref_no =ANY(SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')))as voucher_dtl;	  
		
	INSERT INTO billing.ebill_jit_int_map (ebill_ref_no, jit_ref_no, bill_id, financial_year)
	SELECT 
		_tmp_ref_no, 
		ftos_element::text,
		_bill_id, _financial_year_id
	FROM 
		jsonb_array_elements_text(billing_details_payload->'JitRefs') AS ftos_element;
		
	-- INSERT INTO BOOKED BILL
	
	-- INSERT INTO billing.ddo_allotment_booked_bill(
	-- bill_id, allotment_id, amount, ddo_code, financial_year, active_hoa_id,allotment_received,progressive_expenses)
	-- select  _bill_id, jit_sanction.allotment_id,booked_amt, jit_sanction.ddo_code,trans.financial_year,trans.active_hoa_id,
	-- trans.ceiling_amount, trans.provisional_released_amount+booked_amt
	-- from (select sanction_no, ddo_code, booked_amt, allotment_id  from jit.jit_fto_sanction_booking WHERE ref_no= ANY(
	-- SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
	-- ) AS jit_sanction
	-- , bantan.ddo_allotment_transactions AS trans where jit_sanction.allotment_id = trans.allotment_id;
	
	-- -- INSERT INTO BOOKED BILL

	WITH fto_flag as(
		select is_reissue from jit.tsa_exp_details 
		where ref_no = ANY(SELECT * FROM 
            jsonb_array_elements_text(billing_details_payload->'JitRefs')) group by is_reissue
	)
	INSERT INTO billing.ddo_allotment_booked_bill(
	bill_id, allotment_id, amount, ddo_code, financial_year, active_hoa_id,allotment_received,
	progressive_expenses, is_reissued)
	select  _bill_id, jit_sanction.allotment_id,booking_amt, jit_sanction.ddo_code,trans.financial_year,
	trans.active_hoa_id, trans.ceiling_amount, trans.provisional_released_amount+booking_amt, fto_flag.is_reissue
	from fto_flag, (select sanction_no, ddo_code, sum(booked_amt) as booking_amt, allotment_id 
					from jit.jit_fto_sanction_booking
					WHERE ref_no= ANY(
						SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs'))
						group by sanction_no, ddo_code, allotment_id
					) AS jit_sanction, 
	bantan.ddo_allotment_transactions AS trans where jit_sanction.allotment_id = trans.allotment_id;

	--Update ddo transaction provisional balance
	-- UPDATE bantan.ddo_allotment_transactions  
	-- set provisional_released_amount=provisional_released_amount+prov.sum_allotment
	-- from(
	-- 	select  trans.allotment_id, sum(booked_amt) as sum_allotment
	-- 		from (select sanction_no, ddo_code, booked_amt from jit.jit_fto_sanction_booking WHERE ref_no= ANY(
	-- 			SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
	-- 		) AS jit_sanction, 
	-- 		bantan.ddo_allotment_transactions AS trans where jit_sanction.sanction_no = trans.memo_number and jit_sanction.ddo_code=trans.receiver_sao_ddo_code
	-- 	group by trans.allotment_id
	-- ) AS prov where bantan.ddo_allotment_transactions.allotment_id = prov.allotment_id;
	
	--Update ddo transaction provisional balance
	UPDATE bantan.ddo_allotment_transactions  
	set provisional_released_amount=provisional_released_amount+prov.sum_allotment
	from(
		select  trans.allotment_id, sum(booked_amt) as sum_allotment
			from (select sanction_no, ddo_code, booked_amt, allotment_id 
				  from jit.jit_fto_sanction_booking 
				  WHERE ref_no= ANY(
						SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
				  ) AS jit_sanction, 
			bantan.ddo_allotment_transactions AS trans where jit_sanction.allotment_id = trans.allotment_id
		group by trans.allotment_id
	) AS prov where bantan.ddo_allotment_transactions.allotment_id = prov.allotment_id;

	--Update ddo wallet provisional balance
	UPDATE bantan.ddo_wallet
	set provisional_released_amount=provisional_released_amount+prov.sum_allotment
	from(
		select  trans.receiver_sao_ddo_code, trans.active_hoa_id, sum(booked_amt) as sum_allotment
			from (select sanction_no, ddo_code, booked_amt, allotment_id from jit.jit_fto_sanction_booking 
				  WHERE ref_no= ANY(
					SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
				 ) AS jit_sanction, 
			bantan.ddo_allotment_transactions AS trans where jit_sanction.allotment_id = trans.allotment_id
		group by trans.receiver_sao_ddo_code, trans.active_hoa_id

	) AS prov where bantan.ddo_wallet.sao_ddo_code = prov.receiver_sao_ddo_code
	and bantan.ddo_wallet.active_hoa_id=prov.active_hoa_id;
	-- UPDATE bantan.ddo_wallet
	-- set provisional_released_amount=provisional_released_amount+prov.sum_allotment
	-- from(
	-- 	select  trans.receiver_sao_ddo_code, trans.active_hoa_id, sum(booked_amt) as sum_allotment
	-- 		from (select sanction_no, ddo_code, booked_amt from jit.jit_fto_sanction_booking WHERE ref_no= ANY(
	-- 			SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs')) 
	-- 		) AS jit_sanction, 
	-- 		bantan.ddo_allotment_transactions AS trans where jit_sanction.sanction_no = trans.memo_number
	-- 	group by trans.receiver_sao_ddo_code, trans.active_hoa_id

	-- ) AS prov where bantan.ddo_wallet.sao_ddo_code = prov.receiver_sao_ddo_code and bantan.ddo_wallet.active_hoa_id=prov.active_hoa_id;

	
	--UPDATE GST TABLE WITH BILL ID
	UPDATE jit.gst set bill_id=_bill_id, cpin_id=null, is_mapped=false
	WHERE ref_no= ANY(SELECT * FROM jsonb_array_elements_text(billing_details_payload->'JitRefs'));

	 --insert into bill status info table
    INSERT INTO billing.bill_status_info( bill_id, status_id, created_by, created_at)
        VALUES (_bill_id, (billing_details_payload->>'Status')::smallint, -- Status for approver(2) or operator(1)
		   (billing_details_payload->>'CreatedByUserid')::bigint, now()
        );

	--UPDATE failed_transaction_beneficiary TABLE WITH end_to_end_id
		WITH old_ref_details AS(
			SELECT old_ref_no, last_end_to_end_id
		    FROM jit.tsa_payeemaster
		    WHERE ref_no = ANY (
		        SELECT jsonb_array_elements_text(billing_details_payload->'JitRefs')
		    )
		)
		UPDATE cts.failed_transaction_beneficiary f
		SET is_reissued = true
		FROM old_ref_details refs
		WHERE f.jit_ref_no = refs.old_ref_no
		AND f.end_to_end_id = refs.last_end_to_end_id;
		
 END;
$$;


ALTER PROCEDURE billing.insert_jit_bill(IN billing_details_payload jsonb, OUT inserted_id bigint, OUT _out_ref_no character varying) OWNER TO postgres;

--
-- TOC entry 421 (class 1255 OID 920219)
-- Name: insert_jit_bill_without_bill_details_func(bigint); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.insert_jit_bill_without_bill_details_func(param1 bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    CALL billing.insert_jit_bill_without_bill_details(param1);
END;
$$;


ALTER FUNCTION billing.insert_jit_bill_without_bill_details_func(param1 bigint) OWNER TO postgres;

--
-- TOC entry 415 (class 1255 OID 920220)
-- Name: insert_jit_report(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.insert_jit_report() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
        _status_code smallint;
        _fto_count smallint;
BEGIN

     -- Get the status_code 
    _status_code := NEW.status_id;
	
	SELECT COUNT(jit_ref_no) INTO _fto_count
	FROM billing.ebill_jit_int_map
	WHERE bill_id = NEW.bill_id;
    
    -- Conditional logic based on status_code
    IF _status_code = 1 OR _status_code = 2 THEN  --bill generated
        INSERT INTO jit.jit_report_details (ddo_code, scheme_code, scheme_name, hoa_id, bill_generated)
        SELECT b.ddo_code, b.scheme_code, b.scheme_name, s.active_hoa_id, 1
        FROM billing.bill_details b
		LEFT JOIN billing.bill_subdetail_info s on b.bill_id = s.bill_id
		where b.bill_id = NEW.bill_id
		ON CONFLICT (ddo_code, hoa_id) -- Specify the unique constraint or index
        DO UPDATE 
        SET bill_generated = jit.jit_report_details.bill_generated + 1;

	ELSIF _status_code = 3 THEN -- pending for approval
        INSERT INTO jit.jit_report_details (ddo_code, scheme_code, scheme_name, hoa_id, bill_pending_for_approval)
        SELECT b.ddo_code, b.scheme_code, b.scheme_name, s.active_hoa_id, 1
        FROM billing.bill_details b
		LEFT JOIN billing.bill_subdetail_info s on b.bill_id = s.bill_id
		where b.bill_id = NEW.bill_id
        ON CONFLICT (ddo_code, hoa_id) -- Specify the unique constraint or index
        DO UPDATE 
        SET 
            bill_pending_for_approval=jit.jit_report_details.bill_pending_for_approval + 1;
			
    ELSIF _status_code = 5 THEN --send to trasury
        INSERT INTO jit.jit_report_details (ddo_code, scheme_code, scheme_name, hoa_id, bill_forward_to_treasury)
        SELECT b.ddo_code, b.scheme_code, b.scheme_name, s.active_hoa_id, 1
        FROM billing.bill_details b
		LEFT JOIN billing.bill_subdetail_info s on b.bill_id = s.bill_id
		where b.bill_id = NEW.bill_id
        ON CONFLICT (ddo_code, hoa_id) -- Specify the unique constraint or index
        DO UPDATE 
        SET 
            bill_forward_to_treasury=jit.jit_report_details.bill_forward_to_treasury + 1;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION billing.insert_jit_report() OWNER TO postgres;

--
-- TOC entry 431 (class 1255 OID 920221)
-- Name: insert_pfms_failed_transaction_detail(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_pfms_failed_transaction_detail(IN failed_transaction_file_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    bill_id_list jsonb;
BEGIN
    bill_id_list := failed_transaction_file_payload->'FileStatusDetails'->'BillIds';

    -- CTE to extract all distinct (bill_id, jit_ref_no) pairs from the payload's PayeeDetails
    WITH distinct_bill_jit_pairs AS (
        SELECT
            maps.bill_id,
            maps.jit_ref_no
        FROM
            billing.ebill_jit_int_map maps
        WHERE
            maps.bill_id = ANY (SELECT jsonb_array_elements_text(bill_id_list)::bigint)
    ),
    all_error_entries AS (
        SELECT
            jsonb_array_elements(failed_transaction_file_payload->'ErrorDetails') AS error_entry
    ),
    aggregated_matching_errors AS (
        SELECT
            dbjp.bill_id,
            dbjp.jit_ref_no,
            jsonb_agg(
                jsonb_build_object(
                    'ErrorCode', aee.error_entry->>'ErrorCode',
                    'ErrorDesc', aee.error_entry->>'ErrorDesc',
                    'PayeeDetails',
                    CASE
                        WHEN aee.error_entry->'PayeeDetails' = '[]'::jsonb THEN '[]'::jsonb
                        ELSE (
                            SELECT jsonb_agg(pd_filtered)
                            FROM jsonb_array_elements(aee.error_entry->'PayeeDetails') AS pd_filtered
                            WHERE
                                (pd_filtered->>'BillId')::bigint = dbjp.bill_id
                                AND (pd_filtered->>'JitReferenceNo')::text = dbjp.jit_ref_no
                        )
                    END
                ) ORDER BY aee.error_entry->>'ErrorCode'
            ) FILTER (WHERE
                aee.error_entry->'PayeeDetails' = '[]'::jsonb
                OR
                EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(aee.error_entry->'PayeeDetails') AS pd_check
                    WHERE
                        (pd_check->>'BillId')::bigint = dbjp.bill_id
                        AND (pd_check->>'JitReferenceNo')::text = dbjp.jit_ref_no
                )
            ) AS error_json
        FROM
            distinct_bill_jit_pairs dbjp
        CROSS JOIN
            all_error_entries aee
        GROUP BY
            dbjp.bill_id, dbjp.jit_ref_no
    )
    -- Update ebill_jit_int_map with filtered error details
    UPDATE billing.ebill_jit_int_map maps
    SET
        error_details = ame.error_json,
        is_active = false,
		file_name = REPLACE((failed_transaction_file_payload->'FileStatusDetails'->'FileName')::text, '"', '')
    FROM aggregated_matching_errors ame
    WHERE maps.bill_id = ame.bill_id
      AND maps.jit_ref_no = ame.jit_ref_no
      AND ame.error_json IS NOT NULL;

    -- Update bill_details table status column
    UPDATE billing.bill_details
    SET status = 56
    WHERE bill_id = ANY (SELECT jsonb_array_elements_text(bill_id_list)::bigint);
END;
$$;


ALTER PROCEDURE billing.insert_pfms_failed_transaction_detail(IN failed_transaction_file_payload jsonb) OWNER TO postgres;

--
-- TOC entry 452 (class 1255 OID 920222)
-- Name: insert_pfms_failed_transaction_detail_24092025(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_pfms_failed_transaction_detail_24092025(IN failed_transaction_file_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    bill_id_list jsonb;
BEGIN
    -- Extract the list of BillIds from FileStatusDetails
    bill_id_list := failed_transaction_file_payload->'FileStatusDetails'->'BillIds';

    WITH error_data AS (
        -- Extract each error object from the ErrorDetails array
        SELECT jsonb_array_elements(failed_transaction_file_payload->'ErrorDetails') AS error_entry
    ),
    payee_bill_ids AS (
        SELECT (payee->>'BillId')::bigint AS bill_id
        FROM error_data, jsonb_array_elements(error_entry->'PayeeDetails') AS payee
    ),
    filtered_errors AS (
        SELECT 
            bill_id,
            CASE 
                WHEN bill_id = ANY (SELECT bill_id FROM payee_bill_ids) 
                THEN (SELECT jsonb_agg(error_entry) FROM error_data) -- Full error JSON Inserted
                ELSE (SELECT jsonb_agg(error_entry) FROM error_data
				WHERE error_entry->'PayeeDetails' = '[]'::jsonb) -- Only errors with empty PayeeDetails
            END AS error_json
        FROM (
            SELECT bill_id::bigint 
            FROM jsonb_array_elements_text(bill_id_list) AS bill_id
        ) AS bill_ids
    )

    -- Update ebill_jit_int_map with filtered error details
    UPDATE billing.ebill_jit_int_map maps
    SET 
        error_details = fe.error_json,
        is_active = false, 
		file_name = REPLACE((failed_transaction_file_payload->'FileStatusDetails'->'FileName')::text, '"', '')
    FROM filtered_errors fe
    WHERE maps.bill_id = fe.bill_id;

    -- Update bill_details table status column
    UPDATE billing.bill_details
    SET status = 56 -- PFMS Rejected
    WHERE bill_id = ANY (SELECT jsonb_array_elements_text(bill_id_list)::bigint);
END;
$$;


ALTER PROCEDURE billing.insert_pfms_failed_transaction_detail_24092025(IN failed_transaction_file_payload jsonb) OWNER TO postgres;

--
-- TOC entry 489 (class 1255 OID 920223)
-- Name: insert_pfms_file_status_details(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_pfms_file_status_details(IN pfms_file_status_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    bill_id_list jsonb;
BEGIN
    -- Extract the list of BillIds from Json
    bill_id_list := pfms_file_status_payload->'BillIds';

    WITH filtered_bill_ids AS (
		SELECT bill_id::bigint 
		FROM jsonb_array_elements_text(bill_id_list) AS bill_id
    )
    INSERT INTO billing.billing_pfms_file_status_details(
	bill_id, file_name, status_received_at, payment_status, sanction_status)
    SELECT 
       fb.bill_id, 
	   (pfms_file_status_payload->>'FileName'),
	   (pfms_file_status_payload->>'StatusReceivedAt')::timestamp without time zone, 
	   (pfms_file_status_payload->>'PaymentStatus'),
	   (pfms_file_status_payload->>'SanctionStatus')
	FROM filtered_bill_ids fb;
END;
$$;


ALTER PROCEDURE billing.insert_pfms_file_status_details(IN pfms_file_status_payload jsonb) OWNER TO postgres;

--
-- TOC entry 478 (class 1255 OID 920224)
-- Name: insert_return_memo_generated_bill(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_return_memo_generated_bill(IN return_memo_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
v_queue_message jsonb;
BEGIN			
	INSERT INTO billing.returned_memo_generated_bill(bill_id,bill_objections,generated_at,generated_by)
	SELECT
		(return_memo_payload->>'BillId')::bigint,
		(return_memo_payload->>'BillObjections')::jsonb,
		(return_memo_payload->>'GeneratedAt')::timestamp without time zone,
		(return_memo_payload->>'GeneratedBy')::bigint;
		
	-- Update Status of billing.bill_details	
	UPDATE billing.bill_details
	SET  status = 53 			-- Return Memo Delivered
	WHERE  bill_id= (return_memo_payload->>'BillId')::bigint;
END;	
$$;


ALTER PROCEDURE billing.insert_return_memo_generated_bill(IN return_memo_payload jsonb) OWNER TO postgres;

--
-- TOC entry 439 (class 1255 OID 920225)
-- Name: insert_update_treasury_details(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.insert_update_treasury_details(IN treasury_details_payload jsonb, OUT inserted_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  _treasury_id int;
  -- _updated_at timestamp without time zone;
  -- _created_by bigint;
  -- _updated_by bigint;
BEGIN
  -- Get Treasury Id From JSON
  _treasury_id := (treasury_details_payload ->> 'Id')::int;

  -- Logic for INSERT
  IF _treasury_id IS NULL THEN
    -- Insert new Treasury details
    INSERT INTO master.treasury(
      code, treasury_name, district_code, treasury_srl_number,
      officer_user_id, officer_name, address, address1, address2,
      phone_no1, phone_no2, fax, e_mail, pin, active_flag, createdby_user_id,
      created_by, int_treasury_code, treasury_status, int_ddo_id,
      debt_acct_no, nps_registration_no, pension_flag, ref_code
    )
    VALUES (
      (treasury_details_payload ->> 'Code')::character(4),
      (treasury_details_payload ->> 'TreasuryName')::character varying(100),
      (treasury_details_payload ->> 'DistrictCode')::character(2),
      (treasury_details_payload ->> 'TreasurySrlNumber')::character(4),
      (treasury_details_payload ->> 'OfficerUserId')::bigint,
      (treasury_details_payload ->> 'OfficerName')::character varying(100),
      (treasury_details_payload ->> 'Address')::character varying(200),
      (treasury_details_payload ->> 'Address1')::character varying(200),
      (treasury_details_payload ->> 'Address2')::character varying(200),
      (treasury_details_payload ->> 'PhoneNo1')::character varying(20),
      (treasury_details_payload ->> 'PhoneNo2')::character varying(20),
      (treasury_details_payload ->> 'Fax')::character(20),
      (treasury_details_payload ->> 'EMail')::character varying(50),
      (treasury_details_payload ->> 'Pin')::character(6),
      (treasury_details_payload ->> 'ActiveFlag')::boolean,
      (treasury_details_payload ->> 'CreatedbyUserId')::bigint,
      now(),
      --(treasury_details_payload ->> 'UpdatedBy')::timestamp,
      (treasury_details_payload ->> 'IntTreasuryCode')::character(5),
      (treasury_details_payload ->> 'TreasuryStatus')::character(1),
      (treasury_details_payload ->> 'IntDdoId')::numeric(6,0),
      (treasury_details_payload ->> 'DebtAcctNo')::character(15),
      (treasury_details_payload ->> 'NpsRegistrationNo')::character(10),
      (treasury_details_payload ->> 'PensionFlag')::character(1),
      (treasury_details_payload ->> 'RefCode')::numeric(3,0)
    ) RETURNING id INTO inserted_id;

  -- Logic for UPDATE
  ELSE
   -- _updated_by := (treasury_details_payload ->> 'UpdatedByUserId')::bigint;
   -- _updated_at := now();
    -- Update existing Treasury details
    UPDATE master.treasury
    SET
      treasury_name = (treasury_details_payload ->> 'TreasuryName')::character varying(100),
      district_code = (treasury_details_payload ->> 'DistrictCode')::character(2),
      officer_user_id = (treasury_details_payload ->> 'OfficerUserId')::bigint,
      officer_name = (treasury_details_payload ->> 'OfficerName')::character varying(100),
      address = (treasury_details_payload ->> 'Address')::character varying(200),
      phone_no1 = (treasury_details_payload ->> 'PhoneNo1')::character varying(20),
      phone_no2 = (treasury_details_payload ->> 'PhoneNo2')::character varying(20),
      fax = (treasury_details_payload ->> 'Fax')::character(20),
      e_mail = (treasury_details_payload ->> 'EMail')::character varying(50),
      pin = (treasury_details_payload ->> 'Pin')::character(6),
      pension_flag = (treasury_details_payload ->> 'PensionFlag')::character(1),
      updatedby_user_id = (treasury_details_payload ->> 'UpdatedbyUserId')::bigint,
      updated_by = now()
    WHERE id = _treasury_id;
    inserted_id := _treasury_id;
  END IF;

END;
$$;


ALTER PROCEDURE billing.insert_update_treasury_details(IN treasury_details_payload jsonb, OUT inserted_id integer) OWNER TO postgres;

--
-- TOC entry 496 (class 1255 OID 920226)
-- Name: jit_cancelled_fto_data(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.jit_cancelled_fto_data(IN in_payload jsonb, OUT _out_jit_cancelled_fto jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_gross_amount_diff numeric;
    v_net_amount_diff numeric;
    v_diff_total_amt_for_cs_calc_sc numeric;
    v_diff_total_amt_for_cs_calc_scoc numeric;
    v_diff_total_amt_for_cs_calc_sccc numeric;
    v_diff_total_amt_for_cs_calc_scsal numeric;
    v_diff_total_amt_for_cs_calc_st numeric;
    v_diff_total_amt_for_cs_calc_stoc numeric;
	v_diff_total_amt_for_cs_calc_stcc numeric;
	v_diff_total_amt_for_cs_calc_stsal numeric;
    v_diff_total_amt_for_cs_calc_ot numeric;
    v_diff_total_amt_for_cs_calc_otoc numeric;
    v_diff_total_amt_for_cs_calc_otcc numeric;
    v_diff_total_amt_for_cs_calc_otsal numeric;
	v_scheme_name character varying;
	v_scheme_code character varying;
	v_category_code character varying;
	v_hoa_id bigint;
	 ecs_detail jsonb;
    jit_ecs_detail jsonb;
    voucher_detail jsonb;
	component_detail jsonb;
	gst_detail jsonb;
	bt_detail jsonb;
	tr_detail jsonb;
	deduction_detail jsonb;
	jit_ref_detail jsonb;
	agency_detail jsonb;
	jit_ref_no_array character varying[];
	ded_id bigint;
	bt_amount numeric;
	_payee_id character varying;
	bill_cancelled boolean;
BEGIN
	--- Query to get jit_ref_array
	SELECT array_agg(jit_ref_no)
		INTO jit_ref_no_array
		FROM billing.ebill_jit_int_map 
		WHERE ebill_ref_no IN (
			SELECT reference_no 
			FROM billing.bill_details 
			WHERE bill_id = (in_payload->>'BillId')::bigint AND is_rejected <> true
		);
		
	--- Query for jit_ref	
	SELECT jsonb_agg(jsonb_build_object('refNo', ref_no)) 
	INTO jit_ref_detail
	FROM unnest(jit_ref_no_array) AS ref_no;
		
	--- Query for bt details with tr		
	select jsonb_agg(jsonb_build_object(
            'id', bt.id,
            'btSerial', bt.bt_serial,
            'amount', bt_sl.amount,
            'btType', bt.type,
--             'dedId', bt.bt_serial,
			'trDetails', tr_dt.tr_details
        )) as bt_details into bt_detail
			from billing_master.bt_details as bt
			INNER JOIN billing.bill_btdetail as bt_sl ON bt.bt_serial=bt_sl.bt_serial
	INNER JOIN (
		SELECT d.ded_id,jsonb_agg(
           jsonb_build_object(
               'employeeId', payee.payee_id,
               'employeeName', payee.payee_name,
               'pan', payee.pan_no,
               'amtDeducted', d.amount
           )
       ) AS tr_details
		FROM jit.tsa_payeemaster AS payee
		INNER JOIN  jit.payee_deduction d ON payee.payee_id=d.payee_id
			WHERE d.ref_no = ANY(jit_ref_no_array)
		GROUP BY d.ded_id
	) AS tr_dt ON bt.bt_serial=tr_dt.ded_id
	WHERE bt_sl.bill_id = (in_payload->>'BillId')::bigint;
	
    --- Query to get GrossAmount and NetAmount differences
    SELECT (b.gross_amount) AS GrossAmount,
           (b.net_amount) AS NetAmount,
		   a.scheme_code as SchemeCode, a.scheme_name as SchemeName,
		   a.ddo_code, a.treasury_code
    INTO v_gross_amount_diff, v_net_amount_diff, v_scheme_code ,v_scheme_name
    FROM (
        SELECT * 
        FROM billing.bill_details 
        WHERE bill_id = (in_payload->>'BillId')::bigint
    ) a
    JOIN (
        SELECT 
            SUM(gross_amount) AS gross_amount,
            SUM(net_amount) AS net_amount
        FROM jit.tsa_exp_details 
        WHERE ref_no = ANY(jit_ref_no_array)
    ) b ON 1=1;
	
	--- Query to get voucher details
	SELECT jsonb_agg(jsonb_build_object(
            'voucherNo', voucher.voucher_no,
            'amount', voucher.amount,
            'voucherDate', voucher.voucher_date,
            'descCharges', voucher.desc_charges,
            'authority', voucher.authority
        )) AS voucher_details
			INTO voucher_detail
			FROM jit.fto_voucher as voucher
			WHERE ref_no = ANY(jit_ref_no_array);
		
	--- Query to get component details
	SELECT jsonb_agg(jsonb_build_object(
            'payeeId', component.payee_id,
            'amount', component.amount,
            'componentCode', component.componentcode,
            'slsCode', component.slscode,
            'componentName', jit_component.componentname,
			'schemeName', v_scheme_name
		)) AS component_details
			INTO component_detail
			FROM jit.exp_payee_components AS component
			LEFT JOIN billing.bill_jit_components AS jit_component
				ON component.payee_id = jit_component.payee_id
				AND jit_component.bill_id = (in_payload->>'BillId')::bigint
			WHERE component.ref_no = ANY(jit_ref_no_array);

    --- Query to get other differences
    SELECT 
        (a.total_amt_for_cs_calc_sc - b.total_amt_for_cs_calc_sc) AS diff_total_amt_for_cs_calc_sc,
        (a.total_amt_for_cs_calc_scoc - b.total_amt_for_cs_calc_scoc) AS diff_total_amt_for_cs_calc_scoc,
        (a.total_amt_for_cs_calc_sccc - b.total_amt_for_cs_calc_sccc) AS diff_total_amt_for_cs_calc_sccc,
        (a.total_amt_for_cs_calc_scsal - b.total_amt_for_cs_calc_scsal) AS diff_total_amt_for_cs_calc_scsal,
        (a.total_amt_for_cs_calc_st - b.total_amt_for_cs_calc_st) AS diff_total_amt_for_cs_calc_st,
        (a.total_amt_for_cs_calc_stoc - b.total_amt_for_cs_calc_stoc) AS diff_total_amt_for_cs_calc_stoc,
        (a.total_amt_for_cs_calc_stcc - b.total_amt_for_cs_calc_stcc) AS diff_total_amt_for_cs_calc_stcc,
        (a.total_amt_for_cs_calc_stsal - b.total_amt_for_cs_calc_stsal) AS diff_total_amt_for_cs_calc_stsal,
        (a.total_amt_for_cs_calc_ot - b.total_amt_for_cs_calc_ot) AS diff_total_amt_for_cs_calc_ot,
        (a.total_amt_for_cs_calc_otoc - b.total_amt_for_cs_calc_otoc) AS diff_total_amt_for_cs_calc_otoc,
        (a.total_amt_for_cs_calc_otcc - b.total_amt_for_cs_calc_otcc) AS diff_total_amt_for_cs_calc_otcc,
        (a.total_amt_for_cs_calc_otsal - b.total_amt_for_cs_calc_otsal) AS diff_total_amt_for_cs_calc_otsal,
		a.category_code as category_code,
		a.hoa_id as hoa_id
    INTO 
        v_diff_total_amt_for_cs_calc_sc,
        v_diff_total_amt_for_cs_calc_scoc,
        v_diff_total_amt_for_cs_calc_sccc,
        v_diff_total_amt_for_cs_calc_scsal,
        v_diff_total_amt_for_cs_calc_st,
        v_diff_total_amt_for_cs_calc_stoc,
        v_diff_total_amt_for_cs_calc_stcc,
        v_diff_total_amt_for_cs_calc_stsal,
        v_diff_total_amt_for_cs_calc_ot,
        v_diff_total_amt_for_cs_calc_otoc,
        v_diff_total_amt_for_cs_calc_otcc,
        v_diff_total_amt_for_cs_calc_otsal,
		v_category_code,
		v_hoa_id
    FROM 
    (
        SELECT total_amt_for_cs_calc_sc, 
               total_amt_for_cs_calc_scoc, 
               total_amt_for_cs_calc_sccc,
               total_amt_for_cs_calc_scsal,
               total_amt_for_cs_calc_st,
               total_amt_for_cs_calc_stoc,
			   total_amt_for_cs_calc_stcc,
			   total_amt_for_cs_calc_stsal,
               total_amt_for_cs_calc_ot, 
               total_amt_for_cs_calc_otoc, 
               total_amt_for_cs_calc_otcc, 
               total_amt_for_cs_calc_otsal,
			   category_code,
		       hoa_id
        FROM billing.tr_26a_detail 
        WHERE bill_id = (in_payload->>'BillId')::bigint
    ) a
    JOIN 
    (
        SELECT SUM(total_amt_for_cs_calc_sc) AS total_amt_for_cs_calc_sc, 
               SUM(total_amt_for_cs_calc_scoc) AS total_amt_for_cs_calc_scoc, 
               SUM(total_amt_for_cs_calc_sccc) AS total_amt_for_cs_calc_sccc, 
               SUM(total_amt_for_cs_calc_scsal) AS total_amt_for_cs_calc_scsal,
               SUM(total_amt_for_cs_calc_st) AS total_amt_for_cs_calc_st,
               SUM(total_amt_for_cs_calc_stoc) AS total_amt_for_cs_calc_stoc,
               SUM(total_amt_for_cs_calc_stcc) AS total_amt_for_cs_calc_stcc,
               SUM(total_amt_for_cs_calc_stsal) AS total_amt_for_cs_calc_stsal,
               SUM(total_amt_for_cs_calc_ot) AS total_amt_for_cs_calc_ot, 
               SUM(total_amt_for_cs_calc_otoc) AS total_amt_for_cs_calc_otoc, 
               SUM(total_amt_for_cs_calc_otcc) AS total_amt_for_cs_calc_otcc, 
               SUM(total_amt_for_cs_calc_otsal) AS total_amt_for_cs_calc_otsal
        FROM jit.tsa_exp_details 
        WHERE ref_no = ANY(jit_ref_no_array)
    ) b ON 1=1;
	
	SELECT 
        jsonb_agg(jsonb_build_object(
            'payeeName', ecs.payee_name,
            'beneficiaryId', ecs.beneficiary_id,
            'panNo', ecs.pan_no,
            'ifscCode', ecs.ifsc_code,
            'bankAccountNumber', ecs.bank_account_number,
            'amount', ecs.amount,
            'jitRefNo', addi.jit_reference_no
        )) AS ecs_details,
        jsonb_agg(jsonb_build_object(
            'payeeName', ecs.payee_name,
            'beneficiaryId', ecs.beneficiary_id,
            'jitRefNo', addi.jit_reference_no,
            'aadhar', addi.aadhar,
            'endToEnd', addi.end_to_end_id,
            'grossAmount', addi.gross_amount,
            'netAmount', addi.net_amount,
            'reissueAmount', addi.reissue_amount,
            'topUpAmount', addi.top_up,
            'agencyCode', addi.agency_code,
            'agencyName', addi.agency_name,
            'districtLgdCode', addi.districtcodelgd
        )) AS jit_ecs_detail,
		jsonb_agg(jsonb_build_object(
            'payeeId', ecs.beneficiary_id,
            'agencyCode', addi.agency_code,
            'agencyName', addi.agency_name
        )) AS agency_detail
    INTO ecs_detail, jit_ecs_detail, agency_detail
    FROM billing.bill_ecs_neft_details ecs
    JOIN billing.jit_ecs_additional addi
    ON ecs.id = addi.ecs_id
    WHERE ecs.bill_id = (in_payload->>'BillId')::bigint
      AND ecs.is_cancelled <> true;
	
    -- Construct the JSONB output
    _out_jit_cancelled_fto := jsonb_build_object(
		'category_code', v_category_code,
		'category_code', v_category_code,
		'hoa_id', v_hoa_id,
		'scheme_code', v_scheme_code,
		'scheme_name', v_scheme_name,
        'gross_amount_diff', v_gross_amount_diff,
        'net_amount_diff', v_net_amount_diff,
        'diff_total_amt_for_cs_calc_sc', v_diff_total_amt_for_cs_calc_sc,
        'diff_total_amt_for_cs_calc_scoc', v_diff_total_amt_for_cs_calc_scoc,
        'diff_total_amt_for_cs_calc_sccc', v_diff_total_amt_for_cs_calc_sccc,
        'diff_total_amt_for_cs_calc_scsal', v_diff_total_amt_for_cs_calc_scsal,
        'diff_total_amt_for_cs_calc_st', v_diff_total_amt_for_cs_calc_st,
        'diff_total_amt_for_cs_calc_stoc', v_diff_total_amt_for_cs_calc_stoc,
        'diff_total_amt_for_cs_calc_stcc', v_diff_total_amt_for_cs_calc_stcc,
        'diff_total_amt_for_cs_calc_stsal', v_diff_total_amt_for_cs_calc_stsal,
        'diff_total_amt_for_cs_calc_ot', v_diff_total_amt_for_cs_calc_ot,
        'diff_total_amt_for_cs_calc_otoc', v_diff_total_amt_for_cs_calc_otoc,
        'diff_total_amt_for_cs_calc_otcc', v_diff_total_amt_for_cs_calc_otcc,
        'diff_total_amt_for_cs_calc_otsal', v_diff_total_amt_for_cs_calc_otsal,
		'ecsDetail', ecs_detail,
        'jitEcsDetail', jit_ecs_detail,
        'voucherDetails', voucher_detail,
        'componentDetail', component_detail,
		'btDetail', bt_detail,
		'jitRefs', jit_ref_detail,
		'agencyDetail', agency_detail
    );
END;
$$;


ALTER PROCEDURE billing.jit_cancelled_fto_data(IN in_payload jsonb, OUT _out_jit_cancelled_fto jsonb) OWNER TO postgres;

--
-- TOC entry 428 (class 1255 OID 920228)
-- Name: pfms_file_status_send_to_jit(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.pfms_file_status_send_to_jit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    jit_pfms_file_status jsonb;
BEGIN
	WITH bill_data AS (
        SELECT 
            status.bill_id, 
			status.file_name,
            array_agg(imap.jit_ref_no) AS ref_nos, 
            status.payment_status, 
			status.sanction_status, 
            status.status_received_at
        FROM billing.ebill_jit_int_map imap
        INNER JOIN billing.billing_pfms_file_status_details status using(bill_id)
       	WHERE status.bill_id = NEW.bill_id
	        AND status.payment_status = NEW.payment_status
			AND status.sanction_status = NEW.sanction_status
			AND status.status_received_at = NEW.status_received_at
	        AND NEW.send_to_jit = false
		GROUP BY status.bill_id, status.file_name, status.payment_status, status.sanction_status, status.status_received_at
    )
    SELECT json_agg(json_build_object(
        'BillId', bill_data.bill_id,
        'JitRefNos', bill_data.ref_nos,
		'FileName', bill_data.file_name,
        'PaymentStatus', bill_data.payment_status,
		'SanctionStatus', bill_data.sanction_status,
        'StatusReceivedAt', bill_data.status_received_at
	)) INTO jit_pfms_file_status FROM bill_data;

 -- Insert data into the queue if valid
    IF jit_pfms_file_status IS NOT NULL THEN
        PERFORM message_queue.insert_message_queue(
            'bill_jit_pfms_file_status', jit_pfms_file_status
        );
		
		-- Update `send_to_jit` column only for matching records in `bill_data`
		UPDATE billing.billing_pfms_file_status_details
		SET send_to_jit = true
		WHERE bill_id = NEW.bill_id
	        AND payment_status = NEW.payment_status
			AND sanction_status = NEW.sanction_status
			AND status_received_at = NEW.status_received_at
	        AND NEW.send_to_jit = false;
    END IF;
	
    RETURN NULL;
END;
$$;


ALTER FUNCTION billing.pfms_file_status_send_to_jit() OWNER TO postgres;

--
-- TOC entry 482 (class 1255 OID 920229)
-- Name: sys_generated_bill_no_seq(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.sys_generated_bill_no_seq(IN sys_generated_bill_no_payload jsonb, OUT _out_bill_no character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
	_tmp_bill_no character varying;
	_bill_no bigint;
	_flag smallint;
	_application_type character varying;
BEGIN
	-- Generate BILLNO
	_flag = (sys_generated_bill_no_payload->>'Flag')::smallint;
	_application_type = sys_generated_bill_no_payload->>'ApplicationType';
	
	EXECUTE format('SELECT nextval(%L)', 'billing.sys_generated_bill_no_seq') INTO _bill_no;

	_tmp_bill_no := _application_type || _flag || LPAD(_bill_no::text, 8, '0');
	-- 	SELECT nextval('billing.sys_generated_bill_no_seq');
	
	RAISE NOTICE 'generated_flag %', _flag;
	RAISE NOTICE 'generated_bill_no %', _bill_no;
	RAISE NOTICE 'generated_bill_no %', _tmp_bill_no;
	RAISE NOTICE 'generated_application_type %', _application_type;
	
	_out_bill_no = _tmp_bill_no;
END;
$$;


ALTER PROCEDURE billing.sys_generated_bill_no_seq(IN sys_generated_bill_no_payload jsonb, OUT _out_bill_no character varying) OWNER TO postgres;

--
-- TOC entry 466 (class 1255 OID 920230)
-- Name: trg_adjust_allotment_by_billid(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.trg_adjust_allotment_by_billid() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	financial_year smallint;
BEGIN
	-- 8 for Return Memo Generated
	--56 Bill Rejected By PFMS
	--57 Rejected By RBI
	--105 Bill Pending for Regeneration [Case when single bill single FTO and single bill multiple FTO]
	--106 for Bill Cancelled by DDO

	-- IF (new.status = 106 OR (new.status = 105 AND new.is_regenerated = true) OR (new.status = 8 AND new.is_regenerated = true)) THEN 
		PERFORM bantan.adjust_allotment_by_billid(NEW.bill_id); 
	-- END IF;
	
    RETURN NEW;
END;
$$;


ALTER FUNCTION billing.trg_adjust_allotment_by_billid() OWNER TO postgres;

--
-- TOC entry 453 (class 1255 OID 920231)
-- Name: update_bill_detail_prov(bigint, bigint); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.update_bill_detail_prov(v_bill_id bigint, v_allotment_id bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_amount BIGINT;
BEGIN
	SELECT sum(amount) into v_amount from billing.ddo_allotment_booked_bill where bill_id<=v_bill_id and allotment_id=v_allotment_id;
	
    RETURN v_amount;
END;
$$;


ALTER FUNCTION billing.update_bill_detail_prov(v_bill_id bigint, v_allotment_id bigint) OWNER TO postgres;

--
-- TOC entry 460 (class 1255 OID 920232)
-- Name: update_cpin_ecs(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing.update_cpin_ecs() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE 
	gst_cpin character varying;
BEGIN
	IF NEW.is_deleted = true THEN
		SELECT cpin_id into gst_cpin from  billing_master.cpin_master where id=NEW.cpin_id;
		DELETE FROM billing.bill_ecs_neft_details where bank_account_number=gst_cpin and bill_id = NEW.bill_id and ifsc_code='RBIS0GSTPMT';
	END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION billing.update_cpin_ecs() OWNER TO postgres;

--
-- TOC entry 483 (class 1255 OID 920233)
-- Name: update_incorrect_beneficiary_dtl(jsonb); Type: PROCEDURE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing.update_incorrect_beneficiary_dtl(IN correct_beneficiary_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
      status smallint;
	  wrong_record cts.failed_transaction_beneficiary%ROWTYPE;
BEGIN
  --checking already corrected or not
  SELECT is_corrected INTO status FROM cts.failed_transaction_beneficiary WHERE cts.failed_transaction_beneficiary.id = (correct_beneficiary_payload->>'Id')::bigint;
  IF (status<>0)
       THEN
        RAISE EXCEPTION 'Beneficiary details already corrected.';
       END IF;
  --update the flag of the incorrect beneficiary table
  UPDATE cts.failed_transaction_beneficiary
  SET  is_corrected = 1,
       corrected_at=now(),
        corrected_by=(correct_beneficiary_payload->>'CreatedByUserid')::bigint
  WHERE cts.failed_transaction_beneficiary.id=(correct_beneficiary_payload->>'Id')::bigint;
  SELECT * INTO wrong_record FROM cts.failed_transaction_beneficiary WHERE cts.failed_transaction_beneficiary.id = (correct_beneficiary_payload->>'Id')::bigint; 

 INSERT INTO epradan.corrected_beneficiary_details(
		bill_id, ddo_code, treasury_code, payee_name,account_no,ifsc_code,bank_name,created_by_userid,corrected_by,  financial_year,failed_transaction_amount )
        VALUES (
             wrong_record.bill_id,  wrong_record.ddo_code , wrong_record.treasury_code,wrong_record.payee_name,correct_beneficiary_payload->>'AccountNo',  
			  correct_beneficiary_payload->>'IfscCode', wrong_record.bank_name, wrong_record.corrected_by, wrong_record.corrected_by,wrong_record.financial_year ,wrong_record.failed_transaction_amount);

END;
$$;


ALTER PROCEDURE billing.update_incorrect_beneficiary_dtl(IN correct_beneficiary_payload jsonb) OWNER TO postgres;

--
-- TOC entry 465 (class 1255 OID 920234)
-- Name: log_table_changes(); Type: FUNCTION; Schema: billing_log; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing_log.log_table_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    changed_by_userid bigint;
    has_created_by boolean;
    has_updated_by boolean;
BEGIN
    -- Check if 'created_by_userid' column exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = TG_TABLE_NAME
          AND column_name = 'created_by_userid'
    ) INTO has_created_by;

    -- Check if 'updated_by_userid' column exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = TG_TABLE_NAME
          AND column_name = 'updated_by_userid'
    ) INTO has_updated_by;

    -- Handle DELETE
    IF (TG_OP = 'DELETE') THEN
        IF has_updated_by THEN
            changed_by_userid := OLD.updated_by_userid;
        ELSE
            changed_by_userid := NULL;
        END IF;

        INSERT INTO billing_log.audit_log (
            id,
            schema_name, 
            table_name, 
            operation_type, 
            old_data, 
            changed_by, 
            change_timestamp
        )
        VALUES (
            nextval('billing_log.audit_log_id_seq'),
            TG_TABLE_SCHEMA,
            TG_TABLE_NAME,
            TG_OP,
            row_to_json(OLD),
            changed_by_userid,
            current_timestamp
        );

    -- Handle INSERT
    ELSIF (TG_OP = 'INSERT') THEN
        IF has_created_by THEN
            changed_by_userid := NEW.created_by_userid;
        ELSE
            changed_by_userid := NULL;
        END IF;

        INSERT INTO billing_log.audit_log (
            id,
            schema_name, 
            table_name, 
            operation_type, 
            new_data, 
            changed_by, 
            change_timestamp
        )
        VALUES (
            nextval('billing_log.audit_log_id_seq'),
            TG_TABLE_SCHEMA,
            TG_TABLE_NAME,
            TG_OP,
            row_to_json(NEW),
            changed_by_userid,
            current_timestamp
        );

    -- Handle UPDATE
    ELSIF (TG_OP = 'UPDATE') THEN
        IF has_updated_by THEN
            changed_by_userid := NEW.updated_by_userid;
        ELSE
            changed_by_userid := NULL;
        END IF;

        INSERT INTO billing_log.audit_log (
            id,
            schema_name, 
            table_name, 
            operation_type, 
            old_data, 
            new_data, 
            changed_by, 
            change_timestamp
        )
        VALUES (
            nextval('billing_log.audit_log_id_seq'),
            TG_TABLE_SCHEMA,
            TG_TABLE_NAME,
            TG_OP,
            row_to_json(OLD),
            row_to_json(NEW),
            changed_by_userid,
            current_timestamp
        );
    END IF;

    RETURN NULL; -- Trigger is for logging only
END;
$$;


ALTER FUNCTION billing_log.log_table_changes() OWNER TO postgres;

--
-- TOC entry 430 (class 1255 OID 920235)
-- Name: delete_cpin(bigint, text); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.delete_cpin(IN v_bill_id bigint, IN cpin_number text)
    LANGUAGE plpgsql
    AS $$
DECLARE
   _cpin_id bigint;
BEGIN
	SELECT id into _cpin_id from billing_master.cpin_master b where b.cpin_id=cpin_number;
 
    -- Step 1: update bill_gst table
    UPDATE billing.bill_gst 
    SET is_deleted = true
	where cpin_id = _cpin_id and bill_id= v_bill_id ;

	-- Step 2: update JIT gst table
	update jit.gst
	set is_mapped = false, cpin_id=null
	where bill_id = v_bill_id and cpin_id = _cpin_id;

	-- Update cpin master set active as false

	update billing_master.cpin_master
	set is_active=false where id=_cpin_id;
END;
$$;


ALTER PROCEDURE billing_master.delete_cpin(IN v_bill_id bigint, IN cpin_number text) OWNER TO postgres;

--
-- TOC entry 451 (class 1255 OID 920236)
-- Name: delete_cpin_old1(text); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.delete_cpin_old1(IN cpin_number text)
    LANGUAGE plpgsql
    AS $$
DECLARE
   
BEGIN
    -- Step 1: update bill_gst table
    UPDATE billing.bill_gst g
    SET is_deleted = 'TRUE'
	from billing_master.cpin_master b
	where b.id = g.cpin_id and  b.cpin_id=cpin_number;
-- Step 2: update gst table
		update jit.gst g
		set is_mapped = false
		from
			billing_master.cpin_vender_mst v
			left join billing_master.cpin_master cm
			on cm.id = v.cpinmstid
			where g.payee_gst_in = v.vendorgstin
		    and g.payee_id = v.ben_ref_id
		    and cm.cpin_id = cpin_number;

    RAISE NOTICE 'Procedure executed successfully.';
END;
$$;


ALTER PROCEDURE billing_master.delete_cpin_old1(IN cpin_number text) OWNER TO postgres;

--
-- TOC entry 436 (class 1255 OID 920237)
-- Name: delete_cpin_old2(bigint, text); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.delete_cpin_old2(IN bill_id bigint, IN cpin_number text)
    LANGUAGE plpgsql
    AS $$
DECLARE
   _cpin_id bigint;
BEGIN
	 -- Fetch cpin_id
    SELECT id INTO _cpin_id 
    FROM billing_master.cpin_master c
    WHERE c.cpin_id = cpin_number;

    -- Check if CPIN ID exists before updating
    IF _cpin_id IS NOT NULL THEN
        -- Step 1: Update bill_gst table
        UPDATE billing.bill_gst 
        SET is_deleted = true
        WHERE cpin_id = _cpin_id AND bill_id = bill_id;

        -- Step 2: Update JIT gst table
        UPDATE jit.gst 
        SET is_mapped = false, cpin_id=null
        WHERE bill_id = bill_id AND cpin_id = _cpin_id;
    ELSE
        RAISE NOTICE 'CPIN number % not found in cpin_master', cpin_number;
    END IF;
	
END;
$$;


ALTER PROCEDURE billing_master.delete_cpin_old2(IN bill_id bigint, IN cpin_number text) OWNER TO postgres;

--
-- TOC entry 497 (class 1255 OID 920238)
-- Name: get_cpin_vender_details(character varying, integer, integer); Type: FUNCTION; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing_master.get_cpin_vender_details(v_cpinid character varying, p_page_number integer DEFAULT 1, p_page_size integer DEFAULT 10) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE 
    result JSON;
    total_count BIGINT;
    p_offset INTEGER;
BEGIN
    -- Calculate OFFSET for pagination
    p_offset := (p_page_number - 1) * p_page_size;

    -- Get total count with filtering (including DDO Code match)
    SELECT COUNT(*) INTO total_count
    FROM billing_master.cpin_master cm
    INNER JOIN billing_master.cpin_vender_mst cvm ON cm.id = cvm.cpinmstid;
    -- INNER JOIN epradan.beneficiary_dtl bd ON ful.benf_id = bd.benf_id
    -- WHERE ful.fav_list_id = p_fav_list_id  
    -- AND fl.ddo_code = v_ddo_code  -- Ensuring provided DDO Code matches
    -- AND fl.ddo_code = bd.ddo_code
    --AND (p_vendor_name IS NULL OR cvm.vendorname ILIKE '%' || p_vendor_name || '%')
    --AND (p_cpin_id IS NULL OR cm.cpin_id ILIKE '%' || p_cpin_id || '%');

    -- Get paginated data with filtering
    SELECT json_build_object(
        'TotalCount', total_count,
        'PageNumber', p_page_number,
        'PageSize', p_page_size,
        'Data', COALESCE(json_agg(
            json_build_object(
                'CpinId', paginated_results.cpin_id,
                'CpinAmount', paginated_results.cpin_amount,
                'VendorName', paginated_results.vendorname
    --             'BenfId', paginated_results.benf_id,
    --             'BenfName', paginated_results.benf_name,
    --             'BenfEmail', paginated_results.benf_email_id,
    --             'BenfMobile', paginated_results.benf_mobile_number,
    --             'BenfAddress', paginated_results.benf_address,
    --             'BenfAccountNo', paginated_results.benf_acct_no,
    --             'BankIFSC', paginated_results.benf_bank_ifsc_code,
    --             'BankName', paginated_results.bankname, 
    --             'AccountType', paginated_results.account_type,
    --             'AadharNo', paginated_results.adhar_no,
    --             'RefCode', paginated_results.ref_code,
    --             'PAN', paginated_results.pan,
    --             'GPFNo', paginated_results.gpf_no,
    --             'BenfType', paginated_results.benf_type,
    --             'BenfGroup', paginated_results.benf_group,
    --             'BenfDdoCode', paginated_results.benf_ddo_code,
				-- 'Amount',paginated_results.amount
            )
        ), '[]'::JSON) -- Return empty array if no records
    ) INTO result
    FROM (
        -- Paginated and filtered query with Bank Name
        SELECT 
            cm.cpin_id, 
            cm.cpin_amount, 
            cvm.vendorname
   --          ful.benf_id, 
   --          bd.benf_name, 
   --          bd.benf_email_id, 
   --          bd.benf_mobile_number, 
   --          bd.benf_address, 
   --          bd.benf_acct_no, 
   --          bd.benf_bank_ifsc_code, 
   --          rbi.bankname,
   --          bd.account_type, 
   --          bd.adhar_no, 
   --          bd.ref_code, 
   --          bd.pan, 
   --          bd.gpf_no, 
   --          bd.benf_type, 
   --          bd.benf_group, 
   --          bd.ddo_code AS benf_ddo_code,
			-- ful.amount
        FROM billing_master.cpin_master cm
            
        INNER JOIN 
          billing_master.cpin_vender_mst cvm ON cm.id = cvm.cpinmstid
           -- AND (p_vendor_name IS NULL OR cvm.vendorname ILIKE '%' || p_vendor_name || '%')
           -- AND (p_cpin_id IS NULL OR cm.cpin_id ILIKE '%' || p_cpin_id || '%')
        ORDER BY cm.id 
        LIMIT p_page_size OFFSET p_offset
    ) AS paginated_results;

    RETURN result;
END;
$$;


ALTER FUNCTION billing_master.get_cpin_vender_details(v_cpinid character varying, p_page_number integer, p_page_size integer) OWNER TO postgres;

--
-- TOC entry 426 (class 1255 OID 920239)
-- Name: get_ddo_allotment(bigint, text); Type: FUNCTION; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing_master.get_ddo_allotment(activehoaid bigint, ddocode text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    WITH expenditure AS (
        SELECT 
            COALESCE(SUM(b.gross_amount), 0) AS total_expenditure
        FROM billing.bill_details b
        JOIN billing.bill_subdetail_info bs ON bs.bill_id = b.bill_id 
        WHERE b.ddo_code = ddoCode 
          AND bs.active_hoa_id = activeHoaId
    ),
    treasury_expenditure AS (
        SELECT 
            COALESCE(SUM(b.gross_amount), 0) AS total_treasury
        FROM billing.bill_details b
        JOIN billing.bill_subdetail_info bs ON bs.bill_id = b.bill_id 
        WHERE b.ddo_code = ddoCode 
          AND b.status = 5
          AND bs.active_hoa_id = activeHoaId
    )
    SELECT jsonb_build_object(
        'ActiveHoaId', w.active_hoa_id,
        'SaoDdoCode', w.sao_ddo_code,
        'DdoDesignation', COALESCE(d.designation, ''),
        'FinancialYear', w.financial_year,
        'ReceivedAmount', w.ceiling_amount,
        'ProgressiveExpenditureAmount', e.total_expenditure,
        'AvailableDdoAmount', w.ceiling_amount - e.total_expenditure,
        'AvailableTreasuryAmount', w.ceiling_amount - t.total_treasury
    ) INTO result
    FROM bantan.ddo_wallet w
    LEFT JOIN master.ddo d ON w.sao_ddo_code = d.ddo_code
    LEFT JOIN expenditure e ON TRUE
    LEFT JOIN treasury_expenditure t ON TRUE
    WHERE w.active_hoa_id = activeHoaId 
      AND w.sao_ddo_code = ddoCode;

    RETURN result;
END;
$$;


ALTER FUNCTION billing_master.get_ddo_allotment(activehoaid bigint, ddocode text) OWNER TO postgres;

--
-- TOC entry 481 (class 1255 OID 920240)
-- Name: getcpinwithdetails(text); Type: FUNCTION; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE FUNCTION  billing_master.getcpinwithdetails(cpinidparam text) RETURNS TABLE(cpinid character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT cm.cpin_id, cvm.vendorname, cvm.vendorgstin
    FROM billing_master.cpin_master cm
    INNER JOIN billing_master.cpin_vender_mst cvm ON cm.id = cvm.cpinmstid
    WHERE cm.cpin_id = CpinIdParam;
END;
$$;


ALTER FUNCTION billing_master.getcpinwithdetails(cpinidparam text) OWNER TO postgres;

--
-- TOC entry 425 (class 1255 OID 920241)
-- Name: jit_insert_cpinmaster_cpinvendormst_billgst(jsonb); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.jit_insert_cpinmaster_cpinvendormst_billgst(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_bill_id numeric;
    cpin_detail jsonb;
    inserted_cpin bigint;
    -- vendor_detail jsonb;
	_ddo_gst_in character varying;
	_financial_year_id smallint;
BEGIN
    -- Extract BillId
    v_bill_id = (in_payload->>'BillId')::numeric;

	_ddo_gst_in = (in_payload->>'DdoGSTIN');
	-- Get Current Financial Year
    SELECT  id into _financial_year_id from master.financial_year_master
	where is_active=true;

    -- Loop over each CpinDetail in the payload
    FOR cpin_detail IN
        SELECT * FROM jsonb_array_elements(in_payload->'CpinDetails')
    LOOP
		--RETURN ERROR IN CASE GSTIN NOT AVAILABLE
		
        -- INSERT INTO CPIN MASTER
        INSERT INTO billing_master.cpin_master (
            cpin_id, cpin_amount, cpin_date, cpin_type
			, created_at, created_by_userid
			, ddo_gstin
			, vendor_data, financial_year
        )
        VALUES (
            (cpin_detail->>'CpinId')::numeric,
            (cpin_detail->>'CpinAmount')::bigint,
            (cpin_detail->>'CpinDate')::date,
            (cpin_detail->>'CpinType')::int,
            now(),
			(in_payload->>'CreatedByUserid')::bigint,
			_ddo_gst_in,
			(cpin_detail->'VendorData'), _financial_year_id

        )
        RETURNING id, (cpin_detail->>'CpinId')::numeric AS cpin_id INTO inserted_cpin;
		
		INSERT INTO billing.bill_gst (
            bill_id, cpin_id
			, ddo_gstn, ddo_code, created_by_userid
			, created_at, tr_id,financial_year
        )
        VALUES( 
            v_bill_id,
            inserted_cpin,
            _ddo_gst_in,
            in_payload->>'DdoCode',
			(in_payload->>'CreatedByUserid')::bigint,
            now(),
            (in_payload->>'TrId')::smallint,
			_financial_year_id
		);
		-- Insert Vendor details into cpin_vender_mst
		INSERT INTO billing_master.cpin_vender_mst (
			cpinmstid, vendorname, vendorgstin, invoiceno, invoicedate, 
			invoicevalue, amountpart1, amountpart2, total
			, created_at, created_by_userid, ben_ref_id
		)
		SELECT inserted_cpin, vendor_detail->>'VendorName', vendor_detail->>'VendorGstIn',
			vendor_detail->>'InvoiceNo', (vendor_detail->>'InvoiceDate')::timestamp,
			(vendor_detail->>'InvoiceValue')::double precision, (vendor_detail->>'AmountPart1')::double precision,
			(vendor_detail->>'AmountPart2')::double precision, (vendor_detail->>'Total')::double precision,
			now(), (in_payload->>'CreatedByUserid')::bigint, (vendor_detail->>'BenRefId')::bigint
		FROM jsonb_array_elements(cpin_detail->'VendorData') vendor_detail;

		--UPDATE JIT GST
		UPDATE jit.gst 
		SET is_mapped = true, cpin_id=inserted_cpin
		FROM jsonb_array_elements(cpin_detail->'VendorData') vendor_detail
		where bill_id= v_bill_id and payee_id=(vendor_detail->>'BenRefId')::bigint and invoice_no=vendor_detail->>'InvoiceNo';
    END LOOP;
END;
$$;


ALTER PROCEDURE billing_master.jit_insert_cpinmaster_cpinvendormst_billgst(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 473 (class 1255 OID 920242)
-- Name: jit_insert_cpinmaster_cpinvendormst_billgst_old1(jsonb); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.jit_insert_cpinmaster_cpinvendormst_billgst_old1(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    item jsonb;
    new_cpin_id bigint;  -- Variable to store the newly inserted ID
	cpin_master_payload jsonb;
	cpin_vendor_payload jsonb;
	bill_payload jsonb;
	total_cpin_amount bigint;
BEGIN

	RAISE NOTICE 'bill details %', in_payload;
	cpin_master_payload = in_payload->'CPinData';
	cpin_vendor_payload = in_payload->'VendorData';
	bill_payload = in_payload->'BillGstData';
	
    -- Insert into cpin_master and get the new cpin_id
    INSERT INTO billing_master.cpin_master (
        cpin_id,
        cpin_amount,
        cpin_date,
        cpin_type,
        cpin_sub_type,
        created_by_userid,
        created_at,
        ddo_gstin,
        vendor_data
    )
    VALUES (
        cpin_master_payload->>'CpinId',
        (cpin_master_payload->>'CpinAmount')::bigint,
        (cpin_master_payload->>'CpinDate')::date,
        (cpin_master_payload->>'CpinType')::int,
        (cpin_master_payload->>'CpinSubType')::int,
        (cpin_master_payload->>'CreatedByUserid')::bigint,
        now(),
        cpin_master_payload->>'DdoGstin',
        (cpin_master_payload->>'VendorData')::jsonb
    )
    RETURNING id INTO new_cpin_id;  -- Capture the inserted ID

-----    Loop through each JSON object in the array
    FOR item IN SELECT * FROM jsonb_array_elements(cpin_vendor_payload)
    LOOP
        -- Insert each JSON object into the table using the new_cpin_id
        INSERT INTO billing_master.cpin_vender_mst (
            cpinmstid,
            vendorname,
            vendorgstin,
            invoiceno,
            invoicedate,
            invoicevalue,
            amountpart1,
            amountpart2,
            total,
            created_by_userid,
            created_at
        )
        VALUES (
            new_cpin_id,  -- Use the newly inserted cpin_id
            item->>'VendorName',
            item->>'VendorGstIn',
            item->>'InvoiceNo',
            (item->>'InvoiceDate')::timestamp without time zone,
            (item->>'InvoiceValue')::DOUBLE PRECISION,
            (item->>'AmountPart1')::DOUBLE PRECISION,
            (item->>'AmountPart2')::DOUBLE PRECISION,
            (item->>'Total')::DOUBLE PRECISION,
            (item->>'CreatedByUserid')::bigint,
            now()
        );
    END LOOP;
			
	 --- Insert into bill_gst with the new cpin_id
		INSERT INTO billing.bill_gst (
			bill_id, cpin_id, ddo_gstn, ddo_code, created_at, tr_id
		)
		VALUES (
			(bill_payload->>'BillId')::numeric,
			new_cpin_id,
			in_payload->>'DdoGstIn',
			in_payload->>'DdoCode',
			now(),
			(bill_payload->>'TrId')::smallint
		);
		
	
END;
$$;


ALTER PROCEDURE billing_master.jit_insert_cpinmaster_cpinvendormst_billgst_old1(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 462 (class 1255 OID 920243)
-- Name: jit_insert_cpinmaster_cpinvendormst_billgst_old2(jsonb); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.jit_insert_cpinmaster_cpinvendormst_billgst_old2(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_bill_id numeric;
    cpin_detail jsonb;
    inserted_cpin bigint;
    vendor_detail jsonb;
	_ddo_gst_in character varying;
BEGIN
    -- Extract BillId
    v_bill_id = (in_payload->>'BillId')::numeric;

    -- Loop over each CpinDetail in the payload
    FOR cpin_detail IN
        SELECT * FROM jsonb_array_elements(in_payload->'CpinDetails')
    LOOP
		SELECT gstin into _ddo_gst_in 
		FROM master.ddo 
		WHERE ddo_code = in_payload->>'DdoCode';
		
        -- Insert into cpin_master for each cpin_detail
        INSERT INTO billing_master.cpin_master (
            cpin_id, cpin_amount, cpin_date, cpin_type
-- 			, cpin_sub_type
-- 			, created_by_userid
			, created_at
			, ddo_gstin
			, vendor_data
        )
        VALUES (
            (cpin_detail->>'CpinId')::numeric,
            (cpin_detail->>'CpinAmount')::bigint,
            (cpin_detail->>'CpinDate')::date,
            (cpin_detail->>'CpinType')::int,
--             (cpin_detail->>'CpinSubType')::int,
--             (cpin_detail->>'CreatedByUserid')::bigint,
            now(),
			_ddo_gst_in,
			(cpin_detail->'VendorData')
        )
        RETURNING id, (cpin_detail->>'CpinId')::numeric AS cpin_id INTO inserted_cpin;
		
		INSERT INTO billing.bill_gst (
            bill_id, cpin_id
			, ddo_gstn, ddo_code
			, created_at, tr_id
        )
        VALUES( 
            v_bill_id,
            inserted_cpin,
            _ddo_gst_in,
            in_payload->>'DdoCode',
            now(),
            (in_payload->>'TrId')::smallint
		);

        -- Loop through VendorDetails for each inserted cpin
        FOR vendor_detail IN
            SELECT * FROM jsonb_array_elements(cpin_detail->'VendorData')
        LOOP
            -- Insert Vendor details into cpin_vender_mst
            INSERT INTO billing_master.cpin_vender_mst (
                cpinmstid, vendorname, vendorgstin, invoiceno, invoicedate, 
                invoicevalue, amountpart1, amountpart2, total
-- 				, created_by_userid
				, created_at
            )
            VALUES (
                inserted_cpin,
                vendor_detail->>'VendorName',
                vendor_detail->>'VendorGstIn',
                vendor_detail->>'InvoiceNo',
                (vendor_detail->>'InvoiceDate')::timestamp,
                (vendor_detail->>'InvoiceValue')::double precision,
                (vendor_detail->>'AmountPart1')::double precision,
                (vendor_detail->>'AmountPart2')::double precision,
                (vendor_detail->>'Total')::double precision,
--                 (vendor_detail->>'CreatedByUserid')::bigint,
                now()
            );
        END LOOP;

    END LOOP;

    -- Update bill_details with the total GST amount
    UPDATE billing.bill_details
    SET is_gst = true
-- 	,
--         gst_amount = (SELECT SUM((cpin_de->>'CpinAmount')::bigint) FROM jsonb_array_elements(in_payload->'CpinDetails') AS cpin_de)
    WHERE bill_id = v_bill_id;

	--UPDATE GST TABLE WITH CPIN ID
    UPDATE jit.gst set cpin_id=inserted_cpin 
	FROM jsonb_array_elements(cpin_detail->'VendorData') data
	where bill_id=v_bill_id and payee_gst_in=data->>'VendorGstIn';

END;
$$;


ALTER PROCEDURE billing_master.jit_insert_cpinmaster_cpinvendormst_billgst_old2(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 419 (class 1255 OID 920244)
-- Name: update_ddo_transfer_details(jsonb); Type: PROCEDURE; Schema: billing_master; Owner: postgres
--

CREATE OR REPLACE PROCEDURE billing_master.update_ddo_transfer_details(IN ddo_transfer_details_payload jsonb)
    LANGUAGE plpgsql
    AS $$

Declare 
    _consumer_id character(15);
    _to_ddo character(9);
    _from_ddo character(9);
    _service_provider_id bigint;
    status smallint;
    
BEGIN
            _consumer_id := ddo_transfer_details_payload->>'ConsumerId';
            _to_ddo := ddo_transfer_details_payload->>'ToDdo';
            _from_ddo := ddo_transfer_details_payload->>'DdoCode';
            _service_provider_id :=ddo_transfer_details_payload->>'ServiceProviderId';

            UPDATE billing.service_provider_consumer_ddo_transfer_request A
            SET status= 1
--             FROM billing_master.ddo_transfer_request A
            WHERE A.to_ddo=_to_ddo and A.from_ddo=_from_ddo and TRIM(A.consumer_id)=_consumer_id;

             -- Check if the update was successful
    IF NOT FOUND THEN
        status := 0; -- Update failed
        RETURN;
    END IF;

            ---update for service Provider Consumer Master
           UPDATE billing_master.service_provider_consumer_master B
            SET ddo_code=_to_ddo
--             FROM billing_master.service_provider_consumer_master
            WHERE  B.ddo_code=_from_ddo and B.consumer_id=_consumer_id and B.service_provider_id=_service_provider_id;

 -- Check if the update was successful
    IF NOT FOUND THEN
        status := 0; -- Update failed
        RETURN;
    END IF;

status:=1;

 END;
$$;


ALTER PROCEDURE billing_master.update_ddo_transfer_details(IN ddo_transfer_details_payload jsonb) OWNER TO postgres;

--
-- TOC entry 440 (class 1255 OID 920245)
-- Name: adjust_allotment_failed_beneficiary(bigint, bigint); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.adjust_allotment_failed_beneficiary(v_bill_id bigint, v_failed_transaction_amount bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_hoa BIGINT;
    v_prov_amount     BIGINT;
	-- Variable for cumulative deduction for Failed Beneficiary
    v_total_deducted    BIGINT := 0;
	-- Record for looping through booked allotment details
    bill_allotment_rec RECORD;
	
	v_deduction BIGINT;
	v_deducted_allotments JSONB := '[]'::JSONB;

BEGIN
	v_prov_amount     := COALESCE(v_failed_transaction_amount, '0')::BIGINT;

	FOR bill_allotment_rec IN 
            SELECT dsbb.allotment_id, dsbb.amount 
            FROM billing.ddo_allotment_booked_bill AS dsbb
            WHERE dsbb.bill_id = v_bill_id
            ORDER BY dsbb.allotment_id DESC
	LOOP
		EXIT WHEN v_total_deducted >= v_prov_amount;

		v_deduction := LEAST(bill_allotment_rec.amount, v_prov_amount - v_total_deducted);

		-- Deduct the appropriate amount from the allotment master
		UPDATE bantan.ddo_allotment_transactions
		SET provisional_released_amount = GREATEST(0, provisional_released_amount - v_deduction)
			, updated_at = NOW()
		WHERE allotment_id = bill_allotment_rec.allotment_id;
		
		v_deducted_allotments := v_deducted_allotments || 
            jsonb_build_object(
                'allotment_id', bill_allotment_rec.allotment_id,
                'deducted_amount', v_deduction
            );
			
		-- Update the total deducted amount
		v_total_deducted := v_total_deducted + v_deduction;
	END LOOP;

	UPDATE bantan.ddo_wallet w
	SET provisional_released_amount = provisional_released_amount - g.adj_amount
	FROM
	(
		SELECT  active_hoa_id,receiver_sao_ddo_code, sum((e->>'deducted_amount')::bigint) as adj_amount
		from bantan.ddo_allotment_transactions t, jsonb_array_elements(v_deducted_allotments)e
		where t.allotment_id= (e->>'allotment_id')::bigint
		group by active_hoa_id, receiver_sao_ddo_code
	)g
	WHERE w.sao_ddo_code=g.receiver_sao_ddo_code and w.active_hoa_id=g.active_hoa_id;

  RETURN NULL;
END;
$$;


ALTER FUNCTION cts.adjust_allotment_failed_beneficiary(v_bill_id bigint, v_failed_transaction_amount bigint) OWNER TO postgres;

--
-- TOC entry 413 (class 1255 OID 920246)
-- Name: get_transaction_summary(); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.get_transaction_summary() RETURNS json
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN (
        SELECT json_build_object(
            'failedTransactionAmountWithGst', COALESCE((
                SELECT SUM(failed_transaction_amount)
                FROM cts.failed_transaction_beneficiary
                WHERE is_gst = true AND is_active = 1
            ), 0),
             'failedTransactionAmountWithGstCount',COALESCE((select COUNT(beneficiary_id) 
			 FROM cts.failed_transaction_beneficiary WHERE is_active = 1 and is_gst = true),0),

			 
            'failedTransactionAmountWithoutGst', COALESCE((
                SELECT SUM(failed_transaction_amount)
                FROM cts.failed_transaction_beneficiary
                WHERE is_gst = false AND is_active = 1
            ), 0),
            'failedTransactionAmountWithoutGstCount',COALESCE((SELECT COUNT(beneficiary_id)
			FROM cts.failed_transaction_beneficiary WHERE is_active = 1 and is_gst = false),0),
			 
            'successTransactionAmountWithGst', COALESCE((
                SELECT SUM(amount)
                FROM cts.success_transaction_beneficiary
                WHERE is_gst = true AND is_active = 1
            ), 0),
             'successTransactionAmountWithGstCount',COALESCE((
                SELECT COUNT(ecs_id) FROM cts.success_transaction_beneficiary
                WHERE is_gst = true AND is_active = 1
            ), 0),
            'successTransactionAmountWithoutGst', COALESCE((
                SELECT SUM(amount)
                FROM cts.success_transaction_beneficiary
                WHERE is_gst = false AND is_active = 1
            ), 0),
           'successTransactionAmountWithoutGstCount', COALESCE((
               SELECT COUNT(ecs_id) FROM cts.success_transaction_beneficiary
                WHERE is_gst = false AND is_active = 1
            ), 0),
            'totalGrossAmount', COALESCE((
                SELECT SUM(gross_amount)
                FROM billing.bill_details
            ), 0),

            'totalNetAmount', COALESCE((
                SELECT SUM(net_amount)
                FROM billing.bill_details
            ), 0),

            'totalSuccessfulAmount', COALESCE((
                SELECT SUM(amount)
                FROM cts.success_transaction_beneficiary
                WHERE is_active = 1
            ), 0),

            'totalFailedAmount', COALESCE((
                SELECT SUM(failed_transaction_amount)
                FROM cts.failed_transaction_beneficiary
                WHERE is_active = 1
            ), 0),

            'expectedTransactionCount', COALESCE((
			SELECT count(id) FROM billing.bill_ecs_neft_details
             where is_cancelled = false),0),
            

            'successfulTransactionCount', COALESCE((
                SELECT COUNT(ecs_id)
                FROM cts.success_transaction_beneficiary
                WHERE is_active = 1
            ), 0),

            'failedTransactionCount', COALESCE((
                SELECT COUNT(beneficiary_id)
                FROM cts.failed_transaction_beneficiary
                WHERE is_active = 1
            ), 0),
			
			'pendingTransactionCount', (
  
    COALESCE((SELECT count(id) FROM billing.bill_ecs_neft_details WHERE is_cancelled = false), 0)
    -
    
    (
        COALESCE((SELECT COUNT(ecs_id) FROM cts.success_transaction_beneficiary WHERE is_active = 1), 0)
        +
        COALESCE((SELECT COUNT(beneficiary_id) FROM cts.failed_transaction_beneficiary WHERE is_active = 1), 0)
    )
)
        )
    );
END;
$$;


ALTER FUNCTION cts.get_transaction_summary() OWNER TO postgres;

--
-- TOC entry 501 (class 1255 OID 920247)
-- Name: get_transaction_summary(smallint); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.get_transaction_summary(p_finyear smallint) RETURNS json
    LANGUAGE plpgsql
    AS $$
Declare
 result json;
BEGIN
   WITH
    failed_txn AS (
        SELECT *
        FROM cts.failed_transaction_beneficiary
        WHERE is_active = 1 AND financial_year = p_finyear
    ),
    success_txn AS (
        SELECT *
        FROM cts.success_transaction_beneficiary
        WHERE is_active = 1 AND financial_year = p_finyear
    ),
    current_year_success_ben AS (
        SELECT
			COUNT(1) FILTER (WHERE stb.is_gst = false) as current_year_success_ben_count,
			COUNT(1) FILTER (WHERE stb.is_gst = true) as current_year_gst_success_ben_count,
			COALESCE(SUM(amount) FILTER (WHERE stb.is_gst = false), 0) AS current_year_success_ben_amount,
			COALESCE(SUM(amount) FILTER (WHERE stb.is_gst = true), 0) AS current_year_gst_success_ben_amount
        FROM success_txn stb
		JOIN billing.bill_details bd
		ON bd.bill_id = stb.bill_id
        WHERE bd.financial_year = p_finyear AND is_active = 1 AND stb.financial_year = p_finyear
    ),
	current_year_failed_ben AS (
        SELECT
			COUNT(1) FILTER (WHERE ftb.is_gst = false) as current_year_failed_ben_count,
			COUNT(1) FILTER (WHERE ftb.is_gst = true) as current_year_gst_failed_ben_count,
			COALESCE(SUM(failed_transaction_amount) FILTER (WHERE ftb.is_gst = false), 0) AS current_year_failed_ben_amount,
			COALESCE(SUM(failed_transaction_amount) FILTER (WHERE ftb.is_gst = true), 0) AS current_year_gst_failed_ben_amount
        FROM failed_txn ftb
		JOIN billing.bill_details bd
		ON bd.bill_id = ftb.bill_id
        WHERE bd.financial_year = p_finyear AND is_active = 1 AND ftb.financial_year = p_finyear
    ),
    bill_summary AS (
        SELECT
            COALESCE(SUM(gross_amount), 0) AS total_gross,
            COALESCE(SUM(net_amount), 0) AS total_net,
			COALESCE(SUM(gst_amount), 0) AS total_gst,
			SUM(payee_count) AS total_payee_count
        FROM billing.bill_details
        WHERE is_regenerated = false AND status != 106 AND financial_year = p_finyear 
		AND status >= 5
    ),
	status_summary AS (
		SELECT SUM(bill.gross_amount) AS payment_file_pushed_amount,
		COUNT(status.status_id) AS payment_file_pushed_count
		FROM billing.bill_status_info status
		JOIN billing.bill_details bill
		ON bill.bill_id = status.bill_id
		WHERE status.status_id = 55
		  AND NOT EXISTS (
			SELECT 1
			FROM billing.bill_status_info bsi2
			WHERE bsi2.bill_id = status.bill_id
			  AND bsi2.status_id > 55
		)
	),
	voucher_details AS (
        SELECT COALESCE(SUM(amount), 0) as voucher_amount
        FROM cts.voucher
        WHERE financial_year_id = p_finyear
    )
    SELECT json_build_object(
        -- Failed Txn with GST
        'failedTransactionAmountWithGst', COALESCE(SUM(CASE WHEN is_gst THEN failed_transaction_amount END), 0),
        'failedTransactionAmountWithGstCount', COUNT(CASE WHEN is_gst THEN 1 END),

        -- Failed Txn without GST
        'failedTransactionAmountWithoutGst', COALESCE(SUM(CASE WHEN NOT is_gst THEN failed_transaction_amount END), 0),
        'failedTransactionAmountWithoutGstCount', COUNT(CASE WHEN NOT is_gst THEN 1 END),

        -- Success Txn with GST
        'successTransactionAmountWithGst', (
            SELECT COALESCE(SUM(amount), 0) FROM success_txn WHERE is_gst
        ),
        'successTransactionAmountWithGstCount', (
            SELECT COUNT(id) FROM success_txn WHERE is_gst
        ),

        -- Success Txn without GST
        'successTransactionAmountWithoutGst', (
            SELECT COALESCE(SUM(amount), 0) FROM success_txn WHERE NOT is_gst
        ),
        'successTransactionAmountWithoutGstCount', (
            SELECT COUNT(id) FROM success_txn WHERE NOT is_gst
        ),

        -- Total Gross and Net
        'totalGrossAmount', (SELECT total_gross FROM bill_summary),
        'totalNetAmount', (SELECT total_net FROM bill_summary),
		'totalGstAmount', (SELECT total_gst FROM bill_summary),
        -- Total success/failed amounts
        'totalSuccessfulAmount', (
            SELECT COALESCE(SUM(amount), 0) FROM success_txn
        ),
        'totalFailedAmount', (
            SELECT COALESCE(SUM(failed_transaction_amount), 0) FROM failed_txn
        ),
		'totalVoucherAmount', (SELECT voucher_amount FROM voucher_details),
        -- Transaction counts
        'expectedTransactionCount', (SELECT total_payee_count FROM bill_summary),
        'successfulTransactionCount', (SELECT COUNT(id) FROM success_txn),
        'failedTransactionCount', (SELECT COUNT(id) FROM failed_txn),

        -- Pending count with non-negative enforcement
        'pendingTransactionCount',
        GREATEST(
            (SELECT total_payee_count FROM bill_summary)
            -
            ((SELECT COUNT(id) FROM success_txn) + (SELECT COUNT(id) FROM failed_txn)),
            0
        ),
		'currentYearSuccessBenCount', (SELECT current_year_success_ben_count FROM current_year_success_ben),
		'currentYearSuccessBenAmount', (SELECT current_year_success_ben_amount FROM current_year_success_ben),
		'currentYearGstSuccessBenCount', (SELECT current_year_gst_success_ben_count FROM current_year_success_ben),
		'currentYearGstSuccessBenAmount', (SELECT current_year_gst_success_ben_amount FROM current_year_success_ben),
		'currentYearFailedBenCount', (SELECT current_year_failed_ben_count FROM current_year_failed_ben),
		'currentYearFailedBenAmount', (SELECT current_year_failed_ben_amount FROM current_year_failed_ben),
		'currentYearGstFailedBenCount', (SELECT current_year_gst_failed_ben_count FROM current_year_failed_ben),
		'currentYearGstFailedBenAmount', (SELECT current_year_gst_failed_ben_amount FROM current_year_failed_ben),
		'paymentFilePushedCount', (SELECT payment_file_pushed_count FROM status_summary),
		'paymentFilePushedAmount', (SELECT payment_file_pushed_amount FROM status_summary),
		'pendingAcknowledgedAmount', (
		    SELECT GREATEST(
		        (SELECT total_net + total_gst FROM bill_summary) -
		        (
		            (SELECT COALESCE(SUM(amount), 0) FROM success_txn) +
		            (SELECT COALESCE(SUM(failed_transaction_amount), 0) FROM failed_txn)
		        ),
		        0
		    )
		)
    )
    INTO result
    FROM failed_txn;

    RETURN result;
        
   
END;
$$;


ALTER FUNCTION cts.get_transaction_summary(p_finyear smallint) OWNER TO postgres;

--
-- TOC entry 459 (class 1255 OID 920248)
-- Name: insert_failed_transaction_ben_detail(jsonb); Type: PROCEDURE; Schema: cts; Owner: postgres
--

CREATE OR REPLACE PROCEDURE cts.insert_failed_transaction_ben_detail(IN failed_transaction_ben_payload jsonb)
    LANGUAGE plpgsql
    AS $$
Declare 
	_bill_ref_no character varying;
	_total_failed_amount BIGINT;
    failed_transaction_payload JSONB;
	inserted_ids BIGINT[];
	_bill_fin_year smallint;
BEGIN
 -- STEP 1. Insert Failed Transaction Beneficiary Details
	
	_bill_ref_no := (
		SELECT reference_no
		FROM billing.bill_details
		WHERE bill_id = (failed_transaction_ben_payload->>'BillId')::bigint
	);
	
-- STEP 2: Calculate the total failed amount for all FailedBenDetails
	SELECT SUM((ben_failed_amount->>'FailedAmount')::BIGINT)
	INTO _total_failed_amount
	FROM jsonb_array_elements(failed_transaction_ben_payload->'FailedBenDetails') AS ben_failed_amount;

-- STEP 3: Retrieve the bill financial year from FailedBenDetails
	SELECT financial_year
	INTO _bill_fin_year
	FROM billing.bill_ecs_neft_details,
	jsonb_array_elements(failed_transaction_ben_payload->'FailedBenDetails') AS ecs
	WHERE id = (ecs->>'EcsId')::bigint;

	INSERT INTO cts.failed_transaction_beneficiary(bill_id, treasury_code, ddo_code, payee_name,
	account_no,ifsc_code, bank_name, financial_year, failed_transaction_amount, bill_ref_no,
	jit_ref_no, end_to_end_id, payee_id, agency_code, failed_reason_code, failed_reason_desc,
	total_ben_failed_amount, is_gst, challan_no, major_head, challan_date, is_active,
	cancel_certificate_date, cancel_certificate_no, accepted_date_time,beneficiary_id,
	file_name, utr_no, bill_fin_year )
	SELECT 
		(failed_transaction_ben_payload->>'BillId')::bigint,
		(failed_transaction_ben_payload->>'TreasuryCode'),
		(failed_transaction_ben_payload->>'DdoCode'),
		(value->>'PayeeName')::character varying,
		trim(value->>'AccountNo')::character varying,
		(value->>'IfscCode')::character varying,
		(value->>'BankName')::character varying,
		(failed_transaction_ben_payload->>'FinancialYear')::smallint,
		(value->>'FailedAmount')::bigint,
		_bill_ref_no,
		(value->>'JitReferenceNo')::character varying,
		(value->>'EndToEndId')::character varying,
		(value->>'BeneficiaryId')::character varying,
		(value->>'AgencyCode')::character varying,
		(value->>'FailedReasonCode')::character varying,
		(value->>'FailedReasonDesc')::character varying,
		_total_failed_amount,
		(value->>'IsGST')::bool,
		(value->>'ChallanNo')::integer,
		(value->>'ChallanMajorHead')::character varying,
		(value->>'ChallanDate')::date,
		1,
		(value->>'CancelCertDate')::date,
		(value->>'CancelCertNo')::character varying,
		(value->>'AccpDateTime')::timestamp without time zone,
		(value->>'EcsId')::bigint,
		(value->>'FileName')::character varying,
		(value->>'UtrNumber')::character varying,
		_bill_fin_year
		from	
		jsonb_array_elements(failed_transaction_ben_payload->'FailedBenDetails') AS value;

		select array_agg(id) INTO inserted_ids from cts.failed_transaction_beneficiary where status=0;

		SELECT jit.get_failed_transaction_details() INTO failed_transaction_payload;
		IF (failed_transaction_payload IS NOT NULL) THEN
			PERFORM message_queue.insert_message_queue(
				'bill_jit_failed_ben', failed_transaction_payload
			);	
		END IF;	
		-- Extract list of Inserted Column
		update cts.failed_transaction_beneficiary 
		set status = 1 
		where id = ANY(inserted_ids) and is_gst = false;
		
		---- Update active flag in the basis of existing record
		UPDATE cts.success_transaction_beneficiary stb
		SET is_active = 0
		FROM jsonb_array_elements(failed_transaction_ben_payload->'FailedBenDetails') AS value
		WHERE (value->>'EcsId')::bigint = stb.ecs_id 
		AND (failed_transaction_ben_payload->>'BillId')::bigint = stb.bill_id
		AND (value->>'EndToEndId')::character varying = stb.end_to_end_id
		AND stb.is_active = 1;

END;
$$;


ALTER PROCEDURE cts.insert_failed_transaction_ben_detail(IN failed_transaction_ben_payload jsonb) OWNER TO postgres;

--
-- TOC entry 494 (class 1255 OID 920249)
-- Name: insert_failed_transaction_ben_detail_old(jsonb); Type: PROCEDURE; Schema: cts; Owner: postgres
--

CREATE OR REPLACE PROCEDURE cts.insert_failed_transaction_ben_detail_old(IN failed_transaction_ben_payload jsonb)
    LANGUAGE plpgsql
    AS $$
Declare 
	_ben_count smallint;
	_bill_ref_no character varying;
	_total_failed_amount BIGINT;
BEGIN
 -- STEP 1. Insert Failed Transaction Beneficiary Details
	SELECT COALESCE(jsonb_array_length(failed_transaction_ben_payload->'FailedBenDetails'),0) INTO _ben_count;
	
FOR i IN 0.._ben_count-1 LOOP

	_bill_ref_no := (
		SELECT reference_no
		FROM billing.bill_details
		WHERE bill_id = (failed_transaction_ben_payload->>'BillId')::bigint
	);

-- STEP 2: Calculate the total failed amount for all FailedBenDetails
	SELECT SUM((ben_failed_amount->>'FailedAmount')::BIGINT)
	INTO _total_failed_amount
	FROM jsonb_array_elements(failed_transaction_ben_payload->'FailedBenDetails') AS ben_failed_amount
	WHERE ben_failed_amount->>'JitReferenceNo' = (failed_transaction_ben_payload->'FailedBenDetails'->i->>'JitReferenceNo');

	INSERT INTO cts.failed_transaction_beneficiary(bill_id, treasury_code, ddo_code, payee_name, account_no,
	ifsc_code, bank_name, financial_year, failed_transaction_amount, bill_ref_no, jit_ref_no, end_to_end_id, payee_id, agency_code, failed_reason_code, failed_reason_desc, total_ben_failed_amount)
	VALUES (
		(failed_transaction_ben_payload->>'BillId')::bigint,
		(failed_transaction_ben_payload->>'TreasuryCode'),
		(failed_transaction_ben_payload->>'DdoCode'),
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'PayeeName')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'AccountNo')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'IfscCode')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'BankName')::character varying,
		(failed_transaction_ben_payload->>'FinancialYear')::smallint,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'FailedAmount')::bigint,
		_bill_ref_no,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'JitReferenceNo')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'EndToEndId')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'BeneficiaryId')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'AgencyCode')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'FailedReasonCode')::character varying,
		(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'FailedReasonDesc')::character varying,
-- 		SUM(failed_transaction_ben_payload->'FailedBenDetails'->(i::smallint)::smallint->>'FailedAmount')::bigint
		_total_failed_amount
      );
	END LOOP;
END;
$$;


ALTER PROCEDURE cts.insert_failed_transaction_ben_detail_old(IN failed_transaction_ben_payload jsonb) OWNER TO postgres;

--
-- TOC entry 416 (class 1255 OID 920250)
-- Name: insert_list_of_payment(record, bigint, integer, date, bigint, bigint, date, record, bigint); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.insert_list_of_payment(in_hoa_details record, in_voucher_id bigint, in_voucher_no integer, in_voucher_date date, in_token_id bigint, in_token_no bigint, in_token_date date, in_bill_details record, in_payment_advice_id bigint) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current_month_number smallint:=EXTRACT(MONTH FROM CURRENT_DATE);
    v_current_month_name character(3):=TO_CHAR(CURRENT_DATE, 'Mon');
    v_current_quarter character(2):=cts_accounting.get_fn_quarter_by_month_number(v_current_month_number);
BEGIN
    INSERT INTO cts_accounting.list_of_payment
			(
				demand_no,
				major_head,
				submajor_head,
				minor_head,
				plan_status,
				scheme_head,
				detail_head,
				subdetail_head,
				voted_charged,
				hoa_id,
				voucher_id,
				voucher_no,
				voucher_date,
				token_id,
				token_no,
				token_date,
				bill_id,
				cr_dr,
				gross_amount,
				net,
				tr_bt,
				tr_gross,
				ag_bt,
				quarter,
				month_number,
				month_name,
				treasury_code,
				ddo_code,
				designation,
				pay_type,
				payee_dept,
				scheme_type,
				dept_code,
				created_at,
				payment_advice_id,
				financial_year_id
			)
			VALUES
			(
				in_hoa_details.demand_no,
				in_hoa_details.major_head,
				in_hoa_details.submajor_head,
				in_hoa_details.minor_head,
				in_hoa_details.plan_status,
				in_hoa_details.scheme_head,
				in_hoa_details.detail_head,
				in_hoa_details.subdetail_head,
				in_hoa_details.voted_charged,
				in_bill_details.active_hoa_id,
				in_voucher_id,
				in_voucher_no,
				in_voucher_date,
				in_token_id,
				in_token_no,
				in_token_date,
				in_bill_details.bill_id,
				1,--CR
				in_bill_details.gross_amount,
				in_bill_details.net_amount,
				in_bill_details.treasury_bt,--tr_bt
				in_bill_details.gross_amount - in_bill_details.ag_bt,--tr-gross
				in_bill_details.ag_bt,--ag_bt
				v_current_quarter,
				v_current_month_number,
				v_current_month_name,
				in_bill_details.treasury_code,
				in_bill_details.ddo_code,
				master.get_designation_by_ddo_code(in_bill_details.ddo_code),
				'',-- v_bill_details.pay_type,
				'',-- v_bill_details.payee_dept,
				'',-- v_bill_details.scheme_type,
				 master.get_department_by_demand_code(in_hoa_details.demand_no),
				CURRENT_TIMESTAMP,
				in_payment_advice_id,
				in_bill_details.financial_year
			);
    return 1;
END;
$$;


ALTER FUNCTION cts.insert_list_of_payment(in_hoa_details record, in_voucher_id bigint, in_voucher_no integer, in_voucher_date date, in_token_id bigint, in_token_no bigint, in_token_date date, in_bill_details record, in_payment_advice_id bigint) OWNER TO postgres;

--
-- TOC entry 424 (class 1255 OID 920251)
-- Name: insert_success_transaction_ben_detail(jsonb); Type: PROCEDURE; Schema: cts; Owner: postgres
--

CREATE OR REPLACE PROCEDURE cts.insert_success_transaction_ben_detail(IN success_transaction_ben_payload jsonb)
    LANGUAGE plpgsql
    AS $$
Declare 
	_bill_ref_no character varying;
	_total_amount BIGINT;
    success_transaction_payload jsonb;
    inserted_ids BIGINT[]; -- Array to store IDs of inserted rows
BEGIN
 -- STEP 1. Insert Success Transaction Beneficiary Details
	
	_bill_ref_no := (
		SELECT reference_no
		FROM billing.bill_details
		WHERE bill_id = (success_transaction_ben_payload->>'BillId')::bigint
	);
	
-- STEP 2: Calculate the total amount for all BenDetails
	SELECT SUM((ben_amount->>'Amount')::BIGINT)
	INTO _total_amount
	FROM jsonb_array_elements(success_transaction_ben_payload->'BenDetails') AS ben_amount;

	INSERT INTO cts.success_transaction_beneficiary(bill_id, treasury_code, ddo_code, payee_name, account_no,
	ifsc_code, bank_name, financial_year, amount, bill_ref_no, jit_ref_no, end_to_end_id, payee_id, agency_code, total_amount, is_gst,
	ecs_id, utr_number, accepted_date_time, is_active, file_name)
	SELECT 
		(success_transaction_ben_payload->>'BillId')::bigint,
		(success_transaction_ben_payload->>'TreasuryCode'),
		(success_transaction_ben_payload->>'DdoCode'),
		(value->>'PayeeName')::character varying,
		(value->>'AccountNo')::character varying,
		(value->>'IfscCode')::character varying,
		(value->>'BankName')::character varying,
		(success_transaction_ben_payload->>'FinancialYear')::smallint,
		(value->>'Amount')::bigint,
		_bill_ref_no,
		(value->>'JitReferenceNo')::character varying,
		(value->>'EndToEndId')::character varying,
		(value->>'BeneficiaryId')::character varying,
		(value->>'AgencyCode')::character varying,
		_total_amount,
		(value->>'IsGST')::bool,
		(value->>'EcsId')::bigint,
		(value->>'UtrNumber')::character varying,
		(value->>'AccpDateTime')::timestamp without time zone,
		1,
		(value->>'FileName')::character varying
		from	
		jsonb_array_elements(success_transaction_ben_payload->'BenDetails') AS value;
		
		select array_agg(id) INTO inserted_ids from cts.success_transaction_beneficiary where status=0;

		RAISE NOTICE 'Value of variable X: %', inserted_ids;

		
		SELECT jit.get_success_transaction_details() INTO success_transaction_payload;
		IF (success_transaction_payload IS NOT NULL) THEN
			PERFORM message_queue.insert_message_queue(
				'bill_jit_success_ben', success_transaction_payload
			);	
		END IF;
		
		-- Extract list of AllotmentId
		update cts.success_transaction_beneficiary 
		set status = 1 
		where id = any(inserted_ids);
	
		---- Update active flag in the basis of existing record
		-- UPDATE cts.failed_transaction_beneficiary
		-- SET is_active = 0
		-- FROM jsonb_array_elements(success_transaction_ben_payload->'BenDetails') AS value
		-- WHERE jit_ref_no = (value->>'JitReferenceNo')::character varying
		-- AND account_no = (value->>'AccountNo')::character varying;
		
		UPDATE cts.success_transaction_beneficiary stb
		SET is_active = 0
		FROM jsonb_array_elements(success_transaction_ben_payload->'BenDetails') AS value,
		     cts.failed_transaction_beneficiary ftb
		WHERE (value->>'EcsId')::bigint = ftb.beneficiary_id 
		AND (value->>'EcsId')::bigint = stb.ecs_id 
		AND (success_transaction_ben_payload->>'BillId')::bigint = ftb.bill_id 
		AND (success_transaction_ben_payload->>'BillId')::bigint = stb.bill_id 
		AND ftb.is_active=1;
		
END;
$$;


ALTER PROCEDURE cts.insert_success_transaction_ben_detail(IN success_transaction_ben_payload jsonb) OWNER TO postgres;

--
-- TOC entry 469 (class 1255 OID 920252)
-- Name: insert_token_details(jsonb); Type: PROCEDURE; Schema: cts; Owner: postgres
--

CREATE OR REPLACE PROCEDURE cts.insert_token_details(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
	_treasury_code character varying;
	_ddo_code character varying;
	_financial_year_id smallint;
BEGIN
	SELECT treasury_code, ddo_code, financial_year INTO _treasury_code, _ddo_code, _financial_year_id
	FROM billing.bill_details
	WHERE bill_id = (in_payload->>'EntityId')::bigint;
			
	INSERT INTO cts.token(id, token_number, token_date, entity_id, ddo_code, treasury_code, financial_year_id)
	SELECT 
		(in_payload->>'TokenId')::bigint,
		(in_payload->>'TokenNumber')::bigint,
		(in_payload->>'TokenDate')::date,
		(in_payload->>'EntityId')::bigint,
		_ddo_code,
		_treasury_code,
		_financial_year_id
	ON CONFLICT(entity_id) DO NOTHING;
END;
$$;


ALTER PROCEDURE cts.insert_token_details(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 493 (class 1255 OID 920253)
-- Name: insert_token_details_func(jsonb); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.insert_token_details_func(param1 jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    CALL cts.insert_token_details(param1);
END;
$$;


ALTER FUNCTION cts.insert_token_details_func(param1 jsonb) OWNER TO postgres;

--
-- TOC entry 507 (class 1255 OID 920254)
-- Name: insert_voucher_details(jsonb); Type: PROCEDURE; Schema: cts; Owner: postgres
--

CREATE OR REPLACE PROCEDURE cts.insert_voucher_details(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
	inserted_ids BIGINT[];
	_token_id bigint;
	_financial_year_id smallint;
	voucher_payload jsonb;
	_treasury_code character varying;
BEGIN
	SELECT id, financial_year_id,treasury_code  INTO _token_id, _financial_year_id, _treasury_code
	FROM cts.token
	WHERE entity_id = (in_payload->>'BillId')::bigint;
			
	INSERT INTO cts.voucher(voucher_no, voucher_date, bill_id, major_head, amount, token_id, financial_year_id, treasury_code)
	SELECT 
		(in_payload->>'VoucherNo')::bigint,
		(in_payload->>'VoucherDate')::date,
		(in_payload->>'BillId')::bigint,
		(in_payload->>'MajorHead')::character varying,
		(in_payload->>'VoucherAmount')::bigint,
		_token_id,
		_financial_year_id,
		_treasury_code
	ON CONFLICT(bill_id) DO NOTHING;
		
	select array_agg(id) INTO inserted_ids from cts.voucher where status = 0;

	IF inserted_ids IS NOT NULL AND array_length(inserted_ids, 1) > 0 THEN		
		SELECT json_agg(json_build_object(
			'BillId', voucher.bill_id,
			'VoucherNo', voucher.voucher_no,
			'VoucherDate', voucher.voucher_date,
			'VoucherAmount', voucher.amount,
			'MajorHead', voucher.major_head,
			'RefNos', maps.ref_nos
		)) INTO voucher_payload
		FROM 
			cts.voucher AS voucher
		LEFT JOIN (
			SELECT bill_id, array_agg(jit_ref_no) AS ref_nos
			FROM billing.ebill_jit_int_map
			GROUP BY bill_id
		) AS maps 
		ON voucher.bill_id = maps.bill_id
		WHERE voucher.status = 0 and voucher.bill_id IS NOT NULL;

		IF voucher_payload IS NOT NULL THEN
			PERFORM message_queue.insert_message_queue(
				'bill_jit_voucher', voucher_payload
			);	
		END IF;
		
		-- Extract list of Inserted Column
		update cts.voucher 
		set status = 1 
		where id = ANY(inserted_ids);
	END IF;
END;
$$;


ALTER PROCEDURE cts.insert_voucher_details(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 474 (class 1255 OID 920255)
-- Name: insert_voucher_details_func(jsonb); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.insert_voucher_details_func(param1 jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    CALL cts.insert_voucher_details(param1);
END;
$$;


ALTER FUNCTION cts.insert_voucher_details_func(param1 jsonb) OWNER TO postgres;

--
-- TOC entry 434 (class 1255 OID 920256)
-- Name: trg_adjust_allotment_failed_beneficiary(); Type: FUNCTION; Schema: cts; Owner: postgres
--

CREATE OR REPLACE FUNCTION  cts.trg_adjust_allotment_failed_beneficiary() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	IF NEW.is_gst = false THEN 
		PERFORM cts.adjust_allotment_failed_beneficiary(NEW.bill_id,NEW.failed_transaction_amount); 
	END IF;
	
    RETURN NEW;
END;
$$;


ALTER FUNCTION cts.trg_adjust_allotment_failed_beneficiary() OWNER TO postgres;

--
-- TOC entry 412 (class 1255 OID 920257)
-- Name: update_ddo_allotment_actual_amount_from_treasury(jsonb); Type: PROCEDURE; Schema: cts; Owner: postgres
--

CREATE OR REPLACE PROCEDURE cts.update_ddo_allotment_actual_amount_from_treasury(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
	---- Update actual_released_amount in the basis of existing record
		WITH update_transactions AS (
			UPDATE bantan.ddo_allotment_transactions trans
			SET actual_released_amount = trans.actual_released_amount + (in_payload->>'ActualAmount')::bigint
			WHERE allotment_id = (in_payload->>'AllotmentId')::bigint
			RETURNING *
		)

		UPDATE bantan.ddo_wallet wallet
		SET actual_released_amount = wallet.actual_released_amount + (in_payload->>'ActualAmount')::bigint
		FROM update_transactions
		WHERE wallet.sao_ddo_code = update_transactions.receiver_sao_ddo_code
			AND wallet.active_hoa_id = update_transactions.active_hoa_id
			AND wallet.financial_year = update_transactions.financial_year;
END;
$$;


ALTER PROCEDURE cts.update_ddo_allotment_actual_amount_from_treasury(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 429 (class 1255 OID 920258)
-- Name: bkend_update_jit_allotment_func(character varying, character, bigint, smallint, bigint, bigint); Type: FUNCTION; Schema: jit; Owner: postgres
--

CREATE OR REPLACE FUNCTION  jit.bkend_update_jit_allotment_func(_sanction_no character varying, _ddo_code character, _active_hoa_id bigint, _financial_year smallint, _old_limit_amount bigint, _new_self_limit_amount bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		_effective_limit_amount bigint;
	BEGIN
		_effective_limit_amount :=  _new_self_limit_amount- _old_limit_amount;

		RAISE NOTICE '_sanction_no - %',_sanction_no;
		RAISE NOTICE '_ddo_code - %',_ddo_code;
		RAISE NOTICE '_active_hoa_id - %',_active_hoa_id;
		RAISE NOTICE '_financial_year - %',_financial_year;

		RAISE NOTICE 'ADJUST AMOUNT - %',_effective_limit_amount;
		
		UPDATE jit.jit_allotment
			set self_limit_amount = self_limit_amount + _effective_limit_amount
		where sanction_no= _sanction_no and ddo_code=_ddo_code;

		UPDATE bantan.ddo_allotment_transactions 
			SET budget_alloted_amount = budget_alloted_amount+ _effective_limit_amount,
				ceiling_amount = ceiling_amount + _effective_limit_amount
		WHERE memo_number=_sanction_no and  receiver_sao_ddo_code=_ddo_code;

		UPDATE bantan.ddo_wallet
			SET budget_alloted_amount =  budget_alloted_amount + _effective_limit_amount,
				ceiling_amount =  ceiling_amount + _effective_limit_amount
		WHERE sao_ddo_code = _ddo_code and active_hoa_id = _active_hoa_id and financial_year=_financial_year;
	END;
$$;


ALTER FUNCTION jit.bkend_update_jit_allotment_func(_sanction_no character varying, _ddo_code character, _active_hoa_id bigint, _financial_year smallint, _old_limit_amount bigint, _new_self_limit_amount bigint) OWNER TO postgres;

--
-- TOC entry 437 (class 1255 OID 920259)
-- Name: cancel_fto_from_bill(jsonb, character varying, character varying, bigint); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.cancel_fto_from_bill(IN in_payload jsonb, IN queuename character varying, IN refno character varying, IN billid bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN

	INSERT INTO billing.rabbitmq_transaction (queue_name, data, created_at) VALUES (queueName, in_payload::jsonb, now());
	
	UPDATE billing.ebill_jit_int_map SET is_rejected = TRUE WHERE jit_ref_no = refNo;
	
	UPDATE jit.tsa_exp_details SET is_rejected = TRUE, system_rejected=FALSE, rejected_at=now(),reject_reason='Rejected by DDO' WHERE ref_no = refNo;
	
	UPDATE billing.bill_details SET status=105, is_cancelled = TRUE WHERE bill_id = billid;

	UPDATE billing.jit_ecs_additional SET is_cancelled = TRUE WHERE bill_id = billid AND jit_reference_no = refNo;

	UPDATE billing.bill_ecs_neft_details SET is_cancelled = TRUE WHERE id = ANY(
                    SELECT ecs_id FROM billing.jit_ecs_additional WHERE bill_id = billid AND jit_reference_no = refNo
                );

END;
$$;


ALTER PROCEDURE jit.cancel_fto_from_bill(IN in_payload jsonb, IN queuename character varying, IN refno character varying, IN billid bigint) OWNER TO postgres;

--
-- TOC entry 417 (class 1255 OID 920260)
-- Name: get_failed_transaction_details(); Type: FUNCTION; Schema: jit; Owner: postgres
--

CREATE OR REPLACE FUNCTION  jit.get_failed_transaction_details() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result_payload JSONB;
BEGIN
    -- Step 1: Create a subquery for SuccessBenDetails aggregation
    SELECT
	json_agg(
	json_build_object(
		'BillId', bill.bill_id,
		'DdoCode',bill.ddo_code,
		'RefDetails', bill.ref_details,
		'TreasuryCode', bill.treasury_code,
		'FinancialYear', bill.financial_year
		)
	) INTO result_payload
	FROM(
		SELECT
			jit.bill_id,
			jit.treasury_code,
			jit.ddo_code,
			jit.financial_year,
			jit.jit_ref_no,
			jit.agency_code,
			json_agg(
			json_build_object(
				'JitRefNo', jit.jit_ref_no,
				'AgencyCode', jit.agency_code,
				'TotalBenFailedAmount', jit.total_failed_amount,
				'FailedBenDetails', jit.failed_ben_details,
				'GstFailedBenDetails', null
				)
			) AS ref_details
			FROM(
				SELECT
					f.bill_id,
					f.treasury_code,
					f.ddo_code,
					f.financial_year,
					f.jit_ref_no,
					f.agency_code,
					SUM(f.failed_transaction_amount) as total_failed_amount,
					json_agg(
						json_build_object(
							'PayeeName', f.payee_name,
							'AccountNo', f.account_no,
							'IfscCode', f.ifsc_code,
							'BankName', f.bank_name,
							'PayeeId', f.payee_id,
							'EndToEndId', f.end_to_end_id,
							'AgencyCode', f.agency_code,
							'FailedAmount', f.failed_transaction_amount,
							'FailedReasonCode', f.failed_reason_code,
							'FailedReasonDesc', f.failed_reason_desc,
							'AccpDateTime', f.accepted_date_time,
							'CancelCertNo', f.cancel_certificate_no,
							'CancelCertDate', f.cancel_certificate_date,
							'UtrNumber', f.utr_no,
							'FileName', f.file_name
						)
					) AS failed_ben_details
					FROM cts.failed_transaction_beneficiary f 
					WHERE status = 0 AND
						is_gst = false
					GROUP BY jit_ref_no, agency_code, f.bill_id, f.treasury_code,f.ddo_code,f.financial_year,f.jit_ref_no,f.agency_code
				) as jit
	GROUP BY jit.bill_id, jit.treasury_code,jit.ddo_code,jit.financial_year,jit.jit_ref_no,jit.agency_code
) as bill;

    -- Returning JSON result
    RETURN result_payload;
END;
$$;


ALTER FUNCTION jit.get_failed_transaction_details() OWNER TO postgres;

--
-- TOC entry 498 (class 1255 OID 920261)
-- Name: get_failed_transaction_details_manual_generation(); Type: FUNCTION; Schema: jit; Owner: postgres
--

CREATE OR REPLACE FUNCTION  jit.get_failed_transaction_details_manual_generation() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result_payload JSONB;
BEGIN
    -- Step 1: Create a subquery for SuccessBenDetails aggregation
    SELECT
	json_agg(
	json_build_object(
		'BiillId', bill.bill_id,
		'DdoCode',bill.ddo_code,
		'RefDetails', bill.ref_details,
		'TreasuryCode', bill.treasury_code,
		'FinancialYear', bill.financial_year
		)
	) INTO result_payload
	FROM(
		SELECT
			jit.bill_id,
			jit.treasury_code,
			jit.ddo_code,
			jit.financial_year,
			jit.jit_ref_no,
			jit.agency_code,
			json_agg(
			json_build_object(
				'JitRefNo', jit.jit_ref_no,
				'AgencyCode', jit.agency_code,
				'TotalBenFailedAmount', jit.total_failed_amount,
				'FailedBenDetails', jit.failed_ben_details
				)
			) AS ref_details
			FROM(
				SELECT
					f.bill_id,
					f.treasury_code,
					f.ddo_code,
					f.financial_year,
					f.jit_ref_no,
					f.agency_code,
					SUM(f.failed_transaction_amount) as total_failed_amount,
					json_agg(
						json_build_object(
							'PayeeName', f.payee_name,
							'AccountNo', trim(f.account_no),
							'IfscCode', f.ifsc_code,
							'BankName', f.bank_name,
							'PayeeId', f.payee_id,
							'EndToEndId', f.end_to_end_id,
							
							'CancellationCertificateNo', CONCAT(c.financial_year_id, '/', LPAD(t.token_number::TEXT, 8, '0'), '/', LPAD(c.certificate_id::TEXT, 10, '0')),
							'MajorHead', c.major_head,
							'CancellationDate', c.cancellation_date,
							
							'AgencyCode', f.agency_code,
							'FailedAmount', f.failed_transaction_amount,
							'FailedReasonCode', f.failed_reason_code,
							'FailedReasonDesc', f.failed_reason_desc,
							'AccpDateTime', f.accepted_date_time
						)  
						-- select * from cts.ecs_cancel_transactions
					) AS failed_ben_details
					FROM (select * from cts.failed_transaction_beneficiary WHERE status = 1 AND is_gst = false) f 
					LEFT JOIN cts.token t on f.bill_id=t.entity_id
					LEFT JOIN cts.ecs_cancel_transactions c on t.id = c.token_id and f.payee_id=c.beneficiary_id
					GROUP BY jit_ref_no, agency_code, f.bill_id, f.treasury_code,f.ddo_code,f.financial_year,f.jit_ref_no,f.agency_code
					
				) as jit
	GROUP BY jit.bill_id, jit.treasury_code,jit.ddo_code,jit.financial_year,jit.jit_ref_no,jit.agency_code) as bill;

    -- Returning JSON result
    RETURN result_payload;
END;
$$;


ALTER FUNCTION jit.get_failed_transaction_details_manual_generation() OWNER TO postgres;

--
-- TOC entry 467 (class 1255 OID 920262)
-- Name: get_jit_allotments(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.get_jit_allotments(IN in_payload jsonb, OUT out_payload jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT jsonb_agg(result) INTO out_payload
    FROM (
        SELECT 
            a.allotment_id AS "AllotmentId",
            TRIM(a.sender_sao_ddo_code) AS "AgencyCode",
            a.budget_alloted_amount AS "BudgetAllotedAmount",
            a.ceiling_amount AS "CellingAmount",
            a.provisional_released_amount AS "ProvisionalReleasedAmount",
            a.demand_no || '-' || a.major_head || '-' || a.submajor_head || '-' || 
            a.minor_head || '-' || a.scheme_head || '-' || a.detail_head || '-' || 
            a.subdetail_head || '-' || a.voted_charged AS "Hoa",
            a.treasury_code AS "TreasuryCode",
            a.receiver_sao_ddo_code AS "DdoCode",
            a.created_at AS "CreatedAt",
            a.memo_date::TEXT AS "SanctionDate",
            a.memo_number AS "SanctionNo",
            COALESCE(jsonb_agg(
                jsonb_build_object(
                    'WithdrawlSanctionNo', w.sanction_no,
                    'WithdrawlSanctionDate', w.sanction_date::TEXT,
                    'WithdrawlSanctionAmount', w.self_limit_amount
                )
            ) FILTER (WHERE w.sanction_no IS NOT NULL), '[]') AS "Withdrawals"
        FROM bantan.ddo_allotment_transactions a
        LEFT JOIN jit.jit_withdrawl w
            ON a.memo_number = w.from_sanction_no
           AND TRIM(a.sender_sao_ddo_code) = TRIM(w.agency_code)
        WHERE 
			((in_payload->>'DdoCode')::character varying IS NULL
			OR
			a.receiver_sao_ddo_code = (in_payload->>'DdoCode'))
		AND (
			((in_payload->>'SanctionNo')::character varying IS NULL
			OR
			a.memo_number = (in_payload->>'SanctionNo')::character varying)
		)
        GROUP BY a.allotment_id, a.ceiling_amount, a.budget_alloted_amount, 
                 a.provisional_released_amount, a.demand_no, a.major_head, a.submajor_head,
                 a.minor_head, a.scheme_head, a.detail_head, a.subdetail_head, a.voted_charged,
                 a.treasury_code, a.receiver_sao_ddo_code, a.memo_date, a.memo_number, 
                 a.sender_sao_ddo_code, a.created_at
    ) AS result;
END;
$$;


ALTER PROCEDURE jit.get_jit_allotments(IN in_payload jsonb, OUT out_payload jsonb) OWNER TO postgres;

--
-- TOC entry 508 (class 1255 OID 920263)
-- Name: get_success_transaction_details(); Type: FUNCTION; Schema: jit; Owner: postgres
--

CREATE OR REPLACE FUNCTION  jit.get_success_transaction_details() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result_payload JSONB;
BEGIN
    -- Step 1: Create a subquery for SuccessBenDetails aggregation
    SELECT 
		jsonb_agg(
			jsonb_build_object(
				'BillId', sub.bill_id,
				'TreasuryCode', sub.treasury_code,
				'DdoCode', sub.ddo_code,
				'FinancialYear', sub.financial_year,
				'RefDetails', sub.ref_details
			)
		) INTO result_payload
	FROM
	(
		SELECT 
			sb.bill_id, sb.ddo_code, sb.treasury_code, sb.financial_year,
			jsonb_agg(
				jsonb_build_object(
					'JitRefNo', sb.jit_ref_no,
					'AgencyCode', sb.agency_code,
					'TotalAmount', sb.total_amount,
					'SuccessBenDetails', sb.success_ben_details,
					'SuccessGstBenDetails', null
				)
			) AS ref_details
			FROM
			(
			SELECT
				s.jit_ref_no,
				s.agency_code,
				s.bill_id,
				s.ddo_code,
				s.treasury_code,
				s.financial_year,
				SUM(s.amount) as total_amount,
				jsonb_agg(
					jsonb_build_object(
						'PayeeName', s.payee_name,
						'AccountNo', s.account_no,
						'IfscCode', s.ifsc_code,
						'BankName', s.bank_name,
						'PayeeId', s.payee_id,
						'EndToEndId', s.end_to_end_id,
						'Amount', s.amount,
						'EcsId', s.ecs_id,
						'UtrNumber', s.utr_number,
						'AccpDateTime', s.accepted_date_time,
						'FileName', s.file_name
					)
				) AS success_ben_details
			FROM cts.success_transaction_beneficiary s
			WHERE s.status = 0 -- ConsumedFromTreasury
			  AND s.is_gst = FALSE
			GROUP BY s.jit_ref_no, s.agency_code, s.bill_id, s.ddo_code, s.treasury_code, s.financial_year
			) AS sb
		GROUP BY sb.bill_id, sb.ddo_code, sb.treasury_code, sb.financial_year
	) AS sub;

    -- Returning JSON result
    RETURN result_payload;
END;
$$;


ALTER FUNCTION jit.get_success_transaction_details() OWNER TO postgres;

--
-- TOC entry 463 (class 1255 OID 920264)
-- Name: insert_agency_ddo_mapping_details(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_agency_ddo_mapping_details(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
	_financial_year bigint;
BEGIN
	SELECT id INTO _financial_year from master.financial_year_master where is_active=true;
    INSERT INTO jit.ddo_agency_mapping_details
    (
        treasury_code,
		ddo_code,
		agency_code,
		agency_name,
		sls_code,
		jit_requested_msg,
		financial_year,
		action_taken_at
	)
    VALUES
    (
        in_payload->>'TreasCode',
        in_payload->>'DdoCode',
        in_payload->>'Agencycode',
        in_payload->>'Agencyname',
        in_payload->>'Slscode',
        in_payload->>'RequestMessage',
		_financial_year,
		now()
    );
	PERFORM message_queue.insert_message_queue(
		'ebilling_jit_agency_ddo_mapping'::character varying, in_payload
	);
END;
$$;


ALTER PROCEDURE jit.insert_agency_ddo_mapping_details(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 408 (class 1255 OID 920265)
-- Name: insert_hoa_details(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_hoa_details(IN jit_hoa_details_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
	final_result jsonb;
BEGIN
	-- Insert/update data and capture inserted HOA IDs with status
	WITH inserted AS (
		INSERT INTO master.active_hoa_mst(
			id, dept_code, demand_no, major_head, submajor_head, minor_head,
			plan_status, scheme_head, detail_head, subdetail_head, voted_charged,
			description, isactive, activated_by, financial_year,
			is_aafs, is_sna, is_salary_component, category_code
		)
		SELECT
			(value->>'Id')::bigint,
			(value->>'DeptCode')::varchar,
			(value->>'DemandNo')::varchar,
			(value->>'MajorHead')::varchar,
			(value->>'SubmajorHead')::varchar,
			(value->>'MinorHead')::varchar,
			(value->>'PlanStatus')::varchar,
			(value->>'SchemeHead')::varchar,
			(value->>'DetailHead')::varchar,
			(value->>'SubdetailHead')::varchar,
			(value->>'VotedCharged')::varchar,
			(value->>'Description')::varchar,
			(value->>'Isactive')::boolean,
			(value->>'ActivatedBy')::bigint,
			(value->>'FinancialYear')::smallint,
			false,
			(value->>'IsSna')::boolean,
			(value->>'IsSalaryComponent')::boolean,
			(value->>'Category')::varchar
		FROM jsonb_array_elements(jit_hoa_details_payload) AS value
		ON CONFLICT (id) DO UPDATE SET
			dept_code = EXCLUDED.dept_code,
			demand_no = EXCLUDED.demand_no,
			major_head = EXCLUDED.major_head,
			submajor_head = EXCLUDED.submajor_head,
			minor_head = EXCLUDED.minor_head,
			plan_status = EXCLUDED.plan_status,
			scheme_head = EXCLUDED.scheme_head,
			detail_head = EXCLUDED.detail_head,
			subdetail_head = EXCLUDED.subdetail_head,
			voted_charged = EXCLUDED.voted_charged,
			description = EXCLUDED.description,
			isactive = EXCLUDED.isactive,
			activated_by = EXCLUDED.activated_by,
			financial_year = EXCLUDED.financial_year,
			is_aafs = EXCLUDED.is_aafs,
			is_sna = EXCLUDED.is_sna,
			is_salary_component = EXCLUDED.is_salary_component,
			category_code = EXCLUDED.category_code
		RETURNING id
	)
	SELECT jsonb_agg(jsonb_build_object(
		'HoaId', id,
		'Status', CASE WHEN id IS NOT NULL THEN 1 ELSE 0 END
	)) INTO final_result
	FROM inserted;

	-- Send payload to treasury
	PERFORM message_queue.insert_message_queue('hoa_to_treasury', jit_hoa_details_payload);

	-- Send ACK to billing
	IF final_result IS NOT NULL THEN
		PERFORM message_queue.insert_message_queue('bill_jit_hoa_ack', final_result);
	END IF;

END;
$$;


ALTER PROCEDURE jit.insert_hoa_details(IN jit_hoa_details_payload jsonb) OWNER TO postgres;

--
-- TOC entry 485 (class 1255 OID 920266)
-- Name: insert_jit_allotment(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_jit_allotment(IN jit_allotment_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE 
    finalResult JSONB;
	allotmentAckResult JSONB;
BEGIN  
    -- Insert into jit.jit_allotment and capture inserted records
    WITH extract_treasury_code AS(
		SELECT d.ddo_code, d.treasury_code
		FROM master.ddo d
		WHERE d.ddo_code = ANY (
	        SELECT value->>'DdoCode'
	        FROM jsonb_array_elements(jit_allotment_payload) AS value
	    )
	),
	inserted_allotment AS (
        INSERT INTO jit.jit_allotment(
            sls_code, fin_year, self_limit_amount, hoa_id, ddo_code, treasury_code, sanction_date, sanction_no, limit_type, agency_code, agency_name)
        SELECT 
            value->>'Slscode', 
           (value->>'Finyear')::SMALLINT,
            SUM((value->>'SelfLimitAmt')::NUMERIC::BIGINT),
            (value->>'HoaId')::NUMERIC::BIGINT,
			value->>'DdoCode',
            t.treasury_code,
            value->>'SanctionDate',
            value->>'SanctionNo',
            -- (value->>'SlsLimitDistributionId')::CHARACTER VARYING::BIGINT,
            -- (value->>'HeadWiseSanctionId')::CHARACTER VARYING::BIGINT,
            value->>'LimitType',
			value->>'Agencycode',
			value->>'AgencyName'
        FROM jsonb_array_elements(jit_allotment_payload) AS value, extract_treasury_code t
        WHERE floor((value->>'SelfLimitAmt')::NUMERIC)::BIGINT > 0
		AND (value->>'DdoCode') = t.ddo_code
        GROUP BY 
            value->>'Slscode', 
            (value->>'Finyear')::SMALLINT, 
            value->>'DdoCode',
			t.treasury_code,
            value->>'SanctionDate', 
            value->>'SanctionNo', 
            (value->>'HoaId')::NUMERIC::BIGINT,
            -- (value->>'SlsLimitDistributionId')::CHARACTER VARYING::BIGINT,
            -- (value->>'HeadWiseSanctionId')::CHARACTER VARYING::BIGINT,
            value->>'LimitType',
			value->>'Agencycode',
			value->>'AgencyName'
        RETURNING *
    ),
	hoa_data AS (
		SELECT DISTINCT h.id, h.dept_code, h.demand_no, h.major_head, h.submajor_head,
		h.minor_head, h.plan_status, h.scheme_head, h.detail_head, h.subdetail_head, h.voted_charged
		FROM master.active_hoa_mst h
		JOIN (
			SELECT DISTINCT (value->>'HoaId')::BIGINT AS hoa_id
			FROM jsonb_array_elements(jit_allotment_payload) AS value
		) payload_hoa ON payload_hoa.hoa_id = h.id
		WHERE h.isactive = TRUE
	),
	update_allotment_transaction AS(
        -- Insert into bantan.ddo_allotment_transactions using inserted_allotment
        INSERT INTO bantan.ddo_allotment_transactions(
            memo_number, active_hoa_id, sender_sao_ddo_code, receiver_sao_ddo_code,
            budget_alloted_amount, ceiling_amount, financial_year, memo_date,
			dept_code, demand_no, major_head, submajor_head, minor_head, plan_status, scheme_head, 
			detail_head, subdetail_head, voted_charged, treasury_code, created_at)
        SELECT
            sanction_no,
            hoa_id,
			allot.agency_code,
            t.ddo_code,
            SUM(self_limit_amount),
            SUM(self_limit_amount),
            allot.fin_year,
            sanction_date::Date,
			h.dept_code, h.demand_no, h.major_head, h.submajor_head, h.minor_head,
			h.plan_status, h.scheme_head, h.detail_head, h.subdetail_head, h.voted_charged,
			t.treasury_code, now()
        FROM inserted_allotment allot, hoa_data h, extract_treasury_code t
		WHERE t.ddo_code = allot.ddo_code
			AND allot.agency_code = allot.agency_code
			AND allot.hoa_id = h.id
        GROUP BY sanction_no, hoa_id, t.ddo_code, fin_year, sanction_date,
		allot.agency_code,dept_code, demand_no, major_head, submajor_head, 
		minor_head,plan_status, scheme_head, 
		detail_head, subdetail_head, voted_charged,t.treasury_code
  --       ON CONFLICT(memo_number, sender_sao_ddo_code, receiver_sao_ddo_code)
		-- DO NOTHING
  --       DO UPDATE 
  --       SET 
  --           budget_alloted_amount = bantan.ddo_allotment_transactions.budget_alloted_amount + EXCLUDED.budget_alloted_amount,
  --           ceiling_amount = bantan.ddo_allotment_transactions.ceiling_amount + EXCLUDED.ceiling_amount
		RETURNING allotment_id
	),
	update_ddo_wallet AS(
        -- Insert into bantan.ddo_wallet using inserted_allotment
        INSERT INTO bantan.ddo_wallet(
            sao_ddo_code, budget_alloted_amount, ceiling_amount, active_hoa_id, financial_year,
			dept_code, demand_no, major_head, submajor_head, minor_head, plan_status, scheme_head, 
			detail_head, subdetail_head, voted_charged, treasury_code)
        SELECT
            t.ddo_code,
            SUM(
                CASE 
                    WHEN limit_type = 'A' THEN self_limit_amount
                    ELSE -self_limit_amount
                END
            ),
            SUM(
                CASE 
                    WHEN limit_type = 'A' THEN self_limit_amount
                    ELSE -self_limit_amount
                END
            ),
            hoa_id,
            fin_year,
			h.dept_code, h.demand_no, h.major_head, h.submajor_head, h.minor_head,
			h.plan_status, h.scheme_head, h.detail_head, h.subdetail_head, h.voted_charged,
			t.treasury_code
        FROM inserted_allotment allot
		JOIN hoa_data h ON allot.hoa_id = h.id
        JOIN extract_treasury_code t ON allot.ddo_code = t.ddo_code
        GROUP BY t.ddo_code, hoa_id, fin_year,
		dept_code, demand_no, major_head, submajor_head, minor_head, plan_status, scheme_head, 
			detail_head, subdetail_head, voted_charged, t.treasury_code
        ON CONFLICT(sao_ddo_code, active_hoa_id, financial_year) 
        DO UPDATE 
        SET 
            budget_alloted_amount = bantan.ddo_wallet.budget_alloted_amount + EXCLUDED.budget_alloted_amount,
            ceiling_amount = bantan.ddo_wallet.ceiling_amount + EXCLUDED.ceiling_amount
		RETURNING id
	)

	SELECT json_build_object(
            'AllotmentId', (jit_allotment_payload->0->>'AllotmentId'),
            'Status', CASE 
                          WHEN update_allotment_transaction.allotment_id IS NOT NULL THEN 1 
                          ELSE 0 
                      END
        ) INTO allotmentAckResult
	FROM jsonb_array_elements(jit_allotment_payload) AS value, update_allotment_transaction;

	IF allotmentAckResult IS NOT NULL THEN
		PERFORM message_queue.insert_message_queue(
			'bill_jit_allotment_ack', allotmentAckResult
		);    
	END IF;
        -- Fetch the allotment transactions that have not been sent
	SELECT json_agg(json_build_object(
		'AllotmentId', allotment_id,
		'HoaId', active_hoa_id,
		'DdoCode', trim(receiver_sao_ddo_code),
		'AgencyCode',trim(sender_sao_ddo_code),
		'Finyear', financial_year,
		'MemoNo', memo_number,
		'Amount', ceiling_amount
	)) INTO finalResult
	FROM bantan.ddo_allotment_transactions WHERE is_send = FALSE;

	-- Log and send data to message queue if there are unsent transactions
	IF finalResult IS NOT NULL THEN
		PERFORM message_queue.insert_message_queue(
			'bill_cts_allotment'::character varying, finalResult
		);    
	END IF;

	-- Mark the transactions as sent
	UPDATE bantan.ddo_allotment_transactions
	SET is_send = TRUE 
	WHERE allotment_id = ANY(
		SELECT (value->>'AllotmentId')::BIGINT 
		FROM jsonb_array_elements(finalResult)
	);
END;
$$;


ALTER PROCEDURE jit.insert_jit_allotment(IN jit_allotment_payload jsonb) OWNER TO postgres;

--
-- TOC entry 422 (class 1255 OID 920268)
-- Name: insert_jit_allotment_withdrawal(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_jit_allotment_withdrawal(IN jit_withdrawl_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE 
    finalResult JSONB;
    allotmentAckResult JSONB;
BEGIN   
    -- Insert into jit.jit_allotment and capture inserted records
    WITH selected_records AS (
	    SELECT 
	        value->>'Slscode' AS sls_code, 
	        (value->>'Finyear')::SMALLINT AS fin_year,
	        SUM((value->>'SelfLimitAmt')::NUMERIC::BIGINT) AS self_limit_amount,
	        (value->>'HoaId')::NUMERIC::BIGINT AS hoa_id,
	        value->>'TreasuryCode' AS treasury_code,
	        value->>'DdoCode' AS ddo_code,
	        value->>'SanctionDate' AS sanction_date,
	        value->>'SanctionNo' AS sanction_no,
	        (value->>'SlsLimitDistributionId')::BIGINT AS sls_limit_distribution_id,
	        (value->>'HeadWiseSanctionId')::BIGINT AS head_wise_sanction_id,
	        value->>'LimitType' AS limit_type,
			value->>'Agencycode' AS agency_code,
	        value->>'FromSanctionNo' AS from_sanction_no
	    FROM jsonb_array_elements(jit_withdrawl_payload) AS value
		WHERE 
            floor((value->>'SelfLimitAmt')::NUMERIC)::BIGINT > 0
            AND (value->>'IsWithdraw')::BIGINT = 1
	    GROUP BY 
	        value->>'Slscode', 
	        (value->>'Finyear')::SMALLINT, 
	        value->>'TreasuryCode', 
	        value->>'DdoCode',
	        value->>'SanctionDate', 
	        value->>'SanctionNo', 
	        (value->>'HoaId')::NUMERIC::BIGINT,
	        (value->>'SlsLimitDistributionId')::BIGINT,
	        (value->>'HeadWiseSanctionId')::BIGINT,
	        value->>'LimitType',
			value->>'Agencycode',
	        value->>'FromSanctionNo'
	),
	filtered_records AS (
	    SELECT sr.*
	    FROM selected_records sr
	    INNER JOIN bantan.ddo_allotment_transactions ddo_trx 
	        ON TRIM(sr.from_sanction_no) = TRIM(ddo_trx.memo_number)
	        AND sr.ddo_code = ddo_trx.receiver_sao_ddo_code
			AND sr.agency_code  = ddo_trx.sender_sao_ddo_code
	    WHERE 
	        ddo_trx.ceiling_amount - ddo_trx.provisional_released_amount >= sr.self_limit_amount
	),
	allotment_withdrwl AS (
        INSERT INTO jit.jit_withdrawl (
            sls_code, fin_year, self_limit_amount, hoa_id, treasury_code, ddo_code, 
            sanction_date, sanction_no, sls_limit_distribution_id, head_wise_sanction_id, 
            limit_type, agency_code, from_sanction_no
        )
        SELECT * FROM filtered_records
		RETURNING *
    ),
	update_allotment_transaction AS(
        -- Insert into bantan.ddo_allotment_transactions using inserted_allotment
        UPDATE bantan.ddo_allotment_transactions
        SET 
            surrender_amount = bantan.ddo_allotment_transactions.surrender_amount + w.self_limit_amount, 
            ceiling_amount = bantan.ddo_allotment_transactions.ceiling_amount - w.self_limit_amount
		FROM allotment_withdrwl w
		where TRIM(memo_number) = TRIM(w.from_sanction_no) and receiver_sao_ddo_code=w.ddo_code
			and sender_sao_ddo_code=w.agency_code

		RETURNING allotment_id, w.*
	),
	update_ddo_wallet AS(
        -- Insert into bantan.ddo_wallet using inserted_allotment
        UPDATE bantan.ddo_wallet
        SET 
            surrender_amount = bantan.ddo_wallet.surrender_amount + w.self_limit_amount, 
            ceiling_amount = bantan.ddo_wallet.ceiling_amount - w.self_limit_amount
        FROM 
		(select hoa_id,ddo_code, sum(self_limit_amount) as self_limit_amount from allotment_withdrwl group by (ddo_code,hoa_id)) w
        where active_hoa_id = w.hoa_id and sao_ddo_code=w.ddo_code
        
		-- RETURNING id
	),
	filtered_withdrawals AS (
	    SELECT a.*, uat.allotment_id
	    FROM allotment_withdrwl a, update_allotment_transaction uat
		WHERE TRIM(a.from_sanction_no) = TRIM(uat.from_sanction_no) 
			AND uat.ddo_code=a.ddo_code
			AND uat.agency_code=a.agency_code
	)
	
	SELECT json_agg(json_build_object(
	    'AllotmentId', allotment_id,
	    'HoaId', hoa_id,
	    'DdoCode', ddo_code,
	    'Finyear', fin_year,
		'FromMemoNo', from_sanction_no,
	    'MemoNo', sanction_no,
	    'WithdrawAmount', self_limit_amount
	)),
	json_build_object(
	    'AllotmentId', (jit_withdrawl_payload->0->>'AllotmentId'),
        'Status', CASE 
                      WHEN EXISTS (SELECT 1 FROM filtered_withdrawals) THEN 1 
                      ELSE 0 
                  END
	)
	INTO finalResult, allotmentAckResult
	FROM filtered_withdrawals;

	-- -- Log and send data to message queue if there are unsent transactions
	IF finalResult IS NOT NULL THEN
		PERFORM message_queue.insert_message_queue(
			'bill_cts_allotment_withdrawl', finalResult
		);    
	END IF;

	IF allotmentAckResult IS NOT NULL THEN
		PERFORM message_queue.insert_message_queue(
			'billing_jit_allotment_withdrawl_ack', allotmentAckResult
		);    
	END IF;

	-- -- Mark the Withdrawl transactions as sent
	UPDATE jit.jit_withdrawl
	SET is_send = true 
	WHERE sanction_no = ANY(
		SELECT (value->>'MemoNo')::character varying 
		FROM jsonb_array_elements(finalResult)
	);
END;
$$;


ALTER PROCEDURE jit.insert_jit_allotment_withdrawal(IN jit_withdrawl_payload jsonb) OWNER TO postgres;

--
-- TOC entry 444 (class 1255 OID 920269)
-- Name: insert_jit_details(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_jit_details(IN jit_details_payload jsonb)
    LANGUAGE plpgsql
    AS $$
Declare 
	_total_gst numeric;
	_total_bt numeric;
	_total_treasury_bt numeric;
	_total_ag_bt numeric;
	_ben_count smallint;
	_fto_ref_id bigint;
	_not_exists_ifsc_count smallint;
	_not_exists_ifsc varchar[];
 	ftoAckResult jsonb;	
	_failed_amount bigint;
	_requested_amount  bigint;
BEGIN
		-- /*
		 -- Sum of payload amounts
	    SELECT SUM((p->>'ReissueAmount')::numeric)
	    INTO _requested_amount 
	    FROM jsonb_array_elements(jit_details_payload->'PayeeDetails') p;
		
		SELECT SUM(failed_transaction_amount) INTO _failed_amount
		FROM cts.failed_transaction_beneficiary
		WHERE end_to_end_id = ANY (
		    SELECT (value->>'LastEndToEndId')::text
		    FROM jsonb_array_elements(jit_details_payload->'PayeeDetails') AS value
		);
	
		 -- Validation
	    IF _requested_amount <> _failed_amount THEN
		    RAISE EXCEPTION 
		        'Validation failed: Requested payload total (₹%) does not match Failed Transaction total (₹%)',
		        _requested_amount, _failed_amount;
		END IF;
		-- */
		SELECT COUNT(1), array_agg(ifsc) INTO _not_exists_ifsc_count, _not_exists_ifsc
		FROM
		((SELECT value->>'Ifsc' AS ifsc FROM jsonb_array_elements(jit_details_payload->'PayeeDetails') AS value)
		EXCEPT
		(SELECT ifsc FROM master.rbi_ifsc_stock WHERE is_active=true)) AS q;
	
		IF _not_exists_ifsc_count > 0 THEN
			RAISE EXCEPTION 'IFSC Code Does Not Exist: %', _not_exists_ifsc;
		ELSE
			--Calculate total GST
			SELECT SUM((value->>'GSTAmount')::numeric) INTO _total_gst
			FROM jsonb_array_elements(jit_details_payload->'GSTDetails') AS value;
			--Calculate total BT
			SELECT 
				sum(COALESCE((value->>'Amount')::numeric,0)),
				sum(COALESCE((value->>'Amount')::numeric,0)) FILTER(WHERE REPLACE((value->>'BtType'), ' ', '') ='TreasuryBT'),
				sum(COALESCE((value->>'Amount')::numeric,0)) FILTER(WHERE REPLACE((value->>'BtType'), ' ', '') ='AGBT') 
			INTO _total_bt, _total_treasury_bt, _total_ag_bt
			FROM jsonb_array_elements(jit_details_payload->'BtDetails') AS value;
		
			 -- Handle NULL totals explicitly
		    _total_bt := COALESCE(_total_bt, 0);
		    _total_treasury_bt := COALESCE(_total_treasury_bt, 0);
		    _total_ag_bt := COALESCE(_total_ag_bt, 0);
			_total_gst := COALESCE(_total_gst, 0);
		
			--Calculate Payee Count
			SELECT COUNT(value->>'PayeeId') INTO _ben_count
			FROM jsonb_array_elements(jit_details_payload->'PayeeDetails') AS value;
					
			-- INSERT jit.tsa_exp_details
			INSERT INTO jit.tsa_exp_details(
				ref_no, sls_code, scheme_name, agency_code, agency_name, hoa_id, treas_code, ddo_code,is_top_up,
				is_reissue, net_amount, gross_amount, topup_amount, reissue_amount, total_bt, total_treasury_bt,
				total_ag_bt, total_gst, payee_count, category_code, district_code_lgd, 
				total_amt_for_cs_calc_sc, total_amt_for_cs_calc_scoc, total_amt_for_cs_calc_sccc,
				total_amt_for_cs_calc_scsal, total_amt_for_cs_calc_st, 
				total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_stcc, total_amt_for_cs_calc_stsal,
				total_amt_for_cs_calc_ot, total_amt_for_cs_calc_otoc, 
				total_amt_for_cs_calc_otcc, total_amt_for_cs_calc_otsal, fto_type, financial_year, old_jit_ref_no)
			VALUES (
					(jit_details_payload->>'JitReferenceNo'), (jit_details_payload->>'SlsCode'),
					(jit_details_payload->>'SchemeName'),
					(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),
					(jit_details_payload->>'HoaId')::bigint,
					(jit_details_payload->>'TreasCode'),(jit_details_payload->>'DdoCode'),
					(jit_details_payload->>'TOPUP')::boolean,
					(jit_details_payload->>'Reissue')::boolean,
					(jit_details_payload->>'NetAmount')::numeric,
					(jit_details_payload->>'GrossAmount')::numeric,
					(jit_details_payload->>'TopUpAmount')::numeric,
					(jit_details_payload->>'ReissueAmount')::numeric,
					_total_bt,_total_treasury_bt,_total_ag_bt,_total_gst,_ben_count,
					(jit_details_payload->>'CategoryCode'),
					(jit_details_payload->>'DistrictCodeLgd'),
					(jit_details_payload->>'TotalAmtForCSCalcSC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcSCOC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcSCCC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcSCSAL')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcST')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcSTOC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcSTCC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcSTSAL')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcOT')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcOTOC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcOTCC')::numeric,
					(jit_details_payload->>'TotalAmtForCSCalcOTSAL')::numeric,
					CASE
						WHEN (jit_details_payload->>'TOPUP')::boolean THEN 'TOPUP'
						WHEN (jit_details_payload->>'Reissue')::boolean THEN 'REISSUE'
						ELSE 'NORMAL'
					END,
					(jit_details_payload->>'FinYear')::smallint,
					(jit_details_payload->>'OldJitReferenceNo')
			) ON CONFLICT DO NOTHING
			RETURNING id INTO _fto_ref_id;
			IF (_fto_ref_id >0) THEN
				-- INSERT jit.tsa_payeemaster
				WITH PAYEE_MASTERS AS(
					INSERT INTO jit.tsa_payeemaster(
						payee_code, payee_name, pan_no, aadhaar_no, mobile_no, email_id, bank_name,
						acc_no, ifsc_code, gross_amount, net_amount, reissue_amount, 
						last_end_to_end_id, agency_code, agency_name, ref_id, ref_no, old_ref_no,
						district_code_lgd, state_code_lgd, urban_rural_flag, block_lgd, panchayat_lgd,
						village_lgd, tehsil_lgd, town_lgd, ward_lgd)
					SELECT
						(value->>'PayeeId')::character varying, (value->>'BeneficiaryName')::character varying,
						(value->>'PAN')::character varying,
						(value->>'Aadhar')::character varying, (value->>'MobileNo')::character varying,
						(value->>'EmailId')::character varying,
						b.bankname,(value->>'AccountNumber')::character varying, (value->>'Ifsc')::character varying,
						(value->>'GrossAmount')::numeric,
						(value->>'NetAmount')::decimal, (value->>'ReissueAmount')::decimal, (value->>'LastEndToEndId'),
						(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),
						_fto_ref_id,(jit_details_payload->>'JitReferenceNo'), (jit_details_payload->>'OldJitReferenceNo'),
						(value->>'DistrictCodeLgd'), (value->>'StateCodeLgd'), (value->>'UrbanRuralFlag'),
						(value->>'BlockLgd'), (value->>'PanchayatLgd'),(value->>'VillageLgd'),
						(value->>'TehsilLgd'), (value->>'TownLgd'), (value->>'WardLgd')
					FROM
						jsonb_array_elements(jit_details_payload->'PayeeDetails') value, master.rbi_ifsc_stock b 
					WHERE value->>'Ifsc'::character varying = b.ifsc
					returning id as payee_id, payee_code, payee_name
				)
				,
				BY_TRANSFER AS(
					-- INSERT jit.payee_deduction
					INSERT INTO jit.payee_deduction(payee_id, payee_code, bt_code, bt_desc, bt_type, amount,
					agency_code, agency_name, ref_no, ref_id)
					SELECT  p.payee_id, (value->>'PayeeId')::character varying, (value->>'BtCode')::numeric::smallint,
							(value->>'BtName'),(value->>'BtType'),(value->>'Amount')::decimal,
							(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),
							(jit_details_payload->>'JitReferenceNo'),_fto_ref_id
					FROM	
						jsonb_array_elements(jit_details_payload->'BtDetails') value , PAYEE_MASTERS p
						WHERE (value->>'PayeeId')::character varying=p.payee_code
					returning id
				),
				PAYEE_COMPONENTS AS(
					-- INSERT jit.exp_payee_components
					INSERT INTO jit.exp_payee_components(payee_id, payee_code, componentcode, componentname,
					amount, agency_code, agency_name, ref_no, ref_id, slscode,scheme_name)
					SELECT
						p.payee_id, (value->>'PayeeId')::character varying, (value->>'ComponentCode')::character varying,
						(value->>'ComponentName')::character varying,
						(value->>'Amount')::numeric, (jit_details_payload->>'AgencyCode'),
						(jit_details_payload->>'AgencyName'),
						(jit_details_payload->>'JitReferenceNo'), _fto_ref_id,
						REPLACE((jit_details_payload->'SlsCode')::text, '"', ''),
						REPLACE((jit_details_payload->'SchemeName')::text, '"', '')
					FROM	
					jsonb_array_elements(jit_details_payload->'ComponentDetails') value, PAYEE_MASTERS p
					WHERE (value->>'PayeeId')::character varying=p.payee_code
					returning id
				),
				PAYEE_VOUCHER AS(
					-- INSERT jit.fto_voucher
					INSERT INTO jit.fto_voucher(
					payee_id, payee_code, payee_name, voucher_no, voucher_date, amount, authority, desc_charges,
					agency_code, agency_name, ref_no, ref_id)
					SELECT
						p.payee_id, (value->>'PayeeId')::character varying, p.payee_name,
						(value->>'VoucherNo')::character varying,(value->>'VoucherDate')::date,
						(value->>'Amount')::numeric, (value->>'Authority')::character varying,
						(value->>'DescCharges')::character varying,
						(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),
						(jit_details_payload->>'JitReferenceNo'),_fto_ref_id
					FROM	
					jsonb_array_elements(jit_details_payload->'VoucherDetails') AS value, PAYEE_MASTERS p
					WHERE (value->>'PayeeId')::character varying=p.payee_code
					returning id
				),
				PAYEE_GST AS(
					-- INSERT  jit.gst
					INSERT INTO jit.gst(
					payee_id, payee_code, payee_name, payee_gst_in, invoice_no, invoice_value, invoice_date,
					gst_amount, sgst_amount, cgst_amount, agency_code, agency_name, ref_no, ref_id, igst_amount, is_igst)
					SELECT p.payee_id, (value->>'PayeeId')::character varying,
						(value->>'PayeeName')::character varying,
						(value->>'PayeeGstIn')::character varying, (value->>'InvoiceNo')::character varying,
						(value->>'InvoiceValue')::numeric,
						(value->>'InvoiceDate')::date,(value->>'GSTAmount')::numeric,
						(value->>'SGSTAmount')::numeric, 
						(value->>'CGSTAmount')::numeric, (jit_details_payload->>'AgencyCode'),
						(jit_details_payload->>'AgencyName'),
						(jit_details_payload->>'JitReferenceNo'),_fto_ref_id,
						(value->>'IgstTotal')::numeric::bigint, (value->>'IsIgst')::bool
					FROM	
					jsonb_array_elements(jit_details_payload->'GSTDetails') AS value, PAYEE_MASTERS p
						WHERE (value->>'PayeeId')::character varying=p.payee_code
					returning id
				)
				-- INSERT  jit.tsa_schemecomponent
				INSERT INTO jit.tsa_schemecomponent(slscode, shemename, componentcode, componentname)
					SELECT
						(jit_details_payload->>'SlsCode'),
						(jit_details_payload->>'SchemeName'),
						(value->>'ComponentCode')::character varying,
						(value->>'ComponentName')::character varying
					FROM	
					jsonb_array_elements(jit_details_payload->'ComponentDetails') AS value;
				
				-- INSERT jit.jit_fto_sanction_booking
				INSERT INTO jit.jit_fto_sanction_booking(sanction_id, sanction_no,ddo_code, booked_amt,
				ref_no, ref_id, allotment_id, hoa_id, old_ref_no)
				SELECT  a.id, (value->>'SanctionNo')::character varying,(jit_details_payload->>'DdoCode'),
				(value->>'DebitAmt')::numeric, (jit_details_payload->>'JitReferenceNo'),
				_fto_ref_id, allotment_trans.allotment_id, (value->>'HoaId')::bigint,
				-- (value->>'SanctionDate')::timestamp without time zone,
				(value->>'OldRefNo')
				FROM jsonb_array_elements(jit_details_payload->'SanctionDetails') AS value
				LEFT JOIN jit.jit_allotment a 
				ON a.sanction_no=(value->>'SanctionNo')::character varying
				AND a.ddo_code=(jit_details_payload->>'DdoCode')
				AND a.agency_code= (jit_details_payload->>'AgencyCode')
			   	LEFT JOIN bantan.ddo_allotment_transactions allotment_trans
				ON allotment_trans.memo_number = (value->>'SanctionNo') 
				AND allotment_trans.receiver_sao_ddo_code = (jit_details_payload->>'DdoCode')
				AND allotment_trans.sender_sao_ddo_code = (jit_details_payload->>'AgencyCode');
			
			-- ACK TO WBJIT
			SELECT json_build_object(
			'JitReferenceNo', (jit_details_payload->>'JitReferenceNo'),
			'Status', CASE 
						  WHEN (_fto_ref_id > 0) THEN 1 
						  ELSE 0 
					  END
		    ) INTO ftoAckResult;
		
			IF ftoAckResult IS NOT NULL THEN
				PERFORM message_queue.insert_message_queue(
					'bill_jit_fto_ack', ftoAckResult
				);    
			END IF;
	
		END IF;
	END IF;
 END;
$$;


ALTER PROCEDURE jit.insert_jit_details(IN jit_details_payload jsonb) OWNER TO postgres;

--
-- TOC entry 458 (class 1255 OID 920271)
-- Name: insert_jit_details_wo_tsa_exp_details(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_jit_details_wo_tsa_exp_details(IN jit_details_payload jsonb)
    LANGUAGE plpgsql
    AS $$
Declare 
	_total_gst numeric;
	_total_bt numeric;
	_total_treasury_bt numeric;
	_total_ag_bt numeric;
	_ben_count smallint;
	_fto_ref_id bigint;
BEGIN
	--Calculate total GST
	select sum((value->>'GSTAmount')::numeric) into _total_gst from jsonb_array_elements(jit_details_payload->'GSTDetails') AS value;
	--Calculate total BT
	select 
		sum(COALESCE((value->>'Amount')::numeric,0)),
		sum(COALESCE((value->>'Amount')::numeric,0)) FILTER(WHERE REPLACE((value->>'BtType'), ' ', '') ='TreasuryBT'),
		sum(COALESCE((value->>'Amount')::numeric,0)) FILTER(WHERE REPLACE((value->>'BtType'), ' ', '') ='AGBT') 
	INTO _total_bt, _total_treasury_bt, _total_ag_bt
	from jsonb_array_elements(jit_details_payload->'BtDetails') AS value;

	 -- Handle NULL totals explicitly
    _total_bt := COALESCE(_total_bt, 0);
    _total_treasury_bt := COALESCE(_total_treasury_bt, 0);
    _total_ag_bt := COALESCE(_total_ag_bt, 0);
	_total_gst := COALESCE(_total_gst, 0);

	--Calculate Payee Count
	select count(value->>'PayeeId') into _ben_count from jsonb_array_elements(jit_details_payload->'PayeeDetails') AS value;

	RAISE NOTICE 'GST AMount: %, BT Amount: %, Beneficiary Count: %',_total_gst,_total_bt,_ben_count;
	
	-- INSERT jit.tsa_exp_details
	-- INSERT INTO jit.tsa_exp_details(
	-- 	ref_no, sls_code, scheme_name, agency_code, agency_name, hoa_id, treas_code, ddo_code, is_top_up, is_reissue, 
	-- 	net_amount, gross_amount, topup_amount, reissue_amount, total_bt, total_treasury_bt, total_ag_bt, total_gst, payee_count, category_code, district_code_lgd, 
	-- 	total_amt_for_cs_calc_sc, total_amt_for_cs_calc_scoc, total_amt_for_cs_calc_sccc, total_amt_for_cs_calc_scsal, total_amt_for_cs_calc_st, 
	-- 	total_amt_for_cs_calc_stoc, total_amt_for_cs_calc_stcc, total_amt_for_cs_calc_stsal, total_amt_for_cs_calc_ot, total_amt_for_cs_calc_otoc, 
	-- 	total_amt_for_cs_calc_otcc, total_amt_for_cs_calc_otsal, fto_type)
	-- VALUES (
	-- 		(jit_details_payload->>'JitReferenceNo'), (jit_details_payload->>'SlsCode'), (jit_details_payload->>'SchemeName'),
	-- 		(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),	(jit_details_payload->>'HoaId')::bigint,
	-- 		(jit_details_payload->>'TreasCode'),(jit_details_payload->>'DdoCode'),(jit_details_payload->>'TOPUP')::boolean,
	-- 		(jit_details_payload->>'Reissue')::boolean,(jit_details_payload->>'NetAmount')::numeric,(jit_details_payload->>'GrossAmount')::numeric,
	-- 		(jit_details_payload->>'TopUpAmount')::numeric,(jit_details_payload->>'ReissueAmount')::numeric,
	-- 		_total_bt,_total_treasury_bt,_total_ag_bt,_total_gst,_ben_count,(jit_details_payload->>'CategoryCode'),(jit_details_payload->>'DistrictCodeLgd'),
	-- 		(jit_details_payload->>'TotalAmtForCSCalcSC')::numeric,(jit_details_payload->>'TotalAmtForCSCalcSCOC')::numeric,
	-- 		(jit_details_payload->>'TotalAmtForCSCalcSCCC')::numeric,(jit_details_payload->>'TotalAmtForCSCalcSCSAL')::numeric,
	-- 		(jit_details_payload->>'TotalAmtForCSCalcST')::numeric,(jit_details_payload->>'TotalAmtForCSCalcSTOC')::numeric,
	-- 		(jit_details_payload->>'TotalAmtForCSCalcSTCC')::numeric,(jit_details_payload->>'TotalAmtForCSCalcSTSAL')::numeric,
	-- 		(jit_details_payload->>'TotalAmtForCSCalcOT')::numeric,(jit_details_payload->>'TotalAmtForCSCalcOTOC')::numeric,
	-- 		(jit_details_payload->>'TotalAmtForCSCalcOTCC')::numeric,(jit_details_payload->>'TotalAmtForCSCalcOTSAL')::numeric,
	-- 		CASE
	-- 			WHEN (jit_details_payload->>'TOPUP')::boolean THEN 'TOPUP'
	-- 			WHEN (jit_details_payload->>'Reissue')::boolean THEN 'REISSUE'
	-- 			ELSE 'NORMAL'
	-- 		END 
	-- ) ON CONFLICT DO NOTHING
	-- RETURNING id INTO _fto_ref_id;
	select id into _fto_ref_id from jit.tsa_exp_details where ref_no= jit_details_payload->>'JitReferenceNo';
		
	RAISE NOTICE '_fto_ref_id: % , (IS NULL)%, (GRTZERO)%',_fto_ref_id,( _fto_ref_id != NULL), (_fto_ref_id >0);
 
	IF (_fto_ref_id >0) THEN
		RAISE NOTICE '_fto_ref_id ##: %',_fto_ref_id;

		-- INSERT jit.tsa_payeemaster
		WITH PAYEE_MASTERS AS(
			INSERT INTO jit.tsa_payeemaster(
				payee_code, payee_name, pan_no, aadhaar_no, mobile_no, email_id, bank_name, acc_no, ifsc_code, gross_amount, net_amount, reissue_amount, 
				last_end_to_end_id, agency_code, agency_name, ref_id, ref_no)
			SELECT
				(value->>'PayeeId')::character varying, (value->>'BeneficiaryName')::character varying, (value->>'PAN')::character varying,
				(value->>'Aadhar')::character varying, (value->>'MobileNo')::character varying, (value->>'EmailId')::character varying,
				b.bankname,(value->>'AccountNumber')::character varying, (value->>'Ifsc')::character varying,(value->>'GrossAmount')::numeric,
				(value->>'NetAmount')::decimal, (value->>'ReissueAmount')::decimal, (value->>'LastEndToEndId'),
				(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),_fto_ref_id,(jit_details_payload->>'JitReferenceNo')
			FROM
				jsonb_array_elements(jit_details_payload->'PayeeDetails') value, master.rbi_ifsc_stock b 
			where value->>'Ifsc'::character varying = b.ifsc
			returning id as payee_id, payee_code, payee_name
		)
		,
		BY_TRANSFER AS(
			-- INSERT jit.payee_deduction
			INSERT INTO jit.payee_deduction(payee_id, payee_code, bt_code, bt_desc, bt_type, amount, agency_code, agency_name, ref_no, ref_id)
			SELECT  p.payee_id, (value->>'PayeeId')::character varying, (value->>'BtCode')::numeric::smallint, (value->>'BtName'),(value->>'BtType'),(value->>'Amount')::decimal,
					(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'), (jit_details_payload->>'JitReferenceNo'),_fto_ref_id
				from	
				jsonb_array_elements(jit_details_payload->'BtDetails') value , PAYEE_MASTERS p
				where  (value->>'PayeeId')::character varying=p.payee_code
			returning id
		),
		PAYEE_COMPONENTS AS(
			-- INSERT jit.exp_payee_components
			INSERT INTO jit.exp_payee_components(payee_id, payee_code, componentcode, componentname, amount, agency_code, agency_name, ref_no, ref_id, slscode,scheme_name)
			SELECT
				p.payee_id, (value->>'PayeeId')::character varying, (value->>'ComponentCode')::character varying, (value->>'ComponentName')::character varying,
				(value->>'Amount')::numeric, (jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),
				(jit_details_payload->>'JitReferenceNo'), _fto_ref_id,
				REPLACE((jit_details_payload->'SlsCode')::text, '"', ''), REPLACE((jit_details_payload->'SchemeName')::text, '"', '')
			from	
			jsonb_array_elements(jit_details_payload->'ComponentDetails')  value, PAYEE_MASTERS p
			where  (value->>'PayeeId')::character varying=p.payee_code
			returning id
		),
		PAYEE_VOUCHER AS(
			-- INSERT jit.fto_voucher
			INSERT INTO jit.fto_voucher(
			payee_id, payee_code, payee_name, voucher_no, voucher_date, amount, authority, desc_charges, agency_code, agency_name, ref_no, ref_id)
			SELECT
				p.payee_id, (value->>'PayeeId')::character varying, p.payee_name, (value->>'VoucherNo')::character varying,(value->>'VoucherDate')::date,
				(value->>'Amount')::numeric, (value->>'Authority')::character varying, (value->>'DescCharges')::character varying,
				(jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),(jit_details_payload->>'JitReferenceNo'),_fto_ref_id
			from	
			jsonb_array_elements(jit_details_payload->'VoucherDetails') AS value, PAYEE_MASTERS p
			where  (value->>'PayeeId')::character varying=p.payee_code
			returning id
		),
		PAYEE_GST AS(
			-- INSERT  jit.gst
			INSERT INTO jit.gst(
			payee_id, payee_code, payee_name, payee_gst_in, invoice_no, invoice_value, invoice_date, gst_amount, sgst_amount, 
			cgst_amount, agency_code, agency_name, ref_no, ref_id, igst_amount, is_igst)
			SELECT p.payee_id, (value->>'PayeeId')::character varying, (value->>'PayeeName')::character varying,
				(value->>'PayeeGstIn')::character varying, (value->>'InvoiceNo')::character varying, (value->>'InvoiceValue')::numeric,
				(value->>'InvoiceDate')::date,(value->>'GSTAmount')::numeric, (value->>'SGSTAmount')::numeric, 
				(value->>'CGSTAmount')::numeric, (jit_details_payload->>'AgencyCode'),(jit_details_payload->>'AgencyName'),
				(jit_details_payload->>'JitReferenceNo'),_fto_ref_id,(value->>'IgstTotal')::numeric::bigint, (value->>'IsIgst')::bool
			from	
			jsonb_array_elements(jit_details_payload->'GSTDetails') AS value, PAYEE_MASTERS p
				where  (value->>'PayeeId')::character varying=p.payee_code
			returning id
		)
		-- INSERT  jit.tsa_schemecomponent
		INSERT INTO jit.tsa_schemecomponent(slscode, shemename, componentcode, componentname)
			SELECT
				(jit_details_payload->>'SlsCode'),
				(jit_details_payload->>'SchemeName'),
				(value->>'ComponentCode')::character varying,
				(value->>'ComponentName')::character varying
			from	
			jsonb_array_elements(jit_details_payload->'ComponentDetails') AS value;
		
		-- INSERT jit.jit_fto_sanction_booking
		INSERT INTO jit.jit_fto_sanction_booking(sanction_id, sanction_no,ddo_code, booked_amt, ref_no, ref_id, allotment_id)
		select  a.id, (value->>'SanctionNo')::character varying,(jit_details_payload->>'DdoCode'),(value->>'DebitAmt')::numeric, (jit_details_payload->>'JitReferenceNo'),_fto_ref_id, allotment_trans.allotment_id
		from jsonb_array_elements(jit_details_payload->'SanctionDetails') AS value
		LEFT JOIN jit.jit_allotment a on a.sanction_no=(value->>'SanctionNo')::character varying and a.ddo_code=(jit_details_payload->>'DdoCode')
	   	LEFT JOIN bantan_master.allotment_transactions allotment_trans
		on allotment_trans.memo_number = (value->>'SanctionNo');
		
		-- INSERT INTO jit.jit_fto_sanction_booking(sanction_id, sanction_no,ddo_code, booked_amt, ref_no, ref_id)
		-- select  a.id, (value->>'SanctionNo')::character varying,(jit_details_payload->>'DdoCode'),(value->>'DebitAmt')::numeric, (jit_details_payload->>'JitReferenceNo'),_fto_ref_id
		-- from jsonb_array_elements(jit_details_payload->'SanctionDetails') AS value
		-- LEFT JOIN jit.jit_allotment a on a.sanction_no=(value->>'SanctionNo')::character varying and a.ddo_code=(jit_details_payload->>'DdoCode');
		-- -- INSERT jit.jit_report_details
		-- INSERT INTO  jit.jit_report_details (scheme_code, scheme_name,agency_code,agency_name,hoa_id,fto_received)
	 --        VALUES ((jit_details_payload->>'SlsCode'),(jit_details_payload->>'SchemeName'), (jit_details_payload->>'AgencyCode'),
		-- 	(jit_details_payload->>'AgencyName'),(jit_details_payload->>'HoaId')::bigint,1)
		-- ON CONFLICT (scheme_code, agency_code, hoa_id)
		-- DO UPDATE 
		-- SET fto_received =jit.jit_report_details.fto_received +1;
	END IF;

 END;
$$;


ALTER PROCEDURE jit.insert_jit_details_wo_tsa_exp_details(IN jit_details_payload jsonb) OWNER TO postgres;

--
-- TOC entry 456 (class 1255 OID 920273)
-- Name: insert_jit_report(); Type: FUNCTION; Schema: jit; Owner: postgres
--

CREATE OR REPLACE FUNCTION  jit.insert_jit_report() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
        
BEGIN

    IF NEW.is_rejected = false THEN
        -- If it doesn't exist, insert a new record
        INSERT INTO  jit.jit_report_details (scheme_code, scheme_name, hoa_id, fto_received, ddo_code)
        VALUES (NEW.sls_code, NEW.scheme_name, NEW.hoa_id, 1, NEW.ddo_code)
		ON CONFLICT (ddo_code, hoa_id)
		DO UPDATE
		SET 
          fto_received =jit.jit_report_details.fto_received + 1
        WHERE jit.jit_report_details.scheme_code = NEW.sls_code
		AND  jit.jit_report_details.agency_code = NEW.agency_code 
		AND jit.jit_report_details.hoa_id=NEW.hoa_id;
		
    ELSIF NEW.is_rejected = true THEN
      UPDATE  jit.jit_report_details
        SET 
          fto_rejected =jit.jit_report_details.fto_rejected + 1
        WHERE jit.jit_report_details.scheme_code = NEW.sls_code
		AND jit.jit_report_details.hoa_id = NEW.hoa_id ;
   END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION jit.insert_jit_report() OWNER TO postgres;

--
-- TOC entry 457 (class 1255 OID 920274)
-- Name: insert_jit_scheme_config_master(jsonb); Type: FUNCTION; Schema: jit; Owner: postgres
--

CREATE OR REPLACE FUNCTION  jit.insert_jit_scheme_config_master(in_payload jsonb) RETURNS integer
    LANGUAGE plpgsql PARALLEL SAFE
    AS $$
DECLARE
    result integer;
BEGIN
    WITH upsert_data AS (
        -- Convert JSON array to recordset
        SELECT
            (allocation_data->>'Controllercode') AS controller_code,
            (allocation_data->>'Csscode') AS css_code,
            allocation_data->>'Cssname' AS css_name,
            allocation_data->>'Slscode' AS sls_code,
            allocation_data->>'Slsname' AS sls_name,
            (allocation_data->>'Centershareper')::numeric(5,2) AS goi_share,
            (allocation_data->>'Stateshareper')::numeric(5,2) AS state_share_percentage,
            allocation_data->>'Sgaccountnumber' AS debit_bank_acc_no,
            allocation_data->>'Modelno' AS model_no,
            allocation_data->>'Topup' AS topup,
            (allocation_data->>'Entrydate')::timestamp AS entry_date,
            (allocation_data->>'Statecd') AS state_code,
            1 AS is_active
        FROM jsonb_array_elements(in_payload) AS allocation_data
    ),
    upsert_result AS (
        -- Perform the insert or update (upsert) operation
        INSERT INTO jit.scheme_config_master (
            controllercode, csscode, cssname, sls_code, slsname, state_share, goi_share, 
            debit_bank_acc_no, modelno, topup, entrydate, state_code, is_active, updated_at
        )
        SELECT
            controller_code, css_code, css_name, sls_code, sls_name, state_share_percentage, goi_share, 
            debit_bank_acc_no, model_no, topup, entry_date, state_code, is_active, NOW()
        FROM upsert_data
        ON CONFLICT (sls_code, csscode)
        DO UPDATE 
        SET
            controllercode = EXCLUDED.controllercode,
            cssname = EXCLUDED.cssname,
            slsname = EXCLUDED.slsname,
            state_share = EXCLUDED.state_share,
            goi_share = EXCLUDED.goi_share,
            debit_bank_acc_no = EXCLUDED.debit_bank_acc_no,
            modelno = EXCLUDED.modelno,
            topup = EXCLUDED.topup,
            entrydate = EXCLUDED.entrydate,
            state_code = EXCLUDED.state_code,
            is_active = EXCLUDED.is_active,
            updated_at = NOW()  -- Update the timestamp for updates
        RETURNING *
    )
    -- Log the changes into the log table
    INSERT INTO billing_log.scheme_config_master_log (
        state_code, sls_code, debit_bank_acc_no, modelno, topup, entrydate, 
        csscode, cssname, slsname, controllercode, state_share, goi_share, is_active, action_type, old_values, new_values, created_at, updated_at
    )
    SELECT
        upsert_result.state_code,
        upsert_result.sls_code,
        upsert_result.debit_bank_acc_no,
        upsert_result.modelno,
        upsert_result.topup,
        upsert_result.entrydate,
        upsert_result.csscode,
        upsert_result.cssname,
        upsert_result.slsname,
        upsert_result.controllercode,
        upsert_result.state_share,
        upsert_result.goi_share,
        upsert_result.is_active,
        -- Capture action type as 'INSERT' or 'UPDATE'
        CASE WHEN NOT EXISTS (
			SELECT 1 FROM jit.scheme_config_master
			WHERE sls_code = upsert_result.sls_code
	        AND csscode = upsert_result.csscode)
		THEN 'INSERT' ELSE 'UPDATE' END AS action_type,
        -- Capture old values (only for UPDATE)
        (
            SELECT jsonb_build_object(
                'controllercode', controllercode,
                'csscode', csscode,
                'cssname', cssname,
                'sls_code', sls_code,
                'slsname', slsname,
                'state_share', state_share,
                'goi_share', goi_share,
                'debit_bank_acc_no', debit_bank_acc_no,
                'modelno', modelno,
                'topup', topup,
                'entrydate', entrydate,
                'state_code', state_code,
                'is_active', is_active,
                'created_at', created_at,
                'updated_at', updated_at
            )
            FROM jit.scheme_config_master
            WHERE sls_code = upsert_result.sls_code
              AND csscode = upsert_result.csscode
        ) AS old_values,
        TO_JSONB(upsert_result) AS new_values,
        -- For insert, set created_at; for update, set updated_at
        upsert_result.created_at,
        upsert_result.updated_at
    FROM upsert_result;

	PERFORM message_queue.insert_message_queue(
		'scheme_config_master_to_treasury'::character varying, in_payload
	);

    -- Return a status (could return a count of rows affected, etc.)
    RETURN 1;
END;
$$;


ALTER FUNCTION jit.insert_jit_scheme_config_master(in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 407 (class 1255 OID 920275)
-- Name: insert_mother_sanction_allocation(jsonb, character varying); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_mother_sanction_allocation(IN jit_hoa_details_payload jsonb, IN _queue_name character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE

BEGIN			
	-- Insert data into jit.mother_sanction_allocation
	INSERT INTO jit.mother_sanction_allocation(sls_scheme_code,
			hoa_id, sanction_amount, center_share_amount,
	  	 	state_share_amount, available_amount, css_scheme_code, 
			css_scheme_name, fin_year, amc_amt, psc_amt, efile_no, 
			sls_name, proposal_no, approval_status, mother_sanction_no,
			approved_date, sls_code, sls_limit_distribution_id,
			group_n_sanction_id, head_wise_sanction_id
			)
			SELECT
				jit_hoa_details_payload->>'SlsCode'::character varying,
				(value->>'HoaId')::bigint,
				floor((value->>'SanctionAmount')::numeric)::bigint,
				floor((value->>'CenterShareAmount')::numeric)::bigint,
				floor((value->>'StateShareAmount')::numeric)::bigint,
				floor((value->>'AvailableAmount')::numeric)::bigint,
				jit_hoa_details_payload->>'CssScmCode'::character varying,
				jit_hoa_details_payload->>'CssScmName'::character varying,
				(jit_hoa_details_payload->>'FinYear'::character varying)::smallint,
				floor((jit_hoa_details_payload->>'AmcAmt')::numeric)::bigint,
				floor((jit_hoa_details_payload->>'PscAmt')::numeric)::bigint,
				jit_hoa_details_payload->>'EfileNo'::character varying,
				jit_hoa_details_payload->>'Slsname'::character varying,
				jit_hoa_details_payload->>'ProposalNo'::character varying,
				jit_hoa_details_payload->>'ApprovalStatus'::character varying,
				jit_hoa_details_payload->>'MotherSanctionNo'::character varying,
				TO_TIMESTAMP(jit_hoa_details_payload->>'ApprovedDate', 'MM/DD/YYYY HH24:MI:SS'),
				jit_hoa_details_payload->>'SlsCode'::character varying,
				(jit_hoa_details_payload->>'SlsLimitDistributionId'::character varying)::bigint,
				jit_hoa_details_payload->>'GroupNSanctionId'::character varying,
				(value->>'HeadWiseSanctionId')::bigint
			from	
			jsonb_array_elements(jit_hoa_details_payload->'HeadWiseAllocation') AS value;
END;
$$;


ALTER PROCEDURE jit.insert_mother_sanction_allocation(IN jit_hoa_details_payload jsonb, IN _queue_name character varying) OWNER TO postgres;

--
-- TOC entry 448 (class 1255 OID 920276)
-- Name: insert_return_fto_details(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_return_fto_details(IN return_fto_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
v_queue_message jsonb;
BEGIN			
	INSERT INTO jit.jit_pullback_request(ddo_code,agency_id,ref_no,status,remarks,created_at)
	SELECT
		(return_fto_payload->>'DdoCode')::character varying,
		(return_fto_payload->>'AgencyId')::character varying,
		(return_fto_payload->>'RefNo')::character varying,
		(return_fto_payload->>'Status')::smallint,
		(return_fto_payload->>'Remarks')::character varying,
		(return_fto_payload->>'CreatedAt')::timestamp without time zone;
	
	---- Payload Create
	SELECT 
		json_build_object(
			'DdoCode', fto.ddo_code,
			'AgencyId', fto.agency_code,
			'RefNo', fto.ref_no,
			'Id', fto.id,
			'Status', (CASE
							WHEN fto.is_mapped = true OR fto.is_rejected = true OR fto.system_rejected = true
							THEN 2 ELSE 1
					   END),
			'Remarks', (CASE
							WHEN fto.is_mapped = true OR fto.is_rejected = true OR fto.system_rejected = true
							THEN 'Decline' ELSE 'Approve' 
					   	END)
			)
		INTO v_queue_message
		FROM 
			jit.tsa_exp_details AS fto
		WHERE 
			fto.ref_no = (return_fto_payload->>'RefNo')::character varying;
			
	----- Insert message queue table
		PERFORM message_queue.insert_message_queue(
			'pullback_fto_to_jit', v_queue_message
		);
		
		---- Update tsa_exp_details table
		
		UPDATE jit.tsa_exp_details 
		SET  system_rejected = true, 
			is_rejected = true, 
			reject_reason = CASE WHEN (is_mapped = false OR is_rejected = false) THEN 'Pullback Accepted'
								WHEN (is_mapped = true OR is_rejected = true) THEN 'Pullback Rejected'
							END, 
			rejected_at=now()
		WHERE ref_no = (return_fto_payload->>'RefNo')::character varying;

		-- PERFORM bantan.adjust_sanction_by_fto_ref((return_fto_payload->>'RefNo')::character varying);

END;	
$$;


ALTER PROCEDURE jit.insert_return_fto_details(IN return_fto_payload jsonb) OWNER TO postgres;

--
-- TOC entry 409 (class 1255 OID 920277)
-- Name: insert_return_fto_details(jsonb, character varying); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.insert_return_fto_details(IN return_fto_payload jsonb, IN _queue_name character varying, OUT updated_count integer)
    LANGUAGE plpgsql
    AS $$
DECLARE

BEGIN
INSERT INTO billing.rabbitmq_transaction(queue_name, data,created_at)
		SELECT
			_queue_name, return_fto_payload, now();
			
	INSERT INTO jit.jit_pullback_request(ddo_code,agency_id,ref_no,status,remarks,created_at)
	SELECT
		(return_fto_payload->>'DdoCode')::character varying,
		(return_fto_payload->>'AgencyId')::character varying,
		(return_fto_payload->>'RefNo')::character varying,
		(return_fto_payload->>'Status')::smallint,
		(return_fto_payload->>'Remarks')::character varying,
		(return_fto_payload->>'CreatedAt')::timestamp without time zone;
		
	UPDATE jit.tsa_exp_details 
	SET  system_rejected=true,is_rejected=true,reject_reason=(return_fto_payload->>'Remarks')::character varying,rejected_at=now()
	WHERE ref_no = (return_fto_payload->>'RefNo')::character varying and is_mapped=true;

	-- Get the number of rows updated
    GET DIAGNOSTICS updated_count = ROW_COUNT;
END;	
$$;


ALTER PROCEDURE jit.insert_return_fto_details(IN return_fto_payload jsonb, IN _queue_name character varying, OUT updated_count integer) OWNER TO postgres;

--
-- TOC entry 411 (class 1255 OID 920278)
-- Name: send_ddo_agency_mapping_response(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.send_ddo_agency_mapping_response(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
v_queue_message JSONB;
BEGIN
		UPDATE jit.ddo_agency_mapping_details
		SET response_msg = (in_payload->>'ResponseMsg')::character varying,
		action_type = (in_payload->>'ActionType')::bigint,
		action_taken_at = now()
		WHERE agency_code = (in_payload->>'AgencyCode')::character varying
		AND sls_code = (in_payload->>'SlsCode')::character varying
		AND ddo_code = (in_payload->>'DdoCode')::character varying;
		
		--- Insert into message queue table 

		SELECT 
		    json_build_object(
		        'AgencyCode', (in_payload->>'AgencyCode')::character varying,
		        'SlsCode', (in_payload->>'SlsCode')::character varying,
		        'DdoCode', (in_payload->>'DdoCode')::character varying,
		        'ResponseMsg', (in_payload->>'ResponseMsg')::character varying,
				'ActionType', CASE WHEN (in_payload->>'ActionType')::bigint = 1 THEN 'ACCEPTED'
							  WHEN (in_payload->>'ActionType')::bigint = 0 THEN 'REJECTED' END
		    )
		INTO v_queue_message;
		
		PERFORM message_queue.insert_message_queue(
		'ddo_agency_mapping_to_jit', v_queue_message
		);
		
END;
$$;


ALTER PROCEDURE jit.send_ddo_agency_mapping_response(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 470 (class 1255 OID 920279)
-- Name: send_rejected_fto(jsonb); Type: PROCEDURE; Schema: jit; Owner: postgres
--

CREATE OR REPLACE PROCEDURE jit.send_rejected_fto(IN in_payload jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
v_queue_message jsonb;
ref_count bigint;
_billno_ text;
BEGIN
	--- Insert into message queue table 

		SELECT 
		    json_agg(json_build_object(
		        'RefNo', unique_data.ref_no,
		        'Remarks', unique_data.remarks,
		        'PfmsErrorDesc', unique_data.error_details::jsonb,
		        'ObjectionDesc', unique_data.bill_objections::jsonb
		    ))
		INTO v_queue_message
		FROM (
		    SELECT DISTINCT ON (fto.ref_no) 
		        fto.ref_no, 
		        ((in_payload->>'Fto')::json->>'Remarks')::character varying AS remarks,
		        maps.error_details, 
		        obj.bill_objections
		    FROM 
		        jit.tsa_exp_details AS fto
		    LEFT JOIN
		        billing.ebill_jit_int_map AS maps 
		        ON fto.ref_no = maps.jit_ref_no
		    LEFT JOIN 
		        billing.returned_memo_generated_bill AS obj
		        ON obj.bill_id = maps.bill_id 
		    WHERE 
		        fto.ref_no = ((in_payload->>'Fto')::json->>'JitRefNo')::character varying
		) AS unique_data;
			
		PERFORM message_queue.insert_message_queue(
		'reject_fto_to_jit', v_queue_message
		);
		
	IF((in_payload->>'BillId')::bigint IS NOT NULL) THEN

	---- Update and insert 
		UPDATE billing.ebill_jit_int_map SET is_rejected = TRUE
		WHERE bill_id = (in_payload->>'BillId')::bigint 
		AND jit_ref_no = ((in_payload->>'Fto')::json->>'JitRefNo')::character varying;

		SELECT COUNT(1) INTO ref_count FROM billing.ebill_jit_int_map WHERE bill_id = (in_payload->>'BillId')::bigint and is_rejected = FALSE;
		
		UPDATE billing.bill_details
		SET is_cancelled = TRUE,
		status = CASE WHEN ref_count >= 1 THEN 105
				WHEN ref_count = 0 THEN 106 END
		WHERE bill_id = (in_payload->>'BillId')::bigint and status!=5
		RETURNING bill_no into _billno_;

		IF _billno_ is NULL THEN
			RAISE EXCEPTION 'Bill with Bill Number % cannot be rejected as it has already been forwarded to the treasury', _billno_;
		END IF;		
		
		UPDATE jit.tsa_exp_details
		SET is_rejected = TRUE, system_rejected=FALSE, rejected_at=now(), rejected_by = (in_payload->>'UserId')::bigint,
		reject_reason = ((in_payload->>'Fto')::json->>'Remarks')::character varying
		WHERE ref_no = ((in_payload->>'Fto')::json->>'JitRefNo')::character varying;
	ELSE
		UPDATE jit.tsa_exp_details
			SET is_rejected = TRUE, system_rejected=FALSE, rejected_at = now(),
			reject_reason = ((in_payload->>'Fto')::json->>'Remarks')::character varying,
			rejected_by = (in_payload->>'UserId')::bigint
			WHERE ref_no = ((in_payload->>'Fto')::json->>'JitRefNo')::character varying;
	END IF;
END;
$$;


ALTER PROCEDURE jit.send_rejected_fto(IN in_payload jsonb) OWNER TO postgres;

--
-- TOC entry 480 (class 1255 OID 920280)
-- Name: consume_logs_insert_trigger(); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.consume_logs_insert_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM message_queue.ensure_consume_logs_partition_for_date(NEW.created_at);
    RETURN NEW;
END;
$$;


ALTER FUNCTION message_queue.consume_logs_insert_trigger() OWNER TO postgres;

--
-- TOC entry 445 (class 1255 OID 920281)
-- Name: ensure_consume_logs_partition_for_date(date); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.ensure_consume_logs_partition_for_date(p_date date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    partition_name TEXT;
    start_date DATE := date_trunc('month', p_date);
    end_date DATE := (start_date + INTERVAL '1 month')::DATE;
    partition_table TEXT;
BEGIN
    partition_name := format('consume_logs_%s', to_char(start_date, 'YYYY_MM'));
    partition_table := format('message_queue.%I', partition_name);

    -- Check if partition already exists
    PERFORM 1
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'message_queue';

    IF NOT FOUND THEN
        -- Create the new partition
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS %I
            PARTITION OF message_queue.consume_logs
            FOR VALUES FROM (%L) TO (%L)',
            partition_table, start_date, end_date
        );

        -- Create indexes on the new partition
        EXECUTE format('CREATE INDEX IF NOT EXISTS ON %I (status)', partition_table);
        EXECUTE format('CREATE INDEX IF NOT EXISTS ON %I (queue_name)', partition_table);
        EXECUTE format('CREATE INDEX IF NOT EXISTS ON %I (created_at)', partition_table);
    END IF;
END;
$$;


ALTER FUNCTION message_queue.ensure_consume_logs_partition_for_date(p_date date) OWNER TO postgres;

--
-- TOC entry 479 (class 1255 OID 920282)
-- Name: fto_ack_send_to_jit(); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.fto_ack_send_to_jit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	consume_log_status text;
    consume_log_error_message text;
    ftoAckResult JSONB;
BEGIN
    IF NEW.queue_name = 'jit_ebilling_fto' THEN
        consume_log_status := NEW.status;
        consume_log_error_message := NEW.error_messages;

        SELECT json_build_object(
            'JitReferenceNo', (NEW.message_body::jsonb->>'JitReferenceNo')::character varying, 
            'Status', CASE 
                          WHEN consume_log_status = 'SUCCESS' THEN 1
                          ELSE 0 
                      END,
            'Message', COALESCE(consume_log_error_message, '')
        ) INTO ftoAckResult;

        PERFORM message_queue.insert_message_queue(
            'bill_jit_fto_ack', ftoAckResult
        );
    END IF;

    RETURN NEW; 
END;
$$;


ALTER FUNCTION message_queue.fto_ack_send_to_jit() OWNER TO postgres;

--
-- TOC entry 420 (class 1255 OID 920283)
-- Name: get_failed_transactions(character varying); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.get_failed_transactions(queue_name character varying) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_queue_message jsonb;
BEGIN

 -- Case 1: FTO Failed Transactions
    IF queue_name='wbjit_ebilling_fto' THEN 
    SELECT json_agg(
        json_build_object(
            'JitReferenceNo', (cl.message_body::jsonb)->>'JitReferenceNo',
            'AgencyCode', (cl.message_body::jsonb)->>'AgencyCode',
            'AgencyName', (cl.message_body::jsonb)->>'AgencyName',
            'SlsCode', (cl.message_body::jsonb)->>'SlsCode',
            'SchemeName', (cl.message_body::jsonb)->>'SchemeName',
            'DdoCode', (cl.message_body::jsonb)->>'DdoCode',
            'NetAmount', ((cl.message_body::jsonb)->>'NetAmount')::numeric,
            'GrossAmount', ((cl.message_body::jsonb)->>'GrossAmount')::numeric,
            'ReissueAmount', ((cl.message_body::jsonb)->>'ReissueAmount')::numeric,
            'HoaDetails', CONCAT_WS(
                '-',
                hoa.demand_no,
                hoa.major_head,
                hoa.submajor_head,
                hoa.minor_head,
                hoa.plan_status,
                hoa.scheme_head,
                hoa.detail_head,
                hoa.subdetail_head,
                hoa.voted_charged
            ),
            'HoaDescription', hoa.description,
			'ErrorMessage', cl.error_messages,
			'MessageBody', cl.message_body :: jsonb
        )
    )
    INTO v_queue_message
    FROM (
       SELECT DISTINCT ON ((message_body::jsonb)->>'JitReferenceNo')
        message_body,  
        error_messages 
    FROM message_queue.consume_logs
        WHERE consume_logs.queue_name = get_failed_transactions.queue_name
            AND status = 'FAILED' 
          AND (message_body::jsonb)->>'JitReferenceNo' IS NOT NULL
        ORDER BY (message_body::jsonb)->>'JitReferenceNo'
    ) cl
    JOIN master.active_hoa_mst hoa
      ON hoa.id = ((cl.message_body::jsonb)->>'HoaId')::bigint
	 WHERE NOT EXISTS (
    SELECT 1
    FROM jit.tsa_exp_details ts
    WHERE ts.ref_no = (cl.message_body::jsonb)->>'JitReferenceNo'
);

    -- Case 2: Allotment/Withdrawl Failed Transactions
   ELSIF queue_name IN('wbjit_ebilling_allotment','wbjit_ebilling_allotment_withdrawl') THEN
     SELECT json_agg(
        json_build_object(
            'Slscode', item ->> 'Slscode',
            'Agencycode', item ->> 'Agencycode',
            'Finyear', item ->> 'Finyear',
            'AgencyName', item ->> 'AgencyName',
            'SelfLimitAmt', (item ->> 'SelfLimitAmt')::numeric,
            'TotalAmount', (item ->> 'TotalAmount')::numeric,
            'TreasuryCode', item ->> 'TreasuryCode',
            'DdoCode', item ->> 'DdoCode',
            'SanctionDate', item ->> 'SanctionDate',
            'SanctionNo', item ->> 'SanctionNo',
			'IsWithdraw', item ->> 'IsWithdraw',
            'FromSanctionNo', item ->> 'FromSanctionNo',
            'HoaDetails', CONCAT_WS(
                '-',
                hoa.demand_no,
                hoa.major_head,
                hoa.submajor_head,
                hoa.minor_head,
                hoa.plan_status,
                hoa.scheme_head,
                hoa.detail_head,
                hoa.subdetail_head,
                hoa.voted_charged
            ),
            'HoaDescription', hoa.description,
            'ErrorMessage', sub.error_messages,
			'MessageBody', sub.message_body::jsonb
        )
    )
    INTO v_queue_message
    FROM (SELECT DISTINCT ON (item ->> 'Agencycode',item ->> 'DdoCode',item ->> 'SanctionNo') item, 
           consume_log_data.error_messages,
		   consume_log_data.message_body
    FROM (
        SELECT jsonb_array_elements(message_body::jsonb) AS item, consume_logs.error_messages,consume_logs.message_body
        FROM message_queue.consume_logs
        WHERE consume_logs.queue_name = get_failed_transactions.queue_name
           AND status = 'FAILED'
    ) consume_log_data )sub
    JOIN master.active_hoa_mst hoa
      ON hoa.id = (sub.item ->> 'HoaId')::bigint
	  WHERE (
        (get_failed_transactions.queue_name = 'wbjit_ebilling_allotment' AND NOT EXISTS (
            SELECT 1
            FROM jit.jit_allotment ja
            WHERE ja.ddo_code = sub.item ->> 'DdoCode'
              AND ja.sanction_no = sub.item ->> 'SanctionNo'
              AND ja.agency_code = sub.item ->> 'Agencycode'
        ))
        OR
        (get_failed_transactions.queue_name = 'wbjit_ebilling_allotment_withdrawl' AND NOT EXISTS (
            SELECT 1
            FROM jit.jit_withdrawl jaw
            WHERE jaw.ddo_code = sub.item ->> 'DdoCode'
              AND jaw.sanction_no = sub.item ->> 'SanctionNo'
              AND jaw.agency_code = sub.item ->> 'Agencycode'
        ))
    );
	  
 -- Case 3: Failed and Success Beneficiary Bills 
 ELSIF queue_name IN ('wbjit_cts_billing_failed_beneficiary', 'wbjit_cts_billing_success_beneficiary') THEN
        SELECT json_agg(
            jsonb_build_object(
                'BillId', (bill_data."BillId")::bigint,
                'DdoCode', bill_data."DdoCode",
                'FinancialYear', bill_data."FinancialYear",
                'ErrorMessage', bill_data.error_messages,
				'MessageBody', bill_data.message_body::jsonb,
                'PayeeCount', COALESCE(
    (
        SELECT COUNT(1)
        FROM jsonb_array_elements(
            CASE
                WHEN queue_name = 'wbjit_cts_billing_failed_beneficiary' THEN bill_data."FailedBenDetails"
                ELSE bill_data."BenDetails"
            END
        ) AS b
        WHERE 
            (queue_name = 'wbjit_cts_billing_failed_beneficiary' AND NOT EXISTS (
                SELECT 1
                FROM cts.failed_transaction_beneficiary ftb
                WHERE ftb.bill_id = (bill_data."BillId")::bigint
                  AND ftb.end_to_end_id = b->>'EndToEndId'
            ))
            OR
            (queue_name = 'wbjit_cts_billing_success_beneficiary' AND NOT EXISTS (
                SELECT 1
                FROM cts.success_transaction_beneficiary stb
                WHERE stb.bill_id = (bill_data."BillId")::bigint
                  AND stb.end_to_end_id = b->>'EndToEndId'
            ))
    ), 0
),

                'ReferenceNo', bill_details.reference_no::bigint
				
            ) ||
            CASE
                WHEN queue_name = 'wbjit_cts_billing_failed_beneficiary' THEN
                    jsonb_build_object(
                        'FailedBenDetails', (
                            SELECT json_agg(
                                json_build_object(
                                    'IsGST', b->>'IsGST',
                                    'AccountNo', b->>'AccountNo',
                                    'ChallanNo', b->>'ChallanNo',
                                    'PayeeName', b->>'PayeeName',
                                    'UtrNumber', b->>'UtrNumber',
                                    'AgencyCode', b->>'AgencyCode',
                                    'EndToEndId', b->>'EndToEndId',
                                    'ChallanDate', b->>'ChallanDate',
                                    'CancelCertNo', b->>'CancelCertNo',
                                    'FailedAmount', (b->>'FailedAmount')::numeric,
                                    'CancelCertDate', b->>'CancelCertDate',
                                    'JitReferenceNo', b->>'JitReferenceNo',
                                    'FailedReasonCode', b->>'FailedReasonCode',
                                    'FailedReasonDesc', b->>'FailedReasonDesc'
                                )
                            )
                            FROM jsonb_array_elements(bill_data."FailedBenDetails") AS b
                            WHERE NOT EXISTS (
                                SELECT 1
                                FROM cts.failed_transaction_beneficiary ftb
                                WHERE ftb.bill_id = (bill_data."BillId")::bigint
                                  AND ftb.end_to_end_id = b->>'EndToEndId'
                            )
                        )
                    )
                ELSE
                    jsonb_build_object(
                        'BenDetails', (
                            SELECT json_agg(
                                json_build_object(
                                    'IsGST', b->>'IsGST',
                                    'Amount', (b->>'Amount')::numeric,
                                    'AccountNo', b->>'AccountNo',
                                    'PayeeName', b->>'PayeeName',
                                    'UtrNumber', b->>'UtrNumber',
                                    'AgencyCode', b->>'AgencyCode',
                                    'EndToEndId', b->>'EndToEndId',
                                    'AccpDateTime', b->>'AccpDateTime',
                                    'BeneficiaryId', b->>'BeneficiaryId',
                                    'JitReferenceNo', b->>'JitReferenceNo'
                                )
                            )
                            FROM jsonb_array_elements(bill_data."BenDetails") AS b
                            WHERE NOT EXISTS (
                                SELECT 1
                                FROM cts.success_transaction_beneficiary stb
                                WHERE stb.bill_id = (bill_data."BillId")::bigint
                                  AND stb.end_to_end_id = b->>'EndToEndId'
                            )
                        )
                    )
            END
        )
        INTO v_queue_message
        FROM (
            SELECT DISTINCT ON ((bd."BillId")::bigint)
                   bd.*, cl.error_messages,cl.message_body
            FROM message_queue.consume_logs cl,
                 LATERAL json_to_record(cl.message_body::json) AS bd(
                    "BillId" bigint,
                    "DdoCode" TEXT,
                    "FinancialYear" TEXT,
                    "FailedBenDetails" JSONB,
                    "BenDetails" JSONB
                 )
            WHERE cl.queue_name = get_failed_transactions.queue_name
              AND cl.status = 'FAILED'
              AND (
                  (cl.queue_name = 'wbjit_cts_billing_failed_beneficiary' AND jsonb_typeof(bd."FailedBenDetails") = 'array') OR
                  (cl.queue_name = 'wbjit_cts_billing_success_beneficiary' AND jsonb_typeof(bd."BenDetails") = 'array')
              )
			  AND bd."BillId" IS NOT NULL

            ORDER BY (bd."BillId")::bigint
        ) AS bill_data
        JOIN billing.bill_details 
          ON (bill_data."BillId")::bigint = bill_details.bill_id
        WHERE (
            queue_name = 'wbjit_cts_billing_failed_beneficiary' AND EXISTS (
                SELECT 1
                FROM jsonb_array_elements(bill_data."FailedBenDetails") AS b
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM cts.failed_transaction_beneficiary ftb
                    WHERE ftb.bill_id = (bill_data."BillId")::numeric
                      AND ftb.end_to_end_id = b->>'EndToEndId'
                )
				LIMIT 1
            )
        ) OR (
            queue_name = 'wbjit_cts_billing_success_beneficiary' AND EXISTS (
                SELECT 1
                FROM jsonb_array_elements(bill_data."BenDetails") AS b
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM cts.success_transaction_beneficiary stb
                    WHERE stb.bill_id = (bill_data."BillId")::bigint
                      AND stb.end_to_end_id = b->>'EndToEndId'
                )
				LIMIT 1
            )
        );
		
 -- Case 4: Objected Bills Transactions
    ELSEIF queue_name='wbjit_cts_billing_objected_bill' THEN 
	    SELECT json_agg(
	        json_build_object(
	            'BillId', ((cl.message_body::jsonb)->>'BillId')::bigint,
	            'GeneratedAt', (cl.message_body::jsonb)->>'GeneratedAt',
	            'GeneratedBy', ((cl.message_body::jsonb)->>'GeneratedBy')::bigint,
	            'BillObjections', (cl.message_body::jsonb)->'BillObjections',
				'ErrorMessage', cl.error_messages,
				'MessageBody', cl.message_body::jsonb
	        )
	    )
	    INTO v_queue_message
	    FROM (
	       SELECT DISTINCT ON ((message_body::jsonb)->>'BillId')
	        message_body,  
	        error_messages 
	    FROM message_queue.consume_logs
	        WHERE consume_logs.queue_name = get_failed_transactions.queue_name
	            AND status = 'FAILED' 
	          AND (message_body::jsonb)->>'BillId' IS NOT NULL
	        ORDER BY (message_body::jsonb)->>'BillId'
	    ) cl
		WHERE NOT EXISTS (
		    SELECT 1
		    FROM billing.returned_memo_generated_bill obj
		    WHERE obj.bill_id = ((cl.message_body::jsonb)->>'BillId')::bigint
		);

 -- Case 5: PFMS Failed Bills Transactions
    ELSEIF queue_name = 'wbjit_cts_billing_pfms_failed' THEN
    SELECT json_agg(
        json_build_object(
            'FileName', result."FileName",
            'BillId', result."BillId",
            'ErrorMessage', result."ErrorMessage",
            'MessageBody', result."MessageBody",
            'ErrorDetails', result."ErrorDetails"
        )
    )
    INTO v_queue_message
    FROM (
        SELECT DISTINCT ON (msg_data.bill_id)
            msg_data.file_name AS "FileName",
            msg_data.bill_id AS "BillId",
            msg_data.error_message AS "ErrorMessage",
            msg_data.message_body AS "MessageBody",
            CASE 
                WHEN EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(msg_data.message_body->'ErrorDetails') AS err,
                         jsonb_array_elements(err->'PayeeDetails') AS payee
                    WHERE (payee->>'BillId')::bigint = msg_data.bill_id
                )
                THEN (
                    SELECT jsonb_agg(err_entry)
                    FROM jsonb_array_elements(msg_data.message_body->'ErrorDetails') AS err_entry
                )
                ELSE (
                    SELECT jsonb_agg(err_entry)
                    FROM jsonb_array_elements(msg_data.message_body->'ErrorDetails') AS err_entry
                    WHERE err_entry->'PayeeDetails' = '[]'::jsonb
                )
            END AS "ErrorDetails"
        FROM (
            SELECT
                cl.message_body::jsonb AS message_body,
                cl.error_messages AS error_message,
                ((cl.message_body::jsonb)->'FileStatusDetails'->>'FileName')::text AS file_name,
                jsonb_array_elements_text((cl.message_body::jsonb)->'FileStatusDetails'->'BillIds')::bigint AS bill_id
            FROM message_queue.consume_logs cl
            WHERE cl.queue_name = 'wbjit_cts_billing_pfms_failed'
              AND cl.status = 'FAILED'
              AND (cl.message_body::jsonb)->'FileStatusDetails'->>'BillIds' IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM billing.ebill_jit_int_map maps
                  WHERE maps.bill_id = ANY (
                      SELECT jsonb_array_elements_text(
                          (cl.message_body::jsonb)->'FileStatusDetails'->'BillIds'
                      )::bigint
                  )
                  AND maps.file_name = ((cl.message_body::jsonb)->'FileStatusDetails'->>'FileName')::text
              )
        ) msg_data
    ) result;

 -- Case 6: Objected Bills Transactions
    ELSEIF queue_name='wbjit_cts_billing_voucher' THEN 
	    SELECT json_agg(
	        json_build_object(
	            'BillId', ((cl.message_body::jsonb)->>'BillId')::bigint,
	            'VoucherNo', ((cl.message_body::jsonb)->>'VoucherNo')::int,
	            'MajorHead', (cl.message_body::jsonb)->'MajorHead',
	            'VoucherDate', ((cl.message_body::jsonb)->>'VoucherDate')::date,
				'VoucherAmount', ((cl.message_body::jsonb)->'VoucherAmount')::bigint,
				'ErrorMessage', cl.error_messages,
				'MessageBody', cl.message_body::jsonb
	        )
	    )
	    INTO v_queue_message
	    FROM (
	       SELECT DISTINCT ON ((message_body::jsonb)->>'BillId')
	        message_body,  
	        error_messages 
	    FROM message_queue.consume_logs
	        WHERE consume_logs.queue_name = get_failed_transactions.queue_name
	            AND status = 'FAILED' 
	          AND (message_body::jsonb)->>'BillId' IS NOT NULL
	        ORDER BY (message_body::jsonb)->>'BillId'
	    ) cl
		WHERE NOT EXISTS (
		    SELECT 1
		    FROM cts.voucher v
		    WHERE v.bill_id = ((cl.message_body::jsonb)->>'BillId')::bigint
		);
   ELSE
        -- Handle cases where the queue_name is not recognized or return an empty array
        RETURN '[]'::jsonb;
    END IF;
	
    RETURN COALESCE(v_queue_message, '[]'::jsonb);
END;
$$;


ALTER FUNCTION message_queue.get_failed_transactions(queue_name character varying) OWNER TO postgres;

--
-- TOC entry 455 (class 1255 OID 920285)
-- Name: get_queue_name_by_identifier(character varying); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.get_queue_name_by_identifier(in_identifier character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN (SELECT queue_name FROM message_queue.queues_master where identifier=in_identifier);
END;
$$;


ALTER FUNCTION message_queue.get_queue_name_by_identifier(in_identifier character varying) OWNER TO postgres;

--
-- TOC entry 454 (class 1255 OID 920286)
-- Name: insert_message_queue(character varying, jsonb); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.insert_message_queue(p_queue_identifier_name character varying, p_message jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_message_queue_uuid uuid := gen_random_uuid();
	v_queue_name character varying;
	v_message JSONB;
BEGIN
	v_queue_name := message_queue.get_queue_name_by_identifier(p_queue_identifier_name);
	
  --   INSERT INTO message_queue.message_queues (unique_id, queue_name, message_body)
  --   VALUES (
  --       v_message_queue_uuid,
  --       v_queue_name,
  --       -- v_message
		-- p_message
  --   );
  
   -- If it's a JSON array
    IF jsonb_typeof(p_message) = 'array' THEN
       INSERT INTO message_queue.message_queues (unique_id, queue_name, message_body)
	    VALUES (
	        v_message_queue_uuid,
	        v_queue_name,
	        (
	            SELECT jsonb_agg(
	                jsonb_set(elem, '{queueUniqueId}', to_jsonb(v_message_queue_uuid::text), true)
	            )
	            FROM jsonb_array_elements(p_message) AS elem
	        )
	    );

    -- If it's a single JSON object
    ELSIF jsonb_typeof(p_message) = 'object' THEN
        INSERT INTO message_queue.message_queues (unique_id, queue_name, message_body)
        VALUES (
            v_message_queue_uuid,
            v_queue_name,
            jsonb_set(p_message, '{queueUniqueId}', to_jsonb(v_message_queue_uuid::text), true)
        );
	ELSE
        RAISE EXCEPTION 'Invalid JSON type: %, expected object or array', jsonb_typeof(p_message);
    END IF;
END;
$$;


ALTER FUNCTION message_queue.insert_message_queue(p_queue_identifier_name character varying, p_message jsonb) OWNER TO postgres;

--
-- TOC entry 464 (class 1255 OID 920287)
-- Name: insert_message_queue_15092025(character varying, jsonb); Type: FUNCTION; Schema: message_queue; Owner: postgres
--

CREATE OR REPLACE FUNCTION  message_queue.insert_message_queue_15092025(p_queue_identifier_name character varying, p_message jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_message_queue_uuid uuid := gen_random_uuid();
	v_queue_name character varying;
	v_message JSONB;
BEGIN
	v_queue_name := message_queue.get_queue_name_by_identifier(p_queue_identifier_name);
	
    INSERT INTO message_queue.message_queues (unique_id, queue_name, message_body)
    VALUES (
        v_message_queue_uuid,
        v_queue_name,
        -- v_message
		p_message
    );
END;
$$;


ALTER FUNCTION message_queue.insert_message_queue_15092025(p_queue_identifier_name character varying, p_message jsonb) OWNER TO postgres;

--
-- TOC entry 226 (class 1259 OID 920288)
-- Name: ddo_allotment_sequence; Type: SEQUENCE; Schema: bantan; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS bantan.ddo_allotment_sequence
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE bantan.ddo_allotment_sequence OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 227 (class 1259 OID 920289)
-- Name: ddo_allotment_transactions; Type: TABLE; Schema: bantan; Owner: postgres
--

CREATE TABLE IF NOT EXISTS bantan.ddo_allotment_transactions (
    allotment_id bigint DEFAULT nextval('bantan.ddo_allotment_sequence'::regclass) NOT NULL,
    transaction_id bigint,
    sanction_id bigint,
    memo_number character varying,
    memo_date date,
    from_allotment_id bigint,
    financial_year smallint NOT NULL,
    sender_user_type smallint,
    sender_sao_ddo_code character(200),
    receiver_user_type smallint,
    receiver_sao_ddo_code character(12) NOT NULL,
    dept_code character(2),
    demand_no character(2),
    major_head character(4),
    submajor_head character(2),
    minor_head character(3),
    plan_status character(2),
    scheme_head character(3),
    detail_head character(2),
    subdetail_head character(2),
    voted_charged character(1),
    budget_alloted_amount bigint DEFAULT 0,
    reappropriated_amount bigint DEFAULT 0,
    augment_amount bigint DEFAULT 0,
    surrender_amount bigint DEFAULT 0,
    revised_amount bigint DEFAULT 0,
    ceiling_amount bigint DEFAULT 0 NOT NULL,
    provisional_released_amount bigint DEFAULT 0,
    actual_released_amount numeric(10,0) DEFAULT 0,
    map_type smallint,
    sanction_type smallint,
    status smallint,
    allotment_date date,
    remarks character varying(200),
    created_by_userid bigint,
    created_at timestamp without time zone,
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    uo_id bigint,
    active_hoa_id bigint NOT NULL,
    treasury_code character(3),
    grant_in_aid_type smallint,
    is_send boolean DEFAULT false NOT NULL
);


ALTER TABLE bantan.ddo_allotment_transactions OWNER TO postgres;

--
-- TOC entry 6141 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN ddo_allotment_transactions.sender_user_type; Type: COMMENT; Schema: bantan; Owner: postgres
--

COMMENT ON COLUMN bantan.ddo_allotment_transactions.sender_user_type IS '1 - SAO, 2 - DDO, 3 - JIT';


--
-- TOC entry 228 (class 1259 OID 920304)
-- Name: ddo_wallet; Type: TABLE; Schema: bantan; Owner: postgres
--

CREATE TABLE IF NOT EXISTS bantan.ddo_wallet (
    id bigint NOT NULL,
    sao_ddo_code character(12) NOT NULL,
    dept_code character(2),
    demand_no character(2),
    major_head character(4),
    submajor_head character(2),
    minor_head character(3),
    plan_status character(2),
    scheme_head character(3),
    detail_head character(2),
    subdetail_head character(2),
    voted_charged character(1),
    budget_alloted_amount bigint DEFAULT 0,
    reappropriated_amount bigint DEFAULT 0,
    augment_amount bigint DEFAULT 0,
    surrender_amount bigint DEFAULT 0,
    revised_amount bigint DEFAULT 0,
    ceiling_amount bigint DEFAULT 0 NOT NULL,
    provisional_released_amount bigint DEFAULT 0,
    actual_released_amount bigint DEFAULT 0,
    created_at timestamp without time zone,
    created_by integer,
    updated_at timestamp without time zone,
    updated_by integer,
    active_hoa_id bigint NOT NULL,
    treasury_code character(3),
    financial_year smallint NOT NULL,
    is_active boolean DEFAULT false
);


ALTER TABLE bantan.ddo_wallet OWNER TO postgres;

--
-- TOC entry 229 (class 1259 OID 920316)
-- Name: ddo_wallet_id_seq; Type: SEQUENCE; Schema: bantan; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS bantan.ddo_wallet_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE bantan.ddo_wallet_id_seq OWNER TO postgres;

--
-- TOC entry 6142 (class 0 OID 0)
-- Dependencies: 229
-- Name: ddo_wallet_id_seq; Type: SEQUENCE OWNED BY; Schema: bantan; Owner: postgres
--

ALTER SEQUENCE bantan.ddo_wallet_id_seq OWNED BY bantan.ddo_wallet.id;


--
-- TOC entry 230 (class 1259 OID 920317)
-- Name: bill_details; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_details (
    bill_id bigint NOT NULL,
    bill_no character(15),
    bill_date date NOT NULL,
    bill_mode smallint DEFAULT 0,
    reference_no character(20),
    tr_master_id smallint NOT NULL,
    payment_mode smallint NOT NULL,
    financial_year smallint NOT NULL,
    demand character(2),
    major_head character(4),
    sub_major_head character(2),
    minor_head character(3),
    plan_status character(2),
    scheme_head character(3),
    detail_head character(2),
    voted_charged character(1),
    gross_amount bigint DEFAULT 0,
    net_amount bigint DEFAULT 0,
    bt_amount bigint DEFAULT 0,
    sanction_no character varying(25),
    sanction_amt bigint DEFAULT 0,
    sanction_date date,
    sanction_by character varying(100),
    remarks character varying(100),
    ddo_code character(9),
    is_extended_part_filled boolean DEFAULT false NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    treasury_code character(3),
    is_gem boolean DEFAULT false NOT NULL,
    status smallint NOT NULL,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    form_version smallint DEFAULT 1 NOT NULL,
    form_revision_no smallint DEFAULT 1 NOT NULL,
    sna_grant_type integer,
    css_ben_type integer,
    treasury_bt bigint DEFAULT 0,
    ag_bt bigint DEFAULT 0,
    bill_components jsonb,
    aafs_project_id integer,
    scheme_code character varying(50),
    scheme_name character varying(300),
    bill_type character varying(15),
    is_cancelled boolean DEFAULT false,
    is_gst boolean DEFAULT false,
    gst_amount bigint DEFAULT 0,
    tr_components jsonb,
    is_regenerated boolean DEFAULT false,
    service_provider_id integer,
    payee_count smallint,
    is_reissued boolean DEFAULT false,
    is_cpin_regenerated boolean DEFAULT false
);


ALTER TABLE billing.bill_details OWNER TO postgres;

--
-- TOC entry 231 (class 1259 OID 920341)
-- Name: jit_ecs_additional; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.jit_ecs_additional (
    id bigint NOT NULL,
    ecs_id bigint NOT NULL,
    bill_id bigint NOT NULL,
    beneficiary_id character varying(100),
    aadhar character varying(12),
    gross_amount bigint,
    net_amount bigint,
    reissue_amount bigint,
    top_up bigint,
    end_to_end_id character varying(29),
    agency_code character varying,
    agency_name character varying(300),
    districtcodelgd character(3),
    jit_reference_no character varying,
    is_cancelled boolean,
    financial_year smallint,
    state_code_lgd character(2),
    urban_rural_flag character(1) DEFAULT 'N'::bpchar NOT NULL,
    block_lgd character varying(10),
    panchayat_lgd character varying(10),
    village_lgd character varying(10),
    tehsil_lgd character varying(10),
    town_lgd character varying(10),
    ward_lgd character varying(10),
    CONSTRAINT chk_urban_rural_mandatory_cols CHECK ((((urban_rural_flag = 'R'::bpchar) AND (block_lgd IS NOT NULL) AND (panchayat_lgd IS NOT NULL) AND (village_lgd IS NOT NULL) AND (state_code_lgd IS NOT NULL) AND (districtcodelgd IS NOT NULL)) OR ((urban_rural_flag = 'U'::bpchar) AND (tehsil_lgd IS NOT NULL) AND (town_lgd IS NOT NULL) AND (ward_lgd IS NOT NULL) AND (state_code_lgd IS NOT NULL) AND (districtcodelgd IS NOT NULL)) OR (urban_rural_flag = 'N'::bpchar)))
);


ALTER TABLE billing.jit_ecs_additional OWNER TO postgres;

--
-- TOC entry 6143 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.urban_rural_flag; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.urban_rural_flag IS 'Urban/Rural/NA flag: U=Urban, R=Rural, N=Not Applicable';


--
-- TOC entry 6144 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.block_lgd; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.block_lgd IS 'LGD code for block';


--
-- TOC entry 6145 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.panchayat_lgd; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.panchayat_lgd IS 'LGD code for panchayat';


--
-- TOC entry 6146 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.village_lgd; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.village_lgd IS 'LGD code for village';


--
-- TOC entry 6147 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.tehsil_lgd; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.tehsil_lgd IS 'LGD code for tehsil';


--
-- TOC entry 6148 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.town_lgd; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.town_lgd IS 'LGD code for town';


--
-- TOC entry 6149 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN jit_ecs_additional.ward_lgd; Type: COMMENT; Schema: billing; Owner: postgres
--

COMMENT ON COLUMN billing.jit_ecs_additional.ward_lgd IS 'LGD code for ward';


--
-- TOC entry 232 (class 1259 OID 920348)
-- Name: agency_details_view; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE OR REPLACE VIEW billing.agency_details_view AS
 WITH bill_info AS (
         SELECT ecs.bill_id,
            ecs.agency_code,
            ecs.agency_name,
            bd.ddo_code
           FROM (billing.jit_ecs_additional ecs
             JOIN billing.bill_details bd ON ((bd.bill_id = ecs.bill_id)))
          GROUP BY ecs.bill_id, ecs.agency_code, ecs.agency_name, bd.ddo_code
        )
 SELECT DISTINCT agency_code,
    agency_name,
    ddo_code
   FROM bill_info bi;


ALTER VIEW billing.agency_details_view OWNER TO postgres;

--
-- TOC entry 233 (class 1259 OID 920353)
-- Name: bill_btdetail; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_btdetail (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    bt_serial integer,
    bt_type smallint,
    amount bigint,
    ddo_code character(9),
    treasury_code character(3),
    status smallint,
    created_by bigint,
    created_at timestamp without time zone,
    updated_by bigint,
    updated_at timestamp without time zone,
    financial_year smallint NOT NULL,
    payee_id character varying(20)
);


ALTER TABLE billing.bill_btdetail OWNER TO postgres;

--
-- TOC entry 234 (class 1259 OID 920356)
-- Name: bill_btdetail_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.bill_btdetail_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.bill_btdetail_id_seq OWNER TO postgres;

--
-- TOC entry 6150 (class 0 OID 0)
-- Dependencies: 234
-- Name: bill_btdetail_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.bill_btdetail_id_seq OWNED BY billing.bill_btdetail.id;


--
-- TOC entry 235 (class 1259 OID 920357)
-- Name: bill_gst; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_gst (
    id bigint NOT NULL,
    bill_id bigint,
    cpin_id bigint,
    ddo_gstn character varying(255),
    ddo_code character(9),
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    tr_id smallint,
    is_deleted boolean DEFAULT false,
    financial_year smallint
);


ALTER TABLE billing.bill_gst OWNER TO postgres;

--
-- TOC entry 236 (class 1259 OID 920362)
-- Name: bill_cpin_mapping_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.bill_cpin_mapping_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.bill_cpin_mapping_id_seq OWNER TO postgres;

--
-- TOC entry 6151 (class 0 OID 0)
-- Dependencies: 236
-- Name: bill_cpin_mapping_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.bill_cpin_mapping_id_seq OWNED BY billing.bill_gst.id;


--
-- TOC entry 237 (class 1259 OID 920363)
-- Name: bill_details_bill_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.bill_details_bill_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.bill_details_bill_id_seq OWNER TO postgres;

--
-- TOC entry 6152 (class 0 OID 0)
-- Dependencies: 237
-- Name: bill_details_bill_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.bill_details_bill_id_seq OWNED BY billing.bill_details.bill_id;


--
-- TOC entry 238 (class 1259 OID 920364)
-- Name: bill_ecs_neft_details; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_ecs_neft_details (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    payee_name character varying(100),
    beneficiary_id character varying(100),
    payee_type character(2),
    pan_no character(10),
    contact_number character(15),
    beneficiary_type character(2),
    address character varying(200),
    email character varying(60),
    ifsc_code character(11),
    account_type smallint,
    bank_account_number character(20),
    bank_name character varying(50),
    amount bigint,
    status smallint DEFAULT 1,
    is_active smallint DEFAULT 1,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    e_pradan_id bigint,
    financial_year smallint,
    is_cancelled boolean DEFAULT false,
    is_gst boolean DEFAULT false
);


ALTER TABLE billing.bill_ecs_neft_details OWNER TO postgres;

--
-- TOC entry 239 (class 1259 OID 920374)
-- Name: bill_jit_components; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_jit_components (
    bill_id bigint,
    payee_id character varying(50),
    componentcode character varying(50),
    componentname character varying(300),
    amount bigint,
    slscode character varying(100),
    id bigint NOT NULL,
    financial_year smallint
);


ALTER TABLE billing.bill_jit_components OWNER TO postgres;

--
-- TOC entry 240 (class 1259 OID 920379)
-- Name: bill_jit_components_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.bill_jit_components_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.bill_jit_components_id_seq OWNER TO postgres;

--
-- TOC entry 6153 (class 0 OID 0)
-- Dependencies: 240
-- Name: bill_jit_components_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.bill_jit_components_id_seq OWNED BY billing.bill_jit_components.id;


--
-- TOC entry 241 (class 1259 OID 920380)
-- Name: bill_status_info; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_status_info (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    status_id smallint NOT NULL,
    created_at timestamp without time zone,
    created_by bigint,
    send_to_jit boolean DEFAULT false NOT NULL
);


ALTER TABLE billing.bill_status_info OWNER TO postgres;

--
-- TOC entry 242 (class 1259 OID 920384)
-- Name: bill_status_info_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.bill_status_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.bill_status_info_id_seq OWNER TO postgres;

--
-- TOC entry 6154 (class 0 OID 0)
-- Dependencies: 242
-- Name: bill_status_info_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.bill_status_info_id_seq OWNED BY billing.bill_status_info.id;


--
-- TOC entry 243 (class 1259 OID 920385)
-- Name: bill_subdetail_info; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.bill_subdetail_info (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    active_hoa_id bigint NOT NULL,
    amount bigint,
    status smallint,
    created_by_userid bigint,
    created_at timestamp without time zone,
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    financial_year smallint NOT NULL,
    ddo_code character(9),
    treasury_code character(3)
);


ALTER TABLE billing.bill_subdetail_info OWNER TO postgres;

--
-- TOC entry 244 (class 1259 OID 920388)
-- Name: bill_subdetail_info_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.bill_subdetail_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.bill_subdetail_info_id_seq OWNER TO postgres;

--
-- TOC entry 6155 (class 0 OID 0)
-- Dependencies: 244
-- Name: bill_subdetail_info_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.bill_subdetail_info_id_seq OWNED BY billing.bill_subdetail_info.id;


--
-- TOC entry 245 (class 1259 OID 920389)
-- Name: billing_pfms_file_status_details; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.billing_pfms_file_status_details (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    file_name character varying(32) NOT NULL,
    status_received_at timestamp without time zone NOT NULL,
    payment_status character varying,
    sanction_status character varying,
    created_at timestamp without time zone DEFAULT now(),
    send_to_jit boolean DEFAULT false
);


ALTER TABLE billing.billing_pfms_file_status_details OWNER TO postgres;

--
-- TOC entry 246 (class 1259 OID 920396)
-- Name: billing_pfms_file_status_details_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.billing_pfms_file_status_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.billing_pfms_file_status_details_id_seq OWNER TO postgres;

--
-- TOC entry 6156 (class 0 OID 0)
-- Dependencies: 246
-- Name: billing_pfms_file_status_details_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.billing_pfms_file_status_details_id_seq OWNED BY billing.billing_pfms_file_status_details.id;


--
-- TOC entry 247 (class 1259 OID 920397)
-- Name: ddo_allotment_booked_bill; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.ddo_allotment_booked_bill (
    id integer NOT NULL,
    bill_id bigint NOT NULL,
    allotment_id bigint,
    amount bigint NOT NULL,
    ddo_user_id integer,
    ddo_code character(9),
    treasury_code character(3),
    created_by_userid bigint,
    created_at timestamp without time zone,
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    financial_year smallint NOT NULL,
    active_hoa_id bigint NOT NULL,
    allotment_received bigint DEFAULT 0,
    progressive_expenses bigint DEFAULT 0,
    is_reissued boolean DEFAULT false,
    is_duplicate boolean DEFAULT false
);


ALTER TABLE billing.ddo_allotment_booked_bill OWNER TO postgres;

--
-- TOC entry 248 (class 1259 OID 920404)
-- Name: ddo_allotment_booked_bill_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.ddo_allotment_booked_bill_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.ddo_allotment_booked_bill_id_seq OWNER TO postgres;

--
-- TOC entry 6157 (class 0 OID 0)
-- Dependencies: 248
-- Name: ddo_allotment_booked_bill_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.ddo_allotment_booked_bill_id_seq OWNED BY billing.ddo_allotment_booked_bill.id;


--
-- TOC entry 249 (class 1259 OID 920405)
-- Name: department_details_view; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE OR REPLACE VIEW billing.department_details_view AS
SELECT
    NULL::character(2) AS demand_code,
    NULL::character varying(100) AS department_name,
    NULL::character(9) AS ddo_code;


ALTER VIEW billing.department_details_view OWNER TO postgres;

--
-- TOC entry 250 (class 1259 OID 920409)
-- Name: ebill_jit_int_map_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.ebill_jit_int_map_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.ebill_jit_int_map_id_seq OWNER TO postgres;

--
-- TOC entry 251 (class 1259 OID 920410)
-- Name: ebill_jit_int_map; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.ebill_jit_int_map (
    id bigint DEFAULT nextval('billing.ebill_jit_int_map_id_seq'::regclass) NOT NULL,
    ebill_ref_no character(20) NOT NULL,
    jit_ref_no character varying(50) NOT NULL,
    is_active boolean DEFAULT true,
    error_details jsonb,
    is_rejected boolean DEFAULT false,
    bill_id bigint NOT NULL,
    file_name character varying(32),
    created_at timestamp without time zone DEFAULT now(),
    financial_year smallint
);


ALTER TABLE billing.ebill_jit_int_map OWNER TO postgres;

--
-- TOC entry 252 (class 1259 OID 920419)
-- Name: ebill_jit_int_map_01102025; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.ebill_jit_int_map_01102025 (
    id bigint,
    ebill_ref_no character(20),
    jit_ref_no character varying(50),
    is_active boolean,
    error_details jsonb,
    is_rejected boolean,
    bill_id bigint,
    file_name character varying(32),
    created_at timestamp without time zone,
    financial_year smallint
);


ALTER TABLE billing.ebill_jit_int_map_01102025 OWNER TO postgres;

--
-- TOC entry 253 (class 1259 OID 920424)
-- Name: ebill_jit_int_map_bk_24092025; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.ebill_jit_int_map_bk_24092025 (
    id bigint,
    ebill_ref_no character(20),
    jit_ref_no character varying(50),
    is_active boolean,
    error_details jsonb,
    is_rejected boolean,
    bill_id bigint,
    file_name character varying(32),
    created_at timestamp without time zone,
    financial_year smallint
);


ALTER TABLE billing.ebill_jit_int_map_bk_24092025 OWNER TO postgres;

--
-- TOC entry 254 (class 1259 OID 920429)
-- Name: ecs_neft_details_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.ecs_neft_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.ecs_neft_details_id_seq OWNER TO postgres;

--
-- TOC entry 6158 (class 0 OID 0)
-- Dependencies: 254
-- Name: ecs_neft_details_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.ecs_neft_details_id_seq OWNED BY billing.bill_ecs_neft_details.id;


--
-- TOC entry 255 (class 1259 OID 920430)
-- Name: active_hoa_mst; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.active_hoa_mst (
    id bigint NOT NULL,
    dept_code character(2),
    demand_no character(2),
    major_head character(4),
    submajor_head character(2),
    minor_head character(3),
    plan_status character(2),
    scheme_head character(3),
    detail_head character(2),
    subdetail_head character(2),
    voted_charged character(1),
    description character varying,
    isactive boolean,
    activated_by bigint,
    financial_year smallint,
    is_aafs boolean NOT NULL,
    is_sna boolean NOT NULL,
    is_salary_component boolean,
    category_code character varying
);


ALTER TABLE master.active_hoa_mst OWNER TO postgres;

--
-- TOC entry 256 (class 1259 OID 920435)
-- Name: hoa_details_view; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE OR REPLACE VIEW billing.hoa_details_view AS
 WITH bill_info AS (
         SELECT billsub.bill_id,
            billsub.active_hoa_id,
            concat(hoa.demand_no, '-', hoa.major_head, '-', hoa.submajor_head, '-', hoa.minor_head, '-', hoa.scheme_head, '-', hoa.detail_head, '-', hoa.subdetail_head, '-', hoa.voted_charged) AS hoa
           FROM (billing.bill_subdetail_info billsub
             JOIN master.active_hoa_mst hoa ON ((hoa.id = billsub.active_hoa_id)))
          GROUP BY billsub.bill_id, billsub.active_hoa_id, hoa.demand_no, hoa.major_head, hoa.submajor_head, hoa.minor_head, hoa.scheme_head, hoa.detail_head, hoa.subdetail_head, hoa.voted_charged
        )
 SELECT DISTINCT active_hoa_id,
    hoa
   FROM bill_info bi
  ORDER BY active_hoa_id;


ALTER VIEW billing.hoa_details_view OWNER TO postgres;

--
-- TOC entry 257 (class 1259 OID 920440)
-- Name: jit_ben_agency_map; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.jit_ben_agency_map (
    bill_id bigint,
    payee_id character varying(50),
    agencycode character varying(50),
    agencyname character varying(300)
);


ALTER TABLE billing.jit_ben_agency_map OWNER TO postgres;

--
-- TOC entry 258 (class 1259 OID 920443)
-- Name: jit_ecs_additional_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.jit_ecs_additional_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.jit_ecs_additional_id_seq OWNER TO postgres;

--
-- TOC entry 6159 (class 0 OID 0)
-- Dependencies: 258
-- Name: jit_ecs_additional_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.jit_ecs_additional_id_seq OWNED BY billing.jit_ecs_additional.id;


--
-- TOC entry 259 (class 1259 OID 920444)
-- Name: jit_fto_voucher; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.jit_fto_voucher (
    id bigint NOT NULL,
    bill_id bigint,
    voucher_no character varying(150),
    amount bigint,
    voucher_date date,
    desc_charges character varying(150),
    authority character varying(150)
);


ALTER TABLE billing.jit_fto_voucher OWNER TO postgres;

--
-- TOC entry 260 (class 1259 OID 920447)
-- Name: jit_fto_voucher_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.jit_fto_voucher_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.jit_fto_voucher_id_seq OWNER TO postgres;

--
-- TOC entry 6160 (class 0 OID 0)
-- Dependencies: 260
-- Name: jit_fto_voucher_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.jit_fto_voucher_id_seq OWNED BY billing.jit_fto_voucher.id;


--
-- TOC entry 261 (class 1259 OID 920448)
-- Name: notification_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.notification_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 2147483647
    CACHE 1;


ALTER SEQUENCE billing.notification_id_seq OWNER TO postgres;

--
-- TOC entry 262 (class 1259 OID 920449)
-- Name: notification; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.notification (
    id bigint DEFAULT nextval('billing.notification_id_seq'::regclass) NOT NULL,
    user_id bigint,
    user_role character varying,
    ddo_code character varying,
    message text,
    created_at timestamp without time zone DEFAULT now(),
    reference_id character varying(100),
    notification_type character varying,
    is_read_approver boolean DEFAULT false,
    is_read_operator boolean DEFAULT false
);


ALTER TABLE billing.notification OWNER TO postgres;

--
-- TOC entry 263 (class 1259 OID 920458)
-- Name: returned_memo_generated_bill; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.returned_memo_generated_bill (
    bill_objections jsonb,
    generated_at timestamp without time zone NOT NULL,
    generated_by bigint NOT NULL,
    id bigint NOT NULL,
    bill_id bigint NOT NULL
);


ALTER TABLE billing.returned_memo_generated_bill OWNER TO postgres;

--
-- TOC entry 264 (class 1259 OID 920463)
-- Name: returned_memo_generated_bill_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.returned_memo_generated_bill_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.returned_memo_generated_bill_id_seq OWNER TO postgres;

--
-- TOC entry 6161 (class 0 OID 0)
-- Dependencies: 264
-- Name: returned_memo_generated_bill_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.returned_memo_generated_bill_id_seq OWNED BY billing.returned_memo_generated_bill.id;


--
-- TOC entry 265 (class 1259 OID 920464)
-- Name: slscode_details_view; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE OR REPLACE VIEW billing.slscode_details_view AS
 WITH bill_info AS (
         SELECT bd.bill_id,
            bd.scheme_code,
            bd.scheme_name,
            bd.ddo_code
           FROM billing.bill_details bd
          GROUP BY bd.bill_id, bd.scheme_code, bd.scheme_name, bd.ddo_code
        )
 SELECT DISTINCT scheme_code,
    scheme_name,
    ddo_code
   FROM bill_info bi;


ALTER VIEW billing.slscode_details_view OWNER TO postgres;

--
-- TOC entry 266 (class 1259 OID 920469)
-- Name: sys_generated_bill_no_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.sys_generated_bill_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 99999999
    CACHE 1;


ALTER SEQUENCE billing.sys_generated_bill_no_seq OWNER TO postgres;

--
-- TOC entry 267 (class 1259 OID 920470)
-- Name: tr_detail; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.tr_detail (
    id integer NOT NULL,
    bill_id bigint NOT NULL,
    bill_mode smallint,
    tr_master_id smallint NOT NULL,
    status smallint DEFAULT 1,
    is_deleted smallint,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    is_scheduled boolean NOT NULL
);


ALTER TABLE billing.tr_detail OWNER TO postgres;

--
-- TOC entry 268 (class 1259 OID 920475)
-- Name: tr_detail_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.tr_detail_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.tr_detail_id_seq OWNER TO postgres;

--
-- TOC entry 6162 (class 0 OID 0)
-- Dependencies: 268
-- Name: tr_detail_id_seq; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.tr_detail_id_seq OWNED BY billing.tr_detail.id;


--
-- TOC entry 269 (class 1259 OID 920476)
-- Name: tr_10_detail; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.tr_10_detail (
    id integer DEFAULT nextval('billing.tr_detail_id_seq'::regclass),
    bill_id bigint,
    bill_mode smallint,
    tr_master_id smallint,
    status smallint DEFAULT 1,
    is_deleted smallint,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    is_scheduled boolean,
    employee_details_object jsonb
)
INHERITS (billing.tr_detail);


ALTER TABLE billing.tr_10_detail OWNER TO postgres;

--
-- TOC entry 270 (class 1259 OID 920484)
-- Name: tr_12_detail; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.tr_12_detail (
    id integer DEFAULT nextval('billing.tr_detail_id_seq'::regclass),
    bill_id bigint,
    bill_mode smallint,
    tr_master_id smallint,
    status smallint DEFAULT 1,
    is_deleted smallint,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    is_scheduled boolean,
    employee_details_object jsonb
)
INHERITS (billing.tr_detail);


ALTER TABLE billing.tr_12_detail OWNER TO postgres;

--
-- TOC entry 271 (class 1259 OID 920492)
-- Name: tr_26_detail_id_seq; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing.tr_26_detail_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing.tr_26_detail_id_seq OWNER TO postgres;

--
-- TOC entry 272 (class 1259 OID 920493)
-- Name: tr_26a_detail; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing.tr_26a_detail (
    voucher_details_object jsonb,
    pl_detail_object jsonb,
    reissue_amount bigint DEFAULT 0,
    topup_amount bigint DEFAULT 0,
    total_amt_for_cs_calc_sc bigint DEFAULT 0,
    total_amt_for_cs_calc_scoc bigint DEFAULT 0,
    total_amt_for_cs_calc_sccc bigint DEFAULT 0,
    total_amt_for_cs_calc_scsal bigint DEFAULT 0,
    total_amt_for_cs_calc_st bigint DEFAULT 0,
    total_amt_for_cs_calc_stoc bigint DEFAULT 0,
    total_amt_for_cs_calc_stcc bigint DEFAULT 0,
    total_amt_for_cs_calc_stsal bigint DEFAULT 0,
    total_amt_for_cs_calc_ot bigint DEFAULT 0,
    total_amt_for_cs_calc_otoc bigint DEFAULT 0,
    total_amt_for_cs_calc_otcc bigint DEFAULT 0,
    total_amt_for_cs_calc_otsal bigint DEFAULT 0,
    category_code character varying,
    hoa_id bigint
)
INHERITS (billing.tr_detail);


ALTER TABLE billing.tr_26a_detail OWNER TO postgres;

--
-- TOC entry 273 (class 1259 OID 920514)
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: billing_log; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_log.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_log.audit_log_id_seq OWNER TO postgres;

--
-- TOC entry 274 (class 1259 OID 920515)
-- Name: audit_log; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
)
PARTITION BY RANGE (change_timestamp);


ALTER TABLE billing_log.audit_log OWNER TO postgres;

--
-- TOC entry 275 (class 1259 OID 920519)
-- Name: audit_log_2025_05; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_05 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_05 OWNER TO postgres;

--
-- TOC entry 276 (class 1259 OID 920525)
-- Name: audit_log_2025_06; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_06 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_06 OWNER TO postgres;

--
-- TOC entry 277 (class 1259 OID 920531)
-- Name: audit_log_2025_07; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_07 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_07 OWNER TO postgres;

--
-- TOC entry 278 (class 1259 OID 920537)
-- Name: audit_log_2025_08; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_08 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_08 OWNER TO postgres;

--
-- TOC entry 279 (class 1259 OID 920543)
-- Name: audit_log_2025_09; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_09 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_09 OWNER TO postgres;

--
-- TOC entry 280 (class 1259 OID 920549)
-- Name: audit_log_2025_10; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_10 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_10 OWNER TO postgres;

--
-- TOC entry 281 (class 1259 OID 920555)
-- Name: audit_log_2025_11; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_11 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_11 OWNER TO postgres;

--
-- TOC entry 282 (class 1259 OID 920561)
-- Name: audit_log_2025_12; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2025_12 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2025_12 OWNER TO postgres;

--
-- TOC entry 283 (class 1259 OID 920567)
-- Name: audit_log_2026_01; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2026_01 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2026_01 OWNER TO postgres;

--
-- TOC entry 284 (class 1259 OID 920573)
-- Name: audit_log_2026_02; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2026_02 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2026_02 OWNER TO postgres;

--
-- TOC entry 285 (class 1259 OID 920579)
-- Name: audit_log_2026_03; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2026_03 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2026_03 OWNER TO postgres;

--
-- TOC entry 286 (class 1259 OID 920585)
-- Name: audit_log_2026_04; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.audit_log_2026_04 (
    id bigint DEFAULT nextval('billing_log.audit_log_id_seq'::regclass) NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    operation_type text NOT NULL,
    changed_by bigint,
    change_timestamp timestamp without time zone NOT NULL,
    old_data jsonb,
    new_data jsonb
);


ALTER TABLE billing_log.audit_log_2026_04 OWNER TO postgres;

--
-- TOC entry 287 (class 1259 OID 920591)
-- Name: cheque_details_id_seq; Type: SEQUENCE; Schema: billing_log; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_log.cheque_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_log.cheque_details_id_seq OWNER TO postgres;

--
-- TOC entry 288 (class 1259 OID 920592)
-- Name: ddo_id_seq; Type: SEQUENCE; Schema: billing_log; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_log.ddo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_log.ddo_id_seq OWNER TO postgres;

--
-- TOC entry 289 (class 1259 OID 920593)
-- Name: ddo_log; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.ddo_log (
    id bigint NOT NULL,
    treasury_code character(4),
    ddo_code character(9) NOT NULL,
    ddo_type character(1),
    valid_upto date,
    designation character varying(200),
    address character varying(200),
    phone_no1 character(20),
    phone_no2 character(20),
    fax character(20),
    e_mail character varying(50),
    pin character(6),
    active_flag boolean,
    created_by_userid bigint,
    created_at timestamp without time zone NOT NULL,
    updated_by_userid numeric(8,0),
    updated_at timestamp without time zone NOT NULL,
    ddo_tan_no character(10),
    int_dept_id bigint,
    office_name character varying(100),
    station character varying(50),
    controlling_officer character varying(50),
    enrolement_no character varying(25),
    nps_registration_no character(20),
    int_dept_id_hrms character(3),
    gstin character varying(255),
    parent_treasury_code character varying(10),
    ref_code numeric(6,0)
);


ALTER TABLE billing_log.ddo_log OWNER TO postgres;

--
-- TOC entry 290 (class 1259 OID 920598)
-- Name: ddo_log_id_seq; Type: SEQUENCE; Schema: billing_log; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_log.ddo_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_log.ddo_log_id_seq OWNER TO postgres;

--
-- TOC entry 6163 (class 0 OID 0)
-- Dependencies: 290
-- Name: ddo_log_id_seq; Type: SEQUENCE OWNED BY; Schema: billing_log; Owner: postgres
--

ALTER SEQUENCE billing_log.ddo_log_id_seq OWNED BY billing_log.ddo_log.id;


--
-- TOC entry 291 (class 1259 OID 920599)
-- Name: ebill_jit_int_map_log; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.ebill_jit_int_map_log (
    id bigint NOT NULL,
    ebill_ref_no character(20) NOT NULL,
    jit_ref_no character varying(50) NOT NULL,
    is_active boolean DEFAULT true,
    error_details jsonb,
    is_rejected boolean DEFAULT false,
    bill_id bigint NOT NULL,
    file_name character varying(32),
    created_at timestamp without time zone DEFAULT now(),
    financial_year smallint
);


ALTER TABLE billing_log.ebill_jit_int_map_log OWNER TO postgres;

--
-- TOC entry 292 (class 1259 OID 920607)
-- Name: ebill_jit_int_map_log_id_seq; Type: SEQUENCE; Schema: billing_log; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_log.ebill_jit_int_map_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_log.ebill_jit_int_map_log_id_seq OWNER TO postgres;

--
-- TOC entry 6164 (class 0 OID 0)
-- Dependencies: 292
-- Name: ebill_jit_int_map_log_id_seq; Type: SEQUENCE OWNED BY; Schema: billing_log; Owner: postgres
--

ALTER SEQUENCE billing_log.ebill_jit_int_map_log_id_seq OWNED BY billing_log.ebill_jit_int_map_log.id;


--
-- TOC entry 293 (class 1259 OID 920608)
-- Name: scheme_config_master_log; Type: TABLE; Schema: billing_log; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_log.scheme_config_master_log (
    id bigint NOT NULL,
    state_code character varying(11),
    sls_code character varying(11),
    debit_bank_acc_no character varying(25),
    debit_bank_ifsc character varying(11),
    bharat_dbt_code character varying(22),
    state_share numeric(5,2),
    goi_share numeric(5,2),
    debit_acc_name character varying(200),
    controllercode character varying(20),
    csscode character varying(30),
    cssname character varying(500),
    slsname character varying(500),
    modelno character varying(5),
    topup character varying(10),
    entrydate timestamp without time zone,
    is_active smallint,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone,
    action_type character(6),
    old_values jsonb,
    new_values jsonb
);


ALTER TABLE billing_log.scheme_config_master_log OWNER TO postgres;

--
-- TOC entry 294 (class 1259 OID 920614)
-- Name: scheme_config_master_log_id_seq; Type: SEQUENCE; Schema: billing_log; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_log.scheme_config_master_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_log.scheme_config_master_log_id_seq OWNER TO postgres;

--
-- TOC entry 6165 (class 0 OID 0)
-- Dependencies: 294
-- Name: scheme_config_master_log_id_seq; Type: SEQUENCE OWNED BY; Schema: billing_log; Owner: postgres
--

ALTER SEQUENCE billing_log.scheme_config_master_log_id_seq OWNED BY billing_log.scheme_config_master_log.id;


--
-- TOC entry 295 (class 1259 OID 920615)
-- Name: bill_project_contrctor_mapping_id_seq; Type: SEQUENCE; Schema: billing_master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_master.bill_project_contrctor_mapping_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_master.bill_project_contrctor_mapping_id_seq OWNER TO postgres;

--
-- TOC entry 296 (class 1259 OID 920616)
-- Name: bill_status_master; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.bill_status_master (
    status_id smallint NOT NULL,
    status_code character varying NOT NULL
);


ALTER TABLE billing_master.bill_status_master OWNER TO postgres;

--
-- TOC entry 297 (class 1259 OID 920621)
-- Name: bt_details; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.bt_details (
    id integer NOT NULL,
    bt_serial integer NOT NULL,
    "desc" character varying,
    hoa character varying,
    type character varying,
    demand_no character(2),
    major_head character(4),
    submajor_head character(2),
    minor_head character(3),
    scheme_head character(3),
    detail_head character(2),
    subdetail_head character(2),
    plan_status character(2),
    voted_charged character(1),
    created_by character(12),
    created_at timestamp without time zone,
    annexture character(3)
);


ALTER TABLE billing_master.bt_details OWNER TO postgres;

--
-- TOC entry 298 (class 1259 OID 920626)
-- Name: cpin_master_id_seq; Type: SEQUENCE; Schema: billing_master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_master.cpin_master_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_master.cpin_master_id_seq OWNER TO postgres;

--
-- TOC entry 299 (class 1259 OID 920627)
-- Name: cpin_master; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.cpin_master (
    id bigint DEFAULT nextval('billing_master.cpin_master_id_seq'::regclass) NOT NULL,
    cpin_id character varying(14),
    cpin_amount numeric NOT NULL,
    cpin_date_tcs timestamp without time zone,
    cpin_type integer,
    cpin_sub_type integer,
    active_flag integer,
    status smallint,
    created_at timestamp without time zone,
    created_by_userid bigint,
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    ddo_gstin character varying(15),
    vendor_data jsonb,
    epsid bigint,
    cpin_date date,
    is_active boolean DEFAULT true NOT NULL,
    financial_year smallint
);


ALTER TABLE billing_master.cpin_master OWNER TO postgres;

--
-- TOC entry 300 (class 1259 OID 920634)
-- Name: cpin_vender_mst_id_seq; Type: SEQUENCE; Schema: billing_master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_master.cpin_vender_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_master.cpin_vender_mst_id_seq OWNER TO postgres;

--
-- TOC entry 301 (class 1259 OID 920635)
-- Name: cpin_vender_mst; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.cpin_vender_mst (
    id bigint DEFAULT nextval('billing_master.cpin_vender_mst_id_seq'::regclass) NOT NULL,
    cpinmstid bigint NOT NULL,
    vendorname character varying,
    vendorgstin character varying(15),
    invoiceno character varying,
    invoicedate timestamp without time zone,
    invoicevalue double precision,
    amountpart1 double precision,
    amountpart2 double precision,
    total double precision,
    status smallint,
    created_at timestamp without time zone,
    created_by_userid bigint,
    updated_at timestamp without time zone,
    updated_by_userid bigint,
    ben_ref_id bigint
);


ALTER TABLE billing_master.cpin_vender_mst OWNER TO postgres;

--
-- TOC entry 302 (class 1259 OID 920641)
-- Name: rbi_gst_master; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.rbi_gst_master (
    id integer NOT NULL,
    ifsc character(12) NOT NULL,
    name character(10) DEFAULT 'GST'::bpchar NOT NULL,
    bank_name character varying(100) DEFAULT 'Reserve Bank Of India'::character varying NOT NULL,
    remitting_bank character varying(100) DEFAULT 'RESERVE BANK OF INDIA, PAD'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


ALTER TABLE billing_master.rbi_gst_master OWNER TO postgres;

--
-- TOC entry 303 (class 1259 OID 920648)
-- Name: rbi_gst_master_id_seq; Type: SEQUENCE; Schema: billing_master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_master.rbi_gst_master_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_master.rbi_gst_master_id_seq OWNER TO postgres;

--
-- TOC entry 6166 (class 0 OID 0)
-- Dependencies: 303
-- Name: rbi_gst_master_id_seq; Type: SEQUENCE OWNED BY; Schema: billing_master; Owner: postgres
--

ALTER SEQUENCE billing_master.rbi_gst_master_id_seq OWNED BY billing_master.rbi_gst_master.id;


--
-- TOC entry 304 (class 1259 OID 920649)
-- Name: service_provider_consumer_master_id_seq; Type: SEQUENCE; Schema: billing_master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS billing_master.service_provider_consumer_master_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE billing_master.service_provider_consumer_master_id_seq OWNER TO postgres;

--
-- TOC entry 305 (class 1259 OID 920650)
-- Name: tr_master; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.tr_master (
    id smallint NOT NULL,
    form_name character varying,
    wb_form_code character varying NOT NULL,
    is_employee integer,
    is_integrated_form integer,
    form_url character varying,
    view_url character varying,
    enabled integer,
    pdate timestamp with time zone,
    tdate timestamp with time zone,
    ag_category character varying,
    go_no character varying
);


ALTER TABLE billing_master.tr_master OWNER TO postgres;

--
-- TOC entry 306 (class 1259 OID 920655)
-- Name: tr_master_checklist; Type: TABLE; Schema: billing_master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS billing_master.tr_master_checklist (
    forms character varying,
    has_bt_details smallint,
    has_certificate_details smallint,
    has_neftorcheque_details smallint,
    has_serviceprov_details smallint,
    tr_master_id smallint NOT NULL
);


ALTER TABLE billing_master.tr_master_checklist OWNER TO postgres;

--
-- TOC entry 307 (class 1259 OID 920660)
-- Name: failed_transaction_beneficiary; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.failed_transaction_beneficiary (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(20),
    ifsc_code character(11),
    bank_name character varying,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    corrected_by bigint,
    corrected_at timestamp without time zone,
    is_active smallint,
    financial_year smallint,
    failed_transaction_amount bigint,
    beneficiary_id bigint,
    bill_ref_no character varying,
    jit_ref_no character varying,
    end_to_end_id character varying(29),
    status smallint DEFAULT 0 NOT NULL,
    payee_id character varying,
    agency_code character varying,
    failed_reason_code character varying,
    failed_reason_desc character varying,
    total_ben_failed_amount bigint,
    is_gst boolean DEFAULT false,
    accepted_date_time timestamp without time zone,
    is_corrected boolean DEFAULT false,
    challan_no integer,
    major_head character(4),
    challan_date date,
    cancel_certificate_date date,
    cancel_certificate_no character varying,
    utr_no character varying,
    is_certificate_generated boolean DEFAULT false,
    file_name character(32),
    gst_bill_id bigint,
    is_reissued boolean DEFAULT false,
    bill_fin_year smallint
);


ALTER TABLE cts.failed_transaction_beneficiary OWNER TO postgres;

--
-- TOC entry 308 (class 1259 OID 920671)
-- Name: success_transaction_beneficiary; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.success_transaction_beneficiary (
    id bigint NOT NULL,
    bill_id bigint NOT NULL,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(20),
    ifsc_code character(11),
    bank_name character varying,
    created_by_userid bigint,
    created_at timestamp without time zone DEFAULT now(),
    is_active smallint,
    financial_year smallint,
    amount bigint,
    beneficiary_id bigint,
    bill_ref_no character varying,
    jit_ref_no character varying,
    end_to_end_id character varying(29),
    status smallint DEFAULT 0 NOT NULL,
    payee_id character varying,
    agency_code character varying,
    total_amount bigint,
    is_gst boolean DEFAULT false,
    ecs_id bigint,
    utr_number character varying(22),
    accepted_date_time timestamp without time zone,
    file_name character(32)
);


ALTER TABLE cts.success_transaction_beneficiary OWNER TO postgres;

--
-- TOC entry 309 (class 1259 OID 920679)
-- Name: bill_wise_gst_success_failed_transaction_summary; Type: VIEW; Schema: cts; Owner: postgres
--

CREATE OR REPLACE VIEW cts.bill_wise_gst_success_failed_transaction_summary AS
 WITH bill_base AS (
         SELECT DISTINCT bd.bill_id,
            bd.financial_year,
            max(bd.gross_amount) AS gross_amount,
            max(bd.net_amount) AS net_amount,
            count(ecs.id) AS payee_count
           FROM (billing.bill_details bd
             JOIN billing.bill_ecs_neft_details ecs ON ((ecs.bill_id = bd.bill_id)))
          WHERE (ecs.is_gst = true)
          GROUP BY bd.bill_id, bd.financial_year
        ), success_data AS (
         SELECT sb.bill_id,
            count(sb.ecs_id) AS success_count,
            sum(sb.amount) AS success_amount
           FROM cts.success_transaction_beneficiary sb
          WHERE ((sb.is_gst = true) AND (sb.is_active = 1))
          GROUP BY sb.bill_id
        ), failed_data AS (
         SELECT fb.bill_id,
            count(fb.beneficiary_id) AS failed_count,
            sum(fb.failed_transaction_amount) AS failed_amount,
            COALESCE(bool_or(fb.is_reissued), false) AS is_reissued
           FROM cts.failed_transaction_beneficiary fb
          WHERE ((fb.is_gst = true) AND (fb.is_active = 1))
          GROUP BY fb.bill_id
        ), success_failed_transaction AS (
         SELECT bb.bill_id,
            bb.financial_year,
            bb.gross_amount,
            bb.net_amount,
            COALESCE(fd.is_reissued, false) AS is_reissued,
            COALESCE(sd.success_amount, (0)::numeric) AS success_amount,
            COALESCE(fd.failed_amount, (0)::numeric) AS failed_amount,
            (COALESCE(sd.success_amount, (0)::numeric) + COALESCE(fd.failed_amount, (0)::numeric)) AS total_received_amount,
            bb.payee_count AS total_payee_count,
            COALESCE(sd.success_count, (0)::bigint) AS success_payee_count,
            COALESCE(fd.failed_count, (0)::bigint) AS failed_payee_count,
            GREATEST(((bb.payee_count - COALESCE(sd.success_count, (0)::bigint)) - COALESCE(fd.failed_count, (0)::bigint)), (0)::bigint) AS pending_payee_count
           FROM ((bill_base bb
             LEFT JOIN success_data sd ON ((sd.bill_id = bb.bill_id)))
             LEFT JOIN failed_data fd ON ((fd.bill_id = bb.bill_id)))
        )
 SELECT bill_id,
    financial_year,
    gross_amount,
    net_amount,
    success_amount,
    failed_amount,
    total_received_amount,
    total_payee_count,
    success_payee_count,
    failed_payee_count,
    pending_payee_count,
    is_reissued
   FROM success_failed_transaction;


ALTER VIEW cts.bill_wise_gst_success_failed_transaction_summary OWNER TO postgres;

--
-- TOC entry 310 (class 1259 OID 920684)
-- Name: bill_wise_success_failed_transaction_summary; Type: VIEW; Schema: cts; Owner: postgres
--

CREATE OR REPLACE VIEW cts.bill_wise_success_failed_transaction_summary AS
 WITH bill_base AS (
         SELECT DISTINCT bd.bill_id,
            bd.financial_year,
            max(bd.gross_amount) AS gross_amount,
            max(bd.net_amount) AS net_amount,
            count(ecs.id) AS payee_count
           FROM (billing.bill_details bd
             JOIN billing.bill_ecs_neft_details ecs ON ((ecs.bill_id = bd.bill_id)))
          WHERE (ecs.is_gst = false)
          GROUP BY bd.bill_id, bd.financial_year
        ), success_data AS (
         SELECT sb.bill_id,
            count(sb.ecs_id) AS success_count,
            sum(sb.amount) AS success_amount
           FROM cts.success_transaction_beneficiary sb
          WHERE ((sb.is_gst = false) AND (sb.is_active = 1))
          GROUP BY sb.bill_id
        ), failed_data AS (
         SELECT fb.bill_id,
            count(fb.beneficiary_id) AS failed_count,
            sum(fb.failed_transaction_amount) AS failed_amount,
            COALESCE(bool_or(fb.is_reissued), false) AS is_reissued
           FROM cts.failed_transaction_beneficiary fb
          WHERE ((fb.is_gst = false) AND (fb.is_active = 1))
          GROUP BY fb.bill_id
        ), success_failed_transaction AS (
         SELECT bb.bill_id,
            bb.financial_year,
            bb.gross_amount,
            bb.net_amount,
            COALESCE(fd.is_reissued, false) AS is_reissued,
            COALESCE(sd.success_amount, (0)::numeric) AS success_amount,
            COALESCE(fd.failed_amount, (0)::numeric) AS failed_amount,
            (COALESCE(sd.success_amount, (0)::numeric) + COALESCE(fd.failed_amount, (0)::numeric)) AS total_received_amount,
            bb.payee_count AS total_payee_count,
            COALESCE(sd.success_count, (0)::bigint) AS success_payee_count,
            COALESCE(fd.failed_count, (0)::bigint) AS failed_payee_count,
            GREATEST(((bb.payee_count - COALESCE(sd.success_count, (0)::bigint)) - COALESCE(fd.failed_count, (0)::bigint)), (0)::bigint) AS pending_payee_count
           FROM ((bill_base bb
             LEFT JOIN success_data sd ON ((sd.bill_id = bb.bill_id)))
             LEFT JOIN failed_data fd ON ((fd.bill_id = bb.bill_id)))
        )
 SELECT bill_id,
    financial_year,
    gross_amount,
    net_amount,
    success_amount,
    failed_amount,
    total_received_amount,
    total_payee_count,
    success_payee_count,
    failed_payee_count,
    pending_payee_count,
    is_reissued
   FROM success_failed_transaction;


ALTER VIEW cts.bill_wise_success_failed_transaction_summary OWNER TO postgres;

--
-- TOC entry 311 (class 1259 OID 920689)
-- Name: challan; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.challan (
    id bigint NOT NULL,
    challan_no integer NOT NULL,
    challan_date date NOT NULL,
    amount bigint NOT NULL,
    tr_code character(4) NOT NULL,
    ddo_code character(9),
    treasury_code character(3),
    demand_no character(2),
    major_head character(4),
    submajor_head character(2),
    minor_head character(3),
    scheme_head character(3),
    detail_head character(2),
    subdetail_head character(2),
    plan_status character(2),
    voted_charged character(1),
    token_id bigint NOT NULL,
    payment_advice_id bigint,
    module_id smallint,
    financial_year smallint,
    created_by bigint NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    bill_id bigint
);


ALTER TABLE cts.challan OWNER TO postgres;

--
-- TOC entry 312 (class 1259 OID 920693)
-- Name: failed_transaction_beneficiary_id_seq_bk; Type: SEQUENCE; Schema: cts; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS cts.failed_transaction_beneficiary_id_seq_bk
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE cts.failed_transaction_beneficiary_id_seq_bk OWNER TO postgres;

--
-- TOC entry 313 (class 1259 OID 920694)
-- Name: failed_transaction_beneficiary_bk; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.failed_transaction_beneficiary_bk (
    id bigint DEFAULT nextval('cts.failed_transaction_beneficiary_id_seq_bk'::regclass) NOT NULL,
    bill_id bigint NOT NULL,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(18),
    ifsc_code character(11),
    bank_name character varying,
    created_by_userid bigint,
    created_at timestamp without time zone,
    corrected_by bigint,
    corrected_at timestamp without time zone,
    is_active smallint,
    financial_year smallint,
    failed_transaction_amount bigint,
    beneficiary_id bigint,
    bill_ref_no character varying,
    jit_ref_no character varying,
    end_to_end_id character varying(29),
    status smallint DEFAULT 0 NOT NULL,
    payee_id character varying,
    agency_code character varying,
    failed_reason_code character varying,
    failed_reason_desc character varying,
    total_ben_failed_amount bigint,
    is_gst boolean DEFAULT false,
    accepted_date_time timestamp without time zone,
    is_corrected boolean DEFAULT false,
    challan_no integer,
    major_head character(4),
    challan_date date,
    cancel_certificate_date date,
    cancel_certificate_no character varying
);


ALTER TABLE cts.failed_transaction_beneficiary_bk OWNER TO postgres;

--
-- TOC entry 314 (class 1259 OID 920703)
-- Name: failed_transaction_beneficiary_id_seq; Type: SEQUENCE; Schema: cts; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS cts.failed_transaction_beneficiary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE cts.failed_transaction_beneficiary_id_seq OWNER TO postgres;

--
-- TOC entry 6167 (class 0 OID 0)
-- Dependencies: 314
-- Name: failed_transaction_beneficiary_id_seq; Type: SEQUENCE OWNED BY; Schema: cts; Owner: postgres
--

ALTER SEQUENCE cts.failed_transaction_beneficiary_id_seq OWNED BY cts.failed_transaction_beneficiary.id;


--
-- TOC entry 315 (class 1259 OID 920704)
-- Name: gst; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.gst (
    id bigint NOT NULL,
    payee_id bigint,
    payee_code character varying(50),
    payee_name character varying(200),
    payee_gst_in character varying(100),
    invoice_no character varying,
    invoice_value numeric(12,2),
    invoice_date date,
    gst_amount numeric(12,2),
    sgst_amount numeric(12,2),
    cgst_amount numeric(12,2),
    is_mapped boolean DEFAULT false,
    agency_code character varying(100),
    agency_name character varying,
    ref_no character varying(50),
    ref_id bigint,
    igst_amount numeric(12,2),
    is_igst boolean,
    bill_id bigint,
    cpin_id bigint,
    updated_at timestamp without time zone,
    updated_by bigint,
    old_bill_id bigint,
    old_cpin_id bigint,
    is_regenerated boolean DEFAULT false
);


ALTER TABLE jit.gst OWNER TO postgres;

--
-- TOC entry 316 (class 1259 OID 920711)
-- Name: fto_wise_gst_success_failed_transaction_summary; Type: VIEW; Schema: cts; Owner: postgres
--

CREATE OR REPLACE VIEW cts.fto_wise_gst_success_failed_transaction_summary AS
 WITH bill_summary AS (
         SELECT gst.ref_no,
            bd.financial_year,
            COALESCE(sum(bd.gross_amount), (0)::numeric) AS gross_amount,
            COALESCE(sum(bd.net_amount), (0)::numeric) AS net_amount,
            count(gst.payee_id) AS total_payee_count
           FROM (billing.bill_details bd
             JOIN jit.gst gst ON ((gst.bill_id = bd.bill_id)))
          WHERE (gst.is_regenerated = false)
          GROUP BY gst.ref_no, bd.financial_year
        ), success_summary AS (
         SELECT gst.ref_no,
            count(stb.ecs_id) AS success_payee_count,
            sum(stb.amount) AS success_amount
           FROM (cts.success_transaction_beneficiary stb
             JOIN jit.gst gst ON ((gst.bill_id = stb.bill_id)))
          WHERE ((stb.is_active = 1) AND (stb.is_gst = true) AND (gst.is_regenerated = false))
          GROUP BY gst.ref_no
        ), failed_summary AS (
         SELECT gst.ref_no,
            count(ftb.beneficiary_id) AS failed_payee_count,
            sum(ftb.failed_transaction_amount) AS failed_amount,
            COALESCE(bool_or(ftb.is_reissued), false) AS is_reissued
           FROM (cts.failed_transaction_beneficiary ftb
             JOIN jit.gst gst ON ((gst.bill_id = ftb.bill_id)))
          WHERE ((ftb.is_active = 1) AND (ftb.is_gst = true) AND (gst.is_regenerated = false))
          GROUP BY gst.ref_no
        )
 SELECT bs.ref_no,
    bs.financial_year,
    (bs.gross_amount)::bigint AS gross_amount,
    (bs.net_amount)::bigint AS net_amount,
    COALESCE(ss.success_amount, (0)::numeric) AS success_amount,
    COALESCE(fs.failed_amount, (0)::numeric) AS failed_amount,
    (COALESCE(ss.success_amount, (0)::numeric) + COALESCE(fs.failed_amount, (0)::numeric)) AS total_received_amount,
    (bs.total_payee_count)::smallint AS total_payee_count,
    COALESCE(ss.success_payee_count, (0)::bigint) AS success_payee_count,
    COALESCE(fs.failed_payee_count, (0)::bigint) AS failed_payee_count,
    GREATEST(((bs.total_payee_count - COALESCE(ss.success_payee_count, (0)::bigint)) - COALESCE(fs.failed_payee_count, (0)::bigint)), (0)::bigint) AS pending_payee_count,
    COALESCE(fs.is_reissued, false) AS is_reissued
   FROM ((bill_summary bs
     LEFT JOIN success_summary ss ON (((ss.ref_no)::text = (bs.ref_no)::text)))
     LEFT JOIN failed_summary fs ON (((fs.ref_no)::text = (bs.ref_no)::text)));


ALTER VIEW cts.fto_wise_gst_success_failed_transaction_summary OWNER TO postgres;

--
-- TOC entry 317 (class 1259 OID 920716)
-- Name: fto_wise_success_failed_transaction_summary; Type: VIEW; Schema: cts; Owner: postgres
--

CREATE OR REPLACE VIEW cts.fto_wise_success_failed_transaction_summary AS
 WITH bill_summary AS (
         SELECT DISTINCT ecs_add.jit_reference_no AS jit_ref_no,
            ecs_add.financial_year,
            COALESCE(sum(ecs_add.gross_amount), (0)::numeric) AS gross_amount,
            COALESCE(sum(ecs_add.net_amount), (0)::numeric) AS net_amount,
            count(ecs_add.ecs_id) AS total_payee_count
           FROM (billing.bill_ecs_neft_details ecs
             JOIN billing.jit_ecs_additional ecs_add ON ((ecs.id = ecs_add.ecs_id)))
          WHERE (ecs.is_gst = false)
          GROUP BY ecs_add.jit_reference_no, ecs_add.financial_year
        ), success_summary AS (
         SELECT ecs_add.jit_reference_no AS jit_ref_no,
            count(stb.ecs_id) AS success_payee_count,
            sum(stb.amount) AS success_amount
           FROM (cts.success_transaction_beneficiary stb
             JOIN billing.jit_ecs_additional ecs_add ON ((stb.ecs_id = ecs_add.ecs_id)))
          WHERE ((stb.is_gst = false) AND (stb.is_active = 1))
          GROUP BY ecs_add.jit_reference_no
        ), failed_summary AS (
         SELECT ecs_add.jit_reference_no AS jit_ref_no,
            count(ftb.beneficiary_id) AS failed_payee_count,
            sum(ftb.failed_transaction_amount) AS failed_amount,
            COALESCE(bool_or(ftb.is_reissued), false) AS is_reissued
           FROM (cts.failed_transaction_beneficiary ftb
             JOIN billing.jit_ecs_additional ecs_add ON ((ftb.beneficiary_id = ecs_add.ecs_id)))
          WHERE ((ftb.is_gst = false) AND (ftb.is_active = 1))
          GROUP BY ecs_add.jit_reference_no
        )
 SELECT bs.jit_ref_no,
    bs.financial_year,
    (bs.gross_amount)::bigint AS gross_amount,
    (bs.net_amount)::bigint AS net_amount,
    COALESCE(ss.success_amount, (0)::numeric) AS success_amount,
    COALESCE(fs.failed_amount, (0)::numeric) AS failed_amount,
    (COALESCE(ss.success_amount, (0)::numeric) + COALESCE(fs.failed_amount, (0)::numeric)) AS total_received_amount,
    (bs.total_payee_count)::smallint AS total_payee_count,
    COALESCE(ss.success_payee_count, (0)::bigint) AS success_payee_count,
    COALESCE(fs.failed_payee_count, (0)::bigint) AS failed_payee_count,
    GREATEST(((bs.total_payee_count - COALESCE(ss.success_payee_count, (0)::bigint)) - COALESCE(fs.failed_payee_count, (0)::bigint)), (0)::bigint) AS pending_payee_count,
    COALESCE(fs.is_reissued, false) AS is_reissued
   FROM ((bill_summary bs
     LEFT JOIN success_summary ss ON (((ss.jit_ref_no)::text = (bs.jit_ref_no)::text)))
     LEFT JOIN failed_summary fs ON (((fs.jit_ref_no)::text = (bs.jit_ref_no)::text)));


ALTER VIEW cts.fto_wise_success_failed_transaction_summary OWNER TO postgres;

--
-- TOC entry 318 (class 1259 OID 920721)
-- Name: success_transaction_beneficiary_id_seq_bk; Type: SEQUENCE; Schema: cts; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS cts.success_transaction_beneficiary_id_seq_bk
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE cts.success_transaction_beneficiary_id_seq_bk OWNER TO postgres;

--
-- TOC entry 319 (class 1259 OID 920722)
-- Name: success_transaction_beneficiary_bk; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.success_transaction_beneficiary_bk (
    id bigint DEFAULT nextval('cts.success_transaction_beneficiary_id_seq_bk'::regclass) NOT NULL,
    bill_id bigint NOT NULL,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(18),
    ifsc_code character(11),
    bank_name character varying,
    created_by_userid bigint,
    created_at timestamp without time zone,
    is_active smallint,
    financial_year smallint,
    amount bigint,
    beneficiary_id bigint,
    bill_ref_no character varying,
    jit_ref_no character varying,
    end_to_end_id character varying(29),
    status smallint DEFAULT 0 NOT NULL,
    payee_id character varying,
    agency_code character varying,
    total_amount bigint,
    is_gst boolean DEFAULT false,
    ecs_id bigint,
    utr_number character varying(22),
    accepted_date_time timestamp without time zone
);


ALTER TABLE cts.success_transaction_beneficiary_bk OWNER TO postgres;

--
-- TOC entry 320 (class 1259 OID 920730)
-- Name: success_transaction_beneficiary_id_seq; Type: SEQUENCE; Schema: cts; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS cts.success_transaction_beneficiary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE cts.success_transaction_beneficiary_id_seq OWNER TO postgres;

--
-- TOC entry 6168 (class 0 OID 0)
-- Dependencies: 320
-- Name: success_transaction_beneficiary_id_seq; Type: SEQUENCE OWNED BY; Schema: cts; Owner: postgres
--

ALTER SEQUENCE cts.success_transaction_beneficiary_id_seq OWNED BY cts.success_transaction_beneficiary.id;


--
-- TOC entry 321 (class 1259 OID 920731)
-- Name: token; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.token (
    id bigint NOT NULL,
    token_number bigint NOT NULL,
    token_date date NOT NULL,
    entity_id bigint NOT NULL,
    ddo_code character(9),
    treasury_code character(3),
    financial_year_id smallint
);


ALTER TABLE cts.token OWNER TO postgres;

--
-- TOC entry 322 (class 1259 OID 920734)
-- Name: voucher; Type: TABLE; Schema: cts; Owner: postgres
--

CREATE TABLE IF NOT EXISTS cts.voucher (
    id bigint NOT NULL,
    voucher_no integer NOT NULL,
    voucher_date date NOT NULL,
    major_head character(4) NOT NULL,
    amount bigint NOT NULL,
    financial_year_id smallint NOT NULL,
    bill_id bigint NOT NULL,
    token_id bigint NOT NULL,
    treasury_code character(3) NOT NULL,
    status smallint DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE cts.voucher OWNER TO postgres;

--
-- TOC entry 323 (class 1259 OID 920739)
-- Name: voucher_id_seq; Type: SEQUENCE; Schema: cts; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS cts.voucher_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE cts.voucher_id_seq OWNER TO postgres;

--
-- TOC entry 324 (class 1259 OID 920740)
-- Name: voucher_id_seq1; Type: SEQUENCE; Schema: cts; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS cts.voucher_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE cts.voucher_id_seq1 OWNER TO postgres;

--
-- TOC entry 6169 (class 0 OID 0)
-- Dependencies: 324
-- Name: voucher_id_seq1; Type: SEQUENCE OWNED BY; Schema: cts; Owner: postgres
--

ALTER SEQUENCE cts.voucher_id_seq1 OWNED BY cts.voucher.id;


--
-- TOC entry 325 (class 1259 OID 920741)
-- Name: ddo_agency_mapping_details; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.ddo_agency_mapping_details (
    id bigint NOT NULL,
    agency_code character varying(100) NOT NULL,
    agency_name character varying(200),
    sls_code character varying(100) NOT NULL,
    ddo_code character varying(9) NOT NULL,
    treasury_code character varying(3),
    jit_requested_msg character varying(100),
    response_msg character varying(100),
    received_at timestamp without time zone DEFAULT now() NOT NULL,
    action_taken_at timestamp without time zone NOT NULL,
    action_type smallint,
    financial_year smallint NOT NULL
);


ALTER TABLE jit.ddo_agency_mapping_details OWNER TO postgres;

--
-- TOC entry 6170 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN ddo_agency_mapping_details.action_type; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.ddo_agency_mapping_details.action_type IS '0 for reject, 1 for approve';


--
-- TOC entry 326 (class 1259 OID 920747)
-- Name: ddo_agency_mapping_details_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.ddo_agency_mapping_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.ddo_agency_mapping_details_id_seq OWNER TO postgres;

--
-- TOC entry 6171 (class 0 OID 0)
-- Dependencies: 326
-- Name: ddo_agency_mapping_details_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.ddo_agency_mapping_details_id_seq OWNED BY jit.ddo_agency_mapping_details.id;


--
-- TOC entry 327 (class 1259 OID 920748)
-- Name: exp_payee_components; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.exp_payee_components (
    id bigint NOT NULL,
    payee_id bigint,
    payee_code character varying,
    componentcode character varying(50),
    componentname character varying,
    amount numeric(12,2),
    agency_code character varying(100),
    agency_name character varying,
    ref_no character varying(50),
    ref_id bigint,
    slscode character varying(50),
    scheme_name character varying(200)
);


ALTER TABLE jit.exp_payee_components OWNER TO postgres;

--
-- TOC entry 328 (class 1259 OID 920753)
-- Name: exp_payee_components_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.exp_payee_components_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.exp_payee_components_id_seq OWNER TO postgres;

--
-- TOC entry 6172 (class 0 OID 0)
-- Dependencies: 328
-- Name: exp_payee_components_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.exp_payee_components_id_seq OWNED BY jit.exp_payee_components.id;


--
-- TOC entry 329 (class 1259 OID 920754)
-- Name: fto_voucher; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.fto_voucher (
    id bigint NOT NULL,
    payee_id bigint,
    payee_code character varying(50),
    payee_name character varying(200),
    voucher_no character varying(150),
    voucher_date date,
    amount numeric(12,2),
    authority character varying(150),
    desc_charges character varying(150),
    agency_code character varying(100),
    agency_name character varying,
    ref_no character varying(50),
    ref_id bigint
);


ALTER TABLE jit.fto_voucher OWNER TO postgres;

--
-- TOC entry 330 (class 1259 OID 920759)
-- Name: fto_voucher_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.fto_voucher_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.fto_voucher_id_seq OWNER TO postgres;

--
-- TOC entry 6173 (class 0 OID 0)
-- Dependencies: 330
-- Name: fto_voucher_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.fto_voucher_id_seq OWNED BY jit.fto_voucher.id;


--
-- TOC entry 331 (class 1259 OID 920760)
-- Name: gst_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.gst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.gst_id_seq OWNER TO postgres;

--
-- TOC entry 6174 (class 0 OID 0)
-- Dependencies: 331
-- Name: gst_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.gst_id_seq OWNED BY jit.gst.id;


--
-- TOC entry 332 (class 1259 OID 920761)
-- Name: jit_allotment; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.jit_allotment (
    id bigint NOT NULL,
    sls_code character varying,
    fin_year smallint,
    self_limit_amount bigint NOT NULL,
    hoa_id bigint NOT NULL,
    treasury_code character(3) NOT NULL,
    ddo_code character(9) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    sanction_date character varying NOT NULL,
    sanction_no character varying NOT NULL,
    head_wise_sanction_id bigint,
    limit_type character(1),
    sls_limit_distribution_id bigint,
    agency_code text,
    agency_name character varying
);


ALTER TABLE jit.jit_allotment OWNER TO postgres;

--
-- TOC entry 333 (class 1259 OID 920767)
-- Name: jit_allotment_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.jit_allotment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.jit_allotment_id_seq OWNER TO postgres;

--
-- TOC entry 6175 (class 0 OID 0)
-- Dependencies: 333
-- Name: jit_allotment_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.jit_allotment_id_seq OWNED BY jit.jit_allotment.id;


--
-- TOC entry 334 (class 1259 OID 920768)
-- Name: jit_fto_sanction_booking; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.jit_fto_sanction_booking (
    id bigint NOT NULL,
    sanction_id bigint NOT NULL,
    sanction_no character varying NOT NULL,
    booked_amt numeric(18,2) NOT NULL,
    ref_no character varying(50) NOT NULL,
    ref_id bigint,
    ddo_code character(9) NOT NULL,
    allotment_id bigint,
    is_duplicate boolean DEFAULT false,
    hoa_id bigint,
    old_ref_no character varying(50)
);


ALTER TABLE jit.jit_fto_sanction_booking OWNER TO postgres;

--
-- TOC entry 335 (class 1259 OID 920774)
-- Name: jit_fto_sanction_booking_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.jit_fto_sanction_booking_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.jit_fto_sanction_booking_id_seq OWNER TO postgres;

--
-- TOC entry 6176 (class 0 OID 0)
-- Dependencies: 335
-- Name: jit_fto_sanction_booking_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.jit_fto_sanction_booking_id_seq OWNED BY jit.jit_fto_sanction_booking.id;


--
-- TOC entry 336 (class 1259 OID 920775)
-- Name: jit_pullback_request; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.jit_pullback_request (
    id bigint NOT NULL,
    ddo_code character varying,
    agency_id character varying,
    ref_no character varying,
    status smallint,
    remarks character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


ALTER TABLE jit.jit_pullback_request OWNER TO postgres;

--
-- TOC entry 337 (class 1259 OID 920780)
-- Name: jit_pullback_request_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.jit_pullback_request_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.jit_pullback_request_id_seq OWNER TO postgres;

--
-- TOC entry 6177 (class 0 OID 0)
-- Dependencies: 337
-- Name: jit_pullback_request_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.jit_pullback_request_id_seq OWNED BY jit.jit_pullback_request.id;


--
-- TOC entry 338 (class 1259 OID 920781)
-- Name: jit_report_details; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.jit_report_details (
    id bigint NOT NULL,
    ddo_code character(9),
    scheme_code character varying(50),
    scheme_name character varying,
    hoa_id bigint,
    fto_received bigint DEFAULT '0'::bigint,
    fto_rejected bigint DEFAULT '0'::bigint,
    bill_generated bigint DEFAULT '0'::bigint,
    bill_forward_to_treasury bigint DEFAULT '0'::bigint,
    paymandate_shortlisted bigint DEFAULT '0'::bigint,
    return_by_treasury bigint DEFAULT '0'::bigint,
    bill_pending_for_approval bigint DEFAULT 0,
    agency_code character varying,
    agency_name character varying
);


ALTER TABLE jit.jit_report_details OWNER TO postgres;

--
-- TOC entry 339 (class 1259 OID 920793)
-- Name: jit_report_details_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.jit_report_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.jit_report_details_id_seq OWNER TO postgres;

--
-- TOC entry 6178 (class 0 OID 0)
-- Dependencies: 339
-- Name: jit_report_details_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.jit_report_details_id_seq OWNED BY jit.jit_report_details.id;


--
-- TOC entry 340 (class 1259 OID 920794)
-- Name: jit_withdrawl; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.jit_withdrawl (
    id bigint NOT NULL,
    sls_code character varying,
    fin_year smallint,
    self_limit_amount bigint NOT NULL,
    hoa_id bigint NOT NULL,
    treasury_code character(3) NOT NULL,
    ddo_code character(9) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    sanction_date character varying NOT NULL,
    sanction_no character varying NOT NULL,
    head_wise_sanction_id bigint,
    limit_type character(1),
    sls_limit_distribution_id bigint,
    from_sanction_no character varying,
    is_send boolean DEFAULT false,
    agency_code character(200) NOT NULL
);


ALTER TABLE jit.jit_withdrawl OWNER TO postgres;

--
-- TOC entry 341 (class 1259 OID 920801)
-- Name: jit_withdrawl_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.jit_withdrawl_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.jit_withdrawl_id_seq OWNER TO postgres;

--
-- TOC entry 6179 (class 0 OID 0)
-- Dependencies: 341
-- Name: jit_withdrawl_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.jit_withdrawl_id_seq OWNED BY jit.jit_withdrawl.id;


--
-- TOC entry 342 (class 1259 OID 920802)
-- Name: mother_sanction_allocation; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.mother_sanction_allocation (
    id bigint NOT NULL,
    sls_scheme_code character varying,
    sanction_amount bigint,
    fin_year smallint,
    center_share_amount bigint,
    state_share_amount bigint,
    state_topup_amount bigint,
    available_amount bigint,
    is_top_up boolean,
    send_to_cts smallint DEFAULT 0,
    css_scheme_code character varying,
    css_scheme_name character varying,
    amc_amt bigint,
    approval_status character varying,
    approved_date timestamp without time zone,
    created_at timestamp without time zone,
    efile_no character varying,
    group_n_sanction_id character varying(100),
    head_wise_sanction_id bigint,
    hoa_id bigint,
    mother_sanction_no character varying,
    proposal_no character varying,
    psc_amt bigint,
    sls_code character varying(50),
    sls_limit_distribution_id bigint,
    sls_name character varying(300)
);


ALTER TABLE jit.mother_sanction_allocation OWNER TO postgres;

--
-- TOC entry 6180 (class 0 OID 0)
-- Dependencies: 342
-- Name: COLUMN mother_sanction_allocation.send_to_cts; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.mother_sanction_allocation.send_to_cts IS '0 for not yet send to CTS and 1 for sent to CTS';


--
-- TOC entry 343 (class 1259 OID 920808)
-- Name: mother_sanction_allocation_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.mother_sanction_allocation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.mother_sanction_allocation_id_seq OWNER TO postgres;

--
-- TOC entry 6181 (class 0 OID 0)
-- Dependencies: 343
-- Name: mother_sanction_allocation_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.mother_sanction_allocation_id_seq OWNED BY jit.mother_sanction_allocation.id;


--
-- TOC entry 344 (class 1259 OID 920809)
-- Name: payee_deduction; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.payee_deduction (
    id bigint NOT NULL,
    payee_id bigint,
    payee_code character varying,
    bt_code integer NOT NULL,
    bt_desc character varying,
    bt_type character varying,
    amount double precision NOT NULL,
    agency_code character varying(100),
    agency_name character varying,
    ref_no character varying(50),
    ref_id bigint
);


ALTER TABLE jit.payee_deduction OWNER TO postgres;

--
-- TOC entry 345 (class 1259 OID 920814)
-- Name: payee_deduction_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.payee_deduction_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.payee_deduction_id_seq OWNER TO postgres;

--
-- TOC entry 6182 (class 0 OID 0)
-- Dependencies: 345
-- Name: payee_deduction_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.payee_deduction_id_seq OWNED BY jit.payee_deduction.id;


--
-- TOC entry 346 (class 1259 OID 920815)
-- Name: scheme_config_master; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.scheme_config_master (
    id bigint NOT NULL,
    state_code character varying(11),
    sls_code character varying(11),
    debit_bank_acc_no character varying(25),
    debit_bank_ifsc character varying(11),
    bharat_dbt_code character varying(22),
    state_share numeric(5,2),
    goi_share numeric(5,2),
    debit_acc_name character varying(200),
    controllercode character varying(20),
    csscode character varying(30),
    cssname character varying(500),
    slsname character varying(500),
    modelno character varying(5),
    topup character varying(10),
    entrydate timestamp without time zone,
    is_active smallint DEFAULT 1 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone
);


ALTER TABLE jit.scheme_config_master OWNER TO postgres;

--
-- TOC entry 347 (class 1259 OID 920822)
-- Name: scheme_config_master_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.scheme_config_master_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.scheme_config_master_id_seq OWNER TO postgres;

--
-- TOC entry 6183 (class 0 OID 0)
-- Dependencies: 347
-- Name: scheme_config_master_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.scheme_config_master_id_seq OWNED BY jit.scheme_config_master.id;


--
-- TOC entry 348 (class 1259 OID 920823)
-- Name: tsa_exp_details; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.tsa_exp_details (
    id bigint NOT NULL,
    ref_no character varying(50),
    sls_code character varying(50),
    scheme_name character varying,
    agency_code character varying(100),
    agency_name character varying,
    hoa_id bigint,
    treas_code character varying(3),
    ddo_code character varying(9),
    is_top_up boolean,
    is_reissue boolean,
    net_amount numeric(12,2),
    gross_amount numeric(12,2),
    topup_amount numeric,
    reissue_amount numeric,
    total_bt numeric,
    total_gst numeric,
    payee_count integer,
    category_code character varying,
    district_code_lgd character varying,
    total_amt_for_cs_calc_sc numeric,
    total_amt_for_cs_calc_scoc numeric,
    total_amt_for_cs_calc_sccc numeric,
    total_amt_for_cs_calc_scsal numeric,
    total_amt_for_cs_calc_st numeric,
    total_amt_for_cs_calc_stoc numeric,
    total_amt_for_cs_calc_stcc numeric,
    total_amt_for_cs_calc_stsal numeric,
    total_amt_for_cs_calc_ot numeric,
    total_amt_for_cs_calc_otoc numeric,
    total_amt_for_cs_calc_otcc numeric,
    total_amt_for_cs_calc_otsal numeric,
    created_at timestamp without time zone DEFAULT now(),
    created_by_userid bigint,
    is_mapped boolean DEFAULT false,
    is_rejected boolean DEFAULT false,
    total_treasury_bt numeric DEFAULT 0,
    total_ag_bt numeric DEFAULT 0,
    fto_type character varying(15),
    system_rejected boolean DEFAULT false,
    reject_reason character varying(100),
    rejected_at timestamp without time zone,
    rejected_by bigint,
    financial_year smallint,
    old_jit_ref_no character varying(50)
);


ALTER TABLE jit.tsa_exp_details OWNER TO postgres;

--
-- TOC entry 349 (class 1259 OID 920834)
-- Name: tsa_exp_details_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.tsa_exp_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.tsa_exp_details_id_seq OWNER TO postgres;

--
-- TOC entry 6184 (class 0 OID 0)
-- Dependencies: 349
-- Name: tsa_exp_details_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.tsa_exp_details_id_seq OWNED BY jit.tsa_exp_details.id;


--
-- TOC entry 350 (class 1259 OID 920835)
-- Name: tsa_payeemaster; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.tsa_payeemaster (
    id bigint NOT NULL,
    payee_code character varying(50),
    payee_name character varying(200),
    pan_no character varying(12),
    aadhaar_no character varying(100),
    mobile_no character varying(10),
    email_id character varying(100),
    bank_name character varying(100),
    acc_no character varying(20),
    ifsc_code character varying(15),
    gross_amount numeric(12,2),
    net_amount numeric(12,2),
    reissue_amount numeric(12,2),
    last_end_to_end_id character varying,
    agency_code character varying(100),
    agency_name character varying,
    ref_id bigint,
    ref_no character varying(50),
    payee_type character(2),
    old_ref_no character varying(50),
    district_code_lgd character(3),
    state_code_lgd character(2),
    urban_rural_flag character(1) DEFAULT 'N'::bpchar NOT NULL,
    block_lgd character varying(10),
    panchayat_lgd character varying(10),
    village_lgd character varying(10),
    tehsil_lgd character varying(10),
    town_lgd character varying(10),
    ward_lgd character varying(10),
    CONSTRAINT chk_urban_rural_mandatory_cols CHECK ((((urban_rural_flag = 'R'::bpchar) AND (block_lgd IS NOT NULL) AND (panchayat_lgd IS NOT NULL) AND (village_lgd IS NOT NULL) AND (state_code_lgd IS NOT NULL) AND (district_code_lgd IS NOT NULL)) OR ((urban_rural_flag = 'U'::bpchar) AND (tehsil_lgd IS NOT NULL) AND (town_lgd IS NOT NULL) AND (ward_lgd IS NOT NULL) AND (state_code_lgd IS NOT NULL) AND (district_code_lgd IS NOT NULL)) OR (urban_rural_flag = 'N'::bpchar)))
);


ALTER TABLE jit.tsa_payeemaster OWNER TO postgres;

--
-- TOC entry 6185 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.urban_rural_flag; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.urban_rural_flag IS 'Urban/Rural/NA flag: U=Urban, R=Rural, N=Not Applicable';


--
-- TOC entry 6186 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.block_lgd; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.block_lgd IS 'LGD code for block';


--
-- TOC entry 6187 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.panchayat_lgd; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.panchayat_lgd IS 'LGD code for panchayat';


--
-- TOC entry 6188 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.village_lgd; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.village_lgd IS 'LGD code for village';


--
-- TOC entry 6189 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.tehsil_lgd; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.tehsil_lgd IS 'LGD code for tehsil';


--
-- TOC entry 6190 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.town_lgd; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.town_lgd IS 'LGD code for town';


--
-- TOC entry 6191 (class 0 OID 0)
-- Dependencies: 350
-- Name: COLUMN tsa_payeemaster.ward_lgd; Type: COMMENT; Schema: jit; Owner: postgres
--

COMMENT ON COLUMN jit.tsa_payeemaster.ward_lgd IS 'LGD code for ward';


--
-- TOC entry 351 (class 1259 OID 920842)
-- Name: tsa_payeemaster_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.tsa_payeemaster_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.tsa_payeemaster_id_seq OWNER TO postgres;

--
-- TOC entry 6192 (class 0 OID 0)
-- Dependencies: 351
-- Name: tsa_payeemaster_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.tsa_payeemaster_id_seq OWNED BY jit.tsa_payeemaster.id;


--
-- TOC entry 352 (class 1259 OID 920843)
-- Name: tsa_schemecomponent; Type: TABLE; Schema: jit; Owner: postgres
--

CREATE TABLE IF NOT EXISTS jit.tsa_schemecomponent (
    id bigint NOT NULL,
    slscode character varying(50),
    shemename character varying(300),
    componentcode character varying(50),
    componentname character varying(200),
    is_active boolean,
    financial_year integer
);


ALTER TABLE jit.tsa_schemecomponent OWNER TO postgres;

--
-- TOC entry 353 (class 1259 OID 920848)
-- Name: tsa_schemecomponent_id_seq; Type: SEQUENCE; Schema: jit; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS jit.tsa_schemecomponent_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE jit.tsa_schemecomponent_id_seq OWNER TO postgres;

--
-- TOC entry 6193 (class 0 OID 0)
-- Dependencies: 353
-- Name: tsa_schemecomponent_id_seq; Type: SEQUENCE OWNED BY; Schema: jit; Owner: postgres
--

ALTER SEQUENCE jit.tsa_schemecomponent_id_seq OWNED BY jit.tsa_schemecomponent.id;


--
-- TOC entry 354 (class 1259 OID 920849)
-- Name: bank_type_master; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.bank_type_master (
    id integer NOT NULL,
    bank_type character varying NOT NULL,
    created_date timestamp without time zone DEFAULT now() NOT NULL,
    is_active boolean NOT NULL
);


ALTER TABLE master.bank_type_master OWNER TO postgres;

--
-- TOC entry 355 (class 1259 OID 920855)
-- Name: bank_type_master_id_seq; Type: SEQUENCE; Schema: master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS master.bank_type_master_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE master.bank_type_master_id_seq OWNER TO postgres;

--
-- TOC entry 6194 (class 0 OID 0)
-- Dependencies: 355
-- Name: bank_type_master_id_seq; Type: SEQUENCE OWNED BY; Schema: master; Owner: postgres
--

ALTER SEQUENCE master.bank_type_master_id_seq OWNED BY master.bank_type_master.id;


--
-- TOC entry 356 (class 1259 OID 920856)
-- Name: ddo; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.ddo (
    id bigint NOT NULL,
    treasury_code character(4),
    ddo_code character(9) NOT NULL,
    ddo_type character(1),
    valid_upto date,
    designation character varying(200),
    address character varying(200),
    phone_no1 character(20),
    phone_no2 character(20),
    fax character(20),
    e_mail character varying(50),
    pin character(6),
    active_flag boolean,
    created_by_userid bigint,
    created_at timestamp without time zone NOT NULL,
    updated_by_userid numeric(8,0),
    updated_at timestamp without time zone,
    ddo_tan_no character(10),
    int_dept_id bigint,
    office_name character varying(100),
    station character varying(50),
    controlling_officer character varying(50),
    enrolement_no character varying(25),
    nps_registration_no character(20),
    int_dept_id_hrms character(3),
    gstin character varying(255),
    parent_treasury_code character varying(10),
    ref_code numeric(6,0)
);


ALTER TABLE master.ddo OWNER TO postgres;

--
-- TOC entry 357 (class 1259 OID 920861)
-- Name: ddo_id_seq; Type: SEQUENCE; Schema: master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS master.ddo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE master.ddo_id_seq OWNER TO postgres;

--
-- TOC entry 6195 (class 0 OID 0)
-- Dependencies: 357
-- Name: ddo_id_seq; Type: SEQUENCE OWNED BY; Schema: master; Owner: postgres
--

ALTER SEQUENCE master.ddo_id_seq OWNED BY master.ddo.id;


--
-- TOC entry 358 (class 1259 OID 920862)
-- Name: demand_major_mapping; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.demand_major_mapping (
    id smallint NOT NULL,
    demand_code character(2),
    major_head_code character(4),
    major_head_id smallint
);


ALTER TABLE master.demand_major_mapping OWNER TO postgres;

--
-- TOC entry 359 (class 1259 OID 920865)
-- Name: department; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.department (
    id smallint NOT NULL,
    code character(2) NOT NULL,
    name character varying(100),
    demand_code character(2) NOT NULL
);


ALTER TABLE master.department OWNER TO postgres;

--
-- TOC entry 360 (class 1259 OID 920868)
-- Name: detail_head; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.detail_head (
    id smallint NOT NULL,
    code character(2),
    name character varying(100)
);


ALTER TABLE master.detail_head OWNER TO postgres;

--
-- TOC entry 361 (class 1259 OID 920871)
-- Name: financial_year_master_id_seq; Type: SEQUENCE; Schema: master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS master.financial_year_master_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE master.financial_year_master_id_seq OWNER TO postgres;

--
-- TOC entry 362 (class 1259 OID 920872)
-- Name: financial_year_master; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.financial_year_master (
    id smallint DEFAULT nextval('master.financial_year_master_id_seq'::regclass) NOT NULL,
    financial_year character(9),
    is_active boolean,
    created_by_userid bigint,
    created_at timestamp without time zone,
    updated_by_userid bigint,
    updated_at timestamp without time zone
);


ALTER TABLE master.financial_year_master OWNER TO postgres;

--
-- TOC entry 363 (class 1259 OID 920876)
-- Name: major_head; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.major_head (
    id smallint NOT NULL,
    code character(4),
    name character varying(150)
);


ALTER TABLE master.major_head OWNER TO postgres;

--
-- TOC entry 364 (class 1259 OID 920879)
-- Name: minor_head; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.minor_head (
    id smallint NOT NULL,
    code character(3),
    name character varying(150),
    sub_major_id smallint
);


ALTER TABLE master.minor_head OWNER TO postgres;

--
-- TOC entry 365 (class 1259 OID 920882)
-- Name: pending_ddo_list; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.pending_ddo_list (
    "TREASURY_CODE" character varying(50),
    "DDO_CODE" character varying(50),
    "DESIGNATION" character varying(128)
);


ALTER TABLE master.pending_ddo_list OWNER TO postgres;

--
-- TOC entry 366 (class 1259 OID 920885)
-- Name: rbi_ifsc_stock; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.rbi_ifsc_stock (
    branchid integer,
    bankid integer,
    bankname character varying,
    ifsc character(11) NOT NULL,
    office character varying,
    address character varying,
    district character varying,
    city character varying,
    state character varying,
    phone character varying,
    is_active boolean
);


ALTER TABLE master.rbi_ifsc_stock OWNER TO postgres;

--
-- TOC entry 367 (class 1259 OID 920890)
-- Name: scheme_head; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.scheme_head (
    id smallint NOT NULL,
    demand_code character(2),
    code character(3),
    name character varying(300),
    minor_head_id smallint NOT NULL
);


ALTER TABLE master.scheme_head OWNER TO postgres;

--
-- TOC entry 368 (class 1259 OID 920893)
-- Name: sub_detail_head; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.sub_detail_head (
    id smallint NOT NULL,
    code character(2),
    name character varying(100),
    detail_head_id smallint
);


ALTER TABLE master.sub_detail_head OWNER TO postgres;

--
-- TOC entry 369 (class 1259 OID 920896)
-- Name: sub_major_head; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.sub_major_head (
    id smallint NOT NULL,
    code character(2),
    name character varying(150),
    major_head_id smallint
);


ALTER TABLE master.sub_major_head OWNER TO postgres;

--
-- TOC entry 370 (class 1259 OID 920899)
-- Name: treasury; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.treasury (
    id integer NOT NULL,
    code character(4) NOT NULL,
    treasury_name character varying(100),
    district_code character(2),
    treasury_srl_number character(4),
    officer_user_id bigint,
    officer_name character varying(100),
    address character varying(200),
    address1 character varying(200),
    address2 character varying(200),
    phone_no1 character varying(20),
    phone_no2 character varying(20),
    fax character(20),
    e_mail character varying(50),
    pin character(6),
    active_flag boolean,
    createdby_user_id bigint,
    created_by timestamp without time zone,
    updatedby_user_id numeric(8,0),
    updated_by timestamp without time zone,
    int_treasury_code character(5),
    treasury_status character(1),
    int_ddo_id numeric(6,0),
    debt_acct_no character(15),
    nps_registration_no character(10),
    pension_flag character(1),
    ref_code numeric(3,0)
);


ALTER TABLE master.treasury OWNER TO postgres;

--
-- TOC entry 371 (class 1259 OID 920904)
-- Name: treasury_id_seq; Type: SEQUENCE; Schema: master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS master.treasury_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE master.treasury_id_seq OWNER TO postgres;

--
-- TOC entry 6196 (class 0 OID 0)
-- Dependencies: 371
-- Name: treasury_id_seq; Type: SEQUENCE OWNED BY; Schema: master; Owner: postgres
--

ALTER SEQUENCE master.treasury_id_seq OWNED BY master.treasury.id;


--
-- TOC entry 372 (class 1259 OID 920905)
-- Name: tsa_vendor_type; Type: TABLE; Schema: master; Owner: postgres
--

CREATE TABLE IF NOT EXISTS master.tsa_vendor_type (
    id bigint NOT NULL,
    ven_type_id character varying(3),
    type_name character varying(50),
    is_active boolean DEFAULT true NOT NULL,
    created_by character varying,
    created_at timestamp without time zone DEFAULT now(),
    updated_by character varying,
    updated_at timestamp without time zone
);


ALTER TABLE master.tsa_vendor_type OWNER TO postgres;

--
-- TOC entry 373 (class 1259 OID 920912)
-- Name: tsa_vendor_type_id_seq; Type: SEQUENCE; Schema: master; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS master.tsa_vendor_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE master.tsa_vendor_type_id_seq OWNER TO postgres;

--
-- TOC entry 6197 (class 0 OID 0)
-- Dependencies: 373
-- Name: tsa_vendor_type_id_seq; Type: SEQUENCE OWNED BY; Schema: master; Owner: postgres
--

ALTER SEQUENCE master.tsa_vendor_type_id_seq OWNED BY master.tsa_vendor_type.id;


--
-- TOC entry 374 (class 1259 OID 920913)
-- Name: consume_logs; Type: TABLE; Schema: message_queue; Owner: postgres
--

CREATE TABLE IF NOT EXISTS message_queue.consume_logs (
    id bigint NOT NULL,
    message_id character varying(255),
    queue_name character varying(255),
    exchange_name character varying(255),
    raouting_key character varying(255),
    message_body text,
    consumed_at timestamp without time zone,
    status character(50),
    error_messages text,
    error_type character(50),
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE message_queue.consume_logs OWNER TO postgres;

--
-- TOC entry 375 (class 1259 OID 920919)
-- Name: consume_logs_id_seq; Type: SEQUENCE; Schema: message_queue; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS message_queue.consume_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE message_queue.consume_logs_id_seq OWNER TO postgres;

--
-- TOC entry 6198 (class 0 OID 0)
-- Dependencies: 375
-- Name: consume_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: message_queue; Owner: postgres
--

ALTER SEQUENCE message_queue.consume_logs_id_seq OWNED BY message_queue.consume_logs.id;


--
-- TOC entry 376 (class 1259 OID 920920)
-- Name: consume_logs_partition; Type: TABLE; Schema: message_queue; Owner: postgres
--

CREATE TABLE IF NOT EXISTS message_queue.consume_logs_partition (
    id bigint DEFAULT nextval('message_queue.consume_logs_id_seq'::regclass) NOT NULL,
    message_id character varying(255),
    queue_name character varying(255),
    exchange_name character varying(255),
    raouting_key character varying(255),
    message_body text,
    consumed_at timestamp without time zone,
    status character(50),
    error_messages text,
    error_type character(50),
    created_at timestamp without time zone DEFAULT now() NOT NULL
)
PARTITION BY RANGE (created_at);


ALTER TABLE message_queue.consume_logs_partition OWNER TO postgres;

--
-- TOC entry 377 (class 1259 OID 920925)
-- Name: message_queue_logs; Type: TABLE; Schema: message_queue; Owner: postgres
--

CREATE TABLE IF NOT EXISTS message_queue.message_queue_logs (
    unique_id uuid NOT NULL,
    exchange_name character varying(100),
    queue_name character varying(100) NOT NULL,
    message_body jsonb NOT NULL,
    queue_options jsonb,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    publish_at timestamp without time zone
);


ALTER TABLE message_queue.message_queue_logs OWNER TO postgres;

--
-- TOC entry 378 (class 1259 OID 920931)
-- Name: message_queues; Type: TABLE; Schema: message_queue; Owner: postgres
--

CREATE TABLE IF NOT EXISTS message_queue.message_queues (
    unique_id uuid DEFAULT gen_random_uuid() NOT NULL,
    exchange_name character varying(100),
    queue_name character varying(100) NOT NULL,
    message_body jsonb NOT NULL,
    queue_options jsonb,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    publish_at timestamp without time zone
);


ALTER TABLE message_queue.message_queues OWNER TO postgres;

--
-- TOC entry 379 (class 1259 OID 920938)
-- Name: queues_master; Type: TABLE; Schema: message_queue; Owner: postgres
--

CREATE TABLE IF NOT EXISTS message_queue.queues_master (
    id smallint NOT NULL,
    queue_name character varying(100) NOT NULL,
    identifier character(50) NOT NULL,
    status smallint DEFAULT 1 NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    created_by bigint,
    updated_at timestamp without time zone,
    updated_by bigint,
    exchange_name character varying,
    producer character(20),
    consumer character(20)
);


ALTER TABLE message_queue.queues_master OWNER TO postgres;

--
-- TOC entry 380 (class 1259 OID 920945)
-- Name: queues_master_id_seq; Type: SEQUENCE; Schema: message_queue; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS message_queue.queues_master_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 32767
    CACHE 1;


ALTER SEQUENCE message_queue.queues_master_id_seq OWNER TO postgres;

--
-- TOC entry 6199 (class 0 OID 0)
-- Dependencies: 380
-- Name: queues_master_id_seq; Type: SEQUENCE OWNED BY; Schema: message_queue; Owner: postgres
--

ALTER SEQUENCE message_queue.queues_master_id_seq OWNED BY message_queue.queues_master.id;


--
-- TOC entry 381 (class 1259 OID 920946)
-- Name: bill_ecs_neft_details; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.bill_ecs_neft_details (
    id bigint,
    bill_id bigint,
    payee_name character varying(100),
    beneficiary_id character varying(100),
    payee_type character(2),
    pan_no character(10),
    contact_number character(15),
    beneficiary_type character(2),
    address character varying(200),
    email character varying(60),
    ifsc_code character(11),
    account_type smallint,
    bank_account_number character(20),
    bank_name character varying(50),
    amount bigint,
    status smallint,
    is_active smallint,
    created_by_userid bigint,
    created_at timestamp without time zone,
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    e_pradan_id bigint,
    financial_year smallint,
    is_cancelled boolean,
    is_gst boolean
);


ALTER TABLE public.bill_ecs_neft_details OWNER TO postgres;

--
-- TOC entry 382 (class 1259 OID 920951)
-- Name: bill_status_info_2425; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.bill_status_info_2425 (
    bill_id bigint,
    name character varying,
    date_time timestamp without time zone,
    user_id bigint,
    status_id integer
);


ALTER TABLE public.bill_status_info_2425 OWNER TO postgres;

--
-- TOC entry 383 (class 1259 OID 920956)
-- Name: cts_failed_transaction_beneficiary; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.cts_failed_transaction_beneficiary (
    id bigint,
    transaction_lot_id bigint,
    transaction_lot_ben_id bigint,
    entity_id bigint,
    entity_name character varying,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(18),
    ifsc_code character(11),
    bank_name character varying,
    is_corrected smallint,
    created_by_userid bigint,
    created_at timestamp without time zone,
    corrected_by bigint,
    corrected_at timestamp without time zone,
    status smallint,
    financial_year smallint,
    failed_transaction_amount bigint,
    beneficiary_id bigint,
    module_id smallint,
    failed_code character(200),
    is_gst boolean,
    accepted_at timestamp without time zone,
    challan_major_head character(4),
    challan_no integer,
    challan_date date,
    challan_ref_no character varying(15),
    rbi_book_date date
);


ALTER TABLE public.cts_failed_transaction_beneficiary OWNER TO postgres;

--
-- TOC entry 384 (class 1259 OID 920961)
-- Name: cts_failed_transaction_beneficiary_1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.cts_failed_transaction_beneficiary_1 (
    id bigint,
    transaction_lot_id bigint,
    transaction_lot_ben_id bigint,
    entity_id bigint,
    entity_name character varying,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(18),
    ifsc_code character(11),
    bank_name character varying,
    is_corrected smallint,
    created_by_userid bigint,
    created_at timestamp without time zone,
    corrected_by bigint,
    corrected_at timestamp without time zone,
    status smallint,
    financial_year smallint,
    failed_transaction_amount bigint,
    beneficiary_id bigint,
    module_id smallint,
    failed_code character(200),
    is_gst boolean,
    accepted_at timestamp without time zone,
    challan_major_head character(4),
    challan_no integer,
    challan_date date,
    challan_ref_no character varying(15),
    rbi_book_date date
);


ALTER TABLE public.cts_failed_transaction_beneficiary_1 OWNER TO postgres;

--
-- TOC entry 385 (class 1259 OID 920966)
-- Name: cts_success_transaction_beneficiarys; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.cts_success_transaction_beneficiarys (
    id bigint,
    transaction_lot_id bigint,
    transaction_lot_ben_id bigint,
    ben_ecs_id bigint,
    entity_name character varying,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(18),
    ifsc_code character(11),
    bank_name character varying,
    created_by_userid bigint,
    created_at timestamp without time zone,
    status smallint,
    financial_year smallint,
    amount bigint,
    beneficiary_id character varying(50),
    module_id smallint,
    utr_no character(22),
    end_to_end_id character(29),
    is_gst boolean,
    accepted_at timestamp without time zone,
    entity_id bigint,
    rbi_book_date date
);


ALTER TABLE public.cts_success_transaction_beneficiarys OWNER TO postgres;

--
-- TOC entry 386 (class 1259 OID 920971)
-- Name: cts_success_transaction_beneficiarys_1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.cts_success_transaction_beneficiarys_1 (
    id bigint,
    transaction_lot_id bigint,
    transaction_lot_ben_id bigint,
    ben_ecs_id bigint,
    entity_name character varying,
    treasury_code character(3),
    ddo_code character(9),
    payee_name character varying(100),
    account_no character(18),
    ifsc_code character(11),
    bank_name character varying,
    created_by_userid bigint,
    created_at timestamp without time zone,
    status smallint,
    financial_year smallint,
    amount bigint,
    beneficiary_id character varying(50),
    module_id smallint,
    utr_no character(22),
    end_to_end_id character(29),
    is_gst boolean,
    accepted_at timestamp without time zone,
    entity_id bigint,
    rbi_book_date date
);


ALTER TABLE public.cts_success_transaction_beneficiarys_1 OWNER TO postgres;

--
-- TOC entry 387 (class 1259 OID 920976)
-- Name: ebill_jit_int_map_bk_01102025; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.ebill_jit_int_map_bk_01102025 (
    bill_id bigint,
    jit_ref_no character varying(50),
    error_details jsonb,
    payee_error_details jsonb,
    org_error_details jsonb,
    org_cleaned_json jsonb
);


ALTER TABLE public.ebill_jit_int_map_bk_01102025 OWNER TO postgres;

--
-- TOC entry 388 (class 1259 OID 920981)
-- Name: ebilling_jit_voucher; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.ebilling_jit_voucher (
    id bigint NOT NULL,
    bill_id bigint,
    voucher_no bigint,
    voucher_date date,
    voucher_amount numeric(15,2),
    major_head character varying(4),
    ref_no character varying(50),
    is_active boolean DEFAULT true NOT NULL,
    created_by character varying,
    created_at timestamp without time zone DEFAULT now(),
    updated_by character varying,
    updated_at timestamp without time zone
);


ALTER TABLE public.ebilling_jit_voucher OWNER TO postgres;

--
-- TOC entry 389 (class 1259 OID 920988)
-- Name: ebilling_jit_voucher_id_seq1; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE IF NOT EXISTS public.ebilling_jit_voucher_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.ebilling_jit_voucher_id_seq1 OWNER TO postgres;

--
-- TOC entry 6200 (class 0 OID 0)
-- Dependencies: 389
-- Name: ebilling_jit_voucher_id_seq1; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.ebilling_jit_voucher_id_seq1 OWNED BY public.ebilling_jit_voucher.id;


--
-- TOC entry 390 (class 1259 OID 920989)
-- Name: failed_beneficiary_2425; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.failed_beneficiary_2425 (
    bill_id bigint,
    treasury_code character(3),
    ddo_code character(9),
    financial_year smallint,
    payee_name character varying(100),
    account_no text,
    ifsc_code character(11),
    bank_name character varying,
    failed_transaction_amount bigint,
    beneficiary_id character varying(50),
    ecs_id bigint,
    end_to_end_id character(29),
    utr_no character(22),
    accepted_at timestamp without time zone,
    jit_reference_no character varying,
    agency_code character varying,
    failed_reason_code text,
    failed_reason_desc text,
    is_gst boolean,
    challan_major_head character(4),
    challan_no integer,
    challan_date date,
    challan_cert_no text,
    cancellation_date date
);


ALTER TABLE public.failed_beneficiary_2425 OWNER TO postgres;

--
-- TOC entry 391 (class 1259 OID 920994)
-- Name: failed_ecs_end_to_end_id; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.failed_ecs_end_to_end_id (
    id bigint,
    end_to_end_id character varying(29),
    file_number character varying(32)
);


ALTER TABLE public.failed_ecs_end_to_end_id OWNER TO postgres;

--
-- TOC entry 392 (class 1259 OID 920997)
-- Name: failed_utr_no; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.failed_utr_no (
    id bigint,
    end_to_end_id character varying(29),
    utr_no character varying(22)
);


ALTER TABLE public.failed_utr_no OWNER TO postgres;

--
-- TOC entry 393 (class 1259 OID 921000)
-- Name: jit_success_20250708; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.jit_success_20250708 (
    ref_no character varying(100),
    end_to_end_id character varying(150)
);


ALTER TABLE public.jit_success_20250708 OWNER TO postgres;

--
-- TOC entry 394 (class 1259 OID 921003)
-- Name: jit_voucher_29072025; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.jit_voucher_29072025 (
    bill_id bigint
);


ALTER TABLE public.jit_voucher_29072025 OWNER TO postgres;

--
-- TOC entry 395 (class 1259 OID 921006)
-- Name: match_success_02062025; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.match_success_02062025 (
    end_to_end_id character varying(150),
    gross_amount numeric(12,2)
);


ALTER TABLE public.match_success_02062025 OWNER TO postgres;

--
-- TOC entry 396 (class 1259 OID 921009)
-- Name: message_queue_wbjit_cts_billing_success_beneficiary; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.message_queue_wbjit_cts_billing_success_beneficiary (
    unique_id uuid,
    exchange_name character varying(100),
    queue_name character varying(100),
    message_body jsonb,
    queue_options jsonb,
    created_at timestamp without time zone,
    publish_at timestamp without time zone
);


ALTER TABLE public.message_queue_wbjit_cts_billing_success_beneficiary OWNER TO postgres;

--
-- TOC entry 397 (class 1259 OID 921014)
-- Name: process_failed_ben_success_31052025; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.process_failed_ben_success_31052025 (
    "?column?" text
);


ALTER TABLE public.process_failed_ben_success_31052025 OWNER TO postgres;

--
-- TOC entry 398 (class 1259 OID 921019)
-- Name: result_payload; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.result_payload (
    jsonb_agg jsonb
);


ALTER TABLE public.result_payload OWNER TO postgres;

--
-- TOC entry 399 (class 1259 OID 921024)
-- Name: success_beneficiary_2425; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.success_beneficiary_2425 (
    bill_id bigint,
    treasury_code character(3),
    ddo_code character(9),
    financial_year smallint,
    payee_name character varying(100),
    account_no text,
    ifsc_code character(11),
    bank_name character varying,
    amount bigint,
    beneficiary_id character varying(50),
    ecs_id bigint,
    end_to_end_id character(29),
    utr_no text,
    accepted_at timestamp without time zone,
    jit_reference_no character varying,
    agency_code character varying,
    is_gst boolean
);


ALTER TABLE public.success_beneficiary_2425 OWNER TO postgres;

--
-- TOC entry 400 (class 1259 OID 921029)
-- Name: success_ecs_end_to_end_id; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.success_ecs_end_to_end_id (
    id bigint,
    end_to_end_id character varying(29),
    file_number character varying(32)
);


ALTER TABLE public.success_ecs_end_to_end_id OWNER TO postgres;

--
-- TOC entry 401 (class 1259 OID 921032)
-- Name: test; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.test (
    now timestamp with time zone
);


ALTER TABLE public.test OWNER TO postgres;

--
-- TOC entry 402 (class 1259 OID 921035)
-- Name: tr_26a; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.tr_26a (
    id integer,
    bill_id bigint,
    bill_mode smallint,
    tr_master_id smallint,
    status smallint,
    is_deleted smallint,
    created_by_userid bigint,
    created_at timestamp without time zone,
    updated_by_userid bigint,
    updated_at timestamp without time zone,
    is_scheduled boolean,
    voucher_details_object jsonb,
    pl_detail_object jsonb,
    reissue_amount bigint,
    topup_amount bigint,
    total_amt_for_cs_calc_sc bigint,
    total_amt_for_cs_calc_scoc bigint,
    total_amt_for_cs_calc_sccc bigint,
    total_amt_for_cs_calc_scsal bigint,
    total_amt_for_cs_calc_st bigint,
    total_amt_for_cs_calc_stoc bigint,
    total_amt_for_cs_calc_stcc bigint,
    total_amt_for_cs_calc_stsal bigint,
    total_amt_for_cs_calc_ot bigint,
    total_amt_for_cs_calc_otoc bigint,
    total_amt_for_cs_calc_otcc bigint,
    total_amt_for_cs_calc_otsal bigint,
    category_code character varying,
    hoa_id bigint
);


ALTER TABLE public.tr_26a OWNER TO postgres;

--
-- TOC entry 403 (class 1259 OID 921040)
-- Name: tsa_exp_sanction_details; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.tsa_exp_sanction_details (
    refno character varying NOT NULL,
    debitamt numeric(15,2),
    limitcode bigint,
    hoaid bigint,
    sanctionno character varying(38),
    sanctiondate timestamp without time zone,
    sanctionamt numeric(15,0),
    is_deleted boolean NOT NULL
);


ALTER TABLE public.tsa_exp_sanction_details OWNER TO postgres;

--
-- TOC entry 404 (class 1259 OID 921045)
-- Name: voucher_2526_171025; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.voucher_2526_171025 (
    id bigint,
    voucher_no integer,
    voucher_date date,
    major_head character(4),
    amount bigint,
    financial_year_id smallint,
    bill_id bigint,
    token_id bigint,
    treasury_code character(3),
    status smallint,
    created_at timestamp without time zone
);


ALTER TABLE public.voucher_2526_171025 OWNER TO postgres;

--
-- TOC entry 405 (class 1259 OID 921048)
-- Name: voucher_payload; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS public.voucher_payload (
    json_agg json
);


ALTER TABLE public.voucher_payload OWNER TO postgres;

--
-- TOC entry 406 (class 1259 OID 921053)
-- Name: failed_success_ben_report_view; Type: TABLE; Schema: report; Owner: postgres
--

CREATE TABLE IF NOT EXISTS report.failed_success_ben_report_view (
    bill_id bigint,
    ddo_code character(9),
    bill_type character(15),
    bill_date date,
    hoa character varying,
    description character varying,
    department character(100),
    bill_no character(15),
    bill_reference_no character varying,
    scheme_code character(50),
    scheme_name character(300),
    active_hoa_id bigint,
    ben_amount numeric,
    payee_name character varying,
    payee_end_to_end_id character varying,
    status character varying,
    agency_code character varying,
    agency_name character(300),
    jit_reference_no character varying,
    fin_year character(9),
    fin_year_id smallint,
    token_number bigint
);


ALTER TABLE report.failed_success_ben_report_view OWNER TO postgres;

--
-- TOC entry 5384 (class 0 OID 0)
-- Name: audit_log_2025_05; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_05 FOR VALUES FROM ('2025-05-01 00:00:00') TO ('2025-06-01 00:00:00');


--
-- TOC entry 5385 (class 0 OID 0)
-- Name: audit_log_2025_06; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_06 FOR VALUES FROM ('2025-06-01 00:00:00') TO ('2025-07-01 00:00:00');


--
-- TOC entry 5386 (class 0 OID 0)
-- Name: audit_log_2025_07; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_07 FOR VALUES FROM ('2025-07-01 00:00:00') TO ('2025-08-01 00:00:00');


--
-- TOC entry 5387 (class 0 OID 0)
-- Name: audit_log_2025_08; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_08 FOR VALUES FROM ('2025-08-01 00:00:00') TO ('2025-09-01 00:00:00');


--
-- TOC entry 5388 (class 0 OID 0)
-- Name: audit_log_2025_09; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_09 FOR VALUES FROM ('2025-09-01 00:00:00') TO ('2025-10-01 00:00:00');


--
-- TOC entry 5389 (class 0 OID 0)
-- Name: audit_log_2025_10; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_10 FOR VALUES FROM ('2025-10-01 00:00:00') TO ('2025-11-01 00:00:00');


--
-- TOC entry 5390 (class 0 OID 0)
-- Name: audit_log_2025_11; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_11 FOR VALUES FROM ('2025-11-01 00:00:00') TO ('2025-12-01 00:00:00');


--
-- TOC entry 5391 (class 0 OID 0)
-- Name: audit_log_2025_12; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2025_12 FOR VALUES FROM ('2025-12-01 00:00:00') TO ('2026-01-01 00:00:00');


--
-- TOC entry 5392 (class 0 OID 0)
-- Name: audit_log_2026_01; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2026_01 FOR VALUES FROM ('2026-01-01 00:00:00') TO ('2026-02-01 00:00:00');


--
-- TOC entry 5393 (class 0 OID 0)
-- Name: audit_log_2026_02; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2026_02 FOR VALUES FROM ('2026-02-01 00:00:00') TO ('2026-03-01 00:00:00');


--
-- TOC entry 5394 (class 0 OID 0)
-- Name: audit_log_2026_03; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2026_03 FOR VALUES FROM ('2026-03-01 00:00:00') TO ('2026-04-01 00:00:00');


--
-- TOC entry 5395 (class 0 OID 0)
-- Name: audit_log_2026_04; Type: TABLE ATTACH; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log ATTACH PARTITION billing_log.audit_log_2026_04 FOR VALUES FROM ('2026-04-01 00:00:00') TO ('2026-04-30 00:00:00');


--
-- TOC entry 5406 (class 2604 OID 921058)
-- Name: ddo_wallet id; Type: DEFAULT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet ALTER COLUMN id SET DEFAULT nextval('bantan.ddo_wallet_id_seq'::regclass);


--
-- TOC entry 5438 (class 2604 OID 921059)
-- Name: bill_btdetail id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail ALTER COLUMN id SET DEFAULT nextval('billing.bill_btdetail_id_seq'::regclass);


--
-- TOC entry 5416 (class 2604 OID 921060)
-- Name: bill_details bill_id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details ALTER COLUMN bill_id SET DEFAULT nextval('billing.bill_details_bill_id_seq'::regclass);


--
-- TOC entry 5442 (class 2604 OID 921061)
-- Name: bill_ecs_neft_details id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_ecs_neft_details ALTER COLUMN id SET DEFAULT nextval('billing.ecs_neft_details_id_seq'::regclass);


--
-- TOC entry 5439 (class 2604 OID 921062)
-- Name: bill_gst id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_gst ALTER COLUMN id SET DEFAULT nextval('billing.bill_cpin_mapping_id_seq'::regclass);


--
-- TOC entry 5448 (class 2604 OID 921063)
-- Name: bill_jit_components id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_jit_components ALTER COLUMN id SET DEFAULT nextval('billing.bill_jit_components_id_seq'::regclass);


--
-- TOC entry 5449 (class 2604 OID 921064)
-- Name: bill_status_info id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_status_info ALTER COLUMN id SET DEFAULT nextval('billing.bill_status_info_id_seq'::regclass);


--
-- TOC entry 5451 (class 2604 OID 921065)
-- Name: bill_subdetail_info id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info ALTER COLUMN id SET DEFAULT nextval('billing.bill_subdetail_info_id_seq'::regclass);


--
-- TOC entry 5452 (class 2604 OID 921066)
-- Name: billing_pfms_file_status_details id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.billing_pfms_file_status_details ALTER COLUMN id SET DEFAULT nextval('billing.billing_pfms_file_status_details_id_seq'::regclass);


--
-- TOC entry 5455 (class 2604 OID 921067)
-- Name: ddo_allotment_booked_bill id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill ALTER COLUMN id SET DEFAULT nextval('billing.ddo_allotment_booked_bill_id_seq'::regclass);


--
-- TOC entry 5436 (class 2604 OID 921068)
-- Name: jit_ecs_additional id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_ecs_additional ALTER COLUMN id SET DEFAULT nextval('billing.jit_ecs_additional_id_seq'::regclass);


--
-- TOC entry 5464 (class 2604 OID 921069)
-- Name: jit_fto_voucher id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_fto_voucher ALTER COLUMN id SET DEFAULT nextval('billing.jit_fto_voucher_id_seq'::regclass);


--
-- TOC entry 5469 (class 2604 OID 921070)
-- Name: returned_memo_generated_bill id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.returned_memo_generated_bill ALTER COLUMN id SET DEFAULT nextval('billing.returned_memo_generated_bill_id_seq'::regclass);


--
-- TOC entry 5479 (class 2604 OID 921071)
-- Name: tr_26a_detail id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_26a_detail ALTER COLUMN id SET DEFAULT nextval('billing.tr_detail_id_seq'::regclass);


--
-- TOC entry 5480 (class 2604 OID 921072)
-- Name: tr_26a_detail status; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_26a_detail ALTER COLUMN status SET DEFAULT 1;


--
-- TOC entry 5481 (class 2604 OID 921073)
-- Name: tr_26a_detail created_at; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_26a_detail ALTER COLUMN created_at SET DEFAULT now();


--
-- TOC entry 5470 (class 2604 OID 921074)
-- Name: tr_detail id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_detail ALTER COLUMN id SET DEFAULT nextval('billing.tr_detail_id_seq'::regclass);


--
-- TOC entry 5509 (class 2604 OID 921075)
-- Name: ddo_log id; Type: DEFAULT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.ddo_log ALTER COLUMN id SET DEFAULT nextval('billing_log.ddo_log_id_seq'::regclass);


--
-- TOC entry 5510 (class 2604 OID 921076)
-- Name: ebill_jit_int_map_log id; Type: DEFAULT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.ebill_jit_int_map_log ALTER COLUMN id SET DEFAULT nextval('billing_log.ebill_jit_int_map_log_id_seq'::regclass);


--
-- TOC entry 5514 (class 2604 OID 921077)
-- Name: scheme_config_master_log id; Type: DEFAULT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.scheme_config_master_log ALTER COLUMN id SET DEFAULT nextval('billing_log.scheme_config_master_log_id_seq'::regclass);


--
-- TOC entry 5519 (class 2604 OID 921078)
-- Name: rbi_gst_master id; Type: DEFAULT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.rbi_gst_master ALTER COLUMN id SET DEFAULT nextval('billing_master.rbi_gst_master_id_seq'::regclass);


--
-- TOC entry 5524 (class 2604 OID 921079)
-- Name: failed_transaction_beneficiary id; Type: DEFAULT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary ALTER COLUMN id SET DEFAULT nextval('cts.failed_transaction_beneficiary_id_seq'::regclass);


--
-- TOC entry 5531 (class 2604 OID 921080)
-- Name: success_transaction_beneficiary id; Type: DEFAULT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary ALTER COLUMN id SET DEFAULT nextval('cts.success_transaction_beneficiary_id_seq'::regclass);


--
-- TOC entry 5546 (class 2604 OID 921081)
-- Name: voucher id; Type: DEFAULT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.voucher ALTER COLUMN id SET DEFAULT nextval('cts.voucher_id_seq1'::regclass);


--
-- TOC entry 5549 (class 2604 OID 921082)
-- Name: ddo_agency_mapping_details id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.ddo_agency_mapping_details ALTER COLUMN id SET DEFAULT nextval('jit.ddo_agency_mapping_details_id_seq'::regclass);


--
-- TOC entry 5551 (class 2604 OID 921083)
-- Name: exp_payee_components id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.exp_payee_components ALTER COLUMN id SET DEFAULT nextval('jit.exp_payee_components_id_seq'::regclass);


--
-- TOC entry 5552 (class 2604 OID 921084)
-- Name: fto_voucher id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.fto_voucher ALTER COLUMN id SET DEFAULT nextval('jit.fto_voucher_id_seq'::regclass);


--
-- TOC entry 5540 (class 2604 OID 921085)
-- Name: gst id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.gst ALTER COLUMN id SET DEFAULT nextval('jit.gst_id_seq'::regclass);


--
-- TOC entry 5553 (class 2604 OID 921086)
-- Name: jit_allotment id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment ALTER COLUMN id SET DEFAULT nextval('jit.jit_allotment_id_seq'::regclass);


--
-- TOC entry 5555 (class 2604 OID 921087)
-- Name: jit_fto_sanction_booking id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_fto_sanction_booking ALTER COLUMN id SET DEFAULT nextval('jit.jit_fto_sanction_booking_id_seq'::regclass);


--
-- TOC entry 5557 (class 2604 OID 921088)
-- Name: jit_pullback_request id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_pullback_request ALTER COLUMN id SET DEFAULT nextval('jit.jit_pullback_request_id_seq'::regclass);


--
-- TOC entry 5558 (class 2604 OID 921089)
-- Name: jit_report_details id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_report_details ALTER COLUMN id SET DEFAULT nextval('jit.jit_report_details_id_seq'::regclass);


--
-- TOC entry 5566 (class 2604 OID 921090)
-- Name: jit_withdrawl id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl ALTER COLUMN id SET DEFAULT nextval('jit.jit_withdrawl_id_seq'::regclass);


--
-- TOC entry 5569 (class 2604 OID 921091)
-- Name: mother_sanction_allocation id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.mother_sanction_allocation ALTER COLUMN id SET DEFAULT nextval('jit.mother_sanction_allocation_id_seq'::regclass);


--
-- TOC entry 5571 (class 2604 OID 921092)
-- Name: payee_deduction id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.payee_deduction ALTER COLUMN id SET DEFAULT nextval('jit.payee_deduction_id_seq'::regclass);


--
-- TOC entry 5572 (class 2604 OID 921093)
-- Name: scheme_config_master id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.scheme_config_master ALTER COLUMN id SET DEFAULT nextval('jit.scheme_config_master_id_seq'::regclass);


--
-- TOC entry 5575 (class 2604 OID 921094)
-- Name: tsa_exp_details id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_exp_details ALTER COLUMN id SET DEFAULT nextval('jit.tsa_exp_details_id_seq'::regclass);


--
-- TOC entry 5582 (class 2604 OID 921095)
-- Name: tsa_payeemaster id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_payeemaster ALTER COLUMN id SET DEFAULT nextval('jit.tsa_payeemaster_id_seq'::regclass);


--
-- TOC entry 5584 (class 2604 OID 921096)
-- Name: tsa_schemecomponent id; Type: DEFAULT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_schemecomponent ALTER COLUMN id SET DEFAULT nextval('jit.tsa_schemecomponent_id_seq'::regclass);


--
-- TOC entry 5585 (class 2604 OID 921097)
-- Name: bank_type_master id; Type: DEFAULT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.bank_type_master ALTER COLUMN id SET DEFAULT nextval('master.bank_type_master_id_seq'::regclass);


--
-- TOC entry 5587 (class 2604 OID 921098)
-- Name: ddo id; Type: DEFAULT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.ddo ALTER COLUMN id SET DEFAULT nextval('master.ddo_id_seq'::regclass);


--
-- TOC entry 5589 (class 2604 OID 921099)
-- Name: treasury id; Type: DEFAULT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.treasury ALTER COLUMN id SET DEFAULT nextval('master.treasury_id_seq'::regclass);


--
-- TOC entry 5590 (class 2604 OID 921100)
-- Name: tsa_vendor_type id; Type: DEFAULT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.tsa_vendor_type ALTER COLUMN id SET DEFAULT nextval('master.tsa_vendor_type_id_seq'::regclass);


--
-- TOC entry 5593 (class 2604 OID 921101)
-- Name: consume_logs id; Type: DEFAULT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.consume_logs ALTER COLUMN id SET DEFAULT nextval('message_queue.consume_logs_id_seq'::regclass);


--
-- TOC entry 5600 (class 2604 OID 921102)
-- Name: queues_master id; Type: DEFAULT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.queues_master ALTER COLUMN id SET DEFAULT nextval('message_queue.queues_master_id_seq'::regclass);


--
-- TOC entry 5603 (class 2604 OID 921103)
-- Name: ebilling_jit_voucher id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ebilling_jit_voucher ALTER COLUMN id SET DEFAULT nextval('public.ebilling_jit_voucher_id_seq1'::regclass);


--
-- TOC entry 5609 (class 2606 OID 1008585)
-- Name: ddo_allotment_transactions ddo_allotment_transactions_memo_number_sender_sao_ddo_code__key; Type: CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_allotment_transactions
    ADD CONSTRAINT ddo_allotment_transactions_memo_number_sender_sao_ddo_code__key UNIQUE (memo_number, sender_sao_ddo_code, receiver_sao_ddo_code);


--
-- TOC entry 5611 (class 2606 OID 1008686)
-- Name: ddo_allotment_transactions ddo_allotment_transactions_pkey; Type: CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_allotment_transactions
    ADD CONSTRAINT ddo_allotment_transactions_pkey PRIMARY KEY (allotment_id);


--
-- TOC entry 5613 (class 2606 OID 1008703)
-- Name: ddo_wallet ddo_wallet_pkey; Type: CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet
    ADD CONSTRAINT ddo_wallet_pkey PRIMARY KEY (id);


--
-- TOC entry 5615 (class 2606 OID 1008721)
-- Name: ddo_wallet ddo_wallet_sao_ddo_code_active_hoa_id_financial_year_key; Type: CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet
    ADD CONSTRAINT ddo_wallet_sao_ddo_code_active_hoa_id_financial_year_key UNIQUE (sao_ddo_code, active_hoa_id, financial_year);


--
-- TOC entry 5625 (class 2606 OID 1008736)
-- Name: bill_btdetail bill_btdetail_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail
    ADD CONSTRAINT bill_btdetail_pkey PRIMARY KEY (id);


--
-- TOC entry 5628 (class 2606 OID 1008770)
-- Name: bill_gst bill_cpin_mapping_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_gst
    ADD CONSTRAINT bill_cpin_mapping_pkey PRIMARY KEY (id);


--
-- TOC entry 5618 (class 2606 OID 1008774)
-- Name: bill_details bill_details_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_pkey PRIMARY KEY (bill_id);


--
-- TOC entry 5630 (class 2606 OID 1008941)
-- Name: bill_ecs_neft_details bill_ecs_neft_details_bill_id_bank_account_number_key; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_ecs_neft_details
    ADD CONSTRAINT bill_ecs_neft_details_bill_id_bank_account_number_key UNIQUE (bill_id, bank_account_number);


--
-- TOC entry 5632 (class 2606 OID 1010763)
-- Name: bill_ecs_neft_details bill_ecs_neft_details_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_ecs_neft_details
    ADD CONSTRAINT bill_ecs_neft_details_pkey PRIMARY KEY (id);


--
-- TOC entry 5636 (class 2606 OID 1011300)
-- Name: bill_jit_components bill_jit_components_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_jit_components
    ADD CONSTRAINT bill_jit_components_pkey PRIMARY KEY (id);


--
-- TOC entry 5640 (class 2606 OID 1011695)
-- Name: bill_status_info bill_status_info_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_status_info
    ADD CONSTRAINT bill_status_info_pkey PRIMARY KEY (id);


--
-- TOC entry 5642 (class 2606 OID 1012164)
-- Name: bill_subdetail_info bill_subdetail_info_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info
    ADD CONSTRAINT bill_subdetail_info_pkey PRIMARY KEY (id);


--
-- TOC entry 5645 (class 2606 OID 1012271)
-- Name: billing_pfms_file_status_details billing_pfms_file_status_details_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.billing_pfms_file_status_details
    ADD CONSTRAINT billing_pfms_file_status_details_pkey PRIMARY KEY (id);


--
-- TOC entry 5647 (class 2606 OID 1012399)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_pkey PRIMARY KEY (id);


--
-- TOC entry 5649 (class 2606 OID 1012484)
-- Name: ebill_jit_int_map ebill_jit_int_map_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ebill_jit_int_map
    ADD CONSTRAINT ebill_jit_int_map_pkey PRIMARY KEY (id);


--
-- TOC entry 5622 (class 2606 OID 1012661)
-- Name: jit_ecs_additional jit_ecs_additional_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_ecs_additional
    ADD CONSTRAINT jit_ecs_additional_pkey PRIMARY KEY (id);


--
-- TOC entry 5657 (class 2606 OID 1012881)
-- Name: jit_fto_voucher jit_fto_voucher_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_fto_voucher
    ADD CONSTRAINT jit_fto_voucher_pkey PRIMARY KEY (id);


--
-- TOC entry 5660 (class 2606 OID 1012883)
-- Name: notification notification_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.notification
    ADD CONSTRAINT notification_pkey PRIMARY KEY (id);


--
-- TOC entry 5662 (class 2606 OID 1013097)
-- Name: returned_memo_generated_bill returned_memo_generated_bill_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.returned_memo_generated_bill
    ADD CONSTRAINT returned_memo_generated_bill_pkey PRIMARY KEY (id);


--
-- TOC entry 5667 (class 2606 OID 1013132)
-- Name: tr_10_detail tr_10_detail_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_10_detail
    ADD CONSTRAINT tr_10_detail_pkey PRIMARY KEY (id);


--
-- TOC entry 5671 (class 2606 OID 1013281)
-- Name: tr_12_detail tr_12_detail_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_12_detail
    ADD CONSTRAINT tr_12_detail_pkey PRIMARY KEY (id);


--
-- TOC entry 5676 (class 2606 OID 1013294)
-- Name: tr_26a_detail tr_26a_detail_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_26a_detail
    ADD CONSTRAINT tr_26a_detail_pkey PRIMARY KEY (id);


--
-- TOC entry 5664 (class 2606 OID 1013473)
-- Name: tr_detail tr_detail_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_detail
    ADD CONSTRAINT tr_detail_pkey PRIMARY KEY (id);


--
-- TOC entry 5669 (class 2606 OID 1013475)
-- Name: tr_10_detail unique_id_bill_tr_10; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_10_detail
    ADD CONSTRAINT unique_id_bill_tr_10 UNIQUE (bill_id, tr_master_id);


--
-- TOC entry 5673 (class 2606 OID 1013548)
-- Name: tr_12_detail unique_id_bill_tr_12; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_12_detail
    ADD CONSTRAINT unique_id_bill_tr_12 UNIQUE (bill_id, tr_master_id);


--
-- TOC entry 5678 (class 2606 OID 1013558)
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5680 (class 2606 OID 1013561)
-- Name: audit_log_2025_05 audit_log_2025_05_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_05
    ADD CONSTRAINT audit_log_2025_05_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5682 (class 2606 OID 1013569)
-- Name: audit_log_2025_06 audit_log_2025_06_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_06
    ADD CONSTRAINT audit_log_2025_06_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5684 (class 2606 OID 1013573)
-- Name: audit_log_2025_07 audit_log_2025_07_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_07
    ADD CONSTRAINT audit_log_2025_07_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5686 (class 2606 OID 1013582)
-- Name: audit_log_2025_08 audit_log_2025_08_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_08
    ADD CONSTRAINT audit_log_2025_08_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5688 (class 2606 OID 1013585)
-- Name: audit_log_2025_09 audit_log_2025_09_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_09
    ADD CONSTRAINT audit_log_2025_09_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5690 (class 2606 OID 1013593)
-- Name: audit_log_2025_10 audit_log_2025_10_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_10
    ADD CONSTRAINT audit_log_2025_10_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5692 (class 2606 OID 1013595)
-- Name: audit_log_2025_11 audit_log_2025_11_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_11
    ADD CONSTRAINT audit_log_2025_11_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5694 (class 2606 OID 1013606)
-- Name: audit_log_2025_12 audit_log_2025_12_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2025_12
    ADD CONSTRAINT audit_log_2025_12_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5696 (class 2606 OID 1013614)
-- Name: audit_log_2026_01 audit_log_2026_01_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2026_01
    ADD CONSTRAINT audit_log_2026_01_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5698 (class 2606 OID 1013625)
-- Name: audit_log_2026_02 audit_log_2026_02_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2026_02
    ADD CONSTRAINT audit_log_2026_02_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5700 (class 2606 OID 1013636)
-- Name: audit_log_2026_03 audit_log_2026_03_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2026_03
    ADD CONSTRAINT audit_log_2026_03_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5702 (class 2606 OID 1013646)
-- Name: audit_log_2026_04 audit_log_2026_04_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.audit_log_2026_04
    ADD CONSTRAINT audit_log_2026_04_pkey PRIMARY KEY (id, change_timestamp);


--
-- TOC entry 5704 (class 2606 OID 1013654)
-- Name: ddo_log ddo_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.ddo_log
    ADD CONSTRAINT ddo_pkey PRIMARY KEY (id);


--
-- TOC entry 5706 (class 2606 OID 1013660)
-- Name: ebill_jit_int_map_log ebill_jit_int_map_log_pkey; Type: CONSTRAINT; Schema: billing_log; Owner: postgres
--

ALTER TABLE ONLY billing_log.ebill_jit_int_map_log
    ADD CONSTRAINT ebill_jit_int_map_log_pkey PRIMARY KEY (id);


--
-- TOC entry 5710 (class 2606 OID 1013668)
-- Name: bill_status_master bill_status_master_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.bill_status_master
    ADD CONSTRAINT bill_status_master_pkey PRIMARY KEY (status_id);


--
-- TOC entry 5712 (class 2606 OID 1013670)
-- Name: bt_details bt_details_bt_serial_key; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.bt_details
    ADD CONSTRAINT bt_details_bt_serial_key UNIQUE (bt_serial);


--
-- TOC entry 5714 (class 2606 OID 1013685)
-- Name: bt_details bt_details_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.bt_details
    ADD CONSTRAINT bt_details_pkey PRIMARY KEY (id);


--
-- TOC entry 5716 (class 2606 OID 1013698)
-- Name: cpin_master cpin_master_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.cpin_master
    ADD CONSTRAINT cpin_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5719 (class 2606 OID 1013764)
-- Name: cpin_vender_mst cpin_vender_mst_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.cpin_vender_mst
    ADD CONSTRAINT cpin_vender_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 5721 (class 2606 OID 1013780)
-- Name: rbi_gst_master rbi_gst_master_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.rbi_gst_master
    ADD CONSTRAINT rbi_gst_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5727 (class 2606 OID 1013785)
-- Name: tr_master_checklist tr_master_checklist_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.tr_master_checklist
    ADD CONSTRAINT tr_master_checklist_pkey PRIMARY KEY (tr_master_id);


--
-- TOC entry 5723 (class 2606 OID 1013792)
-- Name: tr_master tr_master_pkey; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.tr_master
    ADD CONSTRAINT tr_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5725 (class 2606 OID 1013797)
-- Name: tr_master tr_master_wb_form_code_key; Type: CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.tr_master
    ADD CONSTRAINT tr_master_wb_form_code_key UNIQUE (wb_form_code);


--
-- TOC entry 5738 (class 2606 OID 1013801)
-- Name: challan challan_pkey; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.challan
    ADD CONSTRAINT challan_pkey PRIMARY KEY (id);


--
-- TOC entry 5729 (class 2606 OID 1013808)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_beneficiary_id_end_to_end_id_key; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_beneficiary_id_end_to_end_id_key UNIQUE (beneficiary_id, end_to_end_id);


--
-- TOC entry 5731 (class 2606 OID 1013818)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_pkey; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_pkey PRIMARY KEY (id);


--
-- TOC entry 5740 (class 2606 OID 1013820)
-- Name: failed_transaction_beneficiary_bk failed_transaction_beneficiary_pkey_bk; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary_bk
    ADD CONSTRAINT failed_transaction_beneficiary_pkey_bk PRIMARY KEY (id);


--
-- TOC entry 5734 (class 2606 OID 1013828)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_ecs_id_end_to_end_id_key; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_ecs_id_end_to_end_id_key UNIQUE (ecs_id, end_to_end_id);


--
-- TOC entry 5736 (class 2606 OID 1014551)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_pkey; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_pkey PRIMARY KEY (id);


--
-- TOC entry 5744 (class 2606 OID 1014922)
-- Name: success_transaction_beneficiary_bk success_transaction_beneficiary_pkey_bk; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary_bk
    ADD CONSTRAINT success_transaction_beneficiary_pkey_bk PRIMARY KEY (id);


--
-- TOC entry 5746 (class 2606 OID 1015150)
-- Name: token token_n_entity_id_key; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.token
    ADD CONSTRAINT token_n_entity_id_key UNIQUE (entity_id);


--
-- TOC entry 5748 (class 2606 OID 1015257)
-- Name: token token_n_pkey; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.token
    ADD CONSTRAINT token_n_pkey PRIMARY KEY (id);


--
-- TOC entry 5750 (class 2606 OID 1015305)
-- Name: voucher voucher_bill_id_key; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.voucher
    ADD CONSTRAINT voucher_bill_id_key UNIQUE (bill_id);


--
-- TOC entry 5752 (class 2606 OID 1015396)
-- Name: voucher voucher_pkey1; Type: CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.voucher
    ADD CONSTRAINT voucher_pkey1 PRIMARY KEY (id);


--
-- TOC entry 5754 (class 2606 OID 1015433)
-- Name: ddo_agency_mapping_details ddo_agency_mapping_details_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.ddo_agency_mapping_details
    ADD CONSTRAINT ddo_agency_mapping_details_pkey PRIMARY KEY (id);


--
-- TOC entry 5756 (class 2606 OID 1015442)
-- Name: exp_payee_components exp_payee_components_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.exp_payee_components
    ADD CONSTRAINT exp_payee_components_pkey PRIMARY KEY (id);


--
-- TOC entry 5758 (class 2606 OID 1015886)
-- Name: fto_voucher fto_voucher_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.fto_voucher
    ADD CONSTRAINT fto_voucher_pkey PRIMARY KEY (id);


--
-- TOC entry 5742 (class 2606 OID 1016274)
-- Name: gst gst_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.gst
    ADD CONSTRAINT gst_pkey PRIMARY KEY (id);


--
-- TOC entry 5760 (class 2606 OID 1016304)
-- Name: jit_allotment jit_allotment_ddo_code_sanction_no_agency_code_key; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment
    ADD CONSTRAINT jit_allotment_ddo_code_sanction_no_agency_code_key UNIQUE (ddo_code, sanction_no, agency_code);


--
-- TOC entry 5762 (class 2606 OID 1016414)
-- Name: jit_allotment jit_allotment_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment
    ADD CONSTRAINT jit_allotment_pkey PRIMARY KEY (id);


--
-- TOC entry 5764 (class 2606 OID 1016433)
-- Name: jit_fto_sanction_booking jit_fto_sanction_booking_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_fto_sanction_booking
    ADD CONSTRAINT jit_fto_sanction_booking_pkey PRIMARY KEY (id);


--
-- TOC entry 5766 (class 2606 OID 1016494)
-- Name: jit_pullback_request jit_pullback_request_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_pullback_request
    ADD CONSTRAINT jit_pullback_request_pkey PRIMARY KEY (id);


--
-- TOC entry 5768 (class 2606 OID 1016501)
-- Name: jit_report_details jit_report_details_ddo_code_hoa_id_key; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_report_details
    ADD CONSTRAINT jit_report_details_ddo_code_hoa_id_key UNIQUE (ddo_code, hoa_id);


--
-- TOC entry 5770 (class 2606 OID 1016529)
-- Name: jit_report_details jit_report_details_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_report_details
    ADD CONSTRAINT jit_report_details_pkey PRIMARY KEY (id);


--
-- TOC entry 5772 (class 2606 OID 1016543)
-- Name: jit_withdrawl jit_withdrawl_ddo_code_agency_code_sanction_no_key; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl
    ADD CONSTRAINT jit_withdrawl_ddo_code_agency_code_sanction_no_key UNIQUE (ddo_code, agency_code, sanction_no);


--
-- TOC entry 5774 (class 2606 OID 1016545)
-- Name: jit_withdrawl jit_withdrawl_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl
    ADD CONSTRAINT jit_withdrawl_pkey PRIMARY KEY (id);


--
-- TOC entry 5776 (class 2606 OID 1016553)
-- Name: mother_sanction_allocation mother_sanction_allocation_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.mother_sanction_allocation
    ADD CONSTRAINT mother_sanction_allocation_pkey PRIMARY KEY (id);


--
-- TOC entry 5778 (class 2606 OID 1016555)
-- Name: mother_sanction_allocation mother_sanction_allocation_sls_limit_distribution_id_head_w_key; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.mother_sanction_allocation
    ADD CONSTRAINT mother_sanction_allocation_sls_limit_distribution_id_head_w_key UNIQUE (sls_limit_distribution_id, head_wise_sanction_id);


--
-- TOC entry 5780 (class 2606 OID 1016558)
-- Name: payee_deduction payee_deduction_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.payee_deduction
    ADD CONSTRAINT payee_deduction_pkey PRIMARY KEY (id);


--
-- TOC entry 5782 (class 2606 OID 1016630)
-- Name: scheme_config_master scheme_config_master_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.scheme_config_master
    ADD CONSTRAINT scheme_config_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5784 (class 2606 OID 1016633)
-- Name: scheme_config_master scheme_config_master_sls_code_csscode_key; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.scheme_config_master
    ADD CONSTRAINT scheme_config_master_sls_code_csscode_key UNIQUE (sls_code, csscode);


--
-- TOC entry 5786 (class 2606 OID 1016637)
-- Name: tsa_exp_details tsa_exp_details_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_exp_details
    ADD CONSTRAINT tsa_exp_details_pkey PRIMARY KEY (id);


--
-- TOC entry 5788 (class 2606 OID 1016781)
-- Name: tsa_exp_details tsa_exp_details_unique_key_ref_no; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_exp_details
    ADD CONSTRAINT tsa_exp_details_unique_key_ref_no UNIQUE (ref_no);


--
-- TOC entry 5790 (class 2606 OID 1017066)
-- Name: tsa_payeemaster tsa_payeemaster_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_payeemaster
    ADD CONSTRAINT tsa_payeemaster_pkey PRIMARY KEY (id);


--
-- TOC entry 5792 (class 2606 OID 1017497)
-- Name: tsa_payeemaster tsa_payeemaster_ref_no_acc_no_key; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_payeemaster
    ADD CONSTRAINT tsa_payeemaster_ref_no_acc_no_key UNIQUE (ref_no, acc_no);


--
-- TOC entry 5794 (class 2606 OID 1019445)
-- Name: tsa_schemecomponent tsa_schemecomponent_pkey; Type: CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_schemecomponent
    ADD CONSTRAINT tsa_schemecomponent_pkey PRIMARY KEY (id);


--
-- TOC entry 5654 (class 2606 OID 1019820)
-- Name: active_hoa_mst active_hoa_mst_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.active_hoa_mst
    ADD CONSTRAINT active_hoa_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 5796 (class 2606 OID 1019823)
-- Name: bank_type_master bank_type_master_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.bank_type_master
    ADD CONSTRAINT bank_type_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5799 (class 2606 OID 1019835)
-- Name: ddo ddo_ddo_code_key; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.ddo
    ADD CONSTRAINT ddo_ddo_code_key UNIQUE (ddo_code);


--
-- TOC entry 5801 (class 2606 OID 1019963)
-- Name: ddo ddo_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.ddo
    ADD CONSTRAINT ddo_pkey PRIMARY KEY (id);


--
-- TOC entry 5803 (class 2606 OID 1019975)
-- Name: demand_major_mapping demand_major_mapping_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.demand_major_mapping
    ADD CONSTRAINT demand_major_mapping_pkey PRIMARY KEY (id);


--
-- TOC entry 5805 (class 2606 OID 1019977)
-- Name: department department_code_key; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.department
    ADD CONSTRAINT department_code_key UNIQUE (code);


--
-- TOC entry 5807 (class 2606 OID 1019979)
-- Name: department department_demand_code_key; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.department
    ADD CONSTRAINT department_demand_code_key UNIQUE (demand_code);


--
-- TOC entry 5809 (class 2606 OID 1019983)
-- Name: department department_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.department
    ADD CONSTRAINT department_pkey PRIMARY KEY (id);


--
-- TOC entry 5811 (class 2606 OID 1019986)
-- Name: detail_head detail_head_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.detail_head
    ADD CONSTRAINT detail_head_pkey PRIMARY KEY (id);


--
-- TOC entry 5813 (class 2606 OID 1019989)
-- Name: financial_year_master financial_year_master_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.financial_year_master
    ADD CONSTRAINT financial_year_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5815 (class 2606 OID 1019998)
-- Name: major_head major_head_code_key; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.major_head
    ADD CONSTRAINT major_head_code_key UNIQUE (code);


--
-- TOC entry 5817 (class 2606 OID 1020007)
-- Name: major_head major_head_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.major_head
    ADD CONSTRAINT major_head_pkey PRIMARY KEY (id);


--
-- TOC entry 5819 (class 2606 OID 1020011)
-- Name: minor_head minor_head_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.minor_head
    ADD CONSTRAINT minor_head_pkey PRIMARY KEY (id);


--
-- TOC entry 5822 (class 2606 OID 1020018)
-- Name: rbi_ifsc_stock rbi_ifsc_stock_ifsc_key; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.rbi_ifsc_stock
    ADD CONSTRAINT rbi_ifsc_stock_ifsc_key UNIQUE (ifsc);


--
-- TOC entry 5824 (class 2606 OID 1020886)
-- Name: rbi_ifsc_stock rbi_ifsc_stock_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.rbi_ifsc_stock
    ADD CONSTRAINT rbi_ifsc_stock_pkey PRIMARY KEY (ifsc);


--
-- TOC entry 5826 (class 2606 OID 1021807)
-- Name: scheme_head scheme_head_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.scheme_head
    ADD CONSTRAINT scheme_head_pkey PRIMARY KEY (id);


--
-- TOC entry 5828 (class 2606 OID 1022079)
-- Name: sub_detail_head sub_detail_head_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.sub_detail_head
    ADD CONSTRAINT sub_detail_head_pkey PRIMARY KEY (id);


--
-- TOC entry 5830 (class 2606 OID 1022516)
-- Name: sub_major_head sub_major_head_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.sub_major_head
    ADD CONSTRAINT sub_major_head_pkey PRIMARY KEY (id);


--
-- TOC entry 5833 (class 2606 OID 1022626)
-- Name: treasury treasury_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.treasury
    ADD CONSTRAINT treasury_pkey PRIMARY KEY (id);


--
-- TOC entry 5835 (class 2606 OID 1022953)
-- Name: treasury treasury_treasury_code_key; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.treasury
    ADD CONSTRAINT treasury_treasury_code_key UNIQUE (code);


--
-- TOC entry 5837 (class 2606 OID 1023326)
-- Name: tsa_vendor_type tsa_vendor_type_pkey; Type: CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.tsa_vendor_type
    ADD CONSTRAINT tsa_vendor_type_pkey PRIMARY KEY (id);


--
-- TOC entry 5839 (class 2606 OID 1023616)
-- Name: consume_logs consume_logs_pkey; Type: CONSTRAINT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.consume_logs
    ADD CONSTRAINT consume_logs_pkey PRIMARY KEY (id);


--
-- TOC entry 5841 (class 2606 OID 1024115)
-- Name: consume_logs_partition consume_logs_pkey1; Type: CONSTRAINT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.consume_logs_partition
    ADD CONSTRAINT consume_logs_pkey1 PRIMARY KEY (id, created_at);


--
-- TOC entry 5843 (class 2606 OID 1024123)
-- Name: message_queue_logs message_queue_logs_pkey; Type: CONSTRAINT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.message_queue_logs
    ADD CONSTRAINT message_queue_logs_pkey PRIMARY KEY (unique_id);


--
-- TOC entry 5845 (class 2606 OID 1024794)
-- Name: message_queues message_queues_pkey; Type: CONSTRAINT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.message_queues
    ADD CONSTRAINT message_queues_pkey PRIMARY KEY (unique_id);


--
-- TOC entry 5847 (class 2606 OID 1024805)
-- Name: queues_master queues_master_pkey; Type: CONSTRAINT; Schema: message_queue; Owner: postgres
--

ALTER TABLE ONLY message_queue.queues_master
    ADD CONSTRAINT queues_master_pkey PRIMARY KEY (id);


--
-- TOC entry 5849 (class 2606 OID 1024813)
-- Name: ebilling_jit_voucher ebilling_jit_voucher_pkey2; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ebilling_jit_voucher
    ADD CONSTRAINT ebilling_jit_voucher_pkey2 PRIMARY KEY (id);


--
-- TOC entry 5616 (class 1259 OID 1024814)
-- Name: bill_details_bill_id_idx; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS bill_details_bill_id_idx ON billing.bill_details USING btree (bill_id) WITH (deduplicate_items='false');


--
-- TOC entry 5637 (class 1259 OID 1024982)
-- Name: fki_bill_jit_components_bill_id_fkey; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS fki_bill_jit_components_bill_id_fkey ON billing.bill_jit_components USING btree (bill_id);


--
-- TOC entry 5620 (class 1259 OID 1025285)
-- Name: fki_jit_ecs_additional_bill_id_fkey; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS fki_jit_ecs_additional_bill_id_fkey ON billing.jit_ecs_additional USING btree (bill_id);


--
-- TOC entry 5655 (class 1259 OID 1025816)
-- Name: fki_jit_fto_voucher_bill_id_fkey; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS fki_jit_fto_voucher_bill_id_fkey ON billing.jit_fto_voucher USING btree (bill_id);


--
-- TOC entry 5650 (class 1259 OID 1025819)
-- Name: idx_ebill_jit_int_map_bill_id; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS idx_ebill_jit_int_map_bill_id ON billing.ebill_jit_int_map USING btree (bill_id);


--
-- TOC entry 5626 (class 1259 OID 1025943)
-- Name: ndx_bill_btdetail; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_bill_btdetail ON billing.bill_btdetail USING btree (bill_id);


--
-- TOC entry 5633 (class 1259 OID 1025949)
-- Name: ndx_bill_ecs_neft_details; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_bill_ecs_neft_details ON billing.bill_ecs_neft_details USING btree (bill_id);


--
-- TOC entry 5638 (class 1259 OID 1026230)
-- Name: ndx_bill_jit_components; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_bill_jit_components ON billing.bill_jit_components USING btree (bill_id);


--
-- TOC entry 5643 (class 1259 OID 1026645)
-- Name: ndx_bill_subdetail_info; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_bill_subdetail_info ON billing.bill_subdetail_info USING btree (bill_id);


--
-- TOC entry 5634 (class 1259 OID 1026704)
-- Name: ndx_ecs_id; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_ecs_id ON billing.bill_ecs_neft_details USING btree (id) WITH (deduplicate_items='false');


--
-- TOC entry 5623 (class 1259 OID 1027020)
-- Name: ndx_jit_ecs_additional; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_jit_ecs_additional ON billing.jit_ecs_additional USING btree (bill_id);


--
-- TOC entry 5658 (class 1259 OID 1027258)
-- Name: ndx_jit_fto_voucher; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_jit_fto_voucher ON billing.jit_fto_voucher USING btree (bill_id);


--
-- TOC entry 5665 (class 1259 OID 1027260)
-- Name: ndx_tr_10_detail; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_tr_10_detail ON billing.tr_10_detail USING btree (bill_id);


--
-- TOC entry 5674 (class 1259 OID 1027261)
-- Name: ndx_tr_26a_detail; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ndx_tr_26a_detail ON billing.tr_26a_detail USING btree (bill_id);


--
-- TOC entry 5651 (class 1259 OID 1027265)
-- Name: unique_active_ebill_jit_int_map; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE UNIQUE INDEX unique_active_ebill_jit_int_map ON billing.ebill_jit_int_map USING btree (jit_ref_no) WHERE ((is_active = true) AND (is_rejected = false));


--
-- TOC entry 5619 (class 1259 OID 1027941)
-- Name: unique_bill_details_active_bill_no; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE UNIQUE INDEX unique_bill_details_active_bill_no ON billing.bill_details USING btree (bill_no) WHERE (is_deleted = false);


--
-- TOC entry 5707 (class 1259 OID 1028542)
-- Name: idx_ebill_jit_int_map_log_bill_id; Type: INDEX; Schema: billing_log; Owner: postgres
--

CREATE INDEX IF NOT EXISTS idx_ebill_jit_int_map_log_bill_id ON billing_log.ebill_jit_int_map_log USING btree (bill_id);


--
-- TOC entry 5708 (class 1259 OID 1028546)
-- Name: unique_active_ebill_jit_int_map_log; Type: INDEX; Schema: billing_log; Owner: postgres
--

CREATE UNIQUE INDEX unique_active_ebill_jit_int_map_log ON billing_log.ebill_jit_int_map_log USING btree (jit_ref_no) WHERE ((is_active = true) AND (is_rejected = false));


--
-- TOC entry 5717 (class 1259 OID 1028547)
-- Name: unique_active_cpin; Type: INDEX; Schema: billing_master; Owner: postgres
--

CREATE UNIQUE INDEX unique_active_cpin ON billing_master.cpin_master USING btree (cpin_id) WHERE (is_active = true);


--
-- TOC entry 5732 (class 1259 OID 1028687)
-- Name: idx_success_trans_ben_billid_endtoendid; Type: INDEX; Schema: cts; Owner: postgres
--

CREATE INDEX IF NOT EXISTS idx_success_trans_ben_billid_endtoendid ON cts.success_transaction_beneficiary USING btree (bill_id, end_to_end_id);


--
-- TOC entry 5652 (class 1259 OID 1030160)
-- Name: active_hoa_mst_id_idx; Type: INDEX; Schema: master; Owner: postgres
--

CREATE INDEX IF NOT EXISTS active_hoa_mst_id_idx ON master.active_hoa_mst USING btree (id) WITH (deduplicate_items='true');


--
-- TOC entry 5797 (class 1259 OID 1030161)
-- Name: ddo_ddo_code_idx; Type: INDEX; Schema: master; Owner: postgres
--

CREATE INDEX IF NOT EXISTS ddo_ddo_code_idx ON master.ddo USING btree (ddo_code) WITH (deduplicate_items='true');


--
-- TOC entry 5820 (class 1259 OID 1030197)
-- Name: rbi_ifsc_stock_ifsc_idx; Type: INDEX; Schema: master; Owner: postgres
--

CREATE INDEX IF NOT EXISTS rbi_ifsc_stock_ifsc_idx ON master.rbi_ifsc_stock USING btree (ifsc) WITH (deduplicate_items='true');


--
-- TOC entry 5831 (class 1259 OID 1031087)
-- Name: treasury_code_idx; Type: INDEX; Schema: master; Owner: postgres
--

CREATE INDEX IF NOT EXISTS treasury_code_idx ON master.treasury USING btree (code) WITH (deduplicate_items='true');


--
-- TOC entry 5850 (class 0 OID 0)
-- Name: audit_log_2025_05_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_05_pkey;


--
-- TOC entry 5851 (class 0 OID 0)
-- Name: audit_log_2025_06_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_06_pkey;


--
-- TOC entry 5852 (class 0 OID 0)
-- Name: audit_log_2025_07_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_07_pkey;


--
-- TOC entry 5853 (class 0 OID 0)
-- Name: audit_log_2025_08_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_08_pkey;


--
-- TOC entry 5854 (class 0 OID 0)
-- Name: audit_log_2025_09_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_09_pkey;


--
-- TOC entry 5855 (class 0 OID 0)
-- Name: audit_log_2025_10_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_10_pkey;


--
-- TOC entry 5856 (class 0 OID 0)
-- Name: audit_log_2025_11_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_11_pkey;


--
-- TOC entry 5857 (class 0 OID 0)
-- Name: audit_log_2025_12_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2025_12_pkey;


--
-- TOC entry 5858 (class 0 OID 0)
-- Name: audit_log_2026_01_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2026_01_pkey;


--
-- TOC entry 5859 (class 0 OID 0)
-- Name: audit_log_2026_02_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2026_02_pkey;


--
-- TOC entry 5860 (class 0 OID 0)
-- Name: audit_log_2026_03_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2026_03_pkey;


--
-- TOC entry 5861 (class 0 OID 0)
-- Name: audit_log_2026_04_pkey; Type: INDEX ATTACH; Schema: billing_log; Owner: postgres
--

ALTER INDEX billing_log.audit_log_pkey ATTACH PARTITION billing_log.audit_log_2026_04_pkey;


--
-- TOC entry 6129 (class 2618 OID 920408)
-- Name: department_details_view _RETURN; Type: RULE; Schema: billing; Owner: postgres
--

CREATE OR REPLACE VIEW billing.department_details_view AS
 WITH bill_info AS (
         SELECT bd.bill_id,
            bd.ddo_code,
            bd.demand
           FROM billing.bill_details bd
          GROUP BY bd.bill_id, bd.demand
        )
 SELECT DISTINCT dept.demand_code,
    dept.name AS department_name,
    bi.ddo_code
   FROM (bill_info bi
     LEFT JOIN master.department dept ON ((dept.demand_code = bi.demand)))
  WHERE (dept.name IS NOT NULL);


--
-- TOC entry 5968 (class 2620 OID 1031089)
-- Name: ddo_allotment_transactions audit_table_changes; Type: TRIGGER; Schema: bantan; Owner: postgres
--

CREATE TRIGGER audit_table_changes AFTER INSERT OR DELETE OR UPDATE ON bantan.ddo_allotment_transactions FOR EACH ROW EXECUTE FUNCTION billing_log.log_table_changes();


--
-- TOC entry 5969 (class 2620 OID 1031090)
-- Name: ddo_wallet audit_table_changes; Type: TRIGGER; Schema: bantan; Owner: postgres
--

CREATE TRIGGER audit_table_changes AFTER INSERT OR DELETE OR UPDATE ON bantan.ddo_wallet FOR EACH ROW EXECUTE FUNCTION billing_log.log_table_changes();


--
-- TOC entry 5973 (class 2620 OID 1031091)
-- Name: bill_status_info after_bill_insert_jit_report; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER after_bill_insert_jit_report AFTER INSERT OR UPDATE ON billing.bill_status_info FOR EACH ROW EXECUTE FUNCTION billing.insert_jit_report();


--
-- TOC entry 5970 (class 2620 OID 1031092)
-- Name: bill_details after_bill_status_update; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER after_bill_status_update AFTER UPDATE OF status, is_regenerated ON billing.bill_details FOR EACH ROW WHEN ((((new.status = 106) AND (new.is_reissued = false)) OR ((new.is_regenerated = true) AND (new.is_reissued = false)))) EXECUTE FUNCTION billing.trg_adjust_allotment_by_billid();


--
-- TOC entry 5974 (class 2620 OID 1031093)
-- Name: bill_status_info after_insert_update_bill_status_send_to_jit; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER after_insert_update_bill_status_send_to_jit AFTER INSERT OR UPDATE ON billing.bill_status_info FOR EACH ROW EXECUTE FUNCTION billing.bill_status_send_to_jit();


--
-- TOC entry 5975 (class 2620 OID 1031094)
-- Name: billing_pfms_file_status_details after_insert_update_pfms_file_status_send_to_jit; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER after_insert_update_pfms_file_status_send_to_jit AFTER INSERT OR UPDATE ON billing.billing_pfms_file_status_details FOR EACH ROW EXECUTE FUNCTION billing.pfms_file_status_send_to_jit();


--
-- TOC entry 5976 (class 2620 OID 1031095)
-- Name: ddo_allotment_booked_bill after_reissue_bill_insert; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER after_reissue_bill_insert AFTER INSERT ON billing.ddo_allotment_booked_bill FOR EACH ROW WHEN ((new.is_reissued = true)) EXECUTE FUNCTION billing.trg_adjust_allotment_by_billid();


--
-- TOC entry 5977 (class 2620 OID 1031096)
-- Name: ddo_allotment_booked_bill audit_table_changes; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER audit_table_changes AFTER INSERT OR DELETE OR UPDATE ON billing.ddo_allotment_booked_bill FOR EACH ROW EXECUTE FUNCTION billing_log.log_table_changes();


--
-- TOC entry 5971 (class 2620 OID 1031097)
-- Name: bill_gst insert_bill_cpin_in_ecs; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER insert_bill_cpin_in_ecs AFTER INSERT ON billing.bill_gst FOR EACH ROW EXECUTE FUNCTION billing.insert_cpin_ecs();


--
-- TOC entry 5972 (class 2620 OID 1031098)
-- Name: bill_gst trg_after_update_billing_bill_gst; Type: TRIGGER; Schema: billing; Owner: postgres
--

CREATE TRIGGER trg_after_update_billing_bill_gst AFTER UPDATE OF is_deleted ON billing.bill_gst FOR EACH ROW WHEN ((new.is_deleted = true)) EXECUTE FUNCTION billing.update_cpin_ecs();


--
-- TOC entry 5978 (class 2620 OID 1031099)
-- Name: failed_transaction_beneficiary after_insert_on_failed_transaction; Type: TRIGGER; Schema: cts; Owner: postgres
--

CREATE TRIGGER after_insert_on_failed_transaction AFTER INSERT ON cts.failed_transaction_beneficiary FOR EACH ROW WHEN ((new.is_gst = false)) EXECUTE FUNCTION cts.trg_adjust_allotment_failed_beneficiary();

ALTER TABLE cts.failed_transaction_beneficiary DISABLE TRIGGER after_insert_on_failed_transaction;


--
-- TOC entry 5979 (class 2620 OID 1031100)
-- Name: failed_transaction_beneficiary_bk after_insert_on_failed_transaction; Type: TRIGGER; Schema: cts; Owner: postgres
--

CREATE TRIGGER after_insert_on_failed_transaction AFTER INSERT ON cts.failed_transaction_beneficiary_bk FOR EACH ROW WHEN ((new.is_gst = false)) EXECUTE FUNCTION cts.trg_adjust_allotment_failed_beneficiary();


--
-- TOC entry 5981 (class 2620 OID 1031101)
-- Name: tsa_exp_details after_fto_insert_jit_report; Type: TRIGGER; Schema: jit; Owner: postgres
--

CREATE TRIGGER after_fto_insert_jit_report AFTER INSERT OR UPDATE ON jit.tsa_exp_details FOR EACH ROW EXECUTE FUNCTION jit.insert_jit_report();


--
-- TOC entry 5980 (class 2620 OID 1031102)
-- Name: jit_fto_sanction_booking audit_table_changes; Type: TRIGGER; Schema: jit; Owner: postgres
--

CREATE TRIGGER audit_table_changes AFTER INSERT OR DELETE OR UPDATE ON jit.jit_fto_sanction_booking FOR EACH ROW EXECUTE FUNCTION billing_log.log_table_changes();


--
-- TOC entry 5982 (class 2620 OID 1031103)
-- Name: consume_logs_partition trigger_ensure_consume_logs_partition; Type: TRIGGER; Schema: message_queue; Owner: postgres
--

CREATE TRIGGER trigger_ensure_consume_logs_partition BEFORE INSERT ON message_queue.consume_logs_partition FOR EACH ROW EXECUTE FUNCTION message_queue.consume_logs_insert_trigger();


--
-- TOC entry 5862 (class 2606 OID 1031104)
-- Name: ddo_allotment_transactions ddo_allotment_transactions_active_hoa_id_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_allotment_transactions
    ADD CONSTRAINT ddo_allotment_transactions_active_hoa_id_fkey FOREIGN KEY (active_hoa_id) REFERENCES master.active_hoa_mst(id) NOT VALID;


--
-- TOC entry 5863 (class 2606 OID 1031109)
-- Name: ddo_allotment_transactions ddo_allotment_transactions_financial_year_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_allotment_transactions
    ADD CONSTRAINT ddo_allotment_transactions_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5864 (class 2606 OID 1031114)
-- Name: ddo_allotment_transactions ddo_allotment_transactions_receiver_sao_ddo_code_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_allotment_transactions
    ADD CONSTRAINT ddo_allotment_transactions_receiver_sao_ddo_code_fkey FOREIGN KEY (receiver_sao_ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5865 (class 2606 OID 1031119)
-- Name: ddo_allotment_transactions ddo_allotment_transactions_treasury_code_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_allotment_transactions
    ADD CONSTRAINT ddo_allotment_transactions_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5866 (class 2606 OID 1031124)
-- Name: ddo_wallet ddo_wallet_active_hoa_id_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet
    ADD CONSTRAINT ddo_wallet_active_hoa_id_fkey FOREIGN KEY (active_hoa_id) REFERENCES master.active_hoa_mst(id);


--
-- TOC entry 5867 (class 2606 OID 1031129)
-- Name: ddo_wallet ddo_wallet_financial_year_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet
    ADD CONSTRAINT ddo_wallet_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5868 (class 2606 OID 1031134)
-- Name: ddo_wallet ddo_wallet_sao_ddo_code_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet
    ADD CONSTRAINT ddo_wallet_sao_ddo_code_fkey FOREIGN KEY (sao_ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5869 (class 2606 OID 1031140)
-- Name: ddo_wallet ddo_wallet_treasury_code_fkey; Type: FK CONSTRAINT; Schema: bantan; Owner: postgres
--

ALTER TABLE ONLY bantan.ddo_wallet
    ADD CONSTRAINT ddo_wallet_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5878 (class 2606 OID 1031145)
-- Name: bill_btdetail bill_btdetail_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail
    ADD CONSTRAINT bill_btdetail_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5879 (class 2606 OID 1031150)
-- Name: bill_btdetail bill_btdetail_bt_serial_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail
    ADD CONSTRAINT bill_btdetail_bt_serial_fkey FOREIGN KEY (bt_serial) REFERENCES billing_master.bt_details(bt_serial) NOT VALID;


--
-- TOC entry 5880 (class 2606 OID 1031156)
-- Name: bill_btdetail bill_btdetail_ddo_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail
    ADD CONSTRAINT bill_btdetail_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5881 (class 2606 OID 1031161)
-- Name: bill_btdetail bill_btdetail_financial_year_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail
    ADD CONSTRAINT bill_btdetail_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5882 (class 2606 OID 1031166)
-- Name: bill_btdetail bill_btdetail_treasury_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_btdetail
    ADD CONSTRAINT bill_btdetail_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5870 (class 2606 OID 1031173)
-- Name: bill_details bill_details_ddo_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5871 (class 2606 OID 1031178)
-- Name: bill_details bill_details_demand_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_demand_fkey FOREIGN KEY (demand) REFERENCES master.department(demand_code) NOT VALID;


--
-- TOC entry 5872 (class 2606 OID 1031183)
-- Name: bill_details bill_details_financial_year_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5873 (class 2606 OID 1031188)
-- Name: bill_details bill_details_status_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_status_fkey FOREIGN KEY (status) REFERENCES billing_master.bill_status_master(status_id) NOT VALID;


--
-- TOC entry 5874 (class 2606 OID 1031193)
-- Name: bill_details bill_details_tr_master_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_tr_master_id_fkey FOREIGN KEY (tr_master_id) REFERENCES billing_master.tr_master(id) NOT VALID;


--
-- TOC entry 5875 (class 2606 OID 1031198)
-- Name: bill_details bill_details_treasury_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_details
    ADD CONSTRAINT bill_details_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5885 (class 2606 OID 1031203)
-- Name: bill_ecs_neft_details bill_ecs_neft_details_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_ecs_neft_details
    ADD CONSTRAINT bill_ecs_neft_details_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5886 (class 2606 OID 1031208)
-- Name: bill_ecs_neft_details bill_ecs_neft_details_financial_year_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_ecs_neft_details
    ADD CONSTRAINT bill_ecs_neft_details_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5887 (class 2606 OID 1031213)
-- Name: bill_ecs_neft_details bill_ecs_neft_details_ifsc_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_ecs_neft_details
    ADD CONSTRAINT bill_ecs_neft_details_ifsc_code_fkey FOREIGN KEY (ifsc_code) REFERENCES master.rbi_ifsc_stock(ifsc) NOT VALID;


--
-- TOC entry 5888 (class 2606 OID 1031218)
-- Name: bill_jit_components bill_jit_components_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_jit_components
    ADD CONSTRAINT bill_jit_components_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5889 (class 2606 OID 1031258)
-- Name: bill_status_info bill_status_info_status_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_status_info
    ADD CONSTRAINT bill_status_info_status_id_fkey FOREIGN KEY (status_id) REFERENCES billing_master.bill_status_master(status_id);


--
-- TOC entry 5890 (class 2606 OID 1031308)
-- Name: bill_subdetail_info bill_subdetail_info_active_hoa_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info
    ADD CONSTRAINT bill_subdetail_info_active_hoa_id_fkey FOREIGN KEY (active_hoa_id) REFERENCES master.active_hoa_mst(id) NOT VALID;


--
-- TOC entry 5891 (class 2606 OID 1031313)
-- Name: bill_subdetail_info bill_subdetail_info_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info
    ADD CONSTRAINT bill_subdetail_info_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5892 (class 2606 OID 1031319)
-- Name: bill_subdetail_info bill_subdetail_info_ddo_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info
    ADD CONSTRAINT bill_subdetail_info_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5893 (class 2606 OID 1031325)
-- Name: bill_subdetail_info bill_subdetail_info_financial_year_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info
    ADD CONSTRAINT bill_subdetail_info_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5894 (class 2606 OID 1031330)
-- Name: bill_subdetail_info bill_subdetail_info_treasury_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_subdetail_info
    ADD CONSTRAINT bill_subdetail_info_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5895 (class 2606 OID 1031335)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_active_hoa_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_active_hoa_id_fkey FOREIGN KEY (active_hoa_id) REFERENCES master.active_hoa_mst(id) NOT VALID;


--
-- TOC entry 5896 (class 2606 OID 1031340)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_allotment_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_allotment_id_fkey FOREIGN KEY (allotment_id) REFERENCES bantan.ddo_allotment_transactions(allotment_id) NOT VALID;


--
-- TOC entry 5897 (class 2606 OID 1031346)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5898 (class 2606 OID 1031352)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_ddo_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5899 (class 2606 OID 1031357)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_financial_year_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5900 (class 2606 OID 1031362)
-- Name: ddo_allotment_booked_bill ddo_allotment_booked_bill_treasury_code_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.ddo_allotment_booked_bill
    ADD CONSTRAINT ddo_allotment_booked_bill_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5883 (class 2606 OID 1031367)
-- Name: bill_gst fk_bill_id; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_gst
    ADD CONSTRAINT fk_bill_id FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5884 (class 2606 OID 1031387)
-- Name: bill_gst fk_cpin_id; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.bill_gst
    ADD CONSTRAINT fk_cpin_id FOREIGN KEY (cpin_id) REFERENCES billing_master.cpin_master(id);


--
-- TOC entry 5876 (class 2606 OID 1031395)
-- Name: jit_ecs_additional jit_ecs_additional_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_ecs_additional
    ADD CONSTRAINT jit_ecs_additional_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5877 (class 2606 OID 1031401)
-- Name: jit_ecs_additional jit_ecs_additional_ecs_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_ecs_additional
    ADD CONSTRAINT jit_ecs_additional_ecs_id_fkey FOREIGN KEY (ecs_id) REFERENCES billing.bill_ecs_neft_details(id);


--
-- TOC entry 5901 (class 2606 OID 1031980)
-- Name: jit_fto_voucher jit_fto_voucher_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.jit_fto_voucher
    ADD CONSTRAINT jit_fto_voucher_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5902 (class 2606 OID 1031995)
-- Name: tr_10_detail tr_10_detail_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_10_detail
    ADD CONSTRAINT tr_10_detail_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5903 (class 2606 OID 1032005)
-- Name: tr_12_detail tr_12_detail_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_12_detail
    ADD CONSTRAINT tr_12_detail_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5904 (class 2606 OID 1032011)
-- Name: tr_26a_detail tr_26a_detail_bill_id_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.tr_26a_detail
    ADD CONSTRAINT tr_26a_detail_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5905 (class 2606 OID 1032159)
-- Name: cpin_vender_mst cpin_vender_mst_cpinmstid_fkey; Type: FK CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.cpin_vender_mst
    ADD CONSTRAINT cpin_vender_mst_cpinmstid_fkey FOREIGN KEY (cpinmstid) REFERENCES billing_master.cpin_master(id) NOT VALID;


--
-- TOC entry 5906 (class 2606 OID 1032169)
-- Name: tr_master_checklist tr_master_checklist_tr_master_id_fkey; Type: FK CONSTRAINT; Schema: billing_master; Owner: postgres
--

ALTER TABLE ONLY billing_master.tr_master_checklist
    ADD CONSTRAINT tr_master_checklist_tr_master_id_fkey FOREIGN KEY (tr_master_id) REFERENCES billing_master.tr_master(id) NOT VALID;


--
-- TOC entry 5917 (class 2606 OID 1032174)
-- Name: challan challan_financial_year_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.challan
    ADD CONSTRAINT challan_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5918 (class 2606 OID 1032180)
-- Name: challan challan_treasury_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.challan
    ADD CONSTRAINT challan_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5907 (class 2606 OID 1032186)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_bill_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5919 (class 2606 OID 1032216)
-- Name: failed_transaction_beneficiary_bk failed_transaction_beneficiary_bill_id_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary_bk
    ADD CONSTRAINT failed_transaction_beneficiary_bill_id_fkey_bk FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5908 (class 2606 OID 1032275)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_ddo_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5920 (class 2606 OID 1032291)
-- Name: failed_transaction_beneficiary_bk failed_transaction_beneficiary_ddo_code_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary_bk
    ADD CONSTRAINT failed_transaction_beneficiary_ddo_code_fkey_bk FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5909 (class 2606 OID 1032308)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_financial_year_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5921 (class 2606 OID 1032326)
-- Name: failed_transaction_beneficiary_bk failed_transaction_beneficiary_financial_year_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary_bk
    ADD CONSTRAINT failed_transaction_beneficiary_financial_year_fkey_bk FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5910 (class 2606 OID 1032338)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_ifsc_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_ifsc_code_fkey FOREIGN KEY (ifsc_code) REFERENCES master.rbi_ifsc_stock(ifsc);


--
-- TOC entry 5922 (class 2606 OID 1032449)
-- Name: failed_transaction_beneficiary_bk failed_transaction_beneficiary_ifsc_code_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary_bk
    ADD CONSTRAINT failed_transaction_beneficiary_ifsc_code_fkey_bk FOREIGN KEY (ifsc_code) REFERENCES master.rbi_ifsc_stock(ifsc);


--
-- TOC entry 5911 (class 2606 OID 1032563)
-- Name: failed_transaction_beneficiary failed_transaction_beneficiary_treasury_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary
    ADD CONSTRAINT failed_transaction_beneficiary_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5923 (class 2606 OID 1032579)
-- Name: failed_transaction_beneficiary_bk failed_transaction_beneficiary_treasury_code_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.failed_transaction_beneficiary_bk
    ADD CONSTRAINT failed_transaction_beneficiary_treasury_code_fkey_bk FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5912 (class 2606 OID 1032587)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_bill_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5926 (class 2606 OID 1033002)
-- Name: success_transaction_beneficiary_bk success_transaction_beneficiary_bill_id_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary_bk
    ADD CONSTRAINT success_transaction_beneficiary_bill_id_fkey_bk FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5913 (class 2606 OID 1033117)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_ddo_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5927 (class 2606 OID 1033244)
-- Name: success_transaction_beneficiary_bk success_transaction_beneficiary_ddo_code_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary_bk
    ADD CONSTRAINT success_transaction_beneficiary_ddo_code_fkey_bk FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5914 (class 2606 OID 1033335)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_financial_year_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_financial_year_fkey FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5928 (class 2606 OID 1033580)
-- Name: success_transaction_beneficiary_bk success_transaction_beneficiary_financial_year_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary_bk
    ADD CONSTRAINT success_transaction_beneficiary_financial_year_fkey_bk FOREIGN KEY (financial_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5915 (class 2606 OID 1033651)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_ifsc_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_ifsc_code_fkey FOREIGN KEY (ifsc_code) REFERENCES master.rbi_ifsc_stock(ifsc);


--
-- TOC entry 5929 (class 2606 OID 1034211)
-- Name: success_transaction_beneficiary_bk success_transaction_beneficiary_ifsc_code_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary_bk
    ADD CONSTRAINT success_transaction_beneficiary_ifsc_code_fkey_bk FOREIGN KEY (ifsc_code) REFERENCES master.rbi_ifsc_stock(ifsc);


--
-- TOC entry 5916 (class 2606 OID 1034397)
-- Name: success_transaction_beneficiary success_transaction_beneficiary_treasury_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary
    ADD CONSTRAINT success_transaction_beneficiary_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5930 (class 2606 OID 1034499)
-- Name: success_transaction_beneficiary_bk success_transaction_beneficiary_treasury_code_fkey_bk; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.success_transaction_beneficiary_bk
    ADD CONSTRAINT success_transaction_beneficiary_treasury_code_fkey_bk FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5931 (class 2606 OID 1034533)
-- Name: token token_n_bill_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.token
    ADD CONSTRAINT token_n_bill_id_fkey FOREIGN KEY (entity_id) REFERENCES billing.bill_details(bill_id);


--
-- TOC entry 5932 (class 2606 OID 1034539)
-- Name: token token_n_ddo_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.token
    ADD CONSTRAINT token_n_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5933 (class 2606 OID 1034546)
-- Name: token token_n_financial_year_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.token
    ADD CONSTRAINT token_n_financial_year_id_fkey FOREIGN KEY (financial_year_id) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5934 (class 2606 OID 1034551)
-- Name: token token_n_treasury_code_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.token
    ADD CONSTRAINT token_n_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5935 (class 2606 OID 1034561)
-- Name: voucher voucher_bill_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.voucher
    ADD CONSTRAINT voucher_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES billing.bill_details(bill_id) NOT VALID;


--
-- TOC entry 5936 (class 2606 OID 1034567)
-- Name: voucher voucher_financial_year_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.voucher
    ADD CONSTRAINT voucher_financial_year_id_fkey FOREIGN KEY (financial_year_id) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5937 (class 2606 OID 1034572)
-- Name: voucher voucher_token_id_fkey; Type: FK CONSTRAINT; Schema: cts; Owner: postgres
--

ALTER TABLE ONLY cts.voucher
    ADD CONSTRAINT voucher_token_id_fkey FOREIGN KEY (token_id) REFERENCES cts.token(id) NOT VALID;


--
-- TOC entry 5938 (class 2606 OID 1034577)
-- Name: exp_payee_components exp_payee_components_payee_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.exp_payee_components
    ADD CONSTRAINT exp_payee_components_payee_id_fkey FOREIGN KEY (payee_id) REFERENCES jit.tsa_payeemaster(id) NOT VALID;


--
-- TOC entry 5939 (class 2606 OID 1034582)
-- Name: exp_payee_components exp_payee_components_ref_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.exp_payee_components
    ADD CONSTRAINT exp_payee_components_ref_id_fkey FOREIGN KEY (ref_id) REFERENCES jit.tsa_exp_details(id) NOT VALID;


--
-- TOC entry 5940 (class 2606 OID 1034587)
-- Name: fto_voucher fto_voucher_payee_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.fto_voucher
    ADD CONSTRAINT fto_voucher_payee_id_fkey FOREIGN KEY (payee_id) REFERENCES jit.tsa_payeemaster(id) NOT VALID;


--
-- TOC entry 5941 (class 2606 OID 1034592)
-- Name: fto_voucher fto_voucher_ref_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.fto_voucher
    ADD CONSTRAINT fto_voucher_ref_id_fkey FOREIGN KEY (ref_id) REFERENCES jit.tsa_exp_details(id) NOT VALID;


--
-- TOC entry 5924 (class 2606 OID 1034597)
-- Name: gst gst_payee_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.gst
    ADD CONSTRAINT gst_payee_id_fkey FOREIGN KEY (payee_id) REFERENCES jit.tsa_payeemaster(id) NOT VALID;


--
-- TOC entry 5925 (class 2606 OID 1034602)
-- Name: gst gst_ref_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.gst
    ADD CONSTRAINT gst_ref_id_fkey FOREIGN KEY (ref_id) REFERENCES jit.tsa_exp_details(id) NOT VALID;


--
-- TOC entry 5942 (class 2606 OID 1034607)
-- Name: jit_allotment jit_allotment_ddo_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment
    ADD CONSTRAINT jit_allotment_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5943 (class 2606 OID 1034612)
-- Name: jit_allotment jit_allotment_fin_year_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment
    ADD CONSTRAINT jit_allotment_fin_year_fkey FOREIGN KEY (fin_year) REFERENCES master.financial_year_master(id) NOT VALID;


--
-- TOC entry 5944 (class 2606 OID 1034617)
-- Name: jit_allotment jit_allotment_hoa_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment
    ADD CONSTRAINT jit_allotment_hoa_id_fkey FOREIGN KEY (hoa_id) REFERENCES master.active_hoa_mst(id) NOT VALID;


--
-- TOC entry 5945 (class 2606 OID 1034622)
-- Name: jit_allotment jit_allotment_treasury_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_allotment
    ADD CONSTRAINT jit_allotment_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5946 (class 2606 OID 1034627)
-- Name: jit_fto_sanction_booking jit_fto_sanction_booking_ref_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_fto_sanction_booking
    ADD CONSTRAINT jit_fto_sanction_booking_ref_id_fkey FOREIGN KEY (ref_id) REFERENCES jit.tsa_exp_details(id) NOT VALID;


--
-- TOC entry 5947 (class 2606 OID 1034632)
-- Name: jit_fto_sanction_booking jit_fto_sanction_booking_sanction_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_fto_sanction_booking
    ADD CONSTRAINT jit_fto_sanction_booking_sanction_id_fkey FOREIGN KEY (sanction_id) REFERENCES jit.jit_allotment(id) NOT VALID;


--
-- TOC entry 5948 (class 2606 OID 1034637)
-- Name: jit_pullback_request jit_pullback_request_ref_no_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_pullback_request
    ADD CONSTRAINT jit_pullback_request_ref_no_fkey FOREIGN KEY (ref_no) REFERENCES jit.tsa_exp_details(ref_no);


--
-- TOC entry 5949 (class 2606 OID 1034664)
-- Name: jit_report_details jit_report_details_hoa_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_report_details
    ADD CONSTRAINT jit_report_details_hoa_id_fkey FOREIGN KEY (hoa_id) REFERENCES master.active_hoa_mst(id);


--
-- TOC entry 5950 (class 2606 OID 1034684)
-- Name: jit_withdrawl jit_withdrawl_ddo_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl
    ADD CONSTRAINT jit_withdrawl_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code);


--
-- TOC entry 5951 (class 2606 OID 1034692)
-- Name: jit_withdrawl jit_withdrawl_fin_year_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl
    ADD CONSTRAINT jit_withdrawl_fin_year_fkey FOREIGN KEY (fin_year) REFERENCES master.financial_year_master(id);


--
-- TOC entry 5952 (class 2606 OID 1034698)
-- Name: jit_withdrawl jit_withdrawl_hoa_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl
    ADD CONSTRAINT jit_withdrawl_hoa_id_fkey FOREIGN KEY (hoa_id) REFERENCES master.active_hoa_mst(id);


--
-- TOC entry 5953 (class 2606 OID 1034704)
-- Name: jit_withdrawl jit_withdrawl_treasury_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.jit_withdrawl
    ADD CONSTRAINT jit_withdrawl_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code);


--
-- TOC entry 5954 (class 2606 OID 1034709)
-- Name: payee_deduction payee_deduction_bt_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.payee_deduction
    ADD CONSTRAINT payee_deduction_bt_code_fkey FOREIGN KEY (bt_code) REFERENCES billing_master.bt_details(bt_serial) NOT VALID;


--
-- TOC entry 5955 (class 2606 OID 1034716)
-- Name: payee_deduction payee_deduction_ref_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.payee_deduction
    ADD CONSTRAINT payee_deduction_ref_id_fkey FOREIGN KEY (ref_id) REFERENCES jit.tsa_exp_details(id) NOT VALID;


--
-- TOC entry 5956 (class 2606 OID 1034723)
-- Name: tsa_exp_details tsa_exp_details_ddo_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_exp_details
    ADD CONSTRAINT tsa_exp_details_ddo_code_fkey FOREIGN KEY (ddo_code) REFERENCES master.ddo(ddo_code) NOT VALID;


--
-- TOC entry 5957 (class 2606 OID 1034728)
-- Name: tsa_exp_details tsa_exp_details_hoa_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_exp_details
    ADD CONSTRAINT tsa_exp_details_hoa_id_fkey FOREIGN KEY (hoa_id) REFERENCES master.active_hoa_mst(id) NOT VALID;


--
-- TOC entry 5958 (class 2606 OID 1034733)
-- Name: tsa_exp_details tsa_exp_details_treas_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_exp_details
    ADD CONSTRAINT tsa_exp_details_treas_code_fkey FOREIGN KEY (treas_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5959 (class 2606 OID 1034738)
-- Name: tsa_payeemaster tsa_payeemaster_ifsc_code_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_payeemaster
    ADD CONSTRAINT tsa_payeemaster_ifsc_code_fkey FOREIGN KEY (ifsc_code) REFERENCES master.rbi_ifsc_stock(ifsc) NOT VALID;


--
-- TOC entry 5960 (class 2606 OID 1034743)
-- Name: tsa_payeemaster tsa_payeemaster_ref_id_fkey; Type: FK CONSTRAINT; Schema: jit; Owner: postgres
--

ALTER TABLE ONLY jit.tsa_payeemaster
    ADD CONSTRAINT tsa_payeemaster_ref_id_fkey FOREIGN KEY (ref_id) REFERENCES jit.tsa_exp_details(id) NOT VALID;


--
-- TOC entry 5961 (class 2606 OID 1034749)
-- Name: ddo ddo_treasury_code_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.ddo
    ADD CONSTRAINT ddo_treasury_code_fkey FOREIGN KEY (treasury_code) REFERENCES master.treasury(code) NOT VALID;


--
-- TOC entry 5962 (class 2606 OID 1034754)
-- Name: demand_major_mapping demand_major_mapping_demand_code_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.demand_major_mapping
    ADD CONSTRAINT demand_major_mapping_demand_code_fkey FOREIGN KEY (demand_code) REFERENCES master.department(demand_code) NOT VALID;


--
-- TOC entry 5963 (class 2606 OID 1034760)
-- Name: demand_major_mapping demand_major_mapping_major_head_id_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.demand_major_mapping
    ADD CONSTRAINT demand_major_mapping_major_head_id_fkey FOREIGN KEY (major_head_id) REFERENCES master.major_head(id) NOT VALID;


--
-- TOC entry 5964 (class 2606 OID 1034767)
-- Name: minor_head minor_head_sub_major_id_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.minor_head
    ADD CONSTRAINT minor_head_sub_major_id_fkey FOREIGN KEY (sub_major_id) REFERENCES master.sub_major_head(id) NOT VALID;


--
-- TOC entry 5965 (class 2606 OID 1034774)
-- Name: scheme_head scheme_head_minor_head_id_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.scheme_head
    ADD CONSTRAINT scheme_head_minor_head_id_fkey FOREIGN KEY (minor_head_id) REFERENCES master.minor_head(id) NOT VALID;


--
-- TOC entry 5966 (class 2606 OID 1034781)
-- Name: sub_detail_head sub_detail_head_detail_head_id_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.sub_detail_head
    ADD CONSTRAINT sub_detail_head_detail_head_id_fkey FOREIGN KEY (detail_head_id) REFERENCES master.detail_head(id) NOT VALID;


--
-- TOC entry 5967 (class 2606 OID 1034786)
-- Name: sub_major_head sub_major_head_major_head_id_fkey; Type: FK CONSTRAINT; Schema: master; Owner: postgres
--

ALTER TABLE ONLY master.sub_major_head
    ADD CONSTRAINT sub_major_head_major_head_id_fkey FOREIGN KEY (major_head_id) REFERENCES master.major_head(id) NOT VALID;