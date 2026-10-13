with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;

with Model_Runner.Tools;

package body Model_Runner.Agent.Recall is

   ---------------
   -- Canonical --
   ---------------

   function Canonical (Arguments : String) return String is
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

      Document : Jsonlib.Documents.Document;
      Error    : Jsonlib.Errors.Error_Info;
   begin
      --  Read as JSON is read -- jsonlib -- once a model's raw controls in
      --  its strings are escaped, a name given twice the last given; and
      --  written back one way: members in the order of their names, no
      --  space between tokens, each string escaped only where it must be.
      --  The same call however its JSON was spelled is one call, as the
      --  tool that runs it reads it.
      Jsonlib.Parsers.Parse
        (Model_Runner.Tools.Controls_Escaped (Arguments), Document, Error,
         (Jsonlib.Parsers.Default_Options with delta Duplicates => Jsonlib.Parsers.Last_Wins));
      if Jsonlib.Errors.Failed (Error) then
         return Squeezed;
      end if;
      return Jsonlib.Serializers.To_String
        (Document, (Jsonlib.Serializers.Default_Options with delta Sort_Members => True));
   end Canonical;

   --------------
   -- Identity --
   --------------

   function Identity (Named : String; Arguments : String) return String is
     (Named & ASCII.NUL & Canonical (Arguments));

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

   procedure Remember
     (Self    : in out Memory;
      Key     : String;
      Touches : Model_Runner.Tools.Runner.Resource := Model_Runner.Tools.Runner.Anything) is
   begin
      if not Self.Held.Contains (Key) then
         Self.Held.Insert (Key, (Touches => Touches, others => <>));
      end if;
   end Remember;

   --------------
   -- Stamp_Of --
   --------------

   function Stamp_Of (Self : Memory; Key : String) return String
   is (if Self.Held.Contains (Key)
       then Ada.Strings.Unbounded.To_String (Self.Held.Element (Key).Stamp) else "");

   ------------
   -- Forget --
   ------------

   procedure Forget (Self : in out Memory; Key : String) is
   begin
      if Self.Held.Contains (Key) then
         Self.Held.Delete (Key);
      end if;
   end Forget;

   ----------
   -- Keep --
   ----------

   procedure Keep
     (Self  : in out Memory;
      Key   : String;
      Text  : String;
      Ended : Model_Runner.Tools.Runner.Call_Outcome;
      Stamp : String := "") is
   begin
      if Self.Held.Contains (Key) and then not Self.Held.Element (Key).Has_Answer then
         Self.Held.Replace
           (Key, (Answer     => Ada.Strings.Unbounded.To_Unbounded_String (Text),
                  Ends       => Ended,
                  Has_Answer => True,
                  Touches    => Self.Held.Element (Key).Touches,
                  Stamp      => Ada.Strings.Unbounded.To_Unbounded_String (Stamp)));
      end if;
   end Keep;

   -------------
   -- Changed --
   -------------

   procedure Changed
     (Self    : in out Memory;
      Key     : String;
      Touches : Model_Runner.Tools.Runner.Resource := Model_Runner.Tools.Runner.Anything)
   is
      use type Model_Runner.Tools.Runner.Resource;
      Stale : Call_Maps.Map;
   begin
      for Position in Self.Held.Iterate loop
         declare
            Held : constant Model_Runner.Tools.Runner.Resource := Call_Maps.Element (Position).Touches;
         begin
            if Held /= Model_Runner.Tools.Runner.Pure
              and then (Touches = Model_Runner.Tools.Runner.Anything
                        or else Held = Model_Runner.Tools.Runner.Anything
                        or else Held = Touches)
            then
               Stale.Insert (Call_Maps.Key (Position), Call_Maps.Element (Position));
            end if;
         end;
      end loop;
      for Position in Stale.Iterate loop
         Self.Held.Delete (Call_Maps.Key (Position));
      end loop;
      Remember (Self, Key, Touches);
   end Changed;

   ----------

   function Made_Change (Ended : Model_Runner.Tools.Runner.Call_Outcome) return Boolean
   is (Model_Runner.Tools.Runner."=" (Ended.Answer, Model_Runner.Tools.Runner.Answered) and then Ended.Changed);

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
            Row.Changed_Ever := Row.Changed_Ever or else Made_Change (Ended);
            return;
         end if;
      end loop;
      Self.Rows.Append
        (Entry_Row'(Named   => To_Unbounded_String (Named),
          Subject => To_Unbounded_String (Subject),
                    Kind    => Kind,
                    Ended   => Ended,
                    Changed_Ever => Made_Change (Ended)));
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
            when Changed => Row.Changed_Ever,
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
      Of_What : String;
      Was     : String) return Boolean
   is
      Whole : constant String := Of_What & ASCII.NUL & Was;
   begin
      if Self.Held.Contains (Whole) then
         return True;
      end if;
      Self.Held.Insert (Whole);
      return False;
   end Seen_Again;

   --------------
   -- Note_For --
   --------------

   function Note_For
     (Self     : in out Carried;
      Key      : String;
      Path     : String;
      Said     : String;
      Ran      : Boolean;
      Reads    : Boolean;
      Answered : Boolean;
      Changed  : Boolean;
      After    : String;
      Quiet    : Natural) return String
   is
      --  An answer with the evidence records it names left out: a check
      --  run again names a new one each time, and failing the same way read
      --  as an answer never given.
      function Without_Evidence (Text : String) return String is
         Kept : Ada.Strings.Unbounded.Unbounded_String;
         At_C : Natural := Text'First;
      begin
         while At_C <= Text'Last loop
            if At_C + 4 <= Text'Last and then Text (At_C .. At_C + 3) = "VER-"
              and then Text (At_C + 4) in '0' .. '9'
            then
               Ada.Strings.Unbounded.Append (Kept, "VER-#");
               At_C := At_C + 4;
               while At_C <= Text'Last and then Text (At_C) in '0' .. '9' loop
                  At_C := At_C + 1;
               end loop;
            else
               Ada.Strings.Unbounded.Append (Kept, Text (At_C));
               At_C := At_C + 1;
            end if;
         end loop;
         return Ada.Strings.Unbounded.To_String (Kept);
      end Without_Evidence;

      Again  : constant Boolean :=
        Ran and then Answered and then Reads
        and then Self.Sighted.Seen_Again (Key, Without_Evidence (Said));
      --  A file's revisions, read or written, are kept as seen; a change
      --  that leaves it at one seen before puts it back -- by edit_file as
      --  by write_file, to a version read as to one written.
      Had_It : constant Boolean :=
        Ran and then Path /= "" and then Answered and then After /= ""
        and then Self.Sighted.Seen_Again ("revision" & ASCII.NUL & Path, After);
      Back   : constant Boolean := Changed and then Had_It;
   begin
      if Again and then Self.Made_Change then
         return ASCII.LF & "(note from the harness: this answers exactly as it did before your last change)";
      elsif Back then
         return ASCII.LF & "(note from the harness: this puts " & Path
           & " back to a version it had earlier in this work, revision " & After & ")";
      elsif Quiet > 0 and then Quiet mod Quiet_Note = 0 then
         return ASCII.LF & "(note from the harness:" & Natural'Image (Quiet)
           & " calls in a row have changed nothing; if what you need is in hand, act on it or give"
           & " your answer)";
      end if;
      return "";
   end Note_For;

end Model_Runner.Agent.Recall;
