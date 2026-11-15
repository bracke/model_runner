with Ada.Calendar;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Shell;
with Hostkit.Spawn;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

with Model_Runner.Config;
with Model_Runner.Text;

package body Model_Runner.CLI.Language_Server is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   package D renames Hostkit.Descriptors;
   package Doc renames Jsonlib.Documents;
   package T renames Model_Runner.Text;

   package Versions is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Positive, Ada.Strings.Hash, "=");

   Running     : Boolean := False;
   Failed      : Boolean := False;   --  would not start: not tried again
   To_Server   : D.Descriptor := D.Invalid;
   From_Server : D.Descriptor := D.Invalid;
   Child       : Hostkit.Spawn.Process_Handle;
   Next_Id     : Positive := 1;
   Opened      : Versions.Map;
   --  Bytes read from the server past the last message.
   Pending     : Unbounded_String;

   function Configured return Boolean is (Model_Runner.Config.Value ("lsp") /= "");

   function Image (Value : Long_Long_Integer) return String is (T.Image (Value));

   --  A file's path as a URI: file://, its bytes outside the unreserved
   --  ones and / written %XX.
   function URI_Of (Path : String) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Result : Unbounded_String := To_Unbounded_String ("file://");
   begin
      for C of Path loop
         if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' then
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
   begin
      for Index in Framed'Range loop
         Bytes (Ada.Streams.Stream_Element_Offset (Index - Framed'First + 1)) := Character'Pos (Framed (Index));
      end loop;
      if D."/=" (D.Write (To_Server, Bytes, Last), D.Transfer_Ok) then
         Running := False;
      end if;
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
            Length_At : constant Natural := Ada.Strings.Fixed.Index (Held, "Content-Length:");
         begin
            if Header > 0 and then Length_At > 0 and then Length_At < Header then
               declare
                  Stop   : constant Natural := Ada.Strings.Fixed.Index (Held (Length_At .. Header), "" & ASCII.CR);
                  Length : constant Natural :=
                    Natural'Value (Held (Length_At + 15 .. Stop - 1));
                  Starts : constant Positive := Header + 4;
               begin
                  if Held'Last >= Starts + Length - 1 then
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
      To_Child, From_Child : D.Pipe_Ends;
      Quiet   : D.Descriptor;
      Options : Hostkit.Spawn.Options;
      Words   : Hostkit.String_Vectors.Vector;
   begin
      if Running or else Failed or else not Configured then
         return;
      end if;
      Failed := True;
      if not D.Create_Pipe (To_Child) or else not D.Create_Pipe (From_Child)
        or else not D.Set_Inheritable (To_Child.Read_End, True)
        or else not D.Set_Inheritable (From_Child.Write_End, True)
      then
         return;
      end if;
      Options.Input := To_Child.Read_End;
      Options.Output := From_Child.Write_End;
      --  What the server logs is not the conversation's.
      if D.Open_File ("/dev/null", D.Open_Write_Truncate, Quiet) and then D.Set_Inheritable (Quiet, True) then
         Options.Error_Output := Quiet;
      end if;
      Words.Append (To_Unbounded_String (Hostkit.Shell.Command_Option));
      Words.Append (To_Unbounded_String (Model_Runner.Config.Value ("lsp")));
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
      Running := True;
      Pending := Null_Unbounded_String;
      Send ("{""jsonrpc"":""2.0"",""id"":" & Image (Long_Long_Integer (Next_Id))
            & ",""method"":""initialize"",""params"":{""processId"":null,""rootUri"":"
            & T.JSON_Quoted (URI_Of (Ada.Directories.Current_Directory))
            & ",""capabilities"":{""textDocument"":{""publishDiagnostics"":{}}}}}");
      --  Its answer, waited for: what it says before then answered or let by.
      declare
         use type Ada.Calendar.Time;
         Deadline : constant Ada.Calendar.Time := Ada.Calendar.Clock + 30.0;
         Wanted   : constant String := """id"":" & Image (Long_Long_Integer (Next_Id));
      begin
         loop
            declare
               Message : constant String := Next_Message (Deadline);
            begin
               if Message = "" then
                  Stop;
                  return;
               end if;
               exit when Ada.Strings.Fixed.Index (Message, Wanted) > 0
                 and then Ada.Strings.Fixed.Index (Message, """method""") = 0;
               Answer_Request (Message);
            end;
         end loop;
      end;
      Next_Id := Next_Id + 1;
      Send ("{""jsonrpc"":""2.0"",""method"":""initialized"",""params"":{}}");
      Failed := False;
   exception
      when others =>
         Running := False;
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
      URI : constant String := URI_Of (Path);
   begin
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
                              return Problems_Of (Document, Params);
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
      Result : Hostkit.Spawn.Status;
   begin
      if Running then
         Send ("{""jsonrpc"":""2.0"",""id"":" & Image (Long_Long_Integer (Next_Id))
               & ",""method"":""shutdown"",""params"":null}");
         Next_Id := Next_Id + 1;
         Send ("{""jsonrpc"":""2.0"",""method"":""exit"",""params"":null}");
      end if;
      D.Close (To_Server);
      D.Close (From_Server);
      --  Its going waited for a second at most: a server that will not
      --  leave on exit is not held for.
      if Running or else Failed then
         for Try in 1 .. 20 loop
            exit when Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Poll, Result);
            delay 0.05;
         end loop;
      end if;
      Running := False;
      Opened.Clear;
      Pending := Null_Unbounded_String;
   exception
      when others =>
         Running := False;
   end Stop;

end Model_Runner.CLI.Language_Server;
