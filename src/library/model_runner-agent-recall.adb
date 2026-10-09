package body Model_Runner.Agent.Recall is

   use type Interfaces.Unsigned_64;

   --  Where a call is held, or nought.
   function Place (Self : Memory; Key : Interfaces.Unsigned_64) return Natural is
   begin
      for Index in 1 .. Self.Used loop
         if Self.Held (Index) = Key then
            return Index;
         end if;
      end loop;
      return 0;
   end Place;

   -----------
   -- Holds --
   -----------

   function Holds (Self : Memory; Key : Interfaces.Unsigned_64) return Boolean
   is (Place (Self, Key) > 0);

   --------------
   -- Answered --
   --------------

   function Answered (Self : Memory; Key : Interfaces.Unsigned_64) return Boolean
   is (Place (Self, Key) > 0 and then Self.Has_Answer (Place (Self, Key)));

   ------------
   -- Answer --
   ------------

   function Answer (Self : Memory; Key : Interfaces.Unsigned_64) return String
   is (if Answered (Self, Key)
       then Ada.Strings.Unbounded.To_String (Self.Answers (Place (Self, Key)))
       else "");

   -----------
   -- Ended --
   -----------

   function Ended (Self : Memory; Key : Interfaces.Unsigned_64)
     return Model_Runner.Tools.Runner.Call_Outcome
   is (if Answered (Self, Key) then Self.Ends (Place (Self, Key))
       else Model_Runner.Tools.Runner.Done);

   --------------
   -- Remember --
   --------------

   procedure Remember (Self : in out Memory; Key : Interfaces.Unsigned_64) is
   begin
      if Place (Self, Key) = 0 and then Self.Used < Most then
         Self.Used := Self.Used + 1;
         Self.Held (Self.Used) := Key;
         Self.Answers (Self.Used) := Ada.Strings.Unbounded.Null_Unbounded_String;
         Self.Has_Answer (Self.Used) := False;
      end if;
   end Remember;

   ----------
   -- Keep --
   ----------

   procedure Keep
     (Self  : in out Memory;
      Key   : Interfaces.Unsigned_64;
      Text  : String;
      Ended : Model_Runner.Tools.Runner.Call_Outcome)
   is
      At_Key : constant Natural := Place (Self, Key);
   begin
      if At_Key > 0 and then not Self.Has_Answer (At_Key) then
         Self.Answers (At_Key) := Ada.Strings.Unbounded.To_Unbounded_String (Text);
         Self.Ends (At_Key) := Ended;
         Self.Has_Answer (At_Key) := True;
      end if;
   end Keep;

   -------------
   -- Changed --
   -------------

   procedure Changed (Self : in out Memory; Key : Interfaces.Unsigned_64) is
   begin
      Self.Used := 0;
      Remember (Self, Key);
   end Changed;

   ----------
   -- Note --
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
      for Index in 1 .. Self.Used loop
         if Self.Rows (Index).Named = Named and then Self.Rows (Index).Subject = Subject then
            Self.Rows (Index).Ended := Ended;
            return;
         end if;
      end loop;
      if Self.Used < Most then
         Self.Used := Self.Used + 1;
         Self.Rows (Self.Used) :=
           (Named   => To_Unbounded_String (Named),
            Subject => To_Unbounded_String (Subject),
            Kind    => Kind,
            Ended   => Ended);
      end if;
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
            when Changed => Row.Ended.Answer = Tr.Answered and then Row.Kind = Tr.Changes,
            when Read    => Row.Ended.Answer = Tr.Answered and then Row.Kind /= Tr.Changes,
            when Failing => Row.Ended.Answer = Tr.Failed,
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
            for Index in 1 .. Self.Used loop
               if Of_Section (Self.Rows (Index), Which) then
                  Append (Line,
                          (if Length (Line) = 0 then Heading (Which) else "; ")
                          & To_String (Self.Rows (Index).Named)
                          & (if Length (Self.Rows (Index).Subject) = 0 then ""
                             else " " & To_String (Self.Rows (Index).Subject))
                          & Why (Self.Rows (Index)));
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

end Model_Runner.Agent.Recall;
