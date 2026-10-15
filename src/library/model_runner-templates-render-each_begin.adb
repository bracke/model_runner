separate (Model_Runner.Templates.Render)
procedure Each_Begin (Step : Instruction) is
   Given : constant Held := Held_Of (Item.Operands.all (Step.Value_At));

   --  A filtered loop walks JSON: the tools, a list of messages and
   --  a turn's calls are filtered as the lists they are written as.
   V : constant Held :=
     (if Step.Test_At /= 0
        and then Given.Kind not in Value_Data | Value_JSON
        and then Given.Kind /= Value_Undefined
      then As_Data (Listed (Given))
      else Given);
   L : Loop_State;

   --  The container a filtered loop walks: what passes the filter of
   --  what the loop was given, each element bound to the loop's
   --  names while its test is asked, as the language asks it. What
   --  the binding wrote into the pool is given back: the loop binds
   --  again from what is kept.
   function Filtered (Src : String) return String is
      Out_Text : Ada.Strings.Unbounded.Unbounded_String;
      Cursor   : Natural := Src'First + 1;
      Key, Value : Span;
      Found    : Boolean;
      Kept     : Natural := 0;
      Mark     : constant Natural := Pool_Used;
      Listing  : constant Boolean := Is_JSON_List (Src);

      procedure Bind_Free (Where : Natural; Piece : String) is
      begin
         if Is_JSON_String (Piece) then
            Assign_Text (Where, Decoded (Piece));
         elsif Is_JSON_Number (Piece) then
            Assign_Text (Where, Piece, Value_Number);
         elsif Piece in "true" | "false" | "null" then
            Store (Where, Read_Out (Piece));
         else
            Store (Where, As_Data (Piece));
         end if;
      end Bind_Free;

      procedure Keep_Piece (Piece : String) is
      begin
         if Kept > 0 then
            Ada.Strings.Unbounded.Append (Out_Text, ", ");
         end if;
         Ada.Strings.Unbounded.Append (Out_Text, Piece);
         Kept := Kept + 1;
      end Keep_Piece;
   begin
      loop
         if Listing then
            Next_Element (Src, Cursor, Value, Found);
            exit when not Found;
            if Step.Length /= 0
              and then Is_JSON_List (Src (Value.First .. Value.Last))
            then
               --  Two names over a list of pairs take each apart, as
               --  the loop itself will.
               declare
                  Inner : Natural := Value.First + 1;
                  One, Two : Span;
                  Got   : Boolean;
               begin
                  Next_Element (Src, Inner, One, Got);
                  if Got then
                     Bind_Free (Step.Offset, Src (One.First .. One.Last));
                     Next_Element (Src, Inner, Two, Got);
                     if Got then
                        Bind_Free
                          (Step.Length, Src (Two.First .. Two.Last));
                     end if;
                  end if;
               end;
            else
               Bind_Free (Step.Offset, Src (Value.First .. Value.Last));
            end if;
            if Truth_Of (Item.Conditions.all (Step.Test_At)) then
               Keep_Piece (Src (Value.First .. Value.Last));
            end if;
         else
            Next_Member (Src, Cursor, Key, Value, Found);
            exit when not Found;
            Assign_Text
              (Step.Offset, Decoded (Src (Key.First .. Key.Last)));
            if Step.Length /= 0 then
               Bind_Free (Step.Length, Src (Value.First .. Value.Last));
            end if;
            if Truth_Of (Item.Conditions.all (Step.Test_At)) then
               Keep_Piece (Src (Key.First .. Key.Last) & ": "
                           & Src (Value.First .. Value.Last));
            end if;
         end if;
      end loop;

      Pool_Used := Mark;
      Slots (Step.Offset) := (Kind => Value_Undefined, others => <>);
      if Step.Length /= 0 then
         Slots (Step.Length) := (Kind => Value_Undefined, others => <>);
      end if;

      return (if Listing then "[" else "{")
        & Ada.Strings.Unbounded.To_String (Out_Text)
        & (if Listing then "]" else "}");
   end Filtered;

   --  A string walked as the language walks one: a character at a time,
   --  as a list of one-character strings -- whole UTF-8 characters, not
   --  bytes. Walked as anything else it rendered nothing.
   function Characters (Text : String) return String is
      Out_Text : Ada.Strings.Unbounded.Unbounded_String;
      At_Byte  : Natural := Text'First;
   begin
      Ada.Strings.Unbounded.Append (Out_Text, "[");
      while At_Byte <= Text'Last loop
         declare
            Lead  : constant Natural := Character'Pos (Text (At_Byte));
            Width : constant Positive :=
              (if Lead >= 16#F0# then 4 elsif Lead >= 16#E0# then 3
               elsif Lead >= 16#C0# then 2 else 1);
            Upto  : constant Natural :=
              Natural'Min (Text'Last, At_Byte + Width - 1);
         begin
            if At_Byte > Text'First then
               Ada.Strings.Unbounded.Append (Out_Text, ", ");
            end if;
            Ada.Strings.Unbounded.Append
              (Out_Text, Quoted (Text (At_Byte .. Upto)));
            At_Byte := Upto + 1;
         end;
      end loop;
      Ada.Strings.Unbounded.Append (Out_Text, "]");
      return Ada.Strings.Unbounded.To_String (Out_Text);
   end Characters;
