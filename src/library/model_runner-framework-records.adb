package body Model_Runner.Framework.Records is

   package E renames Model_Runner.Errors;

   Header_Schema_Id      : constant String := "schema_id";
   Header_Schema_Version : constant String := "schema_version";
   Header_Entity_Id      : constant String := "entity_id";
   Header_Revision       : constant String := "revision";

   --  Whether a name belongs to the header.
   function Is_Header (Name : String) return Boolean
   is (Name = Header_Schema_Id or else Name = Header_Schema_Version
       or else Name = Header_Entity_Id or else Name = Header_Revision);

   --  A natural number without its leading space.
   function Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   --  Where a field is, or where it would go to keep the fields sorted: by
   --  halves, since the fields are kept sorted, and past the last one at
   --  once, since a record is mostly built in order.
   procedure Locate
     (Value : Item;
      Name  : String;
      Place : out Positive;
      Found : out Boolean)
   is
      Low  : Positive := 1;
      High : Natural := Natural (Value.Fields.Length);
   begin
      Found := False;
      if High = 0 or else To_String (Value.Fields (High).Name) < Name then
         Place := High + 1;
         return;
      end if;
      while Low <= High loop
         declare
            Middle : constant Positive := (Low + High) / 2;
            Held   : constant String := To_String (Value.Fields (Middle).Name);
         begin
            if Held = Name then
               Place := Middle;
               Found := True;
               return;
            elsif Held < Name then
               Low := Middle + 1;
            else
               High := Middle - 1;
            end if;
         end;
      end loop;
      Place := Low;
   end Locate;

   -------------------
   -- Is_Field_Name --
   -------------------

   function Is_Field_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0 or else Name'Length > 256
        or else Name (Name'First) not in 'a' .. 'z' | 'A' .. 'Z'
      then
         return False;
      end if;

      for Char of Name loop
         if Char not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
                      | '_' | '.' | ':' | '-' | '/'
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_Field_Name;

   ------------
   -- Create --
   ------------

   function Create
     (Schema_Id      : String;
      Schema_Version : Positive;
      Entity_Id      : String;
      Revision       : Natural) return Item is
   begin
      return
        (Schema_Id      => To_Unbounded_String (Schema_Id),
         Schema_Version => Schema_Version,
         Entity_Id      => To_Unbounded_String (Entity_Id),
         Revision       => Revision,
         Fields         => Field_Vectors.Empty_Vector);
   end Create;

   ---------------
   -- Schema_Id --
   ---------------

   function Schema_Id (Value : Item) return String
   is (To_String (Value.Schema_Id));

   --------------------
   -- Schema_Version --
   --------------------

   function Schema_Version (Value : Item) return Positive
   is (Value.Schema_Version);

   ---------------
   -- Entity_Id --
   ---------------

   function Entity_Id (Value : Item) return String
   is (To_String (Value.Entity_Id));

   --------------
   -- Revision --
   --------------

   function Revision (Value : Item) return Natural
   is (Value.Revision);

   ------------------
   -- Set_Revision --
   ------------------

   procedure Set_Revision (Value : in out Item; To : Natural) is
   begin
      Value.Revision := To;
   end Set_Revision;

   ---------
   -- Set --
   ---------

   procedure Set (Value : in out Item; Name : String; Text : String) is
      Place : Positive;
      Found : Boolean;
   begin
      if not Is_Field_Name (Name) or else Is_Header (Name) then
         return;
      end if;

      Locate (Value, Name, Place, Found);
      if Found then
         Value.Fields (Place).Value := To_Unbounded_String (Text);
      else
         Value.Fields.Insert
           (Before   => Place,
            New_Item => Field'(Name  => To_Unbounded_String (Name),
                               Value => To_Unbounded_String (Text)));
      end if;
   end Set;

   ------------
   -- Remove --
   ------------

   procedure Remove (Value : in out Item; Name : String) is
      Place : Positive;
      Found : Boolean;
   begin
      Locate (Value, Name, Place, Found);
      if Found then
         Value.Fields.Delete (Place);
      end if;
   end Remove;

   ---------
   -- Has --
   ---------

   function Has (Value : Item; Name : String) return Boolean is
      Place : Positive;
      Found : Boolean;
   begin
      if Is_Header (Name) then
         return True;
      end if;
      Locate (Value, Name, Place, Found);
      return Found;
   end Has;

   ---------
   -- Get --
   ---------

   function Get (Value : Item; Name : String) return String is
      Place : Positive;
      Found : Boolean;
   begin
      if Name = Header_Schema_Id then
         return Schema_Id (Value);
      elsif Name = Header_Schema_Version then
         return Image (Value.Schema_Version);
      elsif Name = Header_Entity_Id then
         return Entity_Id (Value);
      elsif Name = Header_Revision then
         return Image (Value.Revision);
      end if;

      Locate (Value, Name, Place, Found);
      return (if Found then To_String (Value.Fields (Place).Value) else "");
   end Get;

   -----------------
   -- Field_Count --
   -----------------

   function Field_Count (Value : Item) return Natural
   is (Natural (Value.Fields.Length));

   ----------------
   -- Field_Name --
   ----------------

   function Field_Name (Value : Item; Index : Positive) return String
   is (To_String (Value.Fields (Index).Name));

   ---------------
   -- Serialize --
   ---------------

   function Serialize (Value : Item) return String is
      Result : Unbounded_String := To_Unbounded_String (Signature & ASCII.LF);

      procedure Emit (Name, Text : String) is
      begin
         Append (Result, Name & " " & Image (Text'Length) & ASCII.LF);
         Append (Result, Text);
         Append (Result, ASCII.LF);
      end Emit;
   begin
      Emit (Header_Schema_Id, Schema_Id (Value));
      Emit (Header_Schema_Version, Image (Value.Schema_Version));
      Emit (Header_Entity_Id, Entity_Id (Value));
      Emit (Header_Revision, Image (Value.Revision));
      for Held of Value.Fields loop
         Emit (To_String (Held.Name), To_String (Held.Value));
      end loop;
      return To_String (Result);
   end Serialize;

   --------------------
   -- Fingerprint_Of --
   --------------------

   function Fingerprint_Of (Value : Item) return String
   is (Fingerprint (Serialize (Value)));

   -----------
   -- Parse --
   -----------

   procedure Parse
     (Text   : String;
      Origin : String;
      Value  : out Item;
      Status : out Model_Runner.Errors.Error_Info)
   is
      At_Byte : Natural := Text'First;

      Seen_Schema_Id, Seen_Version, Seen_Entity, Seen_Revision : Boolean :=
        False;

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Record_Malformed);
         E.Add_Text (Status, "path", Origin, E.Param_Path);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;

      --  A decimal number of at most nine digits, which is every count
      --  and revision this format holds.
      function Number (Digits_Text : String; Result : out Natural)
        return Boolean
      is
      begin
         Result := 0;
         if Digits_Text'Length = 0 or else Digits_Text'Length > 9 then
            return False;
         end if;
         for Char of Digits_Text loop
            if Char not in '0' .. '9' then
               return False;
            end if;
            Result := Result * 10 + (Character'Pos (Char) - Character'Pos ('0'));
         end loop;
         return True;
      end Number;
   begin
      Value := (others => <>);
      Status := E.Success;

      if Text'Length < Signature'Length + 1
        or else Text (Text'First .. Text'First + Signature'Length - 1)
                  /= Signature
        or else Text (Text'First + Signature'Length) /= ASCII.LF
      then
         Refuse ("it does not begin with " & Signature);
         return;
      end if;
      At_Byte := Text'First + Signature'Length + 1;

      while At_Byte <= Text'Last loop
         declare
            Space  : Natural := 0;
            Break  : Natural := 0;
            Length : Natural;
         begin
            for Index in At_Byte .. Text'Last loop
               if Text (Index) = ' ' and then Space = 0 then
                  Space := Index;
               elsif Text (Index) = ASCII.LF then
                  Break := Index;
                  exit;
               end if;
            end loop;

            if Space = 0 or else Break = 0 or else Space > Break then
               Refuse ("a field has no length");
               return;
            end if;

            declare
               Name : constant String := Text (At_Byte .. Space - 1);
            begin
               if not Is_Field_Name (Name) then
                  Refuse ("a field name is not one");
                  return;
               elsif not Number (Text (Space + 1 .. Break - 1), Length) then
                  Refuse ("field " & Name & " has no length");
                  return;
               elsif Length > Text'Last - Break
                 or else Text'Last - Break - Length < 1
                 or else Text (Break + Length + 1) /= ASCII.LF
               then
                  Refuse ("field " & Name & " runs past the end");
                  return;
               end if;

               declare
                  Field_Text : constant String :=
                    Text (Break + 1 .. Break + Length);
                  Count      : Natural;
               begin
                  if Name = Header_Schema_Id then
                     if Seen_Schema_Id then
                        Refuse ("field " & Name & " is given twice");
                        return;
                     end if;
                     Seen_Schema_Id := True;
                     Value.Schema_Id := To_Unbounded_String (Field_Text);

                  elsif Name = Header_Schema_Version then
                     if Seen_Version then
                        Refuse ("field " & Name & " is given twice");
                        return;
                     elsif not Number (Field_Text, Count) or else Count = 0
                     then
                        Refuse ("the schema version is not a number");
                        return;
                     end if;
                     Seen_Version := True;
                     Value.Schema_Version := Count;

                  elsif Name = Header_Entity_Id then
                     if Seen_Entity then
                        Refuse ("field " & Name & " is given twice");
                        return;
                     end if;
                     Seen_Entity := True;
                     Value.Entity_Id := To_Unbounded_String (Field_Text);

                  elsif Name = Header_Revision then
                     if Seen_Revision then
                        Refuse ("field " & Name & " is given twice");
                        return;
                     elsif not Number (Field_Text, Count) then
                        Refuse ("the revision is not a number");
                        return;
                     end if;
                     Seen_Revision := True;
                     Value.Revision := Count;

                  elsif Has (Value, Name) then
                     Refuse ("field " & Name & " is given twice");
                     return;

                  else
                     Set (Value, Name, Field_Text);
                  end if;
               end;

               At_Byte := Break + Length + 2;
            end;
         end;
      end loop;

      if not (Seen_Schema_Id and then Seen_Version and then Seen_Entity
              and then Seen_Revision)
      then
         Refuse ("its header is not whole");
      end if;
   end Parse;

end Model_Runner.Framework.Records;
