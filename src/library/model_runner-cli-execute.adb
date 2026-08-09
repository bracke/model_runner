with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Interfaces;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Reference;
with Model_Runner.Bytes;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.Quantization;
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

   use type Opt.Command_Kind;
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

   --  Limits applied to a session, from the same command line.
   --
   --  --memory-limit bounded the model and nothing else. A session holds the
   --  KV cache, which grows with the context and is the largest thing it
   --  allocates, so a caller asking for a hundred megabytes could be given a
   --  model inside it and then a session of any size at all.
   function Session_Bounds
     (Item : Opt.Command) return Model_Runner.Limits.Session_Limits
   is
      Result : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
   begin
      if Item.Memory_Limit /= 0 then
         Result.Max_Session_Bytes := Item.Memory_Limit;
      end if;
      return Result;
   end Session_Bounds;

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
           (Prepared, Container, Source, Bounds, Cancel, Observer,
            Item.Backend, Item.Repack, Status);

         --  A chat format named on the command line replaces the model's
         --  own. Models whose template this build will not compile are
         --  otherwise usable only in raw mode, and naming the format is a
         --  decision a reader can check -- nothing here guesses one from the
         --  model, because a chat format applied to the wrong model produces
         --  output that looks entirely reasonable and is not what the model
         --  was trained on.
         if E.Is_Ok (Status)
           and then not Model_Runner.Text.Is_Empty (Item.Chat_Template)
         then
            L.Use_Template
              (Prepared,
               Model_Runner.Templates.Built_In
                 (Model_Runner.Text.To_String (Item.Chat_Template)),
               Bounds, Status);
         end if;
      end if;
   end Load;

   ---------------------------------------------------------------------------
   --  help and version
   ---------------------------------------------------------------------------

   --  The chat formats this build carries, in the order they are
   --  declared. Written out beside the option before this, where it said
   --  "llama3 or chatml" and would have gone on saying it.
   function Format_Names return String is
      Room : String (1 .. 256);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Format in Model_Runner.Templates.Chat_Format loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (Model_Runner.Templates.Format_Name (Format));
      end loop;
      return Room (1 .. Used);
   end Format_Names;

   --  The backends this build has, in the order they are declared.
   function Backend_Names return String is
      Room : String (1 .. 256);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Kind in Model_Runner.Backend.Backend_Kind loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (Model_Runner.Backend.Backend_Name (Kind));
      end loop;
      return Room (1 .. Used);
   end Backend_Names;

   --  The architectures this build reads, in the order they are declared.
   function Architecture_Names return String is
      Room : String (1 .. 128);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Kind in L.Architecture loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (L.Architecture_Name (Kind));
      end loop;
      return Room (1 .. Used);
   end Architecture_Names;

   --  The tensor formats this build decodes, in the order they are declared.
   function Decodable_Formats return String is
      Room : String (1 .. 256);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Format in Model_Runner.GGUF.Tensor_Type loop
         if Model_Runner.Quantization.Is_Decodable (Format) then
            if Used > 0 then
               Add (", ");
            end if;
            Add (Model_Runner.GGUF.Type_Name (Format));
         end if;
      end loop;
      return Room (1 .. Used);
   end Decodable_Formats;

   procedure Show_Version (Screen : in out Pres.Console) is
   begin
      Screen.Put_Message
        ("application.version", [Loc.Named ("version", Model_Runner.Version)]);
      Screen.Put_Message
        ("application.license", [Loc.Named ("license", Model_Runner.License)]);
      Screen.Put_Message
        ("application.architecture",
         [Loc.Named ("name", Architecture_Names)]);

      --  What this build can actually take, asked of the build. Someone
      --  running version wants to know whether their file will open, and
      --  the answer was one architecture name and nothing else -- while the
      --  program could already list its formats, its backends and its chat
      --  formats for itself, and does, in help.
      Screen.Put_Message
        ("application.formats", [Loc.Named ("value", Decodable_Formats)]);
      Screen.Put_Message
        ("application.backends", [Loc.Named ("value", Backend_Names)]);
      Screen.Put_Message
        ("application.chat_formats", [Loc.Named ("value", Format_Names)]);
   end Show_Version;

   procedure Show_Help
     (Screen : in out Pres.Console;
      Topic  : String)
   is

      --  Emit a block of help lines, each an independent catalog entry so
      --  that a translation can reflow a line without breaking the layout.
      --
      --  An entry's name is the catalog key and its value, when it has one,
      --  is what the line's {value} stands for. That is how a line listing
      --  what this build carries stays in the block with the rest instead of
      --  being printed beside it and losing its indentation.
      --  Every option a command takes, in the order the registry holds
      --  them, each with the line that documents it.
      --
      --  The lists used to be written out here beside a parser that
      --  accepted a different set: `inspect` documented five options and
      --  took thirty-seven, and --quiet and --verbose worked there while
      --  appearing only under run. Generated from the registry, a help
      --  screen cannot say less than the command accepts.
      procedure Options_Of (Kind : Opt.Command_Kind; Topic_Name : String) is
      begin
         for Index in 1 .. Opt.Option_Count loop
            if Opt.Option_Commands (Index) (Kind)
              and then Opt.Option_Help (Index) /= ""
            then
               declare
                  Key : constant String :=
                    "help." & Topic_Name & "." & Opt.Option_Help (Index);

                  --  Three lines name what this build carries rather than
                  --  a list somebody typed. The value goes in as an
                  --  argument so the sentence around it stays localized.
                  Value : constant String :=
                    (if Opt.Option_Name (Index) = "--color"
                     then Opt.Color_Names
                     elsif Opt.Option_Name (Index) = "--backend"
                     then Backend_Names
                     elsif Opt.Option_Name (Index) = "--chat-template"
                     then Format_Names
                     else "");
               begin
                  Screen.Put_Option (Key, [Loc.Named ("value", Value)]);
               end;
            end if;
         end loop;
      end Options_Of;

   begin
      --  Dispatched on the command a topic names rather than on the word,
      --  and every screen builds its keys from that command's word. The
      --  chain here used to name the four topics beside a Command_Kind that
      --  already named exactly those four, so a fifth command would have
      --  compiled, dispatched, taken options -- and had no help.
      case Opt.Command_Of (Topic) is
         when Opt.Command_Run | Opt.Command_Inspect =>
            declare
               Kind : constant Opt.Command_Kind := Opt.Command_Of (Topic);
               Word : constant String := Opt.Command_Word (Kind);
            begin
               Screen.Put_Message ("help." & Word & ".usage");
               Screen.Put_Line ("");
               Screen.Put_Message ("help." & Word & ".summary");
               Screen.Put_Line ("");
               Screen.Put_Message ("help." & Word & ".options");
               Options_Of (Kind, Word);

               --  Where the output goes and what is never written down are
               --  properties of a run, and are said where a run is
               --  explained.
               if Kind = Opt.Command_Run then
                  Screen.Put_Line ("");
                  Screen.Put_Message ("help.run.streams");
                  Screen.Put_Message ("help.run.privacy");
               end if;
            end;

         when Opt.Command_Help | Opt.Command_Version =>
            declare
               Word : constant String :=
                 Opt.Command_Word (Opt.Command_Of (Topic));
            begin
               Screen.Put_Message ("help." & Word & ".usage");
               Screen.Put_Line ("");
               Screen.Put_Message ("help." & Word & ".summary");
            end;

         when Opt.Command_None =>
            --  No topic. A topic naming no command never reaches here: the
            --  parser refuses it the way it refuses the same word typed as
            --  a command.
            Screen.Put_Message ("application.summary");
            Screen.Put_Line ("");
            Screen.Put_Message ("cli.general.usage");
            Screen.Put_Line ("");
            Screen.Put_Message ("cli.general.commands");

            for Kind in Opt.Command_Kind loop
               if Kind /= Opt.Command_None then
                  Screen.Put_Option
                    ("cli.general.command." & Opt.Command_Word (Kind),
                     [Loc.Named ("value", "")]);
               end if;
            end loop;

            Screen.Put_Line ("");
            Screen.Put_Message ("cli.general.more");
            Screen.Put_Message ("cli.general.exit_statuses");
      end case;
   end Show_Help;

   ---------------------------------------------------------------------------
   --  inspect
   ---------------------------------------------------------------------------

   --  What the chosen backend says it can do. Asked of the backend rather
   --  than taken from the CPU pool's constants, so that a second backend's
   --  numbers are the numbers used -- for the worker count and for whether a
   --  batch is worth asking for.
   --
   --  @param Item Parsed command.
   --  @return The capability record of the backend the command names.
   function Selected_Capabilities
     (Item : Opt.Command) return Model_Runner.Backend.Capabilities
   is (case Item.Backend is
         when Model_Runner.Backend.Backend_CPU =>
           Workers_CPU.Describe (Workers_CPU.Max_Workers),
         when Model_Runner.Backend.Backend_Reference =>
           Model_Runner.Backend.Reference.Describe);

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
   --
   --  Shared with inspect, which reports it. A run and an inspection that
   --  disagreed about the worker count would make the reported one useless.
   --
   --  @param Item Parsed command.
   --  @return Worker tasks the run would use.
   function Selected_Workers (Item : Opt.Command) return Positive is
      Able : constant Model_Runner.Backend.Capabilities :=
        Selected_Capabilities (Item);
   begin
      if not Able.Supports_Parallel then
         return 1;
      elsif Item.Threads > 0 then
         return Positive'Min (Item.Threads, Able.Max_Workers);
      else
         --  The policy lives with the pool, which is what knows that a job
         --  is cut into one more share than it has workers.
         return Positive
           (Workers_CPU.Default_Workers (Model_Runner.Platform.Core_Count));
      end if;
   end Selected_Workers;

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

      Pres.Put_Heading (Screen, "cli.inspect.heading.container", Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.path",
         T.Escape_Controls (T.To_String (Item.Model_Path)), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.file_size",
         T.Image (Long_Long_Integer (Containers.File_Size (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.gguf_version",
         T.Image (Long_Long_Integer (Containers.Version (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.alignment",
         T.Image (Long_Long_Integer (Containers.Alignment (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.metadata_count",
         T.Image (Long_Long_Integer (Containers.Metadata_Count (Container))), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.tensor_count",
         T.Image (Long_Long_Integer (Containers.Tensor_Count (Container))), Pres.Answer);

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
            T.Image (Long_Long_Integer (Parameters)), Pres.Answer);
         Pres.Put_Field
           (Screen, "cli.inspect.label.formats", Listing (1 .. Filled), Pres.Answer);
         Pres.Put_Field
           (Screen, "cli.inspect.label.mapped",
            Screen.Message_Value
              (if Files.Is_Mapped (Source)
               then "cli.inspect.value.yes"
               else "cli.inspect.value.no"), Pres.Answer);
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
            Pres.Put_Heading (Screen, "cli.inspect.heading.architecture", Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.name",
               T.Escape_Controls
                 (Containers.String_Value (Container, "general.name")), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.architecture",
               Containers.String_Value (Container, "general.architecture"), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.context_length",
               T.Image (Long_Long_Integer (Settings.Context_Length)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.embedding",
               T.Image (Long_Long_Integer (Settings.Embedding)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.feed_forward",
               T.Image (Long_Long_Integer (Settings.Feed_Forward)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.layers",
               T.Image (Long_Long_Integer (Settings.Layers)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.heads",
               T.Image (Long_Long_Integer (Settings.Heads)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.kv_heads",
               T.Image (Long_Long_Integer (Settings.KV_Heads)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.head_size",
               T.Image (Long_Long_Integer (Settings.Head_Size)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.rope_dimension",
               T.Image (Long_Long_Integer (Settings.Rotary)), Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.rope_base",
               T.Image (Long_Float (Settings.Rope_Base), 1), Pres.Answer);

            --  Tokenizer.
            declare
               Words : Vocab.Vocabulary;
               Kind  : E.Error_Info;
            begin
               Vocab.Load (Words, Container, Model_Bounds (Item), Kind);
               Pres.Put_Heading (Screen, "cli.inspect.heading.tokenizer", Pres.Answer);
               if E.Is_Error (Kind) then
                  Pres.Report (Screen, Kind);
               else
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.tokenizer_model",
                     T.Escape_Controls (Vocab.Model_Name (Words)), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.vocabulary",
                     T.Image (Long_Long_Integer (Vocab.Size (Words))), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.byte_fallback",
                     Screen.Message_Value
                       (if Vocab.Has_Byte_Fallback (Words)
                        then "cli.inspect.value.yes"
                        else "cli.inspect.value.no"), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.bos_token",
                     T.Image (Long_Long_Integer (Vocab.Beginning_Token (Words))), Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.eos_token",
                     T.Image (Long_Long_Integer (Vocab.End_Token (Words))), Pres.Answer);
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
                     Screen.Message_Value ("cli.inspect.value.absent"), Pres.Answer);
               else
                  Model_Runner.Templates.Compile
                    (Compiled, Text_Value, Model_Bounds (Item), Outcome);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.template",
                     Screen.Message_Value
                       (if E.Is_Ok (Outcome)
                        then "cli.inspect.value.present_supported"
                        else "cli.inspect.value.present_unsupported"), Pres.Answer);
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
               Pres.Put_Heading (Screen, "cli.inspect.heading.memory", Pres.Answer);
               Pres.Put_Field
                 (Screen, "cli.inspect.label.model_bytes",
                  T.Image
                    (Long_Long_Integer
                       (Containers.Tensor_Data_Bytes (Container))), Pres.Answer);
               if E.Is_Ok (Detail2) then
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.session_bytes",
                     T.Image (Long_Long_Integer (Plan.Total_Resident)),
                     Pres.Answer);
               end if;

               --  What --repack would need, which is the one number a caller
               --  weighing that flag has to have and could get only by trying
               --  it and watching. Every matrix becomes four bytes a weight;
               --  the vectors are decoded already and are not repacked.
               declare
                  Repacked : Interfaces.Unsigned_64 := 0;
               begin
                  for Index in 1 .. Containers.Tensor_Count (Container) loop
                     if Containers.Tensor_Rank (Container, Index) >= 2 then
                        Repacked := Repacked
                          + Containers.Tensor_Elements (Container, Index) * 4;
                     end if;
                  end loop;

                  Pres.Put_Field
                    (Screen, "cli.inspect.label.repacked_bytes",
                     T.Image (Long_Long_Integer (Repacked)), Pres.Answer);
               end;
            end;
         end if;
      end;

      --  What would evaluate this model, which is not a property of the file
      --  but of the command that was typed. It is reported here because the
      --  answer stopped being obvious when a second backend arrived: --backend
      --  reference takes one worker whatever --threads says, and a caller who
      --  cannot see that has no way to tell a slow run from a wrong one.
      Pres.Put_Heading (Screen, "cli.inspect.heading.execution", Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.backend",
         Model_Runner.Backend.Backend_Name (Item.Backend), Pres.Answer);
      Pres.Put_Field
        (Screen, "cli.inspect.label.workers",
         T.Image (Long_Long_Integer (Selected_Workers (Item))), Pres.Answer);

      --  Optional detail listings. Neither dumps a vocabulary by default.
      if Item.Show_Metadata then
         Pres.Put_Heading (Screen, "cli.inspect.heading.metadata", Pres.Answer);
         for Index in 1 .. Containers.Metadata_Count (Container) loop
            declare
               Key : constant String :=
                 Containers.Metadata_Key (Container, Index);
            begin
               Pres.Put_Data_Field
                 (Screen,
                  T.Escape_Controls (Key),
                  Containers.Value_Image (Container, Index), Pres.Answer);
            end;
         end loop;
      end if;

      if Item.Show_Tensors then
         Pres.Put_Heading (Screen, "cli.inspect.heading.tensors", Pres.Answer);
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
                  & G.Type_Name (Containers.Tensor_Format (Container, Index)), Pres.Answer);
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
            Session_Bounds => Session_Bounds (Item),
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

                  --  Said here because here is where it happens. Generation is
                  --  handed a prompt that is already rendered and never sees
                  --  the conversation it came from, so the stage it declares
                  --  for this could only ever be published by its caller --
                  --  and was published by nobody.
                  Model_Runner.Progress.Publish
                    (Reporter'Unchecked_Access,
                     Model_Runner.Progress.Generation_Progress
                       (Model_Runner.Progress.Prompt_Rendered,
                        Interfaces.Unsigned_64 (Last)));
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
               --  A backend that does not batch is asked for one token at
               --  a time rather than refused. The capability decides the
               --  request instead of failing it, which is what a capability
               --  is for; --batch-size is a performance control and this is
               --  the performance the chosen backend has.
               Request.Batch_Size :=
                 (if L.Capability (Prepared).Supports_Batched
                  then Item.Batch_Size
                  else 1);

               if not L.Capability (Prepared).Supports_Batched
                 and then Item.Batch_Size /= 1
                 and then Item.Level = Opt.Verbose
               then
                  Pres.Warn
                    (Screen, "warning.backend_no_batching",
                     [Loc.Named
                        ("value",
                         Model_Runner.Backend.Backend_Name
                           (L.Capability (Prepared).Kind))]);
               end if;
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

      Team_Size : constant Natural := Selected_Workers (Item);

   begin
      --  Which backend runs this. There is one, and going through the choice
      --  rather than around it is what makes --backend an option and not a
      --  word the parser accepts and forgets. The case has no others, so a
      --  kind added to the enumeration stops this compiling until something
      --  here answers for it -- which is the only way a second backend can
      --  arrive without the flag that selects it quietly doing nothing.
      case Item.Backend is
      when Model_Runner.Backend.Backend_Reference =>
         --  No pool: this backend runs on the calling task and says so.
         Run_With (null);

      when Model_Runner.Backend.Backend_CPU =>
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
      end case;
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
