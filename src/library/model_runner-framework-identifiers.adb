package body Model_Runner.Framework.Identifiers is

   --------------
   -- Is_Valid --
   --------------

   function Is_Valid (Text : String) return Boolean is
      Word_Start : Boolean := True;
   begin
      if Text'Length = 0 or else Text'Length > 128
        or else Text (Text'First) not in 'A' .. 'Z'
        or else Text (Text'Last) = '-'
      then
         return False;
      end if;

      for Char of Text loop
         if Char = '-' then
            if Word_Start then
               return False;
            end if;
            Word_Start := True;
         elsif Char in 'A' .. 'Z' | '0' .. '9' | '_' then
            Word_Start := False;
         else
            return False;
         end if;
      end loop;
      return True;
   end Is_Valid;

   ------------
   -- Format --
   ------------

   function Format
     (Namespace : String;
      Key       : String;
      Number    : Positive) return String
   is
      Image  : constant String := Positive'Image (Number);
      Plain  : constant String := Image (Image'First + 1 .. Image'Last);
      Padded : constant String :=
        (if Plain'Length >= 3 then Plain
         else [1 .. 3 - Plain'Length => '0'] & Plain);
   begin
      return
        (if Key = "" then Namespace & "-" & Padded
         else Namespace & "-" & Key & "-" & Padded);
   end Format;

   --------------------
   -- Empty_Counters --
   --------------------

   function Empty_Counters return Records.Item
   is (Records.Create (Counters_Schema, 1, Counters_Entity, 1));

   ---------------------
   -- Allocate_Number --
   ---------------------

   function Allocate_Number
     (Counters  : in out Records.Item;
      Namespace : String;
      Key       : String) return Natural
   is
      Stem  : constant String :=
        (if Key = "" then Namespace else Namespace & "-" & Key);
      Field : constant String := "next." & Stem;
      Held  : constant String := Records.Get (Counters, Field);
      Next  : Natural := 0;
   begin
      if not Is_Valid (Stem) or else not Is_Valid (Namespace) then
         return 0;
      end if;

      for Char of Held loop
         if Char not in '0' .. '9' or else Next > 99_999_999 then
            return 0;
         end if;
         Next := Next * 10 + (Character'Pos (Char) - Character'Pos ('0'));
      end loop;
      Next := Natural'Max (Next, 1);

      declare
         Following : constant String := Natural'Image (Next + 1);
      begin
         Records.Set
           (Counters, Field, Following (Following'First + 1 .. Following'Last));
      end;
      return Next;
   end Allocate_Number;

   --------------
   -- Allocate --
   --------------

   function Allocate
     (Counters  : in out Records.Item;
      Namespace : String;
      Key       : String) return String
   is
      Number : constant Natural := Allocate_Number (Counters, Namespace, Key);
   begin
      return (if Number = 0 then "" else Format (Namespace, Key, Number));
   end Allocate;

end Model_Runner.Framework.Identifiers;
