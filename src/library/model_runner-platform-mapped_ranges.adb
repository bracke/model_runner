with System.Storage_Elements;

package body Model_Runner.Platform.Mapped_Ranges is

   use System.Storage_Elements;
   use type Model_Runner.Bytes.Byte_Count;

   --  A model in several files maps one each; a run holds a handful.
   Most : constant := 64;

   type Run is record
      First : Integer_Address := 0;
      Last  : Integer_Address := 0;
   end record;

   type Run_Table is array (1 .. Most) of Run;

   protected Table is
      procedure Note (First, Last : Integer_Address);
      procedure Forget (First : Integer_Address);
      function Holds (First, Last : Integer_Address) return Boolean;
   private
      Runs : Run_Table;
   end Table;

   protected body Table is
      procedure Note (First, Last : Integer_Address) is
      begin
         for R of Runs loop
            if R.Last = 0 then
               R := (First, Last);
               return;
            end if;
         end loop;
      end Note;

      procedure Forget (First : Integer_Address) is
      begin
         for R of Runs loop
            if R.Last /= 0 and then R.First = First then
               R := (0, 0);
            end if;
         end loop;
      end Forget;

      function Holds (First, Last : Integer_Address) return Boolean is
      begin
         return (for some R of Runs =>
                   R.Last /= 0 and then First >= R.First and then Last <= R.Last);
      end Holds;
   end Table;

   procedure Note (Start : System.Address; Length : Model_Runner.Bytes.Byte_Count) is
   begin
      if Length > 0 then
         Table.Note (To_Integer (Start),
                     To_Integer (Start) + Integer_Address (Length));
      end if;
   end Note;

   procedure Forget (Start : System.Address) is
   begin
      Table.Forget (To_Integer (Start));
   end Forget;

   function Holds
     (Start : System.Address; Length : Model_Runner.Bytes.Byte_Count)
      return Boolean
   is (Table.Holds (To_Integer (Start),
                    To_Integer (Start) + Integer_Address (Length)));

end Model_Runner.Platform.Mapped_Ranges;
