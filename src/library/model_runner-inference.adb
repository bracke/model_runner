with Ada.Directories;
with Ada.Streams;
with Ada.Unchecked_Deallocation;

with CryptoLib.Hashes;

with Model_Runner.Bytes;
with Model_Runner.Grammar;
with Model_Runner.Backend.Device;
with Model_Runner.Heap_Buffers;
with Model_Runner.Output;
with Model_Runner.Schema;
with Model_Runner.Stops;

package body Model_Runner.Inference is
   use Ada.Strings.Unbounded;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Backend.Backend_Kind;
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

   procedure Close (Item : in out Session) is
      Ignored : E.Error_Info;
   begin
      --  Stop owned tasks first.  Every later release is best effort so a
      --  finalizer cannot strand the worker pool if another component's
      --  cleanup unexpectedly raises.
      if Item.Pool /= null then
         CPU.Close (Item.Pool.all);
         Free_Pool (Item.Pool);
      end if;
      begin
         L.Close (Item.Context);
      exception
         when others => null;
      end;
      begin
         L.Close (Item.Engine, Ignored);
      exception
         when others => null;
      end;
      begin
         Model_Runner.GGUF.Containers.Close (Item.Container);
      exception
         when others => null;
      end;
      begin
         Model_Runner.GGUF.Shards.Close (Item.Source);
      exception
         when others => null;
      end;
      if Item.Device_Owned then
         begin
            Device.Close;
         exception
            when others => null;
         end;
         Item.Device_Owned := False;
      end if;
      Item.Bounds := Model_Runner.Limits.Default_Session_Limits;
      Item.Path := Null_Unbounded_String;
      Item.Canonical_Path := Null_Unbounded_String;
      Item.Opened := False;
   end Close;

   overriding procedure Finalize (Item : in out Session) is
   begin
      Close (Item);
   end Finalize;

   procedure Open
     (Item    : in out Session;
      Path    : String;
      Options : Open_Options := (others => <>);
      Status  : out E.Error_Info) is
      Ready : Boolean;
   begin
      Close (Item);

      if Options.Backend = Model_Runner.Backend.Backend_Device then
         Device.Open
           (Ready, Budget => Options.Device_Memory,
            Share_Host => Options.Device_Share_Host,
            Patience => Options.Device_Patience, Which => Options.Device_Index);
         if not Ready then
            Status := E.Make (E.Backend_No_Device);
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
         Close (Item);
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
         Close (Item);
         return;
      end if;

      Item.Pool := new CPU.Pool (Options.Workers);
      CPU.Open (Item.Pool.all);
      L.Open
        (Item.Context, Item.Engine, Context => Options.Context_Tokens,
         Session_Bounds => Options.Session_Bounds,
         Workers => CPU.Pool_Reference (Item.Pool), Cache => Options.Cache,
         Values => Options.Values, Paged => Options.Paged, Status => Status);
      if E.Is_Error (Status) then
         Close (Item);
         return;
      end if;

      Item.Bounds := Options.Session_Bounds;
      Item.Path := To_Unbounded_String (Path);
      Item.Canonical_Path := To_Unbounded_String (Ada.Directories.Full_Name (Path));
      Item.Opened := True;
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
         Parts => Model_Runner.GGUF.Shards.Parts (Item.Source));
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
