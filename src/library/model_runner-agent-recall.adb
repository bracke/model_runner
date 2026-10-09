with Ada.Containers.Indefinite_Vectors;

package body Model_Runner.Agent.Recall is

   use type Interfaces.Unsigned_64;

   package Member_Names is new Ada.Containers.Indefinite_Vectors (Positive, String);
   package Name_Sorting is new Member_Names.Generic_Sorting;

   ---------------
   -- Canonical --
   ---------------

   function Canonical (Arguments : String) return String is
      use Ada.Strings.Unbounded;

      At_Char : Natural := Arguments'First;
      Bad     : exception;

      procedure Skip is
      begin
         while At_Char <= Arguments'Last
           and then Arguments (At_Char) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            At_Char := At_Char + 1;
         end loop;
      end Skip;

      function Peek return Character is
      begin
         Skip;
         if At_Char > Arguments'Last then
            raise Bad;
         end if;
         return Arguments (At_Char);
      end Peek;

      --  A string as written, quotes and escapes and all.
      function Text return String is
         First : Positive;
      begin
         if Peek /= '"' then
            raise Bad;
         end if;
         First := At_Char;
         At_Char := At_Char + 1;
         while At_Char <= Arguments'Last and then Arguments (At_Char) /= '"' loop
            if Arguments (At_Char) = '\' then
               At_Char := At_Char + 1;
            end if;
            At_Char := At_Char + 1;
         end loop;
         if At_Char > Arguments'Last then
            raise Bad;
         end if;
         At_Char := At_Char + 1;
         return Arguments (First .. At_Char - 1);
      end Text;

      function Value return String;

      --  An object's members in the order of their names; a name given
      --  twice is the last given, as a reader takes it.
      function Object return String is
         package Members is new Ada.Containers.Indefinite_Hashed_Maps
           (String, String, Ada.Strings.Hash, "=");
         Held  : Members.Map;
         Names : Member_Names.Vector;
         Said  : Unbounded_String := To_Unbounded_String ("{");
      begin
         At_Char := At_Char + 1;
         if Peek = '}' then
            At_Char := At_Char + 1;
            return "{}";
         end if;
         loop
            declare
               Name : constant String := Text;
            begin
               if Peek /= ':' then
                  raise Bad;
               end if;
               At_Char := At_Char + 1;
               declare
                  Given : constant String := Value;
               begin
                  if Held.Contains (Name) then
                     Held.Replace (Name, Given);
                  else
                     Held.Insert (Name, Given);
                     Names.Append (Name);
                  end if;
               end;
            end;
            case Peek is
               when ',' =>
                  At_Char := At_Char + 1;
               when '}' =>
                  At_Char := At_Char + 1;
                  exit;
               when others =>
                  raise Bad;
            end case;
         end loop;
         Name_Sorting.Sort (Names);
         for Index in Names.First_Index .. Names.Last_Index loop
            Append (Said, (if Index = Names.First_Index then "" else ",")
                          & Names (Index) & ":" & Held.Element (Names (Index)));
         end loop;
         return To_String (Said) & "}";
      end Object;

      function List return String is
         Said  : Unbounded_String := To_Unbounded_String ("[");
         First : Boolean := True;
      begin
         At_Char := At_Char + 1;
         if Peek = ']' then
            At_Char := At_Char + 1;
            return "[]";
         end if;
         loop
            Append (Said, (if First then "" else ",") & Value);
            First := False;
            case Peek is
               when ',' =>
                  At_Char := At_Char + 1;
               when ']' =>
                  At_Char := At_Char + 1;
                  exit;
               when others =>
                  raise Bad;
            end case;
         end loop;
         return To_String (Said) & "]";
      end List;

      --  A number or a literal, as written.
      function Word return String is
         First : Positive;
      begin
         Skip;
         First := At_Char;
         while At_Char <= Arguments'Last
           and then Arguments (At_Char)
                    not in ',' | '}' | ']' | ':' | ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            At_Char := At_Char + 1;
         end loop;
         if At_Char = First then
            raise Bad;
         end if;
         return Arguments (First .. At_Char - 1);
      end Word;

      function Value return String is
      begin
         case Peek is
            when '{' => return Object;
            when '[' => return List;
            when '"' => return Text;
            when others => return Word;
         end case;
      end Value;

      --  What is not JSON, without the space outside its strings.
      function Squeezed return String is
         Result : String (1 .. Arguments'Length);
         Last   : Natural := 0;
         Quoted : Boolean := False;
         Escape : Boolean := False;
      begin
         for C of Arguments loop
            if Quoted then
               Last := Last + 1;
               Result (Last) := C;
               if Escape then
                  Escape := False;
               elsif C = '\' then
                  Escape := True;
               elsif C = '"' then
                  Quoted := False;
               end if;
            elsif C = '"' then
               Quoted := True;
               Last := Last + 1;
               Result (Last) := C;
            elsif C not in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
               Last := Last + 1;
               Result (Last) := C;
            end if;
         end loop;
         return Result (1 .. Last);
      end Squeezed;
   begin
      declare
         Whole : constant String := Value;
      begin
         Skip;
         if At_Char <= Arguments'Last then
            raise Bad;
         end if;
         return Whole;
      end;
   exception
      when Bad | Constraint_Error =>
         return Squeezed;
   end Canonical;

   --------------
   -- Identity --
   --------------

   function Identity (Named : String; Arguments : String) return String is
     (Named & ASCII.NUL & Canonical (Arguments));

   ----------
   -- Hash --
   ----------

   function Hash (Item : Pair) return Ada.Containers.Hash_Type is
     (Ada.Containers.Hash_Type'Mod (Item.Of_What xor (Item.Was * 31)));

   -----------
   -- Holds --
   -----------

   function Holds (Self : Memory; Key : String) return Boolean
   is (Self.Held.Contains (Key));

   --------------
   -- Answered --
   --------------

   function Answered (Self : Memory; Key : String) return Boolean
   is (Self.Held.Contains (Key) and then Self.Held.Element (Key).Has_Answer);

   ------------
   -- Answer --
   ------------

   function Answer (Self : Memory; Key : String) return String
   is (if Answered (Self, Key)
       then Ada.Strings.Unbounded.To_String (Self.Held.Element (Key).Answer)
       else "");

   -----------
   -- Ended --
   -----------

   function Ended (Self : Memory; Key : String)
     return Model_Runner.Tools.Runner.Call_Outcome
   is (if Answered (Self, Key) then Self.Held.Element (Key).Ends
       else Model_Runner.Tools.Runner.Done);

   --------------
   -- Remember --
   --------------

   procedure Remember (Self : in out Memory; Key : String) is
   begin
      if not Self.Held.Contains (Key) then
         Self.Held.Insert (Key, (others => <>));
      end if;
   end Remember;

   ----------
   -- Keep --
   ----------

   procedure Keep
     (Self  : in out Memory;
      Key   : String;
      Text  : String;
      Ended : Model_Runner.Tools.Runner.Call_Outcome) is
   begin
      if Self.Held.Contains (Key) and then not Self.Held.Element (Key).Has_Answer then
         Self.Held.Replace
           (Key, (Answer     => Ada.Strings.Unbounded.To_Unbounded_String (Text),
                  Ends       => Ended,
                  Has_Answer => True));
      end if;
   end Keep;

   -------------
   -- Changed --
   -------------

   procedure Changed (Self : in out Memory; Key : String) is
   begin
      Self.Held.Clear;
      Remember (Self, Key);
   end Changed;

   ----------

   procedure Note
     (Self    : in out Work_Log;
      Named   : String;
      Subject : String;
      Kind    : Model_Runner.Tools.Runner.Call_Kind;
      Ended   : Model_Runner.Tools.Runner.Call_Outcome)
   is
      use Ada.Strings.Unbounded;
   begin
      for Row of Self.Rows loop
         if Row.Named = Named and then Row.Subject = Subject then
            Row.Ended := Ended;
            return;
         end if;
      end loop;
      Self.Rows.Append
        (Entry_Row'(Named   => To_Unbounded_String (Named),
          Subject => To_Unbounded_String (Subject),
                    Kind    => Kind,
                    Ended   => Ended));
   end Note;

   -----------------
   -- Record_Text --
   -----------------

   function Record_Text (Self : Work_Log) return String is
      use Ada.Strings.Unbounded;
      package Tr renames Model_Runner.Tools.Runner;
      use type Tr.Answer_Kind;
      use type Tr.Call_Kind;

      type Section is (Changed, Read, Failing, Refused);

      Said : Unbounded_String;

      function Of_Section (Row : Entry_Row; Which : Section) return Boolean
      is (case Which is
            when Changed => Row.Ended.Answer = Tr.Answered and then Row.Ended.Changed,
            when Read    => Row.Ended.Answer = Tr.Answered and then Row.Kind /= Tr.Changes,
            when Failing => Row.Ended.Answer in Tr.Failed | Tr.Timed_Out | Tr.Cancelled,
            when Refused => Row.Ended.Answer = Tr.Refused);

      function Why (Row : Entry_Row) return String
      is (if Row.Ended.Answer /= Tr.Refused then ""
          else (case Row.Ended.Refusal is
                  when Tr.Outside_Project => " (outside the project)",
                  when Tr.Harness_Owned   => " (the harness's own)",
                  when Tr.Policy          => " (not a program the policy allows)",
                  when others             => " (not permitted)"));

      function Heading (Which : Section) return String
      is (case Which is
            when Changed => "changed: ",
            when Read    => "read: ",
            when Failing => "failed, and not answered since: ",
            when Refused => "refused: ");
   begin
      for Which in Section loop
         declare
            Line : Unbounded_String;
         begin
            for Row of Self.Rows loop
               if Of_Section (Row, Which) then
                  Append (Line,
                          (if Length (Line) = 0 then Heading (Which) else "; ")
                          & To_String (Row.Named)
                          & (if Length (Row.Subject) = 0 then ""
                             else " " & To_String (Row.Subject))
                          & Why (Row));
               end if;
            end loop;
            if Length (Line) > 0 then
               Append (Said, To_String (Line) & ASCII.LF);
            end if;
         end;
      end loop;
      return (if Length (Said) <= Record_Most then To_String (Said)
              else Slice (Said, 1, Record_Most - 4) & " ..." & ASCII.LF);
   end Record_Text;

   ----------------
   -- Seen_Again --
   ----------------

   function Seen_Again
     (Self    : in out Sightings;
      Of_What : Interfaces.Unsigned_64;
      Was     : Interfaces.Unsigned_64) return Boolean
   is
   begin
      if Self.Held.Contains ((Of_What, Was)) then
         return True;
      end if;
      Self.Held.Insert ((Of_What, Was));
      return False;
   end Seen_Again;

end Model_Runner.Agent.Recall;
