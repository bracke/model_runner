with Ada.Characters.Handling;

with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Facts is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   --  Facts are kept as fact.<key>.
   Prefix : constant String := "fact.";

   function Word (Image : String) return String
   is (Ada.Characters.Handling.To_Lower (Image));

   ------------
   -- Is_Key --
   ------------

   function Is_Key (Key : String) return Boolean
   is (Key'Length in 1 .. 64
       and then Key (Key'First) in 'a' .. 'z'
       and then (for all Char of Key => Char in 'a' .. 'z' | '0' .. '9' | '_'));

   -----------------
   -- Record_Fact --
   -----------------

   procedure Record_Fact
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Value  : Fact;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Key : constant String := To_String (Value.Key);
   begin
      if not Is_Key (Key) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Key);
         return;
      end if;

      declare
         Stored : Records.Item :=
           Records.Create
             (Schemas.Fact_Schema, 1,
              "FACT-" & Ada.Characters.Handling.To_Upper (Key),
              Stores.Current_Revision (Item, Project_Area, Prefix & Key) + 1);
      begin
         Records.Set (Stored, "key", Key);
         Records.Set (Stored, "value", To_String (Value.Value));
         Records.Set (Stored, "source", Word (Value.Source'Image));
         Records.Set (Stored, "confidence", Word (Value.Confidence'Image));
         if Value.Origin /= Null_Unbounded_String then
            Records.Set (Stored, "origin", To_String (Value.Origin));
         end if;
         Stores.Put (Change, Project_Area, Prefix & Key, Stored);
      end;
      Status := E.Success;
   end Record_Fact;

   ----------
   -- Find --
   ----------

   procedure Find
     (Item   : Stores.Store;
      Key    : String;
      Value  : out Fact;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Stored : Records.Item;
   begin
      Value := (others => <>);
      if not Is_Key (Key) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Key);
         return;
      end if;

      Stores.Read (Item, Project_Area, Prefix & Key, Stored, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Value.Key := To_Unbounded_String (Records.Get (Stored, "key"));
      Value.Value := To_Unbounded_String (Records.Get (Stored, "value"));
      Value.Origin := To_Unbounded_String (Records.Get (Stored, "origin"));

      --  The schema allows only these words, so each is one of them.
      for Source in Derivation_Source loop
         if Word (Source'Image) = Records.Get (Stored, "source") then
            Value.Source := Source;
         end if;
      end loop;
      for Level in Confidence_Level loop
         if Word (Level'Image) = Records.Get (Stored, "confidence") then
            Value.Confidence := Level;
         end if;
      end loop;
   end Find;

   ----------
   -- Keys --
   ----------

   function Keys (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Project_Area) loop
         if Name'Length > Prefix'Length
           and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
         then
            Result.Append (Name (Name'First + Prefix'Length .. Name'Last));
         end if;
      end loop;
      return Result;
   end Keys;

end Model_Runner.Framework.Facts;
