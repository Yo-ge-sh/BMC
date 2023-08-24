CREATE OR REPLACE EDITIONABLE PACKAGE store AS
    PROCEDURE log_error (
        p_error_message VARCHAR2,
        p_ex_message    VARCHAR2
    );

    PROCEDURE log_migration (
        p_message    VARCHAR2,
        p_ex_message VARCHAR2
    );

    PROCEDURE migrate_data;

    FUNCTION migrate_supplier RETURN NUMBER;

    FUNCTION migrate_orders RETURN NUMBER;

    FUNCTION migrate_lines RETURN NUMBER;

    
    FUNCTION convert_to_date (
        input_date IN VARCHAR2
    ) RETURN DATE;

    PROCEDURE display_order_invoice_summary;

    PROCEDURE get_order_invoice_summary (
        p_cursor OUT SYS_REFCURSOR
    );

    PROCEDURE display_second_highest_order_details;

    PROCEDURE get_second_highest_order_details (
        p_cursor OUT SYS_REFCURSOR
    );

    PROCEDURE display_supplier_order_info;

    PROCEDURE get_supplier_order_info (
        p_cursor OUT SYS_REFCURSOR
    );

    PROCEDURE run_all;

END store;
/

CREATE OR REPLACE EDITIONABLE PACKAGE BODY store AS

    v_err_msg VARCHAR2(3200);
    v_msg     VARCHAR2(50);

    -- Procedure to migrate data through different stages
PROCEDURE migrate_data AS
    supp NUMBER; -- Variable to hold result of migrate_supplier function
    ord  NUMBER; -- Variable to hold result of migrate_orders function
    lin  NUMBER; -- Variable to hold result of migrate_lines function
BEGIN
    -- Migrate supplier data
    supp := migrate_supplier; -- Call the migrate_supplier function
    IF supp = 1 THEN -- Check if migrate_supplier was successful
        -- Migrate order data
        ord := migrate_orders; -- Call the migrate_orders function
        IF ord = 1 THEN -- Check if migrate_orders was successful
            -- Migrate order line data
            lin := migrate_lines; -- Call the migrate_lines function
            IF lin = 1 THEN -- Check if migrate_lines was successful
                dbms_output.put_line('DATA Migration Successful');
                log_migration('Migration Succeeded', ''); -- Log migration success
            END IF;
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        dbms_output.put_line('DATA Migration failed ' || sqlerrm);
        v_err_msg := sqlerrm; -- Capture the error message
        log_error('Migration Failed', v_err_msg); -- Log migration failure
END;



    -- Procedure to log errors
PROCEDURE log_error (
    p_error_message VARCHAR2, -- Error message to be logged
    p_ex_message    VARCHAR2  -- Exception message to be logged
) AS
BEGIN
    -- Insert error information into the error_log table
    INSERT INTO error_log (
        error_timestamp,
        error_message,
        exception_message
    ) VALUES (
        systimestamp,
        p_error_message,
        p_ex_message
    );

    COMMIT; -- Commit the transaction to save the log
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK; -- Rollback in case of exception during logging
        -- If logging the error itself fails
        dbms_output.put_line('Error logging failed: ' || sqlerrm);
END ;

-- Procedure to log migration events
PROCEDURE log_migration (
    p_message    VARCHAR2, -- Message to be logged
    p_ex_message VARCHAR2  -- Exception message to be logged
) AS
BEGIN
    -- Insert migration information into the migration_log table
    INSERT INTO migration_log (
        migration_timestamp,
        message,
        exception_message
    ) VALUES (
        systimestamp,
        p_message,
        p_ex_message
    );

    COMMIT; -- Commit the transaction to save the log
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK; -- Rollback in case of exception during logging
        -- If logging the migration event itself fails
        dbms_output.put_line('Migration logging failed: ' || sqlerrm);
END ;


    -- Function to migrate supplier data
