-- on SCOTT user
CALL CASCADELETE('DEPT', 'LOC = ''CHICAGO''');

BEGIN
  CASCADELETE('DEPT', 'LOC = ''CHICAGO'' OR DNAME = ''RESEARCH''');
  ROLLBACK; -- undo delete, this is a test
END;

-- on HR user
-- test "composite primary key" error
CALL CASCADELETE('JOBS', 'JOB_TITLE = ''President''');
