with Hostkit.Shell;
with Model_Runner.Processes;
with Model_Runner.Config;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

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
   begin
      if not Reg.Asks_First (Named) then
         return Model_Runner.Agent.Allow;
      end if;
      --  Planning: nothing is changed, and nobody is asked.
      if Plan_On then
         return Model_Runner.Agent.Deny;
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
            Added  : constant String := ASCII.LF & "[the user's hook after an edit"
                                        & (if Failed then ", which failed" else "") & ": " & Said & "]";
            Room   : constant Natural := Result'Last - Last;
         begin
            --  As much as the answer has room for.
            if Room > 0 then
               Result (Last + 1 .. Last + Natural'Min (Room, Added'Length)) :=
                 Added (Added'First .. Added'First + Natural'Min (Room, Added'Length) - 1);
               Last := Last + Natural'Min (Room, Added'Length);
            end if;
         end;
      end if;
   end Run;

end Model_Runner.CLI.Tool_Turns;