FUNCTION migrate_supplier RETURN NUMBER AS
    CURSOR supplier_curs IS
        -- Retrieve distinct supplier information from xxbcm_order_mgt
        SELECT DISTINCT
            xom.supplier_name,
            xom.supp_address,
            xom.supp_contact_name,
            xom.supp_contact_number,
            xom.supp_email
        FROM
            xxbcm_order_mgt xom
        WHERE
            xom.order_ref NOT LIKE '%-%';

    CURSOR c_exist_supp (
        p_name supplier.name%TYPE
    ) IS
        -- Check if supplier already exists in the SUPPLIER table
        SELECT
            1
        FROM
            supplier
        WHERE
            name = TRIM(p_name);

    r_exist_supp    c_exist_supp%rowtype;
    vfoundsupp      BOOLEAN;
    contact_numbers sys.odcinumberlist;
    num_1           NUMBER;
    num_2           NUMBER;
BEGIN
    FOR r_supplier_curs IN supplier_curs LOOP
        v_msg := TRIM(r_supplier_curs.supplier_name);
        
        
        -- Check if supplier already exists in SUPPLIER table
        OPEN c_exist_supp(r_supplier_curs.supplier_name);
        FETCH c_exist_supp INTO r_exist_supp;
        vfoundsupp := c_exist_supp%found;
        CLOSE c_exist_supp;

        IF NOT vfoundsupp THEN
            -- Insert supplier information into SUPPLIERS
            INSERT INTO supplier (
                name,
                address,
                contact_number_1,
                contact_number_2,
                contact_person,
                email_address
            ) VALUES (
                TRIM(r_supplier_curs.supplier_name),
                REPLACE(r_supplier_curs.supp_address, ' -,', ''),
                REGEXP_SUBSTR(REGEXP_REPLACE(r_supplier_curs.supp_contact_number, ' ', ''),
                              '[^,\.]+',
                              1,
                              1),
                REGEXP_SUBSTR(REGEXP_REPLACE(r_supplier_curs.supp_contact_number, ' ', ''),
                              '[^,\.]+',
                              1,
                              2),
                r_supplier_curs.supp_contact_name,
                r_supplier_curs.supp_email
            );
        ELSE
            -- Update supplier information if it already exists in SUPPLIERS
            UPDATE supplier
            SET
                address = REPLACE(r_supplier_curs.supp_address, ' -,', ''),
                contact_number_1 = REGEXP_SUBSTR(REGEXP_REPLACE(r_supplier_curs.supp_contact_number, ' ', ''),
                                                 '[^,\.]+',
                                                 1,
                                                 1),
                contact_number_2 = REGEXP_SUBSTR(REGEXP_REPLACE(r_supplier_curs.supp_contact_number, ' ', ''),
                                                 '[^,\.]+',
                                                 1,
                                                 2),
                contact_person = r_supplier_curs.supp_contact_name,
                email_address = r_supplier_curs.supp_email
            WHERE
                name = TRIM(r_supplier_curs.supplier_name);
        END IF;
    END LOOP;

    COMMIT;
    RETURN 1;

