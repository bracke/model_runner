with Ada.Strings.Fixed;
with Ada.Text_IO;

with Model_Runner.Platform;

package body Model_Runner.Config is

   Max_Entries : constant := 128;
   Max_Length  : constant := 1024;

   subtype Entry_Text is String (1 .. Max_Length);

   type Setting is record
      Key_Last   : Natural := 0;
      Key_Text   : Entry_Text := [others => ' '];
      Value_Last : Natural := 0;
      Value_Text : Entry_Text := [others => ' '];
   end record;

   Store  : array (1 .. Max_Entries) of Setting;
   Filled : Natural := 0;
   Loaded : Boolean := False;

   function Trim (Item : String) return String
   is (Ada.Strings.Fixed.Trim (Item, Ada.Strings.Both));

   --  Read the file into the store, once. A line is `key = value`, a `#`
   --  begins a comment, and a key already seen is not replaced -- the first
   --  wins, as a flag given twice is refused. Any trouble reading leaves
   --  the store as it is, so a broken file is no settings rather than a
   --  failure.
   procedure Ensure_Loaded is
      Path : constant String := Model_Runner.Platform.Config_File;
      File : Ada.Text_IO.File_Type;

      procedure Remember (Key : String; Value : String) is
      begin
         if Key = "" or else Filled >= Max_Entries then
            return;
         end if;
         for I in 1 .. Filled loop
            if Store (I).Key_Text (1 .. Store (I).Key_Last) = Key then
               return;
            end if;
         end loop;
         if Key'Length <= Max_Length and then Value'Length <= Max_Length then
            Filled := Filled + 1;
            Store (Filled).Key_Last := Key'Length;
            Store (Filled).Key_Text (1 .. Key'Length) := Key;
            Store (Filled).Value_Last := Value'Length;
            Store (Filled).Value_Text (1 .. Value'Length) := Value;
         end if;
      end Remember;
   begin
      if Loaded then
         return;
      end if;
      Loaded := True;

      if Path = "" then
         return;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Raw  : constant String := Ada.Text_IO.Get_Line (File);
            Hash : constant Natural :=
              Ada.Strings.Fixed.Index (Raw, "#");
            Line : constant String :=
              (if Hash = 0 then Raw else Raw (Raw'First .. Hash - 1));
            Eq   : constant Natural :=
              Ada.Strings.Fixed.Index (Line, "=");
         begin
            if Eq /= 0 then
               Remember
                 (Trim (Line (Line'First .. Eq - 1)),
                  Trim (Line (Eq + 1 .. Line'Last)));
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Ensure_Loaded;

   -----------
   -- Value --
   -----------

   function Value (Key : String) return String is
   begin
      Ensure_Loaded;
      for I in 1 .. Filled loop
         if Store (I).Key_Text (1 .. Store (I).Key_Last) = Key then
            return Store (I).Value_Text (1 .. Store (I).Value_Last);
         end if;
      end loop;
      return "";
   end Value;

   ---------
   -- Has --
   ---------

   function Has (Key : String) return Boolean is
   begin
      Ensure_Loaded;
      for I in 1 .. Filled loop
         if Store (I).Key_Text (1 .. Store (I).Key_Last) = Key then
            return True;
         end if;
      end loop;
      return False;
   end Has;

   -----------
   -- Count --
   -----------

   function Count return Natural is
   begin
      Ensure_Loaded;
      return Filled;
   end Count;

   ------------
   -- Key_At --
   ------------

   function Key_At (Index : Positive) return String is
   begin
      Ensure_Loaded;
      return Store (Index).Key_Text (1 .. Store (Index).Key_Last);
   end Key_At;

   --------------
   -- Value_At --
   --------------

   function Value_At (Index : Positive) return String is
   begin
      Ensure_Loaded;
      return Store (Index).Value_Text (1 .. Store (Index).Value_Last);
   end Value_At;

end Model_Runner.Config;
