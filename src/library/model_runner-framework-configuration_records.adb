package body Model_Runner.Framework.Configuration_Records is
   package E renames Model_Runner.Errors;
   use type E.Error_Code;

   Current_Name   : constant String := "resolved";
   Current_Entity : constant String := "PROJECT-CONFIG";

   type Text_Access is access constant String;
   Provenance : constant array (1 .. 5) of Text_Access :=
     [new String'("template_id"),
      new String'("template_version"),
      new String'("template_fingerprint"),
      new String'("template_origin"),
      new String'("template_order")];

   function Copy (Value : Records.Item; Entity_Id : String) return Records.Item is
      Result : Records.Item :=
        Records.Create (Records.Schema_Id (Value), Records.Schema_Version (Value), Entity_Id, 1);
   begin
      for Index in 1 .. Records.Field_Count (Value) loop
         Records.Set
           (Result, Records.Field_Name (Value, Index), Records.Get (Value, Records.Field_Name (Value, Index)));
      end loop;
      return Result;
   end Copy;

   function Fingerprint (Value : Records.Item) return String is
      Meaning : Records.Item := Copy (Value, Current_Entity);
   begin
      Records.Remove (Meaning, "configuration_fingerprint");
      for Field of Provenance loop
         Records.Remove (Meaning, Field.all);
      end loop;
      return Records.Fingerprint_Of (Meaning);
   end Fingerprint;

   procedure Read
     (Item : Stores.Store; Value : out Records.Item; Status : out Model_Runner.Errors.Error_Info) is
   begin
      Stores.Read (Item, Config_Area, Current_Name, Value, Status);
      if E.Is_Ok (Status) and then Records.Get (Value, "configuration_fingerprint") /= Fingerprint (Value) then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "path", Directory_Name (Config_Area) & "/" & Current_Name, E.Param_Path);
      end if;
   end Read;

   function Unreadable (Status : Model_Runner.Errors.Error_Info) return Boolean is
     (E.Is_Error (Status) and then Status.Code /= E.Framework_Not_Found);

   function Required (Item : Stores.Store) return Records.Item is
      Value  : Records.Item;
      None   : Records.Item;
      Status : E.Error_Info;
   begin
      Read (Item, Value, Status);
      if Unreadable (Status) then
         raise Configuration_Unavailable
           with "the project's configuration cannot be read: " & E.Error_Code'Image (Status.Code) &
             (if E.Text_Of (Status, "detail") = "" then "" else " (" & E.Text_Of (Status, "detail") & ")");
      end if;
      return (if E.Is_Error (Status) then None else Value);
   end Required;
end Model_Runner.Framework.Configuration_Records;