EXCEPTION
    WHEN OTHERS THEN
        -- Handle exceptions and log errors
        dbms_output.put_line('DATA Migration failed for Supplier: ' || v_msg || ' ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_migration('Migration Failed, Error occurred at Supplier ' || v_msg, v_err_msg);
        ROLLBACK;
        RETURN 0;
END ;


    -- Function to migrate order data
FUNCTION migrate_orders RETURN NUMBER AS
    CURSOR orders_curs IS
        -- Retrieve order information from xxbcm_order_mgt
        SELECT
            order_ref,
            order_date,
            supplier_name,
            order_total_amount,
            order_description,
            order_status
        FROM
            xxbcm_order_mgt
        WHERE
            order_ref NOT LIKE '%-%'
        ORDER BY
            order_ref;

    CURSOR c_exist_ord (
        p_order_ref orders.order_ref%TYPE
    ) IS
        -- Check if order already exists in the ORDERS table
        SELECT
            1
        FROM
            orders
        WHERE
            order_ref = p_order_ref;

    r_exist_ord c_exist_ord%rowtype;
    vfoundord   BOOLEAN;
    supp_id     supplier.supplier_id%TYPE;
BEGIN
    FOR r_orders_curs IN orders_curs LOOP
        v_msg := r_orders_curs.order_ref;
        
        -- Check if order already exists in ORDERS table
        OPEN c_exist_ord(r_orders_curs.order_ref);
        FETCH c_exist_ord INTO r_exist_ord;
        vfoundord := c_exist_ord%found;
        CLOSE c_exist_ord;

        IF NOT vfoundord THEN
            -- Retrieve the supplier_id for the given supplier_name
            SELECT
                supplier_id
            INTO supp_id
            FROM
                supplier
            WHERE
                name = r_orders_curs.supplier_name;

            -- Insert order information into ORDERS table
            INSERT INTO orders (
                order_ref,
                order_date,
                supplier_id,
                order_total_amount,
                order_description,
                status
            ) VALUES (
                r_orders_curs.order_ref,
                convert_to_date(r_orders_curs.order_date),
                supp_id,
                nvl(regexp_replace(r_orders_curs.order_total_amount, '[^0-9]', ''), 0),
                r_orders_curs.order_description,
                r_orders_curs.order_status
            );
        END IF;
    END LOOP;

    COMMIT;
    RETURN 1;

EXCEPTION
    WHEN OTHERS THEN
        -- Handle exceptions and log errors
        dbms_output.put_line('DATA Migration failed for Order with reference: ' || v_msg || ' ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_migration('Migration Failed, Error occurred at Order with reference ' || v_msg, v_err_msg);
        ROLLBACK;
        RETURN 0;
END ;


    -- Function to migrate order lines data
FUNCTION migrate_lines RETURN NUMBER AS
    CURSOR lines_curs IS
        -- Retrieve order lines and associated invoice information
        SELECT
            regexp_substr(order_ref, '[^-]+')  order_ref,
            regexp_substr(order_ref, '[^-]+$') order_line,
            order_description,
            order_status,
            order_line_amount,
            invoice_reference,
            invoice_date,
            invoice_status,
            invoice_hold_reason,
            invoice_amount,
            invoice_description
        FROM
            xxbcm_order_mgt
        WHERE
            order_ref LIKE '%-%'
        ORDER BY
            order_ref;

    -- Cursor to check if the order line already exists
    CURSOR c_exist_line (
        p_order_id   order_line.order_id%TYPE,
        p_ord_desc   order_line.order_line_description%TYPE,
        p_order_line order_line.order_line_number%TYPE,
        p_amount     order_line.order_line_amount%TYPE
    ) IS
    SELECT
        1
    FROM
        order_line ol
    WHERE
            ol.order_id = p_order_id
        AND ol.order_line_number = p_order_line
        AND ol.order_line_description = p_ord_desc
        AND ol.order_line_amount = p_amount;

    -- Cursor to check if the order line with associated invoice already exists
    CURSOR c_exist_line_inv (
        p_order_id   order_line.order_id%TYPE,
        p_ord_desc   order_line.order_line_description%TYPE,
        p_order_line order_line.order_line_number%TYPE,
        p_amount     order_line.order_line_amount%TYPE,
        p_ref        invoice.invoice_reference%TYPE
    ) IS
    SELECT
        1
    FROM
        order_line   ol,
        invoice_line il,
        invoice      i
    WHERE
            i.invoice_id = il.invoice_id
        AND il.order_line_id = ol.order_line_id
        AND i.invoice_reference = p_ref
        AND ol.order_id = p_order_id
        AND ol.order_line_number = p_order_line
        AND ol.order_line_description = p_ord_desc
        AND ol.order_line_amount = p_amount;

    r_exist_line     c_exist_line%rowtype;
    r_exist_line_inv c_exist_line_inv%rowtype;
    vfoundline       BOOLEAN;
    supp_id          supplier.supplier_id%TYPE;
    ord_id           orders.order_id%TYPE;
    ord_line_id      order_line.order_line_id%TYPE;
    inv_id           invoice.invoice_id%TYPE;
BEGIN
    FOR r_lines_curs IN lines_curs LOOP
        v_msg := r_lines_curs.order_ref;

        -- Retrieve order_id for the given order_ref
        SELECT
            order_id
        INTO ord_id
        FROM
            orders
        WHERE
            order_ref = r_lines_curs.order_ref;

        IF r_lines_curs.invoice_reference IS NULL THEN
            -- Check if the order line already exists
            OPEN c_exist_line(ord_id, r_lines_curs.order_description, r_lines_curs.order_line, nvl(regexp_replace(r_lines_curs.order_line_amount, '[^0-9]', ''), 0));
            FETCH c_exist_line INTO r_exist_line;
            vfoundline := c_exist_line%found;
            CLOSE c_exist_line;
        ELSE
            -- Check if the order line with associated invoice already exists
            OPEN c_exist_line_inv(ord_id, r_lines_curs.order_description, r_lines_curs.order_line, nvl(regexp_replace(r_lines_curs.order_line_amount, '[^0-9]', ''), 0), r_lines_curs.invoice_reference);
            FETCH c_exist_line_inv INTO r_exist_line_inv;
            vfoundline := c_exist_line_inv%found;
            CLOSE c_exist_line_inv;
        END IF;

        IF NOT vfoundline THEN
            -- Insert order line information into ORDER_LINE table
            INSERT INTO order_line (
                order_id,
                order_line_description,
                order_line_number,
                order_line_status,
                order_line_amount
            ) VALUES (
                ord_id,
                r_lines_curs.order_description,
                r_lines_curs.order_line,
                r_lines_curs.order_status,
                nvl(regexp_replace(r_lines_curs.order_line_amount, '[^0-9]', ''), 0)
            ) RETURNING order_line_id INTO ord_line_id;

            IF r_lines_curs.invoice_reference IS NOT NULL THEN
                -- Insert invoice and invoice line information
                INSERT INTO invoice (
                    invoice_reference,
                    invoice_date,
                    invoice_status,
                    invoice_hold_reason
                ) VALUES (
                    r_lines_curs.invoice_reference,
                    convert_to_date(r_lines_curs.invoice_date),
                    r_lines_curs.invoice_status,
                    r_lines_curs.invoice_hold_reason
                ) RETURNING invoice_id INTO inv_id;

                INSERT INTO invoice_line (
                    invoice_id,
                    invoice_amount,
                    invoice_description,
                    order_line_id
                ) VALUES (
                    inv_id,
                    nvl(regexp_replace(r_lines_curs.invoice_amount, '[^0-9]', ''), 0),
                    r_lines_curs.invoice_description,
                    ord_line_id
                );
            END IF;
        END IF;
    END LOOP;

    COMMIT;
    RETURN 1;

EXCEPTION
    WHEN OTHERS THEN
        -- Handle exceptions and log errors
        dbms_output.put_line('DATA Migration failed for Invoice associated to Order with reference: ' || v_msg || ' ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_migration('Migration Failed, Error occurred at Invoice associated to Order with reference ' || v_msg, v_err_msg);
        ROLLBACK;
        RETURN 0;
END ;


    -- Function to convert a given string input_date to DATE using various format masks
FUNCTION convert_to_date (
    input_date IN VARCHAR2
) RETURN DATE IS
    converted_date DATE;
    format_masks   sys.odcivarchar2list := sys.odcivarchar2list('YYYY-MM-DD', 'MM/DD/YYYY', 'DD-MON-YYYY', 'DD.MM.YYYY', 'YYYY/MM/DD',
                                                             'MM/DD/YY', 'DD-MON-YY', 'DD.MM.YY', 'YYYYMMDD', 'MMDDYYYY',
                                                             'DDMONYYYY', 'DDMMYYYY');
BEGIN
    FOR i IN 1..format_masks.count LOOP
        BEGIN
            converted_date := to_date(input_date, format_masks(i));
            RETURN converted_date;
        EXCEPTION
            WHEN OTHERS THEN
                NULL; -- Ignore errors in conversion attempts
        END;
    END LOOP;

    RETURN NULL; -- Return NULL if no valid conversion was found
END;

-- Procedure to retrieve order and invoice summary data
PROCEDURE get_order_invoice_summary (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    -- Open the cursor for selecting order and invoice summary data
    OPEN p_cursor FOR
        SELECT
            TO_NUMBER(substr(o.order_ref, 3))              AS order_number,
            to_char(o.order_date, 'MON-YYYY')              AS order_period,
            initcap(s.name)                                AS supplier_name,
            to_char(o.order_total_amount, '99,999,990.00') AS order_total_amount,
            o.status                                       AS order_status,
            i.invoice_reference,
            to_char(il.invoice_amount, '99,999,990.00')    AS invoice_total_amount,
            i.invoice_status
        FROM
            orders       o,
            order_line   ol,
            supplier     s,
            invoice      i,
            invoice_line il
        WHERE
            o.order_id = ol.order_id
            AND o.supplier_id = s.supplier_id
            AND ol.order_line_id = il.order_line_id (+)
            AND il.invoice_id = i.invoice_id (+)
        ORDER BY
            o.order_date DESC;
END;

-- Procedure to display order and invoice summary data
PROCEDURE display_order_invoice_summary AS
    v_cursor               SYS_REFCURSOR;
    v_order_number         NUMBER;
    v_order_period         VARCHAR2(20);
    v_supplier_name        VARCHAR2(200);
    v_order_total_amount   VARCHAR2(20);
    v_order_status         VARCHAR2(50);
    v_invoice_reference    VARCHAR2(20);
    v_invoice_total_amount VARCHAR2(20);
    v_invoice_status       VARCHAR2(10);
    v_action               VARCHAR2(20);
BEGIN
    -- Retrieve order and invoice summary data
    get_order_invoice_summary(v_cursor);

    -- Display column headers
    dbms_output.put_line(rpad('Order# ', 5)
                         || ' ¦ '
                         || rpad('Order Period', 15)
                         || ' ¦ '
                         || rpad('Supplier Name', 30)
                         || ' ¦ '
                         || rpad('Order Total', 20)
                         || ' ¦ '
                         || rpad('Order Status', 15)
                         || ' ¦ '
                         || rpad('Invoice Reference ', 20)
                         || ' ¦ '
                         || rpad('Invoice Total ', 20)
                         || ' ¦ '
                         || rpad('Invoice Status ', 20)
                         || ' ¦ '
                         || rpad('Action', 20));

    -- Display a separator line
    dbms_output.put_line('-----------------------------------------------------------------------------------------------------------------------------------------------------');

    -- Loop through the cursor and display each row
    LOOP
        FETCH v_cursor INTO
            v_order_number,
            v_order_period,
            v_supplier_name,
            v_order_total_amount,
            v_order_status,
            v_invoice_reference,
            v_invoice_total_amount,
            v_invoice_status;

        EXIT WHEN v_cursor%notfound;

        -- Determine the action based on invoice status
        IF v_invoice_status IS NULL THEN
            v_action := 'To verify';
        ELSIF v_invoice_status = 'Pending' THEN
            v_action := 'To follow up';
        ELSE
            v_action := 'OK';
        END IF;

        -- Display the row data
        dbms_output.put_line(lpad(to_char(v_order_number, 'FM9999'), 5)
                             || ' | '
                             || rpad(to_char(v_order_period), 15)
                             || ' | '
                             || rpad(v_supplier_name, 30)
                             || ' | '
                             || lpad(to_char(v_order_total_amount), 20)
                             || ' | '
                             || rpad(v_order_status, 15)
                             || ' | '
                             || rpad(nvl(v_invoice_reference, '-'), 20)
                             || ' | '
                             || lpad(to_char(nvl(v_invoice_total_amount, '-')), 20)
                             || ' | '
                             || rpad(nvl(v_invoice_status, '-'), 20)
                             || ' | '
                             || rpad(v_action, 20));
    END LOOP;

    CLOSE v_cursor;

EXCEPTION
    WHEN OTHERS THEN
        -- Handle exceptions and log errors
        dbms_output.put_line('Display Error ' || '  ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_error('Display Error ', v_err_msg);
END;


    -- Procedure to retrieve second highest order details
PROCEDURE get_second_highest_order_details (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    -- Open the cursor for selecting second highest order details
    OPEN p_cursor FOR
        SELECT
            TO_NUMBER(substr(o.order_ref, 3))              AS order_number,
            to_char(o.order_date, 'Month DD, YYYY')        AS order_date,
            upper(s.name)                                  AS supplier_name,
            to_char(o.order_total_amount, '99,999,990.00') AS order_total_amount,
            o.status                                       AS order_status,
            LISTAGG(i.invoice_reference, '|') WITHIN GROUP (ORDER BY i.invoice_reference) AS invoice_references
        FROM
            orders       o,
            order_line   ol,
            supplier     s,
            invoice      i,
            invoice_line il
        WHERE
            o.order_id = ol.order_id
            AND o.supplier_id = s.supplier_id
            AND ol.order_line_id = il.order_line_id (+)
            AND il.invoice_id = i.invoice_id (+)
            AND o.order_total_amount = (
                SELECT DISTINCT
                    order_total_amount
                FROM
                    orders
                ORDER BY
                    order_total_amount DESC
                OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY
            )
        GROUP BY
            o.order_ref,
            o.order_date,
            s.name,
            o.order_total_amount,
            o.status;
END;

-- Procedure to display second highest order details
PROCEDURE display_second_highest_order_details AS
    v_cursor             SYS_REFCURSOR;
    v_order_number       NUMBER;
    v_order_date         VARCHAR2(50);
    v_supplier_name      VARCHAR2(200);
    v_order_total_amount VARCHAR2(20);
    v_order_status       VARCHAR2(50);
    v_invoice_references VARCHAR2(4000);
BEGIN
    -- Retrieve and display second highest order details
    get_second_highest_order_details(v_cursor);

    dbms_output.put_line(rpad('Order', 3)
                         || ' ¦ '
                         || rpad('Order Date', 9)
                         || ' ¦ '
                         || rpad('Supplier Name', 30)
                         || ' ¦ '
                         || rpad('Order Total', 20)
                         || ' ¦ '
                         || rpad('Order Status', 15)
                         || ' ¦ '
                         || 'Invoice References');

    dbms_output.put_line('-----------------------------------------------------------------------------------------------------------------------------------------------------');

    FETCH v_cursor INTO
        v_order_number,
        v_order_date,
        v_supplier_name,
        v_order_total_amount,
        v_order_status,
        v_invoice_references;

    IF v_cursor%found THEN
        dbms_output.put_line(lpad(to_char(v_order_number, 'FM9999'), 3)
                             || ' ¦ '
                             || rpad(to_char(v_order_date), 9)
                             || ' ¦ '
                             || rpad(v_supplier_name, 30)
                             || ' ¦ '
                             || lpad(to_char(v_order_total_amount), 20)
                             || ' ¦ '
                             || rpad(v_order_status, 15)
                             || ' ¦ '
                             || v_invoice_references);
    ELSE
        dbms_output.put_line('No data found for the second highest order.' || '  ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_error('Display Error => No data found for the second highest order', v_err_msg);
    END IF;

    CLOSE v_cursor;
EXCEPTION
    WHEN OTHERS THEN
        dbms_output.put_line('Display Error ' || '  ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_error('Display Error ', v_err_msg);
END;

-- Procedure to retrieve supplier order information
PROCEDURE get_supplier_order_info (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    -- Open the cursor for selecting supplier order information
    OPEN p_cursor FOR
        SELECT
            s.name                   AS supplier_name,
            s.contact_person         AS supplier_contact_name,
            replace(to_char(s.contact_number_1, '9999,9999'), ',', '-') AS supplier_contact_no_1,
            replace(to_char(s.contact_number_2, '9999,9999'), ',', '-') AS supplier_contact_no_2,
            COUNT(o.order_id)        AS total_orders,
            to_char(SUM(o.order_total_amount), '99,999,990.00') AS order_total_amount
        FROM
            supplier s,
            orders   o
        WHERE
            s.supplier_id = o.supplier_id
            AND o.order_date BETWEEN TO_DATE('2022-01-01', 'YYYY-MM-DD') AND TO_DATE('2022-08-31', 'YYYY-MM-DD')
        GROUP BY
            s.name,
            s.contact_person,
            s.contact_number_1,
            s.contact_number_2
        ORDER BY
            s.name;
END;

-- Procedure to display supplier order information
PROCEDURE display_supplier_order_info AS
    v_cursor                SYS_REFCURSOR;
    v_supplier_name         VARCHAR2(200);
    v_supplier_contact_name VARCHAR2(50);
    v_supplier_contact_no_1 VARCHAR2(20);
    v_supplier_contact_no_2 VARCHAR2(20);
    v_total_orders          NUMBER;
    v_order_total_amount    VARCHAR2(20);
BEGIN
    -- Retrieve and display supplier order information
    get_supplier_order_info(v_cursor);

    dbms_output.put_line(rpad('Supplier Name', 30)
                         || ' | '
                         || rpad('Supplier Contact', 25)
                         || ' | '
                         || rpad('Contact No. 1', 15)
                         || ' | '
                         || rpad('Contact No. 2', 15)
                         || ' | '
                         || rpad('Total Orders', 5)
                         || ' | '
                         || rpad('Order Total Amount', 20));

    dbms_output.put_line('-----------------------------------------------------------------------------------------------------------------------------------------------------');

    LOOP
        FETCH v_cursor INTO
            v_supplier_name,
            v_supplier_contact_name,
            v_supplier_contact_no_1,
            v_supplier_contact_no_2,
            v_total_orders,
            v_order_total_amount;
        EXIT WHEN v_cursor%notfound;

        dbms_output.put_line(rpad(v_supplier_name, 30)
                             || ' | '
                             || rpad(v_supplier_contact_name, 25)
                             || ' | '
                             || lpad(to_char(v_supplier_contact_no_1), 15)
                             || ' | '
                             || lpad(nvl(to_char(v_supplier_contact_no_2),'-'), 15)
                             || ' | '
                             || lpad(to_char(v_total_orders, 'FM9999'), 5)
                             || ' | '
                             || lpad(to_char(v_order_total_amount), 20));
    END LOOP;

    CLOSE v_cursor;
EXCEPTION
    WHEN OTHERS THEN
        dbms_output.put_line('Display Error ' || '  ' || sqlerrm);
        v_err_msg := sqlerrm;
        log_error('Display Error ', v_err_msg);
END;

-- Procedure to run all procedures
PROCEDURE run_all AS
BEGIN
    migrate_data;
     dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );
        dbms_output.put_line('  ');
        dbms_output.put_line('ORDER INVOICE SUMMARY');
        dbms_output.put_line('~~~~~~~~~~~~~~~~~~~~~');
        dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );
    -- Display order and invoice summary
    display_order_invoice_summary;
    dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );
        dbms_output.put_line('  ');
        dbms_output.put_line('SECOND HIGHEST ORDER DETAILS');
        dbms_output.put_line('~~~~~~~~~~~~~~~~~~~~~~~~~~~~');
        dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );    -- Display second highest order details
    display_second_highest_order_details;
    dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );
        dbms_output.put_line('  ');
        dbms_output.put_line('SUPPLIER ORDER INFO');
        dbms_output.put_line('~~~~~~~~~~~~~~~~~~~');
        dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );
    -- Display supplier order information
    display_supplier_order_info;
    dbms_output.put_line('¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬¬'
        );
END;


END store;
/