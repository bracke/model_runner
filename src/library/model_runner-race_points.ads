--  Places where something else may change a file between two steps that
--  must see it alike -- a look and the write that rests on it -- named so a
--  test can make that happen there, deterministically, where in use it
--  happens only now and then. Nothing is done at a point nobody armed.
--
--  Task safety: arming and passing are for one test at a time.
package Model_Runner.Race_Points is

   --  The places: a workspace's taking in, after its conflicts were judged
   --  and before its files are written or removed; read_file, after the
   --  file was read and before its revision stamp is given.
   type Point is (Take_In_Writes, Read_File_Stamps);

   --  What a test does at a point.
   type Action is access procedure;

   --  Do Then_Do the next time Here is passed: once, and then not again.
   --
   --  @param Where The place.
   --  @param Then_Do What is done there.
   procedure Arm (Where : Point; Then_Do : not null Action);

   --  The code's own mark of a place: what was armed for it is done.
   --
   --  @param Where This place.
   procedure Here (Where : Point);

end Model_Runner.Race_Points;
