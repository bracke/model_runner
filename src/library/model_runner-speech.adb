with Ada.Streams;
with Ada.Unchecked_Deallocation;

with Hostkit.Microphone;

with Model_Runner.Audio;
with Model_Runner.Bytes;
with Model_Runner.Platform;

package body Model_Runner.Speech is

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package CPU renames Model_Runner.Backend.CPU;
   package W renames Model_Runner.Whisper;

   use Ada.Strings.Unbounded;
   use type N.Element_Count;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;
   use type Hostkit.Microphone.Outcome;

   procedure Free is new Ada.Unchecked_Deallocation (Recognizer, Recognizer_Access);
   procedure Free is new Ada.Unchecked_Deallocation (CPU.Pool, Pool_Access);
   procedure Free is new Ada.Unchecked_Deallocation (N.Real_Array, Recording_Buffer);

   --  What is kept free past a speech model and its session: the
   --  conversation's model may still grow its cache.
   Margin : constant Interfaces.Unsigned_64 := 512 * 1024 * 1024;

   function Image (Item : State) return String is
     (case Item is
         when Disabled     => "disabled",
         when Unloaded     => "unloaded",
         when Loading      => "loading",
         when Ready        => "ready",
         when Recording    => "recording",
         when Transcribing => "transcribing",
         when Failed       => "failed",
         when Unloading    => "unloading");

   ------------
   -- Shared --
   ------------

   protected body Shared is

      procedure Configure (Capacity_Samples : N.Element_Count) is
      begin
         if Room = null or else Room'Length /= Capacity_Samples then
            if Room /= null then
               Free (Room);
            end if;
            Room := new N.Real_Array (0 .. Capacity_Samples - 1);
         end if;
         Held := 0;
      end Configure;

      function Now return State is (Current_State);

      procedure Set (To : State) is
      begin
         Current_State := To;
      end Set;

      procedure Post_Capture (Work : Job) is
      begin
         Capture_Work := Work;
         if Work = Begin_Recording then
            Stop := False;
            Capture_Over := False;
            Capture_Outcome := E.Success;
            At_Limit := False;
            Held := 0;
            Has_Result := False;
         end if;
      end Post_Capture;

      entry Next_Capture (Work : out Job) when Capture_Work /= None is
      begin
         Work := Capture_Work;
         Capture_Work := None;
      end Next_Capture;

      procedure Request_Stop is
      begin
         Stop := True;
      end Request_Stop;

      function Stop_Requested return Boolean is (Stop);

      procedure Append (Samples : N.Real_Array; Full : out Boolean) is
         Take : constant N.Element_Count :=
           N.Element_Count'Min (Samples'Length, (if Room = null then 0 else Room'Length - Held));
      begin
         if Take > 0 then
            Room (Held .. Held + Take - 1) := Samples (Samples'First .. Samples'First + Take - 1);
            Held := Held + Take;
         end if;
         Full := Room = null or else Held = Room'Length;
      end Append;

      procedure Capture_Ended (Outcome : E.Error_Info; At_Limit : Boolean) is
      begin
         Capture_Over := True;
         Capture_Outcome := Outcome;
         Shared.At_Limit := At_Limit;
      end Capture_Ended;

      function Capture_Is_Over return Boolean is (Capture_Over);

      entry Await_Capture (Outcome : out E.Error_Info) when Capture_Over is
      begin
         Outcome := Capture_Outcome;
      end Await_Capture;

      function Samples_Held return N.Element_Count is (Held);

      procedure Post_Inference (Work : Job) is
      begin
         --  A quit is never overwritten, and outranks what was posted.
         if Inference_Work /= Quit then
            Inference_Work := Work;
         end if;
      end Post_Inference;

      entry Next_Inference (Work : out Job) when Inference_Work /= None is
      begin
         Work := Inference_Work;
         Inference_Work := None;
      end Next_Inference;

      procedure Set_Result (Text : Unbounded_String; Outcome : E.Error_Info) is
      begin
         Result_Text := Text;
         Result_Outcome := Outcome;
         Has_Result := True;
      end Set_Result;

      function Result_Ready return Boolean is (Has_Result);

      procedure Take_Result
        (Text          : out Unbounded_String;
         Outcome       : out E.Error_Info;
         Limit_Reached : out Boolean) is
      begin
         Text := Result_Text;
         Outcome := Result_Outcome;
         Limit_Reached := At_Limit;
         Result_Text := Null_Unbounded_String;
         Has_Result := False;
         --  The samples are forgotten once heard.
         if Room /= null then
            Room (0 .. Held - 1) := [others => 0.0];
         end if;
         Held := 0;
      end Take_Result;

      procedure Set_Loaded (Loaded : Boolean) is
      begin
         Shared.Loaded := Loaded;
      end Set_Loaded;

      function Is_Loaded return Boolean is (Loaded);

      function Buffer return Recording_Buffer is (Room);

      procedure Release_Buffer is
      begin
         if Room /= null then
            Free (Room);
         end if;
         Held := 0;
      end Release_Buffer;

   end Shared;

   -----------
   -- Admit --
   -----------

   procedure Admit
     (Needed    : Interfaces.Unsigned_64;
      Available : Interfaces.Unsigned_64;
      Status    : out E.Error_Info) is
   begin
      Status := E.Success;
      if Available < Needed or else Available - Needed < Margin then
         Status := E.Make (E.Memory_Limit_Exceeded);
         E.Add_Text (Status, "category", "speech", E.Param_Identifier);
         E.Add_Integer (Status, "requested", Long_Long_Integer (Needed + Margin));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Available));
      end if;
   end Admit;

   ------------------
   -- Capture_Task --
   ------------------

   task body Capture_Task is
      Work   : Job;
      Device : Hostkit.Microphone.Device;
      Result : Hostkit.Microphone.Outcome;
      Reason : Unbounded_String;
      Chunk  : Ada.Streams.Stream_Element_Array (1 .. Hostkit.Microphone.Chunk_Bytes);
      Bytes  : Model_Runner.Bytes.Byte_Array (1 .. Hostkit.Microphone.Chunk_Bytes)
        with Import, Address => Chunk'Address;
      Values : N.Real_Array (0 .. Hostkit.Microphone.Chunk_Bytes / 2 - 1);
      Full   : Boolean;

      function Refusal (Detail : String) return E.Error_Info is
         Status : E.Error_Info := E.Make (E.IO_Microphone_Unavailable);
      begin
         E.Add_Text (Status, "detail", Detail, E.Param_Identifier);
         return Status;
      end Refusal;
   begin
      loop
         Owner.Common.Next_Capture (Work);
         exit when Work = Quit;
         if Work = Begin_Recording and then Owner.Wanted.Played /= null then
            --  Played rather than recorded: the same chunks, as fast as
            --  they are taken.
            declare
               Played : N.Real_Array renames Owner.Wanted.Played.all;
               From   : N.Element_Count := Played'First;
            begin
               loop
                  exit when From > Played'Last;
                  Owner.Common.Append
                    (Played (From .. N.Element_Count'Min (Played'Last, From + Values'Length - 1)), Full);
                  From := From + Values'Length;
                  exit when Full or else Owner.Common.Stop_Requested;
               end loop;
               Owner.Common.Capture_Ended (E.Success, Full);
            end;
         elsif Work = Begin_Recording then
            begin
               Hostkit.Microphone.Open (Device, To_String (Owner.Wanted.Source), Result, Reason);
               if Result /= Hostkit.Microphone.Done then
                  Owner.Common.Capture_Ended (Refusal (To_String (Reason)), False);
               else
                  loop
                     Hostkit.Microphone.Read (Device, Chunk, Result, Reason);
                     if Result /= Hostkit.Microphone.Done then
                        Owner.Common.Capture_Ended (Refusal (To_String (Reason)), False);
                        exit;
                     end if;
                     Model_Runner.Audio.Mix_Signed_16 (Bytes, 1, Values);
                     Owner.Common.Append (Values, Full);
                     if Full then
                        Owner.Common.Capture_Ended (E.Success, True);
                        exit;
                     end if;
                     if Owner.Common.Stop_Requested then
                        Owner.Common.Capture_Ended (E.Success, False);
                        exit;
                     end if;
                  end loop;
                  Hostkit.Microphone.Close (Device);
               end if;
               Values := [others => 0.0];
               Chunk := [others => 0];
            exception
               when others =>
                  Hostkit.Microphone.Close (Device);
                  Owner.Common.Capture_Ended (Refusal ("the recording failed"), False);
            end;
         end if;
      end loop;
   end Capture_Task;

   --------------------
   -- Inference_Task --
   --------------------

   task body Inference_Task is
      Work : Job;

      procedure Unload_All is
      begin
         if W.Is_Open (Owner.Session) then
            W.Close (Owner.Session);
         end if;
         declare
            Ignored : E.Error_Info;
         begin
            W.Close (Owner.Model, Ignored);
         end;
         if Owner.Team /= null then
            CPU.Close (Owner.Team.all);
            Free (Owner.Team);
         end if;
         Owner.Common.Set_Loaded (False);
      end Unload_All;

      --  The model read and a session opened, where they are not.
      procedure Load (Status : out E.Error_Info) is
      begin
         Status := E.Success;
         if Owner.Common.Is_Loaded then
            return;
         end if;
         W.Prepare (Owner.Model, To_String (Owner.Wanted.Model_Path), Status);
         if E.Is_Ok (Status) then
            Admit (Interfaces.Unsigned_64 (W.Weight_Bytes (Owner.Model) + W.Session_Bytes (Owner.Model)),
                   Model_Runner.Platform.Available_Memory, Status);
         end if;
         if E.Is_Ok (Status) then
            declare
               Workers : constant Positive :=
                 (if Owner.Wanted.Workers > 0 then Owner.Wanted.Workers
                  else Positive (CPU.Default_Workers (Model_Runner.Platform.Core_Count)));
            begin
               if Workers > 1 then
                  Owner.Team := new CPU.Pool (CPU.Worker_Count (Workers));
                  CPU.Open (Owner.Team.all);
               end if;
            end;
            W.Open (Owner.Session, Owner.Model'Access,
                    (if Owner.Team = null then null else Owner.Team.all'Unchecked_Access), Status);
         end if;
         if E.Is_Error (Status) then
            Unload_All;
            return;
         end if;
         Owner.Common.Set_Loaded (True);
      end Load;

      procedure Hear is
         Status   : E.Error_Info;
         Captured : E.Error_Info;
         Heard    : W.Transcript;
         Settings : W.Options;
      begin
         if not Owner.Common.Is_Loaded then
            Load (Status);
            if E.Is_Error (Status) then
               Owner.Common.Request_Stop;
               Owner.Common.Await_Capture (Captured);
               Owner.Common.Set (Failed);
               Owner.Common.Set_Result (Null_Unbounded_String, Status);
               return;
            end if;
         end if;
         Owner.Common.Await_Capture (Captured);
         if Owner.Common.Samples_Held = 0 then
            Owner.Common.Set (Ready);
            Owner.Common.Set_Result (Null_Unbounded_String, (if E.Is_Error (Captured) then Captured else E.Success));
            return;
         end if;
         Settings.Language := Owner.Wanted.Language;
         --  What is said to a prompt is short: the language from the
         --  window heard, not from an encoder pass of its own.
         Settings.Detect_From_Window := True;
         Settings.Initial_Prompt := Owner.Wanted.Initial_Prompt;
         declare
            Room : constant Recording_Buffer := Owner.Common.Buffer;
         begin
            W.Transcribe
              (Owner.Session, Room (0 .. Owner.Common.Samples_Held - 1), Settings, Heard, Status,
               Cancel => Owner.Stop_Hearing'Unchecked_Access);
         end;
         if not Owner.Wanted.Keep_Loaded then
            Unload_All;
         end if;
         Owner.Common.Set (if Owner.Common.Is_Loaded then Ready else Unloaded);
         Owner.Common.Set_Result
           ((if E.Is_Ok (Status) then Heard.Text else Null_Unbounded_String),
            (if E.Is_Ok (Status) and then E.Is_Error (Captured) then Captured else Status));
      end Hear;
   begin
      loop
         Owner.Common.Next_Inference (Work);
         exit when Work = Quit;
         begin
            case Work is
               when Load =>
                  declare
                     Status : E.Error_Info;
                  begin
                     Load (Status);
                     --  A load that failed while recording is told when the
                     --  recording is heard, and tried again then.
                     pragma Unreferenced (Status);
                  end;
               when Hear =>
                  Hear;
               when Unload_Model =>
                  Owner.Common.Set (Unloading);
                  Unload_All;
                  Owner.Common.Set (Unloaded);
               when None | Begin_Recording | Quit =>
                  null;
            end case;
         exception
            when Failure : others =>
               Owner.Common.Set (if Owner.Common.Is_Loaded then Ready else Failed);
               Owner.Common.Set_Result (Null_Unbounded_String, E.Unexpected (Failure, "speech"));
         end;
      end loop;
      Unload_All;
   end Inference_Task;

   ------------
   -- Create --
   ------------

   function Create (With_Settings : Settings) return Recognizer_Access is
      Result : constant Recognizer_Access := new Recognizer;
      Seconds : constant Positive := Positive'Min (With_Settings.Max_Seconds, Max_Recording_Seconds);
   begin
      Result.Wanted := With_Settings;
      Result.Common.Set (if Length (With_Settings.Model_Path) = 0 then Disabled else Unloaded);
      if Length (With_Settings.Model_Path) > 0 then
         Result.Common.Configure (N.Element_Count (Seconds) * Model_Runner.Audio.Canonical_Rate);
      end if;
      return Result;
   end Create;

   --------------
   -- Shutdown --
   --------------

   procedure Shutdown (Item : in out Recognizer_Access) is
   begin
      if Item = null then
         return;
      end if;
      Item.Stop_Hearing.Request;
      Item.Common.Request_Stop;
      Item.Common.Post_Capture (Quit);
      Item.Common.Post_Inference (Quit);
      while not (Item.Capture'Terminated and then Item.Inference'Terminated) loop
         delay 0.01;
      end loop;
      Item.Common.Release_Buffer;
      Free (Item);
   end Shutdown;

   -------------
   -- Current --
   -------------

   function Current (Item : Recognizer) return State is (Item.Common.Now);

   -----------
   -- Start --
   -----------

   procedure Start (Item : in out Recognizer; Status : out E.Error_Info) is
      Now : constant State := Item.Common.Now;
   begin
      Status := E.Success;
      if Now = Disabled then
         Status := E.Make (E.Lifecycle_Speech_Disabled);
         return;
      end if;
      if Now in Recording | Transcribing | Loading | Unloading or else Item.Common.Result_Ready then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text (Status, "state", Image (Now), E.Param_Identifier);
         return;
      end if;
      Item.Stop_Hearing.Reset;
      Item.Common.Post_Capture (Begin_Recording);
      Item.Common.Set (Recording);
      if not Item.Common.Is_Loaded then
         Item.Common.Post_Inference (Load);
      end if;
   end Start;

   function Recorded_Seconds (Item : Recognizer) return Duration is
     (Duration (Item.Common.Samples_Held) / Duration (Model_Runner.Audio.Canonical_Rate));

   function Recording_Ended (Item : Recognizer) return Boolean is
     (Item.Common.Now = Recording and then Item.Common.Capture_Is_Over);

   ------------
   -- Finish --
   ------------

   procedure Finish (Item : in out Recognizer; Status : out E.Error_Info) is
   begin
      Status := E.Success;
      if Item.Common.Now /= Recording then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text (Status, "state", Image (Item.Common.Now), E.Param_Identifier);
         return;
      end if;
      Item.Common.Request_Stop;
      Item.Common.Set (Transcribing);
      Item.Common.Post_Inference (Hear);
   end Finish;

   ------------
   -- Cancel --
   ------------

   procedure Cancel (Item : in out Recognizer) is
   begin
      case Item.Common.Now is
         when Recording =>
            Item.Common.Request_Stop;
            --  The capture stops within a tenth of a second; what it held
            --  is forgotten, and no result is left to take.
            while not Item.Common.Capture_Is_Over loop
               delay 0.01;
            end loop;
            declare
               Text : Unbounded_String;
               Ignored : E.Error_Info;
               Limit : Boolean;
            begin
               Item.Common.Take_Result (Text, Ignored, Limit);
            end;
            Item.Common.Set (if Item.Common.Is_Loaded then Ready else Unloaded);
         when Transcribing =>
            Item.Stop_Hearing.Request;
         when others =>
            null;
      end case;
   end Cancel;

   function Has_Result (Item : Recognizer) return Boolean is (Item.Common.Result_Ready);

   ----------
   -- Take --
   ----------

   procedure Take
     (Item          : in out Recognizer;
      Text          : out Unbounded_String;
      Status        : out E.Error_Info;
      Limit_Reached : out Boolean) is
   begin
      Item.Common.Take_Result (Text, Status, Limit_Reached);
   end Take;

   ------------
   -- Unload --
   ------------

   procedure Unload (Item : in out Recognizer; Status : out E.Error_Info) is
      Now : constant State := Item.Common.Now;
   begin
      Status := E.Success;
      if Now in Recording | Transcribing | Loading then
         Status := E.Make (E.Lifecycle_Invalid_State);
         E.Add_Text (Status, "state", Image (Now), E.Param_Identifier);
         return;
      end if;
      if Item.Common.Is_Loaded then
         Item.Common.Set (Unloading);
         Item.Common.Post_Inference (Unload_Model);
      end if;
   end Unload;

end Model_Runner.Speech;
