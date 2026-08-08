with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Interfaces;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Backend.CPU;
with Model_Runner.Bytes;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Memory;
with Model_Runner.Cancellation;
with Model_Runner.Platform;
with Model_Runner.Platform.Signals;
with Model_Runner.Progress;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.UTF8;

with Model_Runner.CLI.Interactive;

package body Model_Runner.CLI.Execute is

   use type Ada.Directories.File_Kind;

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Byte_Sources.Files.Mapping_Policy;
   use type Model_Runner.CLI.Options.Prompt_Source;
   use type Model_Runner.CLI.Options.Text_Access;
   use type Model_Runner.CLI.Options.Verbosity;
   use type Model_Runner.Generation.Completion_Reason;

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;
   package G renames Model_Runner.GGUF;
   package Gen renames Model_Runner.Generation;
   package Containers renames Model_Runner.GGUF.Containers;
   package L renames Model_Runner.Llama;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package Pres renames Model_Runner.Presentation;
   package Workers_CPU renames Model_Runner.Backend.CPU;
   package T renames Model_Runner.Text;
   package Vocab renames Model_Runner.Tokenizer;

   procedure Free_Text is
     new Ada.Unchecked_Deallocation (String, Opt.Text_Access);

   --  Read a whole file as UTF-8, subject to a size limit.
   procedure Read_File
     (Path   : String;
      Limit  : Natural;
      Result : out Opt.Text_Access;
      Status : out E.Error_Info)
   is
      use Ada.Text_IO;
      Handle : File_Type;
      Filled : Natural := 0;
   begin
      Result := null;
      Status := E.Success;

      if not Ada.Directories.Exists (Path) then
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      --  A directory exists and has a size, and opening one fails in a way
      --  that reads as "cannot read this file" -- which sends the reader to
      --  look at a file that is not the problem. The model file reader has
      --  always made this distinction; the prompt file reader did not.
      if Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File then
         Status := E.Make (E.IO_Not_A_Regular_File);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      declare
         Size : constant Ada.Directories.File_Size := Ada.Directories.Size (Path);
      begin
         if Long_Long_Integer (Size) > Long_Long_Integer (Limit) then
            Status := E.Make (E.IO_File_Too_Large);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            E.Add_Integer
              (Status, "size", Long_Long_Integer (Size), E.Param_Bytes);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Limit), E.Param_Bytes);
            return;
         end if;

         Result := new String (1 .. Natural (Size) + 1);
      end;

      Open (Handle, In_File, Path);

      --  Read line by line and restore the separators, so that the prompt
      --  keeps its whitespace and newlines exactly.
      while not End_Of_File (Handle) loop
         declare
            --  The buffer holds the whole file, so there is always room for
            --  the rest of the current line and its separator.
            Stop : constant Natural := Result.all'Length - 1;
            Last : Natural;
         begin
            exit when Filled >= Stop;

            --  The procedure form reads into the buffer. The function form
            --  returns the line as a String, which for a file that is one
            --  very long line puts the entire file on the stack.
            Get_Line (Handle, Result.all (Filled + 1 .. Stop), Last);

            --  Last < Stop means the separator was reached rather than the
            --  buffer filling, so the line genuinely ended here.
            if Last < Stop and then not End_Of_File (Handle) then
               Result.all (Last + 1) := ASCII.LF;
               Filled := Last + 1;
            else
               Filled := Last;
            end if;
         end;
      end loop;

      Close (Handle);

      --  The slice is validated and copied in place. Binding it to a local
      --  constant first would put a copy of the whole file on the stack, and
      --  a file of a few megabytes -- well inside the documented limit --
      --  would then raise Storage_Error and be reported as an unreadable
      --  file, which is not what went wrong.
      if not Model_Runner.UTF8.Is_Valid (Result.all (1 .. Filled)) then
         Free_Text (Result);
         Status := E.Make (E.IO_Invalid_UTF8);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      declare
         Exact : constant Opt.Text_Access :=
           new String'(Result.all (1 .. Filled));
      begin
         Free_Text (Result);
         Result := Exact;
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.Status_Error =>
         if Is_Open (Handle) then
            Close (Handle);
         end if;
         Free_Text (Result);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
      when Storage_Error =>
         --  Running out of room is not a read failure, and saying so would
         --  send the reader to inspect a file that is perfectly fine.
         if Is_Open (Handle) then
            Close (Handle);
         end if;
         Free_Text (Result);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "prompt_file", E.Param_Identifier);
         E.Add_Text (Status, "path", Path, E.Param_Path);
      when others =>
         if Is_Open (Handle) then
            Close (Handle);
         end if;
         Free_Text (Result);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
   end Read_File;

   --  Read standard input to end of file, subject to a size limit.
   --
   --  Name is what the diagnostics call this source. Every message here is
   --  written for a file and asks for a path; standard input has none, and a
   --  message whose argument is missing renders as its own key, so the reader
   --  is told nothing at all. Passing the localized name for standard input
   --  gives "cannot read standard input" rather than a bare identifier.
   procedure Read_Standard_Input
     (Name   : String;
      Limit  : Natural;
      Result : out Opt.Text_Access;
      Status : out E.Error_Info)
   is
      use Ada.Text_IO;

      --  One byte past the limit, so that input which is exactly at the limit
      --  is accepted and anything beyond it is seen rather than truncated.
      Buffer : Opt.Text_Access := new String (1 .. Limit + 1);
      Filled : Natural := 0;
   begin
      Status := E.Success;
      Result := null;

      while not End_Of_File (Current_Input) loop
         declare
            Last : Natural;
         begin
            exit when Filled >= Buffer.all'Length;

            --  The procedure form reads into the buffer. The function form
            --  returns the line as a String, so input that is one very long
            --  line puts the whole of it on the stack, and the Storage_Error
            --  that follows is reported as a failure to read -- which is not
            --  what went wrong. Read_File avoids this for the same reason.
            Get_Line
              (Current_Input,
               Buffer.all (Filled + 1 .. Buffer.all'Length), Last);

            --  Last short of the end means the separator was reached rather
            --  than the buffer filling, so the line genuinely ended here.
            if Last < Buffer.all'Length and then not End_Of_File (Current_Input)
            then
               Buffer.all (Last + 1) := ASCII.LF;
               Filled := Last + 1;
            else
               Filled := Last;
            end if;
         end;
      end loop;

      --  Over the limit is refused, not shortened. Answering a prompt the
      --  reader did not finish writing is worse than declining to answer.
      if Filled > Limit then
         Free_Text (Buffer);
         Status := E.Make (E.IO_Input_Too_Large);
         E.Add_Text (Status, "path", Name, E.Param_Path);
         E.Add_Integer
           (Status, "limit", Long_Long_Integer (Limit), E.Param_Bytes);
         return;
      end if;

      --  Validated in place and copied once. Binding the content to a local
      --  constant first would put a second copy of it on the stack.
      if not Model_Runner.UTF8.Is_Valid (Buffer.all (1 .. Filled)) then
         Free_Text (Buffer);
         Status := E.Make (E.IO_Invalid_UTF8);
         E.Add_Text (Status, "path", Name, E.Param_Path);
         return;
      end if;

      Result := new String'(Buffer.all (1 .. Filled));
      Free_Text (Buffer);
   exception
      when Storage_Error =>
         --  As in Read_File: running out of room is not a read failure, and
         --  saying so sends the reader to inspect input that is perfectly fine.
         Free_Text (Buffer);
         Free_Text (Result);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "prompt_input", E.Param_Identifier);
         E.Add_Text (Status, "path", Name, E.Param_Path);
      when others =>
         Free_Text (Buffer);
         Free_Text (Result);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Name, E.Param_Path);
   end Read_Standard_Input;

   --  Build the model limits a command asks for.
   function Model_Bounds
     (Item : Opt.Command) return Model_Runner.Limits.Model_Limits
   is
      Result : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
   begin
      if Item.Memory_Limit /= 0 then
         Result.Max_Model_Bytes := Item.Memory_Limit;
      end if;
      return Result;
   end Model_Bounds;

   --  Load and validate a container, and prepare a model when asked.
   procedure Load
     (Item      : Opt.Command;
      Screen    : in out Pres.Console;
      Source    : in out Files.File_Source;
      Container : in out Containers.Container;
      Prepared  : in out L.Model;
      Full      : Boolean;
      Observer  : Model_Runner.Progress.Observer_Reference;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Status    : out E.Error_Info)
   is
      Bounds : constant Model_Runner.Limits.Model_Limits := Model_Bounds (Item);
      Path   : constant String := T.To_String (Item.Model_Path);
   begin
      Model_Runner.Progress.Publish
        (Observer,
         Model_Runner.Progress.Load_Progress
           (Model_Runner.Progress.Opening_Model));

      Files.Open
        (Source, Path, Item.Mapping,
         Model_Runner.Bytes.Byte_Count (Bounds.Max_File_Bytes), Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Item.Mapping = Files.Mapping_Automatic
        and then not Files.Is_Mapped (Source)
        and then Item.Level = Opt.Verbose
      then
         Pres.Warn (Screen, "warning.mapping_unavailable");
      end if;

      Containers.Reader.Parse
        (Container, Source, Bounds, Cancel, Observer, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Full then
         L.Prepare
           (Prepared, Container, Source, Bounds, Cancel, Observer, Status);
      end if;
   end Load;

   ---------------------------------------------------------------------------
   --  help and version
   ---------------------------------------------------------------------------

   procedure Show_Version (Screen : in out Pres.Console) is
   begin
      Screen.Put_Message
        ("application.version", [Loc.Named ("version", Model_Runner.Version)]);
      Screen.Put_Message
        ("application.license", [Loc.Named ("license", Model_Runner.License)]);
      Screen.Put_Message
        ("application.architecture",
         [Loc.Named ("name", L.Architecture_Name)]);
   end Show_Version;

   procedure Show_Help
     (Screen : in out Pres.Console;
      Topic  : String)
   is
      --  Emit a block of help lines, each an independent catalog entry so
      --  that a translation can reflow a line without breaking the layout.
      procedure Block (Keys : Loc.Argument_List) is
      begin
         for Entry_Value of Keys loop
            Screen.Put_Option (T.To_String (Entry_Value.Name));
         end loop;
      end Block;
   begin
      if Topic = "run" then
         Screen.Put_Message ("help.run.usage");
         Screen.Put_Line ("");
         Screen.Put_Message ("help.run.summary");
         Screen.Put_Line ("");
         Screen.Put_Message ("help.run.options");
         Block
           ([Loc.Named ("help.run.prompt", ""),
             Loc.Named ("help.run.prompt_file", ""),
             Loc.Named ("help.run.interactive", ""),
             Loc.Named ("help.run.raw", ""),
             Loc.Named ("help.run.system", ""),
             Loc.Named ("help.run.system_file", ""),
             Loc.Named ("help.run.max_tokens", ""),
             Loc.Named ("help.run.context_size", ""),
             Loc.Named ("help.run.threads", ""),
             Loc.Named ("help.run.batch_size", ""),
             Loc.Named ("help.run.temperature", ""),
             Loc.Named ("help.run.top_k", ""),
             Loc.Named ("help.run.top_p", ""),
             Loc.Named ("help.run.min_p", ""),
             Loc.Named ("help.run.repeat_penalty", ""),
             Loc.Named ("help.run.repeat_window", ""),
             Loc.Named ("help.run.seed", ""),
             Loc.Named ("help.run.stop", ""),
             Loc.Named ("help.run.stop_token", ""),
             Loc.Named ("help.run.memory_limit", ""),
             Loc.Named ("help.run.mmap", ""),
             Loc.Named ("help.run.no_mmap", ""),
             Loc.Named ("help.run.quiet", ""),
             Loc.Named ("help.run.verbose", ""),
             Loc.Named ("help.run.show_stats", ""),
             Loc.Named ("help.run.no_stats", ""),
             Loc.Named ("help.run.locale", ""),
             Loc.Named ("help.run.color", "")]);
         Screen.Put_Line ("");
         Screen.Put_Message ("help.run.streams");
         Screen.Put_Message ("help.run.privacy");

      elsif Topic = "inspect" then
         Screen.Put_Message ("help.inspect.usage");
         Screen.Put_Line ("");
         Screen.Put_Message ("help.inspect.summary");
         Screen.Put_Line ("");
         Screen.Put_Message ("help.inspect.options");
         Block
           ([Loc.Named ("help.inspect.metadata", ""),
             Loc.Named ("help.inspect.tensors", ""),
             Loc.Named ("help.inspect.validate", ""),
             Loc.Named ("help.inspect.locale", ""),
             Loc.Named ("help.inspect.color", "")]);

      elsif Topic = "version" then
         Screen.Put_Message ("help.version.usage");
         Screen.Put_Line ("");
         Screen.Put_Message ("help.version.summary");

      elsif Topic = "help" then
         Screen.Put_Message ("help.help.usage");
         Screen.Put_Line ("");
         Screen.Put_Message ("help.help.summary");

      else
         Screen.Put_Message ("application.summary");
         Screen.Put_Line ("");
         Screen.Put_Message ("cli.general.usage");
         Screen.Put_Line ("");
         Screen.Put_Message ("cli.general.commands");
         Block
           ([Loc.Named ("cli.general.command.run", ""),
             Loc.Named ("cli.general.command.inspect", ""),
             Loc.Named ("cli.general.command.help", ""),
             Loc.Named ("cli.general.command.version", "")]);
         Screen.Put_Line ("");
         Screen.Put_Message ("cli.general.more");
         Screen.Put_Message ("cli.general.exit_statuses");
      end if;
   end Show_Help;

   ---------------------------------------------------------------------------
   --  inspect
   ---------------------------------------------------------------------------

   procedure Do_Inspect
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Status  : out Natural)
   is
      Source    : Files.File_Source;
      Container : Containers.Container;
      Prepared  : L.Model;
      Condition : E.Error_Info;
      Ignored   : E.Error_Info;
   begin
      Load
        (Item, Screen, Source, Container, Prepared, False, null, null,
         Condition);

      if E.Is_Error (Condition) then
         Pres.Report (Screen, Condition);
         Files.Close (Source);
         Status := E.Exit_Status (Condition);
         return;
      end if;

      if Item.Validate_Only then
         Screen.Put_Message ("cli.inspect.valid");
         Containers.Close (Container);
         Files.Close (Source);
         Status := E.Exit_Success;
         return;
      end if;

      Pres.Put_Heading (Screen, "cli.inspect.heading.container");
      Pres.Put_Field
        (Screen, "cli.inspect.label.path",
         T.Escape_Controls (T.To_String (Item.Model_Path)));
      Pres.Put_Field
        (Screen, "cli.inspect.label.file_size",
         T.Image (Long_Long_Integer (Containers.File_Size (Container))));
      Pres.Put_Field
        (Screen, "cli.inspect.label.gguf_version",
         T.Image (Long_Long_Integer (Containers.Version (Container))));
      Pres.Put_Field
        (Screen, "cli.inspect.label.alignment",
         T.Image (Long_Long_Integer (Containers.Alignment (Container))));
      Pres.Put_Field
        (Screen, "cli.inspect.label.metadata_count",
         T.Image (Long_Long_Integer (Containers.Metadata_Count (Container))));
      Pres.Put_Field
        (Screen, "cli.inspect.label.tensor_count",
         T.Image (Long_Long_Integer (Containers.Tensor_Count (Container))));

      --  Parameter count and the set of formats actually used.
      declare
         Parameters : Interfaces.Unsigned_64 := 0;
         Formats    : array (G.Tensor_Type) of Boolean := [others => False];
         Listing    : String (1 .. 256);
         Filled     : Natural := 0;
      begin
         for Index in 1 .. Containers.Tensor_Count (Container) loop
            Parameters :=
              Parameters + Containers.Tensor_Elements (Container, Index);
            Formats (Containers.Tensor_Format (Container, Index)) := True;
         end loop;

         for Format in G.Tensor_Type loop
            if Formats (Format) then
               declare
                  Name : constant String := G.Type_Name (Format);
               begin
                  if Filled + Name'Length + 2 <= Listing'Length then
                     if Filled > 0 then
                        Listing (Filled + 1 .. Filled + 2) := ", ";
                        Filled := Filled + 2;
                     end if;
                     Listing (Filled + 1 .. Filled + Name'Length) := Name;
                     Filled := Filled + Name'Length;
                  end if;
               end;
            end if;
         end loop;

         Pres.Put_Field
           (Screen, "cli.inspect.label.parameters",
            T.Image (Long_Long_Integer (Parameters)));
         Pres.Put_Field
           (Screen, "cli.inspect.label.formats", Listing (1 .. Filled));
         Pres.Put_Field
           (Screen, "cli.inspect.label.mapped",
            Screen.Message_Value
              (if Files.Is_Mapped (Source)
               then "cli.inspect.value.yes"
               else "cli.inspect.value.no"));
      end;

      --  Architecture, read from metadata without loading any weights.
      declare
         Settings : L.Configuration;
         Detail   : E.Error_Info;
      begin
         L.Read_Config (Container, Model_Bounds (Item), Settings, Detail);

         if E.Is_Error (Detail) then
            Pres.Report (Screen, Detail);
         else
            Pres.Put_Heading (Screen, "cli.inspect.heading.architecture");
            Pres.Put_Field
              (Screen, "cli.inspect.label.name",
               T.Escape_Controls
                 (Containers.String_Value (Container, "general.name")));
            Pres.Put_Field
              (Screen, "cli.inspect.label.architecture", L.Architecture_Name);
            Pres.Put_Field
              (Screen, "cli.inspect.label.context_length",
               T.Image (Long_Long_Integer (Settings.Context_Length)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.embedding",
               T.Image (Long_Long_Integer (Settings.Embedding)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.feed_forward",
               T.Image (Long_Long_Integer (Settings.Feed_Forward)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.layers",
               T.Image (Long_Long_Integer (Settings.Layers)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.heads",
               T.Image (Long_Long_Integer (Settings.Heads)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.kv_heads",
               T.Image (Long_Long_Integer (Settings.KV_Heads)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.head_size",
               T.Image (Long_Long_Integer (Settings.Head_Size)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.rope_dimension",
               T.Image (Long_Long_Integer (Settings.Rotary)));
            Pres.Put_Field
              (Screen, "cli.inspect.label.rope_base",
               T.Image (Long_Float (Settings.Rope_Base), 1));

            --  Tokenizer.
            declare
               Words : Vocab.Vocabulary;
               Kind  : E.Error_Info;
            begin
               Vocab.Load (Words, Container, Model_Bounds (Item), Kind);
               Pres.Put_Heading (Screen, "cli.inspect.heading.tokenizer");
               if E.Is_Error (Kind) then
                  Pres.Report (Screen, Kind);
               else
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.tokenizer_model",
                     T.Escape_Controls (Vocab.Model_Name (Words)));
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.vocabulary",
                     T.Image (Long_Long_Integer (Vocab.Size (Words))));
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.byte_fallback",
                     Screen.Message_Value
                       (if Vocab.Has_Byte_Fallback (Words)
                        then "cli.inspect.value.yes"
                        else "cli.inspect.value.no"));
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.bos_token",
                     T.Image (Long_Long_Integer (Vocab.Beginning_Token (Words))));
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.eos_token",
                     T.Image (Long_Long_Integer (Vocab.End_Token (Words))));
                  Settings.Vocabulary := Vocab.Size (Words);
               end if;
               Vocab.Close (Words);
            end;

            --  Chat template: present and supported, present and outside the
            --  subset, or absent. Compiled here so the answer is evidence
            --  rather than a guess.
            declare
               Text_Value : constant String :=
                 Containers.String_Value (Container, "tokenizer.chat_template");
               Compiled   : Model_Runner.Templates.Compiled;
               Outcome    : E.Error_Info;
            begin
               if Text_Value = "" then
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.template",
                     Screen.Message_Value ("cli.inspect.value.absent"));
               else
                  Model_Runner.Templates.Compile
                    (Compiled, Text_Value, Model_Bounds (Item), Outcome);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.template",
                     Screen.Message_Value
                       (if E.Is_Ok (Outcome)
                        then "cli.inspect.value.present_supported"
                        else "cli.inspect.value.present_unsupported"));
                  if E.Is_Error (Outcome) and then Item.Level = Opt.Verbose then
                     Pres.Report (Screen, Outcome);
                  end if;
                  Model_Runner.Templates.Close (Compiled);
               end if;
            end;

            --  Memory estimate for the requested context.
            declare
               Plan   : Model_Runner.Memory.Session_Plan;
               Detail2 : E.Error_Info;
            begin
               L.Plan_For (Settings, Item.Context_Size, Plan, Detail2);
               Pres.Put_Heading (Screen, "cli.inspect.heading.memory");
               Pres.Put_Field
                 (Screen, "cli.inspect.label.model_bytes",
                  T.Image
                    (Long_Long_Integer
                       (Containers.Tensor_Data_Bytes (Container))));
               if E.Is_Ok (Detail2) then
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.session_bytes",
                     T.Image (Long_Long_Integer (Plan.Total_Resident)));
               end if;
            end;
         end if;
      end;

      --  Optional detail listings. Neither dumps a vocabulary by default.
      if Item.Show_Metadata then
         Pres.Put_Heading (Screen, "cli.inspect.heading.metadata");
         for Index in 1 .. Containers.Metadata_Count (Container) loop
            declare
               Key : constant String :=
                 Containers.Metadata_Key (Container, Index);
            begin
               Pres.Put_Data_Field
                 (Screen,
                  T.Escape_Controls (Key),
                  Containers.Value_Image (Container, Index));
            end;
         end loop;
      end if;

      if Item.Show_Tensors then
         Pres.Put_Heading (Screen, "cli.inspect.heading.tensors");
         for Index in 1 .. Containers.Tensor_Count (Container) loop
            declare
               Shape : String (1 .. 64) := [others => ' '];
               Last  : Natural := 0;
            begin
               for Axis in 1 .. Containers.Tensor_Rank (Container, Index) loop
                  declare
                     Piece : constant String :=
                       (if Axis > 1 then "x" else "")
                       & T.Image
                           (Long_Long_Integer
                              (Containers.Tensor_Dimension
                                 (Container, Index, Axis)));
                  begin
                     exit when Last + Piece'Length > Shape'Length;
                     Shape (Last + 1 .. Last + Piece'Length) := Piece;
                     Last := Last + Piece'Length;
                  end;
               end loop;

               Pres.Put_Field
                 (Screen,
                  "cli.inspect.label.name",
                  T.Escape_Controls
                    (Containers.Tensor_Name (Container, Index))
                  & "  " & Shape (1 .. Last)
                  & "  "
                  & G.Type_Name (Containers.Tensor_Format (Container, Index)));
            end;
         end loop;
      end if;

      L.Close (Prepared, Ignored);
      Containers.Close (Container);
      Files.Close (Source);
      Status := E.Exit_Success;
   end Do_Inspect;

   ---------------------------------------------------------------------------
   --  run
   ---------------------------------------------------------------------------

   procedure Do_Run
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Catalog : Loc.Catalog;
      Status  : out Natural)
   is
      pragma Unreferenced (Catalog);

      Source    : Files.File_Source;
      Container : Containers.Container;
      Prepared  : L.Model;
      Session   : L.Session;
      Stop_Set  : Model_Runner.Stops.Set;
      Sink      : aliased Pres.Standard_Output_Sink;
      Reporter  : aliased Pres.Progress_Reporter (Screen'Unchecked_Access);
      Clock     : aliased Model_Runner.Clocks.System_Clock;
      Seeds     : aliased Model_Runner.Entropy.Host_Source;
      Prompt    : Opt.Text_Access := null;
      Cancel    : aliased Model_Runner.Cancellation.Token;
      Attached  : Boolean := False;
      Condition : E.Error_Info;
      Ignored   : E.Error_Info;
      Outcome   : Gen.Result;

      procedure Cleanup is
      begin
         if Attached then
            Model_Runner.Platform.Signals.Remove;
            Attached := False;
         end if;
         Model_Runner.Stops.Close (Stop_Set);
         L.Close (Session);
         L.Close (Prepared, Ignored);
         Containers.Close (Container);
         Files.Close (Source);
         Gen.Release (Outcome);
         Free_Text (Prompt);
      end Cleanup;

      procedure Fail (Reason : E.Error_Info) is
      begin
         Pres.Report (Screen, Reason);
         Status := E.Exit_Status (Reason);
         Cleanup;
      end Fail;

      --  Everything from model loading onwards, parameterized by the worker
      --  pool so that the pool can be declared in a frame whose exit waits
      --  for its workers.
      procedure Run_With (Team : Workers_CPU.Pool_Reference) is
      begin
         Status := E.Exit_Success;

         --  Route an interrupt to a clean cancellation for the duration of the
         --  run. Loading and generation both observe it at bounded intervals.
         Model_Runner.Platform.Signals.Install (Cancel'Unchecked_Access, Attached);

      Load
        (Item, Screen, Source, Container, Prepared, True,
         Reporter'Unchecked_Access, Cancel'Unchecked_Access, Condition);
      if E.Is_Error (Condition) then
         Fail (Condition);
         return;
      end if;

      L.Open
        (Session, Prepared, Item.Context_Size,
         Workers => Team, Status => Condition);
      if E.Is_Error (Condition) then
         Fail (Condition);
         return;
      end if;

      --  Interactive mode owns its own loop; it needs the same prepared model
      --  and session, so it is entered here rather than earlier.
      if Item.Prompt_Kind = Opt.Prompt_Interactive then
         Model_Runner.CLI.Interactive.Run
           (Item, Screen, Prepared, Session, Status);
         Cleanup;
         return;
      end if;

      --  Resolve the prompt.
      case Item.Prompt_Kind is
         when Opt.Prompt_Inline =>
            Prompt := new String'(Item.Prompt_Text.all);

         when Opt.Prompt_File =>
            Read_File
              (T.To_String (Item.Prompt_Path),
               Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes,
               Prompt, Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;

         when others =>
            Read_Standard_Input
              (Pres.Message_Value (Screen, "cli.label.standard_input"),
               Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes,
               Prompt, Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;
      end case;

      if Prompt = null or else Prompt.all'Length = 0 then
         Fail (E.Make (E.CLI_No_Prompt_Available));
         return;
      end if;

      if not Model_Runner.UTF8.Is_Valid (Prompt.all) then
         Fail (E.Make (E.IO_Invalid_UTF8));
         return;
      end if;

      --  Build the text that will actually be tokenized. Raw mode sends the
      --  prompt unchanged; conversation mode renders it through the model's
      --  own template and fails rather than guessing when that is unusable.
      declare
         Rendered : Opt.Text_Access := null;

         procedure Release_Rendered is
         begin
            Free_Text (Rendered);
         end Release_Rendered;
      begin
         if Item.Raw then
            Rendered := new String'(Prompt.all);
         else
            if not L.Template_Ready (Prepared) then
               Fail (L.Template_Condition (Prepared));
               return;
            end if;

            declare
               Messages : Conv.History;
               --  The render buffer is bounded by the session limit and is
               --  allocated rather than declared: the limit is large enough
               --  that a stack object of that size would not fit.
               Buffer   : Opt.Text_Access :=
                 new String
                   (1 .. Model_Runner.Limits.Default_Session_Limits
                           .Max_Rendered_Bytes);
               Last     : Natural;
               Words    : constant access constant Vocab.Vocabulary :=
                 L.Vocabulary (Prepared);
            begin
               Conv.Open (Messages, Status => Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               if Item.Has_System then
                  declare
                     System_Text : Opt.Text_Access := null;
                  begin
                     null;
                     if Item.System_Text /= null then
                        System_Text := new String'(Item.System_Text.all);
                     else
                        Read_File
                          (T.To_String (Item.System_Path),
                           Model_Runner.Limits.Default_Session_Limits
                             .Max_Prompt_Bytes,
                           System_Text, Condition);
                        if E.Is_Error (Condition) then
                           Conv.Close (Messages);
                           Fail (Condition);
                           return;
                        end if;
                     end if;

                     Conv.Append
                       (Messages, Conv.System_Role, System_Text.all, Condition);
                     Free_Text (System_Text);
                     if E.Is_Error (Condition) then
                        Free_Text (Buffer);
                        Conv.Close (Messages);
                        Fail (Condition);
                        return;
                     end if;
                  end;
               end if;

               Conv.Append (Messages, Conv.User_Role, Prompt.all, Condition);
               if E.Is_Error (Condition) then
                  Free_Text (Buffer);
                  Conv.Close (Messages);
                  Fail (Condition);
                  return;
               end if;

               Model_Runner.Templates.Render
                 (L.Template (Prepared).all, Messages,
                  Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
                  Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
                  True, Buffer.all, Last, Condition);
               Conv.Close (Messages);

               if E.Is_Error (Condition) then
                  Free_Text (Buffer);
                  Fail (Condition);
                  return;
               end if;

               Rendered := new String'(Buffer.all (1 .. Last));
               Free_Text (Buffer);
            end;
         end if;

         --  Stop conditions.
         Model_Runner.Stops.Open (Stop_Set);
         for Index in 1 .. Item.Stop_Count loop
            Model_Runner.Stops.Add_String
              (Stop_Set, T.To_String (Item.Stop_Strings (Index)), Condition);
            if E.Is_Error (Condition) then
               Release_Rendered;
               Fail (Condition);
               return;
            end if;
         end loop;

         for Index in 1 .. Item.Stop_Token_Count loop
            Model_Runner.Stops.Add_Token
              (Stop_Set, Vocab.Token_Id (Item.Stop_Tokens (Index)), Condition);
            if E.Is_Error (Condition) then
               Release_Rendered;
               Fail (Condition);
               return;
            end if;
         end loop;

         --  A rendered conversation already carries the beginning token, so
         --  the tokenizer must not add a second one.
         declare
            Request : Gen.Request;
         begin
            Request.Max_Tokens := Item.Max_Tokens;
            Request.Sampling := Item.Sampling;
            Request.Seed := Item.Seed;
            Request.Has_Seed := Item.Has_Seed;
            Request.Batch_Size := Item.Batch_Size;
            Request.Retain_Text := False;
            Request.Add_Beginning := Item.Raw;

            Gen.Generate
              (Source   => Prepared,
               Session  => Session,
               Prompt   => Rendered.all,
               Item     => Request,
               Stop_Set => Stop_Set,
               Sink     => Sink'Unchecked_Access,
               Observer => Reporter'Unchecked_Access,
               Time     => Clock'Unchecked_Access,
               Seeds    => Seeds'Unchecked_Access,
               Cancel   => Cancel'Unchecked_Access,
               Outcome  => Outcome);
         end;

         Release_Rendered;
      end;

      if Outcome.Reason = Gen.Runtime_Error then
         Fail (Outcome.Error);
         return;
      end if;

      --  Statistics go to standard error, so a redirected standard output
      --  still contains only generated text.
      if Item.Show_Stats
        or else (not Item.Stats_Set and then Item.Level = Opt.Verbose)
      then
         Pres.Put_Statistics (Screen, Outcome);
      end if;

      Status := E.Exit_Success;
      Cleanup;
      end Run_With;

      --  Worker count: an explicit --threads wins, otherwise the core count
      --  bounded by what the backend accepts. One worker means serial
      --  execution, and produces the same output as any other count.
      --
      --  Cores rather than processors, because on a machine with two
      --  processors per core the second of each pair shares the first's
      --  execution units. Measured on an eight-core Ryzen 7 7840U that
      --  reports sixteen: twelve tokens take 2.20 s of wall with eight
      --  workers and 2.22 s with fourteen, and 14.9 s of processor time
      --  against 26.7 s. The extra workers buy nothing and cost nearly twice
      --  the energy, which matters most on the battery this is likeliest to
      --  run on. --threads still takes any number the backend accepts.
      function Chosen_Workers return Natural is
      begin
         if Item.Threads > 0 then
            return Natural'Min (Item.Threads, Workers_CPU.Max_Workers);
         else
            return Natural'Min
              (Model_Runner.Platform.Core_Count, Workers_CPU.Max_Workers);
         end if;
      end Chosen_Workers;

      Team_Size : constant Natural := Chosen_Workers;

   begin
      if Team_Size <= 1 then
         Run_With (null);
      else
         declare
            --  Declared here so that leaving this block waits for the workers
            --  to terminate; nothing is deallocated and no task outlives the
            --  command.
            Team : aliased Workers_CPU.Pool
              (Workers_CPU.Worker_Count (Team_Size));
         begin
            Run_With (Team'Unchecked_Access);
            Workers_CPU.Close (Team);
         exception
            --  The workers are told to stop before the exception leaves this
            --  block. Without this they are still waiting for work when the
            --  block is left, and leaving waits for them to terminate: the
            --  program stops responding instead of reporting what went wrong.
            --  That is not hypothetical -- an unsigned seed converted to a
            --  signed type raised here, and a verbose run with more than one
            --  worker hung rather than saying anything.
            when others =>
               Workers_CPU.Close (Team);
               raise;
         end;
      end if;
   end Do_Run;

   --------------
   -- Dispatch --
   --------------

   procedure Dispatch
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Catalog : Loc.Catalog;
      Status  : out Natural) is
   begin
      case Item.Kind is
         when Opt.Command_Version =>
            Show_Version (Screen);
            Status := E.Exit_Success;

         when Opt.Command_Help =>
            Show_Help (Screen, T.To_String (Item.Help_Topic));
            Status := E.Exit_Success;

         when Opt.Command_Inspect =>
            Do_Inspect (Item, Screen, Status);

         when Opt.Command_Run =>
            Do_Run (Item, Screen, Catalog, Status);

         when Opt.Command_None =>
            Pres.Report (Screen, E.Make (E.CLI_Missing_Command));
            Status := E.Exit_Usage;
      end case;
   exception
      when others =>
         Pres.Report (Screen, E.Make (E.Internal_Unexpected_Exception));
         Status := E.Exit_Internal;
   end Dispatch;

end Model_Runner.CLI.Execute;
