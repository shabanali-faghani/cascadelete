CREATE OR REPLACE PROCEDURE CASCADELETE(table_name VARCHAR2, where_clause VARCHAR2, log CHAR DEFAULT 'Y', input_batch_size NUMBER DEFAULT 1000) AS
  -- any character except for 'Y' like 'N' turns logging off
  -- the valid maximum number of items in an IN sql statement is 1000

  TYPE VAR_TABLE IS TABLE OF VARCHAR2(32767);

  batch_size NUMBER(4) := input_batch_size;

  FUNCTION PRIMARY_KEY(table_name VARCHAR2) RETURN VARCHAR2 AS
    result VAR_TABLE;
      ex_custom EXCEPTION;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT COLS.COLUMN_NAME
        FROM USER_CONSTRAINTS CONS, USER_CONS_COLUMNS COLS
        WHERE COLS.TABLE_NAME = ''' || table_name || '''
          AND CONS.CONSTRAINT_TYPE = ''P''
          AND CONS.CONSTRAINT_NAME = COLS.CONSTRAINT_NAME
          AND CONS.STATUS = ''ENABLED''
        ORDER BY COLS.POSITION'
      BULK COLLECT INTO result;
      IF result.count = 1 THEN
        RETURN result(1);
      END IF;
      ROLLBACK;     -- rollback all executed deletes, if any
      IF result.count = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'The table ' || TABLE_NAME || ' has not primary key');
      ELSIF result.count > 1 THEN
        RAISE_APPLICATION_ERROR(-20001, 'The table ' || TABLE_NAME || ' has a composite primary key');
      END IF;
      EXCEPTION
      WHEN ex_custom
      THEN DBMS_OUTPUT.PUT_LINE(sqlerrm);
    END PRIMARY_KEY;


  FUNCTION COUNT_OF_RECORDS(table_name VARCHAR2, column_name VARCHAR2, parent_pk_values VARCHAR2) RETURN NUMBER IS
    result VAR_TABLE;
    BEGIN
      IF parent_pk_values IS NULL THEN
        RETURN 0;
      END IF;
      EXECUTE IMMEDIATE 'SELECT count(1) FROM ' || table_name || ' WHERE ' || column_name || ' IN (' || parent_pk_values || ')' BULK COLLECT INTO result;
      RETURN result(1);
    END;

  FUNCTION COLUMN_TYPE(table_name VARCHAR2, column_name VARCHAR2) RETURN VARCHAR2 IS
    result VAR_TABLE;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT DATA_TYPE
         FROM USER_TAB_COLUMNS
         WHERE upper(TABLE_NAME) = upper(''' || table_name || ''') AND upper(COLUMN_NAME) = upper(''' || column_name || ''')'
      BULK COLLECT INTO result;
      RETURN result(1);
    END COLUMN_TYPE;

  FUNCTION TO_CSV(list VAR_TABLE, table_name VARCHAR2, pk VARCHAR2) RETURN VARCHAR2 IS
    column_data_type VARCHAR2(10);
    csv              VARCHAR2(32767);
    single_quote     CHAR(1);
    BEGIN
      column_data_type := COLUMN_TYPE(table_name, pk);
      IF instr(upper(column_data_type), 'CHAR') <> 0 THEN -- CHAR, VARCHAR, VARCHAR2, NCHAR, NVARCHAR2
        single_quote := '''';
      END IF;
      FOR i IN 1..list.count LOOP
        csv := csv || single_quote || list(i) || single_quote || ', ';
      END LOOP;
      RETURN substr(csv, 1, length(csv) - 2);
    END TO_CSV;

  PROCEDURE RECURSIVE_DELETE(ancestor VARCHAR2, parent VARCHAR2, pk VARCHAR2, pk_values VARCHAR2, indent VARCHAR2, where_clause VARCHAR2 DEFAULT NULL) IS

    CURSOR CHILDS (ancestor VARCHAR2, parent VARCHAR2) IS
      SELECT UC.CONSTRAINT_NAME, UC.TABLE_NAME, UCC.COLUMN_NAME AS FOREIGN_KEY
      FROM USER_TABLES UT
        INNER JOIN USER_CONSTRAINTS UC ON UT.TABLE_NAME = UC.TABLE_NAME
        INNER JOIN USER_CONSTRAINTS RUC ON UC.R_CONSTRAINT_NAME = RUC.CONSTRAINT_NAME
        INNER JOIN USER_CONS_COLUMNS UCC ON UC.CONSTRAINT_NAME = UCC.CONSTRAINT_NAME
      WHERE RUC.TABLE_NAME = parent
        AND NOT (UT.IOT_TYPE IS NOT NULL AND UC.CONSTRAINT_TYPE = 'P')
        AND UC.CONSTRAINT_NAME NOT LIKE 'SYS%'
        AND UC.STATUS = 'ENABLED'       -- comment out this line if you want to include DISABLED constraints
        AND ancestor IS NOT NULL
      UNION ALL
      SELECT NULL, parent, NULL
      FROM DUAL
      WHERE ancestor IS NULL;

    query         VARCHAR2(32700);
    child_pk      VARCHAR2(30);
    fk            VARCHAR2(30);
    wrapped_query VARCHAR2(32767);
    result        VAR_TABLE;
    csv           VARCHAR2(32767);
    parts         NUMBER(9) := 0;
    counter       NUMBER(9);
    delete_query  VARCHAR2(32767);

    BEGIN
      FOR child IN CHILDS(ancestor, parent) LOOP
        child_pk := PRIMARY_KEY(child.table_name);
        fk := child.foreign_key;
        query := 'SELECT ' || child_pk || ' FROM ' || child.table_name || ' WHERE ' || child.foreign_key || ' IN (' || pk_values || ')';
        IF ancestor IS NULL THEN    -- case dummy root
          query := 'SELECT ' || child_pk || ' FROM ' || child.table_name || ' WHERE ' || where_clause;
          fk := child_pk;
        END IF;
        wrapped_query := 'SELECT * FROM (' || query || ') WHERE ROWNUM <= ' || batch_size;
        EXECUTE IMMEDIATE wrapped_query BULK COLLECT INTO result;
        IF result.count = 0 THEN
          IF log = 'Y' THEN
            DBMS_OUTPUT.PUT_LINE(indent || '+- (' || CASE WHEN ANCESTOR IS NULL THEN 'NULL' ELSE parent END ||
                                 '  ->  ' || child.table_name || ' - no child record found, continue;)');
          END IF;
          CONTINUE;
        END IF;
        IF log = 'Y' THEN
          DBMS_OUTPUT.PUT_LINE(indent || '+- ' || CASE WHEN ANCESTOR IS NULL THEN 'NULL' ELSE parent END || '  ->  ' || child.table_name);
          DBMS_OUTPUT.PUT_LINE(indent || '*  sql> ' || query);
        END IF;
        parts := ceil(COUNT_OF_RECORDS(child.table_name, fk, nvl(pk_values, TO_CSV(result, child.table_name, child_pk))) / batch_size);
        counter := 1;
        WHILE result.count > 0 LOOP
          csv := TO_CSV(result, child.table_name, child_pk);
          IF log = 'Y' THEN
            DBMS_OUTPUT.PUT_LINE(indent || '*  result (part ' || counter || '/' || parts || '): ' || csv);
          END IF;
          RECURSIVE_DELETE(parent, child.table_name, child_pk, csv, indent || '|    ');
          EXECUTE IMMEDIATE wrapped_query BULK COLLECT INTO result;
          counter := counter + 1;
        END LOOP;
      END LOOP;
      IF ancestor IS NULL THEN RETURN; END IF; -- ignore dummy root, there is nothing to delete
      delete_query := 'DELETE ' || parent || ' WHERE ' || nvl(pk, child_pk) || ' IN (' || pk_values || ')';
      IF log = 'Y' THEN
        DBMS_OUTPUT.PUT_LINE(substr(indent, 1, length(indent) - 5) || '*  ' || delete_query);
      END IF;
      EXECUTE IMMEDIATE delete_query;
    END RECURSIVE_DELETE;

  BEGIN
    DBMS_OUTPUT.ENABLE(NULL); -- unlimited buffer
    IF (input_batch_size IS NULL OR input_batch_size < 1 OR input_batch_size > 1000) THEN
      batch_size := 1000;
    END IF;
    DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('CASCADELETE ' || table_name || ' WHERE ' || where_clause);
    DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
    RECURSIVE_DELETE(NULL, table_name, NULL, NULL, NULL, where_clause);
    IF log = 'Y' THEN
      DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
      DBMS_OUTPUT.PUT_LINE('                          DONE!');
      DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
    END IF;
  END CASCADELETE;
/