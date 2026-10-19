with Interfaces;
with Model_Runner.Output;
with AUnit.Test_Cases;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with AUnit.Assertions; use AUnit.Assertions;

with Model_Runner.Agent;
with Model_Runner.Agent.Recall;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Registry;
with Model_Runner.Tools.Runner;

with Tiny_Model;

package body Tests.Agent_Loop_Cases is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Agent.Stop_Reason;
   use type Model_Runner.Bytes.Byte_Array_Access;

   package Ag renames Model_Runner.Agent;
   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package Tr renames Model_Runner.Tools.Runner;

   package Text_Lists is new Ada.Containers.Indefinite_Vectors (Positive, String);

   --  Where the scripted runs work.
   Dir : constant String := "obj/agent-loop";

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("the agent loop, held to a script");
   end Name;

   --  A file of the runs' directory, written whole.
   procedure Put (Name, Text : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Dir & "/" & Name);
      Ada.Text_IO.Put (File, Text);
      Ada.Text_IO.Close (File);
   end Put;

   --  A call, as a model writes one in the JSON envelope.
   function Call (Named, Arguments : String) return String
   is ("<tool_call>{""name"": """ & Named & """, ""arguments"": " & Arguments & "}</tool_call>");

   function Write (Path, Content : String) return String
   is (Call ("write_file", "{""path"": """ & Path & """, ""content"": """ & Content & """}"));

   function Edit (Path, Old_Text, New_Text : String) return String
   is (Call ("edit_file", "{""path"": """ & Path & """, ""old_text"": """ & Old_Text
                          & """, ""new_text"": """ & New_Text & """}"));

   --  The replies, one a step; before the one numbered Hook_At, Hook runs
   --  -- the world changing between two of the model's turns.
   type Script is new Ag.Reply_Script with record
      Replies : Text_Lists.Vector;
      Next    : Positive := 1;
      Hook_At : Natural := 0;
      Hook    : access procedure := null;

      --  The reply, by number, that stops at its length limit; none at 0.
      Cut_At  : Natural := 0;

      --  Whether its replies are held to each generation's limit.
      Keeps   : Boolean := False;

      --  The context a step has for its reply.
      Room_Of : Natural := Natural'Last;
   end record;

   overriding function Keeps_To_Limit (Self : Script) return Boolean is (Self.Keeps);
   overriding function Room (Self : Script) return Natural is (Self.Room_Of);

   overriding function Cut_Off (Self : Script) return Boolean is (Self.Cut_At > 0 and then Self.Next - 1 = Self.Cut_At);

   overriding function Next_Reply (Self : in out Script) return String is
   begin
      if Self.Next = Self.Hook_At and then Self.Hook /= null then
         Self.Hook.all;
      end if;
      Self.Next := Self.Next + 1;
      return (if Self.Next - 1 <= Natural (Self.Replies.Length) then Self.Replies (Self.Next - 1)
              else "done");
   end Next_Reply;

   --  What each call answered, in order.
   type Recorder is new Ag.Observer with record
      Results  : Text_Lists.Vector;
      Cut_Offs : Natural := 0;
   end record;

   overriding procedure On_Cut_Off (Self : in out Recorder);

   overriding procedure On_Call
     (Self : in out Recorder; Call : Ag.Invocation; Named : String; Arguments : String) is null;

   overriding procedure On_Result
     (Self      : in out Recorder;
      Call      : Ag.Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Tr.Call_Outcome);

   overriding procedure On_Result
     (Self      : in out Recorder;
      Call      : Ag.Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Tr.Call_Outcome)
   is
      pragma Unreferenced (Call, Named, Arguments, Ended);
   begin
      Self.Results.Append (Result);
   end On_Result;

   --  Every call let through, and counted.
   type Counter is new Ag.Approver with record
      Asked : Natural := 0;
   end record;

   overriding function Consider (Self : in out Counter; Named : String; Arguments : String) return Ag.Verdict;

   overriding function Consider (Self : in out Counter; Named : String; Arguments : String) return Ag.Verdict
   is
      pragma Unreferenced (Named, Arguments);
   begin
      Self.Asked := Self.Asked + 1;
      return Ag.Allow;
   end Consider;

   --  The tiny model, prepared, and what it borrows.
   type Harness (Image : access constant Model_Runner.Bytes.Byte_Array) is limited record
      Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
      Parsed : Model_Runner.GGUF.Containers.Container;
      Ready  : aliased L.Model;
   end record;

   Image : Model_Runner.Bytes.Byte_Array_Access;

   overriding procedure On_Cut_Off (Self : in out Recorder) is
   begin
      Self.Cut_Offs := Self.Cut_Offs + 1;
   end On_Cut_Off;

   --  What the loop showed, as a screen would have it.
   type Collecting is new Model_Runner.Output.Sink with record
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding procedure Write (Self : in out Collecting; Item : String; Closed : out Boolean);
   overriding procedure Flush (Self : in out Collecting; Closed : out Boolean);
   overriding function Is_Closed (Self : Collecting) return Boolean is (False);

   overriding procedure Write (Self : in out Collecting; Item : String; Closed : out Boolean) is
   begin
      Ada.Strings.Unbounded.Append (Self.Text, Item);
      Closed := False;
   end Write;

   overriding procedure Flush (Self : in out Collecting; Closed : out Boolean) is
   begin
      Closed := False;
   end Flush;

   --  Run the loop on a fresh conversation, the replies the script's.
   procedure Run
     (Replies  : in out Script;
      Seen     : in out Recorder;
      Ended    : out Ag.Outcome;
      Carry    : Ag.Memory_Reference := null;
      Approver : Ag.Approver_Reference := null;
      Budget   : Natural := 0;
      Shown    : Model_Runner.Output.Sink_Reference := null;
      Reply    : Positive := 64;
      Compact  : Boolean := False;
      Pace     : Ag.Pace_Reference := null;
      Pace_Tokens : Natural := 0;
      Seconds  : Duration := 0.0)
   is
      Under    : Harness (Image);
      Session  : L.Session;
      Messages : Conv.History;
      Offered  : Model_Runner.Tools.Definitions;
      Runner   : Model_Runner.Tools.Builtin.Instance;
      Stop     : Model_Runner.Stops.Set;
      Request  : Model_Runner.Generation.Request;
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;
      Status   : E.Error_Info;
   begin
      Model_Runner.GGUF.Containers.Reader.Parse (Under.Parsed, Under.Source, Status => Status);
      Assert (E.Is_Ok (Status), "the tiny model did not parse");
      L.Prepare (Under.Ready, Under.Parsed, Under.Source, Status => Status);
      Assert (E.Is_Ok (Status), "the tiny model did not prepare");
      L.Open (Session, Under.Ready, Status => Status);
      Assert (E.Is_Ok (Status), "the tiny model's session did not open");
      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "work", Status);
      Model_Runner.Tools.Read
        (Offered,
         Model_Runner.Tools.Registry.Offered
           ([Model_Runner.Tools.Registry.Read_Files | Model_Runner.Tools.Registry.Write_Files => True,
             others => False]),
         Status);
      Assert (E.Is_Ok (Status), "the built-in tools did not read");
      Model_Runner.Stops.Open (Stop);
      Runner.Set_Base (Ada.Directories.Full_Name (Dir));
      Request.Max_Tokens := Reply;
      Ag.Run
        (Source     => Under.Ready,
         Session    => Session,
         Messages   => Messages,
         Offered    => Offered,
         Executor   => Runner,
         Generation => Request,
         Stop_Set   => Stop,
         Sink       => Shown,
         Time       => Clock'Unchecked_Access,
         Seeds      => Seeds'Unchecked_Access,
         Max_Steps  => 24,
         Thinking   => (if Budget > 0 then Model_Runner.Templates.Thinking_On else Model_Runner.Templates.Thinking_Off),
         Think_Budget => Budget,
         Compact    => Compact,
         Watch      => Seen'Unchecked_Access,
         Approve    => Approver,
         Script     => Replies'Unchecked_Access,
         Carry      => Carry,
         Max_Seconds => Seconds,
         Pace_Tokens => Pace_Tokens,
         Pace        => Pace,
         Result     => Ended);
      Conv.Close (Messages);
      Model_Runner.Tools.Close (Offered);
   end Run;

   function Has (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  The loop's notes, its repeats and its approver, each held to a run.
   procedure Loop_Keeps_To_Its_Rules
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      if Image = null then
         Tiny_Model.Build (Image);
      end if;

      --  A reply cut short mid-call is no call: the watcher is told, the
      --  model is told to go on, and its next reply's call runs.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         --  Cut where not even its tool's name can be read: no call at all.
         Replies.Replies.Append ("<tool_call>{""na");
         Replies.Replies.Append (Write ("cut.txt", "whole"));
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended);
         Assert (Seen.Cut_Offs = 1 and then Natural (Seen.Results.Length) = 1
                 and then Ada.Directories.Exists (Dir & "/cut.txt"),
                 "a reply cut short mid-call was not said, or its call was taken:" & Seen.Cut_Offs'Image
                 & Seen.Results.Length'Image);
      end;

      --  A thought at its budget is closed for the reply -- shown closed --
      --  and what it goes on to write has the whole reply's room again: a
      --  call longer than the half the thought left is written whole.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
         Screen  : aliased Collecting;
         Thought : constant String := "<think>" & [1 .. 200 => 'a'] & " still thinking";
      begin
         Replies.Replies.Append (Thought & "</think>" & Write ("budget.txt", [1 .. 40 => 'x']));
         Replies.Keeps := True;
         Run (Replies, Seen, Ended, Budget => 32, Shown => Screen'Unchecked_Access);
         Assert (Ended.Thoughts_Closed = 1 and then Natural (Seen.Results.Length) = 1
                 and then Ada.Directories.Exists (Dir & "/budget.txt"),
                 "a thought at its budget was not closed, or the call after it was cut short:"
                 & Ended.Thoughts_Closed'Image & Seen.Results.Length'Image);
         Assert (Has (Ada.Strings.Unbounded.To_String (Screen.Text), Ag.Thought_Closing),
                 "a thought closed for the reply was not shown closed");
      end;

      --  A reply that ended within its thought's budget does not hold the
      --  next step to that budget: the request was left at it, and a call
      --  longer than the budget, a step later, was cut and never run.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append (Write ("first.txt", "x"));
         Replies.Replies.Append (Write ("second.txt", [1 .. 100 => 'z']));
         Replies.Keeps := True;
         Run (Replies, Seen, Ended, Budget => 32);
         Assert (Seen.Cut_Offs = 0 and then Ada.Directories.Exists (Dir & "/second.txt"),
                 "a step after one that ended within its budget was held to it:" & Seen.Cut_Offs'Image
                 & Seen.Results.Length'Image);
      end;

      --  A reply cut at its length, again and again, with no call: no
      --  answer -- the cut text was taken for one, and the run said it
      --  answered.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         for Again in 1 .. 4 loop
            Replies.Replies.Append (String'[1 .. 2_000 => 'w']);
         end loop;
         Replies.Keeps := True;
         Run (Replies, Seen, Ended);
         Assert (Ended.Reason = Ag.Token_Limit,
                 "a reply cut at its length every time was taken for the answer: "
                 & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  A thought the reply closed itself, and a call it was writing when
      --  the budget came: asked for after as it stands, and run.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<think>short</think>" & Write ("closed.txt", [1 .. 80 => 'y']));
         Replies.Keeps := True;
         Run (Replies, Seen, Ended, Budget => 32);
         Assert (Ended.Thoughts_Closed = 0 and then Seen.Cut_Offs = 0 and then Natural (Seen.Results.Length) = 1
                 and then Ada.Directories.Exists (Dir & "/closed.txt"),
                 "a call cut at the thought's budget, its thought closed, was not asked for after:"
                 & Ended.Thoughts_Closed'Image & Seen.Cut_Offs'Image & Seen.Results.Length'Image);
      end;

      --  A thought that takes the room its reply needed after it: the step
      --  is tried again with the thought held short, and the call after it
      --  has its room -- where the task failed with the context full.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<think>" & [1 .. 2_100 => 'a'] & "</think>" & Write ("room.txt", "z"));
         Replies.Keeps := True;
         Replies.Room_Of := 900;
         Run (Replies, Seen, Ended, Budget => 512, Reply => 1_024, Compact => True);
         Assert (Natural (Seen.Results.Length) = 1 and then Ada.Directories.Exists (Dir & "/room.txt"),
                 "a step whose thought took its reply's room was not tried again with a shorter one:"
                 & Seen.Results.Length'Image & " " & Ended.Reason'Image);
      end;

      --  A file put back as an earlier write left it is said to be.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         --  Put back by another call: the same call again is a repeat.
         Replies.Replies.Append (Write ("f.txt", "one"));
         Replies.Replies.Append (Write ("f.txt", "two"));
         Replies.Replies.Append (Edit ("f.txt", "two", "one"));
         Run (Replies, Seen, Ended);
         Assert (Ended.Reason = Ag.Answered and then Natural (Seen.Results.Length) = 3
                 and then not Has (Seen.Results (2), "back to a version")
                 and then Has (Seen.Results (3), "back to a version it had earlier"),
                 "a file put back was not said to be, or one written anew was:"
                 & Ended.Reason'Image & Seen.Results.Length'Image
                 & (if Natural (Seen.Results.Length) = 3
                    then " / " & Seen.Results (1) & " / " & Seen.Results (2) & " / " & Seen.Results (3)
                    else ""));
      end;

      --  Carried to a second run, what the first saw is seen: the same put
      --  back is said there; a run that carries nothing does not say it.
      declare
         Kept    : aliased Model_Runner.Agent.Recall.Carried;
         First   : Script;
         Second  : Script;
         Fresh   : Script;
         Seen    : Recorder;
         Seen_2  : Recorder;
         Seen_3  : Recorder;
         Ended   : Ag.Outcome;
      begin
         First.Replies.Append (Write ("g.txt", "one"));
         First.Replies.Append (Write ("g.txt", "two"));
         Run (First, Seen, Ended, Carry => Kept'Unchecked_Access);
         Second.Replies.Append (Edit ("g.txt", "two", "one"));
         Run (Second, Seen_2, Ended, Carry => Kept'Unchecked_Access);
         Assert (Natural (Seen_2.Results.Length) = 1
                 and then Has (Seen_2.Results (1), "back to a version it had earlier"),
                 "a second run carrying the first did not see what the first saw");
         Fresh.Replies.Append (Edit ("g.txt", "one", "two"));
         Run (Fresh, Seen_3, Ended);
         Assert (Natural (Seen_3.Results.Length) = 1 and then not Has (Seen_3.Results (1), "back to a version"),
                 "a run carrying nothing saw what another had");
      end;

      --  A change that failed is refused when made again unchanged, and
      --  runs once the file it would change has moved.
      declare
         procedure Moved is
         begin
            Put ("h.txt", "beta");
         end Moved;

         Replies : Script;
         Again   : Script;
         Seen    : Recorder;
         Seen_2  : Recorder;
         Ended   : Ag.Outcome;
      begin
         Put ("h.txt", "alpha");
         Replies.Replies.Append (Edit ("h.txt", "beta", "gamma"));
         Replies.Replies.Append (Edit ("h.txt", "beta", "gamma"));
         Run (Replies, Seen, Ended);
         Assert (Natural (Seen.Results.Length) >= 2
                 and then Has (Seen.Results (1), "error")
                 and then Has (Seen.Results (2), "already made"),
                 "a failed change made again unchanged was not refused as a repeat");
         Put ("h.txt", "alpha");
         Again.Replies.Append (Edit ("h.txt", "beta", "gamma"));
         Again.Replies.Append (Edit ("h.txt", "beta", "gamma"));
         Again.Hook_At := 2;
         Again.Hook := Moved'Unrestricted_Access;
         Run (Again, Seen_2, Ended);
         Assert (Natural (Seen_2.Results.Length) = 2
                 and then Has (Seen_2.Results (2), "edited"),
                 "a failed change was refused after the file it would change had moved: "
                 & (if Natural (Seen_2.Results.Length) >= 2 then Seen_2.Results (2) else ""));
      end;

      --  Every call of a turn of as many as a reply may make is put to the
      --  approver and run; one more, and none is, and the model is told
      --  and asked again -- not taken to have answered.
      declare
         function Turn_Of (Count : Positive) return String is
            Said : Unbounded_String;
         begin
            for Index in 1 .. Count loop
               Append (Said, Write ("many-" & Ada.Strings.Fixed.Trim (Index'Image, Ada.Strings.Left) & ".txt", "x")
                       & ASCII.LF);
            end loop;
            return To_String (Said);
         end Turn_Of;

         Full    : Script;
         Over    : Script;
         Seen    : Recorder;
         Seen_2  : Recorder;
         Ended   : Ag.Outcome;
         Gate    : aliased Counter;
         Gate_2  : aliased Counter;
      begin
         Full.Replies.Append (Turn_Of (Model_Runner.Tools.Max_Calls));
         Run (Full, Seen, Ended, Approver => Gate'Unchecked_Access);
         Assert (Gate.Asked = Model_Runner.Tools.Max_Calls
                 and then Natural (Seen.Results.Length) = Model_Runner.Tools.Max_Calls
                 and then Ada.Directories.Exists
                            (Dir & "/many-" & Ada.Strings.Fixed.Trim (Model_Runner.Tools.Max_Calls'Image,
                                                                       Ada.Strings.Left) & ".txt"),
                 "a turn of as many calls as a reply may make was not all put to the approver and run:"
                 & Gate.Asked'Image & Seen.Results.Length'Image);
         Over.Replies.Append (Turn_Of (Model_Runner.Tools.Max_Calls + 1));
         Run (Over, Seen_2, Ended, Approver => Gate_2'Unchecked_Access);
         Assert (Gate_2.Asked = 0 and then Seen_2.Results.Is_Empty and then Over.Next = 3
                 and then Ended.Reason = Ag.Answered,
                 "a reply of one call too many was run, or taken for an answer, not told and asked again:"
                 & Gate_2.Asked'Image & Over.Next'Image);
      end;
      Ada.Directories.Delete_Tree (Dir);
   end Loop_Keeps_To_Its_Rules;

   --  A loop not told its model's call syntax reads the model's own: the
   --  tiny model under gpt-oss's template, a reply written in harmony and
   --  the syntax left at its default. run --agent's helpers were run so,
   --  read their calls as JSON, made none on a gpt-oss, Gemma or
   --  Qwen3-Coder model and ended with no answer.
   procedure An_Unnamed_Syntax_Is_The_Models_Own
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      function Template_Text return String is
         Held : Ada.Streams.Stream_IO.File_Type;
      begin
         Ada.Streams.Stream_IO.Open
           (Held, Ada.Streams.Stream_IO.In_File, "fixtures/gpt-oss-own.jinja");
         declare
            Room : String (1 .. Natural (Ada.Streams.Stream_IO.Size (Held)));
         begin
            String'Read (Ada.Streams.Stream_IO.Stream (Held), Room);
            Ada.Streams.Stream_IO.Close (Held);
            return Room;
         end;
      end Template_Text;

      Harmony  : Model_Runner.Bytes.Byte_Array_Access;
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Tiny_Model.Build (Harmony, Template => Template_Text);

      declare
         Under    : Harness (Harmony);
         Session  : L.Session;
         Messages : Conv.History;
         Offered  : Model_Runner.Tools.Definitions;
         Runner   : Model_Runner.Tools.Builtin.Instance;
         Stop     : Model_Runner.Stops.Set;
         Request  : Model_Runner.Generation.Request;
         Clock    : aliased Model_Runner.Clocks.System_Clock;
         Seeds    : aliased Model_Runner.Entropy.Host_Source;
         Status   : E.Error_Info;
         Replies  : aliased Script;
         Seen     : aliased Recorder;
         Ended    : Ag.Outcome;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse
           (Under.Parsed, Under.Source, Status => Status);
         L.Prepare (Under.Ready, Under.Parsed, Under.Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not prepare");
         L.Open (Session, Under.Ready, Status => Status);
         Conv.Open (Messages, Status => Status);
         Conv.Append (Messages, Conv.User_Role, "work", Status);
         Model_Runner.Tools.Read
           (Offered,
            Model_Runner.Tools.Registry.Offered
              ([Model_Runner.Tools.Registry.Write_Files => True, others => False]),
            Status);
         Model_Runner.Stops.Open (Stop);
         Runner.Set_Base (Ada.Directories.Full_Name (Dir));
         Request.Max_Tokens := 64;

         Replies.Replies.Append
           ("<|channel|>analysis<|message|>Write it.<|end|><|start|>assistant"
            & "<|channel|>commentary to=functions.write_file <|constrain|>json"
            & "<|message|>{""path"": ""h.txt"", ""content"": ""one""}");
         Replies.Replies.Append ("<|channel|>final<|message|>written");

         Ag.Run
           (Source     => Under.Ready,
            Session    => Session,
            Messages   => Messages,
            Offered    => Offered,
            Executor   => Runner,
            Generation => Request,
            Stop_Set   => Stop,
            Sink       => null,
            Time       => Clock'Unchecked_Access,
            Seeds      => Seeds'Unchecked_Access,
            Max_Steps  => 4,
            Watch      => Seen'Unchecked_Access,
            Script     => Replies'Unchecked_Access,
            Result     => Ended);

         Assert (Natural (Seen.Results.Length) = 1
                 and then Ada.Directories.Exists (Dir & "/h.txt"),
                 "a harmony call was not read with the syntax unnamed:"
                 & Seen.Results.Length'Image & " calls");
         Assert (Ended.Reason = Ag.Answered,
                 "the run did not end on the final channel's answer: "
                 & Ended.Reason'Image);
         Conv.Close (Messages);
         Model_Runner.Tools.Close (Offered);
         L.Close (Session);
      end;
      Model_Runner.Bytes.Free (Harmony);
   end An_Unnamed_Syntax_Is_The_Models_Own;

   --  A pace kept across runs bounds them together: a task's root run
   --  again to report or to mend was given a fresh pace each time, and so
   --  as many paces as it had runs.
   procedure A_Pace_Is_The_Works_Not_Each_Runs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Clock   : aliased Model_Runner.Clocks.System_Clock;
      Now     : constant Interfaces.Unsigned_64 := Model_Runner.Clocks.Read (Clock'Unchecked_Access);
      --  An earlier run's, begun 0.3 s before this one, its speed such that
      --  50 tokens take 0.2 s: past its pace only where its start is kept
      --  -- a pace begun afresh with this run would have nearly all of it.
      Spent   : aliased Ag.Pace_State :=
        (Started => Interfaces.Unsigned_64'Max (1, Now), Tokens => 50, Spent_Ns => 200_000_000);
      Replies : Script;
      Fresh   : Script;
      Seen    : Recorder;
      Ended   : Ag.Outcome;
   begin
      if not Ada.Directories.Exists (Dir) then
         Ada.Directories.Create_Path (Dir);
      end if;
      if Image = null then
         Tiny_Model.Build (Image);
      end if;
      Replies.Replies.Append ("done");
      delay 0.3;
      Run (Replies, Seen, Ended, Pace => Spent'Unchecked_Access, Pace_Tokens => 50, Seconds => 3_600.0);
      Assert (Ended.Reason = Ag.Timed_Out and then Replies.Next = 1,
              "a run whose work was past its pace already was not stopped before its first reply: "
              & Ag.Stop_Reason'Image (Ended.Reason));
      Fresh.Replies.Append ("done");
      Run (Fresh, Seen, Ended, Pace_Tokens => 50, Seconds => 3_600.0);
      Assert (Ended.Reason = Ag.Answered, "a run paced alone was stopped before any speed was measured: "
              & Ag.Stop_Reason'Image (Ended.Reason));
   end A_Pace_Is_The_Works_Not_Each_Runs;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Loop_Keeps_To_Its_Rules'Access,
         "a reply's calls are noted, refused as repeats and approved as the loop's rules say");
      Register_Routine
        (T, An_Unnamed_Syntax_Is_The_Models_Own'Access,
         "a loop not told its model's call syntax reads the model's own");
      Register_Routine
        (T, A_Pace_Is_The_Works_Not_Each_Runs'Access,
         "a pace kept across runs bounds them together");
   end Register_Tests;

end Tests.Agent_Loop_Cases;
