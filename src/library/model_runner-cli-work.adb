with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;

with Model_Runner.CLI.Choosers;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Localization;
with Model_Runner.Text;

package body Model_Runner.CLI.Work is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package Loc renames Model_Runner.Localization;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;
   package W renames Model_Runner.Framework.Work;

   --  The tools an agent working on a task is not given: no shell, no
   --  network, no delegation, nobody to ask.
   Denied : constant array (1 .. 7) of access constant String :=
     [new String'("shell"), new String'("run_python"), new String'("http_get"),
      new String'("web_search"), new String'("sql"), new String'("delegate"),
      new String'("ask_user")];

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

   --  A model, run as this program's own agent in the project.
   type Model_Agent is new W.Agent_Runner with record
      Model   : Unbounded_String;
      Steps   : Unbounded_String;
      Timeout : Natural := 1800;
   end record;

   overriding procedure Run
     (Self        : Model_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Run
     (Self        : Model_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      Arguments : Hostkit.String_Vectors.Vector;
      Output    : constant String := Prompt_Path & ".answer";
      Happened  : Hostkit.Process.Process_Outcome;

      procedure Add (Word : String) is
      begin
         Arguments.Append (To_Unbounded_String (Word));
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
      for Tool of Denied loop
         Add ("--deny-tool");
         Add (Tool.all);
      end loop;

      Happened :=
        Hostkit.Process.Run_Captured
          (Program           => Hostkit.Fs.Own_Executable,
           Arguments         => Arguments,
           Working_Directory => Project,
           Stdin_Path        => Hostkit.Fs.Null_Device,
           Stdout_Path       => Output,
           Stderr_Path       => Hostkit.Fs.Null_Device,
           Timeout_Ms        => Self.Timeout * 1000);

      Answer := To_Unbounded_String (Whole (Output));
      if Ada.Directories.Exists (Output) then
         Ada.Directories.Delete_File (Output);
      end if;
      if not Happened.Started or else Happened.Timed_Out
        or else Happened.Exit_Status /= 0
      then
         Status := E.Make (E.Generation_Invalid_Request);
      end if;
   end Run;

   --  A command the configuration names, run through the execution
   --  policy like any other.
   type Command_Agent (Store : not null access S.Store) is new W.Agent_Runner with record
      Command : Unbounded_String;
   end record;

   overriding procedure Run
     (Self        : Command_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Run
     (Self        : Command_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      Change  : S.Transaction;
      Project_Root : constant String :=
        Ada.Directories.Containing_Directory (S.Root (Self.Store.all));
      Ran     : Model_Runner.Framework.Execution.Outcome;
      Written : constant String := To_String (Self.Command);
      Marker  : constant Natural := Ada.Strings.Fixed.Index (Written, "${prompt}");
      Command : constant String :=
        (if Marker = 0 then Written
         else Written (Written'First .. Marker - 1) & Prompt_Path
              & Written (Marker + 9 .. Written'Last));
   begin
      Model_Runner.Framework.Execution.Run
        (Self.Store.all, Change, Model_Runner.Framework.Execution.Policy_Of (Self.Store.all),
         Command, "", Ran, Status,
         Base => (if Project = Project_Root then "" else Project));
      if E.Is_Ok (Status) then
         S.Commit (Self.Store.all, Change, Status);
      end if;
      Answer := Ran.Output;
      if E.Is_Ok (Status) and then (not Ran.Started or else Ran.Exit_Status /= 0) then
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", "it ended with" & Integer'Image (Ran.Exit_Status));
      end if;
   end Run;

   --  The command, with the agent given or chosen from the configuration.
   procedure Drive
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Given_Runner : access constant W.Agent_Runner'Class;
      Status : out Natural)
   is
      Directory : constant String :=
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

      S.Open (Store, Directory, Report, Outcome);
      if E.Is_Error (Outcome) then
         Fail (Outcome);
         return;
      end if;
      Model_Runner.Framework.Configurations.Read (Store, Config, Outcome);

      --  Tasks whose agents stopped go back first, so they can be chosen.
      declare
         Recovered : Model_Runner.Framework.Name_Lists.Vector;
      begin
         W.Recover (Store, Recovered, Outcome);
         for Id of Recovered loop
            Pres.Put_Note (Screen, "cli.work.recovered", [Loc.Named ("name", Id)]);
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

      if Chosen = Null_Unbounded_String then
         if not Model_Runner.CLI.Choosers.Is_Available then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "task");
            Fail (Outcome);
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
               if Tk.Ready (Store, Id).Ready then
                  Ready.Append (Id);
               else
                  Waiting.Append (Id);
               end if;
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
                        for Reason of Now.Reasons loop
                           Append (Why, Reason & ASCII.LF);
                        end loop;
                        Model_Runner.CLI.Choosers.Append
                          (Offer,
                           (Label      => To_Unbounded_String
                                            (Id & "  " & R.Get (Defined, "title")),
                            Tag        => To_Unbounded_String
                                            (if Now.Ready then "[ready]" else "[blocked]"),
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

            declare
               Picked : constant Natural :=
                 Model_Runner.CLI.Choosers.Choose (Screen, "cli.work.choose", Offer);
            begin
               if Picked = 0 then
                  Pres.Put_Note (Screen, "cli.work.nothing");
                  Status := E.Exit_Cancelled;
                  S.Close (Store);
                  return;
               end if;
               Chosen := To_Unbounded_String (Listed (Picked));
            end;
         end;
      end if;

      loop
         declare
            Model   : constant Model_Runner.Framework.Context.Model_Profile :=
              Model_Runner.Framework.Context.Profile (Store, Setting ("profile", ""));
            Command : constant String := R.Get (Config, "scalar.work.agent");
            Path    : constant String := Setting ("model", "");
         begin
            if Given_Runner /= null then
               W.Execute
                 (Store, To_String (Chosen), Given_Runner.all, Model, Done, Outcome);
            elsif Command /= "" then
               W.Execute
                 (Store, To_String (Chosen),
                  Command_Agent'(Store => Store'Access, Command => To_Unbounded_String (Command)),
                  Model, Done, Outcome);
            elsif Path /= "" then
               W.Execute
                 (Store, To_String (Chosen),
                  Model_Agent'(Model   => To_Unbounded_String (Path),
                               Steps   => To_Unbounded_String (Setting ("steps", "")),
                               Timeout => 1800),
                  Model, Done, Outcome);
            else
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "model");
            end if;
         end;

         if E.Is_Error (Outcome) then
            Fail (Outcome);
            S.Close (Store);
            return;
         end if;

         Say ("cli.work.agent", To_String (Done.Agent_Id), To_String (Done.Task_Id));
         Say ("cli.work.context", To_String (Done.Manifest_Id), To_String (Done.Invocation_Id));
         for Path of Done.Changed_Files loop
            Say ("cli.work.changed", Path, "");
         end loop;
         for Child of Done.Children loop
            Say ("cli.work.child", Child, "");
         end loop;
         if Done.Claimed /= Null_Unbounded_String then
            Say ("cli.work.claimed", To_String (Done.Claimed), To_String (Done.Summary));
         end if;
         if Done.Evidence_Id /= Null_Unbounded_String then
            Say ("cli.work.evidence", To_String (Done.Evidence_Id), "");
         end if;
         for Requirement of Done.Requirements loop
            Say ("cli.work.requirement", Requirement, "");
         end loop;
         Say ("cli.work.ended", To_String (Done.Final_State), To_String (Done.Reason));

         exit when Remaining.Is_Empty;
         Chosen := To_Unbounded_String (Remaining.First_Element);
         Remaining.Delete_First;
      end loop;

      if To_String (Done.Final_State) /= "complete" then
         Status := E.Exit_Input_Output;
      end if;
      S.Close (Store);
   end Drive;

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural) is
   begin
      Drive (Item, Screen, null, Status);
   end Run;

   --------------
   -- Run_With --
   --------------

   procedure Run_With
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Runner : Model_Runner.Framework.Work.Agent_Runner'Class;
      Status : out Natural) is
   begin
      Drive (Item, Screen, Runner'Unchecked_Access, Status);
   end Run_With;

end Model_Runner.CLI.Work;
