create or replace procedure cascadelete(table_name varchar2, where_clause varchar2, logging boolean default true,
  input_batch_size number default 1000) as

  type var_table is table of varchar2(32767);
  batch_size number(4) := input_batch_size;
  cascadelete_query varchar2(32767);
  temp_table_name varchar2(100) := 'CASCADEL_TEMP_TAB';
  temp_table_pkval_col varchar2(100) := 'PK_VAL';
  temp_table_idx_col varchar2(100) := 'IDX';
  rec_index number := 0;

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
      dbms_output.put_line(systimestamp);
      loop  
        exit when l_offset > dbms_lob.getlength(message);  
        dbms_output.put_line( dbms_lob.substr( message, 255, l_offset ) );  
        l_offset := l_offset + 255;  
      end loop;
    end if;
  end log;

  procedure recursive_delete(ancestor varchar2, parent varchar2, pk varchar2, pk_ttidx number, indent varchar2,
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
    csv           CLOB;
    parts         number(9) := 0;
    counter       number(9);
    delete_query  varchar2(32767);
    ch_idx number := pk_ttidx + 1;
    child_cnt number;
  begin
    for child in childs(ancestor, parent) loop
      dbms_output.put_line('handling child: ' || child.table_name || ' by foreign key ' || child.FOREIGN_KEY); 
      child_pk := primary_key(child.table_name);
      fk := child.foreign_key;
      query := 'INSERT INTO ' || temp_table_name || ' (' || temp_table_idx_col || ', ' || temp_table_pkval_col 
        || ') SELECT ' || ch_idx || ', ' || child_pk || ' FROM ' || child.table_name || ' WHERE ' || child.foreign_key 
        || ' IN ( SELECT  ' || temp_table_pkval_col  || ' FROM ' || temp_table_name 
        || ' WHERE ' || temp_table_idx_col || ' = ' || pk_ttidx || ')';
      if ancestor is null then    -- case dummy root
        query := 'INSERT INTO ' || temp_table_name || ' (' || temp_table_idx_col || ', ' || temp_table_pkval_col 
        || ') SELECT ' || ch_idx || ', ' || child_pk || ' FROM ' || child.table_name || ' WHERE ' || where_clause;
        fk := child_pk;
      end if;
      execute immediate query;
      execute immediate 'select count(' || temp_table_pkval_col || ') from ' || temp_table_name 
        || ' where ' || temp_table_idx_col || ' = :idx' into child_cnt using ch_idx;
      log(indent || '+- ' || case when ancestor is null then 'ROOT' else parent end || '  ->  ' || child.table_name);
      if child_cnt = 0 then
        continue;
      end if;
      log(indent || '*  sql> ' || query || ';');
      log(indent || '*  number of records: ' || child_cnt );
      dbms_lob.freetemporary(query);
      recursive_delete(parent, child.table_name, child_pk, ch_idx, indent || '|    ');
      ch_idx := ch_idx + 1;
    end loop;
    if ancestor is null then return; end if; -- ignore dummy root, there is nothing to delete
    delete_query := 'DELETE FROM ' || parent || ' WHERE ' || nvl(pk, child_pk) 
      || ' IN ( SELECT ' || temp_table_pkval_col || ' FROM ' || temp_table_name  
        || ' WHERE ' || temp_table_idx_col || ' = :idx)';
    log(substr(indent, 1, length(indent) - 5) || '*  sql> ' || delete_query || ';');
    execute immediate delete_query USING pk_ttidx;
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
  for c in (select table_name from user_tables where table_name = temp_table_name) loop
    execute immediate 'drop table ' || c.table_name;
  end loop;
  execute immediate 'create table ' || temp_table_name || '(' || temp_table_idx_col || ' NUMBER, ' || temp_table_pkval_col || ' VARCHAR2(4000) )';
  execute immediate 'create index ' || temp_table_name || '_IDX ON ' || temp_table_name || '(' || temp_table_idx_col || ')';
  cascadelete_query := 'SQL> CASCADELETE ' || table_name || ' WHERE ' || where_clause || ';';
  log(cascadelete_query);
  do_dash(length(cascadelete_query));
  recursive_delete(null, upper(table_name), null, 1, null, where_clause);
  do_dash(length(cascadelete_query));
end cascadelete;
/
