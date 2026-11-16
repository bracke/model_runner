with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Process;
with Hostkit.Shell;
with Hostkit.Signals;
with Hostkit.Spawn;
with Hostkit.Spawn.Supervision;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

with Model_Runner.Config;
with Model_Runner.CLI.Process_Reaper;
with Model_Runner.Text;

package body Model_Runner.CLI.Language_Server is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   package D renames Hostkit.Descriptors;
   package Doc renames Jsonlib.Documents;
   package T renames Model_Runner.Text;
   use type Doc.Value_Kind;
   use type Hostkit.Host.Kind;

   package Versions is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Positive, Ada.Strings.Hash, "=");

   Running     : Boolean := False;
   Failed      : Boolean := False;   --  would not start: not tried again
   Failed_For  : Unbounded_String;   --  unless the configured command changes
   To_Server   : D.Descriptor := D.Invalid;
   From_Server : D.Descriptor := D.Invalid;
   Child       : Hostkit.Spawn.Process_Handle := Hostkit.Spawn.Invalid_Process;
   Next_Id     : Positive := 1;
   Opened      : Versions.Map;
   --  A wait that expired may leave an unversioned publication in flight.
   --  Restart before another version is sent, so that publication cannot be
   --  mistaken for diagnostics of the newer text.
   Restart_After_Timeout : Boolean := False;
   --  Bytes read from the server past the last message.
   Pending     : Unbounded_String;

   --  Framing is input from another process, not trusted allocation advice.
   --  A normal LSP header is a few dozen bytes; leave ample room for extension
   --  headers, while bounding both a header that never ends and its body.
   Most_Header  : constant := 64 * 1024;
   Most_Message : constant := 1024 * 1024;

   function Configured return Boolean is (Model_Runner.Config.Value ("lsp") /= "");

   function Image (Value : Long_Long_Integer) return String is (T.Image (Value));

   --  A file's path as a URI: file://, its bytes outside the unreserved
   --  ones and / written %XX.
   function URI_Of (Path : String) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Is_Drive : constant Boolean :=
        Path'Length >= 3
        and then Path (Path'First) in 'A' .. 'Z' | 'a' .. 'z'
        and then Path (Path'First + 1) = ':'
        and then Path (Path'First + 2) in '/' | '\';
      Is_UNC : constant Boolean :=
        Hostkit.Host.Current = Hostkit.Host.Windows
        and then Path'Length >= 2
        and then
          ((Path (Path'First) = '\' and then Path (Path'First + 1) = '\')
           or else
             (Path (Path'First) = '/'
              and then Path (Path'First + 1) = '/'));
      Result : Unbounded_String := To_Unbounded_String
        (if Is_Drive then "file:///"
         elsif Is_UNC then "file:"
         else "file://");
   begin
      for C of Path loop
         if C = '/' or else (C = '\' and then (Is_Drive or else Is_UNC)) then
            Append (Result, '/');
         elsif C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | ':' then
            Append (Result, C);
         else
            Append (Result, '%' & Hex (Character'Pos (C) / 16 + 1) & Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return To_String (Result);
   end URI_Of;

   --  The language a file is in, by its ending, as servers name them.
   function Language_Of (Path : String) return String is
      Dot  : constant Natural := Ada.Strings.Fixed.Index (Path, ".", Ada.Strings.Backward);
      Ends : constant String := (if Dot = 0 then "" else Path (Dot + 1 .. Path'Last));
   begin
      return (if Ends in "adb" | "ads" | "ada" then "ada"
              elsif Ends in "c" | "h" then "c"
              elsif Ends in "cc" | "cpp" | "hpp" | "cxx" then "cpp"
              elsif Ends = "py" then "python"
              elsif Ends = "rs" then "rust"
              elsif Ends = "go" then "go"
              elsif Ends = "java" then "java"
              elsif Ends = "js" then "javascript"
              elsif Ends = "ts" then "typescript"
              else "plaintext");
   end Language_Of;

   procedure Send (Json : String) is
      Framed : constant String := "Content-Length:" & Natural'Image (Json'Length) & ASCII.CR & ASCII.LF
                                  & ASCII.CR & ASCII.LF & Json;
      Bytes  : Ada.Streams.Stream_Element_Array (1 .. Framed'Length);
      Last   : Ada.Streams.Stream_Element_Offset;
      First  : Ada.Streams.Stream_Element_Offset := Bytes'First;
      Outcome : D.Transfer_Outcome;
   begin
      for Index in Framed'Range loop
         Bytes (Ada.Streams.Stream_Element_Offset (Index - Framed'First + 1)) := Character'Pos (Framed (Index));
      end loop;
      while First <= Bytes'Last loop
         Outcome := D.Write (To_Server, Bytes (First .. Bytes'Last), Last);
         if D."=" (Outcome, D.Transfer_Ok) and then Last >= First then
            First := Last + 1;
         elsif D."=" (Outcome, D.Transfer_Interrupted) then
            null;
         else
            Running := False;
            return;
         end if;
      end loop;
   end Send;

   --  The next message's body, waited for until Deadline; "" at the
   --  deadline, or where the server has gone.
   function Next_Message (Deadline : Ada.Calendar.Time) return String is
      use type Ada.Calendar.Time;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65_536);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         --  A whole message held: taken.
         declare
            Held   : constant String := To_String (Pending);
            Header : constant Natural := Ada.Strings.Fixed.Index (Held, ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF);
         begin
            if Header = 0 and then Held'Length > Most_Header then
               Running := False;
               Pending := Null_Unbounded_String;
               return "";
            elsif Header > Most_Header then
               Running := False;
               Pending := Null_Unbounded_String;
               return "";
            elsif Header > 0 then
               declare
                  Position : Natural := Held'First;
                  Length   : Natural := 0;
                  Found    : Boolean := False;
                  Valid    : Boolean := True;
                  Starts   : constant Positive := Header + 4;
               begin
                  while Position < Header and then Valid loop
                     declare
                        End_At : constant Natural :=
                          Ada.Strings.Fixed.Index
                            (Held (Position .. Header - 1), ASCII.CR & ASCII.LF);
                        Last : constant Natural :=
                          (if End_At = 0 then Header - 1 else End_At - 1);
                        Line : constant String := Held (Position .. Last);
                        Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
                     begin
                        if Line = "" or else Colon = 0 then
                           Valid := False;
                        elsif Ada.Characters.Handling.To_Lower
                                (Line (Line'First .. Colon - 1)) = "content-length"
                        then
                           declare
                              Value : constant String :=
                                Ada.Strings.Fixed.Trim
                                  (Line (Colon + 1 .. Line'Last), Ada.Strings.Both);
                           begin
                              if Found or else Value = "" then
                                 Valid := False;
                              else
                                 for C of Value loop
                                    if C not in '0' .. '9' then
                                       Valid := False;
                                       exit;
                                    end if;
                                 end loop;
                                 if Valid then
                                    Length := Natural'Value (Value);
                                    Found := True;
                                 end if;
                              end if;
                           end;
                        end if;
                        Position := (if End_At = 0 then Header else End_At + 2);
                     end;
                  end loop;
                  if not Valid or else not Found then
                     Running := False;
                     Pending := Null_Unbounded_String;
                     return "";
                  end if;
                  if Length > Most_Message then
                     Running := False;
                     Pending := Null_Unbounded_String;
                     return "";
                  elsif Held'Last >= Starts + Length - 1 then
                     Pending := To_Unbounded_String (Held (Starts + Length .. Held'Last));
                     return Held (Starts .. Starts + Length - 1);
                  end if;
               end;
            end if;
         end;
         declare
            Left : constant Duration := Deadline - Ada.Calendar.Clock;
         begin
            if Left <= 0.0
              or else not D.Wait_Readable (From_Server, Integer (Left * 1000.0))
            then
               return "";
            end if;
         end;
         if D."/=" (D.Read (From_Server, Buffer, Last), D.Transfer_Ok) or else Last < Buffer'First then
            Running := False;
            return "";
         end if;
         for B of Buffer (Buffer'First .. Last) loop
            Append (Pending, Character'Val (B));
         end loop;
      end loop;
   exception
      when others =>
         Running := False;
         Pending := Null_Unbounded_String;
         return "";
   end Next_Message;

   --  A request the server made, answered with nothing, so that it does
   --  not wait on the client: its id as it was given.
   procedure Answer_Request (Body_Text : String) is
      Document : Doc.Document;
      Error    : Jsonlib.Errors.Error_Info;
   begin
      Jsonlib.Parsers.Parse (Body_Text, Document, Error);
      if Jsonlib.Errors.Failed (Error)
        or else not Doc.Has_Member (Document, Doc.Root (Document), "id")
        or else not Doc.Has_Member (Document, Doc.Root (Document), "method")
      then
         return;
      end if;
      declare
         Id : constant Doc.Node := Doc.Member (Document, Doc.Root (Document), "id");
      begin
         Send ("{""jsonrpc"":""2.0"",""id"":"
               & (case Doc.Kind (Document, Id) is
                     when Doc.Integer_Value => Image (Doc.As_Integer (Document, Id)),
                     when Doc.String_Value  => T.JSON_Quoted (Doc.As_String (Document, Id)),
                     when others            => "null")
               & ",""result"":null}");
      end;
   end Answer_Request;

   procedure Start is
      use type Hostkit.Spawn.Spawn_Outcome;
      Command : constant String := Model_Runner.Config.Value ("lsp");
      To_Child   : D.Pipe_Ends := (others => D.Invalid);
      From_Child : D.Pipe_Ends := (others => D.Invalid);
      Quiet      : D.Descriptor := D.Invalid;
      Options : Hostkit.Spawn.Options;
      Words   : Hostkit.String_Vectors.Vector;
   begin
      if Running or else Command = ""
        or else (Failed and then Failed_For = Command)
      then
         return;
      end if;
      Failed := True;
      Failed_For := To_Unbounded_String (Command);
      if not D.Create_Pipe (To_Child) or else not D.Create_Pipe (From_Child)
        or else not D.Set_Inheritable (To_Child.Read_End, True)
        or else not D.Set_Inheritable (From_Child.Write_End, True)
      then
         D.Close (To_Child.Read_End);
         D.Close (To_Child.Write_End);
         D.Close (From_Child.Read_End);
         D.Close (From_Child.Write_End);
         return;
      end if;
      Options.Input := To_Child.Read_End;
      Options.Output := From_Child.Write_End;
      Options.Group := Hostkit.Spawn.Group_New;
      --  What the server logs is not the conversation's.
      if Hostkit.Fs.Null_Device /= ""
        and then D.Open_File (Hostkit.Fs.Null_Device, D.Open_Write_Truncate, Quiet)
        and then D.Set_Inheritable (Quiet, True)
      then
         Options.Error_Output := Quiet;
      end if;
      Words.Append (To_Unbounded_String (Hostkit.Shell.Command_Option));
      Words.Append (To_Unbounded_String (Command));
      if Hostkit.Spawn.Start (Hostkit.Shell.Executable, Words, Options, Child) /= Hostkit.Spawn.Spawn_Ok then
         D.Close (To_Child.Read_End);
         D.Close (To_Child.Write_End);
         D.Close (From_Child.Read_End);
         D.Close (From_Child.Write_End);
         D.Close (Quiet);
         return;
      end if;
      D.Close (To_Child.Read_End);
      D.Close (From_Child.Write_End);
      D.Close (Quiet);
      To_Server := To_Child.Write_End;
      From_Server := From_Child.Read_End;
      To_Child.Write_End := D.Invalid;
      From_Child.Read_End := D.Invalid;
      Running := True;
      Pending := Null_Unbounded_String;
      Send ("{""jsonrpc"":""2.0"",""id"":" & Image (Long_Long_Integer (Next_Id))
            & ",""method"":""initialize"",""params"":{""processId"":null,""rootUri"":"
            & T.JSON_Quoted (URI_Of (Ada.Directories.Current_Directory))
            & ",""capabilities"":{""textDocument"":{""publishDiagnostics"":{""versionSupport"":true}}}}}");
      --  Its answer, waited for: what it says before then answered or let by.
      declare
         use type Ada.Calendar.Time;
         Deadline : constant Ada.Calendar.Time := Ada.Calendar.Clock + 30.0;
      begin
         loop
            declare
               Message : constant String := Next_Message (Deadline);
               Document : Doc.Document;
               Error    : Jsonlib.Errors.Error_Info;
               Answered : Boolean := False;
               Accepted : Boolean := False;
            begin
               if Message = "" then
                  Stop;
                  return;
               end if;
               Jsonlib.Parsers.Parse (Message, Document, Error);
               if not Jsonlib.Errors.Failed (Error)
                 and then Doc.Kind (Document, Doc.Root (Document)) = Doc.Object_Value
               then
                  declare
                     Root : constant Doc.Node := Doc.Root (Document);
                  begin
                     Answered :=
                       Doc.Has_Member (Document, Root, "id")
                       and then not Doc.Has_Member (Document, Root, "method")
                       and then Doc.Kind (Document, Doc.Member (Document, Root, "id")) = Doc.Integer_Value
                       and then Doc.As_Integer (Document, Doc.Member (Document, Root, "id"))
                                  = Long_Long_Integer (Next_Id);
                     Accepted :=
                       Answered
                       and then not Doc.Has_Member (Document, Root, "error")
                       and then Doc.Has_Member (Document, Root, "result")
                       and then Doc.Kind
                         (Document, Doc.Member (Document, Root, "result")) = Doc.Object_Value;
                  end;
               end if;
               if Answered and then not Accepted then
                  --  A response carrying an error is a completed initialize
                  --  request, but not a usable language server. Do not send
                  --  initialized or retain it as successfully started.
                  Running := False;
                  Stop;
                  return;
               end if;
               exit when Accepted;
               Answer_Request (Message);
            end;
         end loop;
      end;
      Next_Id := Next_Id + 1;
      Send ("{""jsonrpc"":""2.0"",""method"":""initialized"",""params"":{}}");
      Failed := False;
   exception
      when others =>
         D.Close (To_Child.Read_End);
         D.Close (To_Child.Write_End);
         D.Close (From_Child.Read_End);
         D.Close (From_Child.Write_End);
         D.Close (Quiet);
         Stop;
   end Start;

   --  A file's text, whole.
   function Text_Of (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Text : Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path, Form => "shared=yes");
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Text);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Text_Of;

   --  The problems a publishDiagnostics message gives, a line each.
   function Problems_Of (Document : Doc.Document; Params : Doc.Node) return String is
      List   : Doc.Node;
      Result : Unbounded_String;
      Count  : Natural;
   begin
      if not Doc.Has_Member (Document, Params, "diagnostics") then
         return "(none)";
      end if;
      List := Doc.Member (Document, Params, "diagnostics");
      Count := Doc.Length (Document, List);
      if Count = 0 then
         return "(none)";
      end if;
      for Index in 1 .. Natural'Min (Count, 20) loop
         declare
            One      : constant Doc.Node := Doc.Element (Document, List, Index);
            Line     : Long_Long_Integer := 0;
            Severity : Long_Long_Integer := 1;
            Words    : Unbounded_String;
         begin
            if Doc.Has_Member (Document, One, "range") then
               declare
                  Where : constant Doc.Node := Doc.Member (Document, One, "range");
               begin
                  if Doc.Has_Member (Document, Where, "start") then
                     declare
                        From : constant Doc.Node := Doc.Member (Document, Where, "start");
                     begin
                        if Doc.Has_Member (Document, From, "line") then
                           Line := Doc.As_Integer (Document, Doc.Member (Document, From, "line"));
                        end if;
                     end;
                  end if;
               end;
            end if;
            if Doc.Has_Member (Document, One, "severity") then
               Severity := Doc.As_Integer (Document, Doc.Member (Document, One, "severity"));
            end if;
            if Doc.Has_Member (Document, One, "message") then
               Words := To_Unbounded_String (Doc.As_String (Document, Doc.Member (Document, One, "message")));
            end if;
            Append (Result,
                    "line " & Image (Line + 1) & ": "
                    & (case Severity is
                          when 1 => "error", when 2 => "warning", when 3 => "information", when others => "hint")
                    & ": " & Words & ASCII.LF);
         end;
      end loop;
      if Count > 20 then
         Append (Result, "and" & Natural'Image (Count - 20) & " more" & ASCII.LF);
      end if;
      return To_String (Result);
   exception
      when others =>
         return "";
   end Problems_Of;

   function Problems_In (Path : String; Wait : Duration := 8.0) return String is
      use type Ada.Calendar.Time;
      URI     : constant String := URI_Of (Path);
      Version : Positive;
   begin
      if Restart_After_Timeout then
         Stop;
         Restart_After_Timeout := False;
      end if;
      Start;
      if not Running then
         return "";
      end if;
      declare
         Text : constant String := Text_Of (Path);
      begin
         if Opened.Contains (URI) then
            Opened.Replace (URI, Opened.Element (URI) + 1);
            Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didChange"",""params"":{""textDocument"":{""uri"":"
                  & T.JSON_Quoted (URI) & ",""version"":" & Image (Long_Long_Integer (Opened.Element (URI)))
                  & "},""contentChanges"":[{""text"":" & T.JSON_Quoted (Text) & "}]}}");
         else
            Opened.Insert (URI, 1);
            Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didOpen"",""params"":{""textDocument"":{""uri"":"
                  & T.JSON_Quoted (URI) & ",""languageId"":" & T.JSON_Quoted (Language_Of (Path))
                  & ",""version"":1,""text"":" & T.JSON_Quoted (Text) & "}}}");
         end if;
         Version := Opened.Element (URI);
      end;
      --  Its word on this file, past what it says of others.
      declare
         Deadline : constant Ada.Calendar.Time := Ada.Calendar.Clock + Wait;
      begin
         loop
            declare
               Message  : constant String := Next_Message (Deadline);
               Document : Doc.Document;
               Error    : Jsonlib.Errors.Error_Info;
            begin
               if Message = "" then
                  Restart_After_Timeout := Running;
                  return "";
               end if;
               Jsonlib.Parsers.Parse (Message, Document, Error);
               if not Jsonlib.Errors.Failed (Error)
                 and then Doc.Has_Member (Document, Doc.Root (Document), "method")
               then
                  declare
                     Method : constant String :=
                       Doc.As_String (Document, Doc.Member (Document, Doc.Root (Document), "method"));
                  begin
                     if Method = "textDocument/publishDiagnostics"
                       and then Doc.Has_Member (Document, Doc.Root (Document), "params")
                     then
                        declare
                           Params : constant Doc.Node := Doc.Member (Document, Doc.Root (Document), "params");
                        begin
                           if Doc.Has_Member (Document, Params, "uri")
                             and then Doc.As_String (Document, Doc.Member (Document, Params, "uri")) = URI
                           then
                              if Doc.Has_Member (Document, Params, "version") then
                                 if Doc.Kind (Document, Doc.Member (Document, Params, "version"))
                                      = Doc.Integer_Value
                                   and then Doc.As_Integer
                                     (Document, Doc.Member (Document, Params, "version"))
                                       = Long_Long_Integer (Version)
                                 then
                                    return Problems_Of (Document, Params);
                                 end if;
                              else
                                 return Problems_Of (Document, Params);
                              end if;
                           end if;
                        end;
                     elsif Doc.Has_Member (Document, Doc.Root (Document), "id") then
                        Answer_Request (Message);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
   exception
      when others =>
         return "";
   end Problems_In;

   procedure Stop is
      procedure Stop_Remaining_Group is
         Group : constant Integer := Hostkit.Spawn.Group_Id (Child);
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
         if not Hostkit.Spawn.Is_Valid (Child) then
            return True;
         elsif Hostkit.Spawn.Supervision.Has_Ended (Child, Result)
         then
            Stop_Remaining_Group;
            Hostkit.Spawn.Release (Child);
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
      if Running then
         declare
            use type Ada.Calendar.Time;
            Shutdown_Id : constant Positive := Next_Id;
            Deadline    : constant Ada.Calendar.Time := Ada.Calendar.Clock + 1.0;
            Answered    : Boolean := False;
         begin
            Send ("{""jsonrpc"":""2.0"",""id"":" & Image (Long_Long_Integer (Shutdown_Id))
                  & ",""method"":""shutdown"",""params"":null}");
            Next_Id := Next_Id + 1;
            --  LSP requires the shutdown response before the exit
            --  notification. Requests arriving while it shuts down still
            --  receive an answer, so the server cannot deadlock on one.
            while Running and then not Answered and then Ada.Calendar.Clock < Deadline loop
               declare
                  Message  : constant String := Next_Message (Deadline);
                  Document : Doc.Document;
                  Error    : Jsonlib.Errors.Error_Info;
               begin
                  exit when Message = "";
                  Jsonlib.Parsers.Parse (Message, Document, Error);
                  if not Jsonlib.Errors.Failed (Error)
                    and then Doc.Kind (Document, Doc.Root (Document)) = Doc.Object_Value
                  then
                     declare
                        Root : constant Doc.Node := Doc.Root (Document);
                     begin
                        Answered :=
                          Doc.Has_Member (Document, Root, "id")
                          and then not Doc.Has_Member (Document, Root, "method")
                          and then Doc.Kind (Document, Doc.Member (Document, Root, "id")) = Doc.Integer_Value
                          and then Doc.As_Integer (Document, Doc.Member (Document, Root, "id"))
                                     = Long_Long_Integer (Shutdown_Id);
                     end;
                  end if;
                  if not Answered then
                     Answer_Request (Message);
                  end if;
               end;
            end loop;
            if Running then
               Send ("{""jsonrpc"":""2.0"",""method"":""exit"",""params"":null}");
            end if;
         exception
            when others =>
               if Running then
                  Send ("{""jsonrpc"":""2.0"",""method"":""exit"",""params"":null}");
               end if;
         end;
      end if;
      D.Close (To_Server);
      D.Close (From_Server);
      Wait_A_While;
      --  A server that ignores exit is stopped with its process group, so
      --  helpers it started do not outlive the conversation either.
      if Hostkit.Spawn.Is_Valid (Child) then
         declare
            Group : constant Integer := Hostkit.Spawn.Group_Id (Child);
            Pid   : constant Integer := Hostkit.Spawn.Process_Id (Child);
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
            if Hostkit.Spawn.Is_Valid (Child) then
               Sent := False;
               if Group > 1 then
                  Sent := Hostkit.Signals.Send_To_Group
                    (Group, Hostkit.Signals.Signal_Kill);
               end if;
               if not Sent then
                  Sent := Hostkit.Spawn.Supervision.Stop_Now (Child);
               end if;
               Wait_After_Force;
               if Hostkit.Spawn.Is_Valid (Child) then
                  Model_Runner.CLI.Process_Reaper.Adopt (Child);
               end if;
            end if;
         end;
      end if;
      Running := False;
      Opened.Clear;
      Pending := Null_Unbounded_String;
      Restart_After_Timeout := False;
   exception
      when others =>
         Running := False;
         Restart_After_Timeout := False;
         if Hostkit.Spawn.Is_Valid (Child) then
            declare
               Stopped : constant Boolean := Hostkit.Spawn.Supervision.Stop_Now (Child);
               pragma Unreferenced (Stopped);
            begin
               Wait_After_Force;
               if Hostkit.Spawn.Is_Valid (Child) then
                  Model_Runner.CLI.Process_Reaper.Adopt (Child);
               end if;
            end;
         end if;
   end Stop;

end Model_Runner.CLI.Language_Server;
