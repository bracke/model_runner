with Ada.Text_IO;
with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Terminal_Control;

with Model_Runner.Agent;
with Model_Runner.CLI.Choosers;
with Model_Runner.Platform.Signals;
with Model_Runner.CLI.Init;
with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Project_Requests;
with Model_Runner.CLI.Repo;
with Model_Runner.CLI.Tasks;
with Model_Runner.CLI.Work;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Framework;
with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Generation;
with Model_Runner.Localization;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tools;
with Model_Runner.Tools.Builtin;

package body Model_Runner.CLI.Project_Commands is

   --  What the last root agent's run was refused, a refusal a part.
   Refused_Last : Ada.Strings.Unbounded.Unbounded_String;

   use Ada.Strings.Unbounded;
   use type Model_Runner.Agent.Stop_Reason;
   use type Model_Runner.Conversation.Role;

   package E renames Model_Runner.Errors;
   package Conv renames Model_Runner.Conversation;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;
   package Nt renames Model_Runner.Framework.Intent;
   package Vf renames Model_Runner.Framework.Verification;
   package L renames Model_Runner.Llama;
   package Names renames Model_Runner.Framework.Name_Lists;

   --  The project is where the session was started.
   Here : constant String := ".";

   type Word_Access is access constant String;

   Words : constant array (Positive range <>) of Word_Access :=
     [new String'("/init"), new String'("/bootstrap"), new String'("/state"),
      new String'("/config"), new String'("/task"), new String'("/accept"),
      new String'("/reject"), new String'("/work"), new String'("/cancel"),
      new String'("/check"), new String'("/req"), new String'("/result"),
      new String'("/scan"), new String'("/tree"), new String'("/sym"), new String'("/refs"),
      new String'("/deps"), new String'("/users"),
      new String'("/impact"), new String'("/trace"), new String'("/reconfigure"),
      new String'("/decision"), new String'("/spec"), new String'("/git"),
      new String'("/sandbox"), new String'("/instruct")];

   --  The tools the work's agents may call; each is offered only where the
   --  agent's permissions give it.
   Allowed_Tools : constant array (1 .. 5) of Word_Access :=
     [new String'("read_file"), new String'("write_file"),
      new String'("list_directory"), new String'("delegate"),
      new String'("run_checks")];

   function Image (Value : Natural) return String
   is (T.Image (Long_Long_Integer (Value)));

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

   --  Every other tool refused, and said so.
   type Fence (Screen : not null access Pres.Console) is
     limited new Model_Runner.Agent.Approver with null record;

   overriding function Consider
     (Self : in out Fence; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict;

   overriding function Consider
     (Self : in out Fence; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict
   is
      pragma Unreferenced (Arguments);
   begin
      for Tool of Allowed_Tools loop
         if Tool.all = Named then
            return Model_Runner.Agent.Allow;
         end if;
      end loop;
      Pres.Put_Note (Self.Screen.all, "cli.agent.denied", [Loc.Named ("name", Named)]);
      return Model_Runner.Agent.Deny;
   end Consider;

   package Wk renames Model_Runner.Framework.Work;
   package Pm renames Model_Runner.Framework.Permissions;

   type Host_Access is access all Wk.Child_Host'Class;

   --  What the agent does, shown as it does it and recorded on its
   --  invocation.
   --  Generated text written as it comes, and between its pieces the work
   --  asked after: ended elsewhere -- cancelled from another terminal --
   --  the turn stops there, not at its next call.
   type Watching_Sink is limited new Pres.Standard_Output_Sink with record
      Stop : Model_Runner.Cancellation.Token_Reference := null;

      --  A line that may open a call -- {, ``` or <tool_call> -- held back
      --  from where it starts: dropped when the call is made, as the call
      --  is shown in its own line; written out when it was only text.
      Held          : Unbounded_String;
      Holding       : Boolean := False;
      At_Line_Start : Boolean := True;

      --  A helper's run: what it writes is its report, which the agent
      --  that asked reads and the screen shows as that call's answer.
      Quiet         : Boolean := False;

      --  Whether standard output shows colour: an answer's JSON coloured.
      Styled        : Boolean := False;
   end record;

   --  What was held back was a call: not written.
   procedure Drop_Held (Self : in out Watching_Sink'Class);

   --  What was held back was text: written now.
   procedure Release_Held (Self : in out Watching_Sink'Class);

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean);

   type Watch
     (Screen : not null access Pres.Console;
      Host   : Host_Access)
   is limited new Model_Runner.Agent.Observer with record
      --  Where the reply is written: told of each call, so the call's own
      --  text is not shown beside it.
      Output : access Watching_Sink := null;

      --  Whether a file was written in this run: a run that then only
      --  repeats itself has done its work and is asked for its report.
      Wrote  : Boolean := False;

      --  What its calls were refused, first one of each: said with how
      --  the work ended, as what likely kept it from going on.
      Refused : Names.Vector;

      --  The arguments of the calls asked for and not yet answered, oldest
      --  first: a reply may ask for several before any is answered.
      Asked : Names.Vector;

      --  The run's own stop, asked for when its work is ended elsewhere.
      Stop  : Model_Runner.Cancellation.Token_Reference := null;

      --  The agent the run started with, and the last answer shown: a
      --  helper's lines are marked with its identifier, and an answer the
      --  same as the one before is not written out again.
      Root  : Unbounded_String;
      Shown : Unbounded_String;

      --  The call last shown, and whether calls came several at once: a
      --  result not right after its own call is shown with the call's name.
      Last_Call : Unbounded_String;
      Batched   : Boolean := False;
   end record;

   overriding procedure On_Call
     (Self : in out Watch; Named : String; Arguments : String);

   overriding procedure On_Result
     (Self : in out Watch; Named : String; Result : String);

   --  Whose line it is: nothing for the agent the run started with, the
   --  helper's identifier for a helper's.
   function Whose (Self : in out Watch) return String is
   begin
      if Self.Host = null then
         return "";
      end if;
      declare
         Now : constant String := Wk.Current (Self.Host.all);
      begin
         if Self.Root = Null_Unbounded_String then
            Self.Root := To_Unbounded_String (Now);
         end if;
         return (if Now = To_String (Self.Root) or else Now = "" then "" else Now & " ");
      end;
   end Whose;

   overriding procedure On_Call
     (Self : in out Watch; Named : String; Arguments : String) is
      use type Model_Runner.Cancellation.Token_Reference;
   begin
      --  Its task ended elsewhere -- cancelled from another process -- the
      --  work stops rather than write on for a task that is not its.
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
      Self.Batched := Self.Batched or else not Self.Asked.Is_Empty;
      Self.Asked.Append (Arguments);
      if Self.Output /= null then
         Drop_Held (Self.Output.all);
      end if;
      Pres.Put_Tool_Call (Self.Screen.all, Whose (Self) & Named, Arguments);
      Self.Last_Call := To_Unbounded_String (Whose (Self) & Named);
   end On_Call;

   overriding procedure On_Result
     (Self : in out Watch; Named : String; Result : String) is
      Owner : constant String := Whose (Self);
      Label : constant String :=
        (if Self.Batched or else To_String (Self.Last_Call) /= Owner & Named
         then Owner & Named & ": " else Owner);
   begin
      Self.Last_Call := Null_Unbounded_String;
      if Label & Result = To_String (Self.Shown) then
         Pres.Put_Tool_Result (Self.Screen.all, Label & Pres.Message_Value (Self.Screen.all, "cli.agent.same_again"));
      else
         Pres.Put_Tool_Result (Self.Screen.all, Label & Result);
      end if;
      Self.Shown := To_Unbounded_String (Label & Result);
      if Named = "write_file" and then Result'Length > 5 and then Result (Result'First .. Result'First + 4) = "wrote"
      then
         Self.Wrote := True;
      end if;
      if Result'Length > 7 and then Result (Result'First .. Result'First + 6) = "error: "
        and then (Ada.Strings.Fixed.Index (Result, "may not") > 0
                  or else Ada.Strings.Fixed.Index (Result, "outside the project") > 0
                  or else Ada.Strings.Fixed.Index (Result, "is not a program") > 0)
        and then Natural (Self.Refused.Length) < 3
        and then not Self.Refused.Contains (Result (Result'First + 7 .. Result'Last))
      then
         Self.Refused.Append (Result (Result'First + 7 .. Result'Last));
      end if;
      if Self.Host /= null then
         Self.Host.Note_Call
           (Named, (if Self.Asked.Is_Empty then "" else Self.Asked.First_Element), Result);
      end if;
      if not Self.Asked.Is_Empty then
         Self.Asked.Delete_First;
      end if;
      if Self.Asked.Is_Empty then
         Self.Batched := False;
      end if;
   end On_Result;

   --  Whether a path is one an agent's file tools may reach: inside the
   --  project once every link is followed, and not its state.
   function Within_Project (Path : String) return Boolean
   is (Pm.Path_Refusal (".", Path, Writing => False) = "");

   --  One tool as a model reads it.
   function Tool (Name, Description, Parameters : String) return String
   is ("{""type"": ""function"", ""function"": {""name"": """ & Name
       & """, ""description"": """ & Description
       & """, ""parameters"": " & Parameters & "}}");

   function Strings (Names : String; Required : String) return String
   is ("{""type"": ""object"", ""properties"": {" & Names & "}, ""required"": ["
       & Required & "]}");

   --  The roles the project gives permissions to -- map.permission.role.R
   --  -- as the helper's role is offered: one of them, or anything, where
   --  the project names none.
   function Configured_Roles return Names.Vector is
      Store  : S.Store;
      Status : E.Error_Info;
      Config : R.Item;
      Roles  : Names.Vector;
   begin
      if S.Is_Initialized (".") then
         S.Open_To_Read (Store, ".", Status);
         if E.Is_Ok (Status) then
            Model_Runner.Framework.Configurations.Read (Store, Config, Status);
         end if;
         S.Close (Store);
      end if;
      if E.Is_Ok (Status) then
         for Index in 1 .. R.Field_Count (Config) loop
            declare
               Field : constant String := R.Field_Name (Config, Index);
               Rest  : constant String :=
                 (if Field'Length > 20 and then Field (Field'First .. Field'First + 19)
                                               = "map.permission.role."
                  then Field (Field'First + 20 .. Field'Last) else "");
               Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".");
               Role  : constant String := (if Dot = 0 then Rest else Rest (Rest'First .. Dot - 1));
            begin
               if Role /= "" and then not Roles.Contains (Role) then
                  Roles.Append (Role);
               end if;
            end;
         end loop;
      end if;
      return Roles;
   end Configured_Roles;

   function Role_Property return String is
      Roles  : constant Names.Vector := Configured_Roles;
      Listed : Unbounded_String;
   begin
      for Role of Roles loop
         Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & '"' & Role & '"');
      end loop;
      return (if Roles.Is_Empty then """role"": {""type"": ""string""}, "
              else """role"": {""type"": ""string"", ""enum"": [" & To_String (Listed) & "]}, ");
   end Role_Property;

   --  The tools an agent is offered: reading always, writing and handing
   --  work to a helper where it may.
   function Offered_Text (Host : Host_Access) return String
   is ("["
       & Tool ("read_file", "Read a text file and return its contents.",
               Strings ("""path"": {""type"": ""string""}", """path"""))
       & ", "
       & Tool ("list_directory", "List the entries of a directory.",
               Strings ("""path"": {""type"": ""string""}", """path"""))
       & (if Host /= null and then Host.May_Check (Host.Task_Profile)
          then ", "
               & Tool ("run_checks",
                       "Build and test the project as the task will be verified,"
                       & " and get back whether it passes and, if not, what the"
                       & " failing checks reported.",
                       "{""type"": ""object"", ""properties"": {}}")
          else "")
       & (if Host = null or else Host.May (Pm.Write_Source) or else Host.May (Pm.Write_Specs)
          then ", "
               & Tool ("write_file", "Write text to a file, replacing it.",
                       Strings ("""path"": {""type"": ""string""}, "
                                & """content"": {""type"": ""string""}",
                                """path"", ""content"""))
          else "")
       & (if Host /= null and then Host.May (Pm.Create_Children)
          then ", "
               & Tool ("delegate",
                       "Hand one part of the work -- a review, an investigation,"
                       & " a piece to write -- to a helper that starts with no"
                       & " memory of this conversation and reports back only its"
                       & " result. Say everything it needs in task. role names"
                       & " what it is for, and gives it that role's permissions where the"
                       & " project names the role; need is required (the default),"
                       & " optional or advisory.",
                       Strings ("""task"": {""type"": ""string""}, "
                                & Role_Property
                                & """need"": {""type"": ""string"", ""enum"": "
                                & "[""required"", ""optional"", ""advisory""]}",
                                """task"""))
          else "")
       & "]");

   --  The file tools, fenced by the permissions of the agent now working,
   --  and delegate, which makes a child through the harness and runs it.
   type Work_Tools
     (Agent : not null access constant Session_Agent;
      Host  : Host_Access)
   is new Model_Runner.Tools.Builtin.Instance with record
      --  The calls this agent has made, against its tool budget.
      Made : Natural := 0;
   end record;

   overriding procedure Run
     (Self      : in out Work_Tools;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info);

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean)
   is
      use type Model_Runner.Cancellation.Token_Reference;
      From : constant Positive := Item'First;
   begin
      Closed := False;
      if Self.Quiet then
         if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
            Self.Stop.Request;
         end if;
         return;
      end if;
      if Self.Holding then
         Append (Self.Held, Item);
      else
         for Index in Item'Range loop
            if Self.At_Line_Start and then Item (Index) in '{' | '`' | '<' then
               if Index > From then
                  Pres.Standard_Output_Sink (Self).Write (Item (From .. Index - 1), Closed);
               end if;
               Self.Holding := True;
               Self.Held := To_Unbounded_String (Item (Index .. Item'Last));
               exit;
            end if;
            Self.At_Line_Start :=
              Item (Index) = ASCII.LF or else (Self.At_Line_Start and then Item (Index) in ' ' | ASCII.HT);
         end loop;
         if not Self.Holding and then From <= Item'Last then
            Pres.Standard_Output_Sink (Self).Write (Item (From .. Item'Last), Closed);
         end if;
      end if;
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
   end Write;

   procedure Drop_Held (Self : in out Watching_Sink'Class) is
   begin
      Self.Held := Null_Unbounded_String;
      Self.Holding := False;
      Self.At_Line_Start := True;
   end Drop_Held;

   procedure Release_Held (Self : in out Watching_Sink'Class) is
      Closed : Boolean;
   begin
      if Self.Holding and then Self.Held /= Null_Unbounded_String then
         --  Ended on its own line, as a reply streamed whole would be
         --  before what the harness says next; a line said over and over
         --  -- a model gone round -- shown a few times and then counted.
         declare
            Shown   : Unbounded_String;
            Last    : Unbounded_String;
            Same     : Natural := 0;
            Skipped  : Natural := 0;
            In_Fence : Boolean := False;

            procedure Flush_Skipped is
            begin
               if Skipped > 0 then
                  Append (Shown, "... the same line" & Natural'Image (Skipped) & " times more" & ASCII.LF);
                  Skipped := 0;
               end if;
            end Flush_Skipped;
         begin
            for Raw of Model_Runner.Framework.Lines_Of (To_String (Self.Held)) loop
               declare
                  --  JSON in a fence, or an answer that is JSON whole, coloured
                  --  as JSON where colour shows.
                  Fence : constant Boolean :=
                    Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Left), "```") = 1;
                  Line  : constant String :=
                    (if not Self.Styled then Raw
                     elsif Fence then Raw
                     elsif In_Fence or else Pres.Looks_Like_JSON (To_String (Self.Held))
                     then Pres.JSON_Coloured (Raw)
                     else Raw);
               begin
                  if Fence then
                     In_Fence := not In_Fence;
                  end if;
                  if Raw = To_String (Last) then
                     Same := Same + 1;
                  else
                     Flush_Skipped;
                     Same := 0;
                     Last := To_Unbounded_String (Raw);
                  end if;
                  if Same < 3 then
                     Append (Shown, Line & ASCII.LF);
                  else
                     Skipped := Skipped + 1;
                  end if;
               end;
            end loop;
            Flush_Skipped;
            Pres.Standard_Output_Sink (Self).Write (To_String (Shown), Closed);
         end;
      end if;
      Drop_Held (Self);
   end Release_Held;

   --  One agent's loop, on the session: the root working on its task, or a
   --  child on what it was asked. A root that answers without calling a tool
   --  has changed nothing, whatever its answer says; it is told so and goes
   --  on, twice at most, before its answer is taken as it stands.
   procedure Run_Loop
     (Self   : Session_Agent;
      Prompt : String;
      Host   : Host_Access;
      Budget : Natural;
      Root   : Boolean;
      Answer : out Unbounded_String;
      Tokens : out Natural;
      Status : out Model_Runner.Errors.Error_Info;
      Prompt_Tokens : out Natural)
   is
      Messages : Conv.History;
      Offered  : Model_Runner.Tools.Definitions;
      Runner   : Work_Tools (Self'Unchecked_Access, Host);
      Guard    : aliased Fence (Self.Screen);
      Watcher  : aliased Watch (Self.Screen, Host);
      Sink     : aliased Watching_Sink :=
        (Pres.Standard_Output_Sink with Styled => Pres.Styles_Answers (Self.Screen.all), others => <>);
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;
      Request  : Model_Runner.Generation.Request;
      Outcome  : Model_Runner.Agent.Outcome;
      Calls    : Natural := 0;
      Asked_To_Report : Boolean := False;

      --  The template's own shape of call, and where that is the JSON
      --  envelope, the bare or fenced object too: models asked for a call
      --  often write it without the envelope, the 14B ones as well.
      Written  : constant Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Templates.Syntax_Of (L.Template_Format (Self.Prepared.all));
      Syntax   : constant Model_Runner.Tools.Call_Syntax :=
        (if Model_Runner.Tools."=" (Written, Model_Runner.Tools.Tool_Call_JSON)
         then Model_Runner.Tools.Open_JSON else Written);
   begin
      Answer := Null_Unbounded_String;
      Tokens := 0;
      Prompt_Tokens := 0;
      Watcher.Stop := Self.Cancel;
      Sink.Stop := Self.Cancel;
      Watcher.Output := Sink'Unchecked_Access;
      Sink.Quiet := not Root;

      Conv.Open (Messages, Status => Status);
      if E.Is_Ok (Status) then
         Conv.Append (Messages, Conv.User_Role, Prompt, Status);
      end if;
      if E.Is_Ok (Status) then
         Model_Runner.Tools.Read (Offered, Offered_Text (Host), Status);
      end if;
      if E.Is_Error (Status) then
         Conv.Close (Messages);
         return;
      end if;

      Request.Max_Tokens := Natural'Max (Self.Item.Max_Tokens, 1024);
      Request.Sampling := Self.Item.Sampling;
      Request.Seed := Self.Item.Seed;
      Request.Has_Seed := Self.Item.Has_Seed;
      Request.Batch_Size :=
        (if L.Capability (Self.Prepared.all).Supports_Batched
         then Self.Item.Batch_Size else 1);
      Request.Add_Beginning := False;
      Request.Retain_Text := True;

      for Round in 1 .. (if Root then 3 else 1) loop
         Model_Runner.Agent.Run
           (Source      => Self.Prepared.all,
            Session     => Self.Session.all,
            Messages    => Messages,
            Offered     => Offered,
            Executor    => Runner,
            Generation  => Request,
            Stop_Set    => Self.Stop_Set.all,
            Sink        => Sink'Unchecked_Access,
            Time        => Clock'Unchecked_Access,
            Seeds       => Seeds'Unchecked_Access,
            Max_Steps   => (if Root and then Host /= null then Host.Steps
                            elsif Root then 24 else 16),
            Max_Total_Tokens => Budget,
            Max_Seconds => (if Host = null then 0.0 else Host.Time_Left),
            Cancel      => Self.Cancel,
            Tool_Syntax => Syntax,
            Thinking    => Self.Item.Thinking,
            Approve     => Guard'Unchecked_Access,
            Watch       => Watcher'Unchecked_Access,
            Result      => Outcome);
         --  Held back and never a call: the reply's own text, written.
         Release_Held (Sink);
         Calls := Calls + Outcome.Calls;
         Tokens := Tokens + Outcome.Generated_Tokens;
         Prompt_Tokens := Natural'Max (Prompt_Tokens, Outcome.Prompt_Tokens);
         --  Written, then only repeating what is done: the work is there,
         --  and what is missing is its report -- asked for once, not the
         --  work failed for it.
         if Outcome.Reason = Model_Runner.Agent.Repeating and then Watcher.Wrote and then Round < 3
           and then not Asked_To_Report
         then
            Asked_To_Report := True;
            Conv.Append
              (Messages, Conv.User_Role,
               "That call was made already and its file is written; repeating it changes nothing."
               & " If the task is done, finish now with the report lines: status: done, summary:,"
               & " changed_files:.", Status);
            exit when E.Is_Error (Status);
         else
            exit when Calls > 0 or else Round = 3
              or else Outcome.Reason /= Model_Runner.Agent.Answered;
            Conv.Append
              (Messages, Conv.User_Role,
               "You have not called a tool, so no file has changed. If the task"
               & " needs a change, make it now by calling write_file, then report"
               & " again.", Status);
            exit when E.Is_Error (Status);
         end if;
      end loop;

      if Conv.Length (Messages) > 0
        and then Conv.Sender_At (Messages, Conv.Length (Messages)) = Conv.Assistant_Role
      then
         Answer := To_Unbounded_String (Conv.Content_At (Messages, Conv.Length (Messages)));
      end if;
      --  What it was refused on the way, for the outcome to say.
      if Root then
         Refused_Last := Null_Unbounded_String;
         for One of Watcher.Refused loop
            Append (Refused_Last, (if Refused_Last = Null_Unbounded_String then "" else "; ") & One);
         end loop;
      end if;
      Conv.Close (Messages);
      Model_Runner.Tools.Close (Offered);

      if Outcome.Reason = Model_Runner.Agent.Cancelled then
         --  Stopped for work ended elsewhere, not by the person: the
         --  session's own stop is not left asked for.
         if Model_Runner.Framework.Execution.Work_Withdrawn
           and then Model_Runner.Cancellation."/=" (Self.Cancel, null)
         then
            Self.Cancel.Reset;
         end if;
         Status := E.Make (E.Generation_Cancelled);
      elsif Outcome.Reason = Model_Runner.Agent.Repeating then
         --  Going round, not a request that was wrong.
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "the model");
         declare
            Met : Unbounded_String;
         begin
            for One of Watcher.Refused loop
               Append (Met, (if Met = Null_Unbounded_String then "" else "; ") & One);
            end loop;
            E.Add_Text (Status, "detail", "it kept repeating calls it had already made, and got no"
                        & " further"
                        & (if Met = Null_Unbounded_String then ""
                           else " -- on the way it was refused: " & To_String (Met)));
         end;
      elsif Outcome.Reason = Model_Runner.Agent.Timed_Out then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "time");
         E.Add_Text (Status, "detail", "the work ran out of the time it was given");
      elsif Outcome.Reason /= Model_Runner.Agent.Answered then
         if E.Is_Error (Outcome.Error) then
            Status := Outcome.Error;
         elsif Outcome.Reason in Model_Runner.Agent.Step_Limit | Model_Runner.Agent.Token_Limit then
            --  A budget spent: the limit named, with what raises it.
            Status := E.Make (E.Framework_Limit_Exceeded);
            if Outcome.Reason = Model_Runner.Agent.Token_Limit then
               E.Add_Text (Status, "name", "the agent's token budget");
               E.Add_Text (Status, "detail", "the model used all its tokens -- /config token_budget says which"
                           & " setting holds for this task (its kind's task.token_budget.KIND, else"
                           & " agents.token_budget, and a decision's ruling over either), and /reconfigure"
                           & " of that one gives it more");
            else
               E.Add_Text (Status, "name", "the agent's steps");
               E.Add_Text (Status, "detail", "the model used all its steps with a call still open -- /config"
                           & " max_steps says which setting holds for this task (its kind's task.max_steps.KIND,"
                           & " else agents.max_steps, and a decision's ruling over either), and /reconfigure"
                           & " of that one gives it more");
            end if;
         else
            --  Why the model stopped without answering, in words.
            Status := E.Make (E.Generation_Invalid_Request);
            E.Add_Text
              (Status, "field",
               (case Outcome.Reason is
                  when Model_Runner.Agent.Step_Limit =>
                     "the model used all its steps with a call still open (agents.max_steps)",
                  when Model_Runner.Agent.Token_Limit =>
                     "the model used all its tokens (agents.token_budget)",
                  when Model_Runner.Agent.Repeating =>
                     "the model made only calls it had made already, and got no further",
                  when Model_Runner.Agent.Render_Failed =>
                     "the conversation would not render in the model's template",
                  when Model_Runner.Agent.Grammar_Failed =>
                     "the tool grammar would not compile",
                  when Model_Runner.Agent.History_Failed =>
                     "a turn would not fit the context (a larger --context-size helps)",
                  when Model_Runner.Agent.Declined =>
                     "a call was declined before it ran",
                  when others =>
                     "the model stopped without answering"));
         end if;
      end if;
   end Run_Loop;

   --  What a refusal says, for the model to read.
   function Refusal (Status : E.Error_Info) return String is
      Found : Boolean;
      Given : E.Parameter;
   begin
      E.Find_Parameter (Status, "detail", Found, Given);
      return (if Found then T.To_String (Given.Text_Value)
              else E.Error_Code'Image (Status.Code));
   end Refusal;

   --  A child asked for, made by the harness, run on the session and
   --  answered for; run again when the harness says so.
   function Delegate (Self : Work_Tools; Arguments : String) return String is
      Found    : Boolean;
      Ignored  : Boolean;
      Brief    : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "task", Found);
      Role     : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "role", Ignored);
      Need     : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "need", Ignored);
      Retry_Of : Unbounded_String;
      Told     : Unbounded_String;
   begin
      if not Found or else Brief = "" then
         return "error: delegate needs a task string";
      --  A role is one the project names, where it names any; a tool's
      --  name is never one.
      elsif Role in "read_file" | "write_file" | "list_directory" | "run_checks" | "delegate" then
         return "error: " & Role & " is a tool, not a role: a role says what the helper is for, as reviewer";
      elsif Role /= "" and then not Configured_Roles.Is_Empty and then not Configured_Roles.Contains (Role) then
         declare
            Listed : Unbounded_String;
         begin
            for One of Configured_Roles loop
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
            end loop;
            return "error: " & Role & " is no role here; the roles are " & To_String (Listed);
         end;
      elsif Self.Host = null then
         return "error: no helper can be made here; do the work with the other tools";
      end if;

      --  Nothing more is started for work already cancelled.
      if Model_Runner.Framework.Execution.Work_Withdrawn then
         return "error: the work was cancelled; no helper is made";
      end if;
      loop
         declare
            Id      : Unbounded_String;
            Context : Unbounded_String;
            Budget  : Natural;
            Status  : E.Error_Info;
            Answer  : Unbounded_String;
            Tokens  : Natural;
            Prompt  : Natural;
            Ran     : E.Error_Info;
            Now     : Unbounded_String;
            Retry   : Boolean;
         begin
            Self.Host.Open_Child
              (Role, Need, Brief, To_String (Retry_Of), Id, Context, Budget, Status);
            if E.Is_Error (Status) then
               return (if Told = Null_Unbounded_String then ""
                       else To_String (Told) & ASCII.LF)
                 & "error: no helper was made: " & Refusal (Status);
            end if;
            --  Where a helper's lines begin and end, said: what it does is
            --  shown as it does it, and told apart from its parent's.
            Pres.Put_Aside (Self.Agent.Screen.all, "cli.agent.helper_starts",
                            [Loc.Named ("name", To_String (Id)),
                             Loc.Named ("value", (if Role = "" then "helper" else Role)),
                             Loc.Named ("detail", (if Brief'Length > 80
                                                   then Brief (Brief'First .. Brief'First + 76) & "..."
                                                   else Brief))]);
            Run_Loop (Self.Agent.all, To_String (Context), Self.Host, Budget,
                      Root => False, Answer => Answer, Tokens => Tokens, Status => Ran,
                      Prompt_Tokens => Prompt);

            --  The work cancelled while the helper ran: it is cancelled
            --  with it, however it came to stop.
            if Model_Runner.Framework.Execution.Work_Withdrawn
              or else Model_Runner.Framework.Execution.Cancel_Requested
            then
               Ran := E.Make (E.Generation_Cancelled);
            end if;
            Self.Host.Close_Child (To_String (Answer), Tokens, Ran, Now, Retry,
                                   Prompt_Tokens => Prompt);
            --  A run that failed and is run again is said now, before the
            --  next starts; the answer then names it, and says the last.
            if Retry then
               Pres.Put_Tool_Result (Self.Agent.Screen.all, To_String (Now));
               Told := (if Told = Null_Unbounded_String then Null_Unbounded_String else Told & ASCII.LF)
                 & To_Unbounded_String (To_String (Id) & " failed, and was run once more");
            else
               Told := (if Told = Null_Unbounded_String then Now else Told & ASCII.LF & Now);
            end if;
            exit when not Retry;
            Retry_Of := Id;
         end;
      end loop;
      return To_String (Told);
   end Delegate;

   overriding procedure Run
     (Self      : in out Work_Tools;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      procedure Put (Text : String) is
      begin
         Last := 0;
         Status := E.Success;
         if Text'Length > Result'Length then
            Status := E.Make (E.Tools_Too_Large);
            return;
         end if;
         Result (Result'First .. Result'First + Text'Length - 1) := Text;
         Last := Result'First + Text'Length - 1;
      end Put;

      Found : Boolean;
      Path  : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "path", Found);
      Budget : constant Natural :=
        (if Self.Host = null then 0 else Self.Host.Tool_Budget);

      --  Whether the agent now working may read or write there: inside the
      --  project, and within its source or specification grants.
      function May (Reading : Boolean) return Boolean
      is (Within_Project (Path)
          and then (Self.Host = null
                    or else Self.Host.May
                              ((if Reading then Pm.Read_Source else Pm.Write_Source), Path)
                    or else Self.Host.May
                              ((if Reading then Pm.Read_Specs else Pm.Write_Specs), Path)));
      --  A path written from the root -- /src/main.py -- that names a file
      --  or directory of the project once the root is taken off: the one
      --  meant, as a small model writes it.
      function Inside return String is
         Bare : Natural := Path'First;
      begin
         --  / alone, where the host's root is never the project: its top.
         if Path = "/" then
            return ".";
         elsif Path'Length < 2 or else Path (Path'First) /= '/' or else Within_Project (Path) then
            return "";
         end if;
         while Bare <= Path'Last and then Path (Bare) = '/' loop
            Bare := Bare + 1;
         end loop;
         --  Rooted where nothing on the host is: meant from the project's
         --  top, as the model was told paths are -- the longest end of it the
         --  project holds: /home/user/src/x.adb is src/x.adb where src/ is
         --  the project's, and never a home/user/ tree made inside it.
         if Ada.Directories.Exists (Path) then
            return "";
         end if;
         --  A write goes where the path says from the project's top, and
         --  nowhere a shorter end of it happens to match: a made-up
         --  /path/to/hi.py does not overwrite the project's hi.py.
         if Named = "write_file" then
            declare
               Whole  : constant String := Path (Bare .. Path'Last);
               Slash  : constant Natural := Ada.Strings.Fixed.Index (Whole, "/", Ada.Strings.Backward);
            begin
               return (if Whole /= "" and then Within_Project (Whole)
                         and then (Slash = 0 or else Ada.Directories.Exists (Whole (Whole'First .. Slash - 1)))
                       then Whole else "");
            end;
         end if;
         declare
            Start : Natural := Bare;
         begin
            loop
               declare
                  Tail   : constant String := Path (Start .. Path'Last);
                  Slash  : constant Natural := Ada.Strings.Fixed.Index (Tail, "/", Ada.Strings.Backward);
                  Folder : constant String := (if Slash = 0 then "." else Tail (Tail'First .. Slash - 1));
               begin
                  if Tail /= "" and then Within_Project (Tail)
                    and then (Ada.Directories.Exists (Tail)
                              or else (Named = "write_file" and then Ada.Directories.Exists (Folder)
                                       and then (Folder /= "." or else Start = Bare)))
                  then
                     return Tail;
                  end if;
                  Start := Ada.Strings.Fixed.Index (Tail, "/");
                  exit when Start = 0;
                  Start := Start + 1;
               end;
            end loop;
            --  Nothing of it is the project's: a new file under a new
            --  directory, as written from the top.
            return (if Named = "write_file" and then Within_Project (Path (Bare .. Path'Last))
                      and then Ada.Strings.Fixed.Count (Path (Bare .. Path'Last), "/") <= 1
                    then Path (Bare .. Path'Last) else "");
         exception
            when others =>
               return "";
         end;
      end Inside;
   begin
      --  Past the work's time, nothing more is done: the call is refused,
      --  and the run ends as out of time.
      if Self.Host /= null and then Wk.Time_Is_Up (Self.Host.all) then
         Put ("error: the work's time is up; no further call is run");
         return;
      end if;
      if Found and then Named in "read_file" | "list_directory" | "write_file" and then Inside /= "" then
         declare
            Quoted : constant String := '"' & Path & '"';
            At_Path : constant Natural := Ada.Strings.Fixed.Index (Arguments, Quoted);
         begin
            if At_Path > 0 then
               declare
                  Taken : constant String := Inside;
               begin
                  Run (Self, Named,
                       Arguments (Arguments'First .. At_Path - 1) & '"' & Taken & '"'
                       & Arguments (At_Path + Quoted'Length .. Arguments'Last),
                       Result, Last, Status);
                  --  Read from a shorter end of the path it gave: said, so
                  --  the agent knows which file it was.
                  if Named /= "write_file" and then Taken /= "." and then Last >= Result'First
                    and then Ada.Strings.Fixed.Index (Path, "/" & Taken) /= Path'First
                  then
                     declare
                        Was : constant String := Result (Result'First .. Last);
                     begin
                        Put ("(" & Path & " is taken as the project's " & Taken & ")" & ASCII.LF & Was);
                     end;
                  end if;
               end;
               return;
            end if;
         end;
      end if;
      Self.Made := Self.Made + 1;
      if Budget > 0 and then Self.Made > Budget then
         Put ("error: the budget of" & Natural'Image (Budget)
              & (if Budget = 1 then " tool call" else " tool calls") & " is spent; give your answer now");
      elsif Named = "delegate" then
         Put (Delegate (Self, Arguments));
      elsif Named = "run_checks" then
         if Self.Host = null then
            Put ("error: no checks can be run here");
         else
            declare
               Report : Unbounded_String;
               Ran    : E.Error_Info;
            begin
               Self.Host.Run_Checks (Self.Host.Task_Profile, Report, Ran);
               Put (if E.Is_Ok (Ran) then To_String (Report)
                    else "error: the checks were not run: " & Refusal (Ran));
            end;
         end if;
      elsif Named in "read_file" | "list_directory" | "write_file"
        and then Pm.Path_Refusal (".", Path, Writing => Named = "write_file") /= ""
      then
         Put ("error: " & Pm.Path_Refusal (".", Path, Writing => Named = "write_file"));
      elsif Named in "read_file" | "list_directory" and then not May (Reading => True) then
         Put ("error: you may not read " & Path
              & (if Pm.Sandbox_Refuses (Path, False) then " (" & Pm.Sandbox_Source & " confines it)" else ""));
      elsif Named = "write_file" and then not May (Reading => False) then
         Put ("error: you may not write " & Path
              & (if Pm.Sandbox_Refuses (Path, True) then " (" & Pm.Sandbox_Source & " confines it)" else "")
              & (if Self.Host = null then "" else "; you may write " & Wk.Where_Writes (Self.Host.all)));
      else
         --  What it overwrites in the project is kept as it was first.
         if Named = "write_file" and then Self.Host /= null then
            Wk.Keep_Before_Write (Self.Host.all, Path);
         end if;
         Model_Runner.Tools.Builtin.Run
           (Model_Runner.Tools.Builtin.Instance (Self), Named, Arguments, Result, Last,
            Status);
      end if;
   end Run;

   --  The root's run, with children through Host or without them.
   procedure Work_On
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Host        : Host_Access;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info)
   is
      Before : constant String := Ada.Directories.Current_Directory;
      Prompt : constant String := Whole (Prompt_Path);
      Tokens : Natural;
      Read   : Natural;
   begin
      --  The work is done where the task's files are, and its own
      --  conversation -- and each child's -- is on the session, which the
      --  screen's is read back into afterwards.
      L.Reset (Self.Session.all);
      Ada.Directories.Set_Directory (Project);
      Run_Loop (Self, Prompt, Host, (if Host = null then 0 else Host.Token_Budget), True, Answer,
                Tokens, Status, Read);
      --  Stopped at Ctrl-C, however the model's run then ended -- a closed
      --  backend among them: interrupted, and the task set aside.
      if E.Is_Error (Status)
        and then (Model_Runner.Framework.Execution.Cancel_Requested
                  or else Model_Runner.Framework.Execution.Work_Withdrawn)
      then
         Status := E.Make (E.Generation_Cancelled);
      end if;
      Ada.Directories.Set_Directory (Before);
      L.Reset (Self.Session.all);
      if Host /= null then
         Host.Spend (Tokens, Prompt_Tokens => Read);
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Before);
         L.Reset (Self.Session.all);
         Answer := Null_Unbounded_String;
         Status := E.Make (E.Internal_Unexpected_Exception);
   end Work_On;

   -------------
   -- Profile --
   -------------

   overriding function Profile
     (Self : Session_Agent) return Model_Runner.Framework.Context.Model_Profile
   is
      Path : constant String := T.To_String (Self.Item.Model_Path);
   begin
      return
        (Id             => To_Unbounded_String
                             (if Path = "" then "session"
                              else Ada.Directories.Simple_Name (Path)),
         Provider       => To_Unbounded_String ("model_runner"),
         Context_Limit  => Positive'Max (1, L.Capacity (Self.Session.all)),
         Output_Reserve => Natural'Max (Self.Item.Max_Tokens, 1024),
         Tool_Overhead  =>
           Model_Runner.Framework.Context.Estimate (Offered_Text (null)) + 64,
         Tools          => True,
         Structured     => True,
         Reasoning      => Model_Runner.Templates."=" (Self.Item.Thinking,
                                                   Model_Runner.Templates.Thinking_On),
         Streaming      => True,
         Parallel_Calls => False,
         Resource_Class => To_Unbounded_String ("local"));
   end Profile;

   package Rs renames Model_Runner.Framework.Results;

   --  An issue's text with its own identifier where it says ID: it cannot
   --  hold that itself, as it is named by what it says.
   function With_Id (Id, Summary : String) return String is
      Said : constant String := "/result dismiss ";
      Mark : constant Natural := Ada.Strings.Fixed.Index (Summary, Said & "ID");
   begin
      return (if Mark = 0 then Summary
              else Summary (Summary'First .. Mark + Said'Length - 1) & Id
                   & With_Id (Id, Summary (Mark + Said'Length + 2 .. Summary'Last)));
   end With_Id;

   --  What a person dismissed: result dismiss ID.
   function Dismissed_List (Store : S.Store) return Names.Vector is
      Kept : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "dismissed");
      Result : Names.Vector;
      File   : Ada.Text_IO.File_Type;
   begin
      if Ada.Directories.Exists (Kept) then
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Kept);
         while not Ada.Text_IO.End_Of_File (File) loop
            Result.Append (Ada.Text_IO.Get_Line (File));
         end loop;
         Ada.Text_IO.Close (File);
      end if;
      return Result;
   end Dismissed_List;

   --  The task an issue came from: named in it, or the task of the
   --  invocation it names.
   function Task_Of_Issue
     (Store : S.Store;
      One   : Model_Runner.Framework.Results.Result) return String
   is
      Text : constant String := To_String (One.Summary) & " " & To_String (One.Provenance);
      At_Task : constant Natural := Ada.Strings.Fixed.Index (Text, "TASK-");
      At_Inv  : constant Natural := Ada.Strings.Fixed.Index (Text, "INV-");
   begin
      if At_Task > 0 then
         declare
            Stop : Natural := At_Task + 5;
         begin
            while Stop <= Text'Last and then Text (Stop) in 'A' .. 'Z' | '0' .. '9' | '-' | '_' loop
               Stop := Stop + 1;
            end loop;
            return Text (At_Task .. Stop - 1);
         end;
      elsif At_Inv > 0 and then At_Inv + 9 <= Text'Last then
         declare
            Held : R.Item;
            Got  : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Invocations_Area, Text (At_Inv .. At_Inv + 9), Held, Got);
            return (if E.Is_Ok (Got) then R.Get (Held, "task") else "");
         end;
      end if;
      return "";
   end Task_Of_Issue;

   --  Whether an issue has been acted on, or no longer holds: not listed.
   function Acted_On (Store : S.Store; Issue_Id, Summary : String) return Boolean is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Summary, ": ");
      Named : constant String :=
        (if Colon > Summary'First then Summary (Summary'First .. Colon - 1) else "");
      Kind  : constant Nt.Intent_Kind :=
        (if Ada.Strings.Fixed.Index (Named, "DEC-") = Named'First then Nt.Decision
         elsif Ada.Strings.Fixed.Index (Named, "SPEC-") = Named'First then Nt.Specification
         else Nt.Requirement);
      --  An issue bootstrap raised about a line of a document
      --  -- an entry it still names, criteria before any
      --  requirement -- which the document no longer holds.
      function Document_Dropped return Boolean is
         Issue : Rs.Result;
         Got   : E.Error_Info;
      begin
         Rs.Read (Store, Issue_Id, Issue, Got);
         if E.Is_Error (Got) or else To_String (Issue.Producer) /= "bootstrap"
           or else Ada.Strings.Unbounded.Index (Issue.Provenance, "#") = 0
           or else (Ada.Strings.Fixed.Index (Summary, " still says ") = 0
                    and then Ada.Strings.Fixed.Index (Summary, ", which the project already has") = 0
                    and then Summary /= "acceptance criteria before any requirement")
         then
            return False;
         end if;
         declare
            Mark   : constant Natural := Ada.Strings.Unbounded.Index (Issue.Provenance, "#");
            Path   : constant String := Slice (Issue.Provenance, 1, Mark - 1);
            --  What it says: its identifier, or its words' first line --
            --  a SHALL line has no identifier of its own.
            Words  : constant Names.Vector :=
              Model_Runner.Framework.Lines_Of (To_String (Issue.Payload));
            Said   : constant String :=
              (if Words.Is_Empty then ""
               else Ada.Strings.Fixed.Trim (Words.First_Element, Ada.Strings.Both));
            Needle : constant String :=
              (if Ada.Strings.Fixed.Index (Summary, " still says ") > 0
                  or else Ada.Strings.Fixed.Index (Summary, ", which the project already has") > 0
               then Slice (Issue.Provenance, Mark + 1, Length (Issue.Provenance))
               else Said);
            By_Id  : constant Boolean :=
              (for some Prefix of Names.Vector'(["REQ-", "DEC-", "SPEC-"]) =>
                 Ada.Strings.Fixed.Index (Needle, Prefix) = Needle'First);
            Whole  : constant String :=
              Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), Path);
            File   : Ada.Text_IO.File_Type;
            Found  : Boolean := False;
            --  Criteria after a requirement are its own now.
            Stated : Boolean := False;
            Before : constant Boolean :=
              Summary = "acceptance criteria before any requirement";
         begin
            if Needle = "" then
               return False;
            elsif not Ada.Directories.Exists (Whole) then
               return True;
            end if;
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Whole);
            while not Found and then not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Line : constant String := Ada.Text_IO.Get_Line (File);
               begin
                  --  An entry the document names by its identifier is said
                  --  while the identifier is; one it gives by a line alone,
                  --  while that line is.
                  Found := (Ada.Strings.Fixed.Index (Line, Needle) > 0
                            or else (not Before and then Said /= "" and then not By_Id
                                     and then Ada.Strings.Fixed.Index (Line, Said) > 0))
                    and then not (Before and then Stated);
                  Stated := Stated or else Ada.Strings.Fixed.Index (Line, "REQ-") > 0;
               end;
            end loop;
            Ada.Text_IO.Close (File);
            return not Found;
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               return False;
         end;
      end Document_Dropped;
   begin
      if Ada.Strings.Fixed.Index (Summary, "output of ") = Summary'First then
         return True;
      end if;
      --  A record bootstrap did not propose, for what it says of itself:
      --  done with once the record is gone, or an entry made of it says it.
      if Ada.Strings.Fixed.Index (Summary, ", so it is not proposed: ") > 0 then
         declare
            Issue : Rs.Result;
            Got   : E.Error_Info;
         begin
            Rs.Read (Store, Issue_Id, Issue, Got);
            if E.Is_Ok (Got) and then Ada.Strings.Unbounded.Index (Issue.Provenance, "#") > 0 then
               declare
                  Whole : constant String := To_String (Issue.Provenance);
                  Mark  : constant Natural := Ada.Strings.Fixed.Index (Whole, "#");
                  Path  : constant String := Whole (Whole'First .. Mark - 1);
                  Entry_Of : constant String :=
                    (if Whole'Length > 8 and then Whole (Whole'Last - 7 .. Whole'Last) = "#retired"
                     then Whole (Whole'First .. Whole'Last - 8) else Whole);
               begin
                  if not Ada.Directories.Exists
                           (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), Path))
                    or else (for some Kind in Nt.Requirement .. Nt.Decision =>
                               Nt.Find_By_Provenance (Store, Kind, Entry_Of) /= "")
                  then
                     return True;
                  end if;
               end;
            end if;
         end;
      end if;
      --  A call's failure, or what an agent reported, on work since done:
      --  the work that followed dealt with it.
      declare
         Space : constant Natural := Ada.Strings.Fixed.Index (Summary, " ");
         Call  : constant String :=
           (if Space > Summary'First then Summary (Summary'First .. Space - 1) else "");
         Held  : R.Item;
         Got   : E.Error_Info;
      begin
         if Ada.Strings.Fixed.Index (Call, "INV-") = Call'First
           and then Ada.Strings.Fixed.Index (Summary, " failed: ") = Space
         then
            S.Read (Store, Model_Runner.Framework.Invocations_Area, Call, Held, Got);
            if E.Is_Ok (Got) and then R.Get (Held, "task") /= ""
              and then Tk.State_Of (Store, R.Get (Held, "task")) = "complete"
            then
               return True;
            end if;
         end if;
      end;
      if Document_Dropped then
         return True;
      end if;
      --  A document's words a register did not hold, which it
      --  now does.
      declare
         Mark : constant Natural := Ada.Strings.Fixed.Index (Summary, " now says what ");
      begin
         if Mark > 0 then
            declare
               Rest  : constant String := Summary (Mark + 15 .. Summary'Last);
               Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
               Entry_Id : constant String :=
                 (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
               Of_Kind : constant Nt.Intent_Kind :=
                 (if Ada.Strings.Fixed.Index (Entry_Id, "DEC-") = Entry_Id'First then Nt.Decision
                  elsif Ada.Strings.Fixed.Index (Entry_Id, "SPEC-") = Entry_Id'First
                  then Nt.Specification
                  else Nt.Requirement);
               Held   : Nt.Entity;
               Got    : E.Error_Info;
               Issue  : Rs.Result;

               --  A later issue says what the document says now:
               --  this one is behind it.
               function Overtaken return Boolean is
               begin
                  for Other_Name of S.Names (Store, Model_Runner.Framework.Results_Area)
                  loop
                     declare
                        Other_Id : constant String :=
                          (if Other_Name'Length > 4
                             and then Other_Name (Other_Name'Last - 3 .. Other_Name'Last)
                                      = ".rec"
                           then Other_Name (Other_Name'First .. Other_Name'Last - 4)
                           else Other_Name);
                        Other : Rs.Result;
                        Read  : E.Error_Info;
                     begin
                        if Other_Id /= Issue_Id then
                           Rs.Read (Store, Other_Id, Other, Read, With_Payload => False);
                           if E.Is_Ok (Read)
                             and then Ada.Strings.Fixed.Index
                                        (To_String (Other.Summary),
                                         " now says what " & Entry_Id & " ") > 0
                             and then Other.Created_At > Issue.Created_At
                           then
                              return True;
                           end if;
                        end if;
                     end;
                  end loop;
                  return False;
               end Overtaken;
            begin
               Nt.Read (Store, Of_Kind, Entry_Id, Held, Got);
               Rs.Read (Store, Issue_Id, Issue, Got);
               if E.Is_Ok (Got) and then Overtaken then
                  return True;
               end if;
               return E.Is_Ok (Got)
                 and then (To_String (Held.State) in "obsolete" | "superseded" | "rejected"
                           or else Names."="
                                     (Model_Runner.Framework.Lines_Of (To_String (Held.Text)),
                                      Model_Runner.Framework.Lines_Of
                                        (To_String (Issue.Payload))));
            end;
         end if;
      end;
      return Named /= "" and then Ada.Strings.Fixed.Index (Named, " ") = 0
        and then Nt.State_Of (Store, Kind, Named)
                   in "rejected" | "obsolete" | "superseded";
   end Acted_On;

   ---------
   -- Run --
   ---------

   overriding procedure Run
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info) is
   begin
      Work_On (Self, Prompt_Path, Project, null, Answer, Status);
   end Run;

   -------------------
   -- Run_Parenting --
   -------------------

   overriding procedure Run_Parenting
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Children    : in out Model_Runner.Framework.Work.Child_Host'Class;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info) is
   begin
      Work_On (Self, Prompt_Path, Project, Children'Unchecked_Access, Answer, Status);
   end Run_Parenting;

   ------------------
   -- Recover_Here --
   ------------------

   procedure Recover_Here (Screen : in out Model_Runner.Presentation.Console) is
      Store  : S.Store;
      Report : S.Recovery_Report;
      Status : E.Error_Info;
      Said   : Names.Vector;
   begin
      --  Started below a project's top, as git is: the project above is the
      --  one worked on, and the session moves there -- not a second one
      --  started inside it.
      if not S.Is_Initialized (Here) then
         declare
            Above : Unbounded_String :=
              To_Unbounded_String (Ada.Directories.Current_Directory);
         begin
            loop
               declare
                  Parent : constant String :=
                    Ada.Directories.Containing_Directory (To_String (Above));
               begin
                  exit when Parent = To_String (Above) or else Parent = "";
                  Above := To_Unbounded_String (Parent);
                  if S.Is_Initialized (Parent) then
                     Ada.Directories.Set_Directory (Parent);
                     Pres.Put_Note (Screen, "cli.project.found_above", [Loc.Named ("path", Parent)]);
                     exit;
                  end if;
               end;
            end loop;
         exception
            when others =>
               null;
         end;
      end if;
      if not S.Is_Initialized (Here) then
         return;
      end if;
      S.Open (Store, Here, Report, Status);
      if E.Is_Ok (Status) then
         Model_Runner.Framework.Work.Recover_On_Opening (Store, Report, Said, Status);
      elsif E."=" (Status.Code, E.Framework_Locked) then
         --  Another run holds it: nothing of this session stops, and what
         --  only looks reads it meanwhile.
         S.Open_To_Read (Store, Here, Status);
         if E.Is_Ok (Status) then
            Pres.Put_Note (Screen, "cli.project.held_at_open");
         end if;
      end if;
      if E.Is_Error (Status) then
         Pres.Report (Screen, Status);
      end if;
      for Line of Said loop
         Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
      end loop;

      --  Work finished and waiting on a person to be taken in: said as the
      --  session opens, not left for /state to find.
      if E.Is_Ok (Status) then
         declare
            Waiting : Unbounded_String;
            Count   : Natural := 0;
         begin
            for Id of Tk.List (Store, "verification") loop
               if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
                  Count := Count + 1;
                  Append (Waiting, (if Waiting = Null_Unbounded_String then "" else ", ")
                                   & "/task integrate " & Id);
               end if;
            end loop;
            if Count > 0 then
               Pres.Put_Note (Screen, "cli.project.opening_waiting",
                              [Loc.Named ("count", Image (Count)),
                               Loc.Named ("detail", To_String (Waiting))]);
            end if;
         end;
         --  Tasks set aside, and why in a word each: said as the session
         --  opens, with where the rest is.
         declare
            Stuck : Unbounded_String;
            Count : Natural := 0;

            procedure Take (State_Name : String) is
            begin
               for Id of Tk.List (Store, State_Name) loop
                  --  A parent waiting for its parts is not set aside: it
                  --  goes on once they are done.
                  if State_Name = "blocked"
                    and then (for some Part of Tk.Children (Store, Id) =>
                                Tk.State_Of (Store, Part) not in "complete" | "cancelled" | "rejected")
                  then
                     goto Next_Task;
                  end if;
                  Count := Count + 1;
                  if Count <= 5 then
                     Append (Stuck, (if Stuck = Null_Unbounded_String then "" else ", ")
                                    & Id & " " & State_Name);
                  end if;
                  <<Next_Task>>
               end loop;
            end Take;
         begin
            Take ("blocked");
            Take ("failed");
            if Count > 0 then
               Pres.Put_Note (Screen, "cli.project.opening_stuck",
                              [Loc.Named ("count", Image (Count)),
                               Loc.Named ("detail", To_String (Stuck) & (if Count > 5 then ", ..." else ""))]);
            end if;
         end;
      end if;
      S.Close (Store);
   end Recover_Here;

   ------------------------
   -- Is_Project_Command --
   ------------------------

   function Is_Project_Command (Word : String) return Boolean
   is (for some Known of Words => Known.all = Word);

   ----------
   -- Help --
   ----------

   procedure Help (Screen : in out Model_Runner.Presentation.Console) is
   begin
      --  One key each, spelled out, so the catalog's readers can be found.
      Pres.Put_Help_Line (Screen, "cli.interactive.help.init");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.bootstrap");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.state");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.config");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.git");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.sandbox");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.instruct");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.reconfigure");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.task");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.accept");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.reject");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.work");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.cancel");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.check");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.req");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.decision");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.spec");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.result");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.scan");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.tree");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.sym");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.refs");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.deps");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.users");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.impact");
      Pres.Put_Help_Line (Screen, "cli.interactive.help.trace");
   end Help;

   --  Whether a line leaves a quote open: the rest of it taken as quoted.
   Left_Open : Boolean := False;

   --  The words of a line, with a quoted stretch kept whole.
   function Split (Line : String) return Names.Vector is
      Result  : Names.Vector;
      Current : Unbounded_String;
      Quoted  : Boolean := False;
      Started : Boolean := False;
      Escape  : Boolean := False;

      --  Within single quotes, which open a word or a value after =, as a
      --  shell has them: every character is itself, double quotes too. An
      --  apostrophe inside a word is only an apostrophe, and so is one
      --  inside the quotes that a letter follows: the program's name.
      Single  : Boolean := False;

      --  Whether the quotes of the word being read are kept: words of a
      --  value, not the quoting of a whole one.
      Kept_Quote : Boolean := False;
   begin
      for Index in Line'Range loop
         declare
            Char : constant Character := Line (Index);
         begin
            if Single then
               if Char = ''' and then (Index = Line'Last or else Line (Index + 1) in ' ' | ASCII.HT) then
                  Single := False;
                  --  Quoted words inside a field's value are its words,
                  --  quotes and all: returns 'Hello' keeps them.
                  if Kept_Quote then
                     Append (Current, Char);
                     Kept_Quote := False;
                  end if;
               else
                  Append (Current, Char);
               end if;
               Started := True;
            elsif Char = ''' and then not Quoted and then not Escape
              and then (not Started
                        or else (Length (Current) > 0 and then Element (Current, Length (Current)) = '='))
            then
               Single := True;
               --  A word of a value after NAME= went before: its quotes kept.
               Kept_Quote := not Started
                 and then (for some Word of Result =>
                             Ada.Strings.Fixed.Index (Word, "=") > 1 and then Word (Word'First) /= '-');
               if Kept_Quote then
                  Append (Current, Char);
               end if;
               Started := True;

            --  A quote or a backslash after a backslash is itself.
            elsif Escape then
               if Char not in '"' | '\' | ''' then
                  Append (Current, '\');
               end if;
               Append (Current, Char);
               Started := True;
               Escape := False;
            elsif Char = '\' then
               Escape := True;
            elsif Char = '"' then
               Quoted := not Quoted;
               Started := True;
            elsif Char in ' ' | ASCII.HT and then not Quoted then
               if Started then
                  Result.Append (To_String (Current));
                  Current := Null_Unbounded_String;
                  Started := False;
               end if;
            else
               Append (Current, Char);
               Started := True;
            end if;
         end;
      end loop;
      if Escape then
         Append (Current, '\');
         Started := True;
      end if;
      if Started then
         Result.Append (To_String (Current));
      end if;
      Left_Open := Quoted or else Single;
      return Result;
   end Split;

   --  Whether a word gives an input or a field, as NAME=VALUE.
   function Is_Setting (Word : String) return Boolean is
      Equal : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
   begin
      return Equal > Word'First
        and then (for all C of Word (Word'First .. Equal - 1) =>
                    C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '+' | '-');
   end Is_Setting;

   --  The words of a line with each identifier as the project keeps it:
   --  task-8, TASK-8 and -- where a task is what is named -- 8 alone are
   --  TASK-008; req-1 is REQ-001; REQ-CALC-3 is REQ-CALC-003.
   --  A yes or no read from the person: anything else asked again, a
   --  command typed in its place said and not run, and no answer a no.
   function Answered_Yes (Screen : in out Pres.Console) return Boolean is
   begin
      return Model_Runner.CLI.Choosers.Answered_Yes (Screen);
   end Answered_Yes;

   --  A number typed that names two entries -- REQ-001 and a document's
   --  own REQ-1 -- found while the words were read: said, not guessed.
   Number_Ambiguity : Unbounded_String;

   function Identifiers_As_Kept (Words : Names.Vector) return Names.Vector is
      Result : Names.Vector;

      function Padded (Number : String) return String
      is (if Number'Length >= 3 then Number else [1 .. 3 - Number'Length => '0'] & Number);

      function All_Digits (Text : String) return Boolean
      is (Text'Length in 1 .. 6 and then (for all C of Text => C in '0' .. '9'));

      --  The project's state directory, here or above; "" outside one.
      function State_Directory return String is
         Here : Unbounded_String := To_Unbounded_String (Ada.Directories.Current_Directory);
      begin
         for Ignored in 1 .. 64 loop
            if Ada.Directories.Exists (To_String (Here) & "/.model_runner") then
               return To_String (Here) & "/.model_runner";
            end if;
            declare
               Up : constant String := Ada.Directories.Containing_Directory (To_String (Here));
            begin
               exit when Up = To_String (Here);
               Here := To_Unbounded_String (Up);
            end;
         end loop;
         return "";
      exception
         when others =>
            return "";
      end State_Directory;

      State : constant String := State_Directory;

      --  Whether the project holds an item under this identifier as written.
      function Held_As (Id : String) return Boolean is
         Area : constant String :=
           (if Id'Length > 4 and then Id (Id'First .. Id'First + 3) = "REQ-" then "requirements"
            elsif Id'Length > 4 and then Id (Id'First .. Id'First + 3) = "DEC-" then "decisions"
            elsif Id'Length > 5 and then Id (Id'First .. Id'First + 4) = "SPEC-" then "specs"
            elsif Id'Length > 5 and then Id (Id'First .. Id'First + 4) = "TASK-" then "tasks"
            else "");
      begin
         return State /= "" and then Area /= ""
           and then Ada.Directories.Exists (State & "/" & Area & "/" & Id & ".rec");
      end Held_As;

      --  The entry a document's own label was read into: a requirement or
      --  a decision whose provenance ends #LABEL; "" for none.
      function Labelled (Label : String) return String is
         Mark   : constant String := "#" & Label;
         Search : Ada.Directories.Search_Type;
         Found  : Ada.Directories.Directory_Entry_Type;
      begin
         if State = "" then
            return "";
         end if;
         for Area of Names.Vector'(["requirements", "decisions"]) loop
            if Ada.Directories.Exists (State & "/" & Area) then
               Ada.Directories.Start_Search
                 (Search, State & "/" & Area, "*.rec", [Ada.Directories.Ordinary_File => True, others => False]);
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  declare
                     File : Ada.Text_IO.File_Type;
                     Name : constant String := Ada.Directories.Simple_Name (Found);
                  begin
                     Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Ada.Directories.Full_Name (Found));
                     while not Ada.Text_IO.End_Of_File (File) loop
                        declare
                           Line : constant String := Ada.Text_IO.Get_Line (File);
                        begin
                           if Line'Length > Mark'Length
                             and then Line (Line'Last - Mark'Length + 1 .. Line'Last) = Mark
                           then
                              Ada.Text_IO.Close (File);
                              Ada.Directories.End_Search (Search);
                              --  A kept revision's record is its entry's: the
                              --  label names the entry, as it now is.
                              declare
                                 Base : constant String := Name (Name'First .. Name'Last - 4);
                                 Rev  : constant Natural := Ada.Strings.Fixed.Index (Base, ".rev-");
                              begin
                                 return (if Rev > 0 then Base (Base'First .. Rev - 1) else Base);
                              end;
                           end if;
                        end;
                     end loop;
                     Ada.Text_IO.Close (File);
                  exception
                     when others =>
                        if Ada.Text_IO.Is_Open (File) then
                           Ada.Text_IO.Close (File);
                        end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
            end if;
         end loop;
         return "";
      end Labelled;

      --  A number that names both the padded entry and a document's own
      --  unpadded one: the two kept, to be said.
      procedure Check_Both (Prefix, Number : String) is
         Bare : constant String := Ada.Strings.Fixed.Trim (Number, Ada.Strings.Maps.To_Set ("0"),
                                                           Ada.Strings.Maps.Null_Set);
      begin
         if Bare /= "" and then Padded (Number) /= Bare
           and then Held_As (Prefix & Padded (Number)) and then Held_As (Prefix & Bare)
         then
            Number_Ambiguity := To_Unbounded_String (Prefix & Padded (Number) & " and " & Prefix & Bare);
         end if;
      end Check_Both;

      function Kept (Word : String) return String is
         Upper : constant String := Ada.Characters.Handling.To_Upper (Word);
         Dash  : constant Natural := Ada.Strings.Fixed.Index (Upper, "-", Ada.Strings.Backward);
      begin
         --  Kept as a document numbered it -- REQ-1 -- it is that one.
         if Held_As (Upper) then
            return Upper;
         end if;
         --  A document's own label -- FR-001 -- is the entry read from it.
         if Dash > Upper'First and then Ada.Strings.Fixed.Index (Upper, "REQ-") /= Upper'First
           and then Ada.Strings.Fixed.Index (Upper, "TASK-") /= Upper'First
           and then Labelled (Upper) /= ""
         then
            return Labelled (Upper);
         end if;
         if Dash > Upper'First
           and then (Ada.Strings.Fixed.Index (Upper, "TASK-") = Upper'First
                     or else Ada.Strings.Fixed.Index (Upper, "REQ-") = Upper'First
                     or else Ada.Strings.Fixed.Index (Upper, "DEC-") = Upper'First
                     or else Ada.Strings.Fixed.Index (Upper, "SPEC-") = Upper'First)
           and then All_Digits (Upper (Dash + 1 .. Upper'Last))
           and then (for all C of Upper => C in 'A' .. 'Z' | '0' .. '9' | '-' | '_')
         then
            Check_Both (Upper (Upper'First .. Dash), Upper (Dash + 1 .. Upper'Last));
            declare
               Bare : constant String :=
                 Ada.Strings.Fixed.Trim (Upper (Dash + 1 .. Upper'Last), Ada.Strings.Maps.To_Set ("0"),
                                         Ada.Strings.Maps.Null_Set);
            begin
               if Bare /= ""
                 and then not Held_As (Upper (Upper'First .. Dash) & Padded (Upper (Dash + 1 .. Upper'Last)))
                 and then Held_As (Upper (Upper'First .. Dash) & Bare)
               then
                  return Upper (Upper'First .. Dash) & Bare;
               end if;
            end;
            return Upper (Upper'First .. Dash) & Padded (Upper (Dash + 1 .. Upper'Last));
         end if;
         return Word;
      end Kept;

      Command : constant String := (if Words.Is_Empty then "" else Words.First_Element);

      --  What a number alone at a place stands for: TASK- where a task is
      --  named, REQ-, SPEC- or DEC- where the register's entry is.
      function Number_Kind (Index : Positive) return String;

      function Number_Kind (Index : Positive) return String is
         Act : constant String :=
           (if Natural (Words.Length) >= 2 then Ada.Characters.Handling.To_Lower (Words (2)) else "");
      begin
         if Command in "/work" | "/cancel" and then Index >= 2 then
            return "TASK-";
         elsif Command = "/task" and then Index >= 3
           and then Act in "show" | "audit" | "accept" | "reject" | "cancel" | "complete" | "verify"
                         | "integrate" | "diff" | "edit" | "depend" | "split" | "reopen" | "reconsider"
                         | "move" | "rehome" | "context" | "plan"
         then
            return "TASK-";
         elsif Command = "/task" and then Act = "link" then
            return (if Index = 3 then "TASK-" elsif Index >= 4 then "REQ-" else "");
         elsif Command in "/req" | "/spec" | "/decision" and then Index = 3 and then Act = "move" then
            return (if Command = "/req" then "REQ-" elsif Command = "/spec" then "SPEC-" else "DEC-");
         elsif Command = "/instruct" and then Index = 3 and then Act = "withdraw" then
            return "INSTR-";
         elsif Command in "/req" | "/spec" | "/decision"
           and then ((Index >= 3
                      and then Act in "show" | "accept" | "reject" | "reconsider" | "obsolete" | "block"
                                    | "unblock" | "verify" | "trace")
                     --  The entry alone: a ruling, a text or a target is not
                     --  an identifier for being a number.
                     or else (Index = 3 and then Act in "link" | "unlink" | "govern" | "revise")
                     or else (Index in 3 .. 4 and then Act = "supersede"))
         then
            return (if Command = "/req" then "REQ-" elsif Command = "/spec" then "SPEC-" else "DEC-");
         --  A link's target by its relation: a task is TASK-, a dependency
         --  of the command's own register.
         elsif Command in "/req" | "/spec" | "/decision" and then Index = 5 and then Act in "link" | "unlink"
           and then Natural (Words.Length) >= 4
         then
            declare
               Relation : constant String := Ada.Characters.Handling.To_Lower (Words (4));
            begin
               return (if Relation in "task" | "served_by" | "tasks" then "TASK-"
                       elsif Relation in "dependency" | "depends_on" | "depends"
                       then (if Command = "/req" then "REQ-" elsif Command = "/spec" then "SPEC-" else "DEC-")
                       else "");
            end;
         elsif Command in "/check" | "/trace" and then Index >= 2 then
            return "REQ-";
         end if;
         return "";
      end Number_Kind;
   begin
      for Index in 1 .. Natural (Words.Length) loop
         declare
            Word : constant String := Words (Index);
         begin
            --  A number alone where an identifier is named: a task's, or
            --  the register's the command is about.
            if All_Digits (Word) and then Number_Kind (Index) /= "" then
               Check_Both (Number_Kind (Index), Word);
               --  The register's own way of numbering: REQ-1 where it holds
               --  that and no REQ-001.
               declare
                  Bare : constant String := Ada.Strings.Fixed.Trim (Word, Ada.Strings.Maps.To_Set ("0"),
                                                                    Ada.Strings.Maps.Null_Set);
               begin
                  if Bare /= "" and then not Held_As (Number_Kind (Index) & Padded (Word))
                    and then Held_As (Number_Kind (Index) & Bare)
                  then
                     Result.Append (Number_Kind (Index) & Bare);
                  else
                     Result.Append (Number_Kind (Index) & Padded (Word));
                  end if;
               end;

            --  parent=2, depends_on=1,3, requirements=4: the identifiers a
            --  task's fields hold, each as typed.
            elsif Command = "/task" and then Ada.Strings.Fixed.Index (Word, "=") > 1 then
               declare
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
                  Name  : constant String := Ada.Characters.Handling.To_Lower (Word (Word'First .. Equal - 1));
                  Kind  : constant String :=
                    (if Name in "parent" | "depends_on" then "TASK-"
                     elsif Name = "requirements" then "REQ-" else "");
                  Value : constant String := Word (Equal + 1 .. Word'Last);
                  Out_V : Unbounded_String;
                  Start : Natural := Value'First;
               begin
                  if Kind = "" or else Value = "" then
                     Result.Append (Word);
                  else
                     for At_Index in Value'First .. Value'Last + 1 loop
                        if At_Index > Value'Last or else Value (At_Index) = ',' then
                           declare
                              One : constant String := Value (Start .. At_Index - 1);
                           begin
                              Append (Out_V, (if All_Digits (One) then Kind & Padded (One)
                                              elsif One = "" then "" else Kept (One))
                                             & (if At_Index > Value'Last then "" else ","));
                           end;
                           Start := At_Index + 1;
                        end if;
                     end loop;
                     Result.Append (Word (Word'First .. Equal) & To_String (Out_V));
                  end if;
               end;
            elsif Index > 1 and then Ada.Strings.Fixed.Index (Word, "=") = 0 then
               Result.Append (Kept (Word));
            else
               Result.Append (Word);
            end if;
         end;
      end loop;
      return Result;
   end Identifiers_As_Kept;

   ---------
   -- Run --
   ---------

   --  The exit status the last command's own part set, beside what the
   --  console counted of the errors it reported.
   Last_Status : Natural := 0;

   --  Whether a task's finished work waits in a workspace to be taken in.
   function Waiting_In_Workspace (Task_Id : String) return Boolean is
      Store  : S.Store;
      Read   : E.Error_Info;
      Result : Boolean := False;
   begin
      if S.Is_Initialized (Ada.Directories.Current_Directory) then
         S.Open_To_Read (Store, Ada.Directories.Current_Directory, Read);
         if E.Is_Ok (Read) then
            Result := Tk.State_Of (Store, Task_Id) = "verification"
              and then Model_Runner.Framework.Workspaces.Active_For (Store, Task_Id) /= "";
            S.Close (Store);
         end if;
      end if;
      return Result;
   exception
      when others =>
         return False;
   end Waiting_In_Workspace;

   --  Whether a /work just ended with echo held off: a line typed during
   --  it was not shown, and is shown as it is taken up.
   Typed_Ahead : Boolean := False;

   function Last_Refusals return String is (To_String (Refused_Last));

   function Typed_During_Work return Boolean is
      Was : constant Boolean := Typed_Ahead;
   begin
      Typed_Ahead := False;
      return Was;
   end Typed_During_Work;

   --  Of a fault's account, what was raised and the first place in the
   --  source it passed: enough to find it, not the whole stack.
   function Where_Raised (Information : String) return String is
      Result : Unbounded_String;
      Placed : Boolean := False;
   begin
      for Line of Model_Runner.Framework.Lines_Of (Information) loop
         if Result = Null_Unbounded_String then
            Result := To_Unbounded_String (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both));
         elsif not Placed and then Ada.Strings.Fixed.Index (Line, ".adb:") > 0 then
            Append (Result, ", in " & Ada.Strings.Fixed.Trim
                                         (Line (Ada.Strings.Fixed.Index (Line, " ", Line'First + 3) .. Line'Last),
                                          Ada.Strings.Both));
            Placed := True;
         end if;
      end loop;
      return To_String (Result);
   end Where_Raised;

   procedure Run
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class)
   is
      All_Words  : constant Names.Vector := Identifiers_As_Kept (Split (Line));
      Open_Quote : constant Boolean := Left_Open;
      Word       : constant String := All_Words.First_Element;
      Positional : Names.Vector;
      Command    : Model_Runner.CLI.Project_Requests.Request;
      Continues  : Boolean := False;
      To_Task    : Boolean := False;
      Status     : Natural := 0;
      Outcome    : E.Error_Info;

      function Argument (Index : Positive) return String
      is (if Natural (Positional.Length) >= Index then Positional (Index) else "");

      --  The positional words from one on, joined: a title may have spaces.
      function Rest (From : Positive) return String is
         Text : Unbounded_String;
      begin
         for Index in From .. Natural (Positional.Length) loop
            Append (Text, (if Index = From then "" else " ") & Positional (Index));
         end loop;
         return To_String (Text);
      end Rest;

      --  Names a comma apart.
      function Joined_Names (Listed : Names.Vector) return String is
         Text : Unbounded_String;
      begin
         for One of Listed loop
            Append (Text, (if Text = Null_Unbounded_String then "" else ", ") & One);
         end loop;
         return To_String (Text);
      end Joined_Names;

      --  Whether fields are said under a group's title, set in from it.
      Sectioned : Boolean := False;

      --  A field, its name muted and its value in its tone at a terminal
      --  that shows colour.
      procedure Field (Name, Value : String; Value_Tone : Pres.Tone := Pres.Plain) is
      begin
         Pres.Put_Pair (Screen, "cli.task.field", Name, Value, Value_Tone, Indent => (if Sectioned then 2 else 0));
      end Field;

      --  Of tasks named together, the first now ready: what to work on next.
      procedure Say_First_Ready (Named : Names.Vector; From : Positive) is
         Store : S.Store;
         Read  : E.Error_Info;
      begin
         if not S.Is_Initialized (Here) then
            return;
         end if;
         S.Open_To_Read (Store, Here, Read);
         if E.Is_Ok (Read) then
            for Index in From .. Natural (Named.Length) loop
               declare
                  Given : constant String := Ada.Characters.Handling.To_Upper (Named (Index));
                  Id    : constant String :=
                    (if Given /= "" and then Given'Length <= 6 and then (for all C of Given => C in '0' .. '9')
                     then "TASK-" & (if Given'Length >= 3 then Given else [1 .. 3 - Given'Length => '0'] & Given)
                     else Given);
               begin
                  if Ada.Strings.Fixed.Index (Id, "TASK-") = Id'First and then Tk.Ready (Store, Id).Ready then
                     Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Id)]);
                     exit;
                  end if;
               end;
            end loop;
         end if;
         S.Close (Store);
      end Say_First_Ready;

      --  Open the project, or say there is none.
      procedure With_Store (Act : not null access procedure (Store : in out S.Store)) is
         Store  : S.Store;
         Report : S.Recovery_Report;
      begin
         S.Open (Store, Here, Report, Outcome);

         --  Held by a run in progress, what only looks can still look.
         if E."=" (Outcome.Code, E.Framework_Locked)
           and then (Word in "/state" | "/config" | "/result"
                     or else (Word in "/req" | "/decision" | "/spec"
                              and then Argument (1) not in "new" | "accept" | "reject"
                                 | "reconsider" | "obsolete" | "block" | "unblock" | "revise"
                                 | "link" | "supersede" | "govern" | "move"))
         then
            S.Open_To_Read (Store, Here, Outcome);
            if E.Is_Ok (Outcome) then
               Pres.Put_Note (Screen, "cli.project.read_only");
            end if;
         end if;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;
         --  What a session that died left -- a task running with nobody
         --  running it -- is put right whenever the project is opened, not
         --  only when a session starts: a live one sees it too.
         if not S.Is_Read_Only (Store) then
            declare
               Said : Names.Vector;
               Kept : E.Error_Info;
            begin
               Model_Runner.Framework.Work.Recover (Store, Said, Kept);
               for Id of Said loop
                  Pres.Put_Note (Screen, "cli.project.recovered",
                                 [Loc.Named ("detail", Id & " was running with no one running it; it is "
                                                       & Tk.State_Of (Store, Id) & " now")]);
               end loop;
            end;
         end if;
         Act (Store);
         --  What the command changed follows at once, said under it: a
         --  requirement no longer verified, a task now ready. A command that
         --  only looks changes nothing, and so leaves this to the next that
         --  does.
         if not S.Is_Read_Only (Store)
           and then not (Word in "/state" | "/config" | "/trace" | "/result" | "/help"
                         or else (Word in "/req" | "/spec" | "/decision" | "/task"
                                  and then Argument (1) in "" | "show" | "list" | "audit" | "context" | "diff"))
         then
            declare
               Said : Names.Vector;
               Kept : E.Error_Info;
            begin
               Model_Runner.Framework.Work.Reevaluate (Store, Said, Kept);
               for Line of Said loop
                  Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
               end loop;
            end;
         end if;
         S.Close (Store);
      end With_Store;

      procedure State (Store : in out S.Store) is
         Config : R.Item;
         Read   : E.Error_Info;
         --  Advice found among the counts, said after them.
         Unserved   : Names.Vector;
         Last_Check : Unbounded_String;

         procedure Line_Of (Key : String; Value : String) is
         begin
            Pres.Put_Indented
              (Screen, "cli.task.field",
               [Loc.Named ("name", Pres.Message_Value (Screen, Key)),
                Loc.Named ("value", Value)]);
         end Line_Of;

         function Count (State_Name : String) return String
         is (Image (Natural (Tk.List (Store, State_Name).Length)));

         --  The tasks in a state that needs a person, each with why.
         procedure Which (State_Name : String) is
         begin
            for Id of Tk.List (Store, State_Name) loop
               declare
                  Reasons : constant Names.Vector := Tk.Ready (Store, Id).Reasons;
               begin
                  Pres.Put_Indented
                    (Screen, "cli.project.which",
                     [Loc.Named ("name", Id),
                      Loc.Named ("value", (if Reasons.Is_Empty then State_Name
                                           else Reasons.First_Element))], Indent => 4);
               end;
            end loop;
         end Which;

         Ready : Natural := 0;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         --  In groups, each under its title, as /task show has a task: the
         --  project, its registers, its tasks, its checks, its agents, and
         --  what needs a person.
         Pres.Put_Header (Screen, "cli.state.section.project");
         Line_Of ("cli.project.template", R.Get (Config, "template_id"));
         Line_Of ("cli.project.configuration", Image (R.Revision (Config)));
         --  A project with nothing in it yet: said in a line, with how to
         --  begin, not as a column of noughts.
         if Nt.List (Store, Nt.Requirement).Is_Empty and then Nt.List (Store, Nt.Specification).Is_Empty
           and then Nt.List (Store, Nt.Decision).Is_Empty and then Tk.List (Store).Is_Empty
         then
            Pres.Put_Note (Screen, "cli.project.state_empty");
            return;
         end if;
         --  Requirements that still stand: none rejected, retired or
         --  replaced; those waiting to be decided counted apart.
         Pres.Put_Section (Screen, "cli.state.section.registers");
         declare
            Standing : Natural := 0;
         begin
            for Id of Nt.List (Store, Nt.Requirement) loop
               declare
                  Held : Nt.Entity;
                  Got  : E.Error_Info;
               begin
                  Nt.Read (Store, Nt.Requirement, Id, Held, Got);
                  if E.Is_Ok (Got)
                    and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                  then
                     Standing := Standing + 1;
                  end if;
               end;
            end loop;
            Line_Of ("cli.project.requirements", Image (Standing));
         end;
         Line_Of ("cli.project.candidate_requirements",
                  Image (Natural (Nt.List (Store, Nt.Requirement,
                                           Nt.First_State (Nt.Requirement)).Length)));
         Line_Of ("cli.project.verified",
                  Image (Natural (Nt.List (Store, Nt.Requirement, "verified").Length)));
         --  Specifications and decisions waiting to be decided, where any
         --  do: /accept lists them with the requirements.
         declare
            Specs : constant Natural :=
              Natural (Nt.List (Store, Nt.Specification, Nt.First_State (Nt.Specification)).Length);
            Decisions : constant Natural :=
              Natural (Nt.List (Store, Nt.Decision, Nt.First_State (Nt.Decision)).Length);
         begin
            --  Those in force, where any are: what governs the work.
            if not Nt.List (Store, Nt.Decision, "accepted").Is_Empty then
               Line_Of ("cli.project.accepted_decisions",
                        Image (Natural (Nt.List (Store, Nt.Decision, "accepted").Length)));
            end if;
            if not Nt.List (Store, Nt.Specification, "accepted").Is_Empty then
               Line_Of ("cli.project.accepted_specs",
                        Image (Natural (Nt.List (Store, Nt.Specification, "accepted").Length)));
            end if;
            if Specs > 0 then
               Line_Of ("cli.project.candidate_specs", Image (Specs));
            end if;
            if Decisions > 0 then
               Line_Of ("cli.project.proposed_decisions", Image (Decisions));
            end if;
         end;
         --  Accepted, and nothing open or done serves it: no work will
         --  carry it out unless some is made.
         for Id of Nt.List (Store, Nt.Requirement, "accepted") loop
            declare
               Served : Boolean := False;
            begin
               for Task_Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Task_Id, Defined, Got);
                     Served := Served
                       or else (E.Is_Ok (Got)
                                and then Tk.State_Of (Store, Task_Id) not in "cancelled" | "rejected"
                                and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                                           .Contains (Id));
                  end;
               end loop;
               if not Served then
                  Unserved.Append (Id);
               end if;
            end;
         end loop;
         for Id of Tk.List (Store, "accepted") loop
            if Tk.Ready (Store, Id).Ready then
               Ready := Ready + 1;
            end if;
         end loop;
         Pres.Put_Section (Screen, "cli.state.section.tasks");
         Line_Of ("cli.project.candidates", Count ("candidate"));
         Line_Of ("cli.project.accepted", Count ("accepted"));
         Line_Of ("cli.project.ready", Image (Ready));
         --  Accepted and not ready: each, with what it waits for -- a task,
         --  or a requirement since retired.
         if Natural (Tk.List (Store, "accepted").Length) > Ready then
            Line_Of ("cli.project.waiting", Image (Natural (Tk.List (Store, "accepted").Length) - Ready));
            for Id of Tk.List (Store, "accepted") loop
               declare
                  Now : constant Tk.Readiness := Tk.Ready (Store, Id);
               begin
                  if not Now.Ready then
                     Pres.Put_Indented
                       (Screen, "cli.project.which",
                        [Loc.Named ("name", Id),
                         Loc.Named ("value", (if Now.Reasons.Is_Empty then "waiting"
                                              else Now.Reasons.First_Element))], Indent => 4);
                  end if;
               end;
            end loop;
         end if;
         --  Work a person takes in: each, with how.
         declare
            Waiting : Names.Vector;
         begin
            for Id of Tk.List (Store, "verification") loop
               if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
                  Waiting.Append (Id);
               end if;
            end loop;
            if not Waiting.Is_Empty then
               Line_Of ("cli.project.to_integrate", Image (Natural (Waiting.Length)));
               for Id of Waiting loop
                  Pres.Put_Indented
                    (Screen, "cli.project.which",
                     [Loc.Named ("name", Id),
                      Loc.Named ("value", Tk.Ready (Store, Id).Reasons.First_Element)], Indent => 4);
               end loop;
            end if;
         end;
         Line_Of ("cli.project.blocked", Count ("blocked"));
         Which ("blocked");
         Line_Of ("cli.project.running", Count ("running"));
         --  Each running, with the agent that runs it.
         for Id of Tk.List (Store, "running") loop
            declare
               Runs_It : constant String := Model_Runner.Framework.Agents.Working_On (Store, Id);
            begin
               Pres.Put_Indented
                 (Screen, "cli.project.which",
                  [Loc.Named ("name", Id),
                   Loc.Named ("value", (if Runs_It = "" then "running"
                                        else "its agent " & Runs_It & " is working on it"))], Indent => 4);
            end;
         end loop;
         Line_Of ("cli.project.complete", Count ("complete"));
         Line_Of ("cli.project.failed", Count ("failed"));
         Which ("failed");
         declare
            Last : constant Names.Vector :=
              S.Names (Store, Model_Runner.Framework.Verification_Area);
            Held : R.Item;
         begin
            --  Checks, where any has run.
            if not Last.Is_Empty then
               Pres.Put_Section (Screen, "cli.state.section.checks");
               S.Read (Store, Model_Runner.Framework.Verification_Area,
                       Last.Last_Element, Held, Read);
               Last_Check := To_Unbounded_String (Last.Last_Element);
               Pres.Put_Pair (Screen, "cli.task.field", Pres.Message_Value (Screen, "cli.project.last_check"),
                              Last.Last_Element & " "
                              & (if R.Get (Held, "passed") = "true" then "passed" else "failed"),
                              (if R.Get (Held, "passed") = "true" then Pres.Good else Pres.Bad), Indent => 2);
            end if;
         end;
         declare
            --  The last run of every profile the full verification is made
            --  of, or of the default where it names none: all passed, or
            --  not.
            Full   : Names.Vector := Model_Runner.Framework.Lines_Of (R.Get (Config, "list.verification.full"));
            Latest : Unbounded_String;
            Result : Unbounded_String;
         begin
            --  As /check full chooses it: a profile called full first.
            if R.Has (Config, "profile.full") then
               Full.Clear;
               Full.Append ("full");
            elsif Full.Is_Empty then
               Full.Append (R.Get (Config, "scalar.verification.default"));
            end if;
            for Name of S.Names (Store, Model_Runner.Framework.Verification_Area) loop
               declare
                  Held : R.Item;
               begin
                  S.Read (Store, Model_Runner.Framework.Verification_Area, Name, Held, Read);
                  --  A test is a profile that runs tests: a build in the
                  --  full verification is not one.
                  --  And on the project: a check run in a task's workspace
                  --  tested that workspace, not the project.
                  if E.Is_Ok (Read) and then Full.Contains (R.Get (Held, "profile"))
                    and then R.Get (Config, "scalar.profile_capability." & R.Get (Held, "profile"))
                             = "run_tests"
                    and then R.Get (Held, "workspace") = ""
                  then
                     Latest := To_Unbounded_String (Name);
                     Result := To_Unbounded_String
                       (if R.Get (Held, "passed") = "true" then "passed" else "failed");
                  end if;
               end;
            end loop;
            --  The same run as the last check: said once.
            if Latest /= Null_Unbounded_String and then Latest /= Last_Check then
               Pres.Put_Pair (Screen, "cli.task.field", Pres.Message_Value (Screen, "cli.project.last_full"),
                              To_String (Latest) & " " & To_String (Result),
                              (if To_String (Result) = "passed" then Pres.Good else Pres.Bad), Indent => 2);
            end if;
         end;

         Pres.Put_Section (Screen, "cli.state.section.agents");
         Line_Of ("cli.project.agents_active",
                  Image (Model_Runner.Framework.Agents.Active_Count (Store)));
         --  What confines every agent the session starts, where anything does.
         if Model_Runner.Framework.Permissions.Sandbox_Source /= "" then
            declare
               Shown : Unbounded_String;
            begin
               for Part of Model_Runner.Framework.Lines_Of
                 (Model_Runner.Framework.Permissions.Image (Model_Runner.Framework.Permissions.Sandbox))
               loop
                  Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ") & Part);
               end loop;
               Line_Of ("cli.project.sandbox",
                        Model_Runner.Framework.Permissions.Sandbox_Source & ": " & To_String (Shown));
            end;
         end if;
         Pres.Put_Section (Screen, "cli.state.section.attention");
         --  What waits on a person besides tasks: issues not yet dealt
         --  with, and what does not hold together.
         declare
            Dismissed : constant Names.Vector := Dismissed_List (Store);
            Open      : Natural := 0;
            Counted   : Names.Vector;
         begin
            for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
               declare
                  Result_Id : constant String :=
                    (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                     then Name (Name'First .. Name'Last - 4) else Name);
                  One       : Rs.Result;
                  Got       : E.Error_Info;
               begin
                  Rs.Read (Store, Result_Id, One, Got);
                  if E.Is_Ok (Got) and then Rs."=" (One.Kind, Rs.Diagnostic)
                    and then not Dismissed.Contains (Result_Id)
                    and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                    --  As /result counts: an attempt's issue whose task was
                    --  taken up again since, or ended, is acted on.
                    and then not (Task_Of_Issue (Store, One) /= ""
                                  and then Tk.State_Of (Store, Task_Of_Issue (Store, One))
                                             in "accepted" | "running" | "verification" | "complete"
                                              | "cancelled" | "rejected")
                    and then not Counted.Contains
                                   (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
                  then
                     Counted.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                     Open := Open + 1;
                  end if;
               end;
            end loop;
            --  What waits on a person to be decided, in every register.
            Line_Of ("cli.project.to_decide",
                     Image (Natural (Tk.List (Store, "candidate").Length)
                            + Natural (Model_Runner.CLI.Intents.Pending (Store).Length)));
            Line_Of ("cli.project.open_issues", Image (Open));
            Line_Of ("cli.project.inconsistent",
                     Image (Model_Runner.Framework.Consistency.Length
                              (Model_Runner.Framework.Consistency.Check (Store))));
         end;
         --  Done and not verified: each, and how it is.
         for Id of Nt.List (Store, Nt.Requirement, "implemented") loop
            Pres.Put_Note (Screen, "cli.project.not_verified",
                           [Loc.Named ("name", Id),
                            Loc.Named ("detail",
                                       (if Vf.Why_Not_Verified (Store, Id) = ""
                                        then "its evidence holds; check " & Id & " records it verified"
                                        else Vf.Why_Not_Verified (Store, Id)))]);
         end loop;
         --  Recorded verified, and its evidence no longer holds: said, not
         --  counted on until it is judged again.
         for Id of Nt.List (Store, Nt.Requirement, "verified") loop
            declare
               Why : constant String := Vf.Why_Not_Verified (Store, Id);
            begin
               if Why /= "" then
                  Pres.Put_Note (Screen, "cli.project.stale_verified",
                                 [Loc.Named ("name", Id), Loc.Named ("detail", Why)]);
               end if;
            end;
         end loop;
         --  Accepted, and nothing serves it: after the counts, with a task
         --  that served it once and was cancelled, taken back.
         for Id of Unserved loop
            declare
               Cancelled : Unbounded_String;
            begin
               for Task_Id of Tk.List (Store, "cancelled") loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Task_Id, Defined, Got);
                     if Cancelled = Null_Unbounded_String and then E.Is_Ok (Got)
                       and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")).Contains (Id)
                     then
                        Cancelled := To_Unbounded_String (Task_Id);
                     end if;
                  end;
               end loop;
               if Cancelled /= Null_Unbounded_String then
                  Pres.Put_Note (Screen, "cli.project.unserved_cancelled",
                                 [Loc.Named ("name", Id), Loc.Named ("value", To_String (Cancelled))]);
               else
                  Pres.Put_Note (Screen, "cli.project.unserved", [Loc.Named ("name", Id)]);
               end if;
            end;
         end loop;

         --  The step that comes next, as the state stands: work to take in,
         --  a ready task, candidates to decide, or how to begin.
         declare
            To_Take   : Unbounded_String;
            Ready_One : Unbounded_String;
         begin
            for Id of Tk.List (Store, "verification") loop
               if To_Take = Null_Unbounded_String
                 and then Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= ""
               then
                  To_Take := To_Unbounded_String (Id);
               end if;
            end loop;
            for Id of Tk.List (Store, "accepted") loop
               if Ready_One = Null_Unbounded_String and then Tk.Ready (Store, Id).Ready then
                  Ready_One := To_Unbounded_String (Id);
               end if;
            end loop;
            if To_Take /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.next.integrate", [Loc.Named ("name", To_String (To_Take))]);
            elsif Ready_One /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", To_String (Ready_One))]);
            elsif not Tk.List (Store, "candidate").Is_Empty
              or else not Model_Runner.CLI.Intents.Pending (Store).Is_Empty
            then
               --  Every candidate waiting, tasks and the registers' alike:
               --  one is decided by /accept, several listed by it.
               declare
                  Waiting : Names.Vector := Tk.List (Store, "candidate");
               begin
                  for Which of Model_Runner.CLI.Intents.Pending (Store) loop
                     Waiting.Append (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
                  end loop;
                  if Natural (Waiting.Length) = 1 then
                     Pres.Put_Note (Screen, "cli.next.accept_one",
                                    [Loc.Named ("name", Waiting.First_Element)]);
                  else
                     Pres.Put_Note (Screen, "cli.next.accept_several",
                                    [Loc.Named ("count", Image (Natural (Waiting.Length)))]);
                  end if;
               end;
            elsif Tk.List (Store).Is_Empty and then Nt.List (Store, Nt.Requirement).Is_Empty then
               Pres.Put_Note (Screen, "cli.next.init");
            end if;
         end;
      end State;

      procedure Show_Config (Store : in out S.Store) is
         Config : R.Item;
         Read   : E.Error_Info;

         --  What an accepted decision rules for a setting, by the setting:
         --  shown beside what the configuration says, and the two named
         --  where they disagree.
         Ruled  : Model_Runner.Framework.Configurations.Value_Maps.Map;

         --  The setting an input made, where it holds something else now:
         --  input.work_isolation's is scalar.work.isolation.
         function Since_Init (Name, Given : String) return String is
            Dotted : constant String :=
              Ada.Strings.Fixed.Translate (Name (Name'First + 6 .. Name'Last),
                                           Ada.Strings.Maps.To_Mapping ("_", "."));
         begin
            for Kind_Of in 1 .. 2 loop
               declare
                  Setting : constant String := (if Kind_Of = 1 then "scalar." else "set.") & Dotted;
               begin
                  if R.Has (Config, Setting) and then R.Get (Config, Setting) /= Given then
                     return "; " & Setting & " is " & R.Get (Config, Setting) & " now";
                  end if;
               end;
            end loop;
            return "";
         end Since_Init;

         --  Whether what rules a setting says what it holds: the last ruling
         --  named -- a decision's, or an instruction's -- is its value.
         function Agrees (Said, Value : String) return Boolean is
            Lower : constant String := Ada.Characters.Handling.To_Lower (Said);
            Want  : constant String := Ada.Characters.Handling.To_Lower (Value);
         begin
            return (Lower'Length >= Want'Length + 7
                    and then Lower (Lower'Last - Want'Length - 6 .. Lower'Last) = " rules " & Want)
              or else (Lower'Length >= Want'Length + 6
                       and then Lower (Lower'Last - Want'Length - 5 .. Lower'Last) = " says " & Want);
         end Agrees;

         --  A name NAME is asked for by: a word of it, or words of it in
         --  order -- work is scalar.work.lease's, not network's.
         function Asked (Name : String) return Boolean
         is (Argument (1) = ""
             or else Ada.Strings.Fixed.Index ("." & Name & ".", "." & Argument (1)) > 0);

         --  What a setting is about, for the group it is shown in.
         function Area_Of (Name : String) return String is
            function Starts (Prefix : String) return Boolean
            is (Ada.Strings.Fixed.Index (Name, Prefix) = Name'First);
         begin
            return (if Starts ("input.") or else Starts ("template_") or else Name = "configuration_fingerprint"
                    then "project"
                    elsif Starts ("map.permission.") then "permissions"
                    elsif Starts ("scalar.work.") or else Starts ("scalar.agents.")
                      or else Starts ("scalar.task.max_") or else Starts ("scalar.task.token_budget")
                      or else Starts ("scalar.task.coordination") or else Starts ("scalar.recovery.")
                      or else Starts ("scalar.model.") or else Starts ("scalar.context.")
                    then "work"
                    elsif Starts ("profile.") or else Starts ("scalar.verification.")
                      or else Starts ("list.verification.") or else Starts ("scalar.profile_capability.")
                      or else Starts ("scalar.task.profile.") or else Starts ("set.execution.")
                      or else Starts ("scalar.execution.")
                    then "verification"
                    elsif Starts ("set.components") or else Starts ("map.component.")
                      or else Starts ("set.repository.") or else Starts ("scalar.repository.")
                    then "components"
                    elsif Starts ("scalar.bootstrap.") or else Starts ("set.bootstrap.") then "bootstrap"
                    else "rules");
         end Area_Of;

         --  The first group's title, with no blank line above it.
         First_Group : Boolean := True;

         Areas : constant Names.Vector :=
           (if Argument (1) = ""
            then Names.Vector'(["project", "work", "permissions", "verification", "components", "bootstrap",
                                "rules"])
            else Names.Vector'(["all"]));

         function In_Area (Name, Area : String) return Boolean
         is (Area = "all" or else Area_Of (Name) = Area);
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         for Id of Nt.List (Store, Nt.Decision) loop
            if Nt.State_Of (Store, Nt.Decision, Id) = "accepted" then
               declare
                  All_Of : Names.Vector := Nt.Also_Governs (Store, Nt.Decision, Id);
               begin
                  if Nt.Governs (Store, Nt.Decision, Id) /= "" then
                     All_Of.Prepend (Nt.Governs (Store, Nt.Decision, Id));
                  end if;
                  for One of All_Of loop
                     declare
                        Equal : constant Natural := Ada.Strings.Fixed.Index (One, " = ");
                        Over  : constant Natural := Ada.Strings.Fixed.Index (One, " (over ");
                     begin
                        if Equal > One'First then
                           Ruled.Include (One (One'First .. Equal - 1),
                                          Id & " rules "
                                          & One (Equal + 3 .. (if Over > 0 then Over - 1 else One'Last)));
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end loop;
         --  Set out by what each setting is about, a group a title, where
         --  the whole is asked for; a name asked for, as one list.
         --  A standing instruction on a setting, beside what decisions rule:
         --  INSTR-001 says 3, where the setting is agents.max_steps.
         for Line of Model_Runner.Framework.Authority.Standing_Instructions (Store) loop
            declare
               Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
               Equal : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
            begin
               if Colon > 0 and then Equal > Colon then
                  declare
                     Subject : constant String :=
                       Ada.Strings.Fixed.Trim (Line (Colon + 2 .. Equal - 1), Ada.Strings.Both);
                     Said    : constant String :=
                       Ada.Strings.Fixed.Trim (Line (Equal + 1 .. Line'Last), Ada.Strings.Both);
                     Whole   : constant String :=
                       (if R.Has (Config, Subject) then Subject
                        elsif R.Has (Config, "scalar." & Subject)
                          or else Model_Runner.Framework.Configurations.Known_Names.Contains ("scalar." & Subject)
                        then "scalar." & Subject
                        else Subject);
                     Id      : constant String := Line (Line'First .. Colon - 1);
                  begin
                     if Ruled.Contains (Whole) then
                        Ruled.Replace (Whole, Ruled (Whole) & "; " & Id & " says " & Said);
                     else
                        Ruled.Include (Whole, Id & " says " & Said);
                     end if;
                  end;
               end if;
            end;
         end loop;
         Sectioned := Argument (1) = "";
         for Area of Areas loop
            if Argument (1) = ""
              and then ((for some Index in 1 .. R.Field_Count (Config) =>
                           In_Area (R.Field_Name (Config, Index), Area)
                           and then Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), "file.") /= 1)
                        or else Area in "permissions" | "components"
                        or else (for some Known of Model_Runner.Framework.Configurations.Known_Names =>
                                   In_Area (Known, Area)))
            then
               if First_Group then
                  First_Group := False;
               elsif not Pres.Is_Structured (Screen) then
                  Pres.Put_Line (Screen, "");
               end if;
               Pres.Put_Header
                 (Screen,
                  (if Area = "project" then "cli.config.section.project"
                   elsif Area = "work" then "cli.config.section.work"
                   elsif Area = "permissions" then "cli.config.section.permissions"
                   elsif Area = "verification" then "cli.config.section.verification"
                   elsif Area = "components" then "cli.config.section.components"
                   elsif Area = "bootstrap" then "cli.config.section.bootstrap"
                   else "cli.config.section.rules"));
            end if;
            for Index in 1 .. R.Field_Count (Config) loop
               declare
                  Name  : constant String := R.Field_Name (Config, Index);
                  Value : constant String := R.Get (Config, Name);

                  --  A set's items on one line a comma apart, as the other lines
                  --  name several things; a list's -- commands, in order -- a line
                  --  each.
                  function Shown return String is
                  begin
                     --  A permission granted with nothing more: said so, not a
                     --  bare colon.
                     if Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First and then Value = ""
                       and then Name'Length > 12 and then Name (Name'Last - 11 .. Name'Last) = ".write_specs"
                     then
                        return "(granted, in " & Model_Runner.Framework.Permissions.Specification_Places & ")";
                     elsif Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First and then Value = "" then
                        return "(granted, no limits)";
                     elsif not (Name'Length > 4 and then Name (Name'First .. Name'First + 3) in "set." | "list")
                     then
                        return Value;
                     end if;
                     declare
                        Result : Unbounded_String;
                        Start  : Positive := Value'First;
                     begin
                        for Index in Value'First .. Value'Last + 1 loop
                           --  A set's items are words: a space parts them as a
                           --  comma does, however they were written.
                           if Index > Value'Last or else Value (Index) in ASCII.LF | ASCII.HT | ','
                             or else (Value (Index) = ' ' and then Name (Name'First .. Name'First + 3) = "set.")
                           then
                              declare
                                 Item : constant String :=
                                   Ada.Strings.Fixed.Trim (Value (Start .. Index - 1), Ada.Strings.Both);
                              begin
                                 if Item /= "" then
                                    --  A list's items in order, a comma apart, as
                                    --  a set's are: on the one line.
                                    Append (Result, (if Result = Null_Unbounded_String then "" else ", ") & Item);
                                 end if;
                              end;
                              Start := Index + 1;
                           end if;
                        end loop;
                        return To_String (Result);
                     end;
                  end Shown;

                  --  A kind's or a role's grant the project above withholds:
                  --  what it gives is nothing, said beside what it says.
                  function Withheld_Note return String is
                     package Pm renames Model_Runner.Framework.Permissions;
                     Dot     : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
                     Word    : constant String := (if Dot = 0 then "" else Name (Dot + 1 .. Name'Last));
                     Kind    : constant String :=
                       (if Ada.Strings.Fixed.Index (Name, "map.permission.kind.") = Name'First and then Dot > 20
                        then Name (Name'First + 20 .. Dot - 1) else "");
                  begin
                     if Kind = "" or else Value in "off" | "inherit" then
                        return "";
                     end if;
                     --  What the kind ends with, the project's narrowing and
                     --  all: nothing, though it says something.
                     declare
                        Ends_With : constant Pm.Permission_Set :=
                          Pm.Effective (Store, Kind, "", Within_Sandbox => False);
                     begin
                        for One in Pm.Capability loop
                           if Pm.Word (One) = Word and then not Ends_With (One).Granted then
                              return " (the project above narrows " & Word & " so that it gives none here)";
                           end if;
                        end loop;
                     end;
                     return "";
                  end Withheld_Note;

                  --  The agents' bound set, where the project's own grant is
                  --  lower: the lower is what an agent meets, said beside it.
                  function Bound_Note return String is
                     package Pm renames Model_Runner.Framework.Permissions;
                     Present : Boolean;
                     Grant   : constant Pm.Permission_Set := Pm.Level_Of (Config, "project", Present);
                     Granted : constant Natural :=
                       (if Name = "scalar.agents.max_children" then Grant (Pm.Create_Children).Max_Children
                        elsif Name = "scalar.agents.max_depth" then Grant (Pm.Create_Children).Max_Depth
                        else Natural'Last);
                  begin
                     if Granted = Natural'Last or else not Grant (Pm.Create_Children).Granted
                       or else Value'Length not in 1 .. 6 or else not (for all C of Value => C in '0' .. '9')
                       or else Granted >= Natural'Value (Value)
                     then
                        return "";
                     end if;
                     return " (the project's create_children grants " & Image (Granted)
                       & ", and an agent meets the lower: " & Image (Granted) & ")";
                  end Bound_Note;
               begin
                  --  Those NAME names, when one is given.
                  if (Name'Length < 5 or else Name (Name'First .. Name'First + 4) /= "file.")
                    and then Asked (Name)
                    and then In_Area (Name, Area)
                    --  A level's inherited capabilities are said together below.
                    and then not (Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First
                                  and then Value = "inherit")
                  then
                     --  An input is what /init was given: the settings it made
                     --  may have been changed since, and are shown as they are.
                     Field (Name, (if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "input."
                                   then Shown & " (given at /init" & Since_Init (Name, Value) & ")"
                                   elsif Ruled.Contains (Name)
                                   then Shown & " (" & Ruled (Name)
                                        & (if Agrees (Ruled (Name), Value)
                                           then ")"
                                           else "; they disagree -- /check consistency says how to settle it)")
                                   else Shown & Bound_Note & Withheld_Note),
                            --  Ruled on, and agreeing, apart from a default;
                            --  disagreeing, as something gone wrong.
                            (if not Ruled.Contains (Name)
                               or else (Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "input.")
                             then Pres.Plain
                             elsif Agrees (Ruled (Name), Value)
                             then Pres.Good
                             else Pres.Bad));
                  end if;
               end;
            end loop;
            --  The settings the harness reads that are not set: there, with
            --  what holds for them, so the whole is the whole.
            if Argument (1) = "" then
               for Known of Model_Runner.Framework.Configurations.Known_Names loop
                  if not R.Has (Config, Known) and then In_Area (Known, Area) then
                     Field (Known, "(not set: "
                            & (if Model_Runner.Framework.Configurations.Default_Of (Known) = ""
                               then "nothing holds it"
                               else Model_Runner.Framework.Configurations.Default_Of (Known)) & ")",
                            Pres.Muted);
                  end if;
               end loop;
            end if;
            if Area in "permissions" | "all" then
               --  Each permission level the configuration names: what it takes
               --  from the level above in one line, and each capability it does
               --  not grant said, not left to be missed.
               declare
                  package Pm renames Model_Runner.Framework.Permissions;
                  Levels : Names.Vector;
               begin
                  for Index in 1 .. R.Field_Count (Config) loop
                     declare
                        Name : constant String := R.Field_Name (Config, Index);
                        Rest : constant String :=
                          (if Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First
                           then Name (Name'First + 15 .. Name'Last) else "");
                        Dot  : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
                     begin
                        if Dot > Rest'First and then not Levels.Contains (Rest (Rest'First .. Dot - 1)) then
                           Levels.Append (Rest (Rest'First .. Dot - 1));
                        end if;
                     end;
                  end loop;
                  for Level of Levels loop
                     declare
                        Whole     : constant String := "map.permission." & Level;
                        Inherited : Unbounded_String;
                        Withheld  : Unbounded_String;
                        Above     : constant Pm.Permission_Set := Pm.Effective (Store, "", "", Within_Sandbox => False);
                     begin
                        if Asked (Whole) then
                           for One in Pm.Capability loop
                              declare
                                 Field : constant String := Whole & "." & Pm.Word (One);
                              begin
                                 --  Inherited from a level that withholds it is
                                 --  not had: said apart.
                                 if R.Get (Config, Field) = "inherit" and then Level /= "project"
                                   and then not Above (One).Granted
                                 then
                                    Append (Withheld, (if Withheld = Null_Unbounded_String then "" else ", ")
                                                      & Pm.Word (One) & " (withheld above)");
                                 elsif R.Get (Config, Field) = "inherit" then
                                    Append (Inherited, (if Inherited = Null_Unbounded_String then "" else ", ")
                                                       & Pm.Word (One));
                                 elsif not R.Has (Config, Field) then
                                    Append (Withheld, (if Withheld = Null_Unbounded_String then "" else ", ")
                                                      & Pm.Word (One));
                                 end if;
                              end;
                           end loop;
                           if Withheld /= Null_Unbounded_String then
                              Field (Whole & " withholds", To_String (Withheld));
                           end if;
                           if Inherited /= Null_Unbounded_String then
                              Field (Whole & " inherits",
                                     To_String (Inherited)
                                     & (if Level = "project" then " (the defaults)" else " (from the level above)"));
                           end if;
                        end if;
                     end;
                  end loop;
               end;
            end if;
            if Area in "permissions" | "all" then
               --  The project's permissions where the configuration says none:
               --  what agents are given all the same.
               if (Argument (1) = "" or else Ada.Strings.Fixed.Index ("map.permission.project", Argument (1)) > 0)
                 and then not (for some Index in 1 .. R.Field_Count (Config) =>
                                 Ada.Strings.Fixed.Index (R.Field_Name (Config, Index),
                                                          "map.permission.project") = 1)
               then
                  declare
                     Given : Unbounded_String;
                  begin
                     for Line of Model_Runner.Framework.Lines_Of
                       (Model_Runner.Framework.Permissions.Image
                          (Model_Runner.Framework.Permissions.Effective
                             (Store, "", "", Within_Sandbox => False)))
                     loop
                        Append (Given, (if Given = Null_Unbounded_String then "" else "; ") & Line);
                     end loop;
                     Field ("map.permission.project", "(the default) " & To_String (Given));
                  end;
               end if;
            end if;
            if Area in "components" | "all" then
               --  The components tasks may name, however each was declared:
               --  listed in set.components or placed with map.component.
               if Argument (1) = "" or else Ada.Strings.Fixed.Index ("components", Argument (1)) > 0 then
                  declare
                     Named : Unbounded_String;
                  begin
                     for One of Tk.Components (Store) loop
                        Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & One);
                     end loop;
                     Field ("components (listed or placed)", To_String (Named));
                     --  Open tasks that name a component the project no longer has.
                     declare
                        Stray : Unbounded_String;
                     begin
                        for Id of Tk.List (Store) loop
                           declare
                              Defined : R.Item;
                              Got     : E.Error_Info;
                           begin
                              Tk.Definition (Store, Id, Defined, Got);
                              if E.Is_Ok (Got) and then R.Get (Defined, "component") /= ""
                                and then not Tk.Components (Store).Contains (R.Get (Defined, "component"))
                                and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                              then
                                 Append (Stray, (if Stray = Null_Unbounded_String then "" else ", ")
                                         & Id & " in " & R.Get (Defined, "component"));
                              end if;
                           end;
                        end loop;
                        if Stray /= Null_Unbounded_String then
                           Field ("tasks in no component of the project", To_String (Stray));
                        end if;
                     end;
                  end;
               end if;
            end if;
         end loop;

         --  Settings a name picks out that are not set: said so, as they
         --  mean something unset too.
         if Argument (1) /= "" then
            for Known of Model_Runner.Framework.Configurations.Known_Names loop
               if Ada.Strings.Fixed.Index (Known, Argument (1)) > 0 and then not R.Has (Config, Known)
               then
                  --  Not set, and what that means. The agents' bounds hold
                  --  with the project's create_children grant below them,
                  --  and the lower of the two is what an agent meets.
                  declare
                     Default : constant String :=
                       Model_Runner.Framework.Configurations.Default_Of (Known);
                     package Pm renames Model_Runner.Framework.Permissions;
                     Grant   : constant Pm.Permission_Set :=
                       Pm.Effective (Store, "", "", Within_Sandbox => False);
                     Granted : constant Natural :=
                       (if Known = "scalar.agents.max_children"
                        then Grant (Pm.Create_Children).Max_Children
                        elsif Known = "scalar.agents.max_depth"
                        then Grant (Pm.Create_Children).Max_Depth
                        else Natural'Last);
                  begin
                     Field (Known,
                            (if Default = "" then "(not set: nothing holds it)"
                             else "(not set: " & Default
                                  & (if Granted /= Natural'Last and then Grant (Pm.Create_Children).Granted
                                       and then (for all C of Default => C in '0' .. '9')
                                     then "; the project's create_children grants "
                                          & Image (Granted) & ", and an agent meets the lower: "
                                          & Image (Natural'Min (Granted, Natural'Value (Default)))
                                     else "")
                                  & ")"));
                  end;
               end if;
            end loop;
            --  A setting each kind may have its own of, none set for what is
            --  asked: said what holds instead, not that there is no such
            --  setting -- and a kind the project has not, said so.
            for Family of Names.Vector'
              (["task.max_seconds", "task.max_tool_calls", "task.max_steps", "task.token_budget",
                "task.coordination", "task.profile", "permission.kind"])
            loop
               if ((Argument (1)'Length >= 8 and then Ada.Strings.Fixed.Index (Family, Argument (1)) > 0)
                   or else Ada.Strings.Fixed.Index (Argument (1), Family) > 0)
                 and then not (for some Index in 1 .. R.Field_Count (Config) =>
                                 Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Argument (1)) > 0)
               then
                  declare
                     At_Family : constant Natural := Ada.Strings.Fixed.Index (Argument (1), Family & ".");
                     Kind      : constant String :=
                       (if At_Family = 0 then ""
                        else Argument (1) (At_Family + Family'Length + 1 .. Argument (1)'Last));
                     Bare_Kind : constant String :=
                       (if Ada.Strings.Fixed.Index (Kind, ".") > 0
                        then Kind (Kind'First .. Ada.Strings.Fixed.Index (Kind, ".") - 1) else Kind);
                  begin
                     if Bare_Kind /= "" and then not Tk.Kinds (Store).Contains (Bare_Kind) then
                        Field (Argument (1), "(no kind of task is called " & Bare_Kind & "; they are "
                               & Joined_Names (Tk.Kinds (Store)) & ")");
                     else
                        Field ((if Family = "permission.kind" then "map." else "scalar.") & Family
                               & (if Bare_Kind = "" then ".KIND" else "." & Bare_Kind),
                               (if Family = "permission.kind"
                                then "(not set" & (if Bare_Kind = "" then " for any kind" else "")
                                     & ": the kind takes the project's permissions)"
                                elsif Family = "task.profile"
                                then "(not set" & (if Bare_Kind = "" then " for any kind" else "")
                                     & ": verification.default is what checks it)"
                                else "(not set" & (if Bare_Kind = "" then " for any kind" else "")
                                     & ": agents." & Family (Family'First + 5 .. Family'Last) & " holds)"));
                     end if;
                  end;
                  return;
               end if;
            end loop;
            --  A name nothing holds: said, not answered with nothing.
            if not (for some Index in 1 .. R.Field_Count (Config) =>
                      Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Argument (1)) > 0)
              and then not (for some Known of Model_Runner.Framework.Configurations.Known_Names =>
                              Ada.Strings.Fixed.Index (Known, Argument (1)) > 0)
              and then Ada.Strings.Fixed.Index ("components", Argument (1)) = 0
              and then Ada.Strings.Fixed.Index ("map.permission.project", Argument (1)) = 0
            then
               Pres.Put_Message (Screen, "cli.project.config_none", [Loc.Named ("value", Argument (1))]);
            end if;
         end if;
      end Show_Config;

      procedure Show_Result (Store : in out S.Store) is
         package Rs renames Model_Runner.Framework.Results;
         Held  : Rs.Result;
         Read  : E.Error_Info;
         Size  : constant Natural := Rs.Payload_Size (Store, Argument (1));
         --  A large payload is read only when asked for: /result ID full.
         Whole : constant Boolean := Size <= Rs.Inline_Limit or else Argument (2) = "full";
         --  As the harness writes it: ag-000001 is AG-000001, and AG-1 is
         --  AG-000001 where its kind is numbered so.
         function Normalized (Given : String) return String is
            Upper : constant String := Ada.Characters.Handling.To_Upper (Given);
            Dash  : constant Natural := Ada.Strings.Fixed.Index (Upper, "-");
         begin
            if Dash = 0 or else Upper (Upper'First .. Dash - 1) not in "AG" | "INV" | "VER" | "RES" | "CTX"
            then
               return Given;
            end if;
            declare
               Rest : constant String := Upper (Dash + 1 .. Upper'Last);
            begin
               if Upper (Upper'First .. Dash - 1) in "AG" | "INV" | "VER"
                 and then Rest'Length in 1 .. 5 and then (for all C of Rest => C in '0' .. '9')
               then
                  return Upper (Upper'First .. Dash) & [1 .. 6 - Rest'Length => '0'] & Rest;
               end if;
               return Upper;
            end;
         end Normalized;
         --  A result by the start of its identifier, where one alone
         --  begins so: RES-F510 or F510 is RES-F510869C5653C6C4.
         --  A start that several results begin with: those, as said.
         Several : Unbounded_String;

         function Unique (Given : String) return String is
            Upper : constant String := Ada.Characters.Handling.To_Upper (Given);
            Whole : constant String :=
              (if Upper'Length >= 4 and then Upper (Upper'First .. Upper'First + 3) = "RES-" then Upper
               else "RES-" & Upper);
            Found : Unbounded_String;
            Count : Natural := 0;
         begin
            --  Only a start of a result's identifier is looked for: hex
            --  digits, with RES- or without.
            if Given = "" or else S.Exists (Store, Model_Runner.Framework.Results_Area, Given)
              or else not (for all C of Whole (Whole'First + 4 .. Whole'Last) => C in '0' .. '9' | 'A' .. 'F')
            then
               return Given;
            end if;
            for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
               if Name'Length >= Whole'Length and then Name (Name'First .. Name'First + Whole'Length - 1) = Whole
               then
                  Count := Count + 1;
                  Found := To_Unbounded_String
                    (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                     then Name (Name'First .. Name'Last - 4) else Name);
                  if Count <= 5 then
                     Append (Several, (if Count = 1 then "" else ", ") & To_String (Found));
                  end if;
               end if;
            end loop;
            if Count > 1 then
               Several := To_Unbounded_String (Given & " is the start of" & Natural'Image (Count)
                                               & " results -- " & To_String (Several)
                                               & (if Count > 5 then ", ..." else "")
                                               & "; give more of the one meant");
            else
               Several := Null_Unbounded_String;
            end if;
            return (if Count = 1 then To_String (Found) else Given);
         end Unique;

         Id    : constant String := Unique (Normalized (Argument (1)));
         Asked_Several : constant Unbounded_String := Several;

         function Task_Of (One : Rs.Result) return String
         is (Task_Of_Issue (Store, One));

         --  Any identifier the harness prints: an invocation, a context's
         --  manifest, evidence or an agent is shown as it is recorded.
         function Starts (Prefix : String) return Boolean
         is (Id'Length > Prefix'Length and then Id (Id'First .. Id'First + Prefix'Length - 1) = Prefix);

         procedure Show_Record (Where : Model_Runner.Framework.Area; Name : String) is
            Value : R.Item;
         begin
            S.Read (Store, Where, Name, Value, Read);
            if E.Is_Error (Read) and then not S.Exists (Store, Where, Name) then
               --  Named as it was asked for, not as it is kept.
               Read := E.Make (E.Framework_Not_Found);
               E.Add_Text (Read, "name", Id);
            end if;
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
               return;
            end if;
            for Index in 1 .. R.Field_Count (Value) loop
               declare
                  Named : constant String := R.Field_Name (Value, Index);
               begin
                  --  A check's columns by what each is; other columns a tab
                  --  apart shown as columns.
                  if Named'Length > 6 and then Named (Named'First .. Named'First + 5) = "check."
                  then
                     declare
                        function Split_Cells (Text : String) return Names.Vector is
                           Result : Names.Vector;
                           Start  : Positive := Text'First;
                        begin
                           for Index in Text'First .. Text'Last + 1 loop
                              if Index > Text'Last or else Text (Index) = ASCII.HT then
                                 Result.Append (Ada.Strings.Fixed.Trim
                                                  (Text (Start .. Index - 1), Ada.Strings.Both));
                                 Start := Index + 1;
                              end if;
                           end loop;
                           return Result;
                        end Split_Cells;
                        Cells : constant Names.Vector := Split_Cells (R.Get (Value, Named));
                        function Cell (At_Index : Positive) return String
                        is (if Natural (Cells.Length) >= At_Index then Cells (At_Index) else "");
                     begin
                        Field (Named, Cell (1) & ": " & Cell (5)
                               & " (exit " & Cell (3)
                               & ", " & Cell (4) & " s, " & Cell (6)
                               & (if Cell (8) = "warning" then ", a warning" else "")
                               & (if Cell (9) not in "" | "1" then ", tries " & Cell (9) else "")
                               & ")" & (if Cell (7) = "" then "" else "; log " & Cell (7))
                               & (if Cell (2) = "" then "" else "; ran " & Cell (2)));
                     end;
                  elsif Named = "summary" and then R.Has (Value, "depth") and then R.Get (Value, Named) = ""
                  then
                     Field (Named, "(it gave none)");
                  elsif Named = "permissions" and then R.Has (Value, "depth") then
                     --  An agent's: a line each, and create_children said
                     --  spent where its depth leaves it none.
                     declare
                        Depth : constant Natural :=
                          Natural'Value ("0" & R.Get (Value, "depth"));
                        Shown : Unbounded_String;
                     begin
                        for Line of Model_Runner.Framework.Lines_Of (R.Get (Value, Named)) loop
                           declare
                              Mark  : constant Natural := Ada.Strings.Fixed.Index (Line, "max_depth=");
                              Limit : Natural := Natural'Last;
                              Stop  : Natural;
                           begin
                              if Ada.Strings.Fixed.Index (Line, "create_children") = Line'First
                                and then Mark > 0
                              then
                                 Stop := Mark + 10;
                                 while Stop <= Line'Last and then Line (Stop) in '0' .. '9' loop
                                    Stop := Stop + 1;
                                 end loop;
                                 if Stop > Mark + 10 then
                                    Limit := Natural'Value (Line (Mark + 10 .. Stop - 1));
                                 end if;
                              end if;
                              if Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) /= "" then
                                 Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ")
                                         & Line
                                         & (if Depth >= Limit then " (none at its depth)" else ""));
                              end if;
                           end;
                        end loop;
                        Field (Named, To_String (Shown));
                     end;
                  elsif Named not in "schema_id" | "schema_version" | "entity_id" | "revision" then
                     Field (Named, Ada.Strings.Fixed.Translate
                                     (R.Get (Value, Named),
                                      Ada.Strings.Maps.To_Mapping ([1 => ASCII.HT], " ")));
                  end if;
               end;
            end loop;
            --  An agent's two ends told apart where they differ.
            if R.Has (Value, "outcome") and then R.Has (Value, "state")
              and then R.Get (Value, "outcome") /= R.Get (Value, "state")
            then
               Field ("read as", "state is how its own run ended; outcome is where that left the task");
            end if;
         end Show_Record;
      begin
         --  A start several begin with: which, asked.
         if Asked_Several /= Null_Unbounded_String then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the result");
            E.Add_Text (Outcome, "value", Argument (1));
            E.Add_Text (Outcome, "detail", To_String (Asked_Several));
            Pres.Report (Screen, Outcome);
            return;
         end if;

         --  result dismiss ID: an issue a person has taken as read leaves the
         --  listing; the result itself is kept.
         if Id = "dismiss" then
            declare
               Named   : constant String := Unique (Argument (2));
               Ambiguous : constant Unbounded_String := Several;
               Kept    : constant String :=
                 Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "dismissed");
               Got     : Rs.Result;
            begin
               Rs.Read (Store, Named, Got, Read, With_Payload => False);
               --  all: every issue the listing shows, each as if named.
               if Ada.Characters.Handling.To_Lower (Argument (2)) = "all" then
                  declare
                     Count : Natural := 0;
                     Counted : Names.Vector;
                     File  : Ada.Text_IO.File_Type;
                     Dismissed : constant Names.Vector := Dismissed_List (Store);
                  begin
                     if Ada.Directories.Exists (Kept) then
                        Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Kept);
                     else
                        Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
                     end if;
                     for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
                        declare
                           Result_Id : constant String :=
                             (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                              then Name (Name'First .. Name'Last - 4) else Name);
                           One : Rs.Result;
                           Had : E.Error_Info;
                        begin
                           Rs.Read (Store, Result_Id, One, Had);
                           --  What the listing shows, counted as it shows it:
                           --  one said twice in the same words is one.
                           if E.Is_Ok (Had) and then Rs."=" (One.Kind, Rs.Diagnostic)
                             and then not Dismissed.Contains (Result_Id)
                             and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                             and then not (Task_Of (One) /= ""
                                           and then Tk.State_Of (Store, Task_Of (One))
                                                      in "accepted" | "running" | "verification" | "complete"
                                                       | "cancelled" | "rejected")
                           then
                              Ada.Text_IO.Put_Line (File, Result_Id);
                              if not Counted.Contains (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
                              then
                                 Counted.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                                 Count := Count + 1;
                              end if;
                           end if;
                        end;
                     end loop;
                     Ada.Text_IO.Close (File);
                     Pres.Put_Message (Screen, "cli.result.dismissed_all",
                                       [Loc.Named ("count", Image (Count))]);
                  end;
                  return;
               end if;
               if Ambiguous /= Null_Unbounded_String then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "the issue to dismiss");
                  E.Add_Text (Outcome, "value", Argument (2));
                  E.Add_Text (Outcome, "detail", To_String (Ambiguous));
                  Pres.Report (Screen, Outcome);
                  return;
               elsif Named = "" then
                  Outcome := E.Make (E.Framework_Input_Missing);
                  E.Add_Text (Outcome, "name", "the issue to dismiss: /result dismiss RES-ID, as result"
                              & " lists them");
                  Pres.Report (Screen, Outcome);
                  return;
               elsif Dismissed_List (Store).Contains (Named) then
                  Pres.Put_Note (Screen, "cli.result.dismissed_already", [Loc.Named ("name", Named)]);
                  return;
               elsif Named /= ""
                 and then (E.Is_Ok (Read) or else Ada.Strings.Fixed.Index (Named, "-") > Named'First)
                 and then (E.Is_Error (Read) or else not Rs."=" (Got.Kind, Rs.Diagnostic))
                 and then Ada.Strings.Fixed.Index (Named, "RES-") /= Named'First
               then
                  --  Something else the harness names: not an issue.
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "the issue to dismiss");
                  E.Add_Text (Outcome, "value", Named);
                  E.Add_Text (Outcome, "detail", Named & " is not an issue; /result lists the issues");
                  Pres.Report (Screen, Outcome);
                  return;
               elsif Named = "" or else E.Is_Error (Read) then
                  Outcome := E.Make (E.Framework_Not_Found);
                  E.Add_Text (Outcome, "name", (if Named = "" then "the issue to dismiss" else Named));
                  Pres.Report (Screen, Outcome);
                  return;
               end if;
               declare
                  File : Ada.Text_IO.File_Type;
               begin
                  if Ada.Directories.Exists (Kept) then
                     Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Kept);
                  else
                     Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
                  end if;
                  Ada.Text_IO.Put_Line (File, Named);
                  Ada.Text_IO.Close (File);
               end;
               Pres.Put_Message (Screen, "cli.result.dismissed", [Loc.Named ("name", Named)]);
            end;
            return;
         end if;

         if Id = "" then
            --  None named: the issues kept -- what bootstrap raised, what
            --  agents reported -- each by its identifier and what it says;
            --  not a command's output, which its evidence shows, and not
            --  one about an entry since retired or replaced: acted on.
            declare
               Shown : Natural := 0;
               Said_Before : Names.Vector;

               Dismissed : constant Names.Vector := Dismissed_List (Store);

               --  Each as WHEN TAB ID TAB LINE, to be said newest first.
               Listed : Names.Vector;
               package Listed_Sorting is new Names.Generic_Sorting;
            begin
               for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
                  declare
                     Result_Id : constant String :=
                       (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                        then Name (Name'First .. Name'Last - 4) else Name);
                     One       : Rs.Result;
                     Got       : E.Error_Info;
                  begin
                     Rs.Read (Store, Result_Id, One, Got);
                     if E.Is_Ok (Got) and then Rs."=" (One.Kind, Rs.Diagnostic)
                       and then not Dismissed.Contains (Result_Id)
                       and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                       --  An attempt's issue whose task was taken up again
                       --  since, or ended: acted on.
                       and then not (Task_Of (One) /= ""
                                     and then Tk.State_Of (Store, Task_Of (One))
                                                in "accepted" | "running" | "verification" | "complete"
                                                 | "cancelled" | "rejected")
                       --  Said the same, in the same words, once: two attempts
                       --  that report one thing are one issue here.
                       and then not Said_Before.Contains
                                      (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
                     then
                        Said_Before.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                        Listed.Append (To_String (One.Created_At) & ASCII.HT & Result_Id & ASCII.HT
                                       & (if Task_Of (One) /= ""
                                            and then Ada.Strings.Fixed.Index
                                                       (To_String (One.Summary), Task_Of (One)) = 0
                                          then Task_Of (One) & ": " else "")
                                       & With_Id (Result_Id, To_String (One.Summary)));
                        Shown := Shown + 1;
                     end if;
                  end;
               end loop;
               Listed_Sorting.Sort (Listed);
               for One of reverse Listed loop
                  declare
                     First_Tab  : constant Natural := Ada.Strings.Fixed.Index (One, [1 => ASCII.HT]);
                     Second_Tab : constant Natural :=
                       Ada.Strings.Fixed.Index (One (First_Tab + 1 .. One'Last), [1 => ASCII.HT]);
                  begin
                     Field (One (First_Tab + 1 .. Second_Tab - 1), One (Second_Tab + 1 .. One'Last));
                  end;
               end loop;
               if Shown = 0 then
                  Pres.Put_Message (Screen, "cli.result.none");
               else
                  Pres.Put_Note (Screen, "cli.next.result_dismiss");
               end if;
            end;
            return;
         elsif (Starts ("TASK-") and then Tk.State_Of (Store, Id) = "")
           or else (Starts ("REQ-") and then Nt.State_Of (Store, Nt.Requirement, Id) = "")
           or else (Starts ("DEC-") and then Nt.State_Of (Store, Nt.Decision, Id) = "")
           or else (Starts ("SPEC-") and then Nt.State_Of (Store, Nt.Specification, Id) = "")
         then
            Read := E.Make (E.Framework_Not_Found);
            E.Add_Text (Read, "name", Id);
            Pres.Report (Screen, Read);
            return;
         elsif Starts ("TASK-") or else Starts ("REQ-") or else Starts ("DEC-") or else Starts ("SPEC-")
         then
            Pres.Put_Note
              (Screen, "cli.result.elsewhere",
               [Loc.Named ("name", Id),
                Loc.Named ("value", (if Starts ("TASK-") then "/task show " & Id & " and /task audit " & Id
                                     elsif Starts ("REQ-") then "/req show " & Id
                                     elsif Starts ("DEC-") then "/decision show " & Id
                                     else "/spec show " & Id))]);
            return;
         elsif Starts ("INV-") then
            Show_Record (Model_Runner.Framework.Invocations_Area, Id);
            return;
         elsif Starts ("CTX-") then
            Show_Record (Model_Runner.Framework.Invocations_Area, "manifest." & Id);
            return;
         elsif Starts ("VER-") then
            Show_Record (Model_Runner.Framework.Verification_Area, Id);
            return;
         elsif Starts ("AG-") then
            Show_Record (Model_Runner.Framework.Runtime_Area, "agent." & Id);
            return;
         end if;
         Rs.Read (Store, Id, Held, Read, With_Payload => Whole);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         --  In groups, as /task show is: what it is, what it says, and
         --  where it came from.
         Sectioned := True;
         Pres.Put_Header (Screen, "cli.result.heading", [Loc.Named ("name", Id)]);
         Pres.Put_Section (Screen, "cli.result.section.what");
         Field ("kind", Rs.Kind_Word (Held.Kind));
         Field ("producer", To_String (Held.Producer));
         Field ("created_at", To_String (Held.Created_At));
         if Dismissed_List (Store).Contains (Id) then
            Field ("dismissed", "yes: /result no longer lists it");
         end if;
         Pres.Put_Section (Screen, "cli.result.section.says");
         Field ("summary", With_Id (Id, To_String (Held.Summary)));
         --  Whole, as it is: a line at a time, not cut to fit a message.
         if Whole and then Pres.Is_Structured (Screen) then
            Field ("payload", To_String (Held.Payload));
         elsif Whole then
            Field ("payload", "");
            for Line of Model_Runner.Framework.Lines_Of (To_String (Held.Payload)) loop
               --  JSON coloured as JSON where colour shows.
               Pres.Put_Line (Screen, "      "
                                      & (if Pres.Styles_Answers (Screen)
                                           and then Pres.Looks_Like_JSON (To_String (Held.Payload))
                                         then Pres.JSON_Coloured (Line) else Line));
            end loop;
         else
            Field ("payload", "(" & Image (Size) & " bytes; /result " & Argument (1)
                   & " full shows them)");
         end if;
         Pres.Put_Section (Screen, "cli.result.section.from");
         --  What it came from, without an empty part before its colon.
         Field ("provenance", Ada.Strings.Fixed.Trim (To_String (Held.Provenance),
                                                      Ada.Strings.Maps.To_Set (": "), Ada.Strings.Maps.Null_Set));
         for Other of Model_Runner.Framework.Lines_Of (To_String (Held.References)) loop
            Field ("references", Other);
         end loop;
         Sectioned := False;
         --  An issue still open: how to let it go.
         if Rs."=" (Held.Kind, Rs.Diagnostic) and then not Dismissed_List (Store).Contains (Id) then
            Pres.Put_Note (Screen, "cli.next.result_dismiss_one", [Loc.Named ("name", Id)]);
         end if;
      end Show_Result;

      --  The project's verification, now, for no task in particular.
      procedure Check (Store : in out S.Store) is
         Config   : R.Item;
         Read     : E.Error_Info;
         Change   : S.Transaction;
      begin
         --  A requirement: the tasks serving it verified again, the
         --  requirement itself where the project has a profile for that,
         --  and where it stands then -- with what it still lacks.
         if Argument (1)'Length > 4
           and then Argument (1) (Argument (1)'First .. Argument (1)'First + 3) = "REQ-"
         then
            declare
               package Vf renames Model_Runner.Framework.Verification;
               package Tk renames Model_Runner.Framework.Tasks;
               Requirement : constant String := Argument (1);
               Held        : Model_Runner.Framework.Intent.Entity;
               Got         : E.Error_Info;
               Evidence    : Unbounded_String;
               Passed      : Boolean;
               Changed     : Names.Vector;
               Failing     : Names.Vector;
            begin
               Model_Runner.Framework.Intent.Read
                 (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Got);
               if E.Is_Error (Got) then
                  Pres.Report (Screen, Got);
                  return;
               end if;
               --  Retired: nothing to verify, and its replacement named.
               if To_String (Held.State) in "obsolete" | "rejected" | "superseded" then
                  Got := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Got, "name", "the requirement to check");
                  E.Add_Text (Got, "value", Requirement);
                  E.Add_Text (Got, "detail", Requirement & " is " & To_String (Held.State)
                              & (if Held.Superseded_By /= Null_Unbounded_String
                                 then ", replaced by " & To_String (Held.Superseded_By) & ": check "
                                      & To_String (Held.Superseded_By) & " verifies that one"
                                 else ", and what is retired is not verified"));
                  Pres.Report (Screen, Got);
                  return;
               end if;
               for Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                  begin
                     Tk.Definition (Store, Id, Defined, Got);
                     if E.Is_Ok (Got)
                       and then Model_Runner.Framework.Lines_Of
                                  (R.Get (Defined, "requirements")).Contains (Requirement)
                       and then Tk.State_Of (Store, Id) = "complete"
                       and then Vf.Profile_Of (Store, Id) /= ""
                     then
                        Vf.Run_Profile (Store, Change, Vf.Profile_Of (Store, Id), Id, Evidence,
                                        Passed, Got);
                        if E.Is_Ok (Got) then
                           S.Commit (Store, Change, Got);
                           Field (Id, To_String (Evidence) & (if Passed then " passed" else " failed"));
                           if not Passed then
                              Failing.Append (To_String (Evidence));
                           end if;
                        end if;
                     end if;
                  end;
               end loop;
               Vf.Verify_Requirement (Store, Change, Requirement, Evidence, Passed, Got);
               if E.Is_Ok (Got) then
                  S.Commit (Store, Change, Got);
                  Field (Requirement, To_String (Evidence) & (if Passed then " passed" else " failed"));
                  if not Passed then
                     Failing.Append (To_String (Evidence));
                  end if;
               end if;
               Change := S.No_Changes;
               Vf.Reevaluate_Requirements (Store, Change, Changed, Got);
               S.Commit (Store, Change, Got);
               Model_Runner.Framework.Intent.Read
                 (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Got);
               Field ("state", To_String (Held.State));
               --  The others the checks moved, each named as what it is: a
               --  side effect of the same evidence, not what was asked.
               for Other of Changed loop
                  if Other /= Requirement then
                     Pres.Put_Note
                       (Screen, "cli.work.requirement_also",
                        [Loc.Named ("name", Other),
                         Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Other))]);
                  end if;
               end loop;
               --  Its checks passed and it is not verified: said as what it
               --  is -- not a check that failed -- with what it waits for,
               --  and the command ends without success all the same.
               if To_String (Held.State) /= "verified" and then Failing.Is_Empty then
                  Pres.Put_Message
                    (Screen, "cli.check.passed_not_verified",
                     [Loc.Named ("name", Requirement),
                      Loc.Named ("detail", Vf.Why_Not_Verified (Store, Requirement))]);
                  Last_Status := E.Exit_Status (E.Make (E.Framework_Verification_Failed));
               elsif To_String (Held.State) /= "verified" then
                  Field ("not verified", Vf.Why_Not_Verified (Store, Requirement));
               end if;

               --  Checks that did not pass: a failure, with why.
               for Evidence_Id of Failing loop
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                     Why    : Unbounded_String;
                  begin
                     for Line of Vf.Why_Failed (Store, Evidence_Id) loop
                        Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Line);
                     end loop;
                     E.Add_Text (Failed, "name", Evidence_Id);
                     E.Add_Text (Failed, "detail", To_String (Why));
                     Pres.Report (Screen, Failed);
                  end;
               end loop;
            end;
            return;
         end if;

         --  The state itself, not the project's files: what does not hold
         --  together, found without a model.
         if Argument (1) = "consistency" and then Argument (2) /= "" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "/check consistency");
            E.Add_Text (Outcome, "value", Argument (2));
            E.Add_Text (Outcome, "detail", "it only lists what does not hold together; nothing"
                        & " follows it");
            Pres.Report (Screen, Outcome);
            return;
         elsif Argument (1) = "consistency" then
            declare
               package Cs renames Model_Runner.Framework.Consistency;
               Found : constant Cs.Finding_List := Cs.Check (Store);
            begin
               for Index in 1 .. Cs.Length (Found) loop
                  --  What does not hold together, its kind in the colour of
                  --  something gone wrong.
                  Pres.Put_Marked
                    (Screen, "cli.task.item",
                     [Loc.Named ("name", To_String (Cs.Element (Found, Index).Subject)),
                      Loc.Named ("value", Cs.Kind_Word (Cs.Element (Found, Index).Kind)),
                      Loc.Named ("detail", To_String (Cs.Element (Found, Index).Detail))],
                     Cs.Kind_Word (Cs.Element (Found, Index).Kind), Pres.Bad);
               end loop;
               Pres.Put_Message
                 (Screen, "cli.project.consistency", [Loc.Named ("count", Image (Cs.Length (Found)))]);

               --  Something that does not hold together is a check that did
               --  not pass.
               if Cs.Length (Found) > 0 then
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                  begin
                     E.Add_Text (Failed, "name", "consistency");
                     E.Add_Text (Failed, "detail", "what does not hold together in the state, listed"
                                 & " above: " & Image (Cs.Length (Found)));
                     Pres.Report (Screen, Failed);
                  end;
               end if;
            end;
            return;
         end if;

         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         declare
            --  The profiles to run: the one named; for full, those the
            --  configuration's list verification.full names; otherwise the
            --  default.
            Profiles : Names.Vector;

            procedure Run_One (Profile : String) is
               Evidence : Unbounded_String;
               Passed   : Boolean;
            begin
               Vf.Run_Profile (Store, Change, Profile, "", Evidence, Passed, Outcome);
               if E.Is_Ok (Outcome) then
                  S.Commit (Store, Change, Outcome);
               end if;
               if E.Is_Error (Outcome) then
                  Pres.Report (Screen, Outcome);
                  return;
               end if;

               declare
                  Said : constant Vf.Diagnostic_List :=
                    Vf.Diagnostics_Of (Store, To_String (Evidence));
               begin
                  for Index in 1 .. Vf.Length (Said) loop
                     Pres.Put_Message
                       (Screen, "cli.task.diagnostic",
                        [Loc.Named ("path",
                                    (if Length (Vf.Element (Said, Index).File) = 0
                                     then "(" & Profile & ")"
                                     else To_String (Vf.Element (Said, Index).File) & ":"
                                          & Image (Vf.Element (Said, Index).Line))),
                         Loc.Named ("severity", To_String (Vf.Element (Said, Index).Severity)),
                         Loc.Named ("detail", To_String (Vf.Element (Said, Index).Message)
                                    & (if Length (Vf.Element (Said, Index).Code) = 0 then ""
                                       else " [" & To_String (Vf.Element (Said, Index).Code)
                                            & "]"))]);
                  end loop;
                  Pres.Put_Message
                    (Screen, "cli.task.verified",
                     [Loc.Named ("name", To_String (Evidence)),
                      Loc.Named ("value", (if Passed then "passed" else "failed")),
                      Loc.Named ("count", Image (Vf.Length
                                   (Vf.Parse_Profile (R.Get (Config, "profile." & Profile))))),
                      Loc.Named ("total", Image (Vf.Length (Said)))]);
               end;

               --  New evidence: the requirements are judged again, and said
               --  after what the checks found.
               declare
                  Changed : Names.Vector;
               begin
                  Vf.Reevaluate_Requirements (Store, Change, Changed, Outcome);
                  if E.Is_Ok (Outcome) then
                     S.Commit (Store, Change, Outcome);
                  end if;
                  for Requirement of Changed loop
                     Pres.Put_Message
                       (Screen, "cli.work.requirement",
                        [Loc.Named ("name", Requirement),
                         Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
                  end loop;
                  Outcome := E.Success;
               end;

               --  A pass of a suite that holds no tests yet: said, so that
               --  it is not read as tests that pass.
               if Passed and then Vf.Found_No_Tests (Store, To_String (Evidence)) then
                  Pres.Put_Note (Screen, "cli.check.no_tests_yet", [Loc.Named ("name", Profile)]);
               end if;

               --  A profile that runs no tests, said so, with what does.
               --  Not when others that run them run with it.
               if R.Get (Config, "scalar.profile_capability." & Profile) /= "run_tests"
                 and then not (for some Other of Profiles =>
                                 R.Get (Config, "scalar.profile_capability." & Other) = "run_tests")
               then
                  Pres.Put_Note (Screen, "cli.check.no_tests", [Loc.Named ("name", Profile)]);
               end if;

               --  Not passed: a failure, with what failed and how it ended.
               if not Passed then
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                     Why    : Unbounded_String;
                  begin
                     for Line of Vf.Why_Failed (Store, To_String (Evidence)) loop
                        Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Line);
                     end loop;
                     E.Add_Text (Failed, "name", To_String (Evidence));
                     E.Add_Text (Failed, "detail", To_String (Why));
                     Pres.Report (Screen, Failed);
                  end;
                  --  Its commands may be the wrong ones: where they are set.
                  Pres.Put_Note (Screen, "cli.check.profile_change",
                                 [Loc.Named ("name", Profile),
                                  Loc.Named ("value", R.Get (Config, "profile." & Profile))]);
               end if;
            end Run_One;
         begin
            if Argument (1) = "full" and then not R.Has (Config, "profile.full") then
               for Name of Model_Runner.Framework.Lines_Of (R.Get (Config, "list.verification.full")) loop
                  if R.Has (Config, "profile." & Name) then
                     Profiles.Append (Name);
                  end if;
               end loop;
            elsif Argument (1) /= "" and then R.Has (Config, "profile." & Argument (1)) then
               Profiles.Append (Argument (1));
            elsif Argument (1) /= "" then
               --  Not one: said with those there are.
               declare
                  Named : Unbounded_String;
               begin
                  for Index in 1 .. R.Field_Count (Config) loop
                     declare
                        Field_Name : constant String := R.Field_Name (Config, Index);
                     begin
                        if Field_Name'Length > 8
                          and then Field_Name (Field_Name'First .. Field_Name'First + 7) = "profile."
                        then
                           Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                                   & Field_Name (Field_Name'First + 8 .. Field_Name'Last));
                        end if;
                     end;
                  end loop;
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "what to check");
                  E.Add_Text (Outcome, "value", Argument (1));
                  E.Add_Text (Outcome, "detail", "it is a profile (" & To_String (Named)
                              & "), full, consistency or a requirement");
                  Pres.Report (Screen, Outcome);
               end;
               return;
            end if;
            if Profiles.Is_Empty and then R.Get (Config, "scalar.verification.default") /= "" then
               Profiles.Append (R.Get (Config, "scalar.verification.default"));
            end if;
            if Profiles.Is_Empty then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "a verification profile -- verification.default names none;"
                           & " /reconfigure verification.default=PROFILE names one");
               Pres.Report (Screen, Outcome);
               return;
            end if;
            --  A profile whose every check another in the list runs too is
            --  not run twice: what it would find, that one finds.
            declare
               function Checks_Of (Profile : String) return Names.Vector is
                  Result : Names.Vector;
                  Parsed : constant Vf.Check_List :=
                    Vf.Parse_Profile (R.Get (Config, "profile." & Profile));
               begin
                  for Index in 1 .. Vf.Length (Parsed) loop
                     Result.Append (To_String (Vf.Element (Parsed, Index).Command));
                  end loop;
                  return Result;
               end Checks_Of;

               Kept : Names.Vector;
            begin
               for Profile of Profiles loop
                  if Checks_Of (Profile).Is_Empty
                    or else not (for some Other of Profiles =>
                            Other /= Profile
                            and then (for all Command of Checks_Of (Profile) =>
                                        Checks_Of (Other).Contains (Command))
                            and then Natural (Checks_Of (Other).Length)
                                       > Natural (Checks_Of (Profile).Length))
                  then
                     Kept.Append (Profile);
                  end if;
               end loop;
               Profiles := Kept;
            end;
            for Profile of Profiles loop
               Run_One (Profile);
               exit when E.Is_Error (Outcome);
            end loop;
         end;
      end Check;

      --  Documents read for what the project must be: those named, or
      --  every Markdown file at the top and in docs.
      procedure Bootstrap (Store : in out S.Store) is
         Change : S.Transaction;
         Found  : Model_Runner.Framework.Bootstrap.Output_List;
         Report : Model_Runner.Framework.Bootstrap.Report;
         --  Each named as the project names it: ./docs/x.md and a whole
         --  path into the project are docs/x.md.
         --  A directory named is its Markdown files; one named twice is
         --  read once.
         function Named_Here return Names.Vector is
            Result : Names.Vector;
            procedure Add (One : String) is
            begin
               if not Result.Contains (One) then
                  Result.Append (One);
               end if;
            end Add;

            --  Whether a path matches a pattern: * any characters but /,
            --  ** any directories, none among them.
            function Matches (Pattern, Path : String) return Boolean is
            begin
               if Pattern = "" then
                  return Path = "";
               elsif Pattern'Length >= 3 and then Pattern (Pattern'First .. Pattern'First + 2) = "**/" then
                  if Matches (Pattern (Pattern'First + 3 .. Pattern'Last), Path) then
                     return True;
                  end if;
                  for Cut in Path'Range loop
                     if Path (Cut) = '/'
                       and then Matches (Pattern (Pattern'First + 3 .. Pattern'Last), Path (Cut + 1 .. Path'Last))
                     then
                        return True;
                     end if;
                  end loop;
                  return False;
               elsif Pattern (Pattern'First) = '*' then
                  for Skip in 0 .. Path'Length loop
                     exit when Skip > 0 and then Path (Path'First + Skip - 1) = '/';
                     if Matches (Pattern (Pattern'First + 1 .. Pattern'Last), Path (Path'First + Skip .. Path'Last))
                     then
                        return True;
                     end if;
                  end loop;
                  return False;
               elsif Path = "" then
                  return False;
               elsif Pattern (Pattern'First) = Path (Path'First) then
                  return Matches (Pattern (Pattern'First + 1 .. Pattern'Last), Path (Path'First + 1 .. Path'Last));
               end if;
               return False;
            end Matches;

            --  The files under a directory ("" the project's), each a
            --  document, or each the pattern matches: built output, the
            --  state and what a dot hides left out.
            procedure Walk (Dir, Pattern : String) is
               Search : Ada.Directories.Search_Type;
               One    : Ada.Directories.Directory_Entry_Type;
               Below  : Names.Vector;
            begin
               Ada.Directories.Start_Search (Search, (if Dir = "" then "." else Dir), "");
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, One);
                  declare
                     Simple : constant String := Ada.Directories.Simple_Name (One);
                     Lower  : constant String := Ada.Characters.Handling.To_Lower (Simple);
                     Path   : constant String := (if Dir = "" then Simple else Dir & "/" & Simple);
                  begin
                     if Simple (Simple'First) = '.'
                       or else Lower in "obj" | "bin" | "alire" | "node_modules" | "target" | "build" | "_build"
                                      | "__pycache__" | "venv" | "dist"
                     then
                        null;
                     elsif Ada.Directories."=" (Ada.Directories.Kind (One), Ada.Directories.Directory) then
                        Below.Append (Path);
                     elsif (if Pattern /= "" then Matches (Pattern, Path)
                            else (for some Ending of Names.Vector'([".md", ".txt", ".rst", ".adoc"]) =>
                                    Lower'Length > Ending'Length
                                    and then Lower (Lower'Last - Ending'Length + 1 .. Lower'Last) = Ending))
                     then
                        Add (Path);
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
               for Next of Below loop
                  Walk (Next, Pattern);
               end loop;
            end Walk;
         begin
            for Path of Positional loop
               declare
                  Here : constant String := Model_Runner.Framework.Repository.Relative_Path
                                              (Ada.Directories.Current_Directory, Path);
               begin
                  --  A pattern -- docs/*.md, docs/**/*.rst, **/*.md -- the
                  --  files it matches anywhere in the project; a directory --
                  --  . for the whole project -- the documents in it and below.
                  if Ada.Strings.Fixed.Index (Here, "*") > 0 then
                     Walk ("", Here);
                  elsif Here in "" | "." | "./"
                    or else (Ada.Directories.Exists (Here)
                             and then Ada.Directories."=" (Ada.Directories.Kind (Here), Ada.Directories.Directory))
                  then
                     Walk ((if Here in "" | "." | "./" then ""
                            elsif Here (Here'Last) = '/' then Here (Here'First .. Here'Last - 1) else Here),
                           "");
                  else
                     Add (Here);
                  end if;
               end;
            end loop;
            return Result;
         end Named_Here;
         Named : constant Names.Vector := Named_Here;

         --  The documents named, or those the bootstrap policy reads.
         Files  : constant Names.Vector :=
           (if Positional.Is_Empty then Model_Runner.Framework.Bootstrap.Documents (Store)
            else Named);
      begin
         --  A pattern that finds nothing is said, not read as a name.
         for Path of Positional loop
            if Ada.Strings.Fixed.Index (Path, "*") > 0 and then Named.Is_Empty then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "a document to read");
               E.Add_Text (Outcome, "value", Path);
               E.Add_Text (Outcome, "detail", "no file matches it");
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end loop;
         --  A document named is one within the project, outside its state,
         --  and there to be read: nothing is taken from one that is not.
         for Path of Named loop
            declare
               Extension : constant String :=
                 Ada.Characters.Handling.To_Lower (Ada.Directories.Extension (Path));
            begin
               --  Source is not a document: what it must do is read from
               --  prose, not guessed from code.
               if Extension not in "" | "md" | "markdown" | "txt" | "text" | "rst" | "adoc" | "asciidoc" | "org"
               then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "a document to read");
                  E.Add_Text (Outcome, "value", Path);
                  E.Add_Text (Outcome, "detail",
                              "it is not a document: /bootstrap reads Markdown and text (.md, .txt, .rst,"
                              & " .adoc, .org); what code does is found with /scan and /sym");
                  Pres.Report (Screen, Outcome);
                  return;
               end if;
            end;
         end loop;
         for Path of Named loop
            if Path = "" or else Path (Path'First) in '/' | '\'
              or else Ada.Strings.Fixed.Index (Path, "..") > 0
              or else Ada.Strings.Fixed.Index (Path, ".model_runner") > 0
              or else not Ada.Directories.Exists (Path)
              or else Ada.Directories."/=" (Ada.Directories.Kind (Path), Ada.Directories.Ordinary_File)
            then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "a document to read");
               E.Add_Text (Outcome, "value", Path);
               E.Add_Text (Outcome, "detail",
                           (if not Ada.Directories.Exists (Path) then "there is no such file"
                            elsif Ada.Strings.Fixed.Index (Path, ".model_runner") > 0
                            then "it is the project's own state, not a document of the project's"
                            else "it lies outside the project, which is "
                                 & Ada.Directories.Containing_Directory (S.Root (Store))
                                 & " -- copy it in, or /init where the whole of it is"));
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end loop;
         for Path of Files loop
            declare
               Scanned : constant Model_Runner.Framework.Bootstrap.Output_List :=
                 Model_Runner.Framework.Bootstrap.Scan (Path, Whole (Path));
            begin
               for Index in 1 .. Model_Runner.Framework.Bootstrap.Length (Scanned) loop
                  Model_Runner.Framework.Bootstrap.Append
                    (Found, Model_Runner.Framework.Bootstrap.Element (Scanned, Index));
               end loop;
            end;
         end loop;
         if Files.Is_Empty then
            declare
               Config : R.Item;
               Got    : E.Error_Info;
               Shown  : Unbounded_String;
            begin
               Model_Runner.Framework.Configurations.Read (Store, Config, Got);
               for One of Model_Runner.Framework.Lines_Of
                 (Ada.Strings.Fixed.Translate (R.Get (Config, "set.bootstrap.sources"),
                                               Ada.Strings.Maps.To_Mapping (", ", [ASCII.LF, ASCII.LF])))
               loop
                  Append (Shown, (if Shown = Null_Unbounded_String then "" else ", ") & One);
               end loop;
               Pres.Put_Note (Screen, "cli.next.no_documents",
                              [Loc.Named ("detail", (if Shown = Null_Unbounded_String then "*.md, docs/**/*.md"
                                                     else To_String (Shown)))]);
            end;
            return;
         end if;
         --  Items the documents number are theirs, accepted as the documents
         --  have them -- asked first at a terminal, where the project has
         --  not said, as they govern once accepted.
         declare
            package Bt renames Model_Runner.Framework.Bootstrap;
            Numbered : Names.Vector;
            Accepting : Boolean := True;
            Config    : R.Item;
            Read      : E.Error_Info;
         begin
            Model_Runner.Framework.Configurations.Read (Store, Config, Read);
            for Index in 1 .. Bt.Length (Found) loop
               declare
                  One : constant Bt.Output := Bt.Element (Found, Index);
               begin
                  if Bt."=" (One.Kind, Bt.Imported_Item)
                    and then Length (One.Given_Id) > 0
                    and then not S.Exists (Store, Model_Runner.Framework.Requirements_Area,
                                           To_String (One.Given_Id))
                    and then Model_Runner.Framework.Intent.Find_By_Provenance
                               (Store, Nt.Requirement, To_String (One.Provenance)) = ""
                  then
                     Numbered.Append (To_String (One.Given_Id));
                  end if;
               end;
            end loop;
            if not Numbered.Is_Empty and then R.Get (Config, "scalar.bootstrap.import") = ""
              and then Model_Runner.CLI.Choosers.Is_Available (Screen)
            then
               declare
                  Listed : Unbounded_String;
               begin
                  for Id of Numbered loop
                     Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Id);
                  end loop;
                  Pres.Put_Message (Screen, "cli.project.bootstrap.numbered",
                                    [Loc.Named ("count", Image (Natural (Numbered.Length))),
                                     Loc.Named ("detail", To_String (Listed))]);
                  Accepting := Answered_Yes (Screen);
               end;
            end if;
            Bt.Apply (Store, Change, Found, Report, Outcome, Accept_Numbered => Accepting);
         end;
         if E.Is_Ok (Outcome) then
            S.Commit (Store, Change, Outcome);
         end if;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.project.bootstrapped",
            [Loc.Named ("count", Image (Report.Created)),
             Loc.Named ("value", Image (Natural (Report.Revised.Length))),
             Loc.Named ("total", Image (Report.Existing)),
             Loc.Named ("extra", Image (Report.Issues))]);
         --  Each with what it is now: a candidate waits to be accepted. Many
         --  are said as runs -- REQ-X-001 .. REQ-X-318 -- of one state.
         declare
            function Kind_Of (Id : String) return Nt.Intent_Kind
            is (if Ada.Strings.Fixed.Index (Id, "DEC-") = 1 then Nt.Decision
                elsif Ada.Strings.Fixed.Index (Id, "SPEC-") = 1 then Nt.Specification
                else Nt.Requirement);

            function Stem (Id : String) return String is
               Dash : constant Natural := Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward);
            begin
               return (if Dash = 0 then Id else Id (Id'First .. Dash));
            end Stem;

            function Number_In (Id : String) return Natural is
               Dash : constant Natural := Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward);
            begin
               return Natural'Value (Id (Dash + 1 .. Id'Last));
            exception
               when others =>
                  return 0;
            end Number_In;

            First_Of : Unbounded_String;
            Last_Of  : Unbounded_String;
            Count    : Natural := 0;

            --  A state as made, with why where it was accepted at once.
            function Made_As (Id : String) return String is
               State : constant String := Nt.State_Of (Store, Kind_Of (Id), Id);
            begin
               return (if State = "accepted" then "accepted, as the document has it" else State);
            end Made_As;

            procedure Say_Run is
            begin
               if Count = 1 then
                  Pres.Put_Message
                    (Screen, "cli.project.bootstrap.made",
                     [Loc.Named ("name", To_String (First_Of)),
                      Loc.Named ("value", Made_As (To_String (First_Of)))]);
               elsif Count > 1 then
                  Pres.Put_Message
                    (Screen, "cli.project.bootstrap.made",
                     [Loc.Named ("name", To_String (First_Of) & " .. " & To_String (Last_Of)
                                         & " (" & Image (Count) & ")"),
                      Loc.Named ("value", Made_As (To_String (First_Of)))]);
               end if;
               Count := 0;
            end Say_Run;
         begin
            for Id of Report.Made loop
               if Natural (Report.Made.Length) > 12 and then Count > 0
                 and then Stem (Id) = Stem (To_String (First_Of))
                 --  A run is numbers that follow one another: one taken out
                 --  of it and said apart is not in it.
                 and then Number_In (Id) = Number_In (To_String (Last_Of)) + 1
                 and then Nt.State_Of (Store, Kind_Of (Id), Id)
                          = Nt.State_Of (Store, Kind_Of (To_String (First_Of)), To_String (First_Of))
               then
                  Last_Of := To_Unbounded_String (Id);
                  Count := Count + 1;
               else
                  Say_Run;
                  First_Of := To_Unbounded_String (Id);
                  Last_Of := First_Of;
                  Count := 1;
               end if;
            end loop;
            Say_Run;
         end;
         for Line of Report.Moved loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.moved", [Loc.Named ("detail", Line)]);
         end loop;
         for Line of Report.Adopted loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.adopted", [Loc.Named ("detail", Line)]);
         end loop;
         for Id of Report.Revised loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.revised", [Loc.Named ("name", Id)]);
            --  Work done or doing for what it said before: named.
            declare
               Serving : Unbounded_String;
            begin
               for Task_Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Task_Id, Defined, Got);
                     if E.Is_Ok (Got)
                       and then Tk.State_Of (Store, Task_Id) not in "cancelled" | "rejected"
                       and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                                  .Contains (Id)
                     then
                        Append (Serving, (if Serving = Null_Unbounded_String then "" else ", ")
                                         & Task_Id);
                     end if;
                  end;
               end loop;
               if Serving /= Null_Unbounded_String then
                  Pres.Put_Note (Screen, "cli.project.bootstrap.revised_served",
                                 [Loc.Named ("name", Id), Loc.Named ("detail", To_String (Serving))]);
               end if;
            end;
         end loop;
         for Line of Report.Stale loop
            declare
               Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
            begin
               Pres.Put_Message
                 (Screen, "cli.project.bootstrap.stale",
                  [Loc.Named ("detail", (if Colon = 0 then Line
                                         else With_Id (Line (Line'First .. Colon - 1), Line)))]);
            end;
         end loop;

         --  What it imported as accepted is followed as any accepted
         --  requirement is: its tasks derived, readiness worked out -- its
         --  next step said once, with bootstrap's own.
         Pres.Hold_Next_Steps (Screen, True);
         Model_Runner.CLI.Intents.Move_Along (Store, Screen);
         Pres.Hold_Next_Steps (Screen, False);
         --  Nothing read from what was named: said, with how a document
         --  says a requirement.
         if Report.Created = 0 and then Report.Existing = 0 and then Report.Revised.Is_Empty
           and then Report.Issues = 0 and then Report.Adopted.Is_Empty
         then
            declare
               Listed  : Unbounded_String;
               Retired : Natural := 0;

               --  A decision record that says of itself it is no longer in
               --  force: read, and not proposed, which is not nothing.
               function Retired_Record (Path : String) return Boolean is
                  File : Ada.Text_IO.File_Type;
                  Seen : Boolean := False;
               begin
                  Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
                  while not Ada.Text_IO.End_Of_File (File) and then not Seen loop
                     declare
                        Line : constant String :=
                          Ada.Characters.Handling.To_Lower (Ada.Text_IO.Get_Line (File));
                     begin
                        Seen := Ada.Strings.Fixed.Index (Line, "status") > 0
                          and then (Ada.Strings.Fixed.Index (Line, "rejected") > 0
                                    or else Ada.Strings.Fixed.Index (Line, "deprecated") > 0
                                    or else Ada.Strings.Fixed.Index (Line, "superseded") > 0);
                     end;
                  end loop;
                  Ada.Text_IO.Close (File);
                  return Seen;
               exception
                  when others =>
                     if Ada.Text_IO.Is_Open (File) then
                        Ada.Text_IO.Close (File);
                     end if;
                     return False;
               end Retired_Record;
            begin
               for One of Files loop
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
                  if Retired_Record (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), One))
                  then
                     Retired := Retired + 1;
                  end if;
               end loop;
               if Retired > 0 and then Retired = Natural (Files.Length) then
                  Pres.Put_Note (Screen, "cli.next.bootstrap_retired",
                                 [Loc.Named ("count", Image (Retired)), Loc.Named ("detail", To_String (Listed))]);
               else
                  Pres.Put_Note (Screen, "cli.next.bootstrap_nothing",
                                 [Loc.Named ("detail", To_String (Listed))]);
               end if;
            end;
         end if;

         --  A candidate requirement made waits to be accepted; with none
         --  read at all, how a document says one.
         --  Anything it made that waits on a person -- an entry of any
         --  register, or a task derived from what it accepted -- is
         --  pointed at as one: /accept goes through them all.
         if (for some Id of Report.Made =>
               (Ada.Strings.Fixed.Index (Id, "REQ-") = Id'First
                and then Nt.State_Of (Store, Nt.Requirement, Id) = Nt.First_State (Nt.Requirement))
               or else (Ada.Strings.Fixed.Index (Id, "SPEC-") = Id'First
                        and then Nt.State_Of (Store, Nt.Specification, Id) = Nt.First_State (Nt.Specification))
               or else (Ada.Strings.Fixed.Index (Id, "DEC-") = Id'First
                        and then Nt.State_Of (Store, Nt.Decision, Id) = Nt.First_State (Nt.Decision)))
           or else (not Report.Made.Is_Empty and then not Tk.List (Store, "candidate").Is_Empty)
         then
            Pres.Put_Note (Screen, "cli.next.bootstrap");
         elsif not Report.Made.Is_Empty
           and then not (for some Id of Report.Made => Ada.Strings.Fixed.Index (Id, "REQ-") = Id'First)
           and then Report.Existing = 0 and then Report.Revised.Is_Empty
         then
            Pres.Put_Note (Screen, "cli.next.bootstrap_no_requirement");
         end if;
      end Bootstrap;

      --  A change to the settings: what it changes and reaches, and then,
      --  once it is confirmed, a new revision; what was verified is looked at
      --  again against it.
      procedure Reconfigure (Store : in out S.Store) is
         package Cf renames Model_Runner.Framework.Configurations;
         Known_Before : Names.Vector;
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Read     : E.Error_Info;
         Revision : Natural;
      begin
         --  Nothing named, or help asked for: how it is used.
         if Natural (All_Words.Length) < 2
           or else All_Words (2) in "--help" | "-h" | "help"
         then
            Pres.Put_Message (Screen, "cli.project.reconfigure.usage");
            return;
         end if;

         --  NAME=VALUE, the value running on to the next NAME=: a value of
         --  several words needs no quotes. NAME = VALUE, spaced as
         --  /instruct takes it, is the same.
         declare
            Name  : Unbounded_String;
            Value : Unbounded_String;
            Words_Given : Names.Vector;
         begin
            for Index in 2 .. Natural (All_Words.Length) loop
               declare
                  Part : constant String := All_Words (Index);
               begin
                  if not Words_Given.Is_Empty
                    and then (Part = "=" or else Part (Part'First) = '='
                              or else Words_Given.Last_Element (Words_Given.Last_Element'Last) = '=')
                    and then Ada.Strings.Fixed.Index (Words_Given.Last_Element, "=")
                               in 0 | Words_Given.Last_Element'Last
                    and then not (Part /= "=" and then Part (Part'First) /= '='
                                  and then Ada.Strings.Fixed.Index (Part, "=") > 0)
                  then
                     Words_Given.Replace_Element
                       (Words_Given.Last_Index, Words_Given.Last_Element & Part);
                  else
                     Words_Given.Append (Part);
                  end if;
               end;
            end loop;
            for Part of Words_Given loop
               declare
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Part, "=");
               begin
                  if Part = "confirm=yes" then
                     null;
                  --  A setting starts: named with its kind, or -- as the
                  --  first word -- named any way at all, to be found or
                  --  refused by name rather than dropped.
                  elsif Is_Setting (Part)
                    and then (Ada.Strings.Fixed.Index (Part (Part'First .. Equal - 1), ".") > 0
                              or else Name = Null_Unbounded_String)
                  then
                     if Name /= Null_Unbounded_String then
                        Changes.Include (To_String (Name), To_String (Value));
                     end if;
                     Name := To_Unbounded_String (Part (Part'First .. Equal - 1));
                     Value := To_Unbounded_String (Part (Equal + 1 .. Part'Last));
                  elsif Name /= Null_Unbounded_String then
                     Append (Value, " " & Part);
                  else
                     --  A name with no value: a value is what a change is.
                     Read := E.Make (E.CLI_Invalid_Option_Value);
                     E.Add_Text (Read, "option", Part);
                     E.Add_Text (Read, "value",
                                 (if Part (Part'First) = '='
                                  then "a setting is named before its =, as NAME=VALUE"
                                  else "a setting is changed as " & Part & "=VALUE; /config "
                                       & Part & " shows what it is"));
                     Pres.Report (Screen, Read);
                     return;
                  end if;
               end;
            end loop;
            if Name /= Null_Unbounded_String then
               Changes.Include (To_String (Name), To_String (Value));
            end if;
         end;

         Cf.Plan_Change (Store, Changes, Planned, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         elsif Planned.Changed.Is_Empty then
            Pres.Put_Note (Screen, (if (for some Position in Changes.Iterate =>
                                          Cf.Value_Maps.Element (Position) = "inherit")
                                    then "cli.project.reconfigure.nothing_inherit"
                                    else "cli.project.reconfigure.nothing"));
            return;
         end if;
         --  A check the new configuration would not let run: refused now,
         --  with the change that lets it, not found at the next /check.
         declare
            package Vf renames Model_Runner.Framework.Verification;
            package Ex renames Model_Runner.Framework.Execution;
            Rules   : constant Ex.Policy := Ex.Policy_From (Planned.After);
            Before  : constant Ex.Policy := Ex.Policy_From (Planned.Before);
            Missing : Names.Vector;
            Where   : Unbounded_String;
         begin
            for Index in 1 .. R.Field_Count (Planned.After) loop
               declare
                  Field : constant String := R.Field_Name (Planned.After, Index);
               begin
                  if Ada.Strings.Fixed.Index (Field, "profile.") = Field'First then
                     declare
                        Checks : constant Vf.Check_List := Vf.Parse_Profile (R.Get (Planned.After, Field));
                     begin
                        for At_Check in 1 .. Vf.Length (Checks) loop
                           declare
                              Command : constant String := To_String (Vf.Element (Checks, At_Check).Command);
                              Words   : constant Names.Vector := Ex.Words_Of (Command);
                           begin
                              --  Only what this change stops: a profile it
                              --  sets, or a program it takes away.
                              if not Words.Is_Empty and then Ex.Refusal (Rules, Command) /= ""
                                and then (Ex.Refusal (Before, Command) = "" or else Changes.Contains (Field))
                                and then Ada.Strings.Fixed.Index (Ex.Refusal (Rules, Command), "not a program") > 0
                                and then not Missing.Contains (Words.First_Element)
                              then
                                 Missing.Append (Words.First_Element);
                                 Append (Where, (if Where = Null_Unbounded_String then "" else ", ")
                                                & Field & " runs " & Words.First_Element);
                              end if;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
            if not Missing.Is_Empty then
               declare
                  Allow : Unbounded_String;
                  Asked : Unbounded_String;
               begin
                  for One of Missing loop
                     Append (Allow, (if Allow = Null_Unbounded_String then "" else ",") & One);
                  end loop;
                  --  One change that says it all: where execution.allowed is
                  --  set in it, the programs added to what it is set to.
                  for Position in Changes.Iterate loop
                     declare
                        Key   : constant String := Cf.Value_Maps.Key (Position);
                        Value : constant String :=
                          (if Ada.Strings.Fixed.Index (Key, "execution.allowed") > 0
                              and then Key (Key'Last) /= '+' and then Key (Key'Last) /= '-'
                           then Cf.Value_Maps.Element (Position) & ", " & To_String (Allow)
                           else Cf.Value_Maps.Element (Position));
                     begin
                        if Ada.Strings.Fixed.Index (Key, "execution.allowed") > 0
                          and then Key (Key'Last) /= '+' and then Key (Key'Last) /= '-'
                        then
                           Allow := Null_Unbounded_String;
                        end if;
                        Append (Asked, Key & "="
                                       & (if Ada.Strings.Fixed.Index (Value, " ") > 0
                                            or else Ada.Strings.Fixed.Index (Value, ",") > 0
                                          then '"' & Value & '"' else Value) & " ");
                     end;
                  end loop;
                  Outcome := E.Make (E.Framework_Execution_Refused);
                  E.Add_Text (Outcome, "name", "the check (" & To_String (Where) & ")");
                  E.Add_Text (Outcome, "detail",
                              "set.execution.allowed would not let it run; add it in the same change:"
                              & " /reconfigure " & To_String (Asked)
                              & (if Allow = Null_Unbounded_String then ""
                                 else "set.execution.allowed+=" & To_String (Allow)));
                  Pres.Report (Screen, Outcome);
                  return;
               end;
            end if;
         end;
         --  A setting an accepted decision rules, changed to another value:
         --  said before it is asked, as the disagreement it makes.
         for Id of Nt.List (Store, Nt.Decision) loop
            if Nt.State_Of (Store, Nt.Decision, Id) = "accepted" then
               declare
                  All_Of : Names.Vector := Nt.Also_Governs (Store, Nt.Decision, Id);
               begin
                  if Nt.Governs (Store, Nt.Decision, Id) /= "" then
                     All_Of.Prepend (Nt.Governs (Store, Nt.Decision, Id));
                  end if;
                  for One of All_Of loop
                     declare
                        Equal : constant Natural := Ada.Strings.Fixed.Index (One, " = ");
                        Over  : constant Natural := Ada.Strings.Fixed.Index (One, " (over ");
                        Setting : constant String := (if Equal > One'First then One (One'First .. Equal - 1) else "");
                        Ruling  : constant String :=
                          (if Equal = 0 then "" else One (Equal + 3 .. (if Over > 0 then Over - 1 else One'Last)));
                     begin
                        if Setting /= "" and then R.Get (Planned.After, Setting) /= R.Get (Planned.Before, Setting)
                          and then R.Get (Planned.After, Setting) /= Ruling
                        then
                           --  One that holds over the configuration keeps holding:
                           --  the change is refused, with the ways to change it.
                           if Over > 0 and then Ada.Strings.Fixed.Index (One (Over .. One'Last), "CONFIG") > 0 then
                              Outcome := E.Make (E.Framework_Input_Invalid);
                              E.Add_Text (Outcome, "name", Setting);
                              E.Add_Text (Outcome, "value", R.Get (Planned.After, Setting));
                              E.Add_Text (Outcome, "detail",
                                          Id & " rules " & Ruling & " over the configuration; /decision govern "
                                          & Id & " " & Setting & " VALUE rules another, /decision govern " & Id
                                          & " " & Setting & " none lets it go, or /decision obsolete "
                                          & Id & " lets the configuration say it again");
                              Pres.Report (Screen, Outcome);
                              return;
                           end if;
                           Pres.Put_Note (Screen, "cli.project.reconfigure.against",
                                          [Loc.Named ("name", Setting), Loc.Named ("value", Id & " rules " & Ruling)]);
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end loop;
         --  Named as it is typed: work.lease, not scalar.work.lease.
         for Line of Planned.Changed loop
            Pres.Put_Message
              (Screen, "cli.project.reconfigure.changed",
               [Loc.Named ("name", (if Ada.Strings.Fixed.Index (Line, "scalar.") = Line'First
                                    then Line (Line'First + 7 .. Line'Last) else Line))]);
         end loop;
         for Line of Planned.Impact loop
            Pres.Put_Message (Screen, "cli.project.reconfigure.reaches", [Loc.Named ("name", Line)]);
         end loop;
         --  A value set that nothing here reads does nothing: said, before
         --  it is taken for a change in how the project is checked.
         for Line of Planned.Changed loop
            declare
               Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
               Name  : constant String := (if Colon = 0 then Line else Line (Line'First .. Colon - 1));
               Dot   : constant Natural :=
                 (if Name'Length > 7 then Ada.Strings.Fixed.Index (Name (Name'First + 7 .. Name'Last), ".")
                  else 0);
               Group : constant String := (if Dot = 0 then Name else Name (Name'First .. Dot));
               Known : constant Names.Vector := Cf.Known_Names;
            begin
               if Name'Length > 7 and then Name (Name'First .. Name'First + 6) = "scalar."
                 and then not Known.Contains (Name)
                 and then not (for some One of Known =>
                                 One'Length > Group'Length
                                 and then One (One'First .. One'First + Group'Length - 1) = Group)
               then
                  Pres.Put_Note (Screen, "cli.project.reconfigure.unread", [Loc.Named ("name", Name)]);
               end if;
            end;
         end loop;

         --  A kind or a role granted more than the project allows gets
         --  only what the project allows: before any change to permissions
         --  is made, every such level it would leave is said, once, with
         --  each capability it asks too much of and what it gets.
         if (for some Name of Planned.Changed =>
               Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First)
         then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Levels  : Names.Vector;
               Said_Project : Boolean;
               Of_Project   : constant Pm.Permission_Set :=
                 Pm.Level_Of (Planned.After, "project", Said_Project);
               Project : constant Pm.Permission_Set :=
                 (if Said_Project then Of_Project else Pm.Project_Default);
            begin
               for Index in 1 .. R.Field_Count (Planned.After) loop
                  declare
                     Field : constant String := R.Field_Name (Planned.After, Index);
                     Rest  : constant String :=
                       (if Field'Length > 15 and then Field (Field'First .. Field'First + 14)
                                                     = "map.permission."
                        then Field (Field'First + 15 .. Field'Last) else "");
                     Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
                     Level : constant String := (if Dot = 0 then "" else Rest (Rest'First .. Dot - 1));
                  begin
                     if Level'Length > 5 and then Level (Level'First .. Level'First + 4) in "kind." | "role."
                       and then not Levels.Contains (Level)
                     then
                        Levels.Append (Level);
                     end if;
                  end;
               end loop;
               for Level of Levels loop
                  declare
                     Present : Boolean;
                     --  What it asks for itself: one it inherits asks for
                     --  nothing, and follows what is above.
                     function Own_Asked return Pm.Permission_Set is
                        Result : Pm.Permission_Set := Pm.Level_Of (Planned.After, Level, Present);
                     begin
                        for One in Pm.Capability loop
                           if R.Get (Planned.After, "map.permission." & Level & "." & Pm.Word (One))
                                = "inherit"
                           then
                              Result (One) := Pm.Nothing (One);
                           end if;
                        end loop;
                        return Result;
                     end Own_Asked;
                     Given   : constant Pm.Permission_Set := Own_Asked;
                     Clipped : constant String := Pm.Clipped (Given, Project);
                  begin
                     if Present and then Clipped /= "" then
                        Pres.Put_Note
                          (Screen, "cli.project.clipped",
                           [Loc.Named ("name", Level), Loc.Named ("detail", Clipped)]);
                     end if;
                  end;
               end loop;
            end;
         end if;

         --  A create_children grant past the agents' own bound: bounded by
         --  that, and said, not left to be found out.
         declare
            package Pm renames Model_Runner.Framework.Permissions;
            function Bound (Name, Default : String) return Natural is
               Set : constant String := R.Get (Planned.After, Name);
            begin
               return (if Set'Length in 1 .. 6 and then (for all C of Set => C in '0' .. '9')
                       then Natural'Value (Set) else Natural'Value (Default));
            end Bound;
            Max_Children : constant Natural := Bound ("scalar.agents.max_children", "3");
            Max_Depth    : constant Natural := Bound ("scalar.agents.max_depth", "2");
         begin
            for Line of Planned.Changed loop
               if Ada.Strings.Fixed.Index (Line, ".create_children") > 0 then
                  declare
                     Present : Boolean;
                     Name    : constant String :=
                       Line (Line'First + 15 .. Ada.Strings.Fixed.Index (Line, ".create_children") - 1);
                     Level   : constant Pm.Permission_Set := Pm.Level_Of (Planned.After, Name, Present);
                  begin
                     if Present and then Level (Pm.Create_Children).Granted
                       and then (Level (Pm.Create_Children).Max_Children > Max_Children
                                 or else Level (Pm.Create_Children).Max_Depth > Max_Depth)
                     then
                        --  Only the part past the bound, and a part given no
                        --  number said as that: any, which the bound limits.
                        declare
                           Given    : constant Pm.Grant := Level (Pm.Create_Children);
                           function Said (Count : Natural) return String
                           is (if Count = Natural'Last then "any (none given)" else Image (Count));
                           Children : constant String :=
                             (if Given.Max_Children > Max_Children
                              then "max_children " & Said (Given.Max_Children) & " past "
                                   & Image (Max_Children)
                              else "");
                           Depth    : constant String :=
                             (if Given.Max_Depth > Max_Depth
                              then "max_depth " & Said (Given.Max_Depth) & " past " & Image (Max_Depth)
                              else "");
                        begin
                           Pres.Put_Note
                             (Screen, "cli.project.grant_past_bound",
                              [Loc.Named ("name", Name),
                               Loc.Named ("detail", Children & (if Children /= "" and then Depth /= "" then ", "
                                                                else "") & Depth)]);
                        end;
                     end if;
                  end;
               end if;
            end loop;

            --  The bound raised past what a level grants: that level's
            --  grant, the lower, is what holds there -- said, not lost.
            if (for some Line of Planned.Changed =>
                  Ada.Strings.Fixed.Index (Line, "scalar.agents.max_children") = Line'First
                  or else Ada.Strings.Fixed.Index (Line, "scalar.agents.max_depth") = Line'First)
            then
               declare
                  Levels : Names.Vector;
               begin
                  for Index in 1 .. R.Field_Count (Planned.After) loop
                     declare
                        Field : constant String := R.Field_Name (Planned.After, Index);
                        At_Cc : constant Natural := Ada.Strings.Fixed.Index (Field, ".create_children");
                     begin
                        if Ada.Strings.Fixed.Index (Field, "map.permission.") = Field'First and then At_Cc > 0
                          and then not Levels.Contains (Field (Field'First + 15 .. At_Cc - 1))
                        then
                           Levels.Append (Field (Field'First + 15 .. At_Cc - 1));
                        end if;
                     end;
                  end loop;
                  for Name of Levels loop
                     declare
                        Present : Boolean;
                        Level   : constant Pm.Permission_Set := Pm.Level_Of (Planned.After, Name, Present);
                        Given   : constant Pm.Grant := Level (Pm.Create_Children);
                     begin
                        if Present and then Given.Granted
                          and then (Given.Max_Children < Max_Children or else Given.Max_Depth < Max_Depth)
                        then
                           Pres.Put_Note
                             (Screen, "cli.project.grant_below_bound",
                              [Loc.Named ("name", Name),
                               Loc.Named ("detail",
                                          (if Given.Max_Children < Max_Children
                                           then "max_children=" & Image (Given.Max_Children) else "")
                                          & (if Given.Max_Children < Max_Children and then Given.Max_Depth < Max_Depth
                                             then " " else "")
                                          & (if Given.Max_Depth < Max_Depth
                                             then "max_depth=" & Image (Given.Max_Depth) else ""))]);
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end;

         --  What it leaves without a place, said before it is asked: open
         --  tasks in a component the change takes away.
         Known_Before := Tk.Components (Store);
         declare
            Known_After : constant Names.Vector := Tk.Components_Of (Planned.After);
            Listed      : Unbounded_String;
         begin
            for One of Known_After loop
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
            end loop;
            for Old of Known_Before loop
               if not Known_After.Contains (Old) then
                  declare
                     Count : Natural := 0;
                  begin
                     for Id of Tk.List (Store) loop
                        if Tk.Component_Of_Task (Store, Id) = Old
                          and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                        then
                           Count := Count + 1;
                        end if;
                     end loop;
                     if Count > 0 then
                        Pres.Put_Note
                          (Screen, "cli.project.component_gone",
                           [Loc.Named ("count", Image (Count)), Loc.Named ("name", Old),
                            Loc.Named ("value", To_String (Listed))]);
                     end if;
                  end;
               end if;
            end loop;
         end;

         --  A lease shorter than the time work may take: said, as such a
         --  lease runs out under a run that is still working.
         declare
            function Number (Name : String) return Natural is
            begin
               return Natural'Value (R.Get (Planned.After, Name));
            exception
               when others =>
                  return 0;
            end Number;
            Lease   : constant Natural := Number ("scalar.work.lease");
            Longest : Natural := Number ("scalar.agents.max_seconds");
            Named   : Unbounded_String := To_Unbounded_String ("agents.max_seconds");
         begin
            for Index in 1 .. R.Field_Count (Planned.After) loop
               declare
                  Field : constant String := R.Field_Name (Planned.After, Index);
               begin
                  if Ada.Strings.Fixed.Index (Field, "scalar.task.max_seconds.") = Field'First
                    and then Number (Field) > Longest
                  then
                     Longest := Number (Field);
                     Named := To_Unbounded_String (Field (Field'First + 7 .. Field'Last));
                  end if;
               end;
            end loop;
            if Lease > 0 and then Longest > Lease then
               Pres.Put_Note (Screen, "cli.project.lease_short",
                              [Loc.Named ("count", Image (Lease)), Loc.Named ("name", To_String (Named)),
                               Loc.Named ("total", Image (Longest))]);
            end if;
            --  A token budget smaller than an agent's context alone: every
            --  run would fail before it answers.
            for Line of Planned.Changed loop
               declare
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Line & ":", ":");
                  Field : constant String := Line (Line'First .. Colon - 1);
               begin
                  if (Field = "scalar.agents.token_budget"
                      or else Ada.Strings.Fixed.Index (Field, "scalar.task.token_budget.") = Field'First)
                    and then Number (Field) in 1 .. 2047
                  then
                     Pres.Put_Note (Screen, "cli.project.budget_small",
                                    [Loc.Named ("count", Image (Number (Field)))]);
                  end if;
               end;
            end loop;
         end;

         --  Confirmed by confirm=yes among the words, or asked -- but only
         --  on a terminal: a script's next line is not an answer.
         if All_Words.Contains ("confirm=yes") then
            null;
         elsif not Model_Runner.CLI.Choosers.Is_Available (Screen) then
            declare
               Missing : E.Error_Info := E.Make (E.Framework_Input_Missing);
            begin
               E.Add_Text (Missing, "name", "confirm");
               Pres.Report (Screen, Missing);
               Pres.Put_Note (Screen, "cli.next.confirm");
            end;
            return;
         else
            Pres.Put_Message (Screen, "cli.project.reconfigure.confirm", []);
            if not Answered_Yes (Screen) then
               Pres.Put_Message (Screen, "cli.project.reconfigure.kept");
               return;
            end if;
         end if;

         declare
            Change  : S.Transaction;
            Moved   : Names.Vector;
            Became  : Names.Vector;
            --  The tasks that could start before it, to say which it stops.
            Ready_Before : Names.Vector;
         begin
            for Id of Tk.List (Store, "accepted") loop
               if Tk.Ready (Store, Id).Ready then
                  Ready_Before.Append (Id);
               end if;
            end loop;
            --  The new revision and the requirements it takes verification
            --  from, committed as one.
            Cf.Stage_Change (Store, Change, Planned, Read);
            if E.Is_Ok (Read) then
               Vf.Reevaluate_Requirements
                 (Store, Change, Moved, Read,
                  Configuration => Cf.Verification_Fingerprint (Planned.After));
            end if;
            if E.Is_Ok (Read) then
               S.Commit (Store, Change, Read);
            end if;
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
               return;
            end if;
            Revision := R.Revision (Planned.After);

            --  Readiness is derived, and worked out from the state as it
            --  now is.
            if E.Is_Ok (Read) then
               Tk.Recompute_Readiness (Store, Change, Became, Read);
            end if;
            if E.Is_Ok (Read) then
               S.Commit (Store, Change, Read);
            end if;
            for Requirement of Moved loop
               Pres.Put_Message
                 (Screen, "cli.work.requirement",
                  [Loc.Named ("name", Requirement),
                   Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
            end loop;
            --  A task it leaves unable to start: said, with why.
            for Id of Ready_Before loop
               declare
                  Now : constant Tk.Readiness := Tk.Ready (Store, Id);
               begin
                  if not Now.Ready then
                     Pres.Put_Note (Screen, "cli.project.no_longer_ready",
                                    [Loc.Named ("name", Id),
                                     Loc.Named ("detail", (if Now.Reasons.Is_Empty then ""
                                                           else Now.Reasons.First_Element))]);
                  end if;
               end;
            end loop;
         end;
         --  Components changed: one declared with no roots is told where
         --  its files are said.
         if (for some Name of Planned.Changed =>
               Ada.Strings.Fixed.Index (Name, "map.component.") = Name'First
               or else Ada.Strings.Fixed.Index (Name, "set.components") = Name'First)
         then
            declare
               Known  : constant Names.Vector := Tk.Components (Store);
            begin
               --  Roots within another's: said, with whose the files are.
               for Name of Known loop
                  for Other of Known loop
                     if Other /= Name then
                        for Inner of Model_Runner.Framework.Repository.Component_Roots (Store, Name) loop
                           for Outer of Model_Runner.Framework.Repository.Component_Roots (Store, Other)
                           loop
                              declare
                                 O : constant String :=
                                   (if Outer'Length > 1 and then Outer (Outer'Last) = '/'
                                    then Outer (Outer'First .. Outer'Last - 1) else Outer);
                                 I : constant String :=
                                   (if Inner'Length > 1 and then Inner (Inner'Last) = '/'
                                    then Inner (Inner'First .. Inner'Last - 1) else Inner);
                              begin
                                 --  Strictly within, and new with this change.
                                 if I'Length > O'Length + 1
                                   and then I (I'First .. I'First + O'Length) = O & "/"
                                   and then (for some Line of Planned.Changed =>
                                               Ada.Strings.Fixed.Index
                                                 (Line, "map.component." & Name & ":") = Line'First
                                               or else Ada.Strings.Fixed.Index
                                                 (Line, "map.component." & Other & ":") = Line'First)
                                 then
                                    Pres.Put_Note
                                      (Screen, "cli.project.component_overlap",
                                       [Loc.Named ("name", Name), Loc.Named ("value", Inner),
                                        Loc.Named ("other", Other), Loc.Named ("detail", Outer)]);
                                 end if;
                              end;
                           end loop;
                        end loop;
                     end if;
                  end loop;
               end loop;
               for Name of Known loop
                  if Model_Runner.Framework.Repository.Component_Roots (Store, Name).Is_Empty
                    and then R.Get (Planned.After, "input.project_name") /= Name
                  then
                     Pres.Put_Note (Screen, "cli.project.component_rootless",
                                    [Loc.Named ("name", Name)]);
                  end if;
               end loop;
            end;
         end if;

         declare
            Written : Boolean;
         begin
            Model_Runner.Framework.Git.Keep_Policy (Store, Written, Read);
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
            end if;
         end;
         Pres.Put_Message
           (Screen, "cli.project.reconfigure.done", [Loc.Named ("count", Image (Revision))]);
      end Reconfigure;

      --  How the project stands in Git, asked of Git: the branch, and each
      --  changed path with the tasks whose work changed it.
      procedure Git_Status (Store : in out S.Store) is
         Said : constant Model_Runner.Framework.Git.Status_Report :=
           Model_Runner.Framework.Git.Status_Of (Here);
      begin
         if not Said.Found then
            Pres.Put_Note (Screen, "cli.project.git.none");
            return;
         end if;
         Pres.Put_Header
           (Screen, "cli.project.git.branch", [Loc.Named ("name", To_String (Said.Branch))]);
         --  The changes by the task that made them, each group under its
         --  title, each change said in a word in its colour.
         declare
            Groups : Names.Vector;
            Of_Each : Names.Vector;

            function Made_By (Path : String) return String is
               By : Unbounded_String;
            begin
               for Id of Tk.List (Store) loop
                  declare
                     State : R.Item;
                     Read  : E.Error_Info;
                  begin
                     S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", State, Read);
                     if E.Is_Ok (Read)
                       and then Model_Runner.Framework.Lines_Of (R.Get (State, "changed_files")).Contains (Path)
                     then
                        Append (By, (if By = Null_Unbounded_String then "" else ", ") & Id);
                     end if;
                  end;
               end loop;
               return To_String (By);
            end Made_By;
         begin
            for Line of Said.Changes loop
               Of_Each.Append (Made_By (Line (Line'First + 3 .. Line'Last)));
               if not Groups.Contains (Of_Each.Last_Element) then
                  Groups.Append (Of_Each.Last_Element);
               end if;
            end loop;
            for Group of Groups loop
               if Group = "" then
                  Pres.Put_Section (Screen, "cli.project.git.by_no_task");
               else
                  Pres.Put_Line (Screen, "");
                  Pres.Put_Header (Screen, "cli.project.git.by_task", [Loc.Named ("name", Group)]);
               end if;
               for Index in 1 .. Natural (Said.Changes.Length) loop
                  if Of_Each (Index) = Group then
                     declare
                        Line : constant String := Said.Changes (Index);
                        Code : constant String := Ada.Strings.Fixed.Trim (Line (Line'First .. Line'First + 1),
                                                                          Ada.Strings.Both);
                        Word : constant String :=
                          (if Code = "??" then "new"
                           elsif Ada.Strings.Fixed.Index (Code, "D") > 0 then "deleted"
                           elsif Ada.Strings.Fixed.Index (Code, "A") > 0 then "added"
                           elsif Ada.Strings.Fixed.Index (Code, "R") > 0 then "renamed"
                           else "modified");
                     begin
                        Pres.Put_Row (Screen, Ada.Strings.Fixed.Head (Word, 8), Line (Line'First + 3 .. Line'Last),
                                      Indent => 2,
                                      Main_Tone => (if Word in "new" | "added" then Pres.Good
                                                    elsif Word = "deleted" then Pres.Bad else Pres.Pending),
                                      Mute_Aside => False);
                     end;
                  end if;
               end loop;
            end loop;
         end;
         if Said.Changes.Is_Empty then
            Pres.Put_Note (Screen, "cli.project.git.clean");
         end if;
      end Git_Status;

      --  A person's explicit word on a subject, above every other source:
      --  given, withdrawn, or those standing listed.
      procedure Instruct (Store : in out S.Store) is
         package Au renames Model_Runner.Framework.Authority;
         Change : S.Transaction;
         Said   : Unbounded_String;
         Id     : Unbounded_String;
      begin
         for Index in 2 .. Natural (All_Words.Length) loop
            Append (Said, (if Index = 2 then "" else " ") & All_Words (Index));
         end loop;
         if Said = Null_Unbounded_String then
            for Line of Au.Standing_Instructions (Store) loop
               Pres.Put_Message (Screen, "cli.task.field",
                                 [Loc.Named ("name", Line (Line'First .. Ada.Strings.Fixed.Index (Line, ":") - 1)),
                                  Loc.Named ("value", Line (Ada.Strings.Fixed.Index (Line, ":") + 2 .. Line'Last))]);
            end loop;
            if Au.Standing_Instructions (Store).Is_Empty then
               Pres.Put_Note (Screen, "cli.project.instruct.none");
            end if;
            return;
         elsif Argument (1) = "withdraw" then
            Au.Withdraw (Store, Change, Argument (2), Model_Runner.Framework.Transitions.User,
                         Outcome);
            if E.Is_Ok (Outcome) then
               S.Commit (Store, Change, Outcome);
            end if;
            --  Withdrawn already: nothing to do, and said so.
            if E."=" (Outcome.Code, E.Framework_Transition_Invalid) then
               Pres.Put_Note (Screen, "cli.intent.already",
                              [Loc.Named ("name", Argument (2)), Loc.Named ("value", "withdrawn")]);
               return;
            elsif E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
            else
               Pres.Put_Message (Screen, "cli.task.moved",
                                 [Loc.Named ("name", Argument (2)),
                                  Loc.Named ("value", "withdrawn")]);
            end if;
            return;
         end if;
         declare
            Text      : constant String := To_String (Said);
            Equals    : constant Natural := Ada.Strings.Fixed.Index (Text, "=");
            Overrides : constant Natural := Ada.Strings.Fixed.Index (Text, " overriding ");
            Subject   : constant String :=
              (if Equals = 0 then "" else Ada.Strings.Fixed.Trim (Text (Text'First .. Equals - 1), Ada.Strings.Both));
            Value     : constant String :=
              (if Equals = 0 then ""
               else Ada.Strings.Fixed.Trim
                      (Text (Equals + 1 .. (if Overrides > Equals then Overrides - 1 else Text'Last)),
                       Ada.Strings.Both));
            Over      : constant String :=
              (if Overrides > Equals then Ada.Strings.Fixed.Trim (Text (Overrides + 12 .. Text'Last), Ada.Strings.Both)
               else "");
            --  The settings the subject may name: the configuration's, by
            --  their whole names or without their kind, and those the
            --  harness reads.
            function Known_Subjects return Names.Vector is
               Config : R.Item;
               Read   : E.Error_Info;
               Result : Names.Vector;

               procedure Add (Name : String) is
                  Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".");
               begin
                  if not Result.Contains (Name) then
                     Result.Append (Name);
                  end if;
                  if Dot > 0 and then not Result.Contains (Name (Dot + 1 .. Name'Last)) then
                     Result.Append (Name (Dot + 1 .. Name'Last));
                  end if;
                  --  A baseline by its subject: baseline.project.scope is scope.
                  if Ada.Strings.Fixed.Index (Name, "baseline.") = Name'First then
                     declare
                        Last_Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
                     begin
                        if not Result.Contains (Name (Last_Dot + 1 .. Name'Last)) then
                           Result.Append (Name (Last_Dot + 1 .. Name'Last));
                        end if;
                     end;
                  end if;
               end Add;
            begin
               Model_Runner.Framework.Configurations.Read (Store, Config, Read);
               for Index in 1 .. R.Field_Count (Config) loop
                  Add (R.Field_Name (Config, Index));
               end loop;
               for Name of Model_Runner.Framework.Configurations.Known_Names loop
                  Add (Name);
               end loop;
               return Result;
            end Known_Subjects;
         begin
            --  An instruction is SUBJECT = VALUE: words alone name nothing it
            --  could stand above.
            if Equals = 0 or else Subject = "" then
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "the subject: an instruction is SUBJECT = VALUE, as"
                           & " /instruct documentation = every public operation gets a comment");
               Pres.Report (Screen, Outcome);
               return;
            end if;
            --  What agents may do is the permissions', which an instruction
            --  would only contradict: refused, with where it is changed.
            if Ada.Strings.Fixed.Index (Subject, "permission.") = Subject'First
              or else Ada.Strings.Fixed.Index (Subject, "map.permission.") = Subject'First
            then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "an instruction's subject");
               E.Add_Text (Outcome, "value", Subject);
               declare
                  --  permission.CAP is the project level's: permission.project.CAP.
                  Bare  : constant String :=
                    (if Ada.Strings.Fixed.Index (Subject, "map.") = Subject'First
                     then Subject (Subject'First + 4 .. Subject'Last) else Subject);
                  Rest  : constant String := Bare (Bare'First + 11 .. Bare'Last);
                  Whole : constant String :=
                    (if Ada.Strings.Fixed.Index (Rest, ".") = 0 then "permission.project." & Rest else Bare);
               begin
                  E.Add_Text (Outcome, "detail",
                              "what agents may do is not instructed but granted: /reconfigure map."
                              & Whole & "=" & (if Value in "on" | "off" | "inherit" then Value else "on")
                              & " changes it");
               end;
               Pres.Report (Screen, Outcome);
               return;
            end if;
            --  What it overrides is an entry there is and stands.
            if Over /= "" then
               declare
                  Upper : constant String := Ada.Characters.Handling.To_Upper (Over);
                  State : constant String :=
                    (if Nt.State_Of (Store, Nt.Decision, Upper) /= "" then Nt.State_Of (Store, Nt.Decision, Upper)
                     elsif Nt.State_Of (Store, Nt.Specification, Upper) /= ""
                     then Nt.State_Of (Store, Nt.Specification, Upper)
                     else Nt.State_Of (Store, Nt.Requirement, Upper));
               begin
                  if State = "" or else State in "obsolete" | "superseded" | "rejected" then
                     Outcome := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Outcome, "name", "what it overrides");
                     E.Add_Text (Outcome, "value", Over);
                     E.Add_Text (Outcome, "detail",
                                 (if State = "" then "it is no decision, specification or requirement the"
                                                     & " project holds"
                                  else Upper & " is " & State & ", and overrides nothing now"));
                     Pres.Report (Screen, Outcome);
                     return;
                  end if;
               end;
            end if;
            --  One on the same subject stands already: named, with how to
            --  take it back -- two that say different things both stand.
            for Line of Au.Standing_Instructions (Store) loop
               declare
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Line, " = ");
               begin
                  if Colon > 0 and then Equal > Colon
                    and then Line (Colon + 2 .. Equal - 1) = Subject
                  then
                     Pres.Put_Note (Screen, "cli.project.instruct.same_subject",
                                    [Loc.Named ("name", Line (Line'First .. Colon - 1)),
                                     Loc.Named ("value", Line (Equal + 3 .. Line'Last)),
                                     Loc.Named ("other", Subject)]);
                  end if;
               end;
            end loop;
            Au.Instruct (Store, Change, Subject, Value, Over,
                         Model_Runner.Framework.Transitions.User, Id, Outcome);
            if E.Is_Ok (Outcome) then
               S.Commit (Store, Change, Outcome);
            end if;
            if E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
            else
               Pres.Put_Message (Screen, "cli.task.created",
                                 [Loc.Named ("name", To_String (Id)),
                                  Loc.Named ("detail", Subject & " = " & Value)]);
               --  What it does and does not do: agents are told it above
               --  every other source; a setting it names is not changed by it.
               declare
                  Known : constant Names.Vector := Known_Subjects;
                  Near  : constant String := Model_Runner.Framework.Nearest (Subject, Known);
               begin
                  if not Known.Contains (Subject)
                    and then Ada.Strings.Fixed.Index (Subject, "permission.") /= Subject'First
                  then
                     Pres.Put_Note (Screen, "cli.project.instruct.unknown",
                                    [Loc.Named ("name", Subject),
                                     Loc.Named ("detail", (if Near = "" then ""
                                                           else "; did you mean " & Near & "?"))]);
                  end if;
                  --  A setting of the harness's it names is not changed by it:
                  --  said, with what changes it; a free subject is only told.
                  if Known.Contains (Subject)
                    and then not (for some Name of Known =>
                                    Ada.Strings.Fixed.Index (Name, "baseline.") = Name'First
                                    and then Ada.Strings.Fixed.Tail (Name, Subject'Length + 1) = "." & Subject)
                  then
                     Pres.Put_Note (Screen, "cli.project.instruct.advisory", [Loc.Named ("name", Subject)]);
                  end if;
               end;
            end if;
         end;
      end Instruct;

      --  The one candidate waiting, if there is exactly one.
      procedure Decide (Store : in out S.Store) is
         --  /accept and /reject, or /task accept and /task reject with no
         --  task named: the same question.
         Accepting : constant Boolean :=
           Word = "/accept" or else (Word = "/task" and then Argument (1) = "accept");
         --  A candidate serving only requirements since retired can never
         --  be worked: not offered to be decided, but let go of.
         function Live_Candidates return Names.Vector is
            Result : Names.Vector;
         begin
            for Id of Tk.List (Store, "candidate") loop
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
               begin
                  Tk.Definition (Store, Id, Defined, Read);
                  declare
                     Serves : constant Names.Vector :=
                       Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"));
                  begin
                     if Serves.Is_Empty
                       or else (for some Req of Serves =>
                                  Nt.State_Of (Store, Nt.Requirement, Req)
                                    not in "obsolete" | "rejected" | "superseded")
                     then
                        Result.Append (Id);
                     end if;
                  end;
               end;
            end loop;
            return Result;
         end Live_Candidates;
         Tasks_Waiting : Names.Vector := Live_Candidates;
         Intent_Waiting : constant Names.Vector := Model_Runner.CLI.Intents.Pending (Store);

         --  A number alone is the candidate of that number, in whichever
         --  register: where several have one, which is asked, not guessed.
         Ambiguous : Unbounded_String;
         function Resolved (Given : String) return String is
            Matches : Names.Vector;
            function Number_Of (Id : String) return Natural is
               Dash : constant Natural := Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward);
            begin
               return (if Dash > 0 and then Dash < Id'Last
                         and then (for all C of Id (Dash + 1 .. Id'Last) => C in '0' .. '9')
                       then Natural'Value (Id (Dash + 1 .. Id'Last)) else 0);
            exception
               when others =>
                  return 0;
            end Number_Of;
         begin
            if Given = "" or else Given'Length > 6
              or else not (for all C of Given => C in '0' .. '9')
            then
               return Given;
            end if;
            for Id of Tasks_Waiting loop
               if Number_Of (Id) = Natural'Value (Given) then
                  Matches.Append (Id);
               end if;
            end loop;
            for Which of Intent_Waiting loop
               declare
                  Id : constant String := Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last);
               begin
                  if Number_Of (Id) = Natural'Value (Given) then
                     Matches.Append (Id);
                  end if;
               end;
            end loop;
            if Natural (Matches.Length) = 1 then
               return Matches.First_Element;
            elsif Natural (Matches.Length) > 1 then
               for Id of Matches loop
                  Append (Ambiguous, (if Ambiguous = Null_Unbounded_String then "" else ", ") & Id);
               end loop;
               return "";
            end if;
            return "TASK-" & (if Given'Length >= 3 then Given else [1 .. 3 - Given'Length => '0'] & Given);
         end Resolved;
         Named_One : constant String := (if Word = "/task" then "" else Resolved (Argument (1)));
         Waiting : Names.Vector := Tasks_Waiting;
         Listed  : Unbounded_String;
      begin
         Waiting.Append (Intent_Waiting);

         --  all: every one waiting -- the registers' first, as accepting a
         --  requirement may make tasks, then the tasks that were waiting.
         if Ada.Characters.Handling.To_Lower (Named_One) = "all" then
            if Waiting.Is_Empty then
               Pres.Put_Note (Screen, "cli.project.no_pending");
               return;
            end if;
            --  What was waiting when it was asked, decided; what that makes
            --  -- tasks for the requirements accepted -- named once at the
            --  end, for a person to take up in turn.
            Pres.Hold_Next_Steps (Screen, True);
            for Which of Intent_Waiting loop
               Model_Runner.CLI.Intents.Decide (Store, Which, Accepting, Screen, Say_Next => False);
            end loop;
            Pres.Hold_Next_Steps (Screen, False);
            --  What accepting made -- tasks for the requirements accepted --
            --  is decided with the rest: all is all.
            declare
               Made_Now : Unbounded_String;
            begin
               for Id of Tk.List (Store, "candidate") loop
                  if not Tasks_Waiting.Contains (Id) then
                     Append (Made_Now, (if Made_Now = Null_Unbounded_String then "" else " ") & Id);
                     if Accepting then
                        Tasks_Waiting.Append (Id);
                     end if;
                  end if;
               end loop;
               if Made_Now /= Null_Unbounded_String and then Tasks_Waiting.Is_Empty then
                  Pres.Put_Note (Screen, "cli.next.accept_tasks", [Loc.Named ("detail", To_String (Made_Now))]);
               end if;
            end;
            if not Tasks_Waiting.Is_Empty then
               declare
                  Joined : Unbounded_String;
               begin
                  --  A task serving only what is retired is left out, and
                  --  said: accepting it would have it wait for ever.
                  for Id of Tasks_Waiting loop
                     declare
                        Defined : R.Item;
                        Got     : E.Error_Info;
                        Served  : Names.Vector;
                        Retired : Boolean := False;
                     begin
                        Tk.Definition (Store, Id, Defined, Got);
                        Served := Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"));
                        Retired := not Served.Is_Empty
                          and then (for all Req of Served =>
                                      Nt.State_Of (Store, Nt.Requirement, Req)
                                        in "obsolete" | "superseded" | "rejected");
                        if Retired and then Accepting then
                           Pres.Put_Note (Screen, "cli.project.accept_all_skipped",
                                          [Loc.Named ("name", Id)]);
                        else
                           Append (Joined, (if Joined = Null_Unbounded_String then "" else " ") & Id);
                        end if;
                     end;
                  end loop;
                  if Joined = Null_Unbounded_String then
                     return;
                  end if;
                  Command.Action := T.To_Bounded (if Accepting then "accept" else "reject");
                  Command.Action_Argument := T.To_Bounded (To_String (Joined));
                  To_Task := True;
               end;
            end if;
            return;
         end if;

         --  A number several registers have a candidate of: which, asked.
         if Ambiguous /= Null_Unbounded_String then
            declare
               Which : E.Error_Info := E.Make (E.Framework_Input_Invalid);
            begin
               E.Add_Text (Which, "name", "what to " & (if Accepting then "accept" else "reject"));
               E.Add_Text (Which, "value", Argument (1));
               E.Add_Text (Which, "detail", "several candidates have that number -- " & To_String (Ambiguous)
                           & "; name the one meant");
               Pres.Report (Screen, Which);
               Last_Status := E.Exit_Status (Which);
            end;
            return;
         end if;

         --  One named: that one, and only if it waits to be decided.
         if Named_One /= "" then
            if Tasks_Waiting.Contains (Named_One) then
               Command.Action := T.To_Bounded (if Accepting then "accept" else "reject");
               Command.Action_Argument := T.To_Bounded (Named_One);
               To_Task := True;
               return;
            end if;
            for Which of Intent_Waiting loop
               if Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last) = Named_One then
                  Model_Runner.CLI.Intents.Decide (Store, Which, Accepting, Screen);
                  return;
               end if;
            end loop;
            --  There, and decided already: said as what it is now.
            if Tk.State_Of (Store, Named_One) /= "" then
               declare
                  Settled : E.Error_Info := E.Make (E.Framework_Input_Invalid);
               begin
                  E.Add_Text (Settled, "name", "what to " & (if Accepting then "accept" else "reject"));
                  E.Add_Text (Settled, "value", Named_One);
                  E.Add_Text (Settled, "detail", Named_One & " is " & Tk.State_Of (Store, Named_One)
                              & ", not a candidate waiting to be decided; /accept alone lists those that are");
                  Pres.Report (Screen, Settled);
               end;
               return;
            end if;
            declare
               Missing : E.Error_Info := E.Make (E.Framework_Not_Found);
            begin
               E.Add_Text (Missing, "name", "a proposal " & Named_One);
               Pres.Report (Screen, Missing);
            end;
            return;
         end if;

         if Waiting.Is_Empty then
            Pres.Put_Note (Screen, "cli.project.no_pending");
         elsif Natural (Waiting.Length) > 1 then
            --  Each as the command that decides it.
            for Id of Tasks_Waiting loop
               declare
                  Defined : R.Item;
                  Got     : E.Error_Info;
               begin
                  Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Got);
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else [1 => ASCII.LF])
                          & "/task " & (if Accepting then "accept " else "reject ") & Id
                          & "  (" & R.Get (Defined, "title") & ")");
               end;
            end loop;
            for Which of Intent_Waiting loop
               declare
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Which, ":");
                  Kind  : constant String := Which (Which'First .. Colon - 1);
                  Register : constant Nt.Intent_Kind :=
                    (if Kind = "requirement" then Nt.Requirement
                     elsif Kind = "decision" then Nt.Decision else Nt.Specification);
                  Held     : Nt.Entity;
                  Got      : E.Error_Info;
               begin
                  Nt.Read (Store, Register, Which (Colon + 1 .. Which'Last), Held, Got);
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else [1 => ASCII.LF])
                          & "/"
                          & (if Kind = "requirement" then "req"
                             elsif Kind = "decision" then "decision" else "spec")
                          & (if Accepting then " accept " else " reject ")
                          & Which (Colon + 1 .. Which'Last)
                          & (if E.Is_Ok (Got) then "  (" & To_String (Held.Title) & ")" else ""));
               end;
            end loop;
            --  Listed, not refused: asking what waits is what /accept alone
            --  does when there is more than one.
            --  Each on its own line, as the command that decides it.
            Pres.Put_Message (Screen, "cli.project.pending_many");
            for Line of Model_Runner.Framework.Lines_Of (To_String (Listed)) loop
               Pres.Put_Message (Screen, "cli.project.pending_one", [Loc.Named ("detail", Line)]);
            end loop;
         elsif Intent_Waiting.Is_Empty then
            Command.Action := T.To_Bounded (if Accepting then "accept" else "reject");
            Command.Action_Argument := T.To_Bounded (Waiting.First_Element);
            To_Task := True;
         else
            --  A requirement, specification or decision: decided here.
            Model_Runner.CLI.Intents.Decide
              (Store, Intent_Waiting.First_Element, Accepting, Screen);
         end if;
      end Decide;

      --  /req, /decision and /spec: the registers of what the project is
      --  meant to be.
      procedure Intent_Command (Store : in out S.Store) is
         After : Names.Vector;
      begin
         for Index in 2 .. Natural (All_Words.Length) loop
            After.Append (All_Words (Index));
         end loop;
         Model_Runner.CLI.Intents.Run
           (Store,
            (if Word = "/req" then Nt.Requirement
             elsif Word = "/decision" then Nt.Decision
             else Nt.Specification),
            After, Screen);
      end Intent_Command;
   begin
      --  A usage error of this command points to its own help.
      Pres.Use_Command (Screen, Word (Word'First + 1 .. Word'Last));
      --  A number naming two entries: which, asked for by name.
      if Number_Ambiguity /= Null_Unbounded_String then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "the number given");
         E.Add_Text (Outcome, "value", To_String (Number_Ambiguity));
         E.Add_Text (Outcome, "detail", "it names both; give the one meant as it is written");
         Number_Ambiguity := Null_Unbounded_String;
         Pres.Report (Screen, Outcome);
         return;
      end if;
      --  The model /work would run on, for what is budgeted as /work does.
      if Agent in Wk.Parenting_Runner'Class then
         Command.Session_Profile := Wk.Parenting_Runner'Class (Agent).Profile;
         Command.Has_Session_Profile := True;
      end if;
      if All_Words.Contains ("--verbose")
        --  Read before the words are parsed: the action is the second.
        and then not (Word = "/task"
                      and then (Natural (All_Words.Length) < 2
                                or else All_Words (2) not in "show" | "context" | "audit" | "list" | "plan"))
      then
         Command.Level := Opt.Verbose;
      end if;
      if Open_Quote then
         Pres.Put_Note (Screen, "cli.project.quote_open");
      end if;
      for Index in 2 .. Natural (All_Words.Length) loop
         declare
            Part : constant String := All_Words (Index);
         begin
            --  --set before NAME=VALUE, as the shell spells it, is the
            --  same as NAME=VALUE alone.
            if Part = "--set" then
               null;
            elsif Is_Setting (Part) and then Ada.Strings.Fixed.Head (Part, 2) /= "--"
              and then Command.Input_Count < Opt.Max_Guards
            then
               Command.Input_Count := Command.Input_Count + 1;
               Command.Inputs (Command.Input_Count) := T.To_Bounded (Part);
               Continues := True;
            elsif Continues and then Ada.Strings.Fixed.Head (Part, 2) /= "--" then
               --  A value runs on to the next NAME=, as /reconfigure takes
               --  one: notes=for users is one value, not a word dropped.
               Command.Inputs (Command.Input_Count) :=
                 T.To_Bounded (T.To_String (Command.Inputs (Command.Input_Count)) & " " & Part);
            else
               Continues := False;
               Positional.Append (Part);
            end if;
         end;
      end loop;

      --  A session works in the directory it was started in: another is
      --  refused by name, not worked in unasked or taken for text.
      if Word /= "/init"
        and then (for some One of All_Words =>
                    One = "--directory"
                    or else (One'Length > 12 and then One (One'First .. One'First + 11) = "--directory="))
      then
         Outcome := E.Make (E.CLI_Option_Not_For_Command);
         E.Add_Text (Outcome, "value", Word);
         E.Add_Text (Outcome, "option", "--directory");
         Pres.Report (Screen, Outcome);
         Pres.Put_Note (Screen, "cli.next.session_directory");
         return;
      end if;

      if Word = "/init" then
         --  --directory DIR as the shell takes it: the project started
         --  there, the template the word that is neither.
         declare
            Template : Unbounded_String;
            Index    : Positive := 1;
         begin
            while Index <= Natural (Positional.Length) loop
               if Positional (Index) = "--directory" and then Index < Natural (Positional.Length) then
                  Command.Project_Directory := T.To_Bounded (Positional (Index + 1));
                  Index := Index + 2;
               elsif Ada.Strings.Fixed.Head (Positional (Index), 12) = "--directory="
                 and then Positional (Index) /= "--directory="
               then
                  Command.Project_Directory := T.To_Bounded
                    (Ada.Strings.Fixed.Delete (Positional (Index), 1, 12));
                  Index := Index + 1;
               elsif Template = Null_Unbounded_String then
                  Template := To_Unbounded_String (Positional (Index));
                  Index := Index + 1;
               else
                  --  One template; an input is NAME=VALUE.
                  Outcome := E.Make (E.CLI_Unexpected_Operand);
                  E.Add_Text (Outcome, "value", Positional (Index) & "; /init takes one template, and"
                              & " each input as NAME=VALUE");
                  Pres.Report (Screen, Outcome);
                  return;
               end if;
            end loop;
            Command.Template_Name := T.To_Bounded (To_String (Template));
         end;
         Model_Runner.CLI.Init.Run (Command, Screen, Status);
         Last_Status := Status;

      --  Several tasks named for one move: each moved as if named alone,
      --  and the next step said once, after the last.
      elsif Word = "/task" and then Argument (1) in "accept" | "reject" | "cancel" | "reopen" | "reconsider"
        and then Argument (3) /= ""
        and then (for all Index in 2 .. Natural (Positional.Length) =>
                    Ada.Strings.Fixed.Index (Positional (Index), "TASK-") = 1)
      then
         declare
            Named : constant Names.Vector := Positional;
         begin
            --  The way on said once, at the end, for the first of them.
            for Index in 2 .. Natural (Named.Length) loop
               Pres.Hold_Next_Steps (Screen, True);
               Command.Action := T.To_Bounded (Named (1));
               Command.Action_Argument := T.To_Bounded (Named (Index));
               Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
               Last_Status := Natural'Max (Last_Status, Status);
            end loop;
            Pres.Hold_Next_Steps (Screen, False);
            if Named (1) in "accept" | "reopen" | "reconsider" then
               Say_First_Ready (Named, 2);
            end if;
         end;
      elsif Word in "/accept" | "/reject" and then Argument (2) /= "" then
         --  Several named: each decided as if named alone.
         declare
            Named : constant Names.Vector := Positional;
         begin
            for Index in 1 .. Natural (Named.Length) loop
               Pres.Hold_Next_Steps (Screen, True);
               Positional.Clear;
               Positional.Append (Named (Index));
               With_Store (Decide'Access);
               if To_Task then
                  To_Task := False;
                  Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
                  Last_Status := Natural'Max (Last_Status, Status);
               end if;
            end loop;
            Pres.Hold_Next_Steps (Screen, False);
            if Word = "/accept" then
               Say_First_Ready (Named, 1);
            end if;
         end;
      elsif Word = "/task" and then Argument (1) = "complete"
        and then (Argument (3) /= "" or else Argument (2) = "all")
      then
         --  Several completed by hand, or all the open ones -- code there
         --  already, taken as done a task at a time, each by its checks.
         declare
            Named : Names.Vector;
         begin
            if Argument (2) = "all" then
               declare
                  Store : S.Store;
                  Read  : E.Error_Info;
               begin
                  S.Open_To_Read (Store, Here, Read);
                  if E.Is_Ok (Read) then
                     Named.Append (Tk.List (Store, "candidate"));
                     Named.Append (Tk.List (Store, "accepted"));
                     --  Failed too: done by hand is what its way on said.
                     Named.Append (Tk.List (Store, "failed"));
                  end if;
                  S.Close (Store);
               end;
            else
               for Index in 2 .. Natural (Positional.Length) loop
                  Named.Append (Positional (Index));
               end loop;
            end if;
            if Named.Is_Empty then
               Pres.Put_Note (Screen, "cli.project.nothing_to_complete");
            --  All of them taken as done by hand: each named, with how it
            --  stands, and asked first where there is someone to ask.
            elsif Argument (2) = "all" and then Model_Runner.CLI.Choosers.Is_Available (Screen) then
               declare
                  Store  : S.Store;
                  Read   : E.Error_Info;
                  Listed : Unbounded_String;
               begin
                  S.Open_To_Read (Store, Here, Read);
                  for Id of Named loop
                     Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                                     & Id & " (" & (if E.Is_Ok (Read) then Tk.State_Of (Store, Id) else "?") & ")");
                  end loop;
                  S.Close (Store);
                  Pres.Put_Message (Screen, "cli.project.complete_all_confirm",
                                    [Loc.Named ("detail", To_String (Listed))]);
                  if not Answered_Yes (Screen) then
                     Pres.Put_Message (Screen, "cli.project.complete_all_kept");
                     Named.Clear;
                  end if;
               end;
            end if;
            for Position in 1 .. Natural (Named.Length) loop
               Command.Action := T.To_Bounded ("complete");
               Command.Action_Argument := T.To_Bounded (Named (Position));
               Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
               Last_Status := Natural'Max (Last_Status, Status);
               --  The project's checks failing fail every one alike: the
               --  rest left, and said, not run to fail the same way.
               if Status = E.Exit_Status (E.Make (E.Framework_Verification_Failed))
                 and then Position < Natural (Named.Length)
               then
                  Pres.Put_Note (Screen, "cli.project.complete_stopped",
                                 [Loc.Named ("count", Image (Natural (Named.Length) - Position))]);
                  exit;
               end if;
            end loop;
         end;

      elsif Word = "/task" and then Argument (1) in "accept" | "reject"
        and then Ada.Characters.Handling.To_Lower (Argument (2)) = "all"
      then
         --  Every candidate, each in turn, as if named alone.
         declare
            Named : Names.Vector;
            Store : S.Store;
            Read  : E.Error_Info;
         begin
            S.Open_To_Read (Store, Here, Read);
            if E.Is_Ok (Read) then
               Named.Append (Tk.List (Store, "candidate"));
            end if;
            S.Close (Store);
            if Named.Is_Empty then
               Pres.Put_Note (Screen, "cli.project.no_pending");
            end if;
            --  Each one's way on held: the first that can be worked, once.
            Pres.Hold_Next_Steps (Screen, True);
            for Id of Named loop
               Command.Action := T.To_Bounded (Argument (1));
               Command.Action_Argument := T.To_Bounded (Id);
               Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
               Last_Status := Natural'Max (Last_Status, Status);
            end loop;
            Pres.Hold_Next_Steps (Screen, False);
            if Argument (1) = "accept" then
               Say_First_Ready (Named, 1);
            end if;
         end;

      elsif Word = "/task" and then Argument (1) in "accept" | "reject" and then Argument (2) = "" then
         --  Accepting with no task named: as /accept is -- the one waiting,
         --  or those waiting, listed.
         With_Store (Decide'Access);
         if To_Task then
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
            Last_Status := Status;
         end if;

      elsif Word = "/task" then
         --  /task TASK-X is the task shown.
         if Ada.Strings.Fixed.Index (Argument (1), "TASK-") = 1 then
            Command.Action := T.To_Bounded ("show");
            Command.Action_Argument := T.To_Bounded (Argument (1));
         else
            Command.Action := T.To_Bounded (Argument (1));
            --  --verbose is how much a look says, not what it is said of;
            --  in a title or a note it is the words typed.
            declare
               Said : constant String := Rest (2);
               At_V : constant Natural :=
                 (if Argument (1) in "show" | "context" | "audit" | "list" | "plan"
                  then Ada.Strings.Fixed.Index (" " & Said & " ", " --verbose ") else 0);
            begin
               Command.Action_Argument := T.To_Bounded
                 (if At_V = 0 then Said
                  else Ada.Strings.Fixed.Trim (Said (Said'First .. At_V - 1) & Said (At_V + 9 .. Said'Last),
                                               Ada.Strings.Both));
            end;
         end if;
         Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
         Last_Status := Status;

      elsif Word in "/accept" | "/reject" then
         With_Store (Decide'Access);
         --  The tasks it decides, each in turn -- the next step said once,
         --  after the last.
         if To_Task then
            declare
               Each : constant Names.Vector := Split (T.To_String (Command.Action_Argument));
            begin
               for Index in 1 .. Natural (Each.Length) loop
                  Pres.Hold_Next_Steps (Screen, Index < Natural (Each.Length));
                  Command.Action_Argument := T.To_Bounded (Each (Index));
                  Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
                  Last_Status := Natural'Max (Last_Status, Status);
               end loop;
               Pres.Hold_Next_Steps (Screen, False);
            end;
         end if;

      elsif Word = "/cancel" then
         if Argument (1) = "" then
            Pres.Put_Note (Screen, "cli.project.nothing_running");
         else
            --  Asked first at a terminal: a cancelled task is ended, and its
            --  agent stopped.
            --  Work waiting in a workspace is refused or asked about by the
            --  cancel itself -- with the way to keep it -- not asked here
            --  first to be refused after.
            if Model_Runner.CLI.Choosers.Is_Available (Screen) and then Argument (2) not in "yes" | "anyway"
              and then not Waiting_In_Workspace (Argument (1))
            then
               declare
                  Store  : S.Store;
                  Read   : E.Error_Info;
                  Titled : Unbounded_String;
               begin
                  if S.Is_Initialized (Here) then
                     S.Open_To_Read (Store, Here, Read);
                     --  One that cannot be cancelled is said so before it is
                     --  asked about: a candidate is rejected, one ended is
                     --  ended already.
                     if E.Is_Ok (Read)
                       and then Tk.State_Of (Store, Argument (1)) in "candidate" | "complete" | "cancelled" | "rejected"
                     then
                        declare
                           Now : constant String := Tk.State_Of (Store, Argument (1));
                        begin
                           S.Close (Store);
                           Outcome := E.Make (E.Framework_Transition_Invalid);
                           E.Add_Text (Outcome, "name", Argument (1));
                           E.Add_Text (Outcome, "value", Now);
                           E.Add_Text (Outcome, "expected", "cancelled");
                           E.Add_Text (Outcome, "detail",
                                       (if Now = "candidate"
                                        then "a candidate is not cancelled but rejected: /task reject "
                                             & Argument (1)
                                        else "it is " & Now & " already"));
                           Pres.Report (Screen, Outcome);
                           Last_Status := E.Exit_Status (Outcome);
                           return;
                        end;
                     end if;
                     if E.Is_Ok (Read) and then Tk.State_Of (Store, Argument (1)) /= "" then
                        declare
                           Defined : R.Item;
                        begin
                           Tk.Definition (Store, Argument (1), Defined, Read);
                           Titled := To_Unbounded_String
                             (R.Get (Defined, "title") & ", " & Tk.State_Of (Store, Argument (1))
                              & (if Tk.State_Of (Store, Argument (1)) = "running"
                                 then "; its agent is stopped" else "")
                              & Model_Runner.CLI.Tasks.Waiting_On_It (Store, Argument (1)));
                        end;
                     end if;
                     S.Close (Store);
                  end if;
                  Pres.Put_Message (Screen, "cli.project.cancel.confirm",
                                    [Loc.Named ("name", Argument (1)),
                                     Loc.Named ("detail", To_String (Titled))]);
                  if not Answered_Yes (Screen) then
                     Pres.Put_Message (Screen, "cli.project.cancel.kept", [Loc.Named ("name", Argument (1))]);
                     return;
                  end if;
               end;
            end if;
            Command.Action := T.To_Bounded ("cancel");
            Command.Cancel_Confirmed := True;
            Command.Action_Argument := T.To_Bounded
              (Argument (1) & (if Argument (2) = "anyway" then " anyway" else ""));
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
            Last_Status := Status;

            --  What its work left in the project, named: cancelling ends
            --  the task, not what it wrote.
            declare
               Store : S.Store;
               Read  : E.Error_Info;
               Held  : R.Item;
            begin
               if S.Is_Initialized (Here) then
                  S.Open_To_Read (Store, Here, Read);
                  if E.Is_Ok (Read) and then Tk.State_Of (Store, Argument (1)) = "cancelled" then
                     S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument (1) & ".state", Held, Read);
                     if E.Is_Ok (Read) and then R.Get (Held, "changed_files") /= ""
                       and then R.Get (Held, "current_workspace") = ""
                     then
                        declare
                           Files : Unbounded_String;
                        begin
                           for Path of Model_Runner.Framework.Lines_Of (R.Get (Held, "changed_files")) loop
                              Append (Files, (if Files = Null_Unbounded_String then "" else ", ") & Path);
                           end loop;
                           Pres.Put_Note (Screen, "cli.project.cancel.left",
                                          [Loc.Named ("name", Argument (1)),
                                           Loc.Named ("detail", To_String (Files))]);
                        end;
                     end if;
                  end if;
                  S.Close (Store);
               end if;
            end;
         end if;

      elsif Word = "/work" then
         Command.Action_Argument := T.To_Bounded (Rest (1));
         --  What is typed while the work runs waits until it ends -- a
         --  Ctrl-C that stops the work included, where the terminal would
         --  otherwise throw it away with the interrupt.
         --  Nor shown amid the work's own lines as it is typed: it is
         --  shown when it is taken up, after.
         declare
            Kept : constant Boolean :=
              Hostkit.Terminal_Control.Keep_Input_On_Interrupt (Hostkit.Descriptors.Standard_Input, True);
            Quiet : constant Boolean :=
              Hostkit.Terminal_Control.Set_Echo (Hostkit.Descriptors.Standard_Input, False);

            procedure Restore is
               Ignored : Boolean;
            begin
               if Kept then
                  Ignored := Hostkit.Terminal_Control.Keep_Input_On_Interrupt
                    (Hostkit.Descriptors.Standard_Input, False);
               end if;
               if Quiet then
                  Ignored := Hostkit.Terminal_Control.Set_Echo (Hostkit.Descriptors.Standard_Input, True);
                  Typed_Ahead := True;
               end if;
            end Restore;
            Before_Run : constant Natural := Model_Runner.Platform.Signals.Interrupts;
         begin
            Model_Runner.CLI.Work.Run_With (Command, Screen, Agent, Status);
            Restore;
            --  Stopped with Ctrl-C: what was typed meanwhile is dropped,
            --  as Ctrl-C at the prompt drops it -- not left to become a
            --  message the next command is read into.
            if Model_Runner.Platform.Signals.Interrupts /= Before_Run then
               declare
                  Ignored : Boolean := Hostkit.Terminal_Control.Discard_Input (Hostkit.Descriptors.Standard_Input);
               begin
                  if Typed_Ahead then
                     Typed_Ahead := False;
                     Pres.Put_Note (Screen, "cli.work.typed_dropped");
                  end if;
               end;
            end if;
         exception
            when others =>
               Restore;
               raise;
         end;
         Last_Status := Status;

      elsif Word in "/scan" | "/tree" | "/sym" | "/refs" | "/deps" | "/users" | "/impact" | "/trace" then
         Command.Action := T.To_Bounded (Word (Word'First + 1 .. Word'Last));
         --  --verbose among the words: all of it, as the shell's option.
         Command.Action_Argument :=
           T.To_Bounded (if Argument (1) = "--verbose" then Argument (2) else Argument (1));
         if All_Words.Contains ("--verbose") then
            Command.Level := Opt.Verbose;
         end if;
         Model_Runner.CLI.Repo.Run (Command, Screen, Status);
         Last_Status := Status;

      elsif Word = "/state" then
         if Argument (1) /= "" then
            --  It takes nothing: a word after it is a mistake to say.
            Outcome := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Outcome, "value", Rest (1) & "; /state takes no argument");
            Pres.Report (Screen, Outcome);
            Last_Status := E.Exit_Status (Outcome);
            return;
         end if;
         With_Store (State'Access);
      elsif Word = "/config" then
         With_Store (Show_Config'Access);
      elsif Word = "/req" and then Argument (1) = "verify" and then Argument (2) /= "" then
         --  The same as /check REQ: one way to verify one, said one way.
         declare
            All_Named : constant Names.Vector := Positional;
         begin
            for Index in 2 .. Natural (All_Named.Length) loop
               Positional.Clear;
               Positional.Append (All_Named (Index));
               With_Store (Check'Access);
            end loop;
         end;
      elsif Word in "/req" | "/decision" | "/spec" then
         With_Store (Intent_Command'Access);
      elsif Word = "/result" then
         --  /result show ID as the registers take it: show is the default.
         if Argument (1) = "show" and then Argument (2) /= "" then
            Positional.Delete_First;
         --  /result list as the registers take it: the list is the default.
         elsif Argument (1) = "list" then
            Positional.Delete_First;
         end if;
         With_Store (Show_Result'Access);
      elsif Word = "/check" and then Argument (2) /= ""
        and then (for all One of Positional =>
                    One'Length > 4 and then One (One'First .. One'First + 3) = "REQ-")
      then
         --  Several requirements: each checked in turn, as if named alone.
         declare
            All_Named : constant Names.Vector := Positional;
         begin
            for One of All_Named loop
               Positional.Clear;
               Positional.Append (One);
               With_Store (Check'Access);
            end loop;
         end;
      elsif Word = "/check" then
         With_Store (Check'Access);
      elsif Word = "/bootstrap" then
         With_Store (Bootstrap'Access);
      elsif Word = "/git" then
         With_Store (Git_Status'Access);
      elsif Word = "/instruct" then
         With_Store (Instruct'Access);
      elsif Word = "/sandbox" then
         --  The run's own confinement, below every other level: it needs
         --  no project, and lasts until changed or the session ends.
         if Natural (All_Words.Length) > 1 then
            declare
               --  All of it, constraints such as roots=src/ included.
               Said : Unbounded_String;
            begin
               for Index in 2 .. Natural (All_Words.Length) loop
                  Append (Said, (if Index = 2 then "" else " ") & All_Words (Index));
               end loop;
               Model_Runner.Framework.Permissions.Set_Sandbox
                 ((if To_String (Said) = "off" then "" else To_String (Said)), Outcome);
            end;
            if E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end if;
         --  A variable that does not read is refused here as work refuses
         --  it, not shown as confining to nothing.
         if Model_Runner.Framework.Permissions.Sandbox_Problem /= "" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", Model_Runner.Framework.Permissions.Sandbox_Variable);
            E.Add_Text (Outcome, "value", Ada.Environment_Variables.Value
                                            (Model_Runner.Framework.Permissions.Sandbox_Variable));
            E.Add_Text (Outcome, "detail", Model_Runner.Framework.Permissions.Sandbox_Problem);
            Pres.Report (Screen, Outcome);
            return;
         end if;
         declare
            use type Model_Runner.Framework.Permissions.Permission_Set;
            Now : constant Model_Runner.Framework.Permissions.Permission_Set :=
              Model_Runner.Framework.Permissions.Sandbox;
         begin
            if Now = Model_Runner.Framework.Permissions.Unrestricted then
               Pres.Put_Note (Screen, "cli.project.sandbox.none");
               --  And what that is, where there is a project to say it.
               if S.Is_Initialized (".") then
                  declare
                     package Pm renames Model_Runner.Framework.Permissions;
                     Store : S.Store;
                     Read  : E.Error_Info;
                     Left  : Unbounded_String;
                  begin
                     S.Open_To_Read (Store, ".", Read);
                     if E.Is_Ok (Read) then
                        for Line of Model_Runner.Framework.Lines_Of
                          (Pm.Image (Pm.Effective (Store, "", "", Within_Sandbox => False)))
                        loop
                           Append (Left, (if Left = Null_Unbounded_String then "" else "; ") & Line);
                        end loop;
                        S.Close (Store);
                        Pres.Put_Message
                          (Screen, "cli.project.sandbox.effective",
                           [Loc.Named ("value", (if Left = Null_Unbounded_String then "nothing"
                                                 else To_String (Left)))]);
                     end if;
                  end;
               end if;
            else
               --  In the form /sandbox takes back: capabilities a ; apart.
               declare
                  Shown : Unbounded_String;
               begin
                  for Line of Model_Runner.Framework.Lines_Of
                    (Model_Runner.Framework.Permissions.Image (Now))
                  loop
                     Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ") & Line);
                  end loop;
                  Pres.Put_Message
                    (Screen, "cli.project.sandbox.set",
                     [Loc.Named ("value", (if Shown = Null_Unbounded_String then "nothing"
                                           else To_String (Shown))),
                      Loc.Named ("name", Model_Runner.Framework.Permissions.Sandbox_Source)]);
                  --  What that leaves agents here, the project's own
                  --  permissions being below it: a sandbox grants nothing
                  --  the project does not.
                  if S.Is_Initialized (".") then
                     declare
                        package Pm renames Model_Runner.Framework.Permissions;
                        Store : S.Store;
                        Read  : E.Error_Info;
                        Left  : Unbounded_String;
                     begin
                        S.Open_To_Read (Store, ".", Read);
                        if E.Is_Ok (Read) then
                           for Line of Model_Runner.Framework.Lines_Of
                             (Pm.Image (Pm.Effective (Store, "", "", Within_Sandbox => True)))
                           loop
                              Append (Left, (if Left = Null_Unbounded_String then "" else "; ") & Line);
                           end loop;
                           S.Close (Store);
                           if To_String (Left) /= To_String (Shown) then
                              Pres.Put_Note
                                (Screen, "cli.project.sandbox.effective",
                                 [Loc.Named ("value", (if Left = Null_Unbounded_String then "nothing"
                                                       else To_String (Left)))]);
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      elsif Word = "/reconfigure" then
         With_Store (Reconfigure'Access);
      end if;
   exception
      --  A fault in one command is that command's: said, with what was
      --  raised where, and the session goes on.
      when Fault : others =>
         Pres.Report (Screen, E.Make (E.Internal_Unexpected_Exception));
         Pres.Put_Note (Screen, "cli.project.internal",
                        [Loc.Named ("name", Word),
                         Loc.Named ("detail", Where_Raised (Ada.Exceptions.Exception_Information (Fault)))]);
         Last_Status := E.Exit_Internal;
   end Run;

   --  The agent a command from the shell has: none. Work is the work
   --  command's, which names its agent.
   type No_Agent is new Model_Runner.Framework.Work.Agent_Runner with null record;

   overriding procedure Run
     (Self        : No_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Check_Start
     (Self   : No_Agent;
      Item   : Model_Runner.Framework.Stores.Store;
      Status : in out E.Error_Info);

   overriding procedure Run
     (Self        : No_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out E.Error_Info)
   is
      pragma Unreferenced (Self, Prompt_Path, Project);
   begin
      Answer := Ada.Strings.Unbounded.Null_Unbounded_String;
      Status := E.Make (E.Framework_Input_Missing);
      E.Add_Text (Status, "name", "model");
   end Run;

   overriding procedure Check_Start
     (Self   : No_Agent;
      Item   : Model_Runner.Framework.Stores.Store;
      Status : in out E.Error_Info)
   is
      pragma Unreferenced (Self, Item);
   begin
      Status := E.Make (E.Framework_Input_Missing);
      E.Add_Text (Status, "name", "model");
   end Check_Start;

   -----------------------
   -- Run_Without_Model --
   -----------------------

   procedure Run_Without_Model
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Ignored : constant Natural := Pres.First_Failure (Screen);
      pragma Unreferenced (Ignored);
   begin
      Last_Status := 0;
      Run (Line, Screen, No_Agent'(null record));
      Status := Natural'Max (Pres.First_Failure (Screen), Last_Status);
   end Run_Without_Model;

   --------------------
   -- Run_With_Agent --
   --------------------

   procedure Run_With_Agent
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class;
      Status : out Natural)
   is
      Ignored : constant Natural := Pres.First_Failure (Screen);
      pragma Unreferenced (Ignored);
   begin
      Last_Status := 0;
      Run (Line, Screen, Agent);
      Status := Natural'Max (Pres.First_Failure (Screen), Last_Status);
   end Run_With_Agent;

end Model_Runner.CLI.Project_Commands;
