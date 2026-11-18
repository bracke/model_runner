with Ada.Unchecked_Deallocation;

with Model_Runner.Grammar;
with Model_Runner.Grammar.Rooms;
with Model_Runner.Backend.Device;
with Model_Runner.Heap_Buffers;
with Model_Runner.Output;
with Model_Runner.Schema;
with Model_Runner.Stops;

package body Model_Runner.Inference is
   use Ada.Strings.Unbounded;
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

   procedure Close (Item : in out Session) is
      Ignored : E.Error_Info;
   begin
      L.Close (Item.Context);
      if Item.Pool /= null then
         CPU.Close (Item.Pool.all);
         Free_Pool (Item.Pool);
      end if;
      L.Close (Item.Engine, Ignored);
      Model_Runner.GGUF.Containers.Close (Item.Container);
      Model_Runner.GGUF.Shards.Close (Item.Source);
      if Item.Device_Owned then
         Device.Close;
         Item.Device_Owned := False;
      end if;
      Item.Bounds := Model_Runner.Limits.Default_Session_Limits;
      Item.Path := Null_Unbounded_String;
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
      Item.Opened := True;
   end Open;

   procedure Complete
     (Item          : in out Session;
      Prompt        : String;
      Answer_Schema : String;
      Options       : Completion_Options;
      Outcome       : out Completion) is
      Grammar_Room : Model_Runner.Heap_Buffers.Text
        (Model_Runner.Schema.Max_Grammar_Bytes);
      Grammar_Text : String renames Grammar_Room.Data.all;
      Grammar_Last : Natural := 0;
      Rules_Room   : Model_Runner.Grammar.Rooms.Holder;
      Rules        : Model_Runner.Grammar.Compiled renames Rules_Room.Data.all;
      Stop         : Model_Runner.Stops.Set;
      Sink         : aliased Capture (Options.Maximum_Output_Bytes);
      Request      : G.Request;
      Generated    : G.Result;
      Status       : E.Error_Info;
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

      Model_Runner.Schema.To_Grammar
        (Answer_Schema, Grammar_Text, Grammar_Last, Status);
      if E.Is_Error (Status) then
         Outcome.Error := Status;
         return;
      end if;

      Model_Runner.Grammar.Compile
        (Rules, Grammar_Text (1 .. Grammar_Last), Status);
      if E.Is_Error (Status) then
         Outcome.Error := Status;
         return;
      end if;

      Model_Runner.Stops.Open (Stop, Item.Bounds);
      Request.Max_Tokens := Options.Maximum_Tokens;
      Request.Deadline := Options.Deadline;
      Request.Sampling := Options.Sampling;
      Request.Add_Beginning := Options.Add_Beginning;

      L.Reset (Item.Context);
      G.Generate
        (Source => Item.Engine, Session => Item.Context, Prompt => Prompt,
         Item => Request, Stop_Set => Stop,
         Rules => Rules'Unchecked_Access,
         Sink => Sink'Unchecked_Access, Observer => null, Time => null,
         Seeds => null, Cancel => Options.Cancel, Bounds => Item.Bounds,
         Outcome => Generated);

      Outcome.Text := Sink.Content;
      Outcome.Reason := Generated.Reason;
      Outcome.Error := Generated.Error;
      if Sink.Overflow then
         Outcome.State := Completion_Output_Limit;
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

end Model_Runner.Inference;