begin
   L.Var := Step.Offset;
   L.Key := Step.Length;
   L.Index := 1;
   L.Reversed := Step.Reversed;

   case V.Kind is
      when Value_Data | Value_JSON | Value_Text =>
         declare
            Src : constant String :=
              (if V.Kind = Value_Text then Characters (Text_Of (V))
               elsif Step.Test_At /= 0
                 and then (Is_JSON_List (JSON_Text (V))
                           or else Is_JSON_Mapping (JSON_Text (V)))
               then Filtered (JSON_Text (V))
               else JSON_Text (V));
         begin
            if Is_JSON_List (Src) then
               L.Kind := Over_Elements;
            elsif Is_JSON_Mapping (Src) then
               L.Kind := Over_Entries;
            else
               Position := Step.Target;
               return;
            end if;
            L.Total := JSON_Length (Src);
            if L.Total = 0 then
               Position := Step.Target;
               return;
            end if;
            --  The container's text, kept while the loop runs and
            --  read element by element.
            if Pool_Used + Src'Length > Pool'Length then
               Refuse (Item.Names (L.Var).Offset,
                       Item.Names (L.Var).Length,
                       E.Template_Variables_Too_Large);
               Position := Step.Target;
               return;
            end if;
            L.Base := Pool_Used;
            L.Base_Length := Src'Length;
            Pool (Pool_Used + 1 .. Pool_Used + Src'Length) := Src;
            Pool_Used := Pool_Used + Src'Length;
            L.Cursor := L.Base + 2;
         end;
      when Value_Tools =>
         L.Kind := Over_Tools;
         L.Total := Tool_Count;
      when Value_List =>
         L.Kind := Over_Messages;
         L.From := V.Start;
         L.To := Last_Of (V);
         L.Total := Integer'Max (Last_Of (V) - V.Start + 1, 0);
      when Value_Call =>
         if V.Index /= 0 then
            Position := Step.Target;
            return;
         end if;
         L.Kind := Over_Calls;
         L.Message := V.Start;
         L.Total := Length_Of (V);
      when others =>
         --  A name never assigned is refused here as it is in the
         --  output; a field a message has not got, or none, is an
         --  empty walk -- and so are the tools when none were
         --  offered, which is what a template that walks them
         --  unguarded means.
         declare
            Source : Operand renames Item.Operands.all (Step.Value_At);
         begin
            if V.Kind = Value_Undefined
              and then Source.Count = 1
              and then Source.Terms (1).Offset /= Item.Tools_Slot
              and then Source.Terms (1).Kind = Term_Variable
              and then Source.Terms (1).Path_Len = 0
              and then not Source.Terms (1).Indexes
              and then Source.Terms (1).Chained = 0
              and then Source.Terms (1).Filtered = 0
            then
               Refuse (Item.Names (Source.Terms (1).Offset).Offset,
                       Item.Names (Source.Terms (1).Offset).Length,
                       E.Template_Unknown_Variable);
            end if;
         end;
         Position := Step.Target;
         return;
   end case;

   if L.Total = 0 then
      Position := Step.Target;
      return;
   elsif Loop_Depth >= Max_Loops then
      --  Refused, not skipped: a loop the template meant, left out unsaid.
      Refuse (Item.Names (L.Var).Offset, Item.Names (L.Var).Length,
              E.Template_Nesting_Too_Deep);
      Position := Step.Target;
      return;
   end if;

   Push_Loop (L);
   Bind_Element (Loops (Loop_Depth));
   Position := Position + 1;
end Each_Begin;
