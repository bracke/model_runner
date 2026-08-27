with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Interfaces;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
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
with Model_Runner.Grammar;
with Model_Runner.Schema;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Memory;
with Model_Runner.Numerics;
with Model_Runner.Cancellation;
with Model_Runner.Platform;
with Model_Runner.Platform.Device;
with Model_Runner.Platform.Signals;
with Model_Runner.Progress;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tools;
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
   package N renames Model_Runner.Numerics;

   procedure Free_Reals is
     new Ada.Unchecked_Deallocation
       (Model_Runner.Numerics.Real_Array,
        Model_Runner.Tensors.Real_Array_Access);
   package Opt renames Model_Runner.CLI.Options;

   use type Opt.Command_Kind;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type L.Repack_Mode;
   use type L.Pooling_Choice;
   use type Opt.Pooling_Kind;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;
   package Pres renames Model_Runner.Presentation;
   package Workers_CPU renames Model_Runner.Backend.CPU;
   package T renames Model_Runner.Text;
   package Vocab renames Model_Runner.Tokenizer;

   procedure Free_Text is
     new Ada.Unchecked_Deallocation (String, Opt.Text_Access);

   --  Read a whole file as UTF-8, subject to a size limit.
   --  Write bytes to a path, replacing whatever was there.
   --
   --  Here rather than in the engine: the units that interpret what a model
   --  says may not reach the filesystem, and a saved context is written by
   --  the program rather than by the model.
   procedure Write_File
     (Path   : String;
      Data   : Model_Runner.Bytes.Byte_Array;
      Status : out E.Error_Info)
   is
      use Ada.Streams;

      Handle : Ada.Streams.Stream_IO.File_Type;
      Block  : Stream_Element_Array (1 .. Stream_Element_Offset (Data'Length));
      At_Byte : Stream_Element_Offset := 0;
   begin
      Status := E.Success;

      for Value of Data loop
         At_Byte := At_Byte + 1;
         Block (At_Byte) := Stream_Element (Value);
      end loop;

      begin
         Ada.Streams.Stream_IO.Create
           (Handle, Ada.Streams.Stream_IO.Out_File, Path);
         Ada.Streams.Stream_IO.Write (Handle, Block);
         Ada.Streams.Stream_IO.Close (Handle);
      exception
         when others =>
            if Ada.Streams.Stream_IO.Is_Open (Handle) then
               Ada.Streams.Stream_IO.Close (Handle);
            end if;
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
      end;
   end Write_File;

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
           Model_Runner.Backend.Reference.Describe,
         when Model_Runner.Backend.Backend_Device =>
           Model_Runner.Backend.Device.Describe);

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
      use type Model_Runner.Backend.Backend_Kind;

      Able : constant Model_Runner.Backend.Capabilities :=
        Selected_Capabilities (Item);

      --  Supports_Parallel says whether a backend's own products divide
      --  across workers, and the device's do not: they divide across the
      --  device. But a run is not only its products. Normalizing a batch
      --  and joining its residuals are loops over positions on the host
      --  whichever backend answers, and they were a fifth of a device
      --  prompt with nothing to share them out to. So the device is given
      --  a pool for those, and Max_Workers -- which is one, because that
      --  is a statement about products -- is not what bounds it.
      Device : constant Boolean :=
        Item.Backend = Model_Runner.Backend.Backend_Device;

      Most : constant Positive :=
        (if Device then Model_Runner.Platform.Core_Count
         else Able.Max_Workers);
   begin
      if not Able.Supports_Parallel and then not Device then
         return 1;
      elsif Item.Threads > 0 then
         return Positive'Min (Item.Threads, Most);
      else
         --  The policy lives with the pool, which is what knows that a job
         --  is cut into one more share than it has workers.
         return Positive
           (Workers_CPU.Default_Workers (Model_Runner.Platform.Core_Count));
      end if;
   end Selected_Workers;

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
      Status    : out E.Error_Info;

      --  Which file to load, for the caller that wants a second model: the
      --  draft is loaded exactly as the model is, with the same limits and
      --  the same refusals, and differs only in which path it reads.
      Instead   : String := "")
   is
      Bounds : constant Model_Runner.Limits.Model_Limits := Model_Bounds (Item);
      Path   : constant String :=
        (if Instead = "" then T.To_String (Item.Model_Path) else Instead);
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
         --  An adapter is merged into the weights, and only binary32 ones
         --  can be added to, so naming one selects that repacking where the
         --  caller named none. The help says so where the option is
         --  documented: it costs four bytes a weight, which is the same
         --  bargain --repack f32 already publishes.
         L.Prepare
           (Prepared, Container, Source, Bounds, Cancel, Observer,
            Item.Backend,
            (if Item.Repack = L.No_Repack
               and then not T.Is_Empty (Item.Adapter_Path)
             then L.To_F32
             else Item.Repack),

            --  A caller who named --device-memory has been told what the
            --  device has and said what to use anyway, so a model larger
            --  than that is run rather than refused. What it costs is
            --  reported: the statistics say how many matrices were given
            --  back, which is how many were uploaded again.
            Fit_Required => not Item.Device_Memory_Set,
            Threads      => Selected_Workers (Item),
            Status       => Status);

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

      --  And what the machine has, which is a different question from what
      --  the build can do. Nothing runs on a device yet; this reports what
      --  one would run on, so that a reader can tell "this build cannot" from
      --  "this machine has none" before either becomes a surprise.
      declare
         package Devices renames Model_Runner.Platform.Device;

         Held  : Devices.Inventory;
         Found : Boolean;

         Room : String (1 .. 512) := [others => ' '];
         Used : Natural := 0;

         procedure Add (Text : String) is
         begin
            if Used + Text'Length <= Room'Last then
               Room (Used + 1 .. Used + Text'Length) := Text;
               Used := Used + Text'Length;
            end if;
         end Add;
      begin
         Devices.Open (Held, Found);

         for Index in 1 .. Devices.Count (Held) loop
            if Used > 0 then
               Add (", ");
            end if;
            Add (Devices.Name (Held, Index));

            --  Whether it has its own memory, because that is what decides
            --  whether moving a model to it costs anything.
            Add ((if Devices.Is_Discrete (Held, Index)
                  then " (discrete)"
                  else " (integrated)"));
         end loop;

         Screen.Put_Message
           ("application.devices",
            [Loc.Named ("value",
                        (if Used = 0 then "none" else Room (1 .. Used)))]);

         Devices.Close (Held);
      end;
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
                    (if Opt.Option_Name (Index) = "--repack"
                     then Opt.Repack_Names
                     elsif Opt.Option_Name (Index) = "--kv-cache"
                     then Opt.Cache_Names
                     elsif Opt.Option_Name (Index) = "--arith"
                     then Opt.Arithmetic_Names
                     elsif Opt.Option_Name (Index) = "--pooling"
                     then Opt.Pooling_Names
                     elsif Opt.Option_Name (Index) = "--color"
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
         when Opt.Command_Run | Opt.Command_Embed | Opt.Command_Inspect =>
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
               elsif Kind = Opt.Command_Embed then
                  Screen.Put_Line ("");
                  Screen.Put_Message ("help.embed.streams");
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

      --  The first refusal this inspection printed, if any. The report goes
      --  on past it; the status does not pretend it did not happen.
      Refused   : E.Error_Info;
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
         --  The container is sound; whether this build can use the model is
         --  the other half of the question, and the verdict is the whole of
         --  what this option prints. It used to answer only the first half:
         --  a model whose architecture this build does not implement was
         --  called valid and left with a success, while `run` on the same
         --  file refuses it and leaves with four.
         declare
            Settings : L.Configuration;
            Detail   : E.Error_Info;
         begin
            L.Read_Config (Container, Model_Bounds (Item), Settings, Detail);

            if E.Is_Error (Detail) then
               Pres.Report (Screen, Detail);
               Status := E.Exit_Status (Detail);
            else
               Screen.Put_Message ("cli.inspect.valid");
               Status := E.Exit_Success;
            end if;
         end;

         Containers.Close (Container);
         Files.Close (Source);
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
            --  Reported and remembered. The rest of the report is still
            --  worth printing -- a reader inspecting a file this build
            --  cannot run wants to see what is in it -- but a command that
            --  printed an error and left with a success told a script the
            --  file was fine.
            Pres.Report (Screen, Detail);
            Refused := Detail;
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
            --  The mixture, for a file that has one. Without these the
            --  report names a feed-forward width and nothing else, and for
            --  a model whose feed-forward block sits behind a router that
            --  width belongs to a block the model does not have: the file
            --  states it, the engine computes with the expert's, and a
            --  reader shown only the first is reading about another model.
            if Settings.Experts > 0 then
               Pres.Put_Field
                 (Screen, "cli.inspect.label.experts",
                  T.Image (Long_Long_Integer (Settings.Experts)),
                  Pres.Answer);
               Pres.Put_Field
                 (Screen, "cli.inspect.label.experts_used",
                  T.Image (Long_Long_Integer (Settings.Experts_Used)),
                  Pres.Answer);
               Pres.Put_Field
                 (Screen, "cli.inspect.label.expert_feed_forward",
                  T.Image (Long_Long_Integer (Settings.Expert_Feed)),
                  Pres.Answer);
            end if;

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

            --  What a reader of this report would otherwise have to work
            --  out from the architecture's name: which way it attends, and
            --  whether it can say what comes next at all. Both decide which
            --  command the file is for, and a caller who runs the wrong one
            --  learns it from a refusal rather than from here.
            Pres.Put_Field
              (Screen, "cli.inspect.label.attention",
               Screen.Message_Value
                 (if Settings.Causal
                  then "cli.inspect.value.one_way"
                  else "cli.inspect.value.both_ways"),
               Pres.Answer);
            Pres.Put_Field
              (Screen, "cli.inspect.label.output_head",
               Screen.Message_Value
                 (if Settings.Has_Head
                  then "cli.inspect.value.yes"
                  else "cli.inspect.value.no"),
               Pres.Answer);

            --  And the pooling the file states, for the file that states
            --  one. Absent and none are not the same answer, so a model
            --  that says nothing prints nothing here.
            if Settings.Pooling /= L.Pool_Unstated then
               Pres.Put_Field
                 (Screen, "cli.inspect.label.pooling",
                  (case Settings.Pooling is
                     when L.Pool_Mean => "mean",
                     when L.Pool_Last => "last",
                     when L.Pool_Cls  => "cls",
                     when others      => "none"),
                  Pres.Answer);
            end if;

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
            --  subset, or absent. Compiled and then rendered here, so the
            --  answer is evidence rather than a guess.
            --
            --  Compiling alone is not the evidence it looks like. A value
            --  this engine cannot compute is refused where it is read
            --  rather than where it is compiled -- which is what lets a
            --  template describing tool calling in a branch nobody enters
            --  be used for the conversations that do not enter it -- so a
            --  template that refuses on every conversation there is
            --  compiles without complaint. What is asked here is the
            --  question `run` asks: a turn, and a place for the model to
            --  answer.
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

                  if E.Is_Ok (Outcome) then
                     declare
                        Talk : Model_Runner.Conversation.History;
                        Room : String (1 .. 8192);
                        Used : Natural;
                     begin
                        Model_Runner.Conversation.Open (Talk, Status => Outcome);
                        if E.Is_Ok (Outcome) then
                           Model_Runner.Conversation.Append
                             (Talk, Model_Runner.Conversation.User_Role,
                              "Hello", Outcome);
                        end if;

                        if E.Is_Ok (Outcome) then
                           Model_Runner.Templates.Render
                             (Compiled, Talk,
                              Beginning_Token => "",
                              End_Token => "",
                              Add_Generation_Prompt => True,
                              Target => Room, Last => Used, Status => Outcome);
                        end if;

                        Model_Runner.Conversation.Close (Talk);
                     end;
                  end if;

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
               --  In the storage the caller named, so that what a session
               --  would take can be asked of each of them rather than only
               --  of the one this defaults to. A storage offered for what it
               --  saves should be able to say what it saves.
               L.Plan_For (Settings, Item.Context_Size, Plan, Detail2,
                           Cache => Item.Cache);
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
               --  One line per mode, because the modes differ by a factor
               --  of two and the flag offers both: a caller who wants the
               --  exact one was being shown the price of the other.
               declare
                  Repacked : Interfaces.Unsigned_64 := 0;
                  Exact    : Interfaces.Unsigned_64 := 0;
               begin
                  --  A matrix already in the target format is not copied,
                  --  so a file that is binary32 throughout needs nothing --
                  --  which is what this said 9888 bytes for on a 5024-byte
                  --  fixture before the skip existed.
                  for Index in 1 .. Containers.Tensor_Count (Container) loop
                     if Containers.Tensor_Rank (Container, Index) >= 2 then
                        if not G."=" (Containers.Tensor_Format
                                        (Container, Index),
                                      G.Type_BF16)
                        then
                           Repacked := Repacked
                             + Containers.Tensor_Elements (Container, Index)
                               * 2;
                        end if;

                        if not G."=" (Containers.Tensor_Format
                                        (Container, Index),
                                      G.Type_F32)
                        then
                           Exact := Exact
                             + Containers.Tensor_Elements (Container, Index)
                               * 4;
                        end if;
                     end if;
                  end loop;

                  --  What must fit, not what is held afterwards. The copy
                  --  is decoded from the file's own bytes, so both exist at
                  --  once while it is being written; the file's are released
                  --  when it is done. A caller deciding whether --repack
                  --  will run needs the moment when both are there.
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.repacked_exact",
                     T.Image
                       (Long_Long_Integer
                          (Exact
                           + Containers.Tensor_Data_Bytes (Container))),
                     Pres.Answer);
                  Pres.Put_Field
                    (Screen, "cli.inspect.label.repacked_bytes",
                     T.Image
                       (Long_Long_Integer
                          (Repacked
                           + Containers.Tensor_Data_Bytes (Container))),
                     Pres.Answer);
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
      Status :=
        (if E.Is_Error (Refused) then E.Exit_Status (Refused)
         else E.Exit_Success);
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
      Told      : aliased Pres.Logprob_Reporter (Screen'Unchecked_Access);

      --  A second, smaller model proposing tokens for the first to check,
      --  when one was named. Held here so it outlives the generation.
      Draft_Source    : Files.File_Source;
      Draft_Container : Containers.Container;
      Draft_Model     : aliased L.Model;
      Draft_Session   : aliased L.Session;
      Draft_Ready     : Boolean := False;

      --  Two models that do not number their tokens alike.
      function Draft_Mismatch (Draft, Wanted : Natural) return E.Error_Info is
         Result : E.Error_Info := E.Make (E.Arch_Unsupported_Feature);
      begin
         E.Add_Text (Result, "feature", "draft_vocabulary",
                     E.Param_Identifier);
         E.Add_Integer (Result, "actual", Long_Long_Integer (Draft));
         E.Add_Integer (Result, "expected", Long_Long_Integer (Wanted));
         return Result;
      end Draft_Mismatch;
      Clock     : aliased Model_Runner.Clocks.System_Clock;
      Seeds     : aliased Model_Runner.Entropy.Host_Source;
      Prompt    : Opt.Text_Access := null;

      --  The grammar the run must obey, when one was named. Held here so it
      --  outlives the generation that reads it.
      Rules       : aliased Model_Runner.Grammar.Compiled;
      Rules_Ready : Boolean := False;

      --  The tools offered to the model. Read before anything is generated,
      --  for the same reason a grammar is: an offer that will not parse is
      --  the caller's mistake and is worth finding before a model is asked
      --  to answer under it.
      Offered     : aliased Model_Runner.Tools.Definitions;
      Tools_Ready : Boolean := False;

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
         Model_Runner.Grammar.Close (Rules);
         Rules_Ready := False;
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

         --  Brain floats and an adapter are refused together rather than
         --  merged and rounded: what a merge adds is a small difference to
         --  every weight it touches, and eight mantissa bits is where a
         --  small difference goes.
         if not T.Is_Empty (Item.Adapter_Path)
           and then Item.Repack = L.To_BF16
         then
            Fail (E.Make (E.CLI_Conflicting_Prompt_Sources));
            return;
         end if;

         Load
           (Item, Screen, Source, Container, Prepared, True,
            Reporter'Unchecked_Access, Cancel'Unchecked_Access, Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         --  The adapter, merged into the weights before anything is
         --  generated. A merge is not a second set of weights carried
         --  alongside: what it costs is the load, and evaluation costs what
         --  it cost before.
         --  Every adapter, in the order it was given. A merge is an
         --  addition, so they stack; a scale of minus one subtracts, which
         --  is how one comes off again.
         for Which in 1 .. Item.Adapter_Count loop
            declare
               From   : Files.File_Source;
               Second : Containers.Container;

               --  The Nth scale belongs to the Nth adapter, and an adapter
               --  named without one is the adapter as it was trained.
               Scale : constant Model_Runner.Numerics.Real :=
                 (if Which <= Item.Scale_Count
                  then Item.Adapter_Scales (Which)
                  else 1.0);
            begin
               Files.Open
                 (From, T.To_String (Item.Adapters (Which)),
                  Status => Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               Containers.Reader.Parse (Second, From, Status => Condition);
               if E.Is_Error (Condition) then
                  Files.Close (From);
                  Fail (Condition);
                  return;
               end if;

               L.Merge_Adapter
                 (Prepared, Second, From, Scale, Condition);

               Containers.Close (Second);
               Files.Close (From);

               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;
            end;
         end loop;

         --  A model that cannot say what comes next cannot be run. Refused
         --  here rather than at the first evaluation, so that a caller who
         --  asked the wrong command of the right model is told before a
         --  session, a cache and a worker pool are built for a generation
         --  that is not going to happen. `embed` is what such a model is
         --  for, and saying so is more use than the code alone.
         if not L.Config (Prepared).Has_Head then
            declare
               Refusal : E.Error_Info := E.Make (E.Arch_No_Output_Head);
            begin
               E.Add_Text
                 (Refusal, "architecture",
                  L.Architecture_Name (L.Config (Prepared).Kind),
                  E.Param_Identifier);
               Fail (Refusal);
               return;
            end;
         end if;

         --  The arithmetic, told to the backend before the session opens
         --  and therefore before anything is dispatched. The backend states
         --  that it must be told once and not part way through a run, which
         --  is why this is here and not a parameter of every product.
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (L."=" (Item.Arithmetic, L.Integer_Activations));

         L.Open
           (Session, Prepared, Item.Context_Size,
            Session_Bounds => Session_Bounds (Item),
            Workers => Team, Cache => Item.Cache, Status => Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         --  A draft model, when one was named: a second, smaller model that
         --  proposes what it would say next so that this one can check
         --  several tokens in a single pass over its weights.
         --
         --  Loaded exactly as the model was, with the same limits and the
         --  same refusals. What is checked here is the one thing that makes
         --  two models comparable at all: a proposal is a token identifier,
         --  so two models that number their tokens differently would be
         --  agreeing about numbers rather than about text.
         if not T.Is_Empty (Item.Draft_Path) then
            Load (Item, Screen, Draft_Source, Draft_Container, Draft_Model,
                  True, null, Cancel'Unchecked_Access, Condition,
                  Instead => T.To_String (Item.Draft_Path));
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;

            if L.Config (Draft_Model).Vocabulary
               /= L.Config (Prepared).Vocabulary
            then
               Fail (Draft_Mismatch (L.Config (Draft_Model).Vocabulary,
                                     L.Config (Prepared).Vocabulary));
               return;
            end if;

            --  The same worker pool. A draft that runs serial while the
              --  model it drafts for runs across seven workers is a draft
              --  paying seven times what it should for every proposal, and
              --  the run measures as though drafting were hopeless when
              --  what was hopeless was the arrangement. The two never
              --  evaluate at once -- a round proposes, then checks -- so
              --  one pool serves both.
            L.Open
              (Draft_Session, Draft_Model, Item.Context_Size,
               Session_Bounds => Session_Bounds (Item),
               Workers => Team, Cache => Item.Cache, Status => Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;

            Draft_Ready := True;
         end if;

         --  A schema is a grammar written in another notation, so it
         --  becomes one here and everything below treats it as one. The
         --  parser has already refused a caller who named both.
         if Item.Schema_Text /= null
           or else not T.Is_Empty (Item.Schema_Path)
         then
            declare
               Text : Opt.Text_Access := null;

               Written : String (1 .. Model_Runner.Schema.Max_Grammar_Bytes);
               Last    : Natural;
            begin
               if Item.Schema_Text /= null then
                  Text := new String'(Item.Schema_Text.all);
               else
                  Read_File
                    (T.To_String (Item.Schema_Path),
                     Model_Runner.Schema.Max_Schema_Bytes, Text, Condition);
                  if E.Is_Error (Condition) then
                     Fail (Condition);
                     return;
                  end if;
               end if;

               Model_Runner.Schema.To_Grammar
                 (Text.all, Written, Last, Condition);
               Free_Text (Text);

               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               Model_Runner.Grammar.Compile
                 (Rules, Written (1 .. Last), Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               Rules_Ready := True;
            end;
         end if;

         --  The grammar, before anything is generated. A grammar that will
         --  not compile is the caller's mistake and is worth finding before
         --  a model is asked to produce anything under it.
         if Item.Grammar_Text /= null
           or else not T.Is_Empty (Item.Grammar_Path)
         then
            declare
               Text : Opt.Text_Access := null;
            begin
               if Item.Grammar_Text /= null then
                  Text := new String'(Item.Grammar_Text.all);
               else
                  Read_File
                    (T.To_String (Item.Grammar_Path),
                     Model_Runner.Limits.Default_Session_Limits
                       .Max_Prompt_Bytes,
                     Text, Condition);
                  if E.Is_Error (Condition) then
                     Fail (Condition);
                     return;
                  end if;
               end if;

               Model_Runner.Grammar.Compile (Rules, Text.all, Condition);
               Free_Text (Text);

               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               Rules_Ready := True;
            end;
         end if;

         --  The tools, and the one question worth asking about them: does
         --  this model's template have anywhere to put them. A model told
         --  about no tools answers as though there were none, which looks
         --  from the outside like a model that chose not to call one.
         if Item.Tools_Text /= null
           or else not T.Is_Empty (Item.Tools_Path)
         then
            declare
               Text : Opt.Text_Access := null;
            begin
               if Item.Tools_Text /= null then
                  Text := new String'(Item.Tools_Text.all);
               else
                  Read_File
                    (T.To_String (Item.Tools_Path),
                     Model_Runner.Tools.Max_Definition_Bytes, Text,
                     Condition);
                  if E.Is_Error (Condition) then
                     Fail (Condition);
                     return;
                  end if;
               end if;

               Model_Runner.Tools.Read (Offered, Text.all, Condition);
               Free_Text (Text);

               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               if not L.Template_Ready (Prepared) then
                  Fail (L.Template_Condition (Prepared));
                  return;
               end if;

               if not Model_Runner.Templates.Reads_Tools
                        (L.Template (Prepared).all)
               then
                  Condition := E.Make (E.Tools_Not_In_Template);
                  Fail (Condition);
                  return;
               end if;

               Tools_Ready := True;
            end;
         end if;

         --  A saved session, before the prompt is looked at. What it fills
         --  is the cache and the history, which is exactly what the prompt
         --  would otherwise have to be read to produce; the generation then
         --  keeps whatever of it the prompt agrees with and re-reads only
         --  the rest.
         --
         --  A restore that fails ends the run. It was asked for, and going
         --  on without it would silently do the slow thing after being told
         --  to do the fast one.
         if not T.Is_Empty (Item.Load_Session) then
            declare
               Kept : Files.File_Source;
            begin
               Files.Open
                 (Kept, T.To_String (Item.Load_Session), Status => Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               declare
                  Length : constant Model_Runner.Bytes.Byte_Count :=
                    Files.Size (Kept);
                  Room   : Model_Runner.Bytes.Byte_Array_Access;
               begin
                  Model_Runner.Bytes.Allocate (Length, Room);
                  if Room = null then
                     Files.Close (Kept);
                     Fail (E.Make (E.Memory_Allocation_Failed));
                     return;
                  end if;

                  Files.Read (Kept, 0, Room.all, Condition);
                  Files.Close (Kept);

                  if E.Is_Ok (Condition) then
                     L.Adopt (Session, Prepared, Room.all, Condition);
                  end if;

                  Model_Runner.Bytes.Free (Room);

                  if E.Is_Error (Condition) then
                     Fail (Condition);
                     return;
                  end if;
               end;
            end;
         end if;

         --  Interactive mode owns its own loop; it needs the same prepared model
         --  and session, so it is entered here rather than earlier.
         if Item.Prompt_Kind = Opt.Prompt_Interactive then
            Model_Runner.CLI.Interactive.Run
              (Item, Screen, Prepared, Session,
               (if Rules_Ready then Rules'Unchecked_Access else null),
               (if Tools_Ready then Offered'Unchecked_Access else null),
               Status);
            Cleanup;
            return;
         end if;

         --  One sequence per prompt, from the one loaded model. Between
         --  them the session goes back to nothing: each prompt is its own
         --  conversation, and a second prompt continuing the first would be
         --  a different program.
         for Which in 1 .. Natural'Max (1, Item.Prompt_Count) loop

            if Which > 1 then
               L.Reset (Session);

               --  Which prompt this is, on standard error, so that a reader of
               --  the generated text can tell where one answer ends. Nothing
               --  goes to standard output but what the model produced.
               Pres.Put_Note
                 (Screen, "cli.note.next_prompt",
                  [Loc.Named ("index", T.Image (Long_Long_Integer (Which))),
                   Loc.Named
                     ("total",
                      T.Image (Long_Long_Integer (Item.Prompt_Count)))]);
            end if;

            --  Resolve the prompt.
            case Item.Prompt_Kind is
               when Opt.Prompt_Inline =>
                  Prompt := new String'(Item.Prompts (Which).all);

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

                     --  And the turns that follow it, in the order they
                     --  were given: this is how one run closes the loop
                     --  another opened. A reply is taken apart into what
                     --  the model said and what it asked for, so a caller
                     --  hands back the reply it was printed and this reads
                     --  the calls out of it -- rather than the caller
                     --  taking the reply apart and this trusting the
                     --  pieces.
                     for Turn in 1 .. Item.Turn_Count loop
                        declare
                           Spoken  : Opt.Text_Access := null;
                           Reading : E.Error_Info;
                        begin
                           if Item.Turn_Texts (Turn) /= null then
                              Spoken :=
                                new String'(Item.Turn_Texts (Turn).all);
                           else
                              Read_File
                                (T.To_String (Item.Turn_Paths (Turn)),
                                 Model_Runner.Limits.Default_Session_Limits
                                   .Max_Prompt_Bytes,
                                 Spoken, Condition);
                           end if;

                           if E.Is_Ok (Condition) then
                              if Opt."=" (Item.Turn_Kinds (Turn),
                                          Opt.Turn_Tool)
                              then
                                 Conv.Append
                                   (Messages, Conv.Tool_Role, Spoken.all,
                                    Condition);
                              elsif Tools_Ready then
                                 Conv.Append_Reply
                                   (Messages, Spoken.all, Condition, Reading);
                                 if E.Is_Error (Reading) then
                                    Pres.Report (Screen, Reading);
                                 end if;
                              else
                                 Conv.Append
                                   (Messages, Conv.Assistant_Role, Spoken.all,
                                    Condition);
                              end if;
                           end if;

                           Free_Text (Spoken);

                           if E.Is_Error (Condition) then
                              Free_Text (Buffer);
                              Conv.Close (Messages);
                              Fail (Condition);
                              return;
                           end if;
                        end;
                     end loop;

                     Model_Runner.Templates.Render
                       (L.Template (Prepared).all, Messages,
                        Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
                        Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
                        True, Buffer.all, Last, Condition,
                        Thinking => Item.Thinking,
                        Tools =>
                          (if Tools_Ready
                           then Offered'Unchecked_Access else null));
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
                  for Index in 1 .. Item.Bias_Count loop
                     Request.Bias_Tokens (Index) :=
                       Model_Runner.Tokenizer.Token_Id
                         (Item.Bias_Tokens (Index));
                     Request.Bias_Amounts (Index) := Item.Bias_Amounts (Index);
                  end loop;

                  Request.Bias_Count := Item.Bias_Count;
                  Request.Logprobs := Item.Logprobs;
                  Request.Context_Shift := Item.Context_Shift;
                  Request.Context_Keep := Item.Context_Keep;
                  Request.Draft_Tokens :=
                    (if Draft_Ready then Item.Draft_Tokens else 0);

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
                  --  What was generated is kept only where something here
                  --  reads it back: the calls a reply asks for are read out
                  --  of the reply, and a run that offered no tools has
                  --  nothing to read.
                  Request.Retain_Text := Tools_Ready;

                  --  Who puts the beginning token in front.
                  --
                  --  With --raw there is no template, so nothing else can: the
                  --  request asks for one and the vocabulary decides whether it
                  --  wants one, which Generation checks.
                  --
                  --  With a template the template does it. It is handed the
                  --  beginning token's own text and writes it where the model
                  --  expects it, which for some models is not the front -- and
                  --  the tokenizer turns that spelling back into the one token
                  --  it stands for. Asking here as well would put two in front
                  --  of a model that wants one, and a marker that model did not
                  --  ask for moves a logit by nearly two.
                  --
                  --  What follows from that: a model whose template writes no
                  --  beginning token gets none, whatever its add_bos_token
                  --  says. That is the template's answer and this defers to it,
                  --  because the template is the part that knows where in the
                  --  rendered text the token belongs.
                  Request.Add_Beginning := Item.Raw;

                  --  Keep what the restored cache and the prompt agree on. The
                  --  session already holds a conversation; this is what makes
                  --  restoring it worth anything, and where they diverge the
                  --  engine resets and reads the prompt as it would have.
                  Request.Reuse_Committed_Prefix :=
                    not T.Is_Empty (Item.Load_Session);

                  --  What the last prompt retained goes before this one
                  --  begins: Generate starts from an empty result and would
                  --  otherwise leave the previous run's text behind, once
                  --  per prompt, for as many prompts as were given.
                  Gen.Release (Outcome);
                  Gen.Generate
                    (Source   => Prepared,
                     Session  => Session,
                     Prompt   => Rendered.all,
                     Item     => Request,
                     Stop_Set => Stop_Set,
                     Rules    =>
                       (if Rules_Ready then Rules'Unchecked_Access else null),
                     Sink     => Sink'Unchecked_Access,
                     Observer => Reporter'Unchecked_Access,
                     Time     => Clock'Unchecked_Access,
                     Seeds    => Seeds'Unchecked_Access,
                     Cancel   => Cancel'Unchecked_Access,
                     Draft    =>
                       (if Draft_Ready then Draft_Model'Unchecked_Access
                        else null),
                     Draft_Session =>
                       (if Draft_Ready then Draft_Session'Unchecked_Access
                        else null),
                     Reporter =>
                       (if Item.Logprobs > 0
                        then Told'Unchecked_Access
                        else null),
                     Outcome  => Outcome);
               end;

               Release_Rendered;
            end;

            if Outcome.Reason = Gen.Runtime_Error then
               Fail (Outcome.Error);
               return;
            end if;

            --  A run the reader interrupted did not succeed, and said so with
            --  a zero. Cancelled is not Runtime_Error, so it fell through to
            --  Exit_Success and a script around this program was told the
            --  generation had finished normally -- while `help` promises "7
            --  cancelled" and the error table maps MR-GEN-0006 to seven.
            --
            --  Reported through the same path as any other refusal, so the
            --  status is the table's answer rather than a second one written
            --  here. Cancellation during loading already came out this way;
            --  only cancellation during generation did not.
            if Outcome.Reason = Gen.Cancelled then
               Fail (E.Make (E.Generation_Cancelled));
               return;
            end if;

            --  What the reply asked for, read out of it and shown. The
            --  reply itself has already gone to standard output; this goes
            --  to standard error with the rest of the diagnostics, so a
            --  redirected run still holds only what the model wrote -- and
            --  the caller who has to hand an answer back is told what was
            --  asked rather than left to find it in the text.
            if Tools_Ready then
               declare
                  Asked   : Model_Runner.Tools.Calls;
                  Reading : E.Error_Info;
               begin
                  Model_Runner.Tools.Read_Calls
                    (Asked, Gen.Generated_Text (Outcome), Reading);
                  if E.Is_Error (Reading) then
                     Pres.Report (Screen, Reading);
                  end if;

                  for Index in 1 .. Model_Runner.Tools.Count (Asked) loop
                     declare
                        Named : constant String :=
                          Model_Runner.Tools.Called (Asked, Index);
                     begin
                        Pres.Put_Note
                          (Screen, "cli.run.tool_call",
                           [Loc.Named ("name", Named),
                            Loc.Named
                              ("arguments",
                               Model_Runner.Tools.Arguments (Asked, Index))]);

                        if not Model_Runner.Tools.Offers (Offered, Named) then
                           Pres.Put_Note
                             (Screen, "cli.run.tool_unknown",
                              [Loc.Named ("name", Named)]);
                        end if;
                     end;
                  end loop;
                  Model_Runner.Tools.Close (Asked);
               end;
            end if;

            --  And the context out, when it was asked for. After the run
            --  rather than before it, because what is worth saving is the
            --  prompt and the reply together: the next run continues from
            --  where this one stopped.
            if not T.Is_Empty (Item.Save_Session) then
               declare
                  Room : Model_Runner.Bytes.Byte_Array_Access;
               begin
                  L.Snapshot (Session, Prepared, Room, Condition);
                  if E.Is_Error (Condition) then
                     Fail (Condition);
                     return;
                  end if;

                  Write_File
                    (T.To_String (Item.Save_Session), Room.all, Condition);
                  Model_Runner.Bytes.Free (Room);

                  if E.Is_Error (Condition) then
                     Fail (Condition);
                     return;
                  end if;
               end;
            end if;

            --  Statistics go to standard error, so a redirected standard output
            --  still contains only generated text.
            if Item.Show_Stats
              or else (not Item.Stats_Set and then Item.Level = Opt.Verbose)
            then
               --  With what the device did, when a device did it.
               if Model_Runner.Backend."=" (Item.Backend,
                                             Model_Runner.Backend.Backend_Device)
               then
                  Pres.Put_Statistics
                    (Screen, Outcome,
                     Device         => Model_Runner.Backend.Device.Name,
                     Resident       => Model_Runner.Backend.Device.Resident,
                     Imported       => Model_Runner.Backend.Device.Imported,
                     Resident_Bytes =>
                       Model_Runner.Backend.Device.Resident_Bytes,
                     Given_Back     => Model_Runner.Backend.Device.Given_Back,
                     Cached_Bytes   =>
                       Model_Runner.Backend.Device.Cached_Bytes);
               else
                  Pres.Put_Statistics (Screen, Outcome);
               end if;
            end if;

            Free_Text (Prompt);
         end loop;

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
      --  Options that cannot do anything here say so rather than being
      --  accepted and forgotten.
      if Item.Draft_Tokens_Set and then T.Is_Empty (Item.Draft_Path) then
         Pres.Put_Note (Screen, "cli.note.draft_tokens_unused");
      end if;

      if Item.Device_Memory_Set
        and then Model_Runner.Backend."/=" (Item.Backend,
                                            Model_Runner.Backend.Backend_Device)
      then
         Pres.Put_Note (Screen, "cli.note.device_memory_unused");
      end if;

      --  Said for the same reason and in the same place: an option that
      --  changes nothing where it was given should say so rather than look
      --  as though it worked.
      if Item.Device_Patience_Set
        and then Model_Runner.Backend."/=" (Item.Backend,
                                            Model_Runner.Backend.Backend_Device)
      then
         Pres.Put_Note (Screen, "cli.note.device_patience_unused");
      end if;

      if Item.Device_Index_Set
        and then Model_Runner.Backend."/=" (Item.Backend,
                                            Model_Runner.Backend.Backend_Device)
      then
         Pres.Put_Note (Screen, "cli.note.device_unused");
      end if;

      case Item.Backend is
      when Model_Runner.Backend.Backend_Reference =>
         --  No pool: this backend runs on the calling task and says so.
         Run_With (null);

      when Model_Runner.Backend.Backend_Device =>
         --  A device instead of a pool. Opened here rather than at the first
         --  product so that a machine without one is told before a model is
         --  loaded: being refused after a minute of loading is being refused
         --  a minute late.
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open
              (Ready, Item.Device_Memory, Item.Device_Share,
               Patience => Item.Device_Patience,
               Which => Item.Device_Index);

            --  What the host offered, said once where a device was
            --  actually opened. The engine uses one queue; whether the
            --  family has more is a fact worth printing rather than a
            --  number only a test ever reads.
            if Ready then
               Screen.Put_Message
                 ("cli.note.device_queues",
                  [Loc.Named
                     ("value",
                      Model_Runner.Text.Image
                        (Long_Long_Integer
                           (Model_Runner.Backend.Device.Queues)))]);
            end if;

            if not Ready then
               --  A condition of its own rather than a borrowed one. This
               --  used to report a missing capability with no capability
               --  named, and a message whose text names a parameter that is
               --  not there does not render at all: what a machine with no
               --  device got was the message key in angle brackets, which is
               --  the diagnostic for a diagnostic that failed.
               Fail (E.Make (E.Backend_No_Device));
               return;
            end if;

            --  A pool for the host loops a device run still has, made and
            --  waited for exactly as the processor's is below.
            if Team_Size <= 1 then
               Run_With (null);
            else
               declare
                  Team : aliased Workers_CPU.Pool
                    (Workers_CPU.Worker_Count (Team_Size));
               begin
                  Run_With (Team'Unchecked_Access);
                  Workers_CPU.Close (Team);
               exception
                  when others =>
                     Workers_CPU.Close (Team);
                     raise;
               end;
            end if;

            Model_Runner.Backend.Device.Close;
         end;

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

   ---------------
   -- Do_Embed --
   ---------------

   --  Reduce a text to one vector.
   --
   --  What a model has made of everything it has read lives in the hidden
   --  state, and the output projection throws most of it away: two texts
   --  that mean the same thing leave similar states and quite different
   --  logits, because the logits say only how much each token is favoured
   --  next. This prints the state, pooled over the text's positions.
   --
   --  The prompt is read as written. No chat template is applied and none
   --  would be right: a template turns a text into a turn of a conversation,
   --  and an embedding is of the text.
   --
   --  Evaluated a token at a time rather than as a batch, because the state
   --  of every position is wanted and only the single-token path leaves one
   --  behind for each. For a prompt this is the same arithmetic either way.
   procedure Do_Embed
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural)
   is
      Source    : Files.File_Source;
      Container : Containers.Container;
      Prepared  : L.Model;
      Session   : L.Session;
      Prompt    : Opt.Text_Access := null;
      Condition : E.Error_Info;
      Ignored   : E.Error_Info;

      procedure Cleanup is
      begin
         L.Close (Session);
         L.Close (Prepared, Ignored);
         Containers.Close (Container);
         Files.Close (Source);
         Free_Text (Prompt);
      end Cleanup;

      procedure Fail (Reason : E.Error_Info) is
      begin
         Pres.Report (Screen, Reason);
         Status := E.Exit_Status (Reason);
         Cleanup;
      end Fail;

      procedure Embed_With (Team : Workers_CPU.Pool_Reference) is
      begin
         Status := E.Exit_Success;

         Load (Item, Screen, Source, Container, Prepared, True, null, null,
               Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         --  The arithmetic, told to the backend before the session opens
         --  and therefore before anything is dispatched. The backend states
         --  that it must be told once and not part way through a run, which
         --  is why this is here and not a parameter of every product.
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (L."=" (Item.Arithmetic, L.Integer_Activations));

         L.Open
           (Session, Prepared, Item.Context_Size,
            Session_Bounds => Session_Bounds (Item),
            Workers => Team, Cache => Item.Cache, Status => Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

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

         declare
            Settings : constant L.Configuration := L.Config (Prepared);
            Width    : constant N.Element_Count :=
              N.Element_Count (Settings.Embedding);
            Words    : constant access constant Vocab.Vocabulary :=
              L.Vocabulary (Prepared);

            Tokens : Vocab.Token_Array
              (1 .. Model_Runner.Limits.Default_Session_Limits.Max_Batch);
            Count  : Natural;

            --  Empty where the model has no projection to a distribution,
            --  which is how a caller says they are not asking for one. A
            --  model that has one still produces the last position's, as it
            --  did: nothing here reads it, and refusing to compute it would
            --  be a second path through the evaluator for no gain.
            Logits : N.Real_Array
              (0 .. (if Settings.Has_Head
                     then N.Element_Count (Settings.Vocabulary) - 1
                     else -1));
            Pooled : N.Real_Array (0 .. Width - 1) := [others => 0.0];

            --  Which pooling this run uses. The caller's where they named
            --  one; otherwise the model's own, for the architecture that
            --  states it; otherwise the mean, as before.
            Pooling : constant Opt.Pooling_Kind :=
              (if Item.Pooling_Named then Item.Pooling
               else (case Settings.Pooling is
                       when L.Pool_Cls  => Opt.Pool_Cls,
                       when L.Pool_Last => Opt.Pool_Last,
                       when others      => Opt.Pool_Mean));
         begin
            --  The end marker where the model is one that reads whole texts
            --  and its file asks for one. Bert is trained with a marker at
            --  each end and its states are what they are because of them;
            --  a decoder's embedded text is not a finished utterance and
            --  takes none, which is what this did for every model before.
            Vocab.Encode
              (Words.all, Prompt.all, Vocab.Adds_Beginning (Words.all),
               not Settings.Causal and then Vocab.Adds_End (Words.all),
               Tokens, Count, Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;

            if Count = 0 then
               Fail (E.Make (E.CLI_No_Prompt_Available));
               return;
            end if;

            --  In batches, as a prompt is read, because that is what the
            --  batched path is for: measured on this machine a matrix
            --  product over thirty-two vectors moves 1.87 times the
            --  elements a second that one at a time does, and a text to be
            --  embedded is exactly the shape that likes.
            --
            --  Pooling over the positions needs every position's state, and
            --  only the batched path has them all in hand at once; asking
            --  for them is what the States buffer is.
            declare
               --  How many positions go through the weights at once. A
               --  causal model may take the text in any batches it likes
               --  and get the same answer; one that attends both ways has
               --  to see the whole of it at once, so the batch is the text
               --  and --batch-size has nothing to say about it.
               Step : constant N.Element_Count :=
                 (if not Settings.Causal
                  then N.Element_Count (Count)
                  else N.Element_Count
                         (Natural'Min
                            (Natural'Max (1, Item.Batch_Size),
                             Model_Runner.Limits.Default_Session_Limits
                               .Max_Batch)));

               Room : Model_Runner.Tensors.Real_Array_Access := null;
               From : Positive := 1;
            begin
               Room := new N.Real_Array (0 .. Step * Width - 1);

               while From <= Count loop
                  declare
                     Upto : constant Positive :=
                       Positive'Min (From + Natural (Step) - 1, Count);
                     Taken : constant N.Element_Count :=
                       N.Element_Count (Upto - From + 1);
                  begin
                     L.Evaluate_Batch
                       (Session, Prepared, Tokens (From .. Upto), Logits,
                        States => Room, Status => Condition);
                     if E.Is_Error (Condition) then
                        Free_Reals (Room);
                        Fail (Condition);
                        return;
                     end if;

                     case Pooling is
                        when Opt.Pool_Mean =>
                           for Which in 0 .. Taken - 1 loop
                              for Element in Pooled'Range loop
                                 Pooled (Element) := Pooled (Element)
                                   + Room.all (Which * Width + Element);
                              end loop;
                           end loop;

                        when Opt.Pool_Last =>
                           if Upto = Count then
                              for Element in Pooled'Range loop
                                 Pooled (Element) :=
                                   Room.all ((Taken - 1) * Width + Element);
                              end loop;
                           end if;

                        --  The first position of the text, which is the
                        --  first position of the first batch and of no
                        --  other. A model pooled this way was trained with
                        --  a marker there and with that marker's state
                        --  standing for the whole.
                        when Opt.Pool_Cls =>
                           if From = 1 then
                              for Element in Pooled'Range loop
                                 Pooled (Element) := Room.all (Element);
                              end loop;
                           end if;
                     end case;

                     From := Upto + 1;
                  end;
               end loop;

               Free_Reals (Room);
            end;

            if Pooling = Opt.Pool_Mean then
               for Element in Pooled'Range loop
                  Pooled (Element) := Pooled (Element) / N.Real (Count);
               end loop;
            end if;

            --  To unit length, unless the caller asked for the vector as it
            --  is. A vector of length zero stays as it is: there is no
            --  direction to scale it to, and dividing would produce
            --  not-a-number where the honest answer is what was computed.
            if Item.Normalize then
               declare
                  Total : N.Wide_Real := 0.0;
               begin
                  for Element of Pooled loop
                     Total := Total + N.Wide_Real (Element)
                       * N.Wide_Real (Element);
                  end loop;

                  if Total > 0.0 then
                     declare
                        Scale : constant N.Real :=
                          N.Real (1.0 / N.Sqrt (Total));
                     begin
                        for Element of Pooled loop
                           Element := Element * Scale;
                        end loop;
                     end;
                  end if;
               end;
            end if;

            --  One component a line, so that the usual tools can read it.
            --  Through the plain line writer rather than the generated-text
            --  path, and that is safe here for the reason that path exists:
            --  what it guards against is a model's own bytes reaching a
            --  terminal, and these are digits, a sign and a point produced
            --  by this program from a number.
            for Element of Pooled loop
               Pres.Put_Line (Screen, T.Image (Long_Float (Element), 6));
            end loop;
         end;

         Cleanup;
      end Embed_With;
   begin
      --  Which backend reduces this text, which is the same choice the run
      --  command makes and was not made here at all: a device was selected,
      --  prepared against, and then never opened, so every embedding on a
      --  device was refused by the first product with a state error. One
      --  copy of a choice is one place to make it; two copies is one place
      --  to forget it, which is what happened.
      if Item.Device_Memory_Set
        and then Model_Runner.Backend."/=" (Item.Backend,
                                            Model_Runner.Backend.Backend_Device)
      then
         Pres.Put_Note (Screen, "cli.note.device_memory_unused");
      end if;

      case Item.Backend is
      when Model_Runner.Backend.Backend_Device =>
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open
              (Ready, Item.Device_Memory, Item.Device_Share,
               Patience => Item.Device_Patience,
               Which => Item.Device_Index);

            if not Ready then
               Fail (E.Make (E.Backend_No_Device));
               return;
            end if;

            Embed_With (null);
            Model_Runner.Backend.Device.Close;
         end;

      when Model_Runner.Backend.Backend_Reference =>
         Embed_With (null);

      when Model_Runner.Backend.Backend_CPU =>
         declare
            Wanted : constant Positive := Selected_Workers (Item);
         begin
            if Wanted = 1 then
               Embed_With (null);
            else
               declare
                  --  Declared here so that leaving the block waits for the
                  --  workers, as the run command's pool is.
                  Team : aliased Workers_CPU.Pool
                    (Workers_CPU.Worker_Count (Wanted));
               begin
                  Embed_With (Team'Unchecked_Access);
                  Workers_CPU.Close (Team);
               exception
                  when others =>
                     Workers_CPU.Close (Team);
                     raise;
               end;
            end if;
         end;
      end case;
   end Do_Embed;

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

         when Opt.Command_Embed =>
            Do_Embed (Item, Screen, Status);

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
