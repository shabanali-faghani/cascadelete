# CASCADELETE
**CASCA(DE)LETE** is a stored procedure for deleting all records related by a chain or tree of constraints with one command.

## Motivation
There are some situations where a developer or a dba needs to delete some records from a table that have some related 
records in one or more child tables. Any attempt to delete these records will result in the following error:

**ORA-02292: integrity constraint \<constraint name\> violated - child record found**

This error is raised because the primary key (usually) of the target table was used as a foreign key in another table 
with some not-null values. Using **_on delete cascade_** on constraints and **_Triggers_** on tables are two common workarounds 
to avoid this error but both impose additional work to find constraints and change or add some DDL to the existing schema. 
Moreover, since constraint is essentially a safety mechanism, using these workarounds in critical multi-user databases, 
for example in a big financial database with dozen billion-dollar transactions, is something like turning the safety system 
of the Chernobyl nuclear power plant off!

To get rid of this error it is also possible to find the nodes (tables) of the constraint chain/tree heuristically and 
delete descendants records from bottom to up. It can be done by using the violated constraint name in error message to 
find the foreign key and child table and then delete related records recursively. But since this task is done manually 
it is often error prone and usually very slow. Furthermore, using this method will be very hard and sometimes practically 
impossible when data model is big, data is critical or the task must be done periodically on different base tables. The 
**_CASCADELETE_** is a solution to solve these problems.

## Caution!
The **CASCADELETE** ...
* is distributed/released **AS-IS**
* works like `$ sudo rm -rfv /` and can destroy your database
* only deletes related records by `ENABLED` fk-pk constraints
* falls into an infinite loop if there is a circular foreign key constraint chain  
* throws an exception if a node (table) in the chain has composite pk
* won't work if there is a non fk-pk constraint 

So, probably it is not a tool for you if you have composite pk, circular foreign key constraints or a non fk-pk constraint 
in your database; in your target chain/tree, indeed. The word `probably` implies that the *cascadelete* might works despite 
these problems. That's because some values of a column in a parent table that is target of a constraint might not be used in 
a child table. Altogether, I guess it will work on most databases because its limitations are related to somethings that
are not common in standard databases.

## Use Cases
* To delete wrong or undesirable data from database
* To revert database to its previous state after integration or load tests

## Installation
Run the code inside [_cascadelete.sql_](https://github.com/shabanali-faghani/cascadelete/blob/master/cascadelete.sql) 
file to add the _**CASCADELETE**_ procedure into your schema. 

## Usage
**The procedure signature:**  
`CASCADELETE(table_name VARCHAR2, where_clause VARCHAR2, log CHAR DEFAULT 'Y', input_batch_size NUMBER DEFAULT 1000)`

**It is highly recommended to ...**
* Enable `DBMS_OUTPUT` of the tool you use to see output/log
* Set the `Transaction Control` mode to `Manual`
* Do not disable log when you call the procedure manually (`'Y'`)  

### Using JetBrains DataGrip 
Press `Ctrl+F8` or click on the yellow button from top-left corner of the `Database Console` window to enable `DBMS_OUTPUT`.  

```oraclesqlplus
ex1: CALL CASCADELETE('USER', 'ID = 123456');
ex2: CALL CASCADELETE('PRODUCT', 'CODE LIKE ''%X%''');
ex3: CALL CASCADELETE('ORDER', 'ORDER_DATE > trunc(sysdate - 7)');
ex4: BEGIN
        CASCADELETE('TRANSACTION', 'trunc(TRANSACTION_DATE) = to_date(''2019-03-18'', ''YYYY-MM-DD'') ' || 
                                   'AND STATUS = ''PENDING''');
        -- ROLLBACK;
        -- COMMIT;
     END;
```

## Sample Run on SCOTT
**command:**
```sql
BEGIN
  CASCADELETE('DEPT', 'LOC = ''CHICAGO'' OR DNAME = ''RESEARCH''');
  ROLLBACK; -- undo delete, this is a test
END;
```

**output/log:**
```sql
sql> BEGIN
  CASCADELETE('DEPT', 'LOC = ''CHICAGO'' OR DNAME = ''RESEARCH''');
  ROLLBACK; -- undo delete, this is a test
END;
[2019-04-12 18:47:23] completed in 140ms
[2019-04-12 18:47:23] ------------------------------------------------------------
[2019-04-12 18:47:23] CASCADELETE DEPT WHERE LOC = 'CHICAGO' OR DNAME = 'RESEARCH'
[2019-04-12 18:47:23] ------------------------------------------------------------
[2019-04-12 18:47:23] +- NULL  ->  DEPT
[2019-04-12 18:47:23] *  sql> SELECT DEPTNO FROM DEPT WHERE LOC = 'CHICAGO' OR DNAME = 'RESEARCH'
[2019-04-12 18:47:23] *  result (part 1/1): 20, 30
[2019-04-12 18:47:23] |    +- DEPT  ->  EMP
[2019-04-12 18:47:23] |    *  sql> SELECT EMPNO FROM EMP WHERE DEPTNO IN (20, 30)
[2019-04-12 18:47:23] |    *  result (part 1/1): 7698, 7566, 7654, 7499, 7844, 7900, 7521, 7902, 7369, 7788, 7876
[2019-04-12 18:47:23] |    |    +- EMP  ->  EMP
[2019-04-12 18:47:23] |    |    *  sql> SELECT EMPNO FROM EMP WHERE MGR IN (7698, 7566, 7654, 7499, 7844, 7900, 7521, 7902, 7369, 7788, 7876)
[2019-04-12 18:47:23] |    |    *  result (part 1/1): 7654, 7499, 7844, 7900, 7521, 7902, 7369, 7788, 7876
[2019-04-12 18:47:23] |    |    |    +- EMP  ->  EMP
[2019-04-12 18:47:23] |    |    |    *  sql> SELECT EMPNO FROM EMP WHERE MGR IN (7654, 7499, 7844, 7900, 7521, 7902, 7369, 7788, 7876)
[2019-04-12 18:47:23] |    |    |    *  result (part 1/1): 7369, 7876
[2019-04-12 18:47:23] |    |    |    |    +- (EMP  ->  EMP - no child record found, continue;)
[2019-04-12 18:47:23] |    |    |    *  DELETE EMP WHERE EMPNO IN (7369, 7876)
[2019-04-12 18:47:23] |    |    *  DELETE EMP WHERE EMPNO IN (7654, 7499, 7844, 7900, 7521, 7902, 7369, 7788, 7876)
[2019-04-12 18:47:23] |    *  DELETE EMP WHERE EMPNO IN (7698, 7566, 7654, 7499, 7844, 7900, 7521, 7902, 7369, 7788, 7876)
[2019-04-12 18:47:23] *  DELETE DEPT WHERE DEPTNO IN (20, 30)
[2019-04-12 18:47:23] ------------------------------------------------------------
[2019-04-12 18:47:23]                           DONE!
[2019-04-12 18:47:23] ------------------------------------------------------------
```
