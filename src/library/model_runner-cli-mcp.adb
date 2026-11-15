with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
with Ada.Streams;
with Ada.Strings.Fixed;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Shell;
with Hostkit.Signals;
with Hostkit.Spawn;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;

with Model_Runner.Config;
with Model_Runner.Text;

package body Model_Runner.CLI.MCP is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Calendar.Time;
   package D renames Hostkit.Descriptors;
   package Doc renames Jsonlib.Documents;
   package T renames Model_Runner.Text;
   use type Doc.Value_Kind;

   --  The most servers, and the most of an answer kept.
   Most_Servers : constant := 16;
   Most_Answer  : constant := 64 * 1024;

   --  How long a server is given to start and list its tools, and a call to
   --  be answered.
   Start_Wait : constant Duration := 30.0;
   Call_Wait  : constant Duration := 300.0;

   type Server is record
      Name     : Unbounded_String;
      Running  : Boolean := False;
      To_It    : D.Descriptor := D.Invalid;
      From_It  : D.Descriptor := D.Invalid;
      Child    : Hostkit.Spawn.Process_Handle;
      Next_Id  : Positive := 1;
      Pending  : Unbounded_String;   --  bytes read past the last line
      Tools    : Natural := 0;
      Why      : Unbounded_String;   --  why it is not running
   end record;

   Servers : array (1 .. Most_Servers) of Server;
   Count   : Natural := 0;
   Started : Boolean := False;

   type Tool is record
      Offered : Unbounded_String;   --  mcp__NAME__TOOL
      Own     : Unbounded_String;   --  the server's name for it
      Owner   : Positive;
      Defined : Unbounded_String;   --  its definition, as offered
   end record;

   package Tool_Lists is new Ada.Containers.Indefinite_Vectors (Positive, Tool);
   Tools : Tool_Lists.Vector;

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

   procedure Send (One : in out Server; Json : String) is
      Line  : constant String := Json & ASCII.LF;
      Bytes : Ada.Streams.Stream_Element_Array (1 .. Line'Length);
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      for Index in Line'Range loop
         Bytes (Ada.Streams.Stream_Element_Offset (Index - Line'First + 1)) := Character'Pos (Line (Index));
      end loop;
      if D."/=" (D.Write (One.To_It, Bytes, Last), D.Transfer_Ok) then
         One.Running := False;
         One.Why := To_Unbounded_String ("it stopped reading");
      end if;
   end Send;

   --  The next line it wrote, waited for until Deadline or a cancel; ""
   --  then, or where it has gone.
   function Next_Message
     (One      : in out Server;
      Deadline : Ada.Calendar.Time;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null) return String
   is
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65_536);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         declare
            Held : constant String := To_String (One.Pending);
            Ends : constant Natural := Ada.Strings.Fixed.Index (Held, [1 => ASCII.LF]);
         begin
            if Ends > 0 then
               One.Pending := To_Unbounded_String (Held (Ends + 1 .. Held'Last));
               declare
                  Line : constant String := Ada.Strings.Fixed.Trim (Held (Held'First .. Ends - 1), Ada.Strings.Both);
               begin
                  if Line /= "" then
                     return Line;
                  end if;
               end;
               goto Again;
            end if;
         end;
         loop
            declare
               Left : constant Duration := Deadline - Ada.Calendar.Clock;
            begin
               if Left <= 0.0
                 or else (Model_Runner.Cancellation."/=" (Cancel, null)
                          and then Model_Runner.Cancellation.Is_Cancelled (Cancel))
               then
                  return "";
               end if;
               exit when D.Wait_Readable (One.From_It, Integer (Duration'Min (Left, 0.2) * 1000.0));
            end;
         end loop;
         if D."/=" (D.Read (One.From_It, Buffer, Last), D.Transfer_Ok) or else Last < Buffer'First then
            One.Running := False;
            One.Why := To_Unbounded_String ("it ended");
            return "";
         end if;
         for B of Buffer (Buffer'First .. Last) loop
            Append (One.Pending, Character'Val (B));
         end loop;
         <<Again>>
      end loop;
   exception
      when others =>
         return "";
   end Next_Message;

   --  A request the server made of us: a ping answered, anything else
   --  said to be unknown, so that it does not wait. A notification is let
   --  by.
   procedure Answer_Request (One : in out Server; Document : Doc.Document) is
      Root : constant Doc.Node := Doc.Root (Document);
   begin
      if not Doc.Has_Member (Document, Root, "id") or else not Doc.Has_Member (Document, Root, "method") then
         return;
      end if;
      declare
         Id     : constant String := Jsonlib.Serializers.To_String (Document, Doc.Member (Document, Root, "id"));
         Method : constant String := Doc.As_String (Document, Doc.Member (Document, Root, "method"));
      begin
         if Method = "ping" then
            Send (One, "{""jsonrpc"":""2.0"",""id"":" & Id & ",""result"":{}}");
         else
            Send (One, "{""jsonrpc"":""2.0"",""id"":" & Id
                       & ",""error"":{""code"":-32601,""message"":""not offered by this client""}}");
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
      Cancel   : Model_Runner.Cancellation.Token_Reference := null) return String
   is
      Id       : constant Positive := One.Next_Id;
      Deadline : constant Ada.Calendar.Time := Ada.Calendar.Clock + Wait;
   begin
      One.Next_Id := One.Next_Id + 1;
      Send (One, "{""jsonrpc"":""2.0"",""id"":" & Image (Id) & ",""method"":" & T.JSON_Quoted (Method)
                 & ",""params"":" & Params & "}");
      while One.Running loop
         declare
            Message  : constant String := Next_Message (One, Deadline, Cancel);
            Document : Doc.Document;
            Error    : Jsonlib.Errors.Error_Info;
         begin
            if Message = "" then
               --  Given up on: the server asked to stop working on it.
               if One.Running then
                  Send (One, "{""jsonrpc"":""2.0"",""method"":""notifications/cancelled"",""params"":"
                             & "{""requestId"":" & Image (Id) & "}}");
               end if;
               return "";
            end if;
            Jsonlib.Parsers.Parse (Message, Document, Error);
            if not Jsonlib.Errors.Failed (Error) and then Doc.Kind (Document, Doc.Root (Document)) = Doc.Object_Value
            then
               declare
                  Root : constant Doc.Node := Doc.Root (Document);
               begin
                  if Doc.Has_Member (Document, Root, "method") then
                     Answer_Request (One, Document);
                  elsif Doc.Has_Member (Document, Root, "id")
                    and then Doc.Kind (Document, Doc.Member (Document, Root, "id")) = Doc.Integer_Value
                    and then Doc.As_Integer (Document, Doc.Member (Document, Root, "id")) = Long_Long_Integer (Id)
                  then
                     return Message;
                  end if;
               end;
            end if;
         end;
      end loop;
      return "";
   end Ask;

   procedure Stop (One : in out Server) is
      Result : Hostkit.Spawn.Status;
   begin
      if One.Running then
         --  Its input closed is the protocol's way to end it.
         D.Close (One.To_It);
         for Try in 1 .. 20 loop
            exit when Hostkit.Spawn.Wait (One.Child, Hostkit.Spawn.Wait_Poll, Result);
            delay 0.05;
         end loop;
         if not Hostkit.Spawn.Wait (One.Child, Hostkit.Spawn.Wait_Poll, Result) then
            if Hostkit.Signals.Send_To_Process
                 (Hostkit.Spawn.Process_Id (One.Child), Hostkit.Signals.Signal_Terminate)
            then
               null;
            end if;
            for Try in 1 .. 20 loop
               exit when Hostkit.Spawn.Wait (One.Child, Hostkit.Spawn.Wait_Poll, Result);
               delay 0.05;
            end loop;
         end if;
      end if;
      D.Close (One.To_It);
      D.Close (One.From_It);
      One.Running := False;
   exception
      when others =>
         One.Running := False;
   end Stop;

   --  Start one server and take its tools.
   procedure Start (One : in out Server; Command : String) is
      use type Hostkit.Spawn.Spawn_Outcome;
      To_Child, From_Child : D.Pipe_Ends;
      Quiet   : D.Descriptor;
      Options : Hostkit.Spawn.Options;
      Words   : Hostkit.String_Vectors.Vector;
   begin
      if not D.Create_Pipe (To_Child) or else not D.Create_Pipe (From_Child)
        or else not D.Set_Inheritable (To_Child.Read_End, True)
        or else not D.Set_Inheritable (From_Child.Write_End, True)
      then
         One.Why := To_Unbounded_String ("no pipe to it could be made");
         return;
      end if;
      Options.Input := To_Child.Read_End;
      Options.Output := From_Child.Write_End;
      --  What it logs is not the conversation's.
      if D.Open_File ("/dev/null", D.Open_Write_Truncate, Quiet) and then D.Set_Inheritable (Quiet, True) then
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
      One.Running := True;

      if Ask (One, "initialize",
              "{""protocolVersion"":""2025-06-18"",""capabilities"":{},"
              & """clientInfo"":{""name"":""model_runner"",""version"":""1""}}", Start_Wait) = ""
      then
         One.Why := To_Unbounded_String ("it did not answer initialize");
         Stop (One);
         return;
      end if;
      Send (One, "{""jsonrpc"":""2.0"",""method"":""notifications/initialized""}");

      --  Its tools, page by page.
      declare
         Cursor : Unbounded_String;
      begin
         loop
            declare
               Answer   : constant String :=
                 Ask (One, "tools/list",
                      (if Length (Cursor) = 0 then "{}"
                       else "{""cursor"":" & T.JSON_Quoted (To_String (Cursor)) & "}"), Start_Wait);
               Document : Doc.Document;
               Error    : Jsonlib.Errors.Error_Info;
               Result   : Doc.Node;
            begin
               if Answer = "" then
                  One.Why := To_Unbounded_String ("it did not list its tools");
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
                           if Doc.Has_Member (Document, Item, "name") then
                              declare
                                 Own     : constant String :=
                                   Doc.As_String (Document, Doc.Member (Document, Item, "name"));
                                 Offered : constant String :=
                                   "mcp__" & Plain (To_String (One.Name)) & "__" & Plain (Own);
                                 Told    : constant String :=
                                   (if Doc.Has_Member (Document, Item, "description")
                                      and then Doc.Kind (Document, Doc.Member (Document, Item, "description"))
                                                 = Doc.String_Value
                                    then Doc.As_String (Document, Doc.Member (Document, Item, "description"))
                                    else Own);
                                 Shape   : constant String :=
                                   (if Doc.Has_Member (Document, Item, "inputSchema")
                                    then Jsonlib.Serializers.To_String
                                           (Document, Doc.Member (Document, Item, "inputSchema"))
                                    else "{""type"":""object"",""properties"":{}}");
                              begin
                                 Tools.Append
                                   (Tool'(Offered => To_Unbounded_String (Offered),
                                     Own     => To_Unbounded_String (Own),
                                     Owner   => 1,
                                     Defined => To_Unbounded_String
                                       ("{""type"": ""function"", ""function"": {""name"": "
                                        & T.JSON_Quoted (Offered) & ", ""description"": "
                                        & T.JSON_Quoted
                                            ((if Told'Length > 2048 then Told (Told'First .. Told'First + 2047)
                                              else Told))
                                        & ", ""parameters"": " & Shape & "}}")));
                                 One.Tools := One.Tools + 1;
                              end;
                           end if;
                        end;
                     end loop;
                  end;
               end if;
               if Doc.Has_Member (Document, Result, "nextCursor")
                 and then Doc.Kind (Document, Doc.Member (Document, Result, "nextCursor")) = Doc.String_Value
               then
                  Cursor := To_Unbounded_String (Doc.As_String (Document, Doc.Member (Document, Result, "nextCursor")));
               else
                  exit;
               end if;
            end;
         end loop;
      end;
   exception
      when others =>
         One.Why := To_Unbounded_String ("it said something that could not be read");
         Stop (One);
   end Start;

   procedure Start_All (Notes : out Unbounded_String) is
   begin
      Notes := Null_Unbounded_String;
      if Started then
         return;
      end if;
      Started := True;
      for Index in 1 .. Model_Runner.Config.Count loop
         declare
            Key     : constant String := Model_Runner.Config.Key_At (Index);
            Command : constant String := Model_Runner.Config.Value_At (Index);
         begin
            if Key'Length > Prefix'Length and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix
              and then Command /= "" and then Count < Most_Servers
            then
               Count := Count + 1;
               Servers (Count) := (Name => To_Unbounded_String (Key (Key'First + Prefix'Length .. Key'Last)),
                                   others => <>);
               declare
                  First : constant Natural := Natural (Tools.Length) + 1;
               begin
                  Start (Servers (Count), Command);
                  for At_Tool in First .. Natural (Tools.Length) loop
                     declare
                        One : Tool := Tools (At_Tool);
                     begin
                        One.Owner := Count;
                        Tools.Replace_Element (At_Tool, One);
                     end;
                  end loop;
               end;
               if not Servers (Count).Running then
                  Append (Notes, (if Length (Notes) = 0 then "" else [1 => ASCII.LF])
                                 & To_String (Servers (Count).Name) & ": " & To_String (Servers (Count).Why));
               end if;
            end if;
         end;
      end loop;
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
      Ended     : out Call_End)
   is
      Which : Natural := 0;
   begin
      Said := Null_Unbounded_String;
      Ended := Failed;
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
                   Call_Wait, Cancel);
            Document : Doc.Document;
            Error    : Jsonlib.Errors.Error_Info;
         begin
            if Answer = "" then
               if Model_Runner.Cancellation."/=" (Cancel, null) and then Model_Runner.Cancellation.Is_Cancelled (Cancel)
               then
                  Ended := Cancelled;
                  Said := To_Unbounded_String ("cancelled");
               elsif Owner.Running then
                  Ended := Timed_Out;
                  Said := To_Unbounded_String ("the server did not answer within" & Duration'Image (Call_Wait)
                                               & " seconds");
               else
                  Said := To_Unbounded_String ("the server " & To_String (Owner.Name) & " ended");
               end if;
               return;
            end if;
            Jsonlib.Parsers.Parse (Answer, Document, Error);
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
                  elsif Doc.Has_Member (Document, Result, "structuredContent") then
                     Said := To_Unbounded_String
                       (Jsonlib.Serializers.To_String (Document, Doc.Member (Document, Result, "structuredContent")));
                  end if;
                  if Length (Said) > Most_Answer then
                     Said := To_Unbounded_String
                       (Slice (Said, 1, Most_Answer) & ASCII.LF & "["
                        & Image (Length (Said) - Most_Answer) & " more characters left out]");
                  end if;
                  Ended := (if Erred then Failed else Answered);
               end;
            end;
         end;
      end;
   exception
      when others =>
         Said := To_Unbounded_String ("the server's answer could not be read");
         Ended := Failed;
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
      return To_String (Result);
   end Listing;

   procedure Stop_All is
   begin
      for Index in 1 .. Count loop
         Stop (Servers (Index));
      end loop;
      Count := 0;
      Tools.Clear;
      Started := False;
   end Stop_All;

end Model_Runner.CLI.MCP;
