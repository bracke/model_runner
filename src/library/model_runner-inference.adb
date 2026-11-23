with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Unchecked_Deallocation;

with CryptoLib.Hashes;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Grammar;
with Model_Runner.Heap_Buffers;
with Model_Runner.Output;
with Model_Runner.Schema;
with Model_Runner.Stops;

package body Model_Runner.Inference is
   use Ada.Strings.Unbounded;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Backend.Backend_Kind;
   use type Model_Runner.Backend.Device.Tuning_Disposition;
   use type Model_Runner.Generation.Completion_Reason;

   package CPU renames Model_Runner.Backend.CPU;
   package Device renames Model_Runner.Backend.Device;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;

   procedure Free_Pool is new Ada.Unchecked_Deallocation
     (Object => CPU.Pool, Name => Pool_Access);

   type Capture (Limit : Positive) is limited new Model_Runner.Output.Sink with record
      Content  : UString;
      Overflow : Boolean := False;
      Closed   : Boolean := False;
   end record;

   overriding procedure Write
     (Self   : in out Capture;
      Item   : String;
      Closed : out Boolean);

   overriding procedure Flush
     (Self   : in out Capture;
      Closed : out Boolean);

   overriding function Is_Closed (Self : Capture) return Boolean;

   overriding procedure Write
     (Self   : in out Capture;
      Item   : String;
      Closed : out Boolean) is
   begin
      if not Self.Closed then
         if Item'Length > Self.Limit - Length (Self.Content) then
            Self.Overflow := True;
            Self.Closed := True;
         else
            Append (Self.Content, Item);
         end if;
      end if;
      Closed := Self.Closed;
   end Write;

   overriding procedure Flush
     (Self   : in out Capture;
      Closed : out Boolean) is
   begin
      Closed := Self.Closed;
   end Flush;

   overriding function Is_Closed (Self : Capture) return Boolean is
     (Self.Closed);

   procedure Close (Item : in out Prepared_Schema) is
   begin
      Model_Runner.Grammar.Close (Item.Rules.Data.all);
      Item.Ready := False;
   end Close;

   procedure Prepare
     (Item   : in out Prepared_Schema;
      Text   : String;
      Status : out E.Error_Info) is
      Grammar_Room : Model_Runner.Heap_Buffers.Text
        (Model_Runner.Schema.Max_Grammar_Bytes);
      Grammar_Text : String renames Grammar_Room.Data.all;
      Grammar_Last : Natural := 0;
   begin
      Close (Item);
      Model_Runner.Schema.To_Grammar
        (Text, Grammar_Text, Grammar_Last, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Model_Runner.Grammar.Compile
        (Item.Rules.Data.all, Grammar_Text (1 .. Grammar_Last), Status);
      Item.Ready := E.Is_Ok (Status);
   end Prepare;

   function Is_Ready (Item : Prepared_Schema) return Boolean is
     (Item.Ready);

   procedure Close
     (Item   : in out Session;
      Status : out E.Error_Info)
   is
      procedure Note_Failure
        (Failure : Ada.Exceptions.Exception_Occurrence;
         Doing   : String) is
      begin
         if E.Is_Ok (Status) then
            Status := E.Unexpected (Failure, Doing);
         end if;
      end Note_Failure;

      Model_Status : E.Error_Info;
   begin
      Status := E.Success;

      --  Stop owned tasks first.  Every later release is best effort so a
      --  finalizer cannot strand the worker pool if another component's
      --  cleanup unexpectedly raises.
      if Item.Pool /= null then
         begin
            CPU.Close (Item.Pool.all);
            Free_Pool (Item.Pool);
         exception
            when Failure : others =>
               Note_Failure (Failure, "closing the embedded CPU pool");
         end;
      end if;
      begin
         L.Close (Item.Context);
      exception
         when Failure : others =>
            Note_Failure (Failure, "closing the embedded inference context");
      end;
      begin
         L.Close (Item.Engine, Model_Status);
         if E.Is_Error (Model_Status) and then E.Is_Ok (Status) then
            Status := Model_Status;
            E.Add_Frame (Status, "closing the embedded inference model");
         end if;
      exception
         when Failure : others =>
            Note_Failure (Failure, "closing the embedded inference model");
      end;
      begin
         Model_Runner.GGUF.Containers.Close (Item.Container);
      exception
         when Failure : others =>
            Note_Failure (Failure, "closing the embedded GGUF container");
      end;
      begin
         Model_Runner.GGUF.Shards.Close (Item.Source);
      exception
         when Failure : others =>
            Note_Failure (Failure, "closing the embedded GGUF shards");
      end;
      if Item.Device_Owned then
         begin
            Device.Close_Exclusive (Item.Device_Lease);
            Item.Device_Owned := False;
         exception
            when Failure : others =>
               Note_Failure (Failure, "closing the embedded compute device");
         end;
      end if;
      --  Close always ends the public lifetime: a partly released session
      --  must never remain usable.  The resource objects themselves, and
      --  Device_Owned when its release failed, remain in Item so a later
      --  Close or finalization can retry the failed cleanup.
      Item.Bounds := Model_Runner.Limits.Default_Session_Limits;
      Item.Path := Null_Unbounded_String;
      Item.Canonical_Path := Null_Unbounded_String;
      Item.Opened := False;
   end Close;

   procedure Close (Item : in out Session) is
      Status : E.Error_Info;
   begin
      Close (Item, Status);
      if E.Is_Error (Status) then
         raise Program_Error with E.Diagnostic_Code (Status.Code);
      end if;
   end Close;

   overriding procedure Finalize (Item : in out Session) is
      Status : E.Error_Info;
   begin
      --  A finalizer cannot report a status and must not mask an exception
      --  already leaving the owning scope.  Operational callers use the
      --  status-bearing Close above instead.
      Close (Item, Status);
   end Finalize;

   procedure Open
     (Item    : in out Session;
      Path    : String;
      Options : Open_Options := (others => <>);
      Status  : out E.Error_Info) is
      pragma Suppress (Validity_Check);
      use type Interfaces.Unsigned_64;
      Ready   : Boolean;
      Granted : Boolean;

      procedure Load_Adapter (Index : Positive) is
         package Files renames Model_Runner.Byte_Sources.Files;
         Source : Files.File_Source;
         Parsed : Model_Runner.GGUF.Containers.Container;
      begin
         Files.Open
           (Source, Model_Runner.Text.To_String (Options.Runtime_Adapters (Index).Path),
            Max_Bytes => Model_Runner.Bytes.Byte_Count
              (Interfaces.Unsigned_64'Min
                 (Options.Model_Bounds.Max_File_Bytes,
                  Interfaces.Unsigned_64 (Model_Runner.Bytes.Byte_Count'Last))), Status => Status);
         if E.Is_Ok (Status) then
            Model_Runner.GGUF.Containers.Reader.Parse
              (Parsed, Source, Bounds => Options.Model_Bounds, Cancel => Options.Cancel,
               Observer => Options.Observer, Status => Status);
         end if;
         if E.Is_Ok (Status) then
            L.Attach_Adapter
              (Item.Engine, Parsed, Source, Scale => Options.Runtime_Adapters (Index).Scale,
               Bounds => Options.Adapter_Bounds, Cancel => Options.Cancel, Status => Status);
         end if;
         Model_Runner.GGUF.Containers.Close (Parsed);
         Files.Close (Source);
      exception
         when others =>
            Model_Runner.GGUF.Containers.Close (Parsed);
            Files.Close (Source);
            raise;
      end Load_Adapter;

      --  Preserve the operation's primary diagnostic. Open is a
      --  status-returning boundary, so a second failure during cleanup must
      --  not turn an ordinary refusal into Program_Error.
      procedure Close_After_Failure is
         Primary : constant E.Error_Info := Status;
         Cleanup : E.Error_Info;
      begin
         Close (Item, Cleanup);
         Status := Primary;
         if E.Is_Error (Cleanup) then
            E.Add_Frame
              (Status, "cleanup also reported "
               & E.Diagnostic_Code (Cleanup.Code));
         end if;
      end Close_After_Failure;
   begin
      Close (Item, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Options.Runtime_Adapter_Count > 0 then
         if Options.Backend /= Model_Runner.Backend.Backend_CPU then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text (Status, "feature", "embedded_runtime_adapter_backend", E.Param_Identifier);
            return;
         elsif Options.Adapter_Bounds.Max_Adapters > L.Default_Adapter_Limits.Max_Adapters
           or else Options.Adapter_Bounds.Max_Pairs > L.Default_Adapter_Limits.Max_Pairs
           or else Options.Adapter_Bounds.Max_Rank > L.Default_Adapter_Limits.Max_Rank
           or else Options.Adapter_Bounds.Max_Bytes = 0
           or else Options.Adapter_Bounds.Max_Bytes > L.Default_Adapter_Limits.Max_Bytes
         then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text (Status, "feature", "adapter_limits", E.Param_Identifier);
            return;
         elsif Options.Runtime_Adapter_Count > Options.Adapter_Bounds.Max_Adapters then
            Status := E.Make (E.Memory_Limit_Exceeded);
            E.Add_Text (Status, "category", "adapter_weights", E.Param_Identifier);
            E.Add_Integer (Status, "requested", Long_Long_Integer (Options.Runtime_Adapter_Count));
            E.Add_Integer (Status, "limit", Long_Long_Integer (Options.Adapter_Bounds.Max_Adapters));
            return;
         end if;
         for Index in 1 .. Options.Runtime_Adapter_Count loop
            if Model_Runner.Text.Is_Empty (Options.Runtime_Adapters (Index).Path) then
               Status := E.Make (E.IO_Open_Failed);
               E.Add_Text (Status, "path", "", E.Param_Path);
               return;
            elsif not Model_Runner.Numerics.Is_Finite (Options.Runtime_Adapters (Index).Scale) then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               E.Add_Text (Status, "tensor", "adapter.scale", E.Param_Identifier);
               return;
            end if;
         end loop;
      end if;

      if Options.Backend = Model_Runner.Backend.Backend_Device then
         Device.Open_Exclusive
           (Ready, Granted, Item.Device_Lease,
            Budget => Options.Device_Memory,
            Share_Host => Options.Device_Share_Host,
            Patience => Options.Device_Patience,
            Which => Options.Device_Index,
            Tuning_Profile =>
              Model_Runner.Text.To_String (Options.Device_Tuning));
         if not Granted then
            Status := E.Make (E.Backend_Device_Refused);
            E.Add_Frame (Status, "another process-global device owner exists");
            return;
         end if;
         if not Ready then
            if Device.Tuning_Status = Device.Tuning_Refused then
               Status := E.Make (E.Backend_Tuning_Profile);
               E.Add_Text
                 (Status, "path", Device.Tuning_Profile, E.Param_Path);
            else
               Status := E.Make (E.Backend_No_Device);
            end if;
            return;
         end if;
         Item.Device_Owned := True;
      end if;

      declare
         Auxiliary : Model_Runner.Text.Bounded_List
           (1 .. Options.Auxiliary_Count);
      begin
         for Index in Auxiliary'Range loop
            Auxiliary (Index) := Options.Auxiliary (Index);
         end loop;
         Model_Runner.GGUF.Shards.Open_Model
           (Item.Source, Item.Container, Path, Auxiliary,
            Bounds => Options.Model_Bounds, Cancel => Options.Cancel,
            Observer => Options.Observer,
            Status => Status);
      end;
      if E.Is_Error (Status) then
         Close_After_Failure;
         return;
      end if;

      L.Prepare
        (Item.Engine, Item.Container, Item.Source,
         Bounds => Options.Model_Bounds, Backend => Options.Backend,
         Repack => Options.Repack, Threads => Options.Load_Threads,
         Fit_Required => Options.Fit_Required, Cancel => Options.Cancel,
         Observer => Options.Observer,
         Panel_Cache => Model_Runner.Text.To_String (Options.Panel_Cache),
         Context => Options.Context_Tokens, Cache => Options.Cache,
         Paged => Options.Paged, Status => Status);
      if E.Is_Error (Status) then
         Close_After_Failure;
         return;
      end if;

      for Index in 1 .. Options.Runtime_Adapter_Count loop
         Load_Adapter (Index);
         if E.Is_Error (Status) then
            Close_After_Failure;
            return;
         end if;
      end loop;

      Item.Pool := new CPU.Pool (Options.Workers);
      CPU.Open (Item.Pool.all);
      L.Open
        (Item.Context, Item.Engine, Context => Options.Context_Tokens,
         Session_Bounds => Options.Session_Bounds,
         Workers => CPU.Pool_Reference (Item.Pool), Cache => Options.Cache,
         Values => Options.Values, Paged => Options.Paged, Status => Status);
      if E.Is_Error (Status) then
         Close_After_Failure;
         return;
      end if;

      Item.Bounds := Options.Session_Bounds;
      Item.Path := To_Unbounded_String (Path);
      Item.Canonical_Path := To_Unbounded_String (Ada.Directories.Full_Name (Path));
      Item.Opened := True;
   exception
      when Failure : others =>
         Status := E.Unexpected (Failure, "opening an embedded inference session");
         Close_After_Failure;
   end Open;

   procedure Complete
     (Item          : in out Session;
      Prompt        : String;
      Answer_Schema : String;
      Options       : Completion_Options;
      Outcome       : out Completion) is
      Schema : Prepared_Schema;
      Status : E.Error_Info;
   begin
      Prepare (Schema, Answer_Schema, Status);
      if E.Is_Error (Status) then
         Outcome :=
           (State  => Completion_Failed,
            Reason => G.Runtime_Error,
            Text   => Null_Unbounded_String,
            Error  => Status);
         return;
      end if;
      Complete (Item, Prompt, Schema, Options, Outcome);
   end Complete;

   procedure Complete
     (Item    : in out Session;
      Prompt  : String;
      Schema  : Prepared_Schema;
      Options : Completion_Options;
      Outcome : out Completion) is
      Stop         : Model_Runner.Stops.Set;
      Sink         : aliased Capture (Options.Maximum_Output_Bytes);
      Request      : G.Request;
      Generated    : G.Result;
   begin
      Outcome :=
        (State  => Completion_Failed,
         Reason => G.Runtime_Error,
         Text   => Null_Unbounded_String,
         Error  => E.Success);

      if not Item.Opened then
         Outcome.Error := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;
      if not Schema.Ready then
         Outcome.Error := E.Make (E.Grammar_Missing_Root);
         return;
      end if;

      Model_Runner.Stops.Open (Stop, Item.Bounds);
      Request.Max_Tokens := Options.Maximum_Tokens;
      Request.Fill_Context := Options.Fill_Context;
      Request.Deadline := Options.Deadline;
      Request.Sampling := Options.Sampling;
      Request.Add_Beginning := Options.Add_Beginning;

      L.Reset (Item.Context);
      G.Generate
        (Source => Item.Engine, Session => Item.Context, Prompt => Prompt,
         Item => Request, Stop_Set => Stop,
         Rules => Schema.Rules.Data.all'Unchecked_Access,
         Sink => Sink'Unchecked_Access, Observer => Options.Observer, Time => null,
         Seeds => null, Cancel => Options.Cancel, Bounds => Item.Bounds,
         Outcome => Generated);

      Outcome.Text := Sink.Content;
      Outcome.Reason := Generated.Reason;
      Outcome.Error := Generated.Error;
      if Sink.Overflow then
         Outcome.State := Completion_Output_Limit;
      elsif Generated.Reason in G.Maximum_Tokens | G.Context_Full | G.Output_Closed then
         Outcome.State := Completion_Incomplete;
      elsif Generated.Reason = G.Cancelled then
         Outcome.State := Completion_Cancelled;
      elsif Generated.Reason = G.Time_Limit then
         Outcome.State := Completion_Timed_Out;
      elsif Generated.Reason = G.Runtime_Error then
         Outcome.State := Completion_Failed;
      else
         Outcome.State := Completion_Ready;
      end if;
   end Complete;

   function Is_Open (Item : Session) return Boolean is (Item.Opened);

   function Model_Path (Item : Session) return String is
     (To_String (Item.Path));

   function Provenance (Item : Session) return Model_Provenance is
   begin
      if not Item.Opened then
         return (others => <>);
      end if;
      return
        (Canonical_Path => Item.Canonical_Path,
         Name => To_Unbounded_String
           (Model_Runner.GGUF.Containers.String_Value
              (Item.Container, "general.name")),
         Architecture => To_Unbounded_String
           (L.Architecture_Name (L.Config (Item.Engine).Kind)),
         Fingerprint => L.Fingerprint (Item.Engine),
         Bytes => Interfaces.Unsigned_64
           (Model_Runner.GGUF.Shards.Size (Item.Source)),
         Parts => Model_Runner.GGUF.Shards.Parts (Item.Source),
         Runtime_Adapter_Count => L.Runtime_Adapter_Count (Item.Engine),
         Runtime_Adapter_Bytes => L.Runtime_Adapter_Bytes (Item.Engine));
   end Provenance;

   procedure SHA256
     (Item   : in out Session;
      Digest : out SHA256_Hex;
      Status : out E.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null) is
      use Ada.Streams;
      Chunk_Size : constant Model_Runner.Bytes.Byte_Count := 64 * 1_024;
      Raw        : Model_Runner.Bytes.Byte_Array (1 .. Chunk_Size);
      Encoded    : Stream_Element_Array
        (1 .. Stream_Element_Offset (Chunk_Size));
      Context    : CryptoLib.Hashes.SHA256_Context;
      Value      : CryptoLib.Hashes.SHA256_Digest;
      Offset     : Model_Runner.Bytes.Byte_Count := 0;
      Total      : Model_Runner.Bytes.Byte_Count;
      Hex        : constant String := "0123456789abcdef";
   begin
      Digest := [others => '0'];
      if not Item.Opened then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;
      Total := Model_Runner.GGUF.Shards.Size (Item.Source);
      CryptoLib.Hashes.Initialize_SHA256 (Context);
      Model_Runner.Progress.Publish
        (Observer,
         Model_Runner.Progress.Load_Progress
           (Model_Runner.Progress.Hashing_Model,
            Completed => 0,
            Total     => Interfaces.Unsigned_64 (Total)));
      while Offset < Total loop
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;
         declare
            Take : constant Model_Runner.Bytes.Byte_Count :=
              Model_Runner.Bytes.Byte_Count'Min (Chunk_Size, Total - Offset);
         begin
            Model_Runner.GGUF.Shards.Read
              (Item.Source, Offset, Raw (1 .. Take), Status);
            if E.Is_Error (Status) then
               return;
            end if;
            for Index in 1 .. Take loop
               Encoded (Stream_Element_Offset (Index)) :=
                 Stream_Element (Raw (Index));
            end loop;
            CryptoLib.Hashes.Update
              (Context, Encoded (1 .. Stream_Element_Offset (Take)));
            Offset := Offset + Take;
            Model_Runner.Progress.Publish
              (Observer,
               Model_Runner.Progress.Load_Progress
                 (Model_Runner.Progress.Hashing_Model,
                  Completed => Interfaces.Unsigned_64 (Offset),
                  Total     => Interfaces.Unsigned_64 (Total)));
         end;
      end loop;
      Value := CryptoLib.Hashes.Finalize (Context);
      for Index in Value'Range loop
         Digest (2 * Index - 1) := Hex (Natural (Value (Index)) / 16 + 1);
         Digest (2 * Index) := Hex (Natural (Value (Index)) mod 16 + 1);
      end loop;
      Status := E.Success;
   end SHA256;

end Model_Runner.Inference;
