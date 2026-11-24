with Model_Runner.Grammar;

package body Model_Runner.Schema is

   package E renames Model_Runner.Errors;

   --  A reader over the schema text.
   --
   --  Enough JSON to read a schema and no more: objects, arrays, strings,
   --  numbers, the three literals. It never allocates and never raises; a
   --  text it cannot read is a position it reports.
   type Reader is record
      At_Char : Natural := 0;
      Failed  : Boolean := False;
      Where   : Natural := 0;
   end record;

   procedure Skip_Blanks (Text : String; Item : in out Reader) is
   begin
      while Item.At_Char <= Text'Last
        and then (Text (Item.At_Char) = ' '
                  or else Text (Item.At_Char) = Character'Val (9)
                  or else Text (Item.At_Char) = Character'Val (10)
                  or else Text (Item.At_Char) = Character'Val (13))
      loop
         Item.At_Char := Item.At_Char + 1;
      end loop;
   end Skip_Blanks;

   procedure Fail (Item : in out Reader) is
   begin
      if not Item.Failed then
         Item.Failed := True;
         Item.Where := Item.At_Char;
      end if;
   end Fail;

   --  Read a quoted string, giving back where its contents are. The bounds
   --  are into the schema text, so nothing is copied.
   procedure Read_String
     (Text  : String;
      Item  : in out Reader;
      First : out Natural;
      Last  : out Natural)
   is
   begin
      First := 1;
      Last := 0;

      Skip_Blanks (Text, Item);
      if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '"' then
         Fail (Item);
         return;
      end if;

      Item.At_Char := Item.At_Char + 1;
      First := Item.At_Char;

      while Item.At_Char <= Text'Last and then Text (Item.At_Char) /= '"' loop
         --  An escape takes the next character with it, so that a quote
         --  inside a string does not end it.
         if Text (Item.At_Char) = '\' then
            Item.At_Char := Item.At_Char + 1;
         end if;
         Item.At_Char := Item.At_Char + 1;
      end loop;

      if Item.At_Char > Text'Last then
         Fail (Item);
         return;
      end if;

      Last := Item.At_Char - 1;
      Item.At_Char := Item.At_Char + 1;
   end Read_String;

   --  Where a value begins and ends, whatever kind it is. Used for the
   --  literals of enum and const, which are written into the grammar exactly
   --  as the schema wrote them.
   procedure Read_Value
     (Text  : String;
      Item  : in out Reader;
      First : out Natural;
      Last  : out Natural;
      Depth : Natural := 0)
   is
      Opened : Natural := 0;
   begin
      First := 1;
      Last := 0;

      if Depth > Max_Depth then
         Fail (Item);
         return;
      end if;

      Skip_Blanks (Text, Item);
      if Item.At_Char > Text'Last then
         Fail (Item);
         return;
      end if;

      First := Item.At_Char;

      case Text (Item.At_Char) is
         when '"' =>
            declare
               Ignored_First, Ignored_Last : Natural;
            begin
               Read_String (Text, Item, Ignored_First, Ignored_Last);
            end;

         when '{' | '[' =>
            --  Balanced, counting only brackets outside strings.
            loop
               if Item.At_Char > Text'Last then
                  Fail (Item);
                  return;
               end if;

               case Text (Item.At_Char) is
                  when '{' | '[' =>
                     Opened := Opened + 1;
                     Item.At_Char := Item.At_Char + 1;

                  when '}' | ']' =>
                     Opened := Opened - 1;
                     Item.At_Char := Item.At_Char + 1;
                     exit when Opened = 0;

                  when '"' =>
                     declare
                        Ignored_First, Ignored_Last : Natural;
                     begin
                        Read_String (Text, Item, Ignored_First, Ignored_Last);
                        exit when Item.Failed;
                     end;

                  when others =>
                     Item.At_Char := Item.At_Char + 1;
               end case;
            end loop;

         when others =>
            --  A number or one of the three literals: everything up to the
            --  next separator.
            while Item.At_Char <= Text'Last
              and then Text (Item.At_Char) /= ','
              and then Text (Item.At_Char) /= '}'
              and then Text (Item.At_Char) /= ']'
              and then Text (Item.At_Char) /= ' '
              and then Text (Item.At_Char) /= Character'Val (9)
              and then Text (Item.At_Char) /= Character'Val (10)
              and then Text (Item.At_Char) /= Character'Val (13)
            loop
               Item.At_Char := Item.At_Char + 1;
            end loop;
      end case;

      Last := Item.At_Char - 1;
      if Last < First then
         Fail (Item);
      end if;
   end Read_Value;

   --  Find a member of the object beginning at From, and say where its value
   --  begins. Zero when the object has no such member.
   procedure Find_Member
     (Text  : String;
      From  : Natural;
      Name  : String;
      At_Value : out Natural;
      Failed   : out Boolean)
   is
      Item : Reader := (At_Char => From, others => <>);
   begin
      At_Value := 0;
      Failed := False;

      Skip_Blanks (Text, Item);
      if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
         Failed := True;
         return;
      end if;
      Item.At_Char := Item.At_Char + 1;

      loop
         Skip_Blanks (Text, Item);
         exit when Item.At_Char > Text'Last;

         if Text (Item.At_Char) = '}' then
            return;
         end if;

         declare
            Key_First, Key_Last : Natural;
            Value_First, Value_Last : Natural;
         begin
            Read_String (Text, Item, Key_First, Key_Last);
            if Item.Failed then
               Failed := True;
               return;
            end if;

            Skip_Blanks (Text, Item);
            if Item.At_Char > Text'Last or else Text (Item.At_Char) /= ':' then
               Failed := True;
               return;
            end if;
            Item.At_Char := Item.At_Char + 1;

            Skip_Blanks (Text, Item);
            Value_First := Item.At_Char;

            Read_Value (Text, Item, Value_First, Value_Last);
            if Item.Failed then
               Failed := True;
               return;
            end if;

            if Text (Key_First .. Key_Last) = Name then
               At_Value := Value_First;
               return;
            end if;

            Skip_Blanks (Text, Item);
            if Item.At_Char <= Text'Last
              and then Text (Item.At_Char) = ','
            then
               Item.At_Char := Item.At_Char + 1;
            end if;
         end;
      end loop;

      Failed := True;
   end Find_Member;

   ------------------
   -- To_Grammar --
   ------------------

   --  Both public procedures come here: the JSON shape when In_Tags is
   --  false, and the parameters-in-tags shape when it is true, with the
   --  three spellings that make a tag.
   procedure Write
     (Text    : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out E.Error_Info;
      In_Tags  : Boolean;
      Before  : String;
      After   : String;
      Close   : String;
      In_Call : Boolean := False)
   is
      Used : Natural := 0;

      Overflowed : Boolean := False;

      procedure Put (Item : String) is
      begin
         if Used + Item'Length > Grammar'Length then
            Overflowed := True;
            return;
         end if;

         Grammar (Grammar'First + Used
                  .. Grammar'First + Used + Item'Length - 1) := Item;
         Used := Used + Item'Length;
      end Put;

      --  JSON text written into a grammar literal: its quotes and its own
      --  backslashes escaped, so the literal is that text exactly -- an
      --  enum "a\"b" closed the literal at its escaped quote, and "a\nb"
      --  asked for a real line break where JSON writes a backslash and n.
      procedure Put_Literal (Item : String) is
      begin
         for Char of Item loop
            case Char is
               when '"' => Put ("\""");
               when '\' => Put ("\\");
               when others => Put ([1 => Char]);
            end case;
         end loop;
      end Put_Literal;

      Refused : Boolean := False;
      Refused_By : String (1 .. 64) := [others => ' '];
      Refused_Up : Natural := 0;

      procedure Refuse (What : String) is
         Room : constant Natural :=
           Natural'Min (What'Length, Refused_By'Length);
      begin
         if not Refused then
            Refused := True;
            Refused_By (1 .. Room) :=
              What (What'First .. What'First + Room - 1);
            Refused_Up := Room;
         end if;
      end Refuse;

      Malformed : Boolean := False;

      --  Write the grammar for the schema whose object begins at From.
      procedure Shape (From : Natural; Depth : Natural);
      procedure Known_Keywords (From : Natural);

      function Has_Member (From : Natural; Name : String) return Boolean is
         At_Value : Natural;
         Failed   : Boolean;
      begin
         Find_Member (Text, From, Name, At_Value, Failed);
         return not Failed and then At_Value /= 0;
      end Has_Member;

      --  Resolve a document-local JSON pointer. Remote references are not
      --  allowed: grammar construction remains deterministic and offline.
      --  Escaped pointer components are refused rather than misresolved.
      function Resolve_Ref (From : Natural) return Natural is
         At_Ref : Natural;
         Failed : Boolean;
         Item   : Reader;
         First, Last_At : Natural;
      begin
         Find_Member (Text, From, "$ref", At_Ref, Failed);
         if Failed or else At_Ref = 0 then
            return 0;
         end if;

         Item := (At_Char => At_Ref, others => <>);
         Read_String (Text, Item, First, Last_At);
         if Item.Failed then
            Malformed := True;
            return 0;
         end if;

         if Text (First .. Last_At) = "#" then
            return Text'First;
         elsif Last_At < First + 2
           or else Text (First .. First + 1) /= "#/"
         then
            Refuse ("a non-local $ref");
            return 0;
         end if;

         declare
            Current : Natural := Text'First;
            Start   : Natural := First + 2;
            Stop    : Natural;
            At_Next : Natural;
            Bad     : Boolean;
         begin
            while Start <= Last_At loop
               Stop := Start;
               while Stop <= Last_At and then Text (Stop) /= '/' loop
                  Stop := Stop + 1;
               end loop;
               if Stop = Start then
                  Refuse ("an empty $ref component");
                  return 0;
               end if;
               declare
                  Raw : constant String := Text (Start .. Stop - 1);
                  Decoded : String (1 .. Raw'Length);
                  Used    : Natural := 0;
                  Index   : Natural := Raw'First;
               begin
                  while Index <= Raw'Last loop
                     Used := Used + 1;
                     if Raw (Index) = '~' and then Index < Raw'Last
                       and then Raw (Index + 1) in '0' | '1'
                     then
                        Decoded (Used) :=
                          (if Raw (Index + 1) = '0' then '~' else '/');
                        Index := Index + 2;
                     elsif Raw (Index) = '~' or else Raw (Index) = '\' then
                        Refuse ("an invalid $ref component escape");
                        return 0;
                     else
                        Decoded (Used) := Raw (Index);
                        Index := Index + 1;
                     end if;
                  end loop;
                  Find_Member
                    (Text, Current, Decoded (1 .. Used), At_Next, Bad);
               end;
               if Bad or else At_Next = 0 then
                  Refuse ("an unresolved $ref");
                  return 0;
               end if;
               Current := At_Next;
               Start := Stop + 1;
            end loop;
            return Current;
         end;
      end Resolve_Ref;

      --  The type keyword's value, as a bare word. Empty when absent.
      procedure Named_Type
        (From  : Natural;
         First : out Natural;
         Last  : out Natural)
      is
         At_Value : Natural;
         Failed   : Boolean;
         Item     : Reader;
      begin
         First := 1;
         Last := 0;

         Find_Member (Text, From, "type", At_Value, Failed);
         if Failed or else At_Value = 0 then
            return;
         end if;

         Item := (At_Char => At_Value, others => <>);
         Read_String (Text, Item, First, Last);
         if Item.Failed then
            First := 1;
            Last := 0;
         end if;
      end Named_Type;

      --  One of the plain types, as a grammar fragment.
      procedure Plain (Word : String) is
      begin
         if Word = "string" then
            Put ("str");
         elsif Word = "number" then
            Put ("num");
         elsif Word = "integer" then
            Put ("int");
         elsif Word = "boolean" then
            Put ("bool");
         elsif Word = "null" then
            Put ("""null""");
         else
            Refuse (Word);
         end if;
      end Plain;

      type Plain_Kind is
        (No_Plain, String_Plain, Number_Plain, Integer_Plain,
         Boolean_Plain, Null_Plain, Not_Plain);

      function Word_Of (Kind : Plain_Kind) return String is
        (case Kind is
            when String_Plain  => "string",
            when Number_Plain  => "number",
            when Integer_Plain => "integer",
            when Boolean_Plain => "boolean",
            when Null_Plain    => "null",
            when others        => "");

      function Intersect (Left, Right : Plain_Kind) return Plain_Kind is
        (if Left = No_Plain then Right
         elsif Right = No_Plain then Left
         elsif Left = Right then Left
         elsif (Left = Number_Plain and then Right = Integer_Plain)
           or else (Left = Integer_Plain and then Right = Number_Plain)
         then Integer_Plain
         else Not_Plain);

      --  Reduce a primitive type and any nested allOf list to their exact
      --  intersection. Object and array merging is deliberately not guessed:
      --  combining their properties needs the whole JSON Schema algebra.
      function Plain_Type (From : Natural; Depth : Natural) return Plain_Kind;

      function Plain_Type (From : Natural; Depth : Natural) return Plain_Kind
      is
         Type_First, Type_Last : Natural;
         At_All                : Natural;
         Failed                : Boolean;
         Result                : Plain_Kind := No_Plain;

         function Has (Name : String) return Boolean is
            At_Value : Natural;
            Bad      : Boolean;
         begin
            Find_Member (Text, From, Name, At_Value, Bad);
            return not Bad and then At_Value /= 0;
         end Has;
      begin
         if Depth > Max_Depth then
            Refuse ("nesting");
            return Not_Plain;
         end if;

         Known_Keywords (From);
         if Refused then
            return Not_Plain;
         end if;

         --  These constraints make the member more than a primitive type.
         --  They are supported by Shape on their own, but not silently
         --  weakened while intersecting allOf members.
         if Has ("properties") or else Has ("required") or else Has ("items")
           or else Has ("enum") or else Has ("const")
         then
            Refuse ("allOf with a non-plain schema");
            return Not_Plain;
         end if;

         Named_Type (From, Type_First, Type_Last);
         if Type_Last >= Type_First then
            declare
               Word : constant String := Text (Type_First .. Type_Last);
            begin
               if Word = "string" then
                  Result := String_Plain;
               elsif Word = "number" then
                  Result := Number_Plain;
               elsif Word = "integer" then
                  Result := Integer_Plain;
               elsif Word = "boolean" then
                  Result := Boolean_Plain;
               elsif Word = "null" then
                  Result := Null_Plain;
               else
                  Refuse ("allOf with a non-plain type");
                  return Not_Plain;
               end if;
            end;
         end if;

         Find_Member (Text, From, "allOf", At_All, Failed);
         if Failed or else At_All = 0 then
            return Result;
         end if;

         declare
            Item  : Reader := (At_Char => At_All, others => <>);
            Count : Natural := 0;
         begin
            Skip_Blanks (Text, Item);
            if Item.At_Char > Text'Last
              or else Text (Item.At_Char) /= '['
            then
               Malformed := True;
               return Not_Plain;
            end if;
            Item.At_Char := Item.At_Char + 1;

            loop
               Skip_Blanks (Text, Item);
               exit when Item.At_Char > Text'Last;
               exit when Text (Item.At_Char) = ']';

               declare
                  Value_First, Value_Last : Natural;
                  Part : Plain_Kind;
               begin
                  Read_Value (Text, Item, Value_First, Value_Last);
                  if Item.Failed
                    or else Text (Value_First) /= '{'
                  then
                     Malformed := True;
                     return Not_Plain;
                  end if;

                  Count := Count + 1;
                  Part := Plain_Type (Value_First, Depth + 1);
                  Result := Intersect (Result, Part);
                  if Result = Not_Plain then
                     if not Refused then
                        Refuse ("allOf with incompatible types");
                     end if;
                     return Not_Plain;
                  end if;

                  Skip_Blanks (Text, Item);
                  if Item.At_Char <= Text'Last
                    and then Text (Item.At_Char) = ','
                  then
                     Item.At_Char := Item.At_Char + 1;
                  end if;
               end;
            end loop;

            if Count = 0 or else Result = No_Plain then
               Refuse ("an empty allOf");
               return Not_Plain;
            end if;
         end;

         return Result;
      end Plain_Type;

      --  Whether a name appears in the object's required list. A schema
      --  with no required list requires everything it names, which is not
      --  what JSON Schema says -- there, absent means optional -- but is
      --  the safe direction and is stated in the specification.
      function Is_Required (From : Natural; Name : String) return Boolean is
         At_List : Natural;
         Failed  : Boolean;
         Item    : Reader;
      begin
         Find_Member (Text, From, "required", At_List, Failed);
         if Failed or else At_List = 0 then
            return True;
         end if;

         Item := (At_Char => At_List, others => <>);
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '[' then
            return True;
         end if;
         Item.At_Char := Item.At_Char + 1;

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = ']';

            declare
               First, Last_At : Natural;
            begin
               Read_String (Text, Item, First, Last_At);
               exit when Item.Failed;

               if Text (First .. Last_At) = Name then
                  return True;
               end if;

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         return False;
      end Is_Required;

      --  An object: exactly the properties named, in the order named. A
      --  property the schema does not require may be absent, with the
      --  comma that would precede it.
      procedure Object_Shape (From : Natural; Depth : Natural) is
         At_Props : Natural;
         Failed   : Boolean;
         Item     : Reader;
         Count    : Natural := 0;
      begin
         Find_Member (Text, From, "properties", At_Props, Failed);
         if Failed or else At_Props = 0 then
            --  An object with no properties named is any object, which this
            --  cannot write without allowing everything.
            Refuse ("object without properties");
            return;
         end if;

         Put ("""{"" ws ");

         Item := (At_Char => At_Props, others => <>);
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = '}';

            declare
               Key_First, Key_Last     : Natural;
               Value_First, Value_Last : Natural;
            begin
               Read_String (Text, Item, Key_First, Key_Last);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               Skip_Blanks (Text, Item);
               if Item.At_Char > Text'Last
                 or else Text (Item.At_Char) /= ':'
               then
                  Malformed := True;
                  return;
               end if;
               Item.At_Char := Item.At_Char + 1;

               Skip_Blanks (Text, Item);
               Value_First := Item.At_Char;
               Read_Value (Text, Item, Value_First, Value_Last);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               declare
                  Wanted : constant Boolean :=
                    Is_Required (From, Text (Key_First .. Key_Last));
               begin
                  --  The first property carries no comma, and one that
                  --  may be absent would make the comma before the
                  --  second conditional on it -- which needs an
                  --  alternative for every place the object might
                  --  start. Refused rather than approximated.
                  if Count = 0 and then not Wanted then
                     Refuse ("an optional first property");
                     return;
                  end if;

                  if Count > 0 then
                     Put (" ("","" ws ");
                  end if;
                  Count := Count + 1;

                  Put ("""\""");
                  Put_Literal (Text (Key_First .. Key_Last));
                  Put ("\"":"" ws ");
                  Shape (Value_First, Depth + 1);

                  if Count > 1 then
                     Put ((if Wanted then ")" else ")?"));
                  end if;
               end;

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         Put (" ws ""}""");

         --  Every name the schema requires has to be one it describes. A
         --  required name that no property matches is a demand the grammar
         --  cannot carry -- there is nothing to make mandatory -- and
         --  ignoring it produces a grammar that quietly does not require
         --  what the schema says it does.
         declare
            At_List     : Natural;
            Failed_Here : Boolean;
            Walk        : Reader;
         begin
            Find_Member (Text, From, "required", At_List, Failed_Here);
            if not Failed_Here and then At_List /= 0 then
               Walk := (At_Char => At_List, others => <>);
               Skip_Blanks (Text, Walk);
               if Walk.At_Char <= Text'Last
                 and then Text (Walk.At_Char) = '['
               then
                  Walk.At_Char := Walk.At_Char + 1;

                  loop
                     Skip_Blanks (Text, Walk);
                     exit when Walk.At_Char > Text'Last;
                     exit when Text (Walk.At_Char) = ']';

                     declare
                        First, Last_At : Natural;
                        At_Property    : Natural;
                        Missing        : Boolean;
                     begin
                        Read_String (Text, Walk, First, Last_At);
                        exit when Walk.Failed;

                        Find_Member
                          (Text, At_Props, Text (First .. Last_At),
                           At_Property, Missing);

                        if Missing or else At_Property = 0 then
                           Refuse
                             ("a required property that is not described");
                           return;
                        end if;

                        Skip_Blanks (Text, Walk);
                        if Walk.At_Char <= Text'Last
                          and then Text (Walk.At_Char) = ','
                        then
                           Walk.At_Char := Walk.At_Char + 1;
                        end if;
                     end;
                  end loop;
               end if;
            end if;
         end;
      end Object_Shape;

      --  Merge the closed object shape represented by an allOf tree. Each
      --  property appears once and required names are the union of member
      --  requirements. A duplicate property must carry the same schema;
      --  unlike primitive types, two arbitrary property schemas cannot be
      --  intersected by a context-free grammar without another full schema
      --  algebra, so a conflict is refused rather than weakened.
      procedure Object_AllOf_Shape (From : Natural; Depth : Natural) is
         Max_Properties : constant := 256;
         type Positions is array (1 .. Max_Properties) of Natural;
         type Flags is array (1 .. Max_Properties) of Boolean;
         Key_First, Key_Last, Value_First, Value_Last : Positions :=
           [others => 0];
         Required : Flags := [others => False];
         Count    : Natural := 0;

         procedure Add_Properties (Source : Natural; Level : Natural);

         procedure Add_Properties (Source : Natural; Level : Natural) is
            Type_First, Type_Last : Natural;
            At_Props, At_All      : Natural;
            Failed                : Boolean;
         begin
            if Level > Max_Depth then
               Refuse ("nesting");
               return;
            end if;
            Known_Keywords (Source);
            if Refused then
               return;
            end if;
            if Has_Member (Source, "additionalProperties") then
               --  Merging closed allOf members would admit keys each separate member forbids.
               Refuse ("allOf with closed object members");
               return;
            end if;

            Named_Type (Source, Type_First, Type_Last);
            if Type_Last >= Type_First
              and then Text (Type_First .. Type_Last) /= "object"
            then
               Refuse ("allOf with incompatible types");
               return;
            end if;

            Find_Member (Text, Source, "properties", At_Props, Failed);
            if not Failed and then At_Props /= 0 then
               declare
                  Walk : Reader := (At_Char => At_Props, others => <>);
               begin
                  Skip_Blanks (Text, Walk);
                  if Walk.At_Char > Text'Last
                    or else Text (Walk.At_Char) /= '{'
                  then
                     Malformed := True;
                     return;
                  end if;
                  Walk.At_Char := Walk.At_Char + 1;

                  loop
                     Skip_Blanks (Text, Walk);
                     exit when Walk.At_Char > Text'Last
                       or else Text (Walk.At_Char) = '}';
                     declare
                        KF, KL, VF, VL : Natural;
                        Existing       : Natural := 0;
                     begin
                        Read_String (Text, Walk, KF, KL);
                        Skip_Blanks (Text, Walk);
                        if Walk.Failed or else Walk.At_Char > Text'Last
                          or else Text (Walk.At_Char) /= ':'
                        then
                           Malformed := True;
                           return;
                        end if;
                        Walk.At_Char := Walk.At_Char + 1;
                        Read_Value (Text, Walk, VF, VL);
                        if Walk.Failed then
                           Malformed := True;
                           return;
                        end if;

                        for Index in 1 .. Count loop
                           if Text (Key_First (Index) .. Key_Last (Index)) =
                                Text (KF .. KL)
                           then
                              Existing := Index;
                              exit;
                           end if;
                        end loop;

                        if Existing = 0 then
                           if Count = Max_Properties then
                              Refuse ("too many allOf properties");
                              return;
                           end if;
                           Count := Count + 1;
                           Key_First (Count) := KF;
                           Key_Last (Count) := KL;
                           Value_First (Count) := VF;
                           Value_Last (Count) := VL;
                           Required (Count) :=
                             Is_Required (Source, Text (KF .. KL));
                        elsif Text
                                (Value_First (Existing) .. Value_Last (Existing))
                              /= Text (VF .. VL)
                        then
                           Refuse ("allOf with conflicting properties");
                           return;
                        else
                           Required (Existing) := Required (Existing)
                             or else Is_Required (Source, Text (KF .. KL));
                        end if;

                        Skip_Blanks (Text, Walk);
                        if Walk.At_Char <= Text'Last
                          and then Text (Walk.At_Char) = ','
                        then
                           Walk.At_Char := Walk.At_Char + 1;
                        end if;
                     end;
                  end loop;
               end;
            end if;

            Find_Member (Text, Source, "allOf", At_All, Failed);
            if not Failed and then At_All /= 0 then
               declare
                  Walk    : Reader := (At_Char => At_All, others => <>);
                  Members : Natural := 0;
               begin
                  Skip_Blanks (Text, Walk);
                  if Walk.At_Char > Text'Last
                    or else Text (Walk.At_Char) /= '['
                  then
                     Malformed := True;
                     return;
                  end if;
                  Walk.At_Char := Walk.At_Char + 1;
                  loop
                     Skip_Blanks (Text, Walk);
                     exit when Walk.At_Char > Text'Last
                       or else Text (Walk.At_Char) = ']';
                     declare
                        VF, VL : Natural;
                     begin
                        Read_Value (Text, Walk, VF, VL);
                        if Walk.Failed or else Text (VF) /= '{' then
                           Malformed := True;
                           return;
                        end if;
                        Members := Members + 1;
                        Add_Properties (VF, Level + 1);
                        exit when Refused or else Malformed;
                        Skip_Blanks (Text, Walk);
                        if Walk.At_Char <= Text'Last
                          and then Text (Walk.At_Char) = ','
                        then
                           Walk.At_Char := Walk.At_Char + 1;
                        end if;
                     end;
                  end loop;
                  if Members = 0 then
                     Refuse ("an empty allOf");
                  end if;
               end;
            end if;
         end Add_Properties;

         Emitted : Natural := 0;

         procedure Emit (Index : Positive) is
         begin
            if Emitted > 0 then
               Put (" ("","" ws ");
            end if;
            Emitted := Emitted + 1;
            Put ("""\""");
            Put_Literal (Text (Key_First (Index) .. Key_Last (Index)));
            Put ("\"":"" ws ");
            Shape (Value_First (Index), Depth + 1);
            if Emitted > 1 then
               Put ((if Required (Index) then ")" else ")?"));
            end if;
         end Emit;
      begin
         Add_Properties (From, Depth);
         if Refused or else Malformed then
            return;
         elsif Count = 0 then
            Refuse ("object without properties");
            return;
         end if;

         Put ("""{"" ws ");
         for Index in 1 .. Count loop
            if Required (Index) then
               Emit (Index);
            end if;
         end loop;
         if Emitted = 0 then
            Refuse ("an allOf object with only optional properties");
            return;
         end if;
         for Index in 1 .. Count loop
            if not Required (Index) then
               Emit (Index);
            end if;
         end loop;
         Put (" ws ""}""");
      end Object_AllOf_Shape;

      procedure Alternatives
        (At_Value : Natural; Depth : Natural; Exclusive : Boolean)
      is
         Item  : Reader := (At_Char => At_Value, others => <>);
         Count : Natural := 0;
         Kinds : array (1 .. 64) of Plain_Kind := [others => No_Plain];
         Starts : array (1 .. 64) of Natural := [others => 0];

         function Provably_Disjoint (Left, Right : Positive) return Boolean is
            procedure Const_At
              (Schema : Natural; First, Last_At : out Natural)
            is
               At_Const : Natural;
               Failed   : Boolean;
               Walk     : Reader;
            begin
               First := 1;
               Last_At := 0;
               Find_Member (Text, Schema, "const", At_Const, Failed);
               if Failed or else At_Const = 0 then
                  return;
               end if;
               Walk := (At_Char => At_Const, others => <>);
               Read_Value (Text, Walk, First, Last_At);
               if Walk.Failed then
                  First := 1;
                  Last_At := 0;
               end if;
            end Const_At;

            LF, LL, RF, RL : Natural;
            Left_Props, Right_Props : Natural;
            Failed : Boolean;
         begin
            if Kinds (Left) not in No_Plain | Not_Plain
              and then Kinds (Right) not in No_Plain | Not_Plain
            then
               return Intersect (Kinds (Left), Kinds (Right)) = Not_Plain;
            end if;

            --  Distinct const schemas cannot both accept one value.
            Const_At (Starts (Left), LF, LL);
            Const_At (Starts (Right), RF, RL);
            if LL >= LF and then RL >= RF then
               return Text (LF .. LL) /= Text (RF .. RL);
            end if;

            --  The common object-oneOf idiom uses a required discriminator
            --  property whose const differs in each branch. Because object
            --  shapes here require every named property unless told
            --  otherwise, distinct discriminator constants prove the two
            --  alternatives exclusive.
            Find_Member
              (Text, Starts (Left), "properties", Left_Props, Failed);
            if Failed or else Left_Props = 0 then
               return False;
            end if;
            Find_Member
              (Text, Starts (Right), "properties", Right_Props, Failed);
            if Failed or else Right_Props = 0 then
               return False;
            end if;

            declare
               Walk : Reader := (At_Char => Left_Props, others => <>);
            begin
               Skip_Blanks (Text, Walk);
               if Walk.At_Char > Text'Last or else Text (Walk.At_Char) /= '{'
               then
                  return False;
               end if;
               Walk.At_Char := Walk.At_Char + 1;
               loop
                  Skip_Blanks (Text, Walk);
                  exit when Walk.At_Char > Text'Last
                    or else Text (Walk.At_Char) = '}';
                  declare
                     KF, KL, VF, VL, Other : Natural;
                     Bad : Boolean;
                  begin
                     Read_String (Text, Walk, KF, KL);
                     Skip_Blanks (Text, Walk);
                     if Walk.Failed or else Walk.At_Char > Text'Last
                       or else Text (Walk.At_Char) /= ':'
                     then
                        return False;
                     end if;
                     Walk.At_Char := Walk.At_Char + 1;
                     Read_Value (Text, Walk, VF, VL);
                     if Walk.Failed then
                        return False;
                     end if;
                     Const_At (VF, LF, LL);
                     if LL >= LF then
                        Find_Member
                          (Text, Right_Props, Text (KF .. KL), Other, Bad);
                        if not Bad and then Other /= 0 then
                           Const_At (Other, RF, RL);
                           if RL >= RF
                             and then Text (LF .. LL) /= Text (RF .. RL)
                           then
                              return True;
                           end if;
                        end if;
                     end if;
                     Skip_Blanks (Text, Walk);
                     if Walk.At_Char <= Text'Last
                       and then Text (Walk.At_Char) = ','
                     then
                        Walk.At_Char := Walk.At_Char + 1;
                     end if;
                  end;
               end loop;
            end;
            return False;
         end Provably_Disjoint;
      begin
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '[' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;
         Put ("(");
         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last or else Text (Item.At_Char) = ']';
            declare
               VF, VL : Natural;
               TF, TL : Natural;
            begin
               Read_Value (Text, Item, VF, VL);
               if Item.Failed or else Text (VF) /= '{' then
                  Malformed := True;
                  return;
               end if;
               Count := Count + 1;
               if Count > Kinds'Last then
                  Refuse ("too many schema alternatives");
                  return;
               end if;
               Starts (Count) := VF;
               if Count > 1 then
                  Put (" | ");
               end if;
               Shape (VF, Depth + 1);
               Named_Type (VF, TF, TL);
               if TL >= TF then
                  declare
                     Word : constant String := Text (TF .. TL);
                  begin
                     Kinds (Count) :=
                       (if Word = "string" then String_Plain
                        elsif Word = "number" then Number_Plain
                        elsif Word = "integer" then Integer_Plain
                        elsif Word = "boolean" then Boolean_Plain
                        elsif Word = "null" then Null_Plain
                        else Not_Plain);
                  end;
               else
                  Kinds (Count) := Not_Plain;
               end if;
               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last and then Text (Item.At_Char) = ',' then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;
         Put (")");
         if Count = 0 then
            Malformed := True;
            return;
         end if;

         if Exclusive then
            for Left in 1 .. Count loop
               for Right in Left + 1 .. Count loop
                  if not Provably_Disjoint (Left, Right) then
                     Refuse ("oneOf alternatives that may overlap");
                     return;
                  end if;
               end loop;
            end loop;
         end if;
      end Alternatives;

      procedure Array_Shape (From : Natural; Depth : Natural) is
         At_Items : Natural;
         Failed   : Boolean;
      begin
         Find_Member (Text, From, "items", At_Items, Failed);
         if Failed or else At_Items = 0 then
            Refuse ("array without items");
            return;
         end if;

         --  Empty, one, or several separated by commas.
         Put ("""["" ws (");
         Shape (At_Items, Depth + 1);
         Put (" ("","" ws ");
         Shape (At_Items, Depth + 1);
         Put (")*)? ws ""]""");
      end Array_Shape;

      --  A list of literal values, as alternatives written exactly as the
      --  schema wrote them.
      procedure Choice (At_Value : Natural) is
         Item  : Reader := (At_Char => At_Value, others => <>);
         Count : Natural := 0;
      begin
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '[' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         Put ("(");

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = ']';

            declare
               First, Last_At : Natural;
            begin
               Read_Value (Text, Item, First, Last_At);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               if Count > 0 then
                  Put (" | ");
               end if;
               Count := Count + 1;

               --  Written as a literal, with the quotes a JSON string
               --  carries escaped so the grammar reads them as text.
               Put ("""");
               Put_Literal (Text (First .. Last_At));
               Put ("""");

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         Put (")");

         if Count = 0 then
            Malformed := True;
         end if;
      end Choice;

      --  A value standing in a tag rather than in JSON: text where JSON
      --  would have a quoted string, and the same rule as JSON otherwise.
      procedure Raw_Plain (Word : String) is
      begin
         if In_Call and then Word = "string" then
            Put ("pystr");
         elsif In_Call and then Word = "boolean" then
            Put ("pybool");
         elsif Word = "string" then
            Put ("text");
         else
            Plain (Word);
         end if;
      end Raw_Plain;

      --  An enum's choices as the words themselves: a string's quotes are
      --  JSON's and a tag carries none, so a choice is written bare.
      procedure Raw_Choice (At_Value : Natural) is
         Item  : Reader := (At_Char => At_Value, others => <>);
         Count : Natural := 0;
      begin
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '[' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         Put ("(");

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = ']';

            declare
               First, Last_At : Natural;
            begin
               Read_Value (Text, Item, First, Last_At);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               if Count > 0 then
                  Put (" | ");
               end if;
               Count := Count + 1;

               Put ("""");
               for Index in First .. Last_At loop
                  if Text (Index) = '"' then
                     --  A JSON string's own quotes, left out: the word
                     --  stands bare in a tag. A quote inside one is kept,
                     --  escaped for the grammar.
                     if Index = First or else Index = Last_At then
                        null;
                     else
                        Put ("\""");
                     end if;
                  elsif Text (Index) = '\' then
                     Put ("\\");
                  else
                     Put (Text (Index .. Index));
                  end if;
               end loop;
               Put ("""");

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         Put (")");

         if Count = 0 then
            Malformed := True;
         end if;
      end Raw_Choice;

      --  One property's value as it stands in a tag: a choice bare, a
      --  string as text, a number or boolean as itself, and an object or
      --  an array as the JSON those families write for one.
      procedure Tag_Value (From : Natural) is
         At_Enum, At_Const, At_All : Natural;
         Failed                  : Boolean;
         Type_First, Type_Last   : Natural;
      begin
         Known_Keywords (From);
         if Refused or else Malformed then
            return;
         end if;

         Find_Member (Text, From, "const", At_Const, Failed);
         if not Failed and then At_Const /= 0 then
            if In_Call then
               --  A literal in a call is written as JSON writes it, which
               --  for a string or a number is Python too.
               Shape (From, 1);
            else
               Refuse ("a const in a tag");
            end if;
            return;
         end if;

         Find_Member (Text, From, "enum", At_Enum, Failed);
         if not Failed and then At_Enum /= 0 then
            if In_Call then
               Choice (At_Enum);
            else
               Raw_Choice (At_Enum);
            end if;
            return;
         end if;

         Find_Member (Text, From, "allOf", At_All, Failed);
         if not Failed and then At_All /= 0 then
            declare
               Kind : constant Plain_Kind := Plain_Type (From, 1);
            begin
               if Kind not in No_Plain | Not_Plain then
                  Raw_Plain (Word_Of (Kind));
               end if;
            end;
            return;
         end if;

         Named_Type (From, Type_First, Type_Last);
         if Type_Last < Type_First then
            Refuse ("a schema with no type or enum");
            return;
         end if;

         declare
            Word : constant String := Text (Type_First .. Type_Last);
         begin
            if Word = "object" or else Word = "array" then
               Shape (From, 1);
            else
               Raw_Plain (Word);
            end if;
         end;
      end Tag_Value;

      --  The properties of the top-level object, each in its tag, in the
      --  order the schema names them. Unlike the JSON shape no comma
      --  stands between them, so a property that may be absent may be
      --  absent wherever it stands, the first included.
      procedure Tag_Object_Shape (From : Natural; Depth : Natural := 0) is
         At_Props, At_Any : Natural;
         Failed   : Boolean;
         Item     : Reader;
         Count    : Natural := 0;
         Type_First, Type_Last : Natural;
      begin
         Known_Keywords (From);
         if Refused or else Malformed then
            return;
         end if;
         if Depth > Max_Depth then
            Refuse ("nesting");
            return;
         end if;
         Find_Member (Text, From, "anyOf", At_Any, Failed);
         if not Failed and then At_Any /= 0 then
            if Has_Member (From, "type") or else Has_Member (From, "properties")
              or else Has_Member (From, "required") or else Has_Member (From, "const")
              or else Has_Member (From, "enum") or else Has_Member (From, "$ref")
              or else Has_Member (From, "allOf") or else Has_Member (From, "oneOf")
            then
               Refuse ("tag anyOf with schema siblings");
               return;
            end if;
            Item := (At_Char => At_Any, others => <>);
            Skip_Blanks (Text, Item);
            if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '[' then
               Malformed := True;
               return;
            end if;
            Item.At_Char := Item.At_Char + 1;
            Put ("(");
            loop
               Skip_Blanks (Text, Item);
               exit when Item.At_Char > Text'Last or else Text (Item.At_Char) = ']';
               declare
                  First, Last_At : Natural;
               begin
                  Read_Value (Text, Item, First, Last_At);
                  if Item.Failed or else Text (First) /= '{' then
                     Malformed := True;
                     return;
                  end if;
                  Count := Count + 1;
                  if Count > 64 then
                     Refuse ("too many schema alternatives");
                     return;
                  end if;
                  if Count > 1 then
                     Put (" | ");
                  end if;
                  Tag_Object_Shape (First, Depth + 1);
                  exit when Refused or else Malformed;
                  Skip_Blanks (Text, Item);
                  if Item.At_Char <= Text'Last and then Text (Item.At_Char) = ',' then
                     Item.At_Char := Item.At_Char + 1;
                  end if;
               end;
            end loop;
            Put (")");
            if Count = 0 then
               Malformed := True;
            end if;
            return;
         end if;

         Named_Type (From, Type_First, Type_Last);
         if Type_Last < Type_First
           or else Text (Type_First .. Type_Last) /= "object"
         then
            Refuse ("parameters that are not an object");
            return;
         end if;

         Find_Member (Text, From, "properties", At_Props, Failed);
         if Failed or else At_Props = 0 then
            Refuse ("object without properties");
            return;
         end if;

         Item := (At_Char => At_Props, others => <>);
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = '}';

            declare
               Key_First, Key_Last     : Natural;
               Value_First, Value_Last : Natural;
            begin
               Read_String (Text, Item, Key_First, Key_Last);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               Skip_Blanks (Text, Item);
               if Item.At_Char > Text'Last
                 or else Text (Item.At_Char) /= ':'
               then
                  Malformed := True;
                  return;
               end if;
               Item.At_Char := Item.At_Char + 1;

               Skip_Blanks (Text, Item);
               Value_First := Item.At_Char;
               Read_Value (Text, Item, Value_First, Value_Last);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               declare
                  Wanted : constant Boolean :=
                    Is_Required (From, Text (Key_First .. Key_Last));
               begin
                  if Count > 0 then
                     Put (" ");
                  end if;
                  Count := Count + 1;

                  --  In a call: name=value, the comma after it optional,
                  --  so the last one closes the call without one and a
                  --  trailing one is the Python it is.
                  Put ("(""");
                  Put (Before);
                  Put (Text (Key_First .. Key_Last));
                  Put (After);
                  Put (""" ws ");
                  Tag_Value (Value_First);
                  if In_Call then
                     Put (" ws "",""? ws)");
                  else
                     Put (" ws """);
                     Put (Close);
                     Put (""" ws)");
                  end if;
                  if not Wanted then
                     Put ("?");
                  end if;
               end;

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         if Count = 0 then
            --  A tool with no parameters calls with nothing between its
            --  tags but the whitespace the envelope allows.
            Put ("ws");
         end if;
      end Tag_Object_Shape;

      --  Every member of a schema object, checked against what this reads.
      --  A keyword it does not read is refused rather than ignored: ignoring
      --  one produces a grammar that allows more than the schema does, which
      --  is a constraint that quietly is not one.
      procedure Known_Keywords (From : Natural) is
         Item : Reader := (At_Char => From, others => <>);
      begin
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = '}';

            declare
               Key_First, Key_Last : Natural;
               Value_First, Value_Last : Natural;
            begin
               Read_String (Text, Item, Key_First, Key_Last);
               exit when Item.Failed;

               Skip_Blanks (Text, Item);
               exit when Item.At_Char > Text'Last
                 or else Text (Item.At_Char) /= ':';
               Item.At_Char := Item.At_Char + 1;

               Read_Value (Text, Item, Value_First, Value_Last);
               exit when Item.Failed;

               declare
                  Word : constant String := Text (Key_First .. Key_Last);
                  Type_First, Type_Last : Natural;
               begin
                  if Word = "additionalProperties" then
                     Named_Type (From, Type_First, Type_Last);
                     if Text (Value_First .. Value_Last) /= "false"
                       or else Type_Last < Type_First or else Text (Type_First .. Type_Last) /= "object"
                       or else not Has_Member (From, "properties")
                       or else Has_Member (From, "$ref") or else Has_Member (From, "const")
                       or else Has_Member (From, "enum") or else Has_Member (From, "allOf")
                       or else Has_Member (From, "anyOf") or else Has_Member (From, "oneOf")
                     then
                        Refuse ("additionalProperties outside a plain closed object");
                        return;
                     end if;
                  elsif Word /= "type" and then Word /= "properties"
                    and then Word /= "required" and then Word /= "items"
                    and then Word /= "enum" and then Word /= "const"
                    and then Word /= "allOf"
                    and then Word /= "anyOf" and then Word /= "oneOf"
                    and then Word /= "$ref" and then Word /= "$defs"
                    and then Word /= "definitions"
                    --  Documentary keywords say nothing about the shape.
                    and then Word /= "description" and then Word /= "title"
                    and then Word /= "$schema" and then Word /= "$id"
                  then
                     Refuse (Word);
                     return;
                  end if;
               end;

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;
      end Known_Keywords;

      procedure Shape (From : Natural; Depth : Natural) is
         At_Enum, At_Const, At_All, At_Any, At_One : Natural;
         Failed : Boolean;

         Type_First, Type_Last : Natural;
      begin
         Known_Keywords (From);
         if Refused then
            return;
         end if;

         if Depth > Max_Depth then
            Refuse ("nesting");
            return;
         end if;

         if Has_Member (From, "$ref") then
            declare
               Target : constant Natural := Resolve_Ref (From);
            begin
               if Target /= 0 then
                  --  Shape-bearing siblings are an intersection with the
                  --  reference. Do not silently discard them.
                  if Has_Member (From, "type")
                    or else Has_Member (From, "properties")
                    or else Has_Member (From, "required")
                    or else Has_Member (From, "items")
                    or else Has_Member (From, "enum")
                    or else Has_Member (From, "const")
                    or else Has_Member (From, "allOf")
                    or else Has_Member (From, "anyOf")
                    or else Has_Member (From, "oneOf")
                  then
                     Refuse ("$ref with schema siblings");
                  else
                     Shape (Target, Depth + 1);
                  end if;
               end if;
               return;
            end;
         end if;

         --  A fixed value, or a choice between fixed values, says everything
         --  and nothing else needs reading.
         Find_Member (Text, From, "const", At_Const, Failed);
         if not Failed and then At_Const /= 0 then
            declare
               Item : Reader := (At_Char => At_Const, others => <>);
               First, Last_At : Natural;
            begin
               Read_Value (Text, Item, First, Last_At);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               Put ("""");
               Put_Literal (Text (First .. Last_At));
               Put ("""");
            end;
            return;
         end if;

         Find_Member (Text, From, "enum", At_Enum, Failed);
         if not Failed and then At_Enum /= 0 then
            Choice (At_Enum);
            return;
         end if;

         Find_Member (Text, From, "allOf", At_All, Failed);
         if not Failed and then At_All /= 0 then
            if Has_Member (From, "properties") then
               Object_AllOf_Shape (From, Depth);
            else
               declare
                  Item : Reader := (At_Char => At_All, others => <>);
                  VF, VL, TF, TL : Natural;
                  Looks_Object : Boolean := False;
               begin
                  Skip_Blanks (Text, Item);
                  if Item.At_Char <= Text'Last
                    and then Text (Item.At_Char) = '['
                  then
                     Item.At_Char := Item.At_Char + 1;
                     Skip_Blanks (Text, Item);
                     if Item.At_Char <= Text'Last
                       and then Text (Item.At_Char) /= ']'
                     then
                        Read_Value (Text, Item, VF, VL);
                        if not Item.Failed and then Text (VF) = '{' then
                           Named_Type (VF, TF, TL);
                           Looks_Object := Has_Member (VF, "properties")
                             or else (TL >= TF
                                      and then Text (TF .. TL) = "object");
                        end if;
                     end if;
                  end if;
                  if Looks_Object then
                     Object_AllOf_Shape (From, Depth);
                  else
                     declare
                        Kind : constant Plain_Kind := Plain_Type (From, Depth);
                     begin
                        if Kind not in No_Plain | Not_Plain then
                           Plain (Word_Of (Kind));
                        end if;
                     end;
                  end if;
               end;
            end if;
            return;
         end if;

         Find_Member (Text, From, "anyOf", At_Any, Failed);
         if not Failed and then At_Any /= 0 then
            Alternatives (At_Any, Depth, Exclusive => False);
            return;
         end if;

         Find_Member (Text, From, "oneOf", At_One, Failed);
         if not Failed and then At_One /= 0 then
            Alternatives (At_One, Depth, Exclusive => True);
            return;
         end if;

         Named_Type (From, Type_First, Type_Last);
         if Type_Last < Type_First then
            Refuse ("a schema with no type, const or enum");
            return;
         end if;

         declare
            Word : constant String := Text (Type_First .. Type_Last);
         begin
            if Word = "object" then
               Object_Shape (From, Depth);
            elsif Word = "array" then
               Array_Shape (From, Depth);
            else
               Plain (Word);
            end if;
         end;
      end Shape;
   begin
      Grammar := [others => ' '];
      Last := 0;
      Status := E.Success;

      if Text'Length = 0 or else Text'Length > Max_Schema_Bytes then
         Status := E.Make (E.Grammar_Syntax_Error);
         E.Add_Text (Status, "construct", "the schema", E.Param_Identifier);
         return;
      end if;

      Put ("root ::= ");
      if In_Tags then
         Tag_Object_Shape (Text'First);
      else
         Shape (Text'First, 0);
      end if;
      Put (Character'Val (10) & "");

      --  The pieces every schema leans on, written once. A grammar that
      --  names a rule it does not define is refused by the compiler, so
      --  these are always here even when nothing used them.
      Put ("str ::= ""\"""" (safe | esc)* ""\"""""
           & Character'Val (10));
      --  Everything but a quote, a backslash and the control characters,
      --  which JSON says a string may not carry raw. Without that range a
      --  model can put a newline inside a string and the grammar allows it,
      --  which is a constraint that produces text no JSON reader accepts.
      Put ("safe ::= [^\""\\\x00-\x1f]" & Character'Val (10));
      Put ("esc ::= ""\\"" ([\""\\/bfnrt] | ""u"" hex hex hex hex)"
           & Character'Val (10));
      Put ("hex ::= [0-9a-fA-F]" & Character'Val (10));
      --  Numbers as JSON writes them, and as llama.cpp's converter bounds
      --  them: no leading zero -- 007 is no JSON number -- and an integral
      --  part of at most sixteen digits, a fraction of at most sixteen.
      Put ("int ::= ""-""? integral" & Character'Val (10));
      Put ("integral ::= ""0"" | [1-9] [0-9]{0,15}" & Character'Val (10));
      Put ("num ::= ""-""? integral (""."" [0-9]{1,16})? "
           & "([eE] [-+]? integral)?" & Character'Val (10));
      Put ("bool ::= ""true"" | ""false""" & Character'Val (10));
      --  Whitespace between JSON tokens, so a model constrained by this
      --  grammar may write {"a": 1, "b": 2} with the spacing it was trained
      --  to produce and is not forced into compact {"a":1,"b":2}. It is
      --  optional everywhere, so compact JSON is still accepted.
      --  Bounded as llama.cpp's converter bounds it -- a space, or a line
      --  break or two and an indent of at most twenty -- so a model cannot
      --  write whitespace to the token limit and call it an object.
      Put ("ws ::= ( "" "" | [\x0A]{1,2} [ \x09]{0,20} )?" & Character'Val (10));
      --  What a string is in a tag: anything up to the tag's own close.
      --  The reader takes the one line break off either end of it.
      --  Text with a '<' in it where no tag follows: code compares with
      --  one, and a value that stopped at it cut an edit short mid-line;
      --  and held from every "</", a value could close no tag it held --
      --  an edit of HTML could write no </div>.
      if Close /= "" then
         Put (Model_Runner.Grammar.Excluding ("text", Close));
      else
         Put ("text ::= ( [^<] | ""<"" [^/] )*" & Character'Val (10));
      end if;
      --  A string in a Python call: JSON's, or single-quoted, or between
      --  three quotes and across lines, as a call's longer text is
      --  written; the escapes inside are read back by the call reader.
      Put ("pystr ::= str | sqstr | tqstr" & Character'Val (10));
      Put ("sqstr ::= ""'"" ( [^'\\\x0A] | ""\\"" [^\x0A] )* ""'"""
           & Character'Val (10));
      Put ("tqstr ::= ""\""\""\"""" ( [^\""\\] | ""\\"" [^\x00] "
           & "| ""\"""" [^\""] | ""\""\"""" [^\""] )* ""\""\""\"""""
           & Character'Val (10));
      Put ("pybool ::= ""True"" | ""False""" & Character'Val (10));

      if Malformed then
         Status := E.Make (E.Grammar_Syntax_Error);
         E.Add_Text (Status, "construct", "the schema", E.Param_Identifier);
         return;
      end if;

      if Refused then
         Status := E.Make (E.Grammar_Schema_Unsupported);
         E.Add_Text
           (Status, "construct", Refused_By (1 .. Refused_Up),
            E.Param_Identifier);
         return;
      end if;

      if Overflowed then
         Status := E.Make (E.Grammar_Too_Large);
         return;
      end if;

      Last := Used;
   end Write;

   ----------------
   -- To_Grammar --
   ----------------

   procedure To_Grammar
     (Text    : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out E.Error_Info) is
   begin
      Write (Text, Grammar, Last, Status, In_Tags => False,
             Before => "", After => "", Close => "");
   end To_Grammar;

   --------------------
   -- To_Tag_Grammar --
   --------------------

   procedure To_Tag_Grammar
     (Text    : String;
      Before  : String;
      After   : String;
      Close   : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out E.Error_Info) is
   begin
      Write (Text, Grammar, Last, Status, In_Tags => True,
             Before => Before, After => After, Close => Close);
   end To_Tag_Grammar;

   ---------------------------
   -- To_Call_Grammar --
   ---------------------------

   procedure To_Call_Grammar
     (Text    : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out E.Error_Info) is
   begin
      Write (Text, Grammar, Last, Status, In_Tags => True,
             Before => "", After => "=", Close => "", In_Call => True);
   end To_Call_Grammar;

end Model_Runner.Schema;
