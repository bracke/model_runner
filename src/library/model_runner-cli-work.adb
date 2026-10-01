with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Fs;

with Model_Runner.CLI.Choosers;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Platform.Signals;
with Model_Runner.Text;
with Model_Runner.Tools.Builtin;

package body Model_Runner.CLI.Work is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package Loc renames Model_Runner.Localization;
   package Pm renames Model_Runner.Framework.Permissions;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;
   package W renames Model_Runner.Framework.Work;

   --  The tools an agent working on a task is not given: no shell, no
   --  network, no delegation, nobody to ask.
   --  Refused outright; a program or the network are its where its
   --  permissions grant them, which its file tools' guard holds it to.
   Denied : constant array (1 .. 4) of access constant String :=
     [new String'("sql"), new String'("delegate"), new String'("ask_user"),
      new String'("retrieve")];

   --  A whole file, or nothing when it cannot be read.
   function Whole (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;
      declare
         Text : String (1 .. Natural (Ada.Directories.Size (Path)));
      begin
         Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
         return Text;
      end;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end Whole;

   --  Why an agent's process did not end well, with the last of what it
   --  said: what a person needs to put it right.
   function Ended_Because (Started : Boolean; Code : Integer; Output : String) return String is
      Lines : Natural := 0;
      From  : Natural := Output'Last + 1;
   begin
      if not Started then
         return "the agent did not start";
      end if;
      --  Its last three lines, and no more than 400 characters of them.
      for Index in reverse Output'Range loop
         if Output (Index) = ASCII.LF and then Index < Output'Last then
            Lines := Lines + 1;
            exit when Lines = 3;
         end if;
         From := Index;
         exit when Output'Last - Index >= 400;
      end loop;
      return "the agent ended with" & Integer'Image (Code)
        & (if From > Output'Last then ""
           else ": " & Ada.Strings.Fixed.Trim (Output (From .. Output'Last), Ada.Strings.Both));
   end Ended_Because;

   --  A model, run as this program's own agent in the project.
   type Model_Agent is new W.Agent_Runner with record
      Model   : Unbounded_String;
      Steps   : Unbounded_String;
      Timeout : Natural := 1800;

      --  The context the harness budgets its prompt for, which the model
      --  is run with, so that the two are one; zero leaves it to run.
      Context : Natural := 0;

      --  Where its calls are shown once it ends: it runs apart, quietly.
      Screen  : access Model_Runner.Presentation.Console := null;
   end record;

   overriding procedure Run
     (Self        : Model_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Describe (Self : Model_Agent; Text : in out Unbounded_String);

   overriding procedure Check_Start
     (Self   : Model_Agent;
      Item   : S.Store;
      Status : in out E.Error_Info);

   overriding procedure Describe (Self : Model_Agent; Text : in out Unbounded_String) is
   begin
      Text := "the model " & Self.Model;
   end Describe;

   --  The model it names must be there to be run.
   overriding procedure Check_Start
     (Self   : Model_Agent;
      Item   : S.Store;
      Status : in out E.Error_Info)
   is
      pragma Unreferenced (Item);
      Named : constant String := To_String (Self.Model);
   begin
      --  The program it runs as is this one, started again: gone from where
      --  it was -- replaced and not yet put back -- it cannot be.
      if Hostkit.Fs.Own_Executable = "" or else not Ada.Directories.Exists (Hostkit.Fs.Own_Executable) then
         Status := E.Make (E.Framework_Agent_Failed);
         E.Add_Text (Status, "name", "the agent");
         E.Add_Text (Status, "detail", "the model_runner program this session runs was replaced or removed;"
                     & " start the session again");
      elsif not Ada.Directories.Exists (Model_Runner.Platform.Resolve_Model_Path (Named)) then
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", "model");
         E.Add_Text (Status, "value", Named);
         --  The models there are, by the names model= takes.
         declare
            Listed : Unbounded_String;
            Search : Ada.Directories.Search_Type;
            Found  : Ada.Directories.Directory_Entry_Type;
            Count  : Natural := 0;
         begin
            if Model_Runner.Platform.Models_Directory /= ""
              and then Ada.Directories.Exists (Model_Runner.Platform.Models_Directory)
            then
               Ada.Directories.Start_Search (Search, Model_Runner.Platform.Models_Directory, "*.gguf");
               while Ada.Directories.More_Entries (Search) and then Count < 8 loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                                  & Ada.Directories.Simple_Name (Found));
                  Count := Count + 1;
               end loop;
               Ada.Directories.End_Search (Search);
            end if;
            E.Add_Text (Status, "detail", "there is no such model file here or among the models"
                        & (if Listed = Null_Unbounded_String then ""
                           else " -- they are " & To_String (Listed)));
         exception
            when others =>
               E.Add_Text (Status, "detail", "there is no such model file here or among the models");
         end;
      else
         --  A model file is a GGUF one, by its first four bytes: anything
         --  else is refused before the task is touched.
         declare
            use Ada.Streams.Stream_IO;
            File  : File_Type;
            Magic : String (1 .. 4) := [others => ' '];
         begin
            Open (File, In_File, Model_Runner.Platform.Resolve_Model_Path (Named));
            if Size (File) >= 4 then
               String'Read (Stream (File), Magic);
            end if;
            Close (File);
            if Magic /= "GGUF" then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "model");
               E.Add_Text (Status, "value", Named);
               E.Add_Text (Status, "detail", "it is not a model file: a model is a .gguf file");
            end if;
         exception
            when others =>
               if Is_Open (File) then
                  Close (File);
               end if;
         end;
      end if;
   end Check_Start;

   overriding procedure Run
     (Self        : Model_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      package Pm renames Model_Runner.Framework.Permissions;
      Arguments : Model_Runner.Framework.Name_Lists.Vector;
      Output    : constant String := Prompt_Path & ".answer";
      Happened  : Model_Runner.Framework.Execution.Outcome;
      Given     : Model_Runner.Framework.Name_Lists.Vector;

      procedure Add (Word : String) is
      begin
         Arguments.Append (Word);
      end Add;
   begin
      Answer := Null_Unbounded_String;
      Status := E.Success;
      Add ("run");
      Add (To_String (Self.Model));
      Add ("--agent");
      Add ("--prompt-file");
      Add (Prompt_Path);
      Add ("--quiet");
      if Self.Steps /= Null_Unbounded_String then
         Add ("--max-steps");
         Add (To_String (Self.Steps));
      end if;
      if Self.Context > 0 then
         Add ("--context-size");
         Add (Ada.Strings.Fixed.Trim (Natural'Image (Self.Context), Ada.Strings.Both));
      end if;

      --  What it did, for the harness to account: its tokens and its calls.
      Add ("--trace-file");
      Add (Prompt_Path & ".trace");
      for Tool of Denied loop
         Add ("--deny-tool");
         Add (Tool.all);
      end loop;

      --  Held to the tree it works in and to its permissions, which its
      --  file tools read; what it may do was written beside its prompt,
      --  and none written is nothing granted.
      Given.Append (Pm.Agent_Root_Variable & "=" & Project);
      Given.Append (Pm.Agent_Permissions_Variable & "=" & Whole (Pm.Permissions_Beside (Prompt_Path)));
      Model_Runner.Framework.Execution.Run_Harness
        (Project   => Ada.Directories.Containing_Directory
                        (Ada.Directories.Containing_Directory
                           (Ada.Directories.Containing_Directory
                              (Ada.Directories.Containing_Directory (Prompt_Path)))),
         Program   => Hostkit.Fs.Own_Executable,
         Arguments => Arguments,
         Directory => Project,
         Output    => Output,
         Timeout   => Positive'Max (1, Self.Timeout),
         Result    => Happened,
         Passed    => "LANG,LC_ALL,XDG_DATA_HOME,XDG_CONFIG_HOME,XDG_CACHE_HOME,XDG_RUNTIME_DIR,"
                      & "MODEL_RUNNER_MODELS,MODEL_RUNNER_CONFIG,MODEL_RUNNER_LOCALE,"
                      & Pm.Sandbox_Variable,
         Added     => Given);

      Answer := To_Unbounded_String (Whole (Output));
      if Ada.Directories.Exists (Output) then
         Ada.Directories.Delete_File (Output);
      end if;

      --  Its trace, told to the harness in the harness's own terms.
      declare
         Trace : constant String := Whole (Prompt_Path & ".trace");

         --  The number after "KEY": in the trace, or zero.
         function Count_Of (Key : String) return String is
            At_Key : constant Natural := Ada.Strings.Fixed.Index (Trace, '"' & Key & '"' & ':');
            First  : constant Natural := At_Key + Key'Length + 3;
            Stop   : Natural := First;
         begin
            if At_Key = 0 then
               return "0";
            end if;
            while Stop <= Trace'Last and then Trace (Stop) in '0' .. '9' loop
               Stop := Stop + 1;
            end loop;
            return (if Stop = First then "0" else Trace (First .. Stop - 1));
         end Count_Of;

         Usage : Unbounded_String :=
           To_Unbounded_String ("prompt_tokens " & Count_Of ("prompt_tokens") & ASCII.LF
                                & "output_tokens " & Count_Of ("generated_tokens") & ASCII.LF);
         Mark  : constant String := "{" & '"' & "t_ms" & '"' & ":";
         Call  : constant String := '"' & "event" & '"' & ":" & '"' & "call" & '"';
         Given_Back : constant String := '"' & "event" & '"' & ":" & '"' & "result" & '"';
         From  : Natural := Trace'First;
      begin
         if Trace /= "" then
            --  Each event is one object, up to the next event's start.
            loop
               declare
                  Start : constant Natural :=
                    Ada.Strings.Fixed.Index (Trace (From .. Trace'Last), Mark);
                  Next  : Natural;
               begin
                  exit when Start = 0;
                  Next := Ada.Strings.Fixed.Index (Trace (Start + 1 .. Trace'Last), Mark);
                  declare
                     One  : constant String :=
                       Trace (Start .. (if Next = 0 then Trace'Last else Next - 2));
                     Have : Boolean;
                  begin
                     --  Each call and what it gave back, shown as a run in the
                     --  session shows them.
                     if Self.Screen /= null and then Ada.Strings.Fixed.Index (One, Call) > 0 then
                        Pres.Put_Tool_Call
                          (Self.Screen.all, Model_Runner.Tools.Builtin.Text_Argument (One, "name", Have),
                           Model_Runner.Tools.Builtin.Text_Argument (One, "arguments", Have));
                     elsif Self.Screen /= null and then Ada.Strings.Fixed.Index (One, Given_Back) > 0 then
                        Pres.Put_Tool_Result
                          (Self.Screen.all,
                           Model_Runner.Tools.Builtin.Text_Argument (One, "name", Have) & ": "
                           & Model_Runner.Tools.Builtin.Text_Argument (One, "result", Have));
                     end if;
                     if Ada.Strings.Fixed.Index (One, Call) > 0 then
                        Append (Usage, "call "
                                & Model_Runner.Tools.Builtin.Text_Argument (One, "name", Have)
                                & ASCII.HT
                                & Model_Runner.Tools.Builtin.Text_Argument (One, "arguments", Have)
                                & ASCII.LF);
                     end if;
                  end;
                  exit when Next = 0;
                  From := Next;
               end;
            end loop;
            declare
               File : Ada.Streams.Stream_IO.File_Type;
            begin
               Ada.Streams.Stream_IO.Create
                 (File, Ada.Streams.Stream_IO.Out_File, W.Usage_Beside (Prompt_Path));
               String'Write (Ada.Streams.Stream_IO.Stream (File), To_String (Usage));
               Ada.Streams.Stream_IO.Close (File);
            end;
            Ada.Directories.Delete_File (Prompt_Path & ".trace");
         end if;
      exception
         when others =>
            null;
      end;
      --  Out of time is the work's bound, as the session's agent has it --
      --  the task set aside, not failed; anything else says why, in its
      --  own words from its error stream.
      if Happened.Timed_Out then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "time");
      elsif Model_Runner.Framework.Execution.Cancel_Requested then
         Status := E.Make (E.Generation_Cancelled);
      elsif not Happened.Started or else Happened.Exit_Status /= 0 then
         Status := E.Make (E.Framework_Agent_Failed);
         E.Add_Text (Status, "name", "the agent");
         E.Add_Text (Status, "detail", Ended_Because (Happened.Started, Happened.Exit_Status,
                                                      To_String (Happened.Output)));
      end if;
   end Run;

   --  The command, with the agent given or chosen from the configuration.
   procedure Drive
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Given_Runner : access constant W.Agent_Runner'Class;
      Status : out Natural)
   is
      --  Whole: the agent runs elsewhere, and a relative path would be
      --  read from there.
      Directory : constant String :=
        Ada.Directories.Full_Name
          (if T.Is_Empty (Item.Project_Directory) then "."
           else T.To_String (Item.Project_Directory));
      Store     : aliased S.Store;
      Report    : S.Recovery_Report;
      Outcome   : E.Error_Info;
      Chosen    : Unbounded_String := To_Unbounded_String (T.To_String (Item.Action_Argument));
      Given     : Model_Runner.Framework.Configurations.Value_Maps.Map;
      Config    : R.Item;
      Done      : W.Report;
      Remaining : Model_Runner.Framework.Name_Lists.Vector;

      --  The accepted tasks a textual selector matched.
      Matching  : Model_Runner.Framework.Name_Lists.Vector;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      function Setting (Name, Default : String) return String
      is (if Given.Contains (Name) then Given (Name)
          elsif R.Get (Config, "scalar.work." & Name) /= ""
          then R.Get (Config, "scalar.work." & Name)
          else Default);

      procedure Say (Key : String; Name, Value : String) is
      begin
         Pres.Put_Message
           (Screen, Key, [Loc.Named ("name", Name), Loc.Named ("value", Value)]);
      end Say;

      --  The agent, its context and its call, said as it starts: a long
      --  run is watched knowing what is running.
      procedure Announce (Agent_Id, Manifest_Id, Invocation_Id : String) is
      begin
         Say ("cli.work.agent", Agent_Id, To_String (Chosen));
         Say ("cli.work.context", Manifest_Id, Invocation_Id);
         Ada.Text_IO.Flush;
      end Announce;

      --  What there is to do instead, where nothing was named or ready:
      --  the tasks ready now, else the candidates waiting, else how to
      --  make one.
      --  A task's title.
      function Title_Of (Id : String) return String is
         Defined : R.Item;
         Read    : E.Error_Info;
      begin
         Tk.Definition (Store, Id, Defined, Read);
         return (if E.Is_Ok (Read) then R.Get (Defined, "title") else "");
      end Title_Of;

      procedure Say_What_Is_Ready is
         Ready       : Natural := 0;
         Integrating : Natural := 0;
         Candidate : constant Natural := Natural (Tk.List (Store, "candidate").Length);
      begin
         for Id of Tk.List (Store, "accepted") loop
            if Tk.Ready (Store, Id).Ready then
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
               begin
                  Tk.Definition (Store, Id, Defined, Read);
                  Pres.Put_Note
                    (Screen, "cli.next.ready",
                     [Loc.Named ("name", Id), Loc.Named ("value", R.Get (Defined, "title"))]);
                  Ready := Ready + 1;
               end;
            end if;
         end loop;
         --  Work done and waiting on a person to take it in: said too.
         for Id of Tk.List (Store, "verification") loop
            if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
               Integrating := Integrating + 1;
               Pres.Put_Note
                 (Screen, "cli.next.waits_integration",
                  [Loc.Named ("name", Id), Loc.Named ("value", Title_Of (Id)),
                   Loc.Named ("detail",
                              (if Model_Runner.Framework.Workspaces.Conflict_Files
                                    (Store, Model_Runner.Framework.Workspaces.Active_For (Store, Id))
                                    .Is_Empty
                               then "/task integrate " & Id
                               else "it conflicts with the project; /task integrate " & Id
                                    & " resolved once settled"))]);
            end if;
         end loop;
         --  Accepted and waiting: each with what it waits on, first.
         if Ready = 0 then
            for Id of Tk.List (Store, "accepted") loop
               declare
                  Now : constant Tk.Readiness := Tk.Ready (Store, Id);
               begin
                  if not Now.Ready and then not Now.Reasons.Is_Empty then
                     Pres.Put_Note (Screen, "cli.work.waits_because",
                                    [Loc.Named ("name", Id), Loc.Named ("value", Title_Of (Id)),
                                     Loc.Named ("detail", Now.Reasons.First_Element)]);
                  end if;
               end;
            end loop;
         end if;
         if Ready = 0 and then Candidate > 0 then
            Pres.Put_Note
              (Screen, "cli.next.accept",
               [Loc.Named ("count", T.Image (Long_Long_Integer (Candidate)))]);
         elsif Ready = 0 and then Integrating = 0 then
            Pres.Put_Note (Screen, "cli.next.create");
         end if;
      end Say_What_Is_Ready;

      --  What makes a task that cannot be worked on workable, as a next
      --  step: accepting a candidate, doing or dropping what it waits for,
      --  its parts first, or trying again.

      --  A field of several lines, as one: a comma apart.
      function On_One_Line (Text : String) return String is
         Joined : Unbounded_String;
      begin
         for Line of Model_Runner.Framework.Lines_Of (Text) loop
            Append (Joined, (if Joined = Null_Unbounded_String then "" else ", ") & Line);
         end loop;
         return To_String (Joined);
      end On_One_Line;

      function Way_On (Id : String) return String is
         Defined : R.Item;
         Read    : E.Error_Info;
         State   : constant String := Tk.State_Of (Store, Id);
         Waiting : Unbounded_String;
         First   : Unbounded_String;
      begin
         Tk.Definition (Store, Id, Defined, Read);
         if State = "candidate" then
            return Pres.Next_Step_Value (Screen, "cli.next.accept_task", [Loc.Named ("name", Id)]);
         --  Ended: what takes it up again.
         elsif State in "complete" | "cancelled" then
            return Pres.Next_Step_Value (Screen, "cli.next.reopen", [Loc.Named ("name", Id)]);
         elsif State = "rejected" then
            return Pres.Next_Step_Value (Screen, "cli.next.reconsider", [Loc.Named ("name", Id)]);
         elsif State = "verification"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= ""
         then
            return Pres.Next_Step_Value (Screen, "cli.next.integrate", [Loc.Named ("name", Id)]);
         end if;
         --  Parts not done: they come first.
         --  Each part with the step it waits for, as it stands.
         for Child of Tk.Children (Store, Id) loop
            if Tk.State_Of (Store, Child) not in "complete" | "cancelled" | "rejected" then
               Append (Waiting, (if Waiting = Null_Unbounded_String then "" else "; ")
                       & (if Tk.State_Of (Store, Child) = "candidate" then "/task accept " & Child
                          elsif Tk.State_Of (Store, Child) = "verification"
                            and then Model_Runner.Framework.Workspaces.Active_For (Store, Child) /= ""
                          then "/task integrate " & Child
                          elsif Tk.State_Of (Store, Child) = "running" then Child & " is being worked"
                          elsif Tk.State_Of (Store, Child) in "blocked" | "failed"
                          then "/task accept " & Child & " (" & Tk.State_Of (Store, Child) & ")"
                          elsif Tk.Ready (Store, Child).Ready then "/work " & Child
                          else Child & " waits"));
            end if;
         end loop;
         if Waiting /= Null_Unbounded_String then
            return Pres.Next_Step_Value
              (Screen, "cli.next.parts_first", [Loc.Named ("name", Id),
                                                  Loc.Named ("detail", To_String (Waiting))]);
         end if;
         --  Set aside itself: taken up again first, whatever it waits for.
         if State in "blocked" | "failed" then
            return Pres.Next_Step_Value (Screen, "cli.next.retry", [Loc.Named ("name", Id)]);
         end if;
         --  A requirement it serves that is not accepted yet holds it back.
         for Requirement of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")) loop
            if Model_Runner.Framework.Intent.State_Of (Store, Model_Runner.Framework.Intent.Requirement, Requirement)
                 = "candidate"
            then
               return Pres.Next_Step_Value (Screen, "cli.next.req_first",
                                            [Loc.Named ("name", Id), Loc.Named ("value", Requirement)]);
            end if;
         end loop;
         --  What it waits for: done first, or no longer waited for.
         for Other of Model_Runner.Framework.Lines_Of
           (Ada.Strings.Fixed.Translate (R.Get (Defined, "depends_on"),
                                         Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
         loop
            declare
               Named : constant String := Ada.Strings.Fixed.Trim (Other, Ada.Strings.Both);
            begin
               if Named /= "" and then Tk.State_Of (Store, Named) /= "complete" then
                  First := To_Unbounded_String (Named);
                  exit;
               end if;
            end;
         end loop;
         if First /= Null_Unbounded_String
           and then Tk.State_Of (Store, To_String (First)) in "cancelled" | "rejected"
         then
            --  What it waits for has ended undone: done after all, or let go.
            return Pres.Next_Step_Value
              (Screen, "cli.task.left_waiting",
               [Loc.Named ("name", Id), Loc.Named ("value", To_String (First)),
                Loc.Named ("other", (if Tk.State_Of (Store, To_String (First)) = "rejected"
                                     then "reconsider" else "reopen"))]);
         elsif First /= Null_Unbounded_String then
            return Pres.Next_Step_Value
              (Screen, "cli.next.waits_first",
               [Loc.Named ("name", Id), Loc.Named ("value", To_String (First)),
                Loc.Named ("detail",
                           (if Tk.State_Of (Store, To_String (First)) = "candidate"
                            then "/task accept " & To_String (First)
                            else "/work " & To_String (First)))]);
         elsif State in "blocked" | "failed" then
            return Pres.Next_Step_Value (Screen, "cli.next.retry", [Loc.Named ("name", Id)]);
         end if;
         return "";
      end Way_On;
   begin
      Status := E.Exit_Success;

      for Index in 1 .. Item.Input_Count loop
         declare
            Pair : constant String := T.To_String (Item.Inputs (Index));
            Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
         begin
            if Cut > Pair'First then
               Given.Include (Pair (Pair'First .. Cut - 1), Pair (Cut + 1 .. Pair'Last));
            end if;
         end;
      end loop;

      --  What --set may name, and a sandbox that reads: said before
      --  anything is opened, not found out by an agent confined to nothing.
      for Position in Given.Iterate loop
         declare
            Name : constant String := Model_Runner.Framework.Configurations.Value_Maps.Key (Position);
         begin
            if Name not in "model" | "steps" | "profile" | "all" then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "what work takes");
               E.Add_Text (Outcome, "value", Name);
               E.Add_Text (Outcome, "detail", "work takes model=PATH, steps=N, profile=NAME"
                           & " and all=yes");
               Fail (Outcome);
               return;
            end if;
         end;
      end loop;
      if Model_Runner.Framework.Permissions.Sandbox_Problem /= "" then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "MODEL_RUNNER_SANDBOX");
         E.Add_Text (Outcome, "value", Ada.Environment_Variables.Value ("MODEL_RUNNER_SANDBOX"));
         E.Add_Text (Outcome, "detail", Model_Runner.Framework.Permissions.Sandbox_Problem);
         Fail (Outcome);
         return;
      end if;

      S.Open (Store, Directory, Report, Outcome);
      if E.Is_Error (Outcome) then
         Fail (Outcome);
         return;
      end if;
      Model_Runner.Framework.Configurations.Read (Store, Config, Outcome);

      --  What an interruption left is put right first, so a task whose
      --  agent stopped can be chosen again.
      declare
         Said : Model_Runner.Framework.Name_Lists.Vector;
      begin
         W.Recover_On_Opening (Store, Report, Said, Outcome);
         for Line of Said loop
            --  In a session, what does not hold together was said as it opened.
            if not (Pres.In_Session (Screen)
                    and then Ada.Strings.Fixed.Index (Line, "what does not hold together") = Line'First)
            then
               Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
            end if;
         end loop;
      end;

      --  Everything the plan can start, one after another: the state is
      --  one writer's, so the plan's batch runs in turn.
      if Chosen = Null_Unbounded_String and then Setting ("all", "") = "yes" then
         declare
            Planned : constant Model_Runner.Framework.Orchestration.Dispatch_Plan :=
              Model_Runner.Framework.Orchestration.Plan (Store);
         begin
            if Planned.Start.Is_Empty then
               Pres.Put_Note (Screen, "cli.work.nothing");
               Say_What_Is_Ready;
               S.Close (Store);
               return;
            end if;
            for Id of Planned.Start loop
               Chosen := To_Unbounded_String (Id);
               exit;
            end loop;
            Remaining := Planned.Start;
            Remaining.Delete_First;
         end;
      end if;

      --  A selector that is no task's identifier picks among the accepted
      --  tasks by their identifiers and titles: one match is the task, more
      --  are offered on a terminal and named elsewhere, none is an error.
      if Chosen /= Null_Unbounded_String
        and then not S.Exists (Store, Model_Runner.Framework.Tasks_Area, To_String (Chosen))
      then
         declare
            Wanted : constant String :=
              Ada.Characters.Handling.To_Lower (To_String (Chosen));
            Found  : Unbounded_String;

            --  Every task it matches, whatever its state: one that is not
            --  accepted is said as it is, not missed.
            Any_State : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Id of Tk.List (Store) loop
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
               begin
                  Tk.Definition (Store, Id, Defined, Read);
                  if Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Id), Wanted) > 0
                    or else Ada.Strings.Fixed.Index
                              (Ada.Characters.Handling.To_Lower (R.Get (Defined, "title")), Wanted) > 0
                  then
                     Any_State.Append (Id);
                  end if;
               end;
            end loop;
            for Id of Tk.List (Store, "accepted") loop
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
               begin
                  Tk.Definition (Store, Id, Defined, Read);
                  if Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Id), Wanted) > 0
                    or else Ada.Strings.Fixed.Index
                              (Ada.Characters.Handling.To_Lower (R.Get (Defined, "title")),
                               Wanted) > 0
                  then
                     Matching.Append (Id);
                     Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Id);
                  end if;
               end;
            end loop;
            if Matching.Is_Empty and then Natural (Any_State.Length) = 1 then
               --  The one task it names, not accepted: taken, to be said
               --  why it cannot be worked and what makes it workable.
               Chosen := To_Unbounded_String (Any_State.First_Element);
            elsif Matching.Is_Empty then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "a task matching " & To_String (Chosen)
                           & (if Any_State.Is_Empty then ""
                              else " that is accepted (of those it matches, none is)"));
               Fail (Outcome);
               Pres.Put_Note (Screen, "cli.next.task_list");
               S.Close (Store);
               return;
            elsif Natural (Matching.Length) = 1 then
               Chosen := To_Unbounded_String (Matching.First_Element);
               if Natural (Any_State.Length) > 1 then
                  Pres.Put_Note
                    (Screen, "cli.work.one_accepted",
                     [Loc.Named ("name", To_String (Chosen)),
                      Loc.Named ("count", T.Image (Long_Long_Integer (Natural (Any_State.Length))))]);
               end if;
            elsif not Model_Runner.CLI.Choosers.Is_Available (Screen) then
               --  Which it could be, as a value of its own for a program.
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the task to work on");
               E.Add_Text (Outcome, "value", To_String (Chosen));
               E.Add_Text (Outcome, "detail", "more than one matches: " & To_String (Found));
               E.Add_Text (Outcome, "matches", To_String (Found));
               Fail (Outcome);
               S.Close (Store);
               return;
            else
               Chosen := Null_Unbounded_String;
            end if;
         end;
      end if;

      --  Nothing named and one task ready: that one, said so.
      if Chosen = Null_Unbounded_String then
         declare
            Ready_Ones : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Id of Tk.List (Store, "accepted") loop
               if (Matching.Is_Empty or else Matching.Contains (Id)) and then Tk.Ready (Store, Id).Ready
               then
                  Ready_Ones.Append (Id);
               end if;
            end loop;
            if Natural (Ready_Ones.Length) = 1 and then Setting ("all", "") /= "yes" then
               Chosen := To_Unbounded_String (Ready_Ones.First_Element);
               Pres.Put_Note (Screen, "cli.work.only_ready", [Loc.Named ("name", To_String (Chosen))]);
            end if;
         end;
      end if;

      if Chosen = Null_Unbounded_String then
         if not Model_Runner.CLI.Choosers.Is_Available (Screen) then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "task");
            Fail (Outcome);
            Say_What_Is_Ready;
            S.Close (Store);
            return;
         end if;

         declare
            Offer   : Model_Runner.CLI.Choosers.Choice_List;
            Listed  : Model_Runner.Framework.Name_Lists.Vector;
            Ready   : Model_Runner.Framework.Name_Lists.Vector;
            Waiting : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Id of Tk.List (Store, "accepted") loop
               if not Matching.Is_Empty and then not Matching.Contains (Id) then
                  null;
               elsif Tk.Ready (Store, Id).Ready then
                  Ready.Append (Id);
               else
                  Waiting.Append (Id);
               end if;
            end loop;

            --  Blocked, failed and candidate ones are shown too, with why
            --  and what makes them workable, and not taken: where a person
            --  looks for them.
            for State of Model_Runner.Framework.Name_Lists.Vector'
                           (["blocked", "failed", "candidate", "verification"])
            loop
               for Id of Tk.List (Store, State) loop
                  if (Matching.Is_Empty or else Matching.Contains (Id))
                    and then (State /= "verification"
                              or else Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "")
                  then
                     Waiting.Append (Id);
                  end if;
               end loop;
            end loop;
            declare
               procedure Offer_All
                 (Group : Model_Runner.Framework.Name_Lists.Vector);

               procedure Offer_All
                 (Group : Model_Runner.Framework.Name_Lists.Vector) is
               begin
                  for Id of Group loop
                     declare
                        Defined : R.Item;
                        Read    : E.Error_Info;
                        Now     : constant Tk.Readiness := Tk.Ready (Store, Id);
                        Why     : Unbounded_String;
                     begin
                        Tk.Definition (Store, Id, Defined, Read);
                        --  What it is, for any row; for one not workable
                        --  yet, why and what makes it so first.
                        Append (Why, "kind " & R.Get (Defined, "kind")
                                & (if R.Get (Defined, "component") = "" then ""
                                   else ", in " & R.Get (Defined, "component"))
                                & (if R.Get (Defined, "requirements") = "" then ""
                                   else ", serving " & On_One_Line (R.Get (Defined, "requirements")))
                                & ASCII.LF);
                        if not Now.Ready then
                           Append (Why, (if Tk.State_Of (Store, Id) = "verification"
                                         then "not worked here: its work waits to be taken in"
                                         else "not workable now (" & Tk.State_Of (Store, Id) & ")")
                                   & ASCII.LF);
                        end if;
                        for Reason of Now.Reasons loop
                           Append (Why, Reason & ASCII.LF);
                        end loop;
                        if not Now.Ready and then Way_On (Id) /= "" then
                           Append (Why, Way_On (Id) & ASCII.LF);
                        end if;
                        Model_Runner.CLI.Choosers.Append
                          (Offer,
                           (Label      => To_Unbounded_String
                                            (Id & "  " & R.Get (Defined, "title")),
                            Tag        => To_Unbounded_String
                                            (if Now.Ready then "[ready]"
                                             elsif Tk.State_Of (Store, Id) = "accepted"
                                             then "[waiting]"
                                             elsif Tk.State_Of (Store, Id) = "verification"
                                             then "[to integrate]"
                                             else "[" & Tk.State_Of (Store, Id) & "]"),
                            Details    => Why,
                            Selectable => Now.Ready));
                        Listed.Append (Id);
                     end;
                  end loop;
               end Offer_All;
            begin
               Offer_All (Ready);
               Offer_All (Waiting);
            end;

            --  Nothing workable: said, with what makes something so --
            --  not a list to choose from that takes nothing.
            if Ready.Is_Empty then
               Pres.Put_Note (Screen, "cli.work.nothing_ready");
               Say_What_Is_Ready;
               Status := E.Exit_Cancelled;
               S.Close (Store);
               return;
            end if;

            declare
               Picked : constant Natural :=
                 Model_Runner.CLI.Choosers.Choose (Screen, "cli.work.choose", Offer);
            begin
               if Picked = 0 then
                  Pres.Put_Note (Screen, "cli.work.nothing");
                  if Ready.Is_Empty then
                     Say_What_Is_Ready;
                  end if;
                  Status := E.Exit_Cancelled;
                  S.Close (Store);
                  return;
               end if;
               Chosen := To_Unbounded_String (Listed (Picked));
            end;
         end;
      end if;

      loop
         --  One that cannot be worked is said so before any agent is looked
         --  for: what it waits for comes first.
         --  Its permissions leaving its agent unable are said below, with
         --  the setting that grants the rest.
         if not Tk.Ready (Store, To_String (Chosen)).Ready
           and then W.Unable_Reason (Store, To_String (Chosen)) = ""
         then
            Outcome := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Outcome, "name", To_String (Chosen));
            E.Add_Text (Outcome, "detail",
                        (if Tk.Ready (Store, To_String (Chosen)).Reasons.Is_Empty then "it is not ready"
                         else Tk.Ready (Store, To_String (Chosen)).Reasons.First_Element));
            Fail (Outcome);
            if Way_On (To_String (Chosen)) /= ""
              and then Ada.Strings.Fixed.Index (E.Text_Of (Outcome, "detail"), "task ") = 0
            then
               Pres.Put_Note (Screen, "cli.next.way_on",
                              [Loc.Named ("detail", Way_On (To_String (Chosen)))]);
            end if;
            S.Close (Store);
            return;
         end if;
         --  An agent left nothing to do its task with -- by the task's own
         --  permissions or the sandbox -- is not started to fail: said, with
         --  what gives it the rest.
         if W.Unable_Reason (Store, To_String (Chosen)) /= "" then
            Outcome := E.Make (E.Framework_Permission_Denied);
            E.Add_Text (Outcome, "name", "the agent of " & To_String (Chosen));
            E.Add_Text (Outcome, "detail", W.Unable_Reason (Store, To_String (Chosen)));
            Fail (Outcome);
            S.Close (Store);
            return;
         end if;
         declare
            --  A runner that knows its model budgets for it; otherwise the
            --  profile the configuration names.
            Model   : constant Model_Runner.Framework.Context.Model_Profile :=
              (if Given_Runner /= null and then Given_Runner.all in W.Parenting_Runner'Class
                 and then Setting ("profile", "") = "" and then Setting ("model", "") = ""
               then W.Parenting_Runner'Class (Given_Runner.all).Profile
               else Model_Runner.Framework.Context.Profile (Store, Setting ("profile", "")));
            Path    : constant String := Setting ("model", "");

            --  How long the agent may work: its task's time.
            Agent_Seconds : constant Natural := W.Time_Allowed (Store, To_String (Chosen));

            --  The setting that time is: its kind's, the agents', or the
            --  lease where neither is set.
            function Time_Source return String is
               Defined : R.Item;
               Read    : E.Error_Info;
            begin
               Tk.Definition (Store, To_String (Chosen), Defined, Read);
               declare
                  Kind : constant String := R.Get (Defined, "kind");
               begin
                  return (if Kind /= "" and then Tk.Kind_Policy (Store, Kind, "max_seconds") /= ""
                          then "task.max_seconds." & Kind
                          elsif R.Get (Config, "scalar.agents.max_seconds") /= "" then "agents.max_seconds"
                          else "work.lease, as agents.max_seconds is not set");
               end;
            end Time_Source;
         begin
            --  A model named that cannot be run is said before anything is
            --  announced for it.
            if Path /= "" then
               declare
                  Probe : constant Model_Agent :=
                    (Model => To_Unbounded_String (Path), others => <>);
                  Got   : E.Error_Info := E.Success;
               begin
                  Probe.Check_Start (Store, Got);
                  if E.Is_Error (Got) then
                     Fail (Got);
                     S.Close (Store);
                     return;
                  end if;
               end;
            end if;
            --  Which agent does the work, said before it starts: the one the
            --  project configures, wherever the work is started from.
            --  Said only for a task that can start: one that cannot is
            --  refused with why, and nothing is announced for it.
            if Tk.Ready (Store, To_String (Chosen)).Ready then
               --  In groups, as /task show is: how it starts, the run, and
               --  how it came out.
               Pres.Put_Header (Screen, "cli.work.section.start", [Loc.Named ("name", To_String (Chosen))]);
               --  An outside program an earlier version was told to run
               --  is not run: said, with how to take it out.
               if R.Get (Config, "scalar.work.agent") not in "" | "off" then
                  Pres.Put_Note (Screen, "cli.work.agent_ignored",
                                 [Loc.Named ("value", R.Get (Config, "scalar.work.agent"))]);
               end if;
               --  And how long it has, which is how a hung one ends.
               Pres.Put_Note
                 (Screen, "cli.work.time_allowed",
                  [Loc.Named ("value", T.Image (Long_Long_Integer (Agent_Seconds))
                                       & (if Agent_Seconds = 1 then " second" else " seconds")),
                   Loc.Named ("name", Time_Source)]);
               --  Confined below the project's permissions: said before it
               --  starts, not first at what it refuses.
               if Pm."/=" (Pm.Sandbox, Pm.Unrestricted) then
                  declare
                     Shown : Unbounded_String;
                  begin
                     for Line of Model_Runner.Framework.Lines_Of (Pm.Image (Pm.Sandbox)) loop
                        Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ") & Line);
                     end loop;
                     Pres.Put_Note
                       (Screen, "cli.work.sandboxed",
                        [Loc.Named ("value", (if Shown = Null_Unbounded_String then "nothing"
                                              else To_String (Shown))),
                         Loc.Named ("name", Pm.Sandbox_Source)]);
                  end;
               end if;
               --  A model named for this run is the one that runs, in a
               --  session too.
               if Path /= "" then
                  Say ("cli.work.runner", Path, To_String (Chosen));
                  --  Run apart, it has file tools only: said before it is
                  --  missed, with the run that has the rest.
                  Pres.Put_Note (Screen, "cli.work.runner_apart");
               elsif Given_Runner /= null then
                  Say ("cli.work.runner", Pres.Message_Value (Screen, "cli.work.runner.session"),
                       To_String (Chosen));
               end if;
            end if;
            if Tk.Ready (Store, To_String (Chosen)).Ready then
               Pres.Put_Section (Screen, "cli.work.section.run");
            end if;
            if Given_Runner /= null and then Path = "" then
               W.Execute
                 (Store, To_String (Chosen), Given_Runner.all, Model, Done, Outcome,
                  Starting => Announce'Access);
            elsif Path /= "" then
               W.Execute
                 (Store, To_String (Chosen),
                  Model_Agent'(Model   => To_Unbounded_String (Path),
                               Steps   => To_Unbounded_String (Setting ("steps", "")),
                               Timeout => Positive'Max
                                            (60, W.Time_Allowed (Store, To_String (Chosen))),
                               Context => Model.Context_Limit,
                               Screen  => Screen'Unchecked_Access),
                  Model, Done, Outcome, Starting => Announce'Access);
            else
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "model");
            end if;
         end;

         --  A session told to end ends once this is said: its next steps
         --  are the shell's, where they will be typed.
         if Pres.In_Session (Screen) and then Model_Runner.Platform.Signals.Ending_Asked then
            Pres.Put_Note (Screen, "cli.work.session_ending");
            Pres.Use_Session (Screen, False);
         end if;

         if E.Is_Error (Outcome) then
            Fail (Outcome);
            if E."=" (Outcome.Code, E.Framework_Input_Missing) and then E.Text_Of (Outcome, "name") = "model"
            then
               Pres.Put_Note (Screen, "cli.next.model");

            --  A task that cannot be worked on: what makes it workable,
            --  where the refusal did not say it already.
            elsif Way_On (To_String (Chosen)) /= ""
              and then Ada.Strings.Fixed.Index
                         (E.Text_Of (Outcome, "detail"),
                          Ada.Strings.Fixed.Trim (To_String (Chosen), Ada.Strings.Both) & " ") = 0
            then
               Pres.Put_Note (Screen, "cli.next.way_on", [Loc.Named ("detail", Way_On (To_String (Chosen)))]);
            end if;
            S.Close (Store);
            return;
         end if;

         Pres.Put_Section (Screen, "cli.work.section.outcome");
         --  Each as what happened to it: a file the work took away is
         --  removed, not changed.
         declare
            Tree  : Unbounded_String := To_Unbounded_String
              (Ada.Directories.Containing_Directory (S.Root (Store)));
            Place : Model_Runner.Framework.Workspaces.Workspace;
            Got   : E.Error_Info;
         begin
            if Length (Done.Workspace_Id) > 0 then
               Model_Runner.Framework.Workspaces.Read (Store, To_String (Done.Workspace_Id), Place, Got);
               if E.Is_Ok (Got) then
                  Tree := Place.Path;
               end if;
            end if;
            --  A workspace given up took its files with it: what it
            --  changed is said with where it is kept, not as removed.
            if Length (Done.Workspace_Id) = 0 or else Ada.Directories.Exists (To_String (Tree)) then
               for Path of Done.Changed_Files loop
                  Say ((if Ada.Directories.Exists (Hostkit.Fs.Join (To_String (Tree), Path))
                        then "cli.work.changed" else "cli.work.removed"), Path, "");
               end loop;
            end if;
         end;
         --  Each helper's end was said as it came, where the session ran
         --  the work; a model run apart is summed up here.
         if Given_Runner = null or else Setting ("model", "") /= "" then
            for Child of Done.Children loop
               Say ("cli.work.child", Child, "");
            end loop;
         end if;
         for Candidate of Done.Proposed loop
            Say ("cli.work.proposed", Candidate, "");
         end loop;
         for Title of Done.Twice loop
            Pres.Put_Message (Screen, "cli.work.twice", [Loc.Named ("detail", Title)]);
         end loop;
         for Line of Done.Kept_Back loop
            Pres.Put_Message
              (Screen, "cli.work.kept_back",
               [Loc.Named ("detail", Line), Loc.Named ("name", To_String (Done.Issue_Id))]);
         end loop;
         --  Issues it reported, with nothing kept back: where they are.
         if Done.Kept_Back.Is_Empty and then Done.Issue_Id /= Null_Unbounded_String then
            Pres.Put_Message
              (Screen, "cli.work.issue_kept", [Loc.Named ("name", To_String (Done.Issue_Id))]);
         end if;
         --  What it proposed waits for a person: said how.
         declare
            Waiting : Unbounded_String;
         begin
            for Candidate of Done.Proposed loop
               if Tk.State_Of (Store, Candidate) = "candidate" then
                  Append (Waiting, (if Waiting = Null_Unbounded_String then "" else ", ")
                                   & Candidate);
               end if;
            end loop;
            --  A split's parts are said by the step after it, once.
            if Waiting /= Null_Unbounded_String
              and then not (To_String (Done.Final_State) = "blocked"
                            and then Ada.Strings.Fixed.Index
                                       (To_String (Done.Reason), "waiting for its children: ") = 1)
            then
               Pres.Put_Note
                 (Screen, "cli.next.proposed", [Loc.Named ("detail", To_String (Waiting))]);
            end if;
         end;
         for Other of Done.Waits_For loop
            Say ("cli.work.waits_for", Other, To_String (Done.Task_Id));
         end loop;
         --  Its own word, unless the reason the task ends on says it
         --  already: not the same failure twice.
         if Done.Claimed /= Null_Unbounded_String
           and then not (Done.Summary /= Null_Unbounded_String
                         and then Ada.Strings.Fixed.Index (To_String (Done.Reason), To_String (Done.Summary)) > 0)
         then
            Say ("cli.work.claimed", To_String (Done.Claimed),
                 (if Done.Summary = Null_Unbounded_String then "(it gave no summary)"
                  else To_String (Done.Summary)));
         end if;
         if Done.Scope /= Null_Unbounded_String then
            Say ("cli.work.scope",
                 (if To_String (Done.Scope) = "full_suite" then "the whole suite"
                  elsif To_String (Done.Scope) = "certain_tests" then "the tests it certainly reaches"
                  elsif To_String (Done.Scope) = "component_tests" then "its component's tests"
                  else To_String (Done.Scope)),
                 To_String (Done.Scope_Reason));
         end if;
         if Done.Evidence_Id /= Null_Unbounded_String then
            Say ("cli.work.evidence", To_String (Done.Evidence_Id), "");
         end if;
         --  Whatever its end, the requirements judged again on what it
         --  left: a whole suite that failed takes verification away.
         declare
            Change : S.Transaction;
            Moved  : Model_Runner.Framework.Name_Lists.Vector;
            Judged : E.Error_Info;
         begin
            Model_Runner.Framework.Verification.Reevaluate_Requirements (Store, Change, Moved, Judged);
            if E.Is_Ok (Judged) then
               S.Commit (Store, Change, Judged);
            end if;
            if E.Is_Ok (Judged) then
               for Requirement of Moved loop
                  if not Done.Requirements.Contains (Requirement) then
                     Done.Requirements.Append (Requirement);
                  end if;
               end loop;
            end if;
         end;
         for Requirement of Done.Requirements loop
            declare
               Now : constant String :=
                 Model_Runner.Framework.Intent.State_Of (Store, Model_Runner.Framework.Intent.Requirement, Requirement);
            begin
               Pres.Put_Marked (Screen, "cli.work.requirement",
                                [Loc.Named ("name", Requirement), Loc.Named ("value", Now)],
                                Now, Pres.Tone_Of (Now));
            end;
         end loop;

         --  Complete, and what it served that is still not verified: said,
         --  with why, not left to be found.
         if To_String (Done.Final_State) = "complete" then
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
            begin
               Tk.Definition (Store, To_String (Done.Task_Id), Defined, Read);
               for Requirement of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
               loop
                  if not Done.Requirements.Contains (Requirement)
                    and then Model_Runner.Framework.Intent.State_Of
                               (Store, Model_Runner.Framework.Intent.Requirement, Requirement)
                             not in "verified" | ""
                  then
                     Pres.Put_Note
                       (Screen, "cli.work.requirement_stays",
                        [Loc.Named ("name", Requirement),
                         Loc.Named ("value", Model_Runner.Framework.Intent.State_Of
                                               (Store, Model_Runner.Framework.Intent.Requirement,
                                                Requirement)),
                         Loc.Named ("detail", Model_Runner.Framework.Verification.Why_Not_Verified
                                                (Store, Requirement))]);
                  end if;
               end loop;

               --  What its end lets go on -- a parent whose parts are done,
               --  a task that waited for it -- worked out now, and named.
               declare
                  Change : S.Transaction;
                  Became : Model_Runner.Framework.Name_Lists.Vector;
                  Moved  : E.Error_Info;
               begin
                  Tk.Recompute_Readiness (Store, Change, Became, Moved);
                  if E.Is_Ok (Moved) then
                     S.Commit (Store, Change, Moved);
                  end if;
                  for Id of Became loop
                     if Id /= R.Get (Defined, "parent") then
                        Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
                     end if;
                  end loop;
               end;
               if R.Get (Defined, "parent") /= ""
                 and then Tk.State_Of (Store, R.Get (Defined, "parent")) = "accepted"
                 and then Tk.Ready (Store, R.Get (Defined, "parent")).Ready
               then
                  Pres.Put_Note
                    (Screen, "cli.work.parent_ready", [Loc.Named ("name", R.Get (Defined, "parent"))]);
               end if;
            end;
         end if;
         --  Why, where it did not complete: blocked or failed, the reason
         --  is what a person acts on.
         --  Where it ended stands out from what led there: in the colour
         --  of how it stands.
         declare
            Final : constant String := To_String (Done.Final_State);
            Shown : constant String :=
              (if Final = "verification" then "in verification"
               elsif Final = "blocked" and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "you stopped") = 1
               then "stopped"
               else Final);
         begin
            if Done.Reason = Null_Unbounded_String then
               Pres.Put_Marked (Screen, "cli.work.ended",
                                [Loc.Named ("name", Shown), Loc.Named ("value", "")],
                                Shown, Pres.Tone_Of (Final));
            else
               --  Complete with a reservation: the reservation said as
               --  one, not as why it completed.
               Pres.Put_Marked
                 (Screen, (if Final = "failed" then "cli.work.failed_because"
                           elsif Final = "complete" then "cli.work.complete_but"
                           else "cli.work.ended_because"),
                  [Loc.Named ("name", Shown), Loc.Named ("detail", To_String (Done.Reason))],
                  Shown, (if Shown = "stopped" then Pres.Pending else Pres.Tone_Of (Final)));
            end if;
         end;

         --  And what a person does next, where it did not complete.
         if To_String (Done.Final_State) = "blocked"
           and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "waiting for its children: ") = 1
         then
            declare
               Reason : constant String := To_String (Done.Reason);
               From   : constant Positive := Reason'First + 26;
               Stop   : constant Natural := Ada.Strings.Fixed.Index (Reason, " (");
            begin
               Pres.Put_Note
                 (Screen, "cli.next.parts",
                  [Loc.Named ("detail", Ada.Strings.Fixed.Translate
                                          (Reason (From .. (if Stop = 0 then Reason'Last else Stop - 1)),
                                           Ada.Strings.Maps.To_Mapping (",", " ")))]);
            end;
         elsif To_String (Done.Final_State) in "failed" | "blocked"
           and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "files it may not write") > 0
         then
            --  A permission refused it: trying again is refused alike. The
            --  level that withheld it is the one to change.
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               Project : constant Pm.Permission_Set :=
                 Pm.Effective (Store, "", "", Within_Sandbox => False);
               Kind    : Unbounded_String;
            begin
               Tk.Definition (Store, To_String (Done.Task_Id), Defined, Read);
               Kind := To_Unbounded_String (R.Get (Defined, "kind"));
               --  The session's sandbox refused it: that is what to widen,
               --  not the project's permissions.
               if Ada.Strings.Fixed.Index (To_String (Done.Reason), "sandbox") > 0 then
                  Pres.Put_Note (Screen, "cli.next.sandbox_refused",
                                 [Loc.Named ("name", To_String (Done.Task_Id))]);
               elsif R.Get (Defined, "permissions") /= "" then
                  Pres.Put_Note (Screen, "cli.next.own_permissions_refused",
                                 [Loc.Named ("name", To_String (Done.Task_Id))]);
               --  An agent that touched the project's state is not one to
               --  be let write more.
               elsif Ada.Strings.Fixed.Index (To_String (Done.Reason), "project's state") = 0 then
                  declare
                     Level  : constant String :=
                       (if not Project (Pm.Write_Source).Granted
                          or else not Project (Pm.Write_Source).Roots.Is_Empty
                        then "project"
                        else "kind." & To_String (Kind));
                     Present : Boolean;
                     Held    : constant Pm.Permission_Set := Pm.Level_Of (Store, Level, Present);
                     Why     : constant String := To_String (Done.Reason);
                     Marks   : constant Model_Runner.Framework.Name_Lists.Vector :=
                       ["they were: ", "still there: "];
                     Roots   : Model_Runner.Framework.Name_Lists.Vector := Held (Pm.Write_Source).Roots;
                     Joined_Roots : Unbounded_String;
                  begin
                     --  The roots it has, and the directory of each file it
                     --  was refused: what to write for it to have both.
                     for Mark of Marks loop
                        declare
                           At_Mark : constant Natural := Ada.Strings.Fixed.Index (Why, Mark);
                           From    : constant Natural := At_Mark + Mark'Length;
                           Stop    : Natural := Why'Last;
                        begin
                           if At_Mark > 0 then
                              for Index in From .. Why'Last loop
                                 if Why (Index) = ';'
                                   or else (Index < Why'Last and then Why (Index .. Index + 1) = " -")
                                 then
                                    Stop := Index - 1;
                                    exit;
                                 end if;
                              end loop;
                              for File of Model_Runner.Framework.Lines_Of
                                (Ada.Strings.Fixed.Translate
                                   (Why (From .. Stop), Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                              loop
                                 declare
                                    Path  : constant String := Ada.Strings.Fixed.Trim (File, Ada.Strings.Both);
                                    Slash : constant Natural :=
                                      Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
                                    Dir   : constant String :=
                                      (if Slash = 0 then Path else Path (Path'First .. Slash));
                                 begin
                                    if Dir /= "" and then not Roots.Contains (Dir) then
                                       Roots.Append (Dir);
                                    end if;
                                 end;
                              end loop;
                           end if;
                        end;
                     end loop;
                     for Root of Roots loop
                        Append (Joined_Roots, (if Joined_Roots = Null_Unbounded_String then "" else "|") & Root);
                     end loop;
                     Pres.Put_Note
                       (Screen, "cli.next.write_refused",
                        [Loc.Named ("name", To_String (Done.Task_Id)),
                         Loc.Named ("value", Level),
                         Loc.Named ("detail", (if Joined_Roots = Null_Unbounded_String then "..."
                                               else To_String (Joined_Roots)))]);
                  end;
               end if;
            end;
         elsif To_String (Done.Final_State) in "failed" | "blocked"
           and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "on the way it was refused") > 0
         then
            --  It went round a refusal until it stopped: trying again meets
            --  the same one, so what refused it is the step before.
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               Kind    : Unbounded_String;
               Kind_Set : Boolean := False;
            begin
               Tk.Definition (Store, To_String (Done.Task_Id), Defined, Read);
               Kind := To_Unbounded_String (R.Get (Defined, "kind"));
               for Index in 1 .. R.Field_Count (Config) loop
                  Kind_Set := Kind_Set
                    or else Ada.Strings.Fixed.Index
                              (R.Field_Name (Config, Index), "map.permission.kind." & To_String (Kind) & ".") = 1;
               end loop;
               --  Which refused it decides the way on: a path outside the
               --  project no grant reaches; a narrowing is undone where it is.
               if Ada.Strings.Fixed.Index (To_String (Done.Reason), "outside the project") > 0 then
                  --  Said as what it tried: reading, or writing.
                  Pres.Put_Note (Screen, "cli.next.refused_outside",
                                 [Loc.Named ("name", To_String (Done.Task_Id)),
                                  Loc.Named ("value",
                                             (if Ada.Strings.Fixed.Index (To_String (Done.Reason), "writ") > 0
                                                or else Ada.Strings.Fixed.Index (To_String (Done.Reason), "wrote") > 0
                                              then "write" else "read"))]);
               elsif Ada.Strings.Fixed.Index (To_String (Done.Reason), "sandbox") > 0 then
                  Pres.Put_Note (Screen, "cli.next.sandbox_refused",
                                 [Loc.Named ("name", To_String (Done.Task_Id))]);
               elsif R.Get (Defined, "permissions") /= "" then
                  Pres.Put_Note (Screen, "cli.next.own_permissions_refused",
                                 [Loc.Named ("name", To_String (Done.Task_Id))]);
               elsif Kind_Set then
                  Pres.Put_Note (Screen, "cli.next.kind_refused",
                                 [Loc.Named ("name", To_String (Done.Task_Id)),
                                  Loc.Named ("value", To_String (Kind))]);
               else
                  Pres.Put_Note (Screen, "cli.next.refused_first",
                                 [Loc.Named ("name", To_String (Done.Task_Id))]);
               end if;
            end;
         elsif To_String (Done.Final_State) in "failed" | "blocked"
           and then not (for some Line of Done.Kept_Back =>
                           Ada.Strings.Fixed.Index (Line, "children") > 0
                           or else Ada.Strings.Fixed.Index (Line, "may not propose") > 0)
         then
            --  Refused for want of leave, a retry is refused alike: the way
            --  on is said below, with the level that withheld it. An agent
            --  that said it was blocked asked for something: given in the
            --  task's notes, which its next attempt is told.
            if To_String (Done.Claimed) = "blocked" then
               Pres.Put_Note (Screen, "cli.next.answer_blocked",
                              [Loc.Named ("name", To_String (Done.Task_Id))]);
            elsif Length (Done.Workspace_Id) > 0
              and then Model_Runner.Framework.Workspaces.Kept_Copies (Store).Contains
                         ("given-up-" & To_String (Done.Task_Id) & "-" & To_String (Done.Workspace_Id))
            then
               --  What this run changed is kept: putting that in is a way on
               --  too -- that copy by its name, not an earlier run's.
               Pres.Put_Note (Screen, "cli.next.retry_kept",
                              [Loc.Named ("name", To_String (Done.Task_Id)),
                               Loc.Named ("value", "given-up-" & To_String (Done.Task_Id) & "-"
                                                   & To_String (Done.Workspace_Id))]);
            else
               Pres.Put_Note (Screen, "cli.next.retry", [Loc.Named ("name", To_String (Done.Task_Id))]);
            end if;
         elsif To_String (Done.Final_State) = "cancelled" then
            Pres.Put_Note (Screen, "cli.next.reopen", [Loc.Named ("name", To_String (Done.Task_Id))]);
            --  What waits for it waits still, as a cancel here says.
            for Other of Tk.List (Store) loop
               if Tk.State_Of (Store, Other) not in "complete" | "cancelled" | "rejected" then
                  declare
                     Defined : R.Item;
                     Read    : E.Error_Info;
                  begin
                     Tk.Definition (Store, Other, Defined, Read);
                     if E.Is_Ok (Read)
                       and then (for some One of Model_Runner.Framework.Lines_Of
                                                  (Ada.Strings.Fixed.Translate
                                                     (R.Get (Defined, "depends_on"),
                                                      Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                                 => Ada.Strings.Fixed.Trim (One, Ada.Strings.Both) = To_String (Done.Task_Id))
                     then
                        Pres.Put_Note
                          (Screen, "cli.task.left_waiting",
                           [Loc.Named ("name", Other), Loc.Named ("value", To_String (Done.Task_Id)),
                            Loc.Named ("other", (if Tk.State_Of (Store, To_String (Done.Task_Id)) = "rejected"
                                                 then "reconsider" else "reopen"))]);
                     end if;
                  end;
               end if;
            end loop;
         elsif To_String (Done.Final_State) = "verification"
           and then Done.Workspace_Id /= Null_Unbounded_String
         then
            Pres.Put_Note
              (Screen, "cli.next.integrate", [Loc.Named ("name", To_String (Done.Task_Id))]);
         end if;

         --  Parts or proposals refused for want of leave, whatever else it
         --  made: trying again gives the same; a person makes them by hand,
         --  or gives the leave at the level that withheld it.
         if Done.Issue_Id /= Null_Unbounded_String
           and then (for some Line of Done.Kept_Back =>
                       Ada.Strings.Fixed.Index (Line, "children") > 0
                       or else Ada.Strings.Fixed.Index (Line, "may not propose") > 0)
         then
            declare
               Titles  : Model_Runner.Framework.Name_Lists.Vector;
               Why     : Unbounded_String;
               Defined : R.Item;
               Read    : E.Error_Info;
               Listed  : Unbounded_String;
            begin
               for Line of Done.Kept_Back loop
                  declare
                     Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
                  begin
                     if Colon > Line'First
                       and then (Ada.Strings.Fixed.Index (Line, "children") > Colon
                                 or else Ada.Strings.Fixed.Index (Line, "may not propose") > Colon)
                       and then not Titles.Contains (Line (Line'First .. Colon - 1))
                     then
                        Titles.Append (Line (Line'First .. Colon - 1));
                        if Why = Null_Unbounded_String then
                           Why := To_Unbounded_String (Line (Colon + 2 .. Line'Last));
                        end if;
                     end if;
                  end;
               end loop;
               --  One a task already is -- made as a proposal of its own --
               --  is not offered to be made again.
               declare
                  Open : Model_Runner.Framework.Name_Lists.Vector;
               begin
                  for Title of Titles loop
                     declare
                        Semicolon : constant Natural := Ada.Strings.Fixed.Index (Title, ";");
                        Bare      : constant String := Ada.Characters.Handling.To_Lower
                          (Ada.Strings.Fixed.Trim
                             ((if Semicolon = 0 then Title else Title (Title'First .. Semicolon - 1)),
                              Ada.Strings.Both));
                     begin
                        if not (for some Id of Tk.List (Store) =>
                                  Tk.State_Of (Store, Id) not in "cancelled" | "rejected"
                                  and then Ada.Characters.Handling.To_Lower (Title_Of (Id)) = Bare)
                        then
                           Open.Append (Title);
                        end if;
                     end;
                  end loop;
                  Titles := Open;
               end;
               if Titles.Is_Empty then
                  goto Refused_Said;
               end if;
               for Title of Titles loop
                  declare
                     Semicolon : constant Natural := Ada.Strings.Fixed.Index (Title, ";");
                     Bare      : constant String :=
                       (if Semicolon = 0 then Title else Title (Title'First .. Semicolon - 1));
                  begin
                     Append (Listed, (if Listed = Null_Unbounded_String then "" else "; ")
                                     & Ada.Strings.Fixed.Trim (Bare, Ada.Strings.Both));
                  end;
               end loop;
               Tk.Definition (Store, To_String (Done.Task_Id), Defined, Read);
               --  Its work done, what it would have added are tasks of their
               --  own: each made by hand as a new one, not a split of it.
               if To_String (Done.Final_State) in "complete" | "verification" then
                  for Given of Titles loop
                     --  TITLE; kind=K; component=C as the agent wrote it: its
                     --  own kind and component, else this task's kind.
                     declare
                        Parts     : Model_Runner.Framework.Name_Lists.Vector;
                        Start     : Positive := Given'First;
                        Kind      : Unbounded_String := To_Unbounded_String (R.Get (Defined, "kind"));
                        Component : Unbounded_String;
                     begin
                        for Index in Given'First .. Given'Last + 1 loop
                           if Index > Given'Last or else Given (Index) = ';' then
                              Parts.Append (Ada.Strings.Fixed.Trim (Given (Start .. Index - 1),
                                                                    Ada.Strings.Both));
                              Start := Index + 1;
                           end if;
                        end loop;
                        for Part of Parts loop
                           if Part'Length > 5 and then Part (Part'First .. Part'First + 4) = "kind=" then
                              Kind := To_Unbounded_String (Part (Part'First + 5 .. Part'Last));
                           elsif Part'Length > 10
                             and then Part (Part'First .. Part'First + 9) = "component="
                           then
                              Component := To_Unbounded_String (Part (Part'First + 10 .. Part'Last));
                           end if;
                        end loop;
                        Pres.Put_Note
                          (Screen, "cli.next.task_new_for",
                           [Loc.Named ("detail", Parts.First_Element),
                            Loc.Named ("value", To_String (Kind)
                                       & (if Component = Null_Unbounded_String then ""
                                          else " component=" & To_String (Component))),
                            Loc.Named ("name", To_String (Done.Issue_Id))]);
                     end;
                  end loop;
                  goto Refused_Said;
               end if;
               declare
                  Kind  : constant String := R.Get (Defined, "kind");
                  --  The level that withheld it, which is the one to raise:
                  --  the project's where it holds less than the kind asks.
                  Project : constant Pm.Permission_Set :=
                    Pm.Effective (Store, "", "", Within_Sandbox => False);
                  Said_Kind : Boolean;
                  Of_Kind   : constant Pm.Permission_Set := Pm.Level_Of (Store, "kind." & Kind, Said_Kind);
                  Kind_Limits : constant Boolean :=
                    Said_Kind and then Of_Kind (Pm.Create_Children).Granted
                    and then (Of_Kind (Pm.Create_Children).Max_Children
                                < Project (Pm.Create_Children).Max_Children
                              or else Of_Kind (Pm.Create_Children).Max_Depth
                                        < Project (Pm.Create_Children).Max_Depth);
                  Level : constant String :=
                    (if not Project (Pm.Create_Children).Granted or else not Kind_Limits
                     then "project" else "kind." & Kind);
                  Propose_Level : constant String :=
                    (if not Project (Pm.Propose_Tasks).Granted then "project" else "kind." & Kind);
               begin
                  Pres.Put_Note
                    (Screen, "cli.next.refused_parts",
                     [Loc.Named ("name", To_String (Done.Task_Id)),
                      Loc.Named ("value", To_String (Done.Issue_Id)),
                      Loc.Named ("detail", '"' & To_String (Listed) & '"'),
                      Loc.Named ("other",
                                 (if Pm."/=" (Pm.Sandbox, Pm.Unrestricted)
                                    and then (not Pm.Allows (Pm.Sandbox, Pm.Propose_Tasks)
                                              or else not Pm.Allows
                                                    (Pm.Sandbox,
                                                     Pm.Create_Children))
                                  then Pm.Sandbox_Source & " withholds propose_tasks or"
                                       & " create_children"
                                  elsif R.Get (Defined, "permissions") /= ""
                                  then "its own permissions limit it: /task edit "
                                       & To_String (Done.Task_Id) & " permissions=... widens them"
                                  elsif Ada.Strings.Fixed.Index (To_String (Why), "max_depth") > 0
                                    or else Ada.Strings.Fixed.Index (To_String (Why), "max_children") > 0
                                  then "/reconfigure map.permission." & Level
                                       & ".create_children=""max_depth=N max_children=N"" raises the"
                                       & " limit that stopped them"
                                  else "/reconfigure map.permission." & Propose_Level
                                       & ".propose_tasks= lets its agent propose them"
                                       & (if Propose_Level = "project" and then Said_Kind
                                            and then not Of_Kind (Pm.Propose_Tasks).Granted
                                          then ", with map.permission.kind." & Kind
                                               & ".propose_tasks= for its kind too"
                                          else "")))]);
               end;
               <<Refused_Said>>
            end;
         end if;

         exit when Remaining.Is_Empty;
         Chosen := To_Unbounded_String (Remaining.First_Element);
         Remaining.Delete_First;
      end loop;

      --  Cancelled, from here or from elsewhere, ends as a cancellation.
      if To_String (Done.Final_State) = "cancelled" then
         Status := E.Exit_Cancelled;

      --  Waiting to be taken in is where isolated work ends well; and so
      --  is a split, waiting for its parts.
      elsif To_String (Done.Final_State) /= "complete"
        and then not (To_String (Done.Final_State) = "verification"
                      and then Done.Workspace_Id /= Null_Unbounded_String)
        and then not (To_String (Done.Final_State) = "blocked"
                      and then Ada.Strings.Fixed.Index
                                 (To_String (Done.Reason), "waiting for its children: ") = 1)
      then
         Status := E.Exit_Input_Output;
      end if;
      S.Close (Store);
   end Drive;

   --------------
   -- Run_With --
   --------------

   procedure Run_With
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Runner : Model_Runner.Framework.Work.Agent_Runner'Class;
      Status : out Natural) is
   begin
      Drive (Item, Screen, Runner'Unchecked_Access, Status);
   end Run_With;

end Model_Runner.CLI.Work;
