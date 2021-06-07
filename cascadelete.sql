create or replace procedure cascadelete(table_name varchar2, where_clause varchar2, logging boolean default true,
  input_batch_size number default 1000) as

  type var_table is table of varchar2(32767);
  batch_size number(4) := input_batch_size;
  cascadelete_query varchar2(32767);

  function primary_key(table_name varchar2) return varchar2 as
    result var_table;
    ex_custom exception;
  begin
    execute immediate 'SELECT COLS.COLUMN_NAME
      FROM USER_CONSTRAINTS CONS, USER_CONS_COLUMNS COLS
      WHERE COLS.TABLE_NAME = ''' || table_name || '''
        AND CONS.CONSTRAINT_TYPE = ''P''
        AND CONS.CONSTRAINT_NAME = COLS.CONSTRAINT_NAME
        AND CONS.STATUS = ''ENABLED''
      ORDER BY COLS.POSITION'
        bulk collect into result;
    if result.count = 1 then
      return result(1);
    end if;
    rollback;     -- rollback all executed deletes, if any
    if result.count = 0 then
      raise_application_error(-20001, 'The table ' || table_name || ' has not primary key');
    elsif result.count > 1 then
      raise_application_error(-20001, 'The table ' || table_name || ' has a composite primary key');
    end if;
    exception when ex_custom then dbms_output.put_line(sqlerrm);
  end primary_key;

  procedure log(message CLOB) is
    l_offset     INT := 1;  
  begin
    if logging then
      loop  
        exit when l_offset > dbms_lob.getlength(message);  
        dbms_output.put_line( dbms_lob.substr( message, 255, l_offset ) );  
        l_offset := l_offset + 255;  
      end loop;
    end if;
  end log;

  function number_of_records(table_name varchar2, column_name varchar2, parent_pk_values CLOB) return number is
    result var_table;
    qry clob;
  begin
    if parent_pk_values is null then
      return 0;
    end if;
    qry := 'SELECT count(1) FROM ' || table_name || ' WHERE ' || column_name || ' IN (' || parent_pk_values || ')';
    log('executing: ' || qry);
    execute immediate qry bulk collect into result;
    return result(1);
  end number_of_records;

  function column_type(table_name varchar2, column_name varchar2) return varchar2 is
    result var_table;
  begin
    execute immediate 'SELECT DATA_TYPE
      FROM USER_TAB_COLUMNS
      WHERE upper(TABLE_NAME) = upper(''' || table_name || ''') AND upper(COLUMN_NAME) = upper(''' || column_name || ''')'
        bulk collect into result;
    return result(1);
  end column_type;

  function to_csv(list var_table, table_name varchar2, pk varchar2) return CLOB is
    column_data_type varchar2(10);
    csv              CLOB;
    single_quote     char(1);
  begin
    column_data_type := column_type(table_name, pk);
    -- CHAR, VARCHAR, VARCHAR2, NCHAR, NVARCHAR2, RAW
    if instr(upper(column_data_type), 'CHAR') <> 0 OR upper(column_data_type)='RAW' then 
      single_quote := '''';
    end if;
    for i in 1..list.count loop
      csv := csv || single_quote || replace(list(i), '''', '''''') || single_quote || ', ';
    end loop;
--    log('csv: ' || csv);
    return substr(csv, 1, length(csv) - 2);
  end to_csv;

  procedure recursive_delete(ancestor varchar2, parent varchar2, pk varchar2, pk_values CLOB, indent varchar2,
    where_clause varchar2 default null) is
    cursor childs (ancestor varchar2, parent varchar2) is
      SELECT UC.CONSTRAINT_NAME, UC.TABLE_NAME, UCC.COLUMN_NAME AS FOREIGN_KEY
      FROM USER_TABLES UT
        INNER JOIN USER_CONSTRAINTS UC ON UT.TABLE_NAME = UC.TABLE_NAME
        INNER JOIN USER_CONSTRAINTS RUC ON UC.R_CONSTRAINT_NAME = RUC.CONSTRAINT_NAME
        INNER JOIN USER_CONS_COLUMNS UCC ON UC.CONSTRAINT_NAME = UCC.CONSTRAINT_NAME
      WHERE RUC.TABLE_NAME = parent
        AND NOT (UT.IOT_TYPE IS NOT NULL AND UC.CONSTRAINT_TYPE = 'P')
        AND UC.CONSTRAINT_NAME NOT LIKE 'SYS%'
        AND UC.STATUS = 'ENABLED' -- comment out this line if you want to delete records related by DISABLED constraints, too.
        AND ancestor IS NOT NULL
      UNION ALL
      SELECT NULL, parent, NULL
      FROM DUAL
      WHERE ancestor IS NULL;

    query         CLOB;
    child_pk      varchar2(30);
    fk            varchar2(30);
    wrapped_query CLOB;
    result        var_table;
    csv           CLOB;
    parts         number(9) := 0;
    counter       number(9);
    delete_query  CLOB;

  begin
    for child in childs(ancestor, parent) loop
      dbms_output.put_line('handling child: ' || child.table_name || ' by foreign key ' || child.FOREIGN_KEY); 
      child_pk := primary_key(child.table_name);
      fk := child.foreign_key;
      query := 'SELECT ' || child_pk || ' FROM ' || child.table_name || ' WHERE ' || child.foreign_key || ' IN (' || pk_values || ')';
      if ancestor is null then    -- case dummy root
        query := 'SELECT ' || child_pk || ' FROM ' || child.table_name || ' WHERE ' || where_clause;
        fk := child_pk;
      end if;
      dbms_lob.createtemporary(wrapped_query, true);
      dbms_lob.append(wrapped_query, 'SELECT * FROM (');
      dbms_lob.append(wrapped_query, query);
      dbms_lob.append(wrapped_query, ') WHERE ROWNUM <= ');
      dbms_lob.append(wrapped_query, to_char(batch_size));
      log(wrapped_query);
      execute immediate wrapped_query bulk collect into result;
      log(indent || '+- ' || case when ancestor is null then 'ROOT' else parent end || '  ->  ' || child.table_name);
      if result.count = 0 then
        continue;
      end if;
      log(indent || '*  sql> ' || query || ';');
      dbms_lob.freetemporary(query);
      parts := ceil(number_of_records(child.table_name, fk, nvl(pk_values,
        to_csv(result, child.table_name, child_pk))) / batch_size);
      counter := 1;
      while result.count > 0 loop
        csv := to_csv(result, child.table_name, child_pk);
        log(indent || '*  result (part ' || counter || '/' || parts || '): ' || csv);
        recursive_delete(parent, child.table_name, child_pk, csv, indent || '|    ');
        execute immediate wrapped_query bulk collect into result;
        counter := counter + 1;
      end loop;
      dbms_lob.freetemporary(wrapped_query);
    end loop;
    if ancestor is null then return; end if; -- ignore dummy root, there is nothing to delete
    dbms_lob.createtemporary(delete_query, true);
    dbms_lob.append(delete_query, 'DELETE ');
    dbms_lob.append(delete_query, parent);
    dbms_lob.append(delete_query, ' WHERE ');
    dbms_lob.append(delete_query, nvl(pk, child_pk));
    dbms_lob.append(delete_query, ' IN (');
    dbms_lob.append(delete_query, pk_values);
    dbms_lob.append(delete_query, ')');
    log(substr(indent, 1, length(indent) - 5) || '*  sql> ' || delete_query || ';');
    execute immediate delete_query;
    dbms_lob.freetemporary(delete_query);
  end recursive_delete;

  procedure do_dash(num number) is
    dashes varchar2(32767);
  begin
    for i in 1..num loop
      dashes := dashes || '-';
    end loop;
    log(dashes);
  end do_dash;
begin
  dbms_output.enable(null); -- unlimited buffer
  if (input_batch_size is null or input_batch_size < 1 or input_batch_size > 1000) then
    batch_size := 1000;
  end if;
  cascadelete_query := 'SQL> CASCADELETE ' || table_name || ' WHERE ' || where_clause || ';';
  log(cascadelete_query);
  do_dash(length(cascadelete_query));
  recursive_delete(null, table_name, null, null, null, where_clause);
  do_dash(length(cascadelete_query));
end cascadelete;
/
