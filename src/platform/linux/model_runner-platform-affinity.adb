with Ada.Text_IO;
with System;
with Model_Runner.Text;

package body Model_Runner.Platform.Affinity is
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned_char;
   function Get (Pid : Interfaces.C.int; Size : Interfaces.C.size_t;
                 Set : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "sched_getaffinity";
   function Put (Pid : Interfaces.C.int; Size : Interfaces.C.size_t;
                 Set : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "sched_setaffinity";

   function Allowed (Set : Mask; Processor : Natural) return Boolean is
     (Processor < Set'Length * 8 and then
      (Set (Processor / 8) and Interfaces.C.unsigned_char (2 ** (Processor mod 8))) /= 0);

   function Choose (Count : Positive) return Core_List is
      Result : Core_List (0 .. Count - 1) := [others => -1];
      Usable : aliased Mask;
      Seen : array (0 .. 1023) of Boolean := [others => False];
      Found : Natural := 0;
      File : Ada.Text_IO.File_Type;
   begin
      if Get (0, Usable'Length, Usable'Address) /= 0 then return Result; end if;
      for Processor in Seen'Range loop
         if Allowed (Usable, Processor) then
            Ada.Text_IO.Open
              (File, Ada.Text_IO.In_File,
               "/sys/devices/system/cpu/cpu" & Model_Runner.Text.Trim (Integer'Image (Processor))
               & "/topology/thread_siblings_list", Form => "shared=no");
            declare
               Line : String (1 .. 512);
               Last : Natural;
               Core : Integer;
            begin
               Ada.Text_IO.Get_Line (File, Line, Last);
               Ada.Text_IO.Close (File);
               Core := Model_Runner.Text.Leading_Number (Line (1 .. Last));
               if Core not in Seen'Range then return [Result'Range => -1]; end if;
               if not Seen (Core) then
                  Seen (Core) := True;
                  Result (Found) := Processor;
                  Found := Found + 1;
                  if Found = Count then return Result; end if;
               end if;
            end;
         end if;
      end loop;
      return [Result'Range => -1];
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then Ada.Text_IO.Close (File); end if;
         return [Result'Range => -1];
   end Choose;

   procedure Pin (Item : in out Binding; Processor : Integer) is
      Single : aliased Mask := [others => 0];
   begin
      if Item.Active or else Processor < 0 then return; end if;
      if Get (0, Item.Saved'Length, Item.Saved'Address) /= 0
        or else not Allowed (Item.Saved, Processor)
      then return; end if;
      Single (Processor / 8) := Interfaces.C.unsigned_char (2 ** (Processor mod 8));
      Item.Active := Put (0, Single'Length, Single'Address) = 0;
   end Pin;

   overriding procedure Finalize (Item : in out Binding) is
      Ignored : Interfaces.C.int;
      pragma Unreferenced (Ignored);
   begin
      if Item.Active then
         Ignored := Put (0, Item.Saved'Length, Item.Saved'Address);
         Item.Active := False;
      end if;
   end Finalize;
end Model_Runner.Platform.Affinity;
