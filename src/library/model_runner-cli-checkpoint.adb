with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with Model_Runner.Text;

package body Model_Runner.CLI.Checkpoint is

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Text;
   package US renames Ada.Strings.Unbounded;

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
      File : Stream_IO.File_Type;
      Buf  : US.Unbounded_String;

      procedure LP (S : String) is
      begin
         US.Append (Buf, T.Image (Long_Long_Integer (S'Length)) & " " & S);
      end LP;
   begin
      Status := E.Success;
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

      Create (File, Out_File, Path);
      declare
         S     : constant String := US.To_String (Buf);
         Block : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
      begin
         for I in S'Range loop
            Block (Stream_Element_Offset (I - S'First + 1)) :=
              Stream_Element (Character'Pos (S (I)));
         end loop;
         Write (File, Block);
      end;
      Close (File);
   exception
      when Failure : others =>
         if Is_Open (File) then
            Close (File);
         end if;
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
      Open (File, In_File, Path);
      declare
         Total : constant Natural := Natural (Size (File));
         Block : Stream_Element_Array (1 .. Stream_Element_Offset'Max
                                              (1, Stream_Element_Offset (Total)));
         Last  : Stream_Element_Offset := 0;
         Data  : String (1 .. Total);
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
               Read_Messages :
               loop
                  exit Read_Messages when Pos > Natural (Last);
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

                     if Role = "S" then
                        Conv.Set_System (Into, Content, Said);
                     elsif Role = "A" and then Calls > 0 then
                        Conv.Append_Asking (Into, Content, Said);
                        for C in 1 .. Calls loop
                           declare
                              Ok_Nm, Ok_Ar : Boolean;
                              Nm : constant String := Field (Ok_Nm);
                              Ar : constant String := Field (Ok_Ar);
                           begin
                              exit Read_Messages when not
                                (Ok_Nm and then Ok_Ar);
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
         if Total > 0 then
            Read (File, Block, Last);
         end if;
         Close (File);
         for I in 1 .. Natural (Last) loop
            Data (I) := Character'Val (Block (Stream_Element_Offset (I)));
         end loop;

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
                  if E.Is_Error (Status) or else not Loaded then
                     return;
                  end if;
                  Conv.Clear (Messages);
               end;
            end if;
            Parse (Messages, Loaded, Status);
         end;
      end;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Status := E.Make (E.IO_Read_Failed);
   end Load;

end Model_Runner.CLI.Checkpoint;
