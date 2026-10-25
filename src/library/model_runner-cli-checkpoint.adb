with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Hostkit.Durability;
with Hostkit.Fs;
with Model_Runner.CLI.Partials;

with Model_Runner.Text;
with Model_Runner.UTF8;

package body Model_Runner.CLI.Checkpoint is

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Text;
   package US renames Ada.Strings.Unbounded;

   --  The first line of a file this writes, then its version: none at all
   --  is a file written before there was one, version 0, the same records.
   Header  : constant String := "model_runner-conversation ";
   Version : constant := 1;

   function Image_Of (Value : Natural) return String
   is (T.Image (Long_Long_Integer (Value)));

   ----------
   -- Save --
   ----------

   procedure Save
     (Path : String; Messages : Model_Runner.Conversation.History)
   is
      Ignored : E.Error_Info;
   begin
      Save (Path, Messages, Ignored);
   end Save;

   procedure Save
     (Path     : String;
      Messages : Model_Runner.Conversation.History;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      File    : Stream_IO.File_Type;
      Buf     : US.Unbounded_String;
      Partial : constant String := Model_Runner.CLI.Partials.Beside (Path);
      use type Hostkit.Durability.Outcome;

      procedure LP (S : String) is
      begin
         US.Append (Buf, T.Image (Long_Long_Integer (S'Length)) & " " & S);
      end LP;
   begin
      Status := E.Success;
      --  What the file is and which form of it, so that a reader can tell
      --  one it does not know from a conversation cut short.
      US.Append (Buf, Header & Image_Of (Version) & ASCII.LF);
      for I in 1 .. Conv.Length (Messages) loop
         declare
            Role  : constant String :=
              (case Conv.Sender_At (Messages, I) is
                 when Conv.System_Role    => "S",
                 when Conv.User_Role      => "U",
                 when Conv.Assistant_Role => "A",
                 when Conv.Tool_Role      => "T",
                 when Conv.Developer_Role => "D");
            Calls : constant Natural := Conv.Call_Count (Messages, I);
            --  A message given as parts is written as its parts, the role
            --  letter followed by P, so that the picture beside the words
            --  survives the round trip.
            Parts : constant String := Conv.Parts_At (Messages, I);
         begin
            if Parts'Length > 0 then
               LP (Role & "P");
               LP (Parts);
            else
               LP (Role);
               LP (Conv.Content_At (Messages, I));
            end if;
            LP (T.Image (Long_Long_Integer (Calls)));
            for C in 1 .. Calls loop
               LP (Conv.Call_Name (Messages, I, C));
               LP (Conv.Call_Arguments (Messages, I, C));
            end loop;
         end;
      end loop;

      --  Beside its name first, on the device, and then in its place: a
      --  save that stops part way -- a full disk, a kill -- leaves the
      --  conversation saved before, not half of this one. Written a slice
      --  at a time from where it was built, not copied whole onto a stack.
      Create (File, Out_File, Partial, Form => "shared=no");
      declare
         Slice_Bytes : constant := 64 * 1024;
         Length      : constant Natural := US.Length (Buf);
         From        : Natural := 1;
      begin
         while From <= Length loop
            declare
               Upto  : constant Natural := Natural'Min (Length, From + Slice_Bytes - 1);
               S     : constant String := US.Slice (Buf, From, Upto);
               Block : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
            begin
               for I in S'Range loop
                  Block (Stream_Element_Offset (I - S'First + 1)) := Stream_Element (Character'Pos (S (I)));
               end loop;
               Write (File, Block);
               From := Upto + 1;
            end;
         end loop;
      end;
      Close (File);
      if Hostkit.Durability.Sync_File (Partial) = Hostkit.Durability.Failed
        or else not Hostkit.Fs.Replace_File (Partial, Path)
      then
         raise Ada.IO_Exceptions.Use_Error;
      end if;
      declare
         Listed : constant Hostkit.Durability.Outcome :=
           Hostkit.Durability.Sync_Directory (Ada.Directories.Containing_Directory (Ada.Directories.Full_Name (Path)));
         pragma Unreferenced (Listed);
      begin
         null;
      end;
   exception
      when Failure : others =>
         if Is_Open (File) then
            Close (File);
         end if;
         begin
            if Ada.Directories.Exists (Partial) then
               Ada.Directories.Delete_File (Partial);
            end if;
         exception
            when others =>
               null;
         end;
         Status := E.Make (E.IO_Write_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Save;

   ----------
   -- Load --
   ----------

   procedure Load
     (Path     : String;
      Messages : in out Model_Runner.Conversation.History;
      Loaded   : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info;
      Replace  : Boolean := False)
   is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      File : Stream_IO.File_Type;
   begin
      Loaded := False;
      Status := E.Success;
      Open (File, In_File, Path, Form => "shared=no");

      --  No larger than the conversation it could hold, written out: its
      --  rendering's bound twice over, for the fields' lengths and the
      --  calls beside it. Read whole otherwise, before anything said it
      --  was a conversation at all.
      if Size (File) > Stream_IO.Count
                         (2 * Conv.Bounds_Of (Messages).Max_Rendered_Bytes
                          + 1024 * 1024)
      then
         Close (File);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      declare
         type Text_Access is access String;
         procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);
         Total : constant Natural := Natural (Size (File));
         Last  : Stream_Element_Offset := 0;
         --  On the heap: a conversation of megabytes is past a stack.
         Held  : Text_Access := new String (1 .. Total);
         Data  : String renames Held.all;
         --  Whether the parse read the file to its end: one that stops at
         --  a record that is none is a file cut short, not a conversation.
         Whole : Boolean := False;
         --  The conversation the data holds, read into a history.
         procedure Parse
           (Into : in out Model_Runner.Conversation.History;
            Got  : out Boolean;
            Said : out Model_Runner.Errors.Error_Info) is
         begin
            Got := False;
            Said := E.Success;
            declare
               Pos : Natural := 1;

               --  What the turn before was: a tool's answer follows a call
               --  or another tool's answer, and nothing else.
               After_Call : Boolean := False;

               --  A record that is no record of this file's: refused, not
               --  read as some other turn.
               procedure Refuse (Code : E.Error_Code := E.IO_Read_Failed) is
               begin
                  Said := E.Make (Code);
                  E.Add_Text (Said, "path", Path, E.Param_Path);
               end Refuse;

               --  Read one length-prefixed field; Ok is false when what is there
               --  is not one, which ends the parse.
               function Field (Ok : out Boolean) return String is
                  N    : Natural := 0;
                  Seen : Boolean := False;
               begin
                  Ok := False;
                  while Pos <= Natural (Last)
                    and then Data (Pos) in '0' .. '9'
                  loop
                     N := N * 10 + (Character'Pos (Data (Pos))
                                    - Character'Pos ('0'));
                     Pos  := Pos + 1;
                     Seen := True;
                  end loop;
                  if not (Seen and then Pos <= Natural (Last)
                          and then Data (Pos) = ' ')
                    or else Pos + N > Natural (Last) + 1
                  then
                     return "";
                  end if;
                  Pos := Pos + 1;                    --  the space
                  declare
                     R : constant String := Data (Pos .. Pos + N - 1);
                  begin
                     Pos := Pos + N;
                     Ok  := True;
                     return R;
                  end;
               end Field;
            begin
               --  The version line, where there is one.
               if Natural (Last) >= Header'Length
                 and then Data (1 .. Header'Length) = Header
               then
                  declare
                     Number : Natural := 0;
                     Seen   : Boolean := False;
                  begin
                     Pos := Header'Length + 1;
                     while Pos <= Natural (Last) and then Data (Pos) in '0' .. '9'
                     loop
                        Number := Number * 10
                          + (Character'Pos (Data (Pos)) - Character'Pos ('0'));
                        Pos := Pos + 1;
                        Seen := True;
                     end loop;
                     if not Seen or else Number > Version
                       or else Pos > Natural (Last) or else Data (Pos) /= ASCII.LF
                     then
                        --  A form this does not know, said, not guessed at.
                        Refuse;
                        return;
                     end if;
                     Pos := Pos + 1;
                  end;
               end if;

               Read_Messages :
               loop
                  --  Whole only where a record ends and the file with it:
                  --  a file cut after a field ends where a field did too.
                  if Pos > Natural (Last) then
                     Whole := True;
                     exit Read_Messages;
                  end if;
                  declare
                     Ok_R, Ok_C, Ok_N : Boolean;
                     Role    : constant String := Field (Ok_R);
                     Content : constant String := Field (Ok_C);
                     Count_S : constant String :=
                       (if Ok_R and then Ok_C then Field (Ok_N) else "");
                     Calls   : Natural := 0;
                  begin
                     exit Read_Messages when not (Ok_R and then Ok_C and then Ok_N);
                     begin
                        Calls := Natural'Value (Count_S);
                     exception
                        when others =>
                           exit Read_Messages;
                     end;

                     --  A role this writes, calls only where an assistant
                     --  asks for them, an answer only to a call, and every
                     --  word UTF-8: otherwise not this file's records.
                     if Role not in "S" | "U" | "A" | "T" | "D"
                                  | "SP" | "UP" | "AP" | "TP" | "DP"
                       or else (Calls > 0 and then Role not in "A" | "AP")
                       or else (Role in "T" | "TP" and then not After_Call)
                     then
                        Refuse;
                        exit Read_Messages;
                     end if;
                     if not Model_Runner.UTF8.Is_Valid (Content) then
                        Refuse (E.IO_Invalid_UTF8);
                        exit Read_Messages;
                     end if;
                     After_Call :=
                       (Role in "A" | "AP" and then Calls > 0)
                       or else Role in "T" | "TP";

                     if Role = "S" then
                        Conv.Set_System (Into, Content, Said);
                     elsif Role in "A" | "AP" and then Calls > 0 then
                        --  An assistant's turn that asks, its words or its
                        --  parts, then each call it makes.
                        if Role = "AP" then
                           Conv.Append_Parts
                             (Into, Conv.Assistant_Role, Content, Said);
                        else
                           Conv.Append_Asking (Into, Content, Said);
                        end if;
                        for C in 1 .. Calls loop
                           declare
                              Ok_Nm, Ok_Ar : Boolean;
                              Nm : constant String := Field (Ok_Nm);
                              Ar : constant String := Field (Ok_Ar);
                           begin
                              exit Read_Messages when not
                                (Ok_Nm and then Ok_Ar);
                              if not (Model_Runner.UTF8.Is_Valid (Nm)
                                      and then Model_Runner.UTF8.Is_Valid (Ar))
                              then
                                 Refuse (E.IO_Invalid_UTF8);
                                 exit Read_Messages;
                              end if;
                              if E.Is_Ok (Said) then
                                 Conv.Append_Call (Into, Nm, Ar, Said);
                              end if;
                           end;
                        end loop;
                     elsif Role'Length = 2 and then Role (Role'Last) = 'P' then
                        Conv.Append_Parts
                          (Into,
                           (if Role (Role'First) = 'U' then Conv.User_Role
                            elsif Role (Role'First) = 'T' then Conv.Tool_Role
                            elsif Role (Role'First) = 'D' then Conv.Developer_Role
                            elsif Role (Role'First) = 'S' then Conv.System_Role
                            else Conv.Assistant_Role),
                           Content, Said);
                     elsif Content'Length > 0 then
                        Conv.Append
                          (Into,
                           (if Role = "U" then Conv.User_Role
                            elsif Role = "T" then Conv.Tool_Role
                            elsif Role = "D" then Conv.Developer_Role
                            else Conv.Assistant_Role),
                           Content, Said);
                     end if;

                     if E.Is_Error (Said) then
                        exit Read_Messages;
                     end if;
                     Got := True;
                  end;
               end loop Read_Messages;
            end;
         end Parse;
      begin
         --  Read a slice at a time into the text.
         declare
            Slice : Stream_Element_Array (1 .. 64 * 1024);
            Got   : Stream_Element_Offset;
         begin
            while Natural (Last) < Total loop
               Read (File, Slice (1 .. Stream_Element_Offset'Min (Slice'Last,
                                                                 Stream_Element_Offset (Total) - Last)), Got);
               exit when Got = 0;
               for I in 1 .. Got loop
                  Data (Natural (Last + I)) := Character'Val (Slice (I));
               end loop;
               Last := Last + Got;
            end loop;
         end;
         Close (File);

         declare
         begin
            --  Read into one of its own first: a file that will not read
            --  leaves the conversation it would replace as it is, from what
            --  was read once.
            if Replace then
               declare
                  Trial : Model_Runner.Conversation.History;
               begin
                  Conv.Open (Trial, Conv.Bounds_Of (Messages), Status);
                  if E.Is_Ok (Status) then
                     Parse (Trial, Loaded, Status);
                  end if;
                  if E.Is_Ok (Status) and then Loaded and then not Whole then
                     Status := E.Make (E.IO_Read_Failed);
                     E.Add_Text (Status, "path", Path, E.Param_Path);
                  end if;
                  if E.Is_Error (Status) or else not Loaded then
                     Free (Held);
                     return;
                  end if;
                  Conv.Clear (Messages);
               end;
            end if;
            Parse (Messages, Loaded, Status);
            Free (Held);
            if E.Is_Ok (Status) and then not Whole then
               --  What was read stays read; that more was not is said.
               Status := E.Make (E.IO_Read_Failed);
               E.Add_Text (Status, "path", Path, E.Param_Path);
            end if;
         end;
      exception
         when others =>
            --  The text given back whatever stopped the read.
            Free (Held);
            raise;
      end;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
   end Load;

end Model_Runner.CLI.Checkpoint;
