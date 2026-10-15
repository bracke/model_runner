with System.Storage_Elements;

package body Model_Runner.Platform.Mapped_Ranges is

   use System.Storage_Elements;
   use type Model_Runner.Bytes.Byte_Count;

   --  A model in several files maps one each; a run holds a handful.
   Most : constant := 64;

   type Run is record
      First  : Integer_Address := 0;
      Last   : Integer_Address := 0;
      Handle : Long_Long_Integer := -1;
   end record;

   type Run_Table is array (1 .. Most) of Run;

   protected Table is
      procedure Note (First, Last : Integer_Address; Handle : Long_Long_Integer);

      --  Waits while a handle Locate gave out is being opened again: a
      --  region closed under that, its descriptor's number taken by the
      --  next file opened, was another file read and called this one.
      entry Forget (First : Integer_Address);
      function Holds (First, Last : Integer_Address) return Boolean;
      procedure Locate
        (First, Last : Integer_Address;
         Handle      : out Long_Long_Integer;
         Base        : out Integer_Address);
      procedure Located_Done;
   private
      Runs    : Run_Table;
      Readers : Natural := 0;
   end Table;

   protected body Table is
      procedure Note (First, Last : Integer_Address; Handle : Long_Long_Integer) is
      begin
         for R of Runs loop
            if R.Last = 0 then
               R := (First, Last, Handle);
               return;
            end if;
         end loop;
      end Note;

      entry Forget (First : Integer_Address) when Readers = 0 is
      begin
         for R of Runs loop
            if R.Last /= 0 and then R.First = First then
               R := (0, 0, -1);
            end if;
         end loop;
      end Forget;

      function Holds (First, Last : Integer_Address) return Boolean is
      begin
         return (for some R of Runs =>
                   R.Last /= 0 and then First >= R.First and then Last <= R.Last);
      end Holds;

      procedure Locate
        (First, Last : Integer_Address;
         Handle      : out Long_Long_Integer;
         Base        : out Integer_Address) is
      begin
         Handle := -1;
         Base := 0;
         for R of Runs loop
            if R.Last /= 0 and then First >= R.First and then Last <= R.Last
            then
               Handle := R.Handle;
               Base := R.First;
               if Handle >= 0 then
                  Readers := Readers + 1;
               end if;
               return;
            end if;
         end loop;
      end Locate;

      procedure Located_Done is
      begin
         if Readers > 0 then
            Readers := Readers - 1;
         end if;
      end Located_Done;
   end Table;

   procedure Note
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count;
      Handle : Long_Long_Integer := -1) is
   begin
      if Length > 0 then
         Table.Note (To_Integer (Start),
                     To_Integer (Start) + Integer_Address (Length), Handle);
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

   function Locate
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count;
      Handle : out Long_Long_Integer;
      Offset : out Model_Runner.Bytes.Byte_Count) return Boolean
   is
      Base : Integer_Address;
   begin
      Table.Locate (To_Integer (Start),
                    To_Integer (Start) + Integer_Address (Length),
                    Handle, Base);
      Offset := (if Handle >= 0
                 then Model_Runner.Bytes.Byte_Count (To_Integer (Start) - Base)
                 else 0);
      return Handle >= 0;
   end Locate;

   procedure Located_Done is
   begin
      Table.Located_Done;
   end Located_Done;

end Model_Runner.Platform.Mapped_Ranges;
