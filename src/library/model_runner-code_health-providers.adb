with Ada.Characters.Handling;

package body Model_Runner.Code_Health.Providers is

   package E renames Model_Runner.Errors;

   procedure Refuse
     (Status : out E.Error_Info;
      Name   : String;
      Value  : String;
      Detail : String) is
   begin
      Status := E.Make (E.Framework_Schema_Violation);
      E.Add_Text (Status, "name", Name);
      E.Add_Text (Status, "value", Value);
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   function Valid_Identifier (Value : String) return Boolean is
   begin
      return Value'Length > 0
        and then Value (Value'First) in 'a' .. 'z'
        and then (for all Letter of Value =>
                    Letter in 'a' .. 'z' | '0' .. '9' | '-' | '_');
   end Valid_Identifier;

   function Valid_Version (Value : String) return Boolean is
   begin
      return Value'Length > 0
        and then (for all Letter of Value =>
                    Ada.Characters.Handling.Is_Alphanumeric (Letter)
                    or else Letter in '.' | '-' | '_' | '+');
   end Valid_Version;

   procedure Register
     (Into   : in out Registry;
      Item   : not null Provider_Reference;
      Status : out E.Error_Info)
   is
      Id : constant String := Identifier (Item.all);
   begin
      if not Valid_Identifier (Id) then
         Refuse (Status, "provider", Id, "invalid provider identifier");
         return;
      elsif not Valid_Version (Version (Item.all)) then
         Refuse (Status, "provider", Id, "invalid provider version");
         return;
      elsif Contains (Into, Id) then
         Refuse (Status, "provider", Id, "duplicate provider identifier");
         return;
      end if;

      --  Keep the registry sorted, making selection independent of startup
      --  registration order.
      for Index in 1 .. Natural (Into.Items.Length) loop
         if Id < Identifier (Into.Items.Element (Index).all) then
            Into.Items.Insert (Index, Item);
            Status := E.Success;
            return;
         end if;
      end loop;
      Into.Items.Append (Item);
      Status := E.Success;
   end Register;

   function Length (From : Registry) return Natural is
     (Natural (From.Items.Length));

   function Length (From : Provider_List) return Natural is
     (Natural (From.Items.Length));

   function Element
     (From  : Provider_List;
      Index : Positive) return Provider_Reference is
     (From.Items.Element (Index));

   function Contains
     (Within     : Registry;
      Identifier : String) return Boolean is
     (Find (Within, Identifier) /= null);

   function Find
     (Within     : Registry;
      Identifier : String) return Provider_Reference is
   begin
      for Item of Within.Items loop
         if Providers.Identifier (Item.all) = Identifier then
            return Item;
         end if;
      end loop;
      return null;
   end Find;

   function Select_Providers
     (From  : Registry;
      Path  : String;
      Level : Check_Level) return Provider_List
   is
      Result : Provider_List;
   begin
      for Item of From.Items loop
         if Supports (Item.all, Path, Level) then
            Result.Items.Append (Item);
         end if;
      end loop;
      return Result;
   end Select_Providers;

end Model_Runner.Code_Health.Providers;
