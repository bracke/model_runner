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
with Model_Runner.UTF8;
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

   function Read (Path : String) return String
   is (Call ("read_file", "{""path"": """ & Path & """}"));

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

      --  The reply, by number, that stops where the context filled.
      Full_At : Natural := 0;

      --  Whether its replies are held to each generation's limit.
      Keeps   : Boolean := False;

      --  The context a step has for its reply.
      Room_Of : Natural := Natural'Last;
   end record;

   overriding function Keeps_To_Limit (Self : Script) return Boolean is (Self.Keeps);
   --  Whether the next step's room is too small for any reply, once: a
   --  context filled, for its compaction.
   Tight_Once : Boolean := False;

   overriding function Room (Self : Script) return Natural;

   overriding function Cut_Off (Self : Script) return Boolean is (Self.Cut_At > 0 and then Self.Next - 1 = Self.Cut_At);
   overriding function Context_Filled (Self : Script) return Boolean
   is (Self.Full_At > 0 and then Self.Next - 1 = Self.Full_At);

   overriding function Next_Reply (Self : in out Script) return String is
   begin
      if Self.Next = Self.Hook_At and then Self.Hook /= null then
         Self.Hook.all;
      end if;
      Self.Next := Self.Next + 1;
      return (if Self.Next - 1 <= Natural (Self.Replies.Length) then Self.Replies (Self.Next - 1)
              else "done");
   end Next_Reply;

   overriding function Room (Self : Script) return Natural is
   begin
      if Tight_Once then
         Tight_Once := False;
         return 10;
      end if;
      return Self.Room_Of;
   end Room;

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
      --  The call it halts the run at, or none at 0.
      Halt_At : Natural := 0;
   end record;

   overriding function Consider (Self : in out Counter; Named : String; Arguments : String) return Ag.Verdict;

   overriding function Consider (Self : in out Counter; Named : String; Arguments : String) return Ag.Verdict
   is
      pragma Unreferenced (Named, Arguments);
   begin
      Self.Asked := Self.Asked + 1;
      return (if Self.Halt_At > 0 and then Self.Asked = Self.Halt_At then Ag.Halt else Ag.Allow);
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

   --  How many of the last run's calls had no tool answer after them, and
   --  whether it was told that a call of its reply could not be read.
   Unanswered : Natural := 0;
   Told_Lost  : Boolean := False;
   --  Whether it was told its reply ended after its reasoning, and how
   --  many of its turns hold a thought left open.
   Told_Empty : Boolean := False;
   Left_Open  : Natural := 0;
   --  Whether it was told a call of its reply could not be read at all.
   Told_Unreadable : Boolean := False;

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
      Seconds  : Duration := 0.0;
      Total    : Natural := 0;
      Steps    : Positive := 24;
      Talk     : access Conv.History := null;
      Syntax   : Model_Runner.Tools.Call_Syntax := Model_Runner.Tools.Tool_Call_JSON)
   is
      Under    : Harness (Image);
      Session  : L.Session;
      --  The conversation: the caller's where it carries one on, as /work's
      --  rounds do; else one of its own.
      Own      : aliased Conv.History;
      Held     : constant access Conv.History := (if Talk = null then Own'Access else Talk);
      Messages : Conv.History renames Held.all;
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
      if Talk = null or else Conv.Length (Messages) = 0 then
         Conv.Open (Messages, Status => Status);
      end if;
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
         Max_Steps  => Steps,
         Tool_Syntax => Syntax,
         Thinking   => (if Budget > 0 then Model_Runner.Templates.Thinking_On else Model_Runner.Templates.Thinking_Off),
         Think_Budget => Budget,
         Compact    => Compact,
         Watch      => Seen'Unchecked_Access,
         Approve    => Approver,
         Script     => Replies'Unchecked_Access,
         Carry      => Carry,
         Max_Seconds => Seconds,
         Max_Total_Tokens => Total,
         Pace_Tokens => Pace_Tokens,
         Pace        => Pace,
         Result     => Ended);
      --  Each assistant turn's calls, against the tool answers after it.
      Unanswered := 0;
      Told_Lost := False;
      Told_Empty := False;
      Left_Open := 0;
      Told_Unreadable := False;
      for Index in 1 .. Conv.Length (Messages) loop
         if Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index), "Your tool call could not be read") > 0 then
            Told_Unreadable := True;
         end if;
         if Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index), "ended after its reasoning") > 0 then
            Told_Empty := True;
         end if;
         if Conv."=" (Conv.Sender_At (Messages, Index), Conv.Assistant_Role)
           and then Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index), "<think>") > 0
           and then Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index), "</think>") = 0
         then
            Left_Open := Left_Open + 1;
         end if;
         if Conv."=" (Conv.Sender_At (Messages, Index), Conv.User_Role)
           and then (Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index), "could not be read, so it was not run")
                       > 0
                     or else Ada.Strings.Fixed.Index
                               (Conv.Content_At (Messages, Index), "in the middle of one more tool call") > 0)
         then
            Told_Lost := True;
         end if;
         if Conv."=" (Conv.Sender_At (Messages, Index), Conv.Assistant_Role) then
            declare
               Answers : Natural := 0;
               Next    : Positive := Index + 1;
            begin
               while Next <= Conv.Length (Messages)
                 and then Conv."=" (Conv.Sender_At (Messages, Next), Conv.Tool_Role)
               loop
                  Answers := Answers + 1;
                  Next := Next + 1;
               end loop;
               Unanswered := Unanswered + Natural'Max (0, Conv.Call_Count (Messages, Index) - Answers);
            end;
         end if;
      end loop;
      if Talk = null then
         Conv.Close (Messages);
      end if;
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

      --  Cut after a whole call, in the words after it: the call is
      --  whole and runs -- judged by the text's last characters, it was
      --  said to be cut short and not run.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append (Write ("whole.txt", "w") & ASCII.LF & "Now I will");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended);
         Assert (Ada.Directories.Exists (Dir & "/whole.txt"),
                 "a whole call cut in the words after it was not run:" & Seen.Results.Length'Image);
      end;

      --  A whole call that would not read, cut in the words after it, is
      --  told as unreadable: taken for cut in it, the model heard of no
      --  call at all.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<tool_call>{""name"": ""write_file"", ""arguments"": {,}}</tool_call>"
                                 & ASCII.LF & "Let me");
         Replies.Replies.Append (Write ("read-again.txt", "w"));
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended);
         Assert (Told_Unreadable and then Ada.Directories.Exists (Dir & "/read-again.txt"),
                 "a whole call that would not read, cut in the words after it, was not told unreadable");
      end;

      --  In the open form, a whole call and then one cut: the whole one
      --  runs and the cut one is said -- taken for the last call read, the
      --  whole one was not run and the cut one never named.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Put ("open-read.txt", "read me");
         Replies.Replies.Append ("{""name"": ""read_file"", ""arguments"": {""path"": ""open-read.txt""}}" & ASCII.LF
                                 & "{""name"": ""write_file"", ""arguments"": {""path"": ""b.txt"","
                                 & " ""content"": ""abc");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended, Syntax => Model_Runner.Tools.Open_JSON);
         Assert (Natural (Seen.Results.Length) >= 1 and then Has (Seen.Results (1), "read me") and then Told_Lost,
                 "a whole open-form call before one cut was not run, or the cut one not said:"
                 & Seen.Results.Length'Image & " " & Told_Lost'Image);
      end;

      --  A Gemma call cut in a ```tool_call block is said to be cut, not
      --  unreadable: told to write it again in the format, a model wrote it
      --  again as long.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("```tool_call" & ASCII.LF & "write_file(path=""g.txt"", content=""abc");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended, Syntax => Model_Runner.Tools.Python_Code);
         Assert (not Told_Unreadable, "a Gemma call cut in its block was told it could not be read");
      end;

      --  A call cut right at its body's opener is the call cut: read whole
      --  with no arguments, a list or a check ran that was never written.
      declare
         procedure Cut_At (Reply : String; Syntax : Model_Runner.Tools.Call_Syntax; Why : String) is
            Replies : Script;
            Seen    : Recorder;
            Ended   : Ag.Outcome;
         begin
            Replies.Replies.Append (Reply);
            Replies.Cut_At := 1;
            Run (Replies, Seen, Ended, Syntax => Syntax);
            Assert (Seen.Results.Is_Empty or else Has (Seen.Results (1), "length limit"), Why);
         end Cut_At;
      begin
         Cut_At ("<|channel|>commentary to=functions.list_directory <|constrain|>json<|message|>",
                 Model_Runner.Tools.Harmony_Call, "a harmony call cut at its body's opener ran with none");
         Cut_At (">>>list_directory" & ASCII.LF, Model_Runner.Tools.Recipient_JSON,
                 "a recipient call cut at its body's opener ran with none");
      end;

      --  A call cut where the context filled is cut, as one at the reply's
      --  length is: told it could not be read, a model wrote it again as long.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": ""full.txt"","
                                 & " ""content"": ""abc");
         Replies.Full_At := 1;
         Run (Replies, Seen, Ended);
         Assert (not Told_Unreadable, "a call cut where the context filled was told it could not be read");
      end;

      --  A whole Gemma call, braces in its strings, and words after it cut:
      --  no call is left open -- counted as one, the model was told one
      --  more call was cut and not run.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Put ("braced.txt", "  if (x) {");
         Replies.Replies.Append ("```tool_code" & ASCII.LF
                                 & "edit_file(path=""braced.txt"", old_text=""  if (x) {"", new_text=""  if (y) {"")"
                                 & ASCII.LF & "```" & ASCII.LF & "Then I will");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended, Syntax => Model_Runner.Tools.Python_Code);
         Assert (not Told_Lost, "a whole Gemma call with braces in its strings was taken for one left open");
      end;

      --  So too in the open form, where a bracket or a quote in the thought
      --  or the words after the call is no call left open.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<think>f( says 5"" </think>" & Write ("open-whole.txt", "w") & ASCII.LF
                                 & "Next (README");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended, Syntax => Model_Runner.Tools.Open_JSON);
         Assert (Ada.Directories.Exists (Dir & "/open-whole.txt"),
                 "a whole open-form call, with brackets in its thought and after, was taken for cut:"
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

      --  A gate that halts the run at a reply's second call: the first
      --  runs, and the second is answered as not run -- left with no
      --  answer, a conversation picked up again had a call with none.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
         Gate    : aliased Counter;
      begin
         Replies.Replies.Append (Write ("halt-a.txt", "a") & Write ("halt-b.txt", "b"));
         Gate.Halt_At := 2;
         Run (Replies, Seen, Ended, Approver => Gate'Unchecked_Access);
         Assert (Ended.Reason = Ag.Declined and then Ada.Directories.Exists (Dir & "/halt-a.txt")
                 and then not Ada.Directories.Exists (Dir & "/halt-b.txt") and then Unanswered = 0,
                 "a call a halt stopped was left with no answer:" & Unanswered'Image & " "
                 & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  A good call beside a block that will not read: the good one runs,
      --  and the model is told of the other -- all of them went for one.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append
           (Write ("kept.txt", "k") & "<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": }</tool_call>");
         Run (Replies, Seen, Ended);
         Assert (Ada.Directories.Exists (Dir & "/kept.txt") and then Told_Lost,
                 "a block that would not read took the good call with it, or was not said");
      end;

      --  Cut at its length in the middle of its second call: the whole
      --  first one runs -- taken for the call cut short, it was not.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append (Write ("whole.txt", "w") & "<tool_call>{""name"": ""write_file"", ""argu");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended);
         Assert (Ada.Directories.Exists (Dir & "/whole.txt") and then Told_Lost,
                 "a whole call before one cut at the length was not run, or the cut one not said:"
                 & Seen.Results.Length'Image & Seen.Cut_Offs'Image & " " & Told_Lost'Image & " "
                 & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  Halted, and a block lost beside: every call answered before the
      --  model is told of the lost one -- a note among the answers parted
      --  them from their calls.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
         Gate    : aliased Counter;
      begin
         Replies.Replies.Append
           (Write ("both-a.txt", "a") & Write ("both-b.txt", "b")
            & "<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": }</tool_call>");
         Gate.Halt_At := 2;
         Run (Replies, Seen, Ended, Approver => Gate'Unchecked_Access);
         Assert (Unanswered = 0 and then Told_Lost,
                 "a halt's answers were parted from their calls by the note:" & Unanswered'Image);
      end;

      --  A block that would not read in the middle, and a call cut at the
      --  length after it, its object whole and its close not written: the
      --  whole first call runs, the cut one does not -- taken for the lost
      --  block, it ran and wrote its file short.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append
           (Write ("mid-a.txt", "a") & "<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": }</tool_call>"
            & "<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": ""mid-c.txt"","
            & " ""content"": ""cut sh""}}");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended);
         Assert (Ada.Directories.Exists (Dir & "/mid-a.txt") and then not Ada.Directories.Exists (Dir & "/mid-c.txt"),
                 "a call cut at the length after a block that would not read was run:"
                 & Seen.Results.Length'Image & " " & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  Calls left by the step limit, or the token budget, are each
      --  answered as not run: left with none, a conversation picked up
      --  again rendered calls with no answer.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append (Write ("limit-a.txt", "a") & Write ("limit-b.txt", "b"));
         Run (Replies, Seen, Ended, Steps => 1);
         Assert (Ended.Reason = Ag.Step_Limit and then Unanswered = 0,
                 "calls the step limit left were not answered:" & Unanswered'Image & " "
                 & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  A call that will not read, written so again with its chances
      --  spent, is no answer: the run fails, where the markup was handed
      --  back as its answer.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
         Bad     : constant String := "<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": }</tool_call>";
      begin
         for Times in 1 .. 4 loop
            Replies.Replies.Append (Bad);
         end loop;
         Run (Replies, Seen, Ended);
         Assert (Ended.Reason = Ag.Generation_Failed,
                 "a call that would not read, its chances spent, ended as an answer: "
                 & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  Out of room with no turn to drop and compaction not asked for: the
      --  reply made to fit the room left, where the run failed.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append (Write ("fit.txt", "f"));
         Replies.Keeps := True;
         Replies.Room_Of := 900;
         Run (Replies, Seen, Ended, Reply => 1_024);
         Assert (Ada.Directories.Exists (Dir & "/fit.txt"),
                 "a reply was not made to fit the room left without compaction: "
                 & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  A reply cut at its length inside its thought is kept closed: left
      --  open, every later prompt carried it whole.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<think>" & [1 .. 40 => 'm'] & " still");
         Replies.Cut_At := 1;
         Run (Replies, Seen, Ended);
         Assert (Left_Open = 0, "a thought cut at the length was kept open:" & Left_Open'Image);
      end;

      --  A reply whose thought the harness closed at its budget and which
      --  then stopped gave no answer: told so, where it was taken for one.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         --  The budget's 32 tokens of thought, and only a space after.
         Replies.Replies.Append ("<think>" & [1 .. 121 => 'a'] & " ");
         Replies.Replies.Append ("the answer");
         Replies.Keeps := True;
         Run (Replies, Seen, Ended, Budget => 32);
         Assert (Told_Empty and then Ended.Reason = Ag.Answered,
                 "a reply of thought alone was taken for an answer: " & Ag.Stop_Reason'Image (Ended.Reason)
                 & " " & Told_Empty'Image);
      end;

      --  Thought alone every time, its notes spent, with no limit reached:
      --  no answer, not a budget's stop -- said to be the token limit with
      --  no budget set.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         for Count in 1 .. 6 loop
            Replies.Replies.Append ("<think>" & [1 .. 121 => 'a'] & " ");
         end loop;
         Replies.Keeps := True;
         Run (Replies, Seen, Ended, Budget => 32);
         Assert (Ended.Reason = Ag.Generation_Failed,
                 "replies of thought alone, with no limit reached, ended as " & Ag.Stop_Reason'Image (Ended.Reason));
      end;

      --  A whole call after a block that would not read runs too, and the
      --  lost one is said: read only to the bad block, it was dropped unsaid.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append
           ("<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": }</tool_call>"
            & Write ("after-bad.txt", "b"));
         Run (Replies, Seen, Ended);
         Assert (Ada.Directories.Exists (Dir & "/after-bad.txt") and then Told_Lost and then Unanswered = 0,
                 "a whole call after a block that would not read was dropped, or the block not said");
      end;

      --  On the last step, a call block closed that would not read, words
      --  after it: the step limit stopped it, not an answer.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append
           ("<tool_call>{""name"": ""write_file"", ""arguments"": {""path"": }</tool_call>" & ASCII.LF
            & "Done, I think.");
         Run (Replies, Seen, Ended, Steps => 1);
         Assert (Ended.Reason = Ag.Step_Limit,
                 "a call that would not read on the last step, words after it, was an answer: "
                 & Ag.Stop_Reason'Image (Ended.Reason));
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

      --  A reply held to the room, its thought closed at its budget: what
      --  follows the closing is asked for in the room left after it -- a
      --  token past, it was refused every time, and the step made again
      --  with a cap of what the old thought had left.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append ("<think>" & [1 .. 1_200 => 'a'] & Write ("budget.txt", "q"));
         Replies.Keeps := True;
         Replies.Room_Of := 900;
         Run (Replies, Seen, Ended, Budget => 256, Reply => 1_024);
         --  Once to learn the room -- asked for the whole reply, the first
         --  continuation is past it -- and once in it.
         Assert (Ada.Directories.Exists (Dir & "/budget.txt") and then Ended.Thoughts_Closed = 2,
                 "a continuation after a thought, held to the room, was refused:" & Ended.Thoughts_Closed'Image
                 & " " & Ended.Reason'Image);
      end;

      --  After a compaction, a file read again whose answer it dropped is
      --  read to see it again, not a repeat: held to be one, a run
      --  recovering what it had read stopped as going round.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;

         procedure Fill is
         begin
            Tight_Once := True;
         end Fill;
      begin
         for Name of String'("abcdef") loop
            Put ("seen-" & Name & ".txt", "text of " & Name);
            Replies.Replies.Append (Read ("seen-" & Name & ".txt"));
         end loop;
         Replies.Replies.Append (Read ("seen-a.txt"));
         Replies.Replies.Append (Read ("seen-b.txt"));
         Replies.Replies.Append ("done");
         Replies.Keeps := True;
         Replies.Hook_At := 7;
         Replies.Hook := Fill'Unrestricted_Access;
         Run (Replies, Seen, Ended, Compact => True);
         Assert (Ended.Compactions >= 1 and then Ended.Reason = Ag.Answered,
                 "files read again after a compaction dropped them ended the run as "
                 & Ended.Reason'Image & Ended.Compactions'Image);
      end;

      --  So too a change that failed, its error dropped: made again, it
      --  runs again -- told its error was above, where it was not.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;

         procedure Fill is
         begin
            Tight_Once := True;
         end Fill;
      begin
         Put ("failed-a.txt", "text");
         Replies.Replies.Append (Edit ("failed-a.txt", "absent", "x"));
         for Name of String'("bcdef") loop
            Put ("failed-" & Name & ".txt", "text of " & Name);
            Replies.Replies.Append (Read ("failed-" & Name & ".txt"));
         end loop;
         Replies.Replies.Append (Edit ("failed-a.txt", "absent", "x"));
         Replies.Replies.Append ("done");
         Replies.Keeps := True;
         Replies.Hook_At := 7;
         Replies.Hook := Fill'Unrestricted_Access;
         Run (Replies, Seen, Ended, Compact => True);
         Assert (Natural (Seen.Results.Length) = 7 and then Has (Seen.Results (7), "is not in")
                 and then not Has (Seen.Results (7), "already made"),
                 "a failed change made again after a compaction dropped its error was told it was above:"
                 & Seen.Results.Length'Image);
      end;

      --  A compaction keeps the recent turns: a call whose answer is still
      --  among them, made again, is a repeat -- every answer taken for
      --  dropped, a run going round near a full context never stopped.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;

         procedure Fill is
         begin
            Tight_Once := True;
         end Fill;
      begin
         for Name of String'("abcdef") loop
            Put ("kept-" & Name & ".txt", "text of " & Name);
            Replies.Replies.Append (Read ("kept-" & Name & ".txt"));
         end loop;
         Replies.Replies.Append (Read ("kept-f.txt"));
         Replies.Replies.Append (Read ("kept-f.txt"));
         Replies.Replies.Append ("done");
         Replies.Keeps := True;
         Replies.Hook_At := 7;
         Replies.Hook := Fill'Unrestricted_Access;
         Run (Replies, Seen, Ended, Compact => True);
         Assert (Ended.Compactions >= 1 and then Ended.Reason = Ag.Repeating,
                 "a call whose answer a compaction kept, made again, was not a repeat: "
                 & Ended.Reason'Image & Ended.Compactions'Image);
      end;

      --  A run carried on in the same conversation, as /work's rounds are:
      --  what the first run's calls answered is still there, and the same
      --  calls again are repeats -- begun as if none were, they were not.
      declare
         Kept    : aliased Model_Runner.Agent.Recall.Carried;
         Talk    : aliased Conv.History;
         First   : Script;
         Second  : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         First.Replies.Append (Write ("carried.txt", "x"));
         First.Replies.Append ("done");
         Run (First, Seen, Ended, Carry => Kept'Unchecked_Access, Talk => Talk'Access);
         Second.Replies.Append (Write ("carried.txt", "x"));
         Second.Replies.Append (Write ("carried.txt", "x"));
         Second.Replies.Append ("done");
         Run (Second, Seen, Ended, Carry => Kept'Unchecked_Access, Talk => Talk'Access);
         Assert (Ended.Reason = Ag.Repeating,
                 "calls a carried run made again, their answers in the conversation, were not repeats: "
                 & Ended.Reason'Image);
         Conv.Close (Talk);
      end;

      --  A call made again is given the tool's answer again, and the
      --  harness's note as the harness's: kept with the note, the repeat
      --  gave the note back as the tool's, said as quoted.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
      begin
         Replies.Replies.Append (Write ("noted.txt", "one"));
         Replies.Replies.Append (Write ("noted.txt", "two"));
         Replies.Replies.Append (Edit ("noted.txt", "two", "one"));
         Replies.Replies.Append (Edit ("noted.txt", "two", "one"));
         Run (Replies, Seen, Ended);
         Assert (Natural (Seen.Results.Length) = 4 and then Has (Seen.Results (3), "back to a version")
                 and then not Has (Seen.Results (4), "quoted, not the harness"),
                 "a repeat gave the harness's note back as the tool's:"
                 & (if Natural (Seen.Results.Length) = 4 then " " & Seen.Results (4) else Seen.Results.Length'Image));
      end;

      --  A tool's answer cut inside a character, or of a file that is not
      --  UTF-8, is given as text: kept as bytes, the next prompt could not
      --  be read into tokens.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
         Accents : Unbounded_String;
      begin
         for Count in 1 .. 20_000 loop
            Append (Accents, Character'Val (16#C3#) & Character'Val (16#A9#));
         end loop;
         Put ("accents.txt", To_String (Accents));
         Put ("latin.txt", "caf" & Character'Val (16#E9#));
         Replies.Replies.Append (Call ("read_file", "{""path"": ""accents.txt"", ""first_line"": 1}"));
         Replies.Replies.Append (Read ("latin.txt"));
         Run (Replies, Seen, Ended);
         Assert (Natural (Seen.Results.Length) = 2 and then Model_Runner.UTF8.Is_Valid (Seen.Results (1))
                 and then Model_Runner.UTF8.Is_Valid (Seen.Results (2)),
                 "a tool's answer was given as bytes that are not UTF-8");
      end;

      --  A run of many calls keeps its history: held to 256 calls, one of
      --  two calls a step was told its history was too long near its
      --  128th step, whatever room it had.
      declare
         Replies : Script;
         Seen    : Recorder;
         Ended   : Ag.Outcome;
         Lines   : Unbounded_String;
      begin
         for Line in 1 .. 400 loop
            Append (Lines, "line" & Line'Image & ASCII.LF);
         end loop;
         Put ("long.txt", To_String (Lines));
         for Step in 1 .. 150 loop
            declare
               At_Line : constant String := Ada.Strings.Fixed.Trim (Natural'Image (2 * Step), Ada.Strings.Left);
               Next    : constant String := Ada.Strings.Fixed.Trim (Natural'Image (2 * Step + 1), Ada.Strings.Left);
            begin
               Replies.Replies.Append
                 (Call ("read_file", "{""path"": ""long.txt"", ""first_line"": " & At_Line & ", ""last_line"": "
                        & At_Line & "}")
                  & ASCII.LF
                  & Call ("read_file", "{""path"": ""long.txt"", ""first_line"": " & Next & ", ""last_line"": "
                          & Next & "}"));
            end;
         end loop;
         Replies.Replies.Append ("done");
         Run (Replies, Seen, Ended, Steps => 200);
         Assert (Ended.Reason = Ag.Answered and then Natural (Seen.Results.Length) = 300,
                 "a run of three hundred calls ended " & Ended.Reason'Image & " after" & Seen.Results.Length'Image);
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

      --  A call larger than a reply's calls may be is told so and asked
      --  again, and where every one is, the run fails: the markup was kept
      --  as the reply's text, nothing said, and the run ended answered.
      declare
         Large   : constant String := Write ("large.txt", [1 .. Model_Runner.Tools.Max_Call_Bytes + 100 => 'x']);
         Once    : Script;
         Always  : Script;
         Seen    : Recorder;
         Seen_2  : Recorder;
         Ended   : Ag.Outcome;
      begin
         Once.Replies.Append (Large);
         Once.Replies.Append ("done");
         Run (Once, Seen, Ended);
         Assert (Seen.Results.Is_Empty and then not Ada.Directories.Exists (Dir & "/large.txt")
                 and then Once.Next = 3 and then Ended.Reason = Ag.Answered,
                 "a call too large to read was not told and asked again:" & Once.Next'Image
                 & " " & Ag.Stop_Reason'Image (Ended.Reason));
         for Count in 1 .. 6 loop
            Always.Replies.Append (Large);
         end loop;
         Run (Always, Seen_2, Ended);
         Assert (Seen_2.Results.Is_Empty and then Ended.Reason = Ag.Generation_Failed,
                 "calls always too large to read ended the run as " & Ag.Stop_Reason'Image (Ended.Reason));
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

      --  A harmony reply of its analysis alone gave no answer: told so and
      --  asked again, where it ended the run answered with nothing; and
      --  with no tools a reply is kept as its final message, as one with
      --  calls is -- kept raw, the template refused its markers.
      for Tools_On in Boolean loop
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
            Model_Runner.GGUF.Containers.Reader.Parse (Under.Parsed, Under.Source, Status => Status);
            L.Prepare (Under.Ready, Under.Parsed, Under.Source, Status => Status);
            L.Open (Session, Under.Ready, Status => Status);
            Conv.Open (Messages, Status => Status);
            Conv.Append (Messages, Conv.User_Role, "work", Status);
            Model_Runner.Tools.Read
              (Offered,
               (if Tools_On
                then Model_Runner.Tools.Registry.Offered
                       ([Model_Runner.Tools.Registry.Write_Files => True, others => False])
                else "[]"),
               Status);
            Model_Runner.Stops.Open (Stop);
            Runner.Set_Base (Ada.Directories.Full_Name (Dir));
            Request.Max_Tokens := 64;
            Replies.Replies.Append ("<|channel|>analysis<|message|>Only thinking.<|end|>");
            --  And a call that will not read is told so, as in any form --
            --  not that the reply ended after its reasoning.
            if Tools_On then
               Replies.Replies.Append ("<|channel|>commentary to=functions.write_file <|constrain|>json"
                                       & "<|message|>{""path"": ""h.txt"",}<|call|>");
            end if;
            Replies.Replies.Append
              ("<|channel|>analysis<|message|>Now.<|end|><|start|>assistant<|channel|>final<|message|>said");
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
            Assert (Ended.Reason = Ag.Answered and then Replies.Next = (if Tools_On then 4 else 3)
                    and then Conv.Content_At (Messages, Conv.Length (Messages)) = "said"
                    and then (not Tools_On
                              or else (for some Index in 1 .. Conv.Length (Messages) =>
                                         Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index),
                                                                  "Your tool call could not be read") > 0)),
                    "a harmony reply of its analysis alone was taken for the answer, or a reply kept raw"
                    & " (tools " & Tools_On'Image & "): " & Ended.Reason'Image & Replies.Next'Image & " ["
                    & Conv.Content_At (Messages, Conv.Length (Messages)) & "]");
            Conv.Close (Messages);
            Model_Runner.Tools.Close (Offered);
            L.Close (Session);
         end;
      end loop;

      --  Harmony calls that never read, their chances spent: the run failed,
      --  not answered -- the call's close is the end of the generation and
      --  never in the text, and it ended answered with no answer.
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
         Model_Runner.GGUF.Containers.Reader.Parse (Under.Parsed, Under.Source, Status => Status);
         L.Prepare (Under.Ready, Under.Parsed, Under.Source, Status => Status);
         L.Open (Session, Under.Ready, Status => Status);
         Conv.Open (Messages, Status => Status);
         Conv.Append (Messages, Conv.User_Role, "work", Status);
         Model_Runner.Tools.Read
           (Offered, Model_Runner.Tools.Registry.Offered
                       ([Model_Runner.Tools.Registry.Write_Files => True, others => False]), Status);
         Model_Runner.Stops.Open (Stop);
         Runner.Set_Base (Ada.Directories.Full_Name (Dir));
         Request.Max_Tokens := 64;
         for Count in 1 .. 6 loop
            Replies.Replies.Append ("<|channel|>commentary to=functions.write_file <|constrain|>json"
                                    & "<|message|>{""path"": ""h.txt""");
         end loop;
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
            Max_Steps  => 8,
            Watch      => Seen'Unchecked_Access,
            Script     => Replies'Unchecked_Access,
            Result     => Ended);
         Assert (Ended.Reason = Ag.Generation_Failed,
                 "harmony calls that never read ended the run as " & Ended.Reason'Image);
         Conv.Close (Messages);
         Model_Runner.Tools.Close (Offered);
         L.Close (Session);
      end;
      Model_Runner.Bytes.Free (Harmony);
   end An_Unnamed_Syntax_Is_The_Models_Own;

   --  A thought the prompt opened and the reply never closed, the reply
   --  cut at its length: all of it is thought, kept closed, and a call it
   --  drafted on the way is not run -- read as an answer, the drafted call
   --  ran, and the turn was kept unclosed, in every later prompt whole.
   procedure A_Thought_The_Prompt_Opened_Is_Thought
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      function Template_Text return String is
         Held : Ada.Streams.Stream_IO.File_Type;
      begin
         Ada.Streams.Stream_IO.Open (Held, Ada.Streams.Stream_IO.In_File, "fixtures/qwen36-own.jinja");
         declare
            Room : String (1 .. Natural (Ada.Streams.Stream_IO.Size (Held)));
         begin
            String'Read (Ada.Streams.Stream_IO.Stream (Held), Room);
            Ada.Streams.Stream_IO.Close (Held);
            return Room;
         end;
      end Template_Text;

      LF       : constant Character := ASCII.LF;
      Opened   : Model_Runner.Bytes.Byte_Array_Access;

      function Call_Of (Path : String) return String
      is ("<tool_call>" & LF & "<function=write_file>" & LF & "<parameter=path>" & LF & Path & LF
          & "</parameter>" & LF & "<parameter=content>" & LF & "x" & LF & "</parameter>" & LF
          & "</function>" & LF & "</tool_call>");
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Tiny_Model.Build (Opened, Template => Template_Text);

      declare
         Under    : Harness (Opened);
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
         Closed   : Boolean := False;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Under.Parsed, Under.Source, Status => Status);
         L.Prepare (Under.Ready, Under.Parsed, Under.Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not prepare");
         L.Open (Session, Under.Ready, Status => Status);
         Conv.Open (Messages, Status => Status);
         Conv.Append (Messages, Conv.User_Role, "work", Status);
         Model_Runner.Tools.Read
           (Offered, Model_Runner.Tools.Registry.Offered
                       ([Model_Runner.Tools.Registry.Write_Files => True, others => False]), Status);
         Model_Runner.Stops.Open (Stop);
         Runner.Set_Base (Ada.Directories.Full_Name (Dir));
         Request.Max_Tokens := 64;

         --  Cut in its thought after a drafted call; then a thought closed
         --  and a call made; then the answer.
         Replies.Replies.Append ("I could write it:" & LF & Call_Of ("drafted.txt") & LF & "but first");
         Replies.Cut_At := 1;
         Replies.Replies.Append ("Now.</think>" & LF & Call_Of ("made.txt"));
         Replies.Replies.Append ("Done.</think>" & LF & "written");

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
            Max_Steps  => 6,
            Watch      => Seen'Unchecked_Access,
            Script     => Replies'Unchecked_Access,
            Result     => Ended);

         for Index in 1 .. Conv.Length (Messages) loop
            if Conv."=" (Conv.Sender_At (Messages, Index), Conv.Assistant_Role) then
               Closed := Ada.Strings.Fixed.Index (Conv.Content_At (Messages, Index), "but first" & LF & "</think>") > 0
                         or else Closed;
            end if;
         end loop;
         Assert (Ada.Directories.Exists (Dir & "/made.txt") and then not Ada.Directories.Exists (Dir & "/drafted.txt"),
                 "a call drafted in a thought the prompt opened was run, or the one made after was not:"
                 & Seen.Results.Length'Image);
         Assert (Closed, "a thought the prompt opened, cut at the length, was kept unclosed");
         Conv.Close (Messages);
         Model_Runner.Tools.Close (Offered);
         L.Close (Session);
      end;
      Model_Runner.Bytes.Free (Opened);
   end A_Thought_The_Prompt_Opened_Is_Thought;

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
        (T, A_Thought_The_Prompt_Opened_Is_Thought'Access,
         "a thought the prompt opened and the reply never closed is thought");
      Register_Routine
        (T, A_Pace_Is_The_Works_Not_Each_Runs'Access,
         "a pace kept across runs bounds them together");
   end Register_Tests;

end Tests.Agent_Loop_Cases;
