with Model_Runner.CLI.Language_Server;
with Hostkit.Shell;
with Model_Runner.Processes;
with Model_Runner.Config;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Model_Runner.CLI.Choosers;
with Model_Runner.Tools.Registry;

package body Model_Runner.CLI.Tool_Turns is

   use Ada.Strings.Unbounded;
   package US renames Ada.Strings.Unbounded;
   package Pres renames Model_Runner.Presentation;

   --  A file as it was before a turn changed it.
   type Kept_File is record
      Path    : Unbounded_String;
      Existed : Boolean := False;
      Bytes   : Unbounded_String;   --  its content, byte for byte
      Turn    : Natural := 0;
   end record;

   package Kept_Files is new Ada.Containers.Indefinite_Vectors (Positive, Kept_File);

   --  What the session's turns changed, oldest first; the turn counted.
   Kept    : Kept_Files.Vector;
   Turn_At : Natural := 0;

   --  The most turns kept to undo.
   Turns_Kept : constant := 32;

   Base : Unbounded_String;

   Plan_On : Boolean := False;

   procedure Set_Planning (On : Boolean) is
   begin
      Plan_On := On;
   end Set_Planning;

   function Planning return Boolean is (Plan_On);

   function Matches (Pattern, Text : String) return Boolean is
      --  Greedy with one step back: where the last * was, and where in the
      --  text it was tried to end.
      P, X       : Natural := 0;
      Star, Mark : Natural := 0;
      Starred    : Boolean := False;
   begin
      P := Pattern'First;
      X := Text'First;
      while X <= Text'Last loop
         if P <= Pattern'Last and then Pattern (P) = '*' then
            Starred := True;
            Star := P;
            Mark := X;
            P := P + 1;
         elsif P <= Pattern'Last and then Pattern (P) = Text (X) then
            P := P + 1;
            X := X + 1;
         elsif Starred then
            P := Star + 1;
            Mark := Mark + 1;
            X := Mark;
         else
            return False;
         end if;
      end loop;
      while P <= Pattern'Last and then Pattern (P) = '*' loop
         P := P + 1;
      end loop;
      return P > Pattern'Last;
   end Matches;

   --  What a call is on, for a rule's pattern: its command, path or
   --  address as the arguments give it, else the arguments as written.
   function Subject_Of (Arguments : String) return String is
      package Doc renames Jsonlib.Documents;
      Document : Doc.Document;
      Error    : Jsonlib.Errors.Error_Info;
      use type Doc.Value_Kind;

      --  Whether the arguments give Key as a string.
      function Has (Key : String) return Boolean is
        (Doc.Has_Member (Document, Doc.Root (Document), Key)
         and then Doc.Kind (Document, Doc.Member (Document, Doc.Root (Document), Key)) = Doc.String_Value);

      function Value (Key : String) return String is
        (Doc.As_String (Document, Doc.Member (Document, Doc.Root (Document), Key)));
   begin
      Jsonlib.Parsers.Parse (Arguments, Document, Error);
      if Jsonlib.Errors.Failed (Error) or else Doc.Kind (Document, Doc.Root (Document)) /= Doc.Object_Value then
         return Arguments;
      end if;
      return (if Has ("command") then Value ("command")
              elsif Has ("path") then Value ("path")
              elsif Has ("url") then Value ("url")
              else Arguments);
   exception
      when others =>
         return Arguments;
   end Subject_Of;

   --  Whether one of a setting's rules names the call.
   function Named_By (Rules, Named, Subject : String) return Boolean is
      At_Rule : Natural := Rules'First;
   begin
      while At_Rule <= Rules'Last loop
         if Rules (At_Rule) = ' ' then
            At_Rule := At_Rule + 1;
         else
            declare
               --  To the next space outside parentheses.
               Ending : Natural := At_Rule;
               Depth  : Natural := 0;
            begin
               while Ending <= Rules'Last and then (Depth > 0 or else Rules (Ending) /= ' ') loop
                  if Rules (Ending) = '(' then
                     Depth := Depth + 1;
                  elsif Rules (Ending) = ')' and then Depth > 0 then
                     Depth := Depth - 1;
                  end if;
                  Ending := Ending + 1;
               end loop;
               declare
                  Rule  : constant String := Rules (At_Rule .. Ending - 1);
                  Open  : constant Natural := Ada.Strings.Fixed.Index (Rule, "(");
               begin
                  if Open = 0 then
                     if Matches (Rule, Named) then
                        return True;
                     end if;
                  elsif Rule (Rule'Last) = ')'
                    and then Matches (Rule (Rule'First .. Open - 1), Named)
                    and then Matches (Rule (Open + 1 .. Rule'Last - 1), Subject)
                  then
                     return True;
                  end if;
               end;
               At_Rule := Ending + 1;
            end;
         end if;
      end loop;
      return False;
   end Named_By;

   function Rule_For (Named, Arguments : String) return Rule_Answer is
      Deny  : constant String := Model_Runner.Config.Value ("tools.deny");
      Allow : constant String := Model_Runner.Config.Value ("tools.allow");
   begin
      if Deny = "" and then Allow = "" then
         return No_Rule;
      end if;
      declare
         Subject : constant String := Subject_Of (Arguments);
      begin
         if Named_By (Deny, Named, Subject) then
            return Rule_Denies;
         elsif Named_By (Allow, Named, Subject) then
            return Rule_Allows;
         end if;
      end;
      return No_Rule;
   end Rule_For;

   procedure Set_Base (Directory : String) is
   begin
      Base := To_Unbounded_String (Directory);
   end Set_Base;

   procedure Begin_Turn is
   begin
      Turn_At := Turn_At + 1;
      --  Past the turns kept, the oldest go.
      while not Kept.Is_Empty and then Kept.First_Element.Turn + Turns_Kept <= Turn_At loop
         Kept.Delete_First;
      end loop;
   end Begin_Turn;

   function Path_Of (Arguments : String) return String is
      Key : constant Natural := Ada.Strings.Fixed.Index (Arguments, """path""");
      Open, Close : Natural;
   begin
      if Key = 0 then
         return "";
      end if;
      Open := Ada.Strings.Fixed.Index (Arguments (Key + 6 .. Arguments'Last), """");
      if Open = 0 then
         return "";
      end if;
      Close := Open + 1;
      while Close <= Arguments'Last and then Arguments (Close) /= '"' loop
         if Arguments (Close) = '\' then
            Close := Close + 1;
         end if;
         Close := Close + 1;
      end loop;
      return (if Close > Arguments'Last then "" else Arguments (Open + 1 .. Close - 1));
   end Path_Of;

   procedure Before_Change (Path : String) is
      Full : constant String :=
        (if Path = "" then ""
         elsif Path (Path'First) = '/' or else Length (Base) = 0 then Ada.Directories.Full_Name (Path)
         else Ada.Directories.Full_Name (To_String (Base) & "/" & Path));
      Item : Kept_File;
   begin
      if Full = "" then
         return;
      end if;
      --  Once a turn: the file as the turn found it.
      for Each of Kept loop
         if Each.Turn = Turn_At and then To_String (Each.Path) = Full then
            return;
         end if;
      end loop;
      Item.Path := To_Unbounded_String (Full);
      Item.Turn := Turn_At;
      Item.Existed := Ada.Directories.Exists (Full)
        and then Ada.Directories."=" (Ada.Directories.Kind (Full), Ada.Directories.Ordinary_File);
      if Item.Existed then
         declare
            File   : Ada.Streams.Stream_IO.File_Type;
            Size   : constant Natural := Natural (Ada.Directories.Size (Full));
            Buffer : String (1 .. Size);
         begin
            Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Full, Form => "shared=yes");
            String'Read (Ada.Streams.Stream_IO.Stream (File), Buffer);
            Ada.Streams.Stream_IO.Close (File);
            Item.Bytes := To_Unbounded_String (Buffer);
         end;
      end if;
      Kept.Append (Item);
   exception
      when others =>
         null;
   end Before_Change;

   procedure Undo (Restored : out Ada.Strings.Unbounded.Unbounded_String) is
      Last_Turn : Natural := 0;
   begin
      Restored := Null_Unbounded_String;
      if Kept.Is_Empty then
         return;
      end if;
      Last_Turn := Kept.Last_Element.Turn;
      while not Kept.Is_Empty and then Kept.Last_Element.Turn = Last_Turn loop
         declare
            Item : constant Kept_File := Kept.Last_Element;
            Path : constant String := To_String (Item.Path);
         begin
            Kept.Delete_Last;
            begin
               if Item.Existed then
                  declare
                     File : Ada.Streams.Stream_IO.File_Type;
                  begin
                     Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
                     String'Write (Ada.Streams.Stream_IO.Stream (File), To_String (Item.Bytes));
                     Ada.Streams.Stream_IO.Close (File);
                  end;
               elsif Ada.Directories.Exists (Path) then
                  Ada.Directories.Delete_File (Path);
               end if;
               Append (Restored, Path & ASCII.LF);
            exception
               when others =>
                  null;
            end;
         end;
      end loop;
   end Undo;

   overriding procedure Explain
     (Self   : in out Conversation_Approver;
      Reason : out Ada.Strings.Unbounded.Unbounded_String) is
   begin
      Reason :=
        (if Self.Ruled
         then To_Unbounded_String
                ("not run: the user's settings (tools.deny) refuse this call -- do not try another way"
                 & " to do the same; say that it is refused, and go on with what is allowed")
         elsif Self.Planned
         then To_Unbounded_String
                ("not run: plan mode is on, and nothing is changed until the user ends it -- do not try"
                 & " another way to change it; describe the change instead, as a step of your plan,"
                 & " and answer with the plan")
         else Null_Unbounded_String);
   end Explain;

   procedure Allow_Always (Self : in out Conversation_Approver; Named : String) is
   begin
      if Ada.Strings.Fixed.Index (US.To_String (Self.Always), " " & Named & " ") = 0 then
         US.Append (Self.Always, Named & " ");
      end if;
   end Allow_Always;

   overriding function Consider
     (Self : in out Conversation_Approver; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict
   is
      package Reg renames Model_Runner.Tools.Registry;
      package Ch renames Model_Runner.CLI.Choosers;
      Items : Ch.Choice_List;
      Taken : Natural;

      function Option (Key : String) return Ch.Choice
      is ((Label      => US.To_Unbounded_String (Pres.Message_Value (Self.Screen.all, Key)),
           Tag        => US.Null_Unbounded_String,
           Details    => US.Null_Unbounded_String,
           Selectable => True));

      --  Allowed: a file it writes or edits kept first, for /undo.
      function Allowed return Model_Runner.Agent.Verdict is
      begin
         if Reg.Known (Named) and then Reg."=" (Reg.Needs (Named), Reg.Write_Files) then
            Before_Change (Path_Of (Arguments));
         end if;
         return Model_Runner.Agent.Allow;
      end Allowed;

      --  The call as it is shown: its name and arguments, cut to a line.
      Shown : constant String := Named & " " & Arguments;
      Rule  : constant Rule_Answer := Rule_For (Named, Arguments);
   begin
      --  The user's rules refuse it, whatever it is.
      if Rule = Rule_Denies then
         Self.Planned := False;
         Self.Ruled := True;
         return Model_Runner.Agent.Deny;
      end if;
      --  A helper is not asked for: each of its own calls is.
      if not Reg.Asks_First (Named) or else Named = "delegate" then
         return Model_Runner.Agent.Allow;
      end if;
      Self.Planned := False;
      Self.Ruled := False;
      --  Planning: nothing is changed, and nobody is asked.
      if Plan_On then
         Self.Planned := True;
         return Model_Runner.Agent.Deny;
      end if;
      if Rule = Rule_Allows then
         return Allowed;
      end if;
      if Ada.Strings.Fixed.Index (US.To_String (Self.Always), " " & Named & " ") > 0 then
         return Allowed;
      end if;
      --  No terminal to ask at: not run.
      if not Ch.Is_Available (Self.Screen.all) then
         return Model_Runner.Agent.Deny;
      end if;
      Ch.Append (Items, Option ("cli.agent.approve.once"));
      Ch.Append (Items, Option ("cli.agent.approve.always"));
      Ch.Append (Items, Option ("cli.agent.approve.no"));
      Ch.Append (Items, Option ("cli.agent.approve.stop"));
      Taken := Ch.Choose
        (Self.Screen.all, "cli.agent.approve.title", Items,
         Heading => Pres.Message_Value (Self.Screen.all, "cli.agent.approve.title") & " "
                    & (if Shown'Length > 200 then Shown (Shown'First .. Shown'First + 199) & "..." else Shown));
      case Taken is
         when 1 =>
            return Allowed;
         when 2 =>
            Allow_Always (Self, Named);
            return Allowed;
         when 4 =>
            return Model_Runner.Agent.Halt;
         when others =>
            return Model_Runner.Agent.Deny;
      end case;
   end Consider;

   function Run_Hook (Key, File : String; Failed : out Boolean) return String is
      Command : constant String := Model_Runner.Config.Value (Key);
      Asked   : Model_Runner.Processes.Request;
   begin
      Failed := False;
      if Command = "" then
         return "";
      end if;
      declare
         --  $FILE, each, the file's path quoted for the shell.
         Line  : Unbounded_String;
         From  : Positive := Command'First;
         At_It : Natural := Ada.Strings.Fixed.Index (Command, "$FILE");
      begin
         while At_It > 0 loop
            Append (Line, Command (From .. At_It - 1) & Hostkit.Shell.Quote (File));
            From := At_It + 5;
            At_It := Ada.Strings.Fixed.Index (Command (From .. Command'Last), "$FILE");
         end loop;
         Append (Line, Command (From .. Command'Last));
         Asked.Program := To_Unbounded_String (Hostkit.Shell.Executable);
         Asked.Arguments.Append (To_Unbounded_String (Hostkit.Shell.Command_Option));
         Asked.Arguments.Append (Line);
         Asked.Directory := (if Length (Base) > 0 then Base
                             else To_Unbounded_String (Ada.Directories.Current_Directory));
         Asked.Limit := 120.0;
      end;
      declare
         Ran : constant Model_Runner.Processes.Result := Model_Runner.Processes.Run (Asked);
      begin
         Failed := not Model_Runner.Processes.Succeeded (Ran);
         return Model_Runner.Processes.Told (Ran, Key);
      end;
   end Run_Hook;

   overriding procedure Run
     (Self      : in out Hooked_Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      package Reg renames Model_Runner.Tools.Registry;
      --  Words put after the tool's answer, as much as it has room for.
      procedure Add (Words : String) is
         Room : constant Natural := Result'Last - Last;
      begin
         if Room > 0 then
            Result (Last + 1 .. Last + Natural'Min (Room, Words'Length)) :=
              Words (Words'First .. Words'First + Natural'Min (Room, Words'Length) - 1);
            Last := Last + Natural'Min (Room, Words'Length);
         end if;
      end Add;
   begin
      Model_Runner.Tools.Builtin.Run
        (Model_Runner.Tools.Builtin.Instance (Self), Named, Arguments, Result, Last, Outcome, Status);
      if Model_Runner.Errors.Is_Ok (Status)
        and then Reg.Known (Named) and then Reg."=" (Reg.Needs (Named), Reg.Write_Files)
        and then Model_Runner.Config.Value ("hook.after-edit") /= ""
      then
         declare
            Failed : Boolean;
            Path   : constant String := Path_Of (Arguments);
            Said   : constant String :=
              Run_Hook ("hook.after-edit",
                        (if Path = "" or else Path (Path'First) = '/' or else Length (Base) = 0 then Path
                         else To_String (Base) & "/" & Path),
                        Failed);
         begin
            Add (ASCII.LF & "[the user's hook after an edit" & (if Failed then ", which failed" else "")
                 & ": " & Said & "]");
         end;
      end if;
      --  And the language server's word on the file, where one is named.
      if Model_Runner.Errors.Is_Ok (Status)
        and then Reg.Known (Named) and then Reg."=" (Reg.Needs (Named), Reg.Write_Files)
        and then Model_Runner.CLI.Language_Server.Configured
      then
         declare
            Path : constant String := Path_Of (Arguments);
            Full : constant String :=
              (if Path = "" then ""
               elsif Path (Path'First) = '/' or else Length (Base) = 0 then Ada.Directories.Full_Name (Path)
               else Ada.Directories.Full_Name (To_String (Base) & "/" & Path));
            Said : constant String :=
              (if Full = "" then "" else Model_Runner.CLI.Language_Server.Problems_In (Full));
         begin
            if Said = "(none)" then
               Add (ASCII.LF & "[the language server finds no problems in it]");
            elsif Said /= "" then
               Add (ASCII.LF & "[the language server finds these problems in it:" & ASCII.LF & Said & "]");
            end if;
         end;
      end if;
   end Run;

end Model_Runner.CLI.Tool_Turns;
