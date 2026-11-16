with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Process;
with Hostkit.Shell;
with Hostkit.Signals;
with Hostkit.Spawn;
with Hostkit.Spawn.Supervision;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;

with Model_Runner.Config;
with Model_Runner.CLI.Process_Reaper;
with Model_Runner.Errors;
with Model_Runner.Platform.IO_Cancellation;
with Model_Runner.Text;
with Model_Runner.Tools;
with Model_Runner.UTF8;

package body Model_Runner.CLI.MCP is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Calendar.Time;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   package D renames Hostkit.Descriptors;
   package Doc renames Jsonlib.Documents;
   package IOC renames Model_Runner.Platform.IO_Cancellation;
   package T renames Model_Runner.Text;
   use type Doc.Value_Kind;

   --  The most servers, and the most of an answer kept.
   Most_Servers : constant := 16;
   Most_Answer  : constant := 64 * 1024;
   Most_Tools   : constant := Model_Runner.Tools.Max_Definitions;
   Most_Pages   : constant := 64;
   Most_Message : constant := 1024 * 1024;

   --  The shared discovery ceiling, and how long a call may be answered.
   Start_Wait : constant Duration := 30.0;
   Call_Wait  : constant Duration := 300.0;

   type Server is record
      Name     : Unbounded_String;
      Running  : Boolean := False;
      To_It    : D.Descriptor := D.Invalid;
      From_It  : D.Descriptor := D.Invalid;
      Child    : Hostkit.Spawn.Process_Handle := Hostkit.Spawn.Invalid_Process;
      Non_Blocking_Writes : Boolean := False;
      Next_Id  : Positive := 1;
      Pending  : Unbounded_String;   --  bytes read past the last line
      Tools    : Natural := 0;
      Skipped  : Natural := 0;       --  invalid or individually too large
      Why      : Unbounded_String;   --  why it is not running
   end record;

   Servers : array (1 .. Most_Servers) of Server;
   Count   : Natural := 0;
   Started : Boolean := False;
   Omitted_Servers : Natural := 0;

   type Tool is record
      Offered : Unbounded_String;   --  mcp__NAME__TOOL
      Own     : Unbounded_String;   --  the server's name for it
      Owner   : Positive;
      Defined : Unbounded_String;   --  its definition, as offered
   end record;

   package Tool_Lists is new Ada.Containers.Indefinite_Vectors (Positive, Tool);
   type Raw_Tool is record
      Own   : Unbounded_String;
      Told  : Unbounded_String;
      Shape : Unbounded_String;
   end record;
   package Raw_Tool_Lists is new Ada.Containers.Indefinite_Vectors
     (Positive, Raw_Tool);
   package Cursor_Lists is new Ada.Containers.Indefinite_Vectors (Positive, String);
   Tools : Tool_Lists.Vector;
   Discovered : array (1 .. Most_Servers) of Raw_Tool_Lists.Vector;

   Prefix : constant String := "mcp.";

   function Configured return Boolean is
   begin
      for Index in 1 .. Model_Runner.Config.Count loop
         declare
            Key : constant String := Model_Runner.Config.Key_At (Index);
         begin
            if Key'Length > Prefix'Length and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix
              and then Model_Runner.Config.Value_At (Index) /= ""
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Configured;

   function Image (Value : Natural) return String is (T.Image (Long_Long_Integer (Value)));

   --  At most Most bytes, ending between UTF-8 characters. Text from a JSON
   --  document is valid UTF-8; Safe_Prefix_Length withholds only a character
   --  whose bytes straddle the proposed end.
   function UTF8_Prefix (Text : String; Most : Natural) return String is
   begin
      if Text'Length <= Most then
         return Text;
      elsif Most = 0 then
         return "";
      end if;
      declare
         Candidate : constant String := Text (Text'First .. Text'First + Most - 1);
         Kept      : constant Natural := Model_Runner.UTF8.Safe_Prefix_Length (Candidate);
      begin
         return (if Kept = 0 then "" else Candidate (Candidate'First .. Candidate'First + Kept - 1));
      end;
   end UTF8_Prefix;

   --  A name as a tool's name may hold it: letters, digits, _ and -.
   function Plain (Name : String) return String is
      Result : String := Name;
   begin
      for C of Result loop
         if C not in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' then
            C := '_';
         end if;
      end loop;
      return Result;
   end Plain;

   --  Plain is deliberately readable, but is not one-to-one: foo.bar and
   --  foo_bar both become foo_bar. Keep the familiar name where it is free;
   --  a later collision gets a stable numeric suffix, so every definition
   --  still routes to its own server tool.
   function Unique_Offered (Base : String) return String is
      Number : Natural := 1;
   begin
      loop
         declare
            Candidate : constant String :=
              Base & (if Number = 1 then "" else "__" & Image (Number));
            Used : Boolean := False;
         begin
            for One of Tools loop
               if One.Offered = Candidate then
                  Used := True;
                  exit;
               end if;
            end loop;
            if not Used then
               return Candidate;
            end if;
         end;
         Number := Number + 1;
      end loop;
   end Unique_Offered;

   --  Give up an MCP server without waiting in the caller.  This is used when
   --  its input pipe has applied backpressure past a tool deadline: a partial
   --  JSON line makes the connection unusable, and ending the process tree is
   --  what releases a blocking write on hosts without non-blocking pipes.
   procedure Abandon (One : in out Server; Why : String) is
      Sent : Boolean := False;
   begin
      if Hostkit.Spawn.Is_Valid (One.Child) then
         declare
            Group : constant Integer := Hostkit.Spawn.Group_Id (One.Child);
         begin
            if Group > 1 then
               Sent := Hostkit.Signals.Send_To_Group
                 (Group, Hostkit.Signals.Signal_Kill);
            end if;
         exception
            when others =>
               null;
         end;
         if not Sent then
            Sent := Hostkit.Spawn.Supervision.Stop_Now (One.Child);
         end if;
      end if;
      D.Close (One.To_It);
      D.Close (One.From_It);
      One.Running := False;
      One.Why := To_Unbounded_String (Why);
      if Hostkit.Spawn.Is_Valid (One.Child) then
         Model_Runner.CLI.Process_Reaper.Adopt (One.Child);
      end if;
   exception
      when others =>
         D.Close (One.To_It);
         D.Close (One.From_It);
         One.Running := False;
         One.Why := To_Unbounded_String (Why);
         if Hostkit.Spawn.Is_Valid (One.Child) then
            Model_Runner.CLI.Process_Reaper.Adopt (One.Child);
         end if;
   end Abandon;

   function Send
     (One      : in out Server;
      Json     : String;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null)
      return Boolean
   is
      Line  : constant String := Json & ASCII.LF;
      Bytes : Ada.Streams.Stream_Element_Array (1 .. Line'Length);
      Target : constant D.Descriptor := One.To_It;

      function Stopped return Boolean is
        (Model_Runner.Cancellation.Is_Cancelled (Cancel)
         or else (Deadline /= Ada.Real_Time.Time_Last
                  and then Deadline <= Ada.Real_Time.Clock));

      procedure Write_Blocking (Succeeded : out Boolean) is
         Last    : Ada.Streams.Stream_Element_Offset;
         First   : Ada.Streams.Stream_Element_Offset := Bytes'First;
         Outcome : D.Transfer_Outcome;
      begin
         while First <= Bytes'Last loop
            Outcome := D.Write (Target, Bytes (First .. Bytes'Last), Last);
            if D."=" (Outcome, D.Transfer_Ok) and then Last >= First then
               First := Last + 1;
            elsif D."=" (Outcome, D.Transfer_Interrupted) then
               null;
            else
               Succeeded := False;
               return;
            end if;
         end loop;
         Succeeded := True;
      end Write_Blocking;
   begin
      for Index in Line'Range loop
         Bytes (Ada.Streams.Stream_Element_Offset (Index - Line'First + 1)) := Character'Pos (Line (Index));
      end loop;
      if Stopped then
         return False;
      end if;

      if One.Non_Blocking_Writes then
         declare
            Last    : Ada.Streams.Stream_Element_Offset;
            First   : Ada.Streams.Stream_Element_Offset := Bytes'First;
            Outcome : D.Transfer_Outcome;
         begin
            while First <= Bytes'Last loop
               if Stopped then
                  Abandon (One, "its input stayed blocked past the call deadline");
                  return False;
               end if;
               Outcome := D.Write (Target, Bytes (First .. Bytes'Last), Last);
               if D."=" (Outcome, D.Transfer_Ok) and then Last >= First then
                  First := Last + 1;
               elsif D."=" (Outcome, D.Transfer_Interrupted) then
                  null;
               elsif D."=" (Outcome, D.Transfer_Would_Block) then
                  delay 0.005;
               else
                  One.Running := False;
                  One.Why := To_Unbounded_String ("it stopped reading");
                  return False;
               end if;
            end loop;
            return not Stopped;
         end;
      elsif Deadline = Ada.Real_Time.Time_Last
        and then Model_Runner.Cancellation."=" (Cancel, null)
      then
         declare
            Succeeded : Boolean;
         begin
            Write_Blocking (Succeeded);
            if not Succeeded then
               One.Running := False;
               One.Why := To_Unbounded_String ("it stopped reading");
            end if;
            return Succeeded;
         end;
      else
         --  Windows anonymous pipes cannot be made non-blocking.  Keep the
         --  potentially blocking host call in a dependent task registered
         --  for CancelSynchronousIo; process teardown alone is insufficient
         --  when a descendant inherited the pipe's read handle.
         declare
            protected Completion is
               procedure Finish (Value : Boolean);
               entry Wait (Value : out Boolean);
            private
               Ready : Boolean := False;
               Good  : Boolean := False;
            end Completion;

            protected body Completion is
               procedure Finish (Value : Boolean) is
               begin
                  Good := Value;
                  Ready := True;
               end Finish;

               entry Wait (Value : out Boolean) when Ready is
               begin
                  Value := Good;
               end Wait;
            end Completion;

            Registration : IOC.Token;

            task Writer is
               entry Begin_Write (Registered : out Boolean);
            end Writer;
            task body Writer is
               Good       : Boolean := False;
               Can_Cancel : Boolean := False;
            begin
               IOC.Register_Current_Task (Registration, Can_Cancel);
               accept Begin_Write (Registered : out Boolean) do
                  Registered := Can_Cancel;
               end Begin_Write;
               if Can_Cancel then
                  Write_Blocking (Good);
               end if;
               Completion.Finish (Good);
            exception
               when others =>
                  Completion.Finish (False);
            end Writer;

            Finished  : Boolean := False;
            Registered : Boolean := False;
            Succeeded : Boolean := False;
         begin
            Writer.Begin_Write (Registered);
            if not Registered then
               Abandon (One, "the host could not register its blocking input pipe");
               Completion.Wait (Succeeded);
               IOC.Release (Registration);
               return False;
            end if;
            loop
               select
                  Completion.Wait (Succeeded);
                  Finished := True;
               or
                  delay 0.01;
               end select;
               exit when Finished or else Stopped;
            end loop;
            if not Finished then
               declare
                  Cancellation_Requested : constant Boolean :=
                    IOC.Cancel (Registration);
                  pragma Unreferenced (Cancellation_Requested);
               begin
                  null;
               end;
               Abandon (One, "its input stayed blocked past the call deadline");
               --  A successful host cancellation makes the foreign call
               --  return.  Keep even the handoff wait bounded in case the
               --  write completed concurrently with the cancellation.
               select
                  Completion.Wait (Succeeded);
               or
                  delay 1.0;
                  abort Writer;
               end select;
               IOC.Release (Registration);
               return False;
            elsif not Succeeded then
               IOC.Release (Registration);
               One.Running := False;
               One.Why := To_Unbounded_String ("it stopped reading");
               return False;
            end if;
            IOC.Release (Registration);
            return not Stopped;
         end;
      end if;
   end Send;

   --  The next line it wrote, waited for until Deadline or a cancel; ""
   --  then, or where it has gone.
   function Next_Message
     (One      : in out Server;
      Deadline : Ada.Real_Time.Time;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null) return String
   is
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65_536);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         if Deadline <= Ada.Real_Time.Clock
           or else Model_Runner.Cancellation.Is_Cancelled (Cancel)
         then
            return "";
         end if;
         declare
            Ends : constant Natural := Index (One.Pending, [1 => ASCII.LF]);
         begin
            if Ends > 0 then
               declare
                  Line : constant String :=
                    (if Ends = 1 then ""
                     else Ada.Strings.Fixed.Trim (Slice (One.Pending, 1, Ends - 1), Ada.Strings.Both));
               begin
                  Delete (One.Pending, 1, Ends);
                  if Line /= "" then
                     return Line;
                  end if;
               end;
               goto Again;
            end if;
         end;
         loop
            declare
               Left : constant Ada.Real_Time.Time_Span :=
                 Deadline - Ada.Real_Time.Clock;
            begin
               if Left <= Ada.Real_Time.Time_Span_Zero
                 or else (Model_Runner.Cancellation."/=" (Cancel, null)
                          and then Model_Runner.Cancellation.Is_Cancelled (Cancel))
               then
                  return "";
               end if;
               exit when D.Wait_Readable
                 (One.From_It,
                  Integer
                    (Duration'Min
                       (Ada.Real_Time.To_Duration (Left), 0.2) * 1000.0));
            end;
         end loop;
         if D."/=" (D.Read (One.From_It, Buffer, Last), D.Transfer_Ok) or else Last < Buffer'First then
            One.Running := False;
            One.Why := To_Unbounded_String ("it ended");
            return "";
         end if;
         declare
            Before_End : Natural := Natural (Last - Buffer'First + 1);
         begin
            for Position in Buffer'First .. Last loop
               if Buffer (Position) = Ada.Streams.Stream_Element (Character'Pos (ASCII.LF)) then
                  Before_End := Natural (Position - Buffer'First);
                  exit;
               end if;
            end loop;
            if Before_End > Most_Message
              or else Length (One.Pending) > Most_Message - Before_End
            then
               One.Running := False;
               One.Why := To_Unbounded_String ("it wrote a message larger than 1 MiB");
               One.Pending := Null_Unbounded_String;
               return "";
            end if;
         end;
         for B of Buffer (Buffer'First .. Last) loop
            Append (One.Pending, Character'Val (B));
         end loop;
         <<Again>>
      end loop;
   exception
      when others =>
         One.Running := False;
         One.Why := To_Unbounded_String ("its message could not be read");
         One.Pending := Null_Unbounded_String;
         return "";
   end Next_Message;

   --  A request the server made of us: a ping answered, anything else
   --  said to be unknown, so that it does not wait. A notification is let
   --  by.
   procedure Answer_Request
     (One      : in out Server;
      Document : Doc.Document;
      Deadline : Ada.Real_Time.Time;
      Cancel   : Model_Runner.Cancellation.Token_Reference)
   is
      Root : constant Doc.Node := Doc.Root (Document);
      Sent : Boolean;
      pragma Unreferenced (Sent);
   begin
      if not Doc.Has_Member (Document, Root, "id") or else not Doc.Has_Member (Document, Root, "method") then
         return;
      end if;
      declare
         Id     : constant String := Jsonlib.Serializers.To_String (Document, Doc.Member (Document, Root, "id"));
         Method : constant String := Doc.As_String (Document, Doc.Member (Document, Root, "method"));
      begin
         if Method = "ping" then
            Sent := Send
              (One, "{""jsonrpc"":""2.0"",""id"":" & Id & ",""result"":{}}",
               Deadline, Cancel);
         else
            Sent := Send
              (One, "{""jsonrpc"":""2.0"",""id"":" & Id
               & ",""error"":{""code"":-32601,""message"":""not offered by this client""}}",
               Deadline, Cancel);
         end if;
      end;
   exception
      when others =>
         null;
   end Answer_Request;

   --  Ask, and wait for the answer to it: its text, the requests and
   --  notifications before it dealt with. "" where none came.
   function Ask
     (One      : in out Server;
      Method   : String;
      Params   : String;
      Wait     : Duration;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Absolute_Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
      return String
   is
      Id       : constant Positive := One.Next_Id;
      Deadline : Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Duration'Max (0.0, Wait));

      procedure Cancel_Request is
         Cleanup_Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (50);
         Sent : Boolean;
         pragma Unreferenced (Sent);
      begin
         if One.Running then
            Sent := Send
              (One, "{""jsonrpc"":""2.0"",""method"":""notifications/cancelled"",""params"":"
               & "{""requestId"":" & Image (Id) & "}}",
               Cleanup_Deadline);
         end if;
      end Cancel_Request;
   begin
      if Absolute_Deadline /= Ada.Real_Time.Time_Last
        and then Absolute_Deadline < Deadline
      then
         Deadline := Absolute_Deadline;
      end if;
      --  Params are built by the caller before Ask begins.  Recheck both
      --  controls here, at the last boundary before a side-effecting request
      --  is put on the wire.
      if Deadline <= Ada.Real_Time.Clock
        or else Model_Runner.Cancellation.Is_Cancelled (Cancel)
      then
         return "";
      end if;
      One.Next_Id := One.Next_Id + 1;
      if not Send
        (One, "{""jsonrpc"":""2.0"",""id"":" & Image (Id) & ",""method"":" & T.JSON_Quoted (Method)
         & ",""params"":" & Params & "}", Deadline, Cancel)
      then
         --  A complete line may have crossed the boundary just as the write
         --  finished.  A partial line retires the server inside Send; a live
         --  server instead receives the same bounded cancellation as a
         --  response wait that expired.
         Cancel_Request;
         return "";
      end if;
      while One.Running loop
         declare
            Message  : constant String := Next_Message (One, Deadline, Cancel);
            Document : Doc.Document;
            Error    : Jsonlib.Errors.Error_Info;
         begin
            if Message = "" then
               --  Given up on: ask it to stop, but bound even this cleanup so
               --  a server that no longer reads cannot hold the caller.
               Cancel_Request;
               return "";
            end if;
            Jsonlib.Parsers.Parse (Message, Document, Error);
            if not Jsonlib.Errors.Failed (Error) and then Doc.Kind (Document, Doc.Root (Document)) = Doc.Object_Value
            then
               declare
                  Root : constant Doc.Node := Doc.Root (Document);
               begin
                  if Doc.Has_Member (Document, Root, "method") then
                     Answer_Request (One, Document, Deadline, Cancel);
                  elsif Doc.Has_Member (Document, Root, "id")
                    and then Doc.Kind (Document, Doc.Member (Document, Root, "id")) = Doc.Integer_Value
                    and then Doc.As_Integer (Document, Doc.Member (Document, Root, "id")) = Long_Long_Integer (Id)
                  then
                     --  Parsing and validating a bounded but hostile message
                     --  still consumes time.  The owning boundary applies to
                     --  the completed call, not merely to its last read.
                     if Deadline <= Ada.Real_Time.Clock
                       or else Model_Runner.Cancellation.Is_Cancelled (Cancel)
                     then
                        Cancel_Request;
                        return "";
                     end if;
                     return Message;
                  end if;
               end;
            end if;
         end;
      end loop;
      return "";
   end Ask;

   procedure Stop (One : in out Server) is
      procedure Stop_Remaining_Group is
         Group : constant Integer := Hostkit.Spawn.Group_Id (One.Child);
         Sent  : Boolean;
      begin
         if Group > 1 then
            Sent := Hostkit.Signals.Send_To_Group
              (Group, Hostkit.Signals.Signal_Terminate);
            if Sent then
               delay 0.05;
               Sent := Hostkit.Signals.Send_To_Group
                 (Group, Hostkit.Signals.Signal_Kill);
            end if;
         end if;
      exception
         when others =>
            null;
      end Stop_Remaining_Group;

      function Collected return Boolean is
         Result : Hostkit.Spawn.Status;
      begin
         if not Hostkit.Spawn.Is_Valid (One.Child) then
            return True;
         elsif Hostkit.Spawn.Supervision.Has_Ended (One.Child, Result)
         then
            Stop_Remaining_Group;
            Hostkit.Spawn.Release (One.Child);
            return True;
         end if;
         return False;
      end Collected;

      procedure Wait_A_While is
      begin
         for Try in 1 .. 20 loop
            exit when Collected;
            delay 0.05;
         end loop;
      end Wait_A_While;

      procedure Wait_After_Force is
      begin
         for Try in 1 .. 20 loop
            exit when Collected;
            delay 0.05;
         end loop;
      end Wait_After_Force;
   begin
      --  Its input closed is the protocol's graceful way to end it. A child
      --  already observed at EOF still has to be collected.
      D.Close (One.To_It);
      D.Close (One.From_It);
      Wait_A_While;
      if Hostkit.Spawn.Is_Valid (One.Child) then
         declare
            Group : constant Integer := Hostkit.Spawn.Group_Id (One.Child);
            Pid   : constant Integer := Hostkit.Spawn.Process_Id (One.Child);
            Sent  : Boolean := False;
         begin
            if Group > 1 then
               Sent := Hostkit.Signals.Send_To_Group
                 (Group, Hostkit.Signals.Signal_Terminate);
            end if;
            if not Sent then
               Sent := Hostkit.Process.Request_Stop (Pid);
            end if;
            Wait_A_While;
            if Hostkit.Spawn.Is_Valid (One.Child) then
               Sent := False;
               if Group > 1 then
                  Sent := Hostkit.Signals.Send_To_Group
                    (Group, Hostkit.Signals.Signal_Kill);
               end if;
               if not Sent then
                  Sent := Hostkit.Spawn.Supervision.Stop_Now (One.Child);
               end if;
               Wait_After_Force;
               if Hostkit.Spawn.Is_Valid (One.Child) then
                  Model_Runner.CLI.Process_Reaper.Adopt (One.Child);
               end if;
            end if;
         end;
      end if;
      One.Running := False;
   exception
      when others =>
         One.Running := False;
         if Hostkit.Spawn.Is_Valid (One.Child) then
            declare
               Stopped : constant Boolean := Hostkit.Spawn.Supervision.Stop_Now (One.Child);
               pragma Unreferenced (Stopped);
            begin
               Wait_After_Force;
               if Hostkit.Spawn.Is_Valid (One.Child) then
                  Model_Runner.CLI.Process_Reaper.Adopt (One.Child);
               end if;
            end;
         end if;
   end Stop;

   --  Start one server and take its tools.
   procedure Start
     (One     : in out Server;
      Owner   : Positive;
      Command : String;
      Deadline : Ada.Calendar.Time)
   is
      use type Hostkit.Spawn.Spawn_Outcome;
      To_Child   : D.Pipe_Ends := (others => D.Invalid);
      From_Child : D.Pipe_Ends := (others => D.Invalid);
      Quiet      : D.Descriptor := D.Invalid;
      Options : Hostkit.Spawn.Options;
      Words   : Hostkit.String_Vectors.Vector;

      function Time_Left return Duration is
        (Duration'Max (0.0, Deadline - Ada.Calendar.Clock));
   begin
      if Ada.Calendar.Clock >= Deadline then
         One.Why := To_Unbounded_String
           ("discovery did not finish before the shared deadline");
         return;
      end if;
      if not D.Create_Pipe (To_Child) or else not D.Create_Pipe (From_Child)
        or else not D.Set_Inheritable (To_Child.Read_End, True)
        or else not D.Set_Inheritable (From_Child.Write_End, True)
      then
         D.Close (To_Child.Read_End);
         D.Close (To_Child.Write_End);
         D.Close (From_Child.Read_End);
         D.Close (From_Child.Write_End);
         One.Why := To_Unbounded_String ("no pipe to it could be made");
         return;
      end if;
      Options.Input := To_Child.Read_End;
      Options.Output := From_Child.Write_End;
      Options.Group := Hostkit.Spawn.Group_New;
      --  What it logs is not the conversation's.
      if Hostkit.Fs.Null_Device /= ""
        and then D.Open_File (Hostkit.Fs.Null_Device, D.Open_Write_Truncate, Quiet)
        and then D.Set_Inheritable (Quiet, True)
      then
         Options.Error_Output := Quiet;
      end if;
      Words.Append (To_Unbounded_String (Hostkit.Shell.Command_Option));
      Words.Append (To_Unbounded_String (Command));
      if Hostkit.Spawn.Start (Hostkit.Shell.Executable, Words, Options, One.Child) /= Hostkit.Spawn.Spawn_Ok then
         D.Close (To_Child.Read_End);
         D.Close (To_Child.Write_End);
         D.Close (From_Child.Read_End);
         D.Close (From_Child.Write_End);
         D.Close (Quiet);
         One.Why := To_Unbounded_String ("it would not start");
         return;
      end if;
      D.Close (To_Child.Read_End);
      D.Close (From_Child.Write_End);
      D.Close (Quiet);
      One.To_It := To_Child.Write_End;
      One.From_It := From_Child.Read_End;
      To_Child.Write_End := D.Invalid;
      From_Child.Read_End := D.Invalid;
      One.Non_Blocking_Writes := D.Set_Non_Blocking (One.To_It, True);
      One.Running := True;
      if not One.Non_Blocking_Writes and then not IOC.Supported then
         Abandon
           (One, "the host cannot enforce deadlines on its input pipe");
         return;
      end if;

      declare
         Answer   : constant String :=
           Ask (One, "initialize",
                "{""protocolVersion"":""2025-06-18"",""capabilities"":{},"
                & """clientInfo"":{""name"":""model_runner"",""version"":""1""}}", Time_Left);
         Document : Doc.Document;
         Error    : Jsonlib.Errors.Error_Info;
         Accepted    : Boolean := False;
         Offers_Tools : Boolean := False;
      begin
         if Answer /= "" then
            Jsonlib.Parsers.Parse (Answer, Document, Error);
            if not Jsonlib.Errors.Failed (Error)
              and then Doc.Kind (Document, Doc.Root (Document)) = Doc.Object_Value
            then
               declare
                  Root : constant Doc.Node := Doc.Root (Document);
               begin
                  if not Doc.Has_Member (Document, Root, "error")
                    and then Doc.Has_Member (Document, Root, "result")
                    and then Doc.Kind (Document, Doc.Member (Document, Root, "result"))
                               = Doc.Object_Value
                  then
                     declare
                        Result : constant Doc.Node := Doc.Member (Document, Root, "result");
                     begin
                        Accepted :=
                          Doc.Has_Member (Document, Result, "protocolVersion")
                          and then Doc.Kind
                            (Document, Doc.Member (Document, Result, "protocolVersion"))
                              = Doc.String_Value
                          and then Doc.As_String
                            (Document, Doc.Member (Document, Result, "protocolVersion"))
                              = "2025-06-18";
                        Offers_Tools :=
                          Doc.Has_Member (Document, Result, "capabilities")
                          and then Doc.Kind
                            (Document, Doc.Member (Document, Result, "capabilities"))
                              = Doc.Object_Value
                          and then Doc.Has_Member
                            (Document, Doc.Member (Document, Result, "capabilities"), "tools")
                          and then Doc.Kind
                            (Document,
                             Doc.Member
                               (Document, Doc.Member (Document, Result, "capabilities"), "tools"))
                              = Doc.Object_Value;
                     end;
                  end if;
               end;
            end if;
         end if;
         if not Accepted then
            if One.Running then
               One.Why := To_Unbounded_String
                 (if Ada.Calendar.Clock >= Deadline
                  then "discovery did not finish before the shared deadline"
                  elsif Answer = "" then "it did not answer initialize"
                  else "it refused initialize");
            end if;
            Stop (One);
            return;
         elsif not Offers_Tools then
            One.Why := To_Unbounded_String ("it offers no tools capability");
            Stop (One);
            return;
         end if;
      end;
      declare
         Sent : constant Boolean :=
           Send
             (One, "{""jsonrpc"":""2.0"",""method"":""notifications/initialized""}",
              Ada.Real_Time.Clock
              + Ada.Real_Time.To_Time_Span (Time_Left));
      begin
         if not Sent then
            if One.Running then
               One.Why := To_Unbounded_String
                 ("discovery did not finish before the shared deadline");
            end if;
            Stop (One);
            return;
         end if;
      end;

      --  Its tools, page by page.
      declare
         Cursor : Unbounded_String;
         Seen   : Cursor_Lists.Vector;
         Pages  : Natural := 0;
      begin
         loop
            if Ada.Calendar.Clock >= Deadline then
               One.Why := To_Unbounded_String
                 ("discovery did not finish before the shared deadline");
               Stop (One);
               return;
            end if;
            Pages := Pages + 1;
            declare
               Answer   : constant String :=
                 Ask (One, "tools/list",
                      (if Length (Cursor) = 0 then "{}"
                       else "{""cursor"":" & T.JSON_Quoted (To_String (Cursor)) & "}"), Time_Left);
               Document : Doc.Document;
               Error    : Jsonlib.Errors.Error_Info;
               Result   : Doc.Node;
            begin
               if Answer = "" then
                  if One.Running then
                     One.Why := To_Unbounded_String
                       (if Ada.Calendar.Clock >= Deadline
                        then "discovery did not finish before the shared deadline"
                        else "it did not list its tools");
                  end if;
                  Stop (One);
                  return;
               end if;
               Jsonlib.Parsers.Parse (Answer, Document, Error);
               if Jsonlib.Errors.Failed (Error)
                 or else not Doc.Has_Member (Document, Doc.Root (Document), "result")
               then
                  One.Why := To_Unbounded_String ("it refused to list its tools");
                  Stop (One);
                  return;
               end if;
               Result := Doc.Member (Document, Doc.Root (Document), "result");
               if Doc.Has_Member (Document, Result, "tools") then
                  declare
                     List : constant Doc.Node := Doc.Member (Document, Result, "tools");
                  begin
                     for Index in 1 .. Doc.Length (Document, List) loop
                        declare
                           Item : constant Doc.Node := Doc.Element (Document, List, Index);
                        begin
                           if Doc.Kind (Document, Item) /= Doc.Object_Value
                             or else not Doc.Has_Member (Document, Item, "name")
                             or else Doc.Kind
                               (Document, Doc.Member (Document, Item, "name")) /= Doc.String_Value
                             or else not Doc.Has_Member (Document, Item, "inputSchema")
                           then
                              One.Skipped := One.Skipped + 1;
                           elsif Natural (Discovered (Owner).Length) >= Most_Tools
                           then
                              --  The conversation cannot offer more than this
                              --  under any built-in-tool mix. Do not retain an
                              --  unbounded inventory merely to omit it later.
                              One.Skipped := One.Skipped + 1;
                           else
                              declare
                                 Own : constant String :=
                                   Doc.As_String (Document, Doc.Member (Document, Item, "name"));
                              begin
                                 Discovered (Owner).Append
                                   (Raw_Tool'
                                      (Own => To_Unbounded_String (Own),
                                       Told => To_Unbounded_String
                                         (if Doc.Has_Member (Document, Item, "description")
                                            and then Doc.Kind
                                              (Document, Doc.Member (Document, Item, "description"))
                                                = Doc.String_Value
                                          then Doc.As_String
                                            (Document, Doc.Member (Document, Item, "description"))
                                          else Own),
                                       Shape => To_Unbounded_String
                                         (Jsonlib.Serializers.To_String
                                            (Document, Doc.Member (Document, Item, "inputSchema")))));
                              end;
                           end if;
                        end;
                     end loop;
                  end;
               end if;
               if Doc.Has_Member (Document, Result, "nextCursor")
                 and then Doc.Kind (Document, Doc.Member (Document, Result, "nextCursor")) = Doc.String_Value
               then
                  declare
                     Next     : constant String :=
                       Doc.As_String (Document, Doc.Member (Document, Result, "nextCursor"));
                     Repeated : Boolean := Next = "";
                  begin
                     for Previous of Seen loop
                        if Previous = Next then
                           Repeated := True;
                           exit;
                        end if;
                     end loop;
                     if Repeated or else Pages >= Most_Pages then
                        One.Why := To_Unbounded_String
                          (if Repeated then "it repeated a tools/list cursor"
                           else "its tools/list had too many pages");
                        Stop (One);
                        return;
                     end if;
                     Seen.Append (Next);
                     Cursor := To_Unbounded_String (Next);
                  end;
               else
                  exit;
               end if;
            end;
         end loop;
      end;
   exception
      when others =>
         D.Close (To_Child.Read_End);
         D.Close (To_Child.Write_End);
         D.Close (From_Child.Read_End);
         D.Close (From_Child.Write_End);
         D.Close (Quiet);
         One.Why := To_Unbounded_String ("it said something that could not be read");
         Stop (One);
   end Start;

   procedure Start_All (Notes : out Unbounded_String) is
      --  Discovery happens before the first turn, but each server progresses
      --  independently under the same deadline. A slow entry therefore
      --  neither takes time away from a later one nor receives less time merely
      --  because more servers were configured. Leave room after discovery for
      --  the bounded close/terminate/kill sequence in Start's failure path.
      Cleanup_Reserve : constant Duration := 4.0;
      Deadline : constant Ada.Calendar.Time :=
        Ada.Calendar.Clock + Start_Wait - Cleanup_Reserve;
      Commands : array (1 .. Most_Servers) of Unbounded_String;

      protected Completion is
         procedure Done;
         procedure Set_Target (Value : Natural);
         entry Wait_All;
      private
         Finished : Natural := 0;
         Target   : Natural := 0;
      end Completion;

      protected body Completion is
         procedure Done is
         begin
            Finished := Finished + 1;
         end Done;

         procedure Set_Target (Value : Natural) is
         begin
            Target := Value;
         end Set_Target;

         entry Wait_All when Finished >= Target is
         begin
            null;
         end Wait_All;
      end Completion;

      task type Starter (Index : Positive);
      type Starter_Access is access Starter;
      Workers : array (1 .. Most_Servers) of Starter_Access := [others => null];

      task body Starter is
      begin
         Start
           (Servers (Index), Index, To_String (Commands (Index)), Deadline);
         Completion.Done;
      exception
         when others =>
            Servers (Index).Why := To_Unbounded_String
              ("it said something that could not be read");
            Stop (Servers (Index));
            Completion.Done;
      end Starter;

      procedure Free is new Ada.Unchecked_Deallocation
        (Starter, Starter_Access);
   begin
      Notes := Null_Unbounded_String;
      if Started then
         return;
      end if;
      Started := True;

      --  Take a stable snapshot of the configured commands before tasks start.
      for Index in 1 .. Model_Runner.Config.Count loop
         declare
            Key     : constant String := Model_Runner.Config.Key_At (Index);
            Command : constant String := Model_Runner.Config.Value_At (Index);
         begin
            if Key'Length > Prefix'Length
              and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix
              and then Command /= ""
            then
               if Count >= Most_Servers then
                  Omitted_Servers := Omitted_Servers + 1;
               else
                  Count := Count + 1;
                  Servers (Count) :=
                    (Name => To_Unbounded_String
                       (Key (Key'First + Prefix'Length .. Key'Last)),
                     others => <>);
                  Commands (Count) := To_Unbounded_String (Command);
                  Discovered (Count).Clear;
               end if;
            end if;
         end;
      end loop;

      Completion.Set_Target (Count);
      for Index in 1 .. Count loop
         Workers (Index) := new Starter (Index);
      end loop;
      Completion.Wait_All;
      for Index in 1 .. Count loop
         Free (Workers (Index));
      end loop;

      --  Merge in configuration order after discovery has stopped. This keeps
      --  collision suffixes deterministic while no task mutates the inventory.
      for Index in 1 .. Count loop
         if Servers (Index).Running then
            for Found of Discovered (Index) loop
               if Natural (Tools.Length) >= Most_Tools then
                  Servers (Index).Skipped := Servers (Index).Skipped + 1;
               else
                  declare
                     Own     : constant String := To_String (Found.Own);
                     Offered : constant String :=
                       Unique_Offered
                         ("mcp__" & Plain (To_String (Servers (Index).Name))
                          & "__" & Plain (Own));
                     Raw : constant String :=
                       "{""type"": ""function"", ""function"": {""name"": "
                       & T.JSON_Quoted (Offered) & ", ""description"": "
                       & T.JSON_Quoted (UTF8_Prefix (To_String (Found.Told), 2048))
                       & ", ""parameters"": " & To_String (Found.Shape) & "}}";
                     Parsed : Model_Runner.Tools.Definitions;
                     Read   : Model_Runner.Errors.Error_Info;
                  begin
                     Model_Runner.Tools.Read (Parsed, Raw, Read);
                     if Model_Runner.Errors.Is_Ok (Read)
                       and then Model_Runner.Tools.Count (Parsed) = 1
                     then
                        Tools.Append
                          (Tool'
                             (Offered => To_Unbounded_String (Offered),
                              Own     => Found.Own,
                              Owner   => Index,
                              Defined => To_Unbounded_String
                                (Model_Runner.Tools.Definition (Parsed, 1))));
                        Servers (Index).Tools := Servers (Index).Tools + 1;
                     else
                        Servers (Index).Skipped := Servers (Index).Skipped + 1;
                     end if;
                     Model_Runner.Tools.Close (Parsed);
                  end;
               end if;
            end loop;
         end if;
         Discovered (Index).Clear;
         if not Servers (Index).Running then
            Append
              (Notes, (if Length (Notes) = 0 then "" else [1 => ASCII.LF])
               & To_String (Servers (Index).Name) & ": "
               & To_String (Servers (Index).Why));
         elsif Servers (Index).Skipped > 0 then
            Append
              (Notes, (if Length (Notes) = 0 then "" else [1 => ASCII.LF])
               & To_String (Servers (Index).Name) & ": "
               & Image (Servers (Index).Skipped)
               & (if Servers (Index).Skipped = 1 then " tool was" else " tools were")
               & " invalid, too large, or past the limit and omitted");
         end if;
      end loop;
      if Omitted_Servers > 0 then
         Append
           (Notes, (if Length (Notes) = 0 then "" else [1 => ASCII.LF])
            & Image (Omitted_Servers)
            & (if Omitted_Servers = 1 then " configured server was"
               else " configured servers were")
            & " omitted after the limit of " & Image (Most_Servers));
      end if;
   end Start_All;

   function Definitions return String is
      Result : Unbounded_String;
   begin
      for One of Tools loop
         if Servers (One.Owner).Running then
            Append (Result, (if Length (Result) = 0 then "" else ", ") & One.Defined);
         end if;
      end loop;
      return To_String (Result);
   end Definitions;

   procedure Bounded_Definitions
     (Max_Count : Natural;
      Max_Bytes : Natural;
      Result    : out Unbounded_String;
      Count     : out Natural;
      Bytes     : out Natural;
      Omitted   : out Natural)
   is
   begin
      Result := Null_Unbounded_String;
      Count := 0;
      Bytes := 0;
      Omitted := 0;
      for One of Tools loop
         if Servers (One.Owner).Running then
            declare
               --  Definitions keeps both the canonical object and its name
               --  in the same 64 KiB pool.
               Need : constant Natural := Length (One.Defined) + Length (One.Offered);
            begin
               if Count < Max_Count
                 and then Need <= Max_Bytes
                 and then Bytes <= Max_Bytes - Need
               then
                  Append (Result, (if Length (Result) = 0 then "" else ", ") & One.Defined);
                  Count := Count + 1;
                  Bytes := Bytes + Need;
               else
                  Omitted := Omitted + 1;
               end if;
            end;
         end if;
      end loop;
   end Bounded_Definitions;

   function Owns (Named : String) return Boolean is
   begin
      for One of Tools loop
         if One.Offered = Named then
            return True;
         end if;
      end loop;
      return False;
   end Owns;

   procedure Call
     (Named     : String;
      Arguments : String;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Said      : out Unbounded_String;
      Ended     : out Call_End;
      Deadline  : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
   is
      Which : Natural := 0;
      Wait_For : Duration := Call_Wait;
      Call_Deadline : Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Call_Wait);

      --  Parsing and rendering a response are part of the bounded call too.
      --  All response exits pass this point so a cancellation or deadline
      --  reached after Ask returned cannot be mistaken for a protocol error.
      function Interrupted return Boolean is
      begin
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Said := To_Unbounded_String ("cancelled");
            Ended := Cancelled;
            return True;
         elsif Ada.Real_Time.Clock >= Call_Deadline then
            Said := To_Unbounded_String
              ("the server did not answer within" & Duration'Image (Wait_For)
               & " seconds");
            Ended := Timed_Out;
            return True;
         end if;
         return False;
      end Interrupted;
   begin
      Said := Null_Unbounded_String;
      Ended := Failed;
      --  A tool request may have side effects.  Observe a standing
      --  cancellation before Ask has an opportunity to put it on the wire.
      if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
         Said := To_Unbounded_String ("cancelled");
         Ended := Cancelled;
         return;
      end if;
      if Deadline /= Ada.Real_Time.Time_Last and then Deadline < Call_Deadline then
         Call_Deadline := Deadline;
      end if;
      if Call_Deadline /= Ada.Real_Time.Time_Last then
         declare
            Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            if Call_Deadline <= Now then
               Said := To_Unbounded_String ("the tool deadline expired before the server call");
               Ended := Timed_Out;
               return;
            end if;
            Wait_For := Duration'Min
              (Call_Wait, Ada.Real_Time.To_Duration (Call_Deadline - Now));
         end;
      end if;
      for Index in 1 .. Natural (Tools.Length) loop
         if Tools (Index).Offered = Named then
            Which := Index;
            exit;
         end if;
      end loop;
      if Which = 0 then
         Said := To_Unbounded_String ("no server offers " & Named);
         return;
      end if;
      declare
         Owner : Server renames Servers (Tools (Which).Owner);
      begin
         if not Owner.Running then
            Said := To_Unbounded_String
              ("the server " & To_String (Owner.Name) & " is not running: " & To_String (Owner.Why));
            return;
         end if;
         declare
            Answer   : constant String :=
              Ask (Owner, "tools/call",
                   "{""name"":" & T.JSON_Quoted (To_String (Tools (Which).Own))
                   & ",""arguments"":" & (if Arguments = "" then "{}" else Arguments) & "}",
                   Wait_For, Cancel, Absolute_Deadline => Call_Deadline);
            Document : Doc.Document;
            Error    : Jsonlib.Errors.Error_Info;
         begin
            if Answer = "" then
               if Interrupted then
                  null;
               elsif Owner.Running then
                  Ended := Timed_Out;
                  Said := To_Unbounded_String ("the server did not answer within" & Duration'Image (Wait_For)
                                               & " seconds");
               else
                  Said := To_Unbounded_String ("the server " & To_String (Owner.Name) & " ended");
               end if;
               return;
            end if;
            Jsonlib.Parsers.Parse (Answer, Document, Error);
            if Interrupted then
               return;
            end if;
            if Jsonlib.Errors.Failed (Error) then
               Said := To_Unbounded_String ("the server's answer could not be read");
               return;
            end if;
            declare
               Root : constant Doc.Node := Doc.Root (Document);
            begin
               --  Refused by the protocol: its message.
               if Doc.Has_Member (Document, Root, "error") then
                  declare
                     Fault : constant Doc.Node := Doc.Member (Document, Root, "error");
                  begin
                     Said := To_Unbounded_String
                       ("the server refused the call: "
                        & (if Doc.Has_Member (Document, Fault, "message")
                           then Doc.As_String (Document, Doc.Member (Document, Fault, "message"))
                           else Jsonlib.Serializers.To_String (Document, Fault)));
                  end;
                  if Interrupted then
                     return;
                  end if;
                  return;
               end if;
               declare
                  Result : constant Doc.Node := Doc.Member (Document, Root, "result");
                  Erred  : constant Boolean :=
                    Doc.Has_Member (Document, Result, "isError")
                    and then Doc.Kind (Document, Doc.Member (Document, Result, "isError")) = Doc.Boolean_Value
                    and then Doc.As_Boolean (Document, Doc.Member (Document, Result, "isError"));
               begin
                  if Doc.Has_Member (Document, Result, "content") then
                     declare
                        List : constant Doc.Node := Doc.Member (Document, Result, "content");
                     begin
                        for Index in 1 .. Doc.Length (Document, List) loop
                           declare
                              Item : constant Doc.Node := Doc.Element (Document, List, Index);
                              Kind : constant String :=
                                (if Doc.Has_Member (Document, Item, "type")
                                 then Doc.As_String (Document, Doc.Member (Document, Item, "type")) else "");
                              Piece : constant String :=
                                (if Kind = "text" and then Doc.Has_Member (Document, Item, "text")
                                 then Doc.As_String (Document, Doc.Member (Document, Item, "text"))
                                 elsif Kind = "resource" and then Doc.Has_Member (Document, Item, "resource")
                                   and then Doc.Has_Member
                                     (Document, Doc.Member (Document, Item, "resource"), "text")
                                 then Doc.As_String
                                   (Document, Doc.Member (Document, Doc.Member (Document, Item, "resource"), "text"))
                                 else "[" & (if Kind = "" then "content" else Kind)
                                      & (if Doc.Has_Member (Document, Item, "mimeType")
                                         then ", " & Doc.As_String (Document, Doc.Member (Document, Item, "mimeType"))
                                         else "")
                                      & ", not shown]");
                           begin
                              Append (Said, (if Length (Said) = 0 then "" else [1 => ASCII.LF]) & Piece);
                           end;
                        end loop;
                     end;
                  end if;
                  --  Structured content is result data in its own right. A
                  --  server may accompany it with a short human summary which
                  --  does not repeat every field, so retain both forms.
                  if Doc.Has_Member (Document, Result, "structuredContent") then
                     Append
                       (Said, (if Length (Said) = 0 then "" else [1 => ASCII.LF])
                        & Jsonlib.Serializers.To_String
                            (Document, Doc.Member (Document, Result, "structuredContent")));
                  end if;
                  if Length (Said) > Most_Answer then
                     declare
                        Whole : constant String := To_String (Said);
                        Kept  : constant String := UTF8_Prefix (Whole, Most_Answer);
                     begin
                        Said := To_Unbounded_String
                          (Kept & ASCII.LF & "["
                           & Image (Whole'Length - Kept'Length) & " more bytes left out]");
                     end;
                  end if;
                  if not Interrupted then
                     Ended := (if Erred then Failed else Answered);
                  end if;
               end;
            end;
         end;
      end;
   exception
      when others =>
         if not Interrupted then
            Said := To_Unbounded_String ("the server's answer could not be read");
            Ended := Failed;
         end if;
   end Call;

   function Listing return String is
      Result : Unbounded_String;
   begin
      for Index in 1 .. Count loop
         Append (Result, (if Length (Result) = 0 then "" else [1 => ASCII.LF])
                 & To_String (Servers (Index).Name) & ": "
                 & (if Servers (Index).Running
                    then "running, " & Image (Servers (Index).Tools)
                         & (if Servers (Index).Tools = 1 then " tool" else " tools")
                    else "not running -- " & To_String (Servers (Index).Why)));
      end loop;
      if Omitted_Servers > 0 then
         Append
           (Result, (if Length (Result) = 0 then "" else [1 => ASCII.LF])
            & Image (Omitted_Servers)
            & (if Omitted_Servers = 1 then " configured server omitted"
               else " configured servers omitted")
            & " -- limit " & Image (Most_Servers));
      end if;
      return To_String (Result);
   end Listing;

   procedure Stop_All is
   begin
      for Index in 1 .. Count loop
         Stop (Servers (Index));
         Discovered (Index).Clear;
      end loop;
      Count := 0;
      Omitted_Servers := 0;
      Tools.Clear;
      Started := False;
   end Stop_All;

end Model_Runner.CLI.MCP;
