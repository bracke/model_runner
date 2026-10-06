separate (Model_Runner.Templates.Render)
function Qwen_Tool_Of (Src : String) return String is
   Out_Text : Ada.Strings.Unbounded.Unbounded_String;

   procedure Put (S : String) is
   begin
      Ada.Strings.Unbounded.Append (Out_Text, S);
   end Put;

   --  A span of Src, empty when First > Last.
   type Span is record
      First : Natural := 1;
      Last  : Natural := 0;
   end record;

   function Present (S : Span) return Boolean is (S.First <= S.Last);

   function Past_Blanks (From : Natural) return Natural is
      I : Natural := From;
   begin
      while I <= Src'Last
        and then Src (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
      loop
         I := I + 1;
      end loop;
      return I;
   end Past_Blanks;

   --  The value beginning at I: a string with its quotes, an object
   --  or array with its brackets, or a bare number or word.
   function Value_At (From : Natural) return Span is
      I : Natural := Past_Blanks (From);
      Depth : Natural := 0;
      In_String : Boolean := False;
      Start : constant Natural := I;
   begin
      if I > Src'Last then
         return (1, 0);
      end if;
      if Src (I) = '"' then
         I := I + 1;
         while I <= Src'Last and then Src (I) /= '"' loop
            if Src (I) = '\' then
               I := I + 1;
            end if;
            I := I + 1;
         end loop;
         return (Start, Natural'Min (I, Src'Last));
      elsif Src (I) in '{' | '[' then
         loop
            exit when I > Src'Last;
            if In_String then
               if Src (I) = '\' then
                  I := I + 1;
               elsif Src (I) = '"' then
                  In_String := False;
               end if;
            elsif Src (I) = '"' then
               In_String := True;
            elsif Src (I) in '{' | '[' then
               Depth := Depth + 1;
            elsif Src (I) in '}' | ']' then
               Depth := Depth - 1;
               exit when Depth = 0;
            end if;
            I := I + 1;
         end loop;
         return (Start, Natural'Min (I, Src'Last));
      else
         while I <= Src'Last
           and then Src (I) not in ',' | '}' | ']' | ' ' | ASCII.LF
         loop
            I := I + 1;
         end loop;
         return (Start, I - 1);
      end if;
   end Value_At;

   --  The next member of an object from Cursor, which starts just
   --  past the opening brace; Found is False at the closing one.
   procedure Next_Member
     (Cursor : in out Natural;
      Key    : out Span;
      Held   : out Span;
      Found  : out Boolean)
   is
      I : Natural := Past_Blanks (Cursor);
   begin
      Found := False;
      Key := (1, 0);
      Held := (1, 0);
      if I <= Src'Last and then Src (I) = ',' then
         I := Past_Blanks (I + 1);
      end if;
      if I > Src'Last or else Src (I) /= '"' then
         return;
      end if;
      Key := Value_At (I);
      I := Past_Blanks (Key.Last + 1);
      if I <= Src'Last and then Src (I) = ':' then
         I := I + 1;
      end if;
      Held := Value_At (I);
      Cursor := Held.Last + 1;
      Found := True;
   end Next_Member;

   --  The next element of an array from Cursor, just past the bracket.
   procedure Next_Element
     (Cursor : in out Natural; Held : out Span; Found : out Boolean)
   is
      I : Natural := Past_Blanks (Cursor);
   begin
      Found := False;
      Held := (1, 0);
      if I <= Src'Last and then Src (I) = ',' then
         I := Past_Blanks (I + 1);
      end if;
      if I > Src'Last or else Src (I) = ']' then
         return;
      end if;
      Held := Value_At (I);
      Cursor := Held.Last + 1;
      Found := True;
   end Next_Element;

   function Member (Obj : Span; Name : String) return Span is
      Cursor : Natural;
      Key, Held : Span;
      Found : Boolean;
   begin
      if not Present (Obj) or else Src (Obj.First) /= '{' then
         return (1, 0);
      end if;
      Cursor := Obj.First + 1;
      loop
         Next_Member (Cursor, Key, Held, Found);
         exit when not Found;
         if Src (Key.First + 1 .. Key.Last - 1) = Name then
            return Held;
         end if;
      end loop;
      return (1, 0);
   end Member;

   function Is_String (S : Span) return Boolean
   is (Present (S) and then Src (S.First) = '"');
   function Is_Mapping (S : Span) return Boolean
   is (Present (S) and then Src (S.First) = '{');
   function Is_List (S : Span) return Boolean
   is (Present (S) and then Src (S.First) = '[');

   --  A JSON string's characters. The definition's escapes are
   --  decoded already, so what remains are the ones JSON requires.
   function Decoded (S : Span) return String is
      R : String (1 .. S.Last - S.First + 1);
      M : Natural := 0;
      I : Natural := S.First + 1;
   begin
      while I < S.Last loop
         if Src (I) = '\' and then I + 1 < S.Last then
            I := I + 1;
            M := M + 1;
            case Src (I) is
               when 'n' => R (M) := ASCII.LF;
               when 't' => R (M) := ASCII.HT;
               when 'r' => R (M) := ASCII.CR;
               when others => R (M) := Src (I);
            end case;
         else
            M := M + 1;
            R (M) := Src (I);
         end if;
         I := I + 1;
      end loop;
      return R (1 .. M);
   end Decoded;

   --  Python's str of a value, which is what `| string` writes.
   function Pythonic (S : Span) return String;

   --  Python's repr of a value, which is how str writes a list's or a
   --  mapping's entries: strings in single quotes.
   function Repr (S : Span) return String is
      R : Ada.Strings.Unbounded.Unbounded_String;
      Cursor : Natural;
      Key, Held : Span;
      Found : Boolean;
      First_One : Boolean := True;
   begin
      if Is_String (S) then
         return "'" & Decoded (S) & "'";
      elsif Is_List (S) then
         Ada.Strings.Unbounded.Append (R, "[");
         Cursor := S.First + 1;
         loop
            Next_Element (Cursor, Held, Found);
            exit when not Found;
            if not First_One then
               Ada.Strings.Unbounded.Append (R, ", ");
            end if;
            First_One := False;
            Ada.Strings.Unbounded.Append (R, Repr (Held));
         end loop;
         Ada.Strings.Unbounded.Append (R, "]");
         return Ada.Strings.Unbounded.To_String (R);
      elsif Is_Mapping (S) then
         Ada.Strings.Unbounded.Append (R, "{");
         Cursor := S.First + 1;
         loop
            Next_Member (Cursor, Key, Held, Found);
            exit when not Found;
            if not First_One then
               Ada.Strings.Unbounded.Append (R, ", ");
            end if;
            First_One := False;
            Ada.Strings.Unbounded.Append
              (R, Repr (Key) & ": " & Repr (Held));
         end loop;
         Ada.Strings.Unbounded.Append (R, "}");
         return Ada.Strings.Unbounded.To_String (R);
      end if;
      return Pythonic (S);
   end Repr;

   function Pythonic (S : Span) return String is
      Bare : constant String :=
        (if Present (S) then Src (S.First .. S.Last) else "");
   begin
      if Is_String (S) then
         return Decoded (S);
      elsif Is_List (S) or else Is_Mapping (S) then
         return Repr (S);
      elsif Bare = "true" then
         return "True";
      elsif Bare = "false" then
         return "False";
      elsif Bare = "null" then
         return "None";
      end if;
      return Bare;
   end Pythonic;

   --  render_item_list: a non-empty list inside a tag, its strings
   --  in backticks and anything else as it prints.
   procedure Item_List (List : Span; Tag : String) is
      Cursor : Natural;
      Held : Span;
      Found : Boolean;
      First_One : Boolean := True;
   begin
      if not Is_List (List) then
         return;
      end if;
      Cursor := List.First + 1;
      Next_Element (Cursor, Held, Found);
      if not Found then
         return;
      end if;
      Put (ASCII.LF & "<" & Tag & ">[");
      loop
         if not First_One then
            Put (", ");
         end if;
         First_One := False;
         if Is_String (Held) then
            Put ("`" & Decoded (Held) & "`");
         else
            Put (Pythonic (Held));
         end if;
         Next_Element (Cursor, Held, Found);
         exit when not Found;
      end loop;
      Put ("]</" & Tag & ">");
   end Item_List;

   --  A value inside a tag named for its key: the JSON of a mapping,
   --  Python's str of anything else.
   procedure In_Tag (Key : String; Held : Span) is
   begin
      Put (ASCII.LF & "<" & Key & ">");
      if Is_Mapping (Held) then
         Put (Src (Held.First .. Held.Last));
      else
         Put (Pythonic (Held));
      end if;
      Put ("</" & Key & ">");
   end In_Tag;

   Whole : constant Span := Value_At (Src'First);
   Tool  : Span := Whole;
begin
   if Present (Member (Whole, "function")) then
      Tool := Member (Whole, "function");
   end if;

   Put (ASCII.LF & "<function>" & ASCII.LF & "<name>");
   Put (Pythonic (Member (Tool, "name")));
   Put ("</name>");
   Put (ASCII.LF & "<description>");
   Put (Model_Runner.Text.Trim (Pythonic (Member (Tool, "description"))));
   Put ("</description>");
   Put (ASCII.LF & "<parameters>");

   declare
      Parameters : constant Span := Member (Tool, "parameters");
      Properties : constant Span := Member (Parameters, "properties");
      Cursor     : Natural;
      Key, Fields : Span;
      Found      : Boolean;
   begin
      if Is_Mapping (Properties) then
         Cursor := Properties.First + 1;
         loop
            Next_Member (Cursor, Key, Fields, Found);
            exit when not Found;
            Put (ASCII.LF & "<parameter>");
            Put (ASCII.LF & "<name>" & Decoded (Key) & "</name>");
            if Present (Member (Fields, "type")) then
               Put (ASCII.LF & "<type>"
                    & Pythonic (Member (Fields, "type")) & "</type>");
            end if;
            if Present (Member (Fields, "description")) then
               Put (ASCII.LF & "<description>"
                    & Model_Runner.Text.Trim
                        (Pythonic (Member (Fields, "description")))
                    & "</description>");
            end if;
            Item_List (Member (Fields, "enum"), "enum");

            declare
               Inner : Natural := Fields.First + 1;
               K, V  : Span;
               More  : Boolean;
            begin
               if Is_Mapping (Fields) then
                  loop
                     Next_Member (Inner, K, V, More);
                     exit when not More;
                     declare
                        Name : constant String := Decoded (K);
                     begin
                        if Name /= "type" and then Name /= "description"
                          and then Name /= "enum"
                          and then Name /= "required"
                        then
                           In_Tag (Name, V);
                        end if;
                     end;
                  end loop;
               end if;
            end;

            Item_List (Member (Fields, "required"), "required");
            Put (ASCII.LF & "</parameter>");
         end loop;
      end if;
      Item_List (Member (Parameters, "required"), "required");
   end;

   Put (ASCII.LF & "</parameters>");
   if Present (Member (Tool, "return")) then
      In_Tag ("return", Member (Tool, "return"));
   end if;
   Put (ASCII.LF & "</function>");

   return Ada.Strings.Unbounded.To_String (Out_Text);
end Qwen_Tool_Of;
