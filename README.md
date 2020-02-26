# CASCADELETE
The _CASCA**DE**LETE_ is a stored procedure for deleting all records related to each other by a chain or tree of constraints by using one command.

## Motivation
There are some situations where a developer or a dba needs to delete some records from a table that have some related 
records in one or more child tables. Any attempt to delete these records will result in the following error:

**ORA-02292: integrity constraint \<constraint name\> violated - child record found**

This error is raised because the primary key (usually) of the target table was used as a foreign key in another table 
with some not-null values. Using **_on delete cascade_** on constraints and **_Triggers_** on tables are two common workarounds 
to avoid this error but both impose additional work to find constraints and change or add some DDL to the existing schema. 
Moreover, since constraint is essentially a safety mechanism, using these workarounds in critical multi-user databases, in a big financial database with dozen billion-dollar transactions, for example, is something like turning the safety system 
of the Chernobyl nuclear power plant off!

To get rid of this error it is also possible to find the nodes (tables) of the constraint chain/tree heuristically and 
delete descendants records from bottom to up. It can be done by using the violated constraint name in  error message to 
find the foreign key and child table and then delete related records recursively. But since this task is done manually 
it is often error prone and usually very slow. Furthermore, using this method will be very hard and sometimes practically 
impossible when data model is big, data is critical or the task must be done periodically on different base tables. The 
**_CASCADELETE_** is a solution to solve these problems.

## Disclamation!
The *CASCADELETE* ...
* is distributed/released as-is
* works like `$ sudo rm -rfv /` and can destroy your database
* only deletes related records by `ENABLED` fk-pk constraints (change it if you need)
* falls into an infinite loop if there is a circular foreign key constraint chain  
* throws an exception if a node (table) in the chain has a composite pk
* won't work if there is a non fk-pk constraint 

So, probably this is not a tool for you if you have composite pk, circular foreign key constraints or a non fk-pk constraint 
in your database; in your target chain/tree, indeed. The word `probably` implies that the *cascadelete* might works despite 
these problems. That's because some values of a column in a parent table that is target of a constraint, may not be used in 
the child table. Altogether, it should work on the majority of databases because the mentioned limitations are not common.

## Installation
Copy/paste the content of [_cascadelete.sql_](https://github.com/shabanali-faghani/cascadelete/blob/master/cascadelete.sql) file into your database's console tool and run.  

## Usage

#### It is highly recommended to ...
* Enable `DBMS_OUTPUT` of the tool you use to see output/log
* Set the `Transaction Control` mode to `Manual`
* Do not disable logging when you call the procedure manually  

#### Using JetBrains DataGrip v.2019.2.5
1. Press `Ctrl+F8` or click on the `Enable SYS.DBMS_OUTPUT (Ctrl+F8)` button of the `Services` window.  
2. Check and increase the value of `Override console cycle buffer size (1024 KB)` option from 
   `File > Settings > Editor > General > Console`. This is needed when the number of deleted records are big.    

```oraclesqlplus
ex1: CALL CASCADELETE('USER', 'ID = 123456');
ex2: CALL CASCADELETE('PRODUCT', 'CODE LIKE ''%X%''');
ex3: CALL CASCADELETE('ORDER', 'ORDERDATE > trunc(sysdate - 7)');
ex4: BEGIN
        CASCADELETE('TRANSACTION', 'trunc(TRANSACTIONDATE) = to_date(''2019-03-18'', ''YYYY-MM-DD'') ' || 
                                   'AND STATUS = ''PENDING''');
        -- ROLLBACK;
        -- COMMIT;
     END;
```

## Sample Run (obfuscated)
**command:**
```sql
BEGIN
  CASCADELETE('TABLE_A', 'CODE LIKE ''ABCD%''');
  ROLLBACK; -- undo cascadelete, this is a test!
END;
```

**output/log:**
```sql
MY_USER> BEGIN
           CASCADELETE('TABLE_A', 'CODE LIKE ''ABCD%''');
           ROLLBACK; -- undo cascadelete, this is a test!
         END;
[2020-02-26 12:21:42] completed in 2 s 395 ms
[2020-02-26 12:21:42] SQL> CASCADELETE TABLE_A WHERE CODE LIKE 'ABCD%';
[2020-02-26 12:21:42] -------------------------------------------------
[2020-02-26 12:21:42] +- ROOT  ->  TABLE_A
[2020-02-26 12:21:43] *  sql> SELECT ID FROM TABLE_A WHERE CODE LIKE 'ABCD%';
[2020-02-26 12:21:43] *  result (part 1/1): 181434
[2020-02-26 12:21:43] |    +- TABLE_A  ->  TABLE_B
[2020-02-26 12:21:43] |    +- TABLE_A  ->  TABLE_C
[2020-02-26 12:21:43] |    *  sql> SELECT ID FROM TABLE_C WHERE C_A_FK IN (181434);
[2020-02-26 12:21:43] |    *  result (part 1/1): 176170
[2020-02-26 12:21:43] |    |    +- TABLE_C  ->  TABLE_D
[2020-02-26 12:21:43] |    |    *  sql> SELECT ID FROM TABLE_D WHERE D_C_FK IN (176170);
[2020-02-26 12:21:43] |    |    *  result (part 1/1): 421730, 421731, 421732, 421733, 421734, 421735, 421736, 421737, 421738
[2020-02-26 12:21:43] |    |    *  sql> DELETE TABLE_D WHERE ID IN (421730, 421731, 421732, 421733, 421734, 421735, 421736, 421737, 421738);
[2020-02-26 12:21:43] |    *  sql> DELETE TABLE_C WHERE ID IN (176170);
[2020-02-26 12:21:43] |    +- TABLE_A  ->  TABLE_E
[2020-02-26 12:21:43] |    *  sql> SELECT ID FROM TABLE_E WHERE E_A_FK IN (181434);
[2020-02-26 12:21:43] |    *  result (part 1/1): 181681
[2020-02-26 12:21:43] |    *  sql> DELETE TABLE_E WHERE ID IN (181681);
[2020-02-26 12:21:43] *  sql> DELETE TABLE_A WHERE ID IN (181434);
[2020-02-26 12:21:43] -------------------------------------------------
```
