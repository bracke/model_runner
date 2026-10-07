with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces;
with Model_Runner.Backend.Device;
with Model_Runner.Backend.Reference;
with Model_Runner.Quantization.Interleave;
with Model_Runner.Quantization;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Platform;
with Model_Runner.UTF8;

package body Model_Runner.CLI.Execute.Support is

   use type Ada.Directories.File_Kind;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.CLI.Options.Text_Access;
   use type L.Repack_Mode;

   --  A string as a JSON string body: the characters JSON must not carry raw
   --  -- the quote, the backslash, the control characters -- become escapes,
   --  so any tool argument or result drops into a trace as valid JSON.
   function JSON_Escape (S : String) return String is
      Out_S : US.Unbounded_String;

      procedure Hex4 (C : Character) is
         Nibble : constant String := "0123456789abcdef";
         Code   : constant Natural := Character'Pos (C);
      begin
         US.Append (Out_S, "\u00");
         US.Append (Out_S, Nibble (Nibble'First + Code / 16));
         US.Append (Out_S, Nibble (Nibble'First + Code mod 16));
      end Hex4;
   begin
      for C of S loop
         case C is
            when '"'      => US.Append (Out_S, "\""");
            when '\'      => US.Append (Out_S, "\\");
            when ASCII.LF => US.Append (Out_S, "\n");
            when ASCII.CR => US.Append (Out_S, "\r");
            when ASCII.HT => US.Append (Out_S, "\t");
            when Character'Val (0) .. Character'Val (8)
               | Character'Val (11) .. Character'Val (12)
               | Character'Val (14) .. Character'Val (31) => Hex4 (C);
            when others   => US.Append (Out_S, C);
         end case;
      end loop;
      return US.To_String (Out_S);
   end JSON_Escape;

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

            --  A line ended the Windows way keeps its carriage return on a
            --  host whose text files end lines with a line feed alone, and
            --  loses it on Windows, so the one file was a different prompt
            --  on each. Dropped on every host: a prompt is its lines.
            if Last < Stop
              and then Last > Filled
              and then Result.all (Last) = ASCII.CR
            then
               Last := Last - 1;
            end if;

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

         --  The weights a device reads where they lie are one arena, and
         --  the default cap on a single allocation is sixteen gigabytes:
         --  a 21 GB mixture asked for with --device-memory 0 was refused
         --  for the arena's size after the caller had named a limit above
         --  it. A limit the caller wrote is the caller's word for what
         --  the host can take, so the cap on one allocation follows it up
         --  and never down.
         if Item.Memory_Limit > Result.Max_Allocation_Bytes then
            Result.Max_Allocation_Bytes := Item.Memory_Limit;
         end if;
      end if;
      return Result;
   end Model_Bounds;

   --  Limits applied to a session, from the same command line.
   --
   --  --memory-limit bounded the model and nothing else. A session holds the
   --  KV cache, which grows with the context and is the largest thing it
   --  allocates, so a caller asking for a hundred megabytes could be given a
   --  model inside it and then a session of any size at all.
   --
   --  Where the caller names no limit, half of what the host has. A
   --  model's declared context is a training fact and not a sizing one:
   --  Qwen3-30B-A3B declares 40,960 tokens, which is 8.5 GB of cache, held
   --  on the host and again on a device, on a machine with 30 GB -- and
   --  the file's own pages and the weights on the device beside it. Twice
   --  that was the desktop killed for want of memory before anything was
   --  generated. Refused with both numbers, the answer is --context-size
   --  or --memory-limit, which is a decision rather than an accident.
   function Session_Bounds
     (Item : Opt.Command) return Model_Runner.Limits.Session_Limits
   is
      Result : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
   begin
      if Item.Memory_Limit /= 0 then
         Result.Max_Session_Bytes := Item.Memory_Limit;
      elsif Model_Runner.Platform.Physical_Memory > 0 then
         Result.Max_Session_Bytes := Model_Runner.Platform.Physical_Memory / 2;
      end if;
      return Result;
   end Session_Bounds;

   --  Whether this session's cache is dealt in pages. On for the device
   --  where the caller said nothing: a paged cache attends whole on the
   --  device, bit for bit and at a block's speed, and pays only for the
   --  positions it fills rather than a block its whole width -- so a
   --  partly filled context costs a fraction of the memory the target
   --  hardware is short of. Off on the processor, whose cache is host
   --  memory with no pages to deal. --paged and --no-paged override.
   function Session_Paging (Item : Opt.Command) return Boolean
   is (if Item.Paged_Named then Item.Paged
       else Model_Runner.Backend."="
              (Item.Backend, Model_Runner.Backend.Backend_Device));

   --  What the device will not do with this session, said as it opens
   --  rather than left to be inferred from a run that was slower than it
   --  looked: three things keep a session's attention off the device --
   --  heads wider than the room a kernel keeps, a packed cache whose
   --  rows that kernel does not read, and a context past what one
   --  storage buffer holds -- and the products stay there through all of
   --  them, so every other number the run reports reads as it does when
   --  the whole model runs on the device.
   --
   --  Said for every session a command opens for the model it was given:
   --  a run's and an embedding's alike, the answer being the same
   --  question about the same device. Nothing is said for a session that
   --  opened on another backend, or for one the device takes whole.
   --
   --  @param Screen Where notes go.
   --  @param Session Session just opened.
   procedure Say_Device_Room
     (Screen  : in out Pres.Console;
      Session : L.Session)
   is
      Why         : L.Device_Limit;
      Asked, Kept : Interfaces.Unsigned_64;

      function Shown (Value : Interfaces.Unsigned_64) return String
      is (Model_Runner.Text.Image (Long_Long_Integer (Value)));
   begin
      L.Device_Room (Session, Why, Asked, Kept);

      case Why is
         when L.Device_Takes_All =>
            null;

         when L.Heads_Past_Room =>
            Screen.Put_Message
              ("cli.note.heads_off_device",
               [Loc.Named ("value", Shown (Asked)),
                Loc.Named ("total", Shown (Kept))]);

         when L.Packed_Heads_Unread =>
            Screen.Put_Message
              ("cli.note.packed_heads_off_device",
               [Loc.Named ("value", Shown (Asked)),
                Loc.Named ("total", Shown (Kept))]);

         when L.Context_Past_Bound =>
            Screen.Put_Message
              ("cli.note.context_off_device",
               [Loc.Named ("value", Shown (Asked)),
                Loc.Named ("total", Shown (Kept))]);

         when L.Blocks_All_Held =>
            Screen.Put_Message
              ("cli.note.blocks_all_held",
               [Loc.Named ("value", Shown (Asked)),
                Loc.Named ("total", Shown (Kept))]);
      end case;
   end Say_Device_Room;

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
   --  The arithmetic a run computes with: what --arith named, or, where
   --  nothing was named, the default -- int8 -- for every family but the
   --  one measured to want another. Gemma 2 with every product rounded
   --  answers three tool tasks of ten where it answers seven unrounded and
   --  eight with its attention left whole, so it takes the mixed mode
   --  unasked; a caller who names an arithmetic gets the one named.
   function Chosen_Arithmetic
     (Item : Opt.Command; Prepared : L.Model) return L.Arithmetic_Mode
   is (if not Item.Arithmetic_Set
         and then L."=" (Item.Arithmetic, L.Integer_Activations)
         and then L."=" (L.Config (Prepared).Kind, L.Gemma2)
       then L.Mixed_Activations
       else Item.Arithmetic);

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

   --  What the command asks of the rotation, over what the file states.
   --
   --  Empty and zero are unasked, which is what a command that names none
   --  of these means: the file decides, as it always did.
   function Asked_Rotation (Item : Opt.Command) return L.Rotary_Request is
      Named : constant String := T.To_String (Item.Rope_Scaling);
   begin
      return
        (Kind =>
           (if Named = "none" then L.As_Trained
            elsif Named = "linear" then L.Linear_Stretch
            elsif Named = "yarn" then L.Yarn_Stretch
            else L.Unasked),
         Factor      => Model_Runner.Numerics.Wide_Real (Item.Rope_Scale),
         Base        => Model_Runner.Numerics.Wide_Real (Item.Rope_Base),
         Original    => Item.Yarn_Original,
         Beta_Fast   =>
           Model_Runner.Numerics.Wide_Real (Item.Yarn_Beta_Fast),
         Beta_Slow   =>
           Model_Runner.Numerics.Wide_Real (Item.Yarn_Beta_Slow),
         Attenuation =>
           Model_Runner.Numerics.Wide_Real (Item.Yarn_Attention));
   end Asked_Rotation;

   ---------------------
   -- Resolved_Backend --
   ---------------------

   --  The backend a run takes when none is named: the device where one
   --  opens and the model's weights fit the device's budget, the processor
   --  otherwise. A device option named without --backend (--device-memory,
   --  --device, --device-patience) says the caller wants the device, and
   --  gets it. The device is left open when it is chosen, opened as the run
   --  will ask for it, so the run's own Open finds it ready rather than
   --  building its pipelines a second time; it is closed when it is not.
   --  A mixture of experts whose experts do not fit the device still
   --  goes there when the rest of it does: the device runs each layer's
   --  front half and the processor the experts. What the budget is weighed
   --  against is then the model's bytes less its experts' -- the tensors
   --  named *_exps -- or the whole file where it cannot be read as a model
   --  here (the run reports that itself). A dense model is split the same
   --  way, a layer's gate, up and down to the processor's panels, so its
   --  bytes are weighed less those of the layers whose three the panels
   --  take: ThinkingCap-Qwen3.8-27B, 15.5 GB against 14.6, generates at
   --  3.66 tokens a second split and 2.90 on the processor alone.
   function Resolved_Backend
     (Item   : Opt.Command;
      Screen : in out Pres.Console) return Opt.Command
   is
      Result : Opt.Command := Item;
      Ready  : Boolean;

      --  The bytes of a file the device need not hold: a mixture's
      --  experts, or where it has none, the feed-forward of every layer
      --  whose gate, up and down the processor's panels take. Nought where
      --  the file cannot be read as a model, which discounts nothing and so
      --  never puts on the device what would not fit there: the cautious
      --  answer, not a guess.
      function Spared_Bytes (Path : String) return Interfaces.Unsigned_64 is
         From      : Files.File_Source;
         Parsed    : Containers.Container;
         Condition : E.Error_Info;
         Total     : Interfaces.Unsigned_64 := 0;
         Dense     : Interfaces.Unsigned_64 := 0;

         --  The tensor of this name, or nought.
         function Named (Wanted : String) return Natural is
         begin
            for Index in 1 .. Containers.Tensor_Count (Parsed) loop
               if Containers.Tensor_Name (Parsed, Index) = Wanted then
                  return Index;
               end if;
            end loop;
            return 0;
         end Named;

         --  Whether the panels take this matrix, as the split asks.
         function Paneled (Index : Natural) return Boolean
         is (Index /= 0
             and then Containers.Tensor_Rank (Parsed, Index) = 2
             and then Model_Runner.Quantization.Interleave.Interleaves
                        (Containers.Tensor_Format (Parsed, Index),
                         Model_Runner.Numerics.Element_Count
                           (Containers.Tensor_Dimension (Parsed, Index, 2)),
                         Model_Runner.Numerics.Element_Count
                           (Containers.Tensor_Dimension (Parsed, Index, 1))));
      begin
         Files.Open (From, Path, Status => Condition);
         if E.Is_Error (Condition) then
            return 0;
         end if;

         Containers.Reader.Parse (Parsed, From, Status => Condition);
         if not E.Is_Error (Condition) then
            for Index in 1 .. Containers.Tensor_Count (Parsed) loop
               declare
                  Name : constant String :=
                    Containers.Tensor_Name (Parsed, Index);
                  Gate : constant Natural :=
                    Ada.Strings.Fixed.Index (Name, "ffn_gate.weight");
               begin
                  if Ada.Strings.Fixed.Index (Name, "_exps.") > 0 then
                     Total := Total + Containers.Tensor_Bytes (Parsed, Index);
                  elsif Gate > 0 and then Gate + 14 = Name'Last then
                     declare
                        Stem : constant String := Name (Name'First .. Gate - 1);
                        Up   : constant Natural := Named (Stem & "ffn_up.weight");
                        Down : constant Natural := Named (Stem & "ffn_down.weight");
                     begin
                        if Paneled (Index) and then Paneled (Up)
                          and then Paneled (Down)
                        then
                           Dense := Dense
                             + Containers.Tensor_Bytes (Parsed, Index)
                             + Containers.Tensor_Bytes (Parsed, Up)
                             + Containers.Tensor_Bytes (Parsed, Down);
                        end if;
                     end;
                  end if;
               end;
            end loop;
            if Total = 0 then
               Total := Dense;
            end if;
         end if;

         Containers.Close (Parsed);
         Files.Close (From);
         return Total;
      exception
         when others =>
            --  Anything raised here is not a file that will not read --
            --  that is the status above -- but a fault: closed, and on.
            Files.Close (From);
            raise;
      end Spared_Bytes;
   begin
      if Item.Backend_Set then
         return Result;
      end if;

      if Item.Device_Memory_Set
        or else Item.Device_Index_Set
        or else Item.Device_Patience_Set
      then
         Result.Backend := Model_Runner.Backend.Backend_Device;
         return Result;
      end if;

      Model_Runner.Backend.Device.Open
        (Ready, Item.Device_Memory, Item.Device_Share,
         Patience => Item.Device_Patience,
         Which => Item.Device_Index);

      if not Ready then
         return Result;
      end if;

      declare
         Path : constant String :=
           Model_Runner.Platform.Resolve_Model_Path
             (T.To_String (Item.Model_Path));

         Weights : constant Interfaces.Unsigned_64 :=
           (if Ada.Directories.Exists (Path)
            then Interfaces.Unsigned_64 (Ada.Directories.Size (Path))
            else 0);

         Holds : constant Interfaces.Unsigned_64 :=
           Model_Runner.Backend.Device.Describe.Memory_Bytes;
      begin
         if Weights > 0
           and then Holds > 0
           and then (Weights <= Holds
                     or else Weights - Spared_Bytes (Path) <= Holds)
         then
            Result.Backend := Model_Runner.Backend.Backend_Device;
         else
            Model_Runner.Backend.Device.Close;

            if Weights > Holds and then Holds > 0 then
               Screen.Put_Message
                 ("cli.note.backend_auto_cpu",
                  [Loc.Named
                     ("requested",
                      Model_Runner.Text.Image (Long_Long_Integer (Weights))),
                   Loc.Named
                     ("limit",
                      Model_Runner.Text.Image (Long_Long_Integer (Holds)))]);
            end if;
         end if;
      end;

      return Result;
   exception
      --  The model file gone or not to be read between the look and the
      --  size: the run reports that itself, on the backend asked for.
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         Model_Runner.Backend.Device.Close;
         return Item;
      --  Anything else is a fault in the choosing, said as one at the
      --  command's boundary rather than passed off as the default choice.
      when others =>
         Model_Runner.Backend.Device.Close;
         raise;
   end Resolved_Backend;

   --  A run on the processor with no rewrite asked for: its weights in
   --  panels, where this processor has the kernels that read them, the
   --  model is one panels cover and it fits in what memory is free.
   --  Without them Q2_K, Q3_K and the four-bit lookups run on the
   --  floating-point path: TinyLlama Q2_K generates 12 tokens a second as
   --  stored and 73 in panels.
   function With_Panels (Item : Opt.Command) return Opt.Command is
      Result : Opt.Command := Item;
      Path   : constant String :=
        Model_Runner.Platform.Resolve_Model_Path (T.To_String (Item.Model_Path));
      Weights : constant Interfaces.Unsigned_64 :=
        (if Ada.Directories.Exists (Path) then Interfaces.Unsigned_64 (Ada.Directories.Size (Path)) else 0);
   begin
      if Model_Runner.Backend."=" (Item.Backend, Model_Runner.Backend.Backend_CPU)
        and then L."=" (Item.Repack, L.No_Repack)
        and then not Item.Repack_Asked
        and then T.Is_Empty (Item.Adapter_Path)
        --  The panels are held, the file's pages only cached and given back:
        --  room for the panels and a margin is what it takes; and in one
        --  allocation the bounds allow -- a model past it, qwen3.6-35B's
        --  19 GB against 16 GiB, would be refused at load for a default
        --  nobody asked for.
        and then L.Panels_Unasked
                   (Weights, Model_Bounds (Item).Max_Allocation_Bytes,
                    Model_Runner.Platform.Available_Memory)
      then
         Result.Repack := L.To_Rows;
      end if;
      return Result;
   exception
      --  The file gone between the look and the size: run as asked, and
      --  the run says what it finds.
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         return Item;
   end With_Panels;

end Model_Runner.CLI.Execute.Support;
