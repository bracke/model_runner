with Ada.Characters.Latin_1;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;

package body Model_Runner.Backend.Device is

   use type System.Address;
   use type System.Storage_Elements.Integer_Address;

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Bytes.Byte_Count;
   use type Interfaces.Unsigned_64;

   package Devices renames Model_Runner.Platform.Device;
   package Products renames Model_Runner.Platform.Device.Products;
   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Tensors;

   --  One device, held for the program. A backend is chosen once for a run
   --  and the device it names outlives every product on it, so there is
   --  nothing here for a second one to be.
   Held   : Devices.Inventory;
   Opened : Devices.Context;
   Engine : Products.Engine;

   Ready_Now : Boolean := False;

   --  The layers' outcomes, as Note_Layer counts them.
   Whole_Count  : Natural := 0;
   Handed_Count : Natural := 0;
   Handed_First : Handing := Not_Handed;

   --  And how often a session was turned out of a block of the cache or a
   --  seat in the room of rings to give it to another.
   Turned_Blocks : Natural := 0;
   Turned_Rings  : Natural := 0;

   --  And how often one was moved to close a gap below it.
   Moved_Blocks : Natural := 0;
   Moved_Rings  : Natural := 0;

   --  What the last whole layer asked for that this device will not do,
   --  found before the sequence is built: a sequence refused while it is
   --  built never reaches the engine's Run, so what Run says of it is the
   --  layer before's.
   Layer_Refusal : Handing := Not_Handed;

   --  Room for what a fused half-layer hands the device and takes back: a
   --  row's queries and a row's residual, for every row of the call.
   --
   --  Held here rather than declared in the procedure because it is sixteen
   --  kilobytes a row for a small model, and a round carrying a joining
   --  member's prompt is hundreds of rows: on the stack that is megabytes,
   --  and the stack said so. Grown to the largest call seen and kept, which
   --  is one allocation for a run rather than one a layer.
   Fed_Room : T.Real_Array_Access := null;

   --  Whether this device was opened to read the weights where they lie.
   --  Held here because Describe is asked about a device that is already
   --  open and has to answer for how it was opened.
   Sharing : Boolean := False;

   --  And how much of the device's memory it was opened for, for the same
   --  reason and for one more: a second Open asking for something different
   --  has to get it.
   Opened_Budget : Interfaces.Unsigned_64 := 0;

   --  And how it was opened to wait, for the same reason.
   Opened_Slice    : Duration := 0.020;
   Opened_Patience : Duration := 60.0;

   --  Which device the open one is, for the same reason the settings above
   --  are kept: an Open naming a different device must not be answered with
   --  this one.
   Opened_Which : Positive := 1;

   Named      : String (1 .. Devices.Max_Name_Bytes) := [others => ' '];
   Named_Last : Natural := 0;

   --  Which packing a format is uploaded and decoded as.
   --
   --  Declared here because Describe asks it as well: what the backend says
   --  it reads is what this has an arm for, and a second list would be a
   --  second place for the two to disagree.
   --
   --  @param Format Element format as the file names it.
   --  @param Packing The shader's name for that layout.
   --  @param Known False when the shader has no branch for it.
   procedure Packing_Of
     (Format  : Model_Runner.GGUF.Tensor_Type;
      Packing : out Products.Weight_Packing;
      Known   : out Boolean);

   --------------
   -- Describe --
   --------------

   --  Somewhere to put three results before they are handed out separately.
   --
   --  A sequence fills one array, product after product, because that is
   --  what one result buffer read back once gives. The three targets a layer
   --  has are three separate arrays, so the run lands here and is copied out.
   --  The copy is a few thousand values against two submissions and two
   --  fence waits saved, which is why it is a copy and not a reason to give
   --  every product its own buffer.
   Landing : T.Real_Array_Access := null;

   --  The timeline Keep_Timeline keeps: sums of the device's stamps by the
   --  shape of the sequence. A shape is the steps, described as Products
   --  describes them, and the positions the run was for to within a
   --  doubling -- a prompt's experts are each run for however many
   --  positions chose them, and a shape a count would be one a run.
   --  Sixteen is more shapes than a model runs, and a seventeenth is
   --  counted and not summed.
   Shape_Limit : constant := 16;
   Label_Limit : constant := 40;

   --  Which doubling a count of positions is in: one, two and three, four
   --  to seven, and so on.
   function Band (Count : Positive) return Natural is
      Result : Natural := 0;
      Left   : Positive := Count;
   begin
      while Left > 1 loop
         Left := Left / 2;
         Result := Result + 1;
      end loop;
      return Result;
   end Band;

   subtype Step_Label is String (1 .. Label_Limit);
   type Label_Array is array (1 .. Products.Sequence_Limit) of Step_Label;
   type Length_Array is array (1 .. Products.Sequence_Limit) of Natural;

   type Shape_Sums is record
      Held      : Natural := 0;
      Positions : Natural := 0;
      Least     : Natural := 0;
      Most      : Natural := 0;
      Runs      : Natural := 0;
      Labels    : Label_Array := [others => [others => ' ']];
      Lengths   : Length_Array := [others => 0];
      Sums      : Products.Step_Times := [others => 0.0];
      Whole     : Float := 0.0;
   end record;

   type Shape_Array is array (1 .. Shape_Limit) of Shape_Sums;

   Timing       : Boolean := False;
   Shapes       : Shape_Array;
   Shapes_Held  : Natural := 0;
   Shapes_Lost  : Natural := 0;

   --  Add what the engine's last run stamped to the shape it belongs to.
   procedure Note_Timeline (Steps : Products.Sequence; Count : Positive) is
      Line : constant Products.Timeline := Products.Last_Timeline (Engine);

      Labels  : Label_Array := [others => [others => ' ']];
      Lengths : Length_Array := [others => 0];
      Found   : Natural := 0;
   begin
      if not Timing or else Line.Held = 0
        or else Line.Held /= Products.Length (Steps)
      then
         return;
      end if;

      for Index in 1 .. Line.Held loop
         declare
            Text : constant String := Products.Describe (Steps, Index);
            Up   : constant Natural := Natural'Min (Text'Length, Label_Limit);
         begin
            Labels (Index) (1 .. Up) := Text (Text'First .. Text'First + Up - 1);
            Lengths (Index) := Up;
         end;
      end loop;

      for Shape in 1 .. Shapes_Held loop
         if Shapes (Shape).Held = Line.Held
           and then Shapes (Shape).Positions = Band (Count)
           and then Shapes (Shape).Labels = Labels
         then
            Found := Shape;
            exit;
         end if;
      end loop;

      if Found = 0 then
         if Shapes_Held = Shape_Limit then
            Shapes_Lost := Shapes_Lost + 1;
            return;
         end if;
         Shapes_Held := Shapes_Held + 1;
         Found := Shapes_Held;
         Shapes (Found) :=
           (Held => Line.Held, Positions => Band (Count), Least => Count,
            Most => Count, Labels => Labels, Lengths => Lengths,
            others => <>);
      end if;

      Shapes (Found).Least := Natural'Min (Shapes (Found).Least, Count);
      Shapes (Found).Most := Natural'Max (Shapes (Found).Most, Count);
      Shapes (Found).Runs := Shapes (Found).Runs + 1;
      Shapes (Found).Whole := Shapes (Found).Whole + Line.Whole;
      for Index in 1 .. Line.Held loop
         Shapes (Found).Sums (Index) :=
           Shapes (Found).Sums (Index) + Line.Steps (Index);
      end loop;
   end Note_Timeline;

   --  Whether a token should attend out of the copy, kept for an engine
   --  opened after it was asked.
   Halves_Wanted : Boolean := False;

   procedure Attend_In_Halves (On : Boolean) is
   begin
      Halves_Wanted := On;

      if Ready_Now then
         Products.Prefer_Halves (Engine, On);
      end if;
   end Attend_In_Halves;

   function Attends_In_Halves return Boolean
   is (Ready_Now and then Products.Prefers_Halves (Engine));

   procedure Attend_Exactly (On : Boolean) is
   begin
      if Ready_Now then
         Products.Prefer_Exact_Attention (Engine, On);
      end if;
   end Attend_Exactly;

   function Attends_Exactly return Boolean
   is (Ready_Now and then Products.Prefers_Exact_Attention (Engine));

   procedure Keep_Timeline (On : Boolean) is
      Ok : Boolean := True;
   begin
      Timing := On;
      Shapes_Held := 0;
      Shapes_Lost := 0;

      if Ready_Now then
         Products.Time_Steps (Engine, On, Ok);
      end if;

      if not Ok then
         Timing := False;
      end if;
   end Keep_Timeline;

   function Timeline_Report return String is
      use Ada.Strings.Unbounded;

      Text : Unbounded_String;

      --  A number of microseconds with one decimal, and a whole number,
      --  without the space 'Image puts in front.
      function Micro (Value : Float) return String is
         Tenths : constant Natural :=
           Natural (Float'Max (Value, 0.0) * 10.0);
         Whole  : constant String := Natural'Image (Tenths / 10);
         Part   : constant String := Natural'Image (Tenths mod 10);
      begin
         return Whole (Whole'First + 1 .. Whole'Last) & "."
           & Part (Part'First + 1 .. Part'Last);
      end Micro;

      function Plain (Value : Natural) return String is
         Whole : constant String := Natural'Image (Value);
      begin
         return Whole (Whole'First + 1 .. Whole'Last);
      end Plain;
   begin
      if Shapes_Held = 0 then
         return (if Timing then "device timeline: nothing was run"
                 else "device timeline: not kept");
      end if;

      for Shape in 1 .. Shapes_Held loop
         declare
            This : Shape_Sums renames Shapes (Shape);
            Runs : constant Float := Float (This.Runs);
         begin
            Append
              (Text,
               Plain (This.Runs) & " runs of " & Plain (This.Held)
               & " steps at " & Plain (This.Least)
               & (if This.Most > This.Least
                  then " to " & Plain (This.Most) & " positions"
                  elsif This.Least = 1 then " position" else " positions")
               & ": " & Micro (This.Whole / Runs) & " us a run"
               & Ada.Characters.Latin_1.LF);

            for Index in 1 .. This.Held loop
               Append
                 (Text,
                  "  " & Plain (Index) & " "
                  & This.Labels (Index) (1 .. This.Lengths (Index)) & ": "
                  & Micro (This.Sums (Index) / Runs) & " us"
                  & (if This.Whole > 0.0
                     then " (" & Plain (Natural (This.Sums (Index)
                                                  / This.Whole * 100.0))
                          & "%)"
                     else "")
                  & Ada.Characters.Latin_1.LF);
            end loop;
         end;
      end loop;

      if Shapes_Lost > 0 then
         Append (Text, Plain (Shapes_Lost)
                 & " runs of other shapes were not summed"
                 & Ada.Characters.Latin_1.LF);
      end if;

      --  And the whole of it: what the device was busy for across every
      --  run summed, against which a wall clock says what the host's
      --  share was.
      declare
         Busy : Float := 0.0;
         Runs : Natural := 0;
      begin
         for Shape in 1 .. Shapes_Held loop
            Busy := Busy + Shapes (Shape).Whole;
            Runs := Runs + Shapes (Shape).Runs;
         end loop;

         Append (Text, "device busy " & Micro (Busy / 1000.0) & " ms in "
                 & Plain (Runs) & " runs" & Ada.Characters.Latin_1.LF);
      end;

      return To_String (Text);
   end Timeline_Report;

   --  A sequence run on the engine, its answer left in Landing. Declared
   --  here because the single product below is one of these.
   procedure Run_Sequence
     (Steps  : Products.Sequence;
      Vector : T.Real_Array_Access;
      Count  : Positive;
      Wanted : Model_Runner.Numerics.Element_Count;
      Asked  : Interfaces.Unsigned_64;
      Status : out E.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference);

   function Describe return Capabilities is
      Result : Capabilities;
   begin
      Result.Kind := Backend_Device;

      --  Every format the shader decodes for itself, which is every format
      --  this program reads. It was three, and the other twelve reached a
      --  device only through --repack f32: a pass over the whole model at
      --  load and four bytes a weight afterwards, which for a k-quant model
      --  is four times the memory it was quantized to avoid.
      --
      --  Read from the mapping that reaches the shader's branches rather
      --  than listed here, because a list here is a second copy of one: the
      --  two lists that have to agree are the shader's branches and this,
      --  and the test that compares them multiplies a matrix in each format
      --  on the device.
      --
      --  It used to be read from Is_Supported, which says what the program
      --  reads rather than what the shader does. Those were the same set for
      --  as long as the two decoders were written together, and MXFP4 is
      --  where they parted for a while: it arrived with an Ada decoder and
      --  no shader branch, and this claimed it. A model carrying one then
      --  passed the loader's check and was refused inside the first product
      --  instead -- as a missing capability, with no tensor named, because
      --  a view arriving there carries none. Asked of Packing_Of, a format
      --  the shader lacks is refused where every other format a backend
      --  cannot take is refused: while the model loads, by name, with the
      --  backend named. The shader decodes MXFP4 now and the two sets are
      --  the same again; the mapping stays the source, so the next format
      --  to arrive one-sided is refused rather than claimed.
      Result.Formats := [others => False];
      for Format in Model_Runner.GGUF.Tensor_Type loop
         declare
            Packing : Products.Weight_Packing;
            Known   : Boolean;
         begin
            Packing_Of (Format, Packing, Known);
            Result.Formats (Format) := Known;
            pragma Unreferenced (Packing);
         end;
      end loop;

      --  A packed row begins at a block boundary and a block is not four
      --  bytes long, so what the shader needs from the storage is that a
      --  matrix begins somewhere it can address, not that a row does.
      Result.Alignment := 4;
      Result.Supports_Matrix_Vector := True;

      --  A batch, because that is where a device earns its place: one
      --  reading of the weights for every vector of a prompt rather than one
      --  each.
      Result.Supports_Batched := True;
      Result.Supports_Parallel := False;
      Result.Max_Workers := 1;

      --  What the open device will hold, which is nothing at all when none
      --  is open: this is asked while a model prepares, and by then the
      --  caller has opened one or has been told it could not.
      --
      --  And nothing to answer for when the weights are being read where
      --  they lie: there is no size a model has to be under, because none
      --  of it is going into the device's own memory.
      Result.Memory_Bytes :=
        (if Sharing then 0 else Products.Capacity (Engine));

      return Result;
   end Describe;

   ----------
   -- Open --
   ----------

   procedure Open
     (Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0;
      Which      : Positive := 1)
   is
      Found : Boolean;
   begin
      --  An open device is kept only when it was opened for what is being
      --  asked for now. It used to be kept whatever was asked: a second
      --  Open with a different budget, or with the weights to be read where
      --  they lie rather than copied, was answered with the first one's
      --  device and its policy, and said nothing.
      --
      --  One process runs one model in this program, so the shipped path
      --  never met it -- which is exactly why it survived. A test that runs
      --  three --device-memory settings in one process met it at once, and
      --  read the first setting's statistics three times.
      if Ready_Now
        and then Opened_Budget = Budget
        and then Sharing = Share_Host
        and then Opened_Slice = Slice
        and then Opened_Patience = Patience
        and then Opened_Which = Which
      then
         Ready := True;
         return;
      end if;

      Close;
      Ready := False;

      Devices.Open (Held, Found);
      if not Found or else Devices.Count (Held) = 0 then
         return;
      end if;

      --  The device the caller named, counting from one in the order the
      --  host names them, and the first of them when the caller named none.
      --  Out of range is a refusal: a caller that asked for the second
      --  device and silently got the first would be told the wrong thing
      --  about what its figures describe.
      if Which > Devices.Count (Held) then
         return;
      end if;

      Devices.Open (Opened, Held, Which, Found);
      if not Found then
         return;
      end if;

      Products.Open (Engine, Opened, Found, Budget, Share_Host,
                     Slice, Patience);
      if not Found then
         Devices.Close (Opened);
         return;
      end if;

      declare
         Text : constant String := Devices.Name (Held, 1);
      begin
         Named_Last := Natural'Min (Text'Length, Named'Length);
         Named (1 .. Named_Last) :=
           Text (Text'First .. Text'First + Named_Last - 1);
      end;

      --  A timeline asked for before the engine was is kept from here,
      --  and the copy preferred before it was is read from here.
      if Timing then
         Products.Time_Steps (Engine, True, Timing);
      end if;

      if Halves_Wanted then
         Products.Prefer_Halves (Engine, True);
      end if;

      Sharing := Share_Host;
      Opened_Which := Which;
      Opened_Budget := Budget;
      Opened_Slice := Slice;
      Opened_Patience := Patience;
      Ready_Now := True;
      Ready := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close is
   begin
      T.Free (Landing);
      T.Free (Fed_Room);
      Products.Close (Engine);
      Devices.Close (Opened);
      Devices.Close (Held);
      Ready_Now := False;
      Sharing := False;
      Named_Last := 0;
      Whole_Count := 0;
      Handed_Count := 0;
      Handed_First := Not_Handed;
      Turned_Blocks := 0;
      Turned_Rings := 0;
      Moved_Blocks := 0;
      Moved_Rings := 0;
   end Close;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready return Boolean is (Ready_Now);

   ----------
   -- Name --
   ----------

   function Name return String is (Named (1 .. Named_Last));

   --------------
   -- Resident --
   --------------

   function Resident return Natural is (Products.Resident (Engine));

   function Resident_Limit return Natural
   is (Products.Max_Resident);

   ---------------------
   -- Resident_Bytes --
   ---------------------

   function Resident_Bytes return Interfaces.Unsigned_64
   is (Products.Resident_Bytes (Engine));

   ---------------
   -- Imported --
   ---------------

   function Shares_Host return Boolean is (Sharing);

   function Imported return Natural is (Products.Imported (Engine));

   -----------------
   -- Given_Back --
   -----------------

   function Given_Back return Natural is (Products.Given_Back (Engine));

   ----------------
   -- Note_Layer --
   ----------------

   procedure Note_Layer
     (Whole : Boolean;
      Asked : Boolean := False;
      Cache : Boolean := False;
      Held  : Boolean := False) is
   begin
      if Whole then
         Whole_Count := Whole_Count + 1;
         return;
      end if;

      Handed_Count := Handed_Count + 1;

      if Handed_First = Not_Handed then
         Handed_First :=
           (if Held then Blocks_Handed
            elsif Cache then Cache_Handed
            elsif not Asked then Shape_Handed
            elsif Layer_Refusal /= Not_Handed then Layer_Refusal
            else (case Products.Last_Refusal (Engine) is
                     when Products.Packed_Refused => Packed_Handed,
                     when Products.Cache_Refused  => Cache_Handed,
                     when Products.Room_Refused   => Room_Handed,
                     when Products.Shape_Refused  => Refused_Handed,

                     --  A sequence that never reached Run: what refused
                     --  it is one of the shapes it is built from.
                     when Products.Not_Refused    => Shape_Handed));
      end if;
   end Note_Layer;

   function Layers_Whole return Natural is (Whole_Count);

   function Layers_Handed return Natural is (Handed_Count);

   function First_Handing return Handing is (Handed_First);

   -----------------
   -- Note_Turned --
   -----------------

   procedure Note_Turned (Ring : Boolean := False) is
   begin
      if Ring then
         Turned_Rings := Turned_Rings + 1;
      else
         Turned_Blocks := Turned_Blocks + 1;
      end if;
   end Note_Turned;

   function Blocks_Turned return Natural is (Turned_Blocks);

   function Rings_Turned return Natural is (Turned_Rings);

   ----------------
   -- Move_Cache --
   ----------------

   procedure Move_Cache
     (From   : Model_Runner.Numerics.Element_Count;
      Into   : Model_Runner.Numerics.Element_Count;
      Runs   : Block_Runs;
      Halves : Boolean;
      Ok     : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Move_Cache (Engine, From, Into, Runs, Halves, Ok);
   end Move_Cache;

   ----------------
   -- Move_State --
   ----------------

   procedure Move_State
     (From     : Model_Runner.Numerics.Element_Count;
      Into     : Model_Runner.Numerics.Element_Count;
      Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Move_State (Engine, From, Into, Elements, Ok);
   end Move_State;

   ----------------
   -- Note_Moved --
   ----------------

   procedure Note_Moved (Ring : Boolean := False) is
   begin
      if Ring then
         Moved_Rings := Moved_Rings + 1;
      else
         Moved_Blocks := Moved_Blocks + 1;
      end if;
   end Note_Moved;

   function Blocks_Moved return Natural is (Moved_Blocks);

   function Rings_Moved return Natural is (Moved_Rings);

   function Cached_Bytes return Interfaces.Unsigned_64
   is (Products.Cached_Bytes (Engine));

   function State_Room_Bytes return Interfaces.Unsigned_64
   is (Products.State_Room_Bytes (Engine));

   function Cached_Elements return Model_Runner.Numerics.Element_Count
   is (Products.Cached_Elements (Engine));

   function Queues return Natural is (Devices.Queue_Count (Opened));

   function Waited return Natural is (Products.Waited (Engine));

   ------------------------
   -- Forget_Matrices --
   ------------------------

   procedure Forget_Matrices is
   begin
      if Products.Is_Ready (Engine) then
         Products.Forget_Matrices (Engine);
      end if;
   end Forget_Matrices;

   ---------------
   -- Packing_Of --
   ---------------

   --  How the device should read a view's bytes, and whether it can.
   procedure Packing_Of
     (Format  : Model_Runner.GGUF.Tensor_Type;
      Packing : out Products.Weight_Packing;
      Known   : out Boolean) is
   begin
      Packing := Products.Values_F32;
      Known := True;

      --  One arm per format the shader decodes, which is every format this
      --  program reads. The others in Tensor_Type are the ones the parser
      --  recognizes and nothing here decodes -- Q8_1, Q8_K -- and a model in
      --  one of those is refused before it reaches a backend at all.
      case Format is
         when Model_Runner.GGUF.Type_F32     =>
            Packing := Products.Values_F32;
         when Model_Runner.GGUF.Type_F16     =>
            Packing := Products.Values_F16;
         when Model_Runner.GGUF.Type_BF16    =>
            Packing := Products.Values_BF16;

         when Model_Runner.GGUF.Type_Q4_0    =>
            Packing := Products.Packed_Q4_0;
         when Model_Runner.GGUF.Type_Q4_1    =>
            Packing := Products.Packed_Q4_1;
         when Model_Runner.GGUF.Type_Q5_0    =>
            Packing := Products.Packed_Q5_0;
         when Model_Runner.GGUF.Type_Q5_1    =>
            Packing := Products.Packed_Q5_1;
         when Model_Runner.GGUF.Type_Q8_0    =>
            Packing := Products.Packed_Q8_0;
         when Model_Runner.GGUF.Type_IQ4_NL  =>
            Packing := Products.Packed_IQ4_NL;

         when Model_Runner.GGUF.Type_Q2_K    =>
            Packing := Products.Packed_Q2_K;
         when Model_Runner.GGUF.Type_Q3_K    =>
            Packing := Products.Packed_Q3_K;
         when Model_Runner.GGUF.Type_Q4_K    =>
            Packing := Products.Packed_Q4_K;
         when Model_Runner.GGUF.Type_Q5_K    =>
            Packing := Products.Packed_Q5_K;
         when Model_Runner.GGUF.Type_Q6_K    =>
            Packing := Products.Packed_Q6_K;
         when Model_Runner.GGUF.Type_IQ4_XS  =>
            Packing := Products.Packed_IQ4_XS;

         when Model_Runner.GGUF.Type_MXFP4   =>
            Packing := Products.Packed_MXFP4;

         when others =>
            Known := False;
      end case;
   end Packing_Of;

   --------------
   -- Products --
   --------------

   --  One matrix against however many vectors, which is what both of the
   --  public operations are. Written once because the checks are the same
   --  and a second copy of them is a second place for one to be missing.

   --  Where a tensor begins, as an address. A view says where its buffer is
   --  and how far into it the tensor starts; the device wants the two added,
   --  as the name it keeps a resident matrix under.
   function At_Offset
     (Base : System.Address; Offset : Model_Runner.Bytes.Byte_Count)
      return System.Address
   is (System.Storage_Elements.To_Address
         (System.Storage_Elements.To_Integer (Base)
          + System.Storage_Elements.Integer_Address (Offset)));

   --  Why a product that did not run did not run.
   --
   --  This backend has one operation and the device has it, so a product
   --  that comes back unrun is a fact about the request rather than about
   --  what the backend can do. Where the request is larger than the device
   --  said it would read, that is nameable and is named. This used to
   --  report the capability matrix_vector as missing, which sent a reader
   --  looking for a device feature that was there all along -- and every
   --  model whose output projection is wider than an invented bound came
   --  here to be told it.
   procedure Declined
     (Status : out E.Error_Info;
      Needed : Interfaces.Unsigned_64 := 0)
   is
      Limit : constant Interfaces.Unsigned_64 := Products.Byte_Limit (Engine);
   begin
      if Limit > 0 and then Needed > Limit then
         Status := E.Make (E.Backend_Product_Too_Large);
         E.Add_Integer (Status, "requested", Long_Long_Integer (Needed));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Limit));
      else
         Status := E.Make (E.Backend_Device_Refused);
      end if;

      E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                  E.Param_Identifier);
   end Declined;

   procedure Compute
     (Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Exact   : Boolean := False)
   is
      Packing   : Products.Weight_Packing;
      Known     : Boolean;

      --  The largest buffer this product asks the device for, which is what
      --  a refusal has to be able to name.
      Asked     : Interfaces.Unsigned_64 := 0;
   begin
      Status := E.Success;

      if not Ready_Now then
         --  Closed rather than invalid-state. The state message names the
         --  session it is about and this is not about a session, so the
         --  parameter it wanted was never attached and the whole diagnostic
         --  came out as its own key in angle brackets.
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Packing_Of (Weight.Format, Packing, Known);
      if not Known then
         --  A missing capability rather than an unsupported format, and the
         --  difference is which of them can be said. The format message
         --  names the tensor that carries it, which is knowable while a
         --  model loads and is what refuses a model there; a view arriving
         --  here carries no name, so that message could not be rendered and
         --  this one can.
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text
           (Status, "capability",
            Model_Runner.GGUF.Type_Name (Weight.Format), E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         return;
      end if;

      if Vectors = null or else Target = null
        or else Count = 0
        or else Weight.Base = System.Null_Address
        or else Vectors.all'Length < Count * Weight.Columns
        or else Target.all'Length < Count * Weight.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      --  The weights as they are stored. A view is a run of bytes at a known
      --  offset whatever the packing, so what the device is handed is the
      --  model's own storage -- no copy on this side of the interface, and
      --  for a packed model no decoded copy anywhere.
      declare
         Wide : constant Interfaces.Unsigned_64 :=
           Products.Row_Bytes (Packing, Natural (Weight.Columns));

         Bytes : constant Model_Runner.Bytes.Byte_Count :=
           Model_Runner.Bytes.Byte_Count (Weight.Rows)
           * Model_Runner.Bytes.Byte_Count (Wide);
      begin
         if Wide = 0
           or else Weight.Span < Weight.Offset + Bytes
         then
            Status := E.Make (E.Tensor_Shape_Mismatch);
            return;
         end if;

         Asked := Interfaces.Unsigned_64 (Bytes);

         --  The whole storage, and where in it this matrix begins. Not the
         --  matrix alone: a device reading the weights where they lie is
         --  handed a page-aligned range, and a range described by the matrix
         --  alone would be one nobody could check the ends of.
         --  As a sequence of one, which computes what the single call
         --  computes to the bit and is what the timeline sees: a model's
         --  output head is the one product a token runs outside its
         --  layers, and a token's device time was read without it.
         declare
            Storage : Model_Runner.Bytes.Byte_Array (1 .. Weight.Span)
              with Import, Address => Weight.Base;

            Steps  : Products.Sequence;
            Added  : Boolean;
            Wanted : constant Model_Runner.Numerics.Element_Count :=
              Count * Weight.Rows;
         begin
            --  A stop already standing costs the device nothing, and it
            --  is answered before anything is uploaded or recorded, as
            --  the single call answered it; one that arrives during the
            --  wait is answered between its slices.
            if Model_Runner.Cancellation."/=" (Cancel, null)
              and then Cancel.all.Is_Requested
            then
               Status := E.Make (E.Generation_Cancelled);
               return;
            end if;

            Products.Open_Sequence (Steps);
            Products.Add_Product
              (Steps, Weight.Base, Weight.Span, Weight.Offset, Packing,
               Natural (Weight.Rows), Natural (Weight.Columns), Added,
               Key => Storage (Storage'First + Weight.Offset)'Address,
               Exact => Exact);

            if not Added then
               Declined (Status, Asked);
               return;
            end if;

            Run_Sequence
              (Steps, Vectors, Positive (Count), Wanted, Asked, Status,
               Cancel);

            if E.Is_Ok (Status) then
               Target.all (Target.all'First .. Target.all'First + Wanted - 1)
                 := Landing.all
                      (Landing.all'First .. Landing.all'First + Wanted - 1);
            end if;

         end;
      end;
   end Compute;

   --------------
   -- Dispatch --
   --------------

   procedure Dispatch
     (Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null) is
   begin
      Compute (Weight, Vector, 1, Target, Status, Cancel);
   end Dispatch;

   -------------------
   -- Reserve_Cache --
   -------------------

   procedure Reserve_Cache
     (Elements  : Model_Runner.Numerics.Element_Count;
      Copy_Upto : Model_Runner.Numerics.Element_Count;
      Ok        : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Reserve (Engine, Elements, Copy_Upto, Ok);
   end Reserve_Cache;

   -------------------
   -- Release_Cache --
   -------------------

   procedure Release_Cache is
   begin
      if Ready_Now then
         Products.Release_Cache (Engine);
      end if;
   end Release_Cache;

   ------------------------
   -- Release_State_Room --
   ------------------------

   procedure Release_State_Room is
   begin
      if Ready_Now then
         Products.Release_State_Room (Engine);
      end if;
   end Release_State_Room;

   -----------------
   -- Clear_State --
   -----------------

   procedure Clear_State
     (At_Value : Model_Runner.Numerics.Element_Count;
      Count    : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Clear_State (Engine, At_Value, Count, Ok);
   end Clear_State;

   -----------------
   -- Cache_Bound --
   -----------------

   function Cache_Bound return Interfaces.Unsigned_64
   is (if Ready_Now then Products.Byte_Limit (Engine) else 0);

   --------------------
   -- Cache_Bytes_For --
   --------------------

   function Cache_Bytes_For
     (Elements : Model_Runner.Numerics.Element_Count)
      return Interfaces.Unsigned_64
   is (Interfaces.Unsigned_64 (Elements) * 4);

   ---------------
   -- Put_Table --
   ---------------

   procedure Put_Table
     (At_Value : Model_Runner.Numerics.Element_Count;
      Words    : Word_List;
      Ok       : out Boolean)
   is
      Held : constant Products.Word_List (Words'Range) :=
        [for Index in Words'Range => Words (Index)];
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Put_Words (Engine, At_Value, Held, Ok);
   end Put_Table;

   ---------------
   -- Put_Cache --
   ---------------

   procedure Put_Cache
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : T.Real_Array;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Put_Cache (Engine, At_Value, Values, Ok);
   end Put_Cache;

   ---------------------
   -- Put_Cache_Bytes --
   ---------------------

   procedure Put_Cache_Bytes
     (At_Byte : Interfaces.Unsigned_64;
      Data    : Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Put_Bytes (Engine, At_Byte, Data, Ok);
   end Put_Cache_Bytes;

   ---------------------
   -- Get_Cache_Bytes --
   ---------------------

   procedure Get_Cache_Bytes
     (At_Byte : Interfaces.Unsigned_64;
      Data    : out Model_Runner.Bytes.Byte_Array;
      Ok      : out Boolean) is
   begin
      if not Ready_Now then
         Data := [others => 0];
         Ok := False;
         return;
      end if;

      Products.Get_Bytes (Engine, At_Byte, Data, Ok);
   end Get_Cache_Bytes;

   --------------------
   -- Attends_Packed --
   --------------------

   function Attends_Packed return Boolean
   is (Ready_Now and then Products.Attends_Packed (Engine));

   function Attends_Packed_Heads
     (Head_Size : Natural; Value_Size : Natural) return Boolean
   is (Ready_Now
       and then Products.Takes_Packed_Heads (Engine, Head_Size, Value_Size));

   function Attention_Head_Room return Natural
   is (if Ready_Now then Products.Attention_Room else 0);

   -------------------
   -- Attend_Packed --
   -------------------

   procedure Attend_Packed
     (K_Bits     : Positive;
      V_Bits     : Positive;
      Query      : T.Real_Array;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Bytes    : Interfaces.Unsigned_64;
      V_Bytes    : Interfaces.Unsigned_64;
      KV_Width   : Natural;
      V_Width    : Natural;
      KS_At      : Natural;
      VS_At      : Natural;
      K_Blocks   : Natural;
      V_Blocks   : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Target     : out T.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Attend_Packed
        (Engine, K_Bits, V_Bits, Query, Heads, Head_Size, Value_Size, Group_Size,
         First, Last, K_Bytes, V_Bytes, KV_Width, V_Width, KS_At, VS_At,
         K_Blocks, V_Blocks, Scale, Cap, Target, Ok, Positions, Window,
         Causal, Max_Bias);
   end Attend_Packed;

   ---------------
   -- Get_Cache --
   ---------------

   procedure Get_Cache
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out T.Real_Array;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Get_Cache (Engine, At_Value, Values, Ok);
   end Get_Cache;

   -------------------
   -- Fetch_Carried --
   -------------------

   procedure Fetch_Carried
     (Into : out Model_Runner.Tensors.Real_Array;
      Ok   : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Fetch_Carried (Engine, Into, Ok);
   end Fetch_Carried;

   -----------------
   -- Runs_Linear --
   -----------------

   function Runs_Linear return Boolean
   is (Ready_Now and then Products.Runs_Linear (Engine));

   -------------------
   -- Reserve_State --
   -------------------

   procedure Reserve_State
     (Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Reserve_State (Engine, Elements, Ok);
   end Reserve_State;

   ---------------
   -- Put_State --
   ---------------

   procedure Put_State
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : Model_Runner.Tensors.Real_Array;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Put_State (Engine, At_Value, Values, Ok);
   end Put_State;

   ---------------
   -- Get_State --
   ---------------

   procedure Get_State
     (At_Value : Model_Runner.Numerics.Element_Count;
      Values   : out Model_Runner.Tensors.Real_Array;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Get_State (Engine, At_Value, Values, Ok);
   end Get_State;

   ------------
   -- Attend --
   ------------

   procedure Attend
     (Query      : T.Real_Array;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Base     : Natural;
      V_Base     : Natural;
      KV_Width   : Natural;
      V_Width    : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Target     : out T.Real_Array;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Attend_Resident
        (Engine, Query, Heads, Head_Size, Value_Size, Group_Size,
         First, Last, K_Base, V_Base, KV_Width, V_Width, Scale, Cap,
         Target, Ok, Positions, Window, Causal, Max_Bias);
   end Attend;

   --  Whether a packed session's batch of this many positions goes
   --  through the matrix instruction, over its layer unpacked into the
   --  copy: the caller offered the unpacking, and the kernel is the one
   --  the batch would take.
   function Through_Matrix
     (Unpacked   : Unpacking_Shape;
      Positions  : Natural;
      Head_Size  : Natural;
      Value_Size : Natural) return Boolean
   is (Unpacked.Cells > 0
       and then Products.Attends_By_Matrix
                  (Engine, Positions, Head_Size, Value_Size));

   --  The two unpacking steps, keys then values, after the step From --
   --  the one that last wrote the packed block, or none.
   procedure Add_Unpacking
     (Steps    : in out Products.Sequence;
      Unpacked : Unpacking_Shape;
      KV_Width : Natural;
      V_Width  : Natural;
      From     : Natural;
      Added    : out Boolean) is
   begin
      Products.Add_Place
        (Steps, KV_Width, KV_Width, 0, Added,
         From_Step => From, Packed => Unpacked.Keys, Unpack => True,
         Cells => Unpacked.Cells,
         Half_At => Interfaces.Unsigned_64 (Unpacked.K_Base)
                    + Products.Copy_At (Engine));
      if not Added then
         return;
      end if;

      Products.Add_Place
        (Steps, V_Width, V_Width, 0, Added,
         From_Step => From, Packed => Unpacked.Values, Unpack => True,
         Cells => Unpacked.Cells,
         Half_At => Interfaces.Unsigned_64 (Unpacked.V_Base)
                    + Products.Copy_At (Engine));
   end Add_Unpacking;

   ------------------------
   -- Attend_And_Project --
   ------------------------

   procedure Attend_And_Project
     (Query      : T.Real_Array;
      Heads      : Natural;
      Head_Size  : Natural;
      Value_Size : Natural;
      Group_Size : Natural;
      First      : Natural;
      Last       : Natural;
      K_Base     : Natural;
      V_Base     : Natural;
      KV_Width   : Natural;
      V_Width    : Natural;
      Scale      : Model_Runner.Numerics.Real;
      Cap        : Model_Runner.Numerics.Real;
      Weight     : T.View;
      Into       : T.Real_Array_Access;
      Ok         : out Boolean;
      Positions  : Natural := 1;
      Window     : Natural := 0;
      Causal     : Boolean := True;
      Max_Bias   : Model_Runner.Numerics.Real := 0.0;
      Packed     : Packed_Cache := Not_Packed;
      Sinks_At   : Natural := 0;
      Pages_At   : Natural := 0;
      Page_Shift : Natural := 0)
   is
      Slots : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Natural'Max (Positions, 1));

      --  What the sequence writes: the blend, then the projection of it.
      --  Both come back in one array because Run fills one, and only the
      --  second half is wanted.
      Blend  : constant Model_Runner.Numerics.Element_Count :=
        Slots * Model_Runner.Numerics.Element_Count (Heads)
        * Model_Runner.Numerics.Element_Count (Value_Size);
      Wanted : constant Model_Runner.Numerics.Element_Count :=
        Blend + Slots * Weight.Rows;

      Steps   : Products.Sequence;
      Packing : Products.Weight_Packing;
      Known   : Boolean;
      Added   : Boolean;
      Halted  : Boolean := False;
   begin
      Ok := False;

      if not Ready_Now or else Into = null
        or else Weight.Base = System.Null_Address
        or else Into.all'Length < Slots * Weight.Rows
        or else Weight.Columns
                  /= Model_Runner.Numerics.Element_Count (Heads)
                     * Model_Runner.Numerics.Element_Count (Value_Size)
      then
         return;
      end if;

      Packing_Of (Weight.Format, Packing, Known);
      if not Known then
         return;
      end if;

      Products.Open_Sequence (Steps);

      --  The blend is read by the projection chained to it and by nothing
      --  here, so it is left on the device rather than copied back for the
      --  slice below to step over.
      Products.Add_Attention
        (Steps, Heads, Head_Size, Value_Size, Group_Size, First, Last,
         K_Base, V_Base, KV_Width, V_Width, Scale, Cap, Added,
         Window => Window, Causal => Causal, Max_Bias => Max_Bias,
         Kept => False, Packed => Packed, Sinks_At => Sinks_At,
         Pages_At => Pages_At, Page_Shift => Page_Shift);
      if not Added then
         return;
      end if;

      --  Chained: the projection reads the blend where it lies, which is
      --  the whole point of naming the two together.
      Products.Add_Chained_Product
        (Steps, Weight.Base, Weight.Span, Weight.Offset, Packing,
         Natural (Weight.Rows), Natural (Weight.Columns), Added,
         Key => At_Offset (Weight.Base, Weight.Offset));
      if not Added then
         return;
      end if;

      if Landing = null or else Landing.all'Length < Wanted then
         T.Free (Landing);
         T.Allocate (Wanted, Landing);
         if Landing = null then
            return;
         end if;
      end if;

      Products.Run
        (Engine, Steps, Query, Natural'Max (Positions, 1),
         Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
         Ok, Halted);

      if Ok then
         Note_Timeline (Steps, Natural'Max (Positions, 1));
      end if;

      if Halted or else not Ok then
         Ok := False;
         return;
      end if;

      Into.all (Into.all'First .. Into.all'First + Slots * Weight.Rows - 1) :=
        Landing.all (Landing.all'First + Blend
                     .. Landing.all'First + Wanted - 1);
   end Attend_And_Project;

   ----------------------
   -- Attend_And_Feed --
   ----------------------

   procedure Attend_And_Feed
     (Query       : T.Real_Array;
      Residual    : T.Real_Array;
      Heads       : Natural;
      Head_Size   : Natural;
      Value_Size  : Natural;
      Group_Size  : Natural;
      First       : Natural;
      Last        : Natural;
      K_Base      : Natural;
      V_Base      : Natural;
      KV_Width    : Natural;
      V_Width     : Natural;
      Scale       : Model_Runner.Numerics.Real;
      Cap         : Model_Runner.Numerics.Real;
      Weight      : T.View;
      Norm_Weight : T.Real_Array;
      Epsilon     : Model_Runner.Numerics.Real;
      Gate        : T.View;
      Up          : T.View;
      Down        : T.View;
      Unit        : Natural;
      Into        : T.Real_Array_Access;
      Ok          : out Boolean;
      Positions   : Natural := 1;
      Window      : Natural := 0;
      Causal      : Boolean := True;
      Max_Bias    : Model_Runner.Numerics.Real := 0.0;
      Table_At    : Natural := 0;
      Packed      : Packed_Cache := Not_Packed;
      Sinks_At    : Natural := 0;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Pages_At   : Natural := 0;
      Page_Shift : Natural := 0)
   is
      Slots : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Natural'Max (Positions, 1));

      Wide  : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Heads)
        * Model_Runner.Numerics.Element_Count (Head_Size);

      --  Every step writes into the one array Run fills, and only the last
      --  of them is wanted here. The rest stay on the device, which is what
      --  the sequence is for.
      Blend   : constant Model_Runner.Numerics.Element_Count :=
        Slots * Model_Runner.Numerics.Element_Count (Heads)
        * Model_Runner.Numerics.Element_Count (Value_Size);
      Rest    : constant Model_Runner.Numerics.Element_Count :=
        Slots * (Weight.Rows          --  the projection
                 + Weight.Rows        --  the first join
                 + Weight.Rows        --  the normalization
                 + Gate.Rows          --  the gating arm
                 + Up.Rows            --  the other arm
                 + Gate.Rows          --  their combination
                 + Down.Rows);        --  the projection down
      Wanted  : constant Model_Runner.Numerics.Element_Count :=
        Blend + Rest + Slots * Down.Rows;

      Fed_Span : constant Model_Runner.Numerics.Element_Count :=
        Slots * (Wide + Weight.Rows);

      Steps   : Products.Sequence;
      Packing : Products.Weight_Packing;
      Gate_P, Up_P, Down_P : Products.Weight_Packing;
      Known   : Boolean;
      Added   : Boolean;
      Halted  : Boolean := False;
   begin
      Ok := False;

      --  Everything this needs to be true, asked once. A caller refused
      --  here does the layer the way it did before, which is two
      --  submissions and the joining and normalizing on the host.
      if not Ready_Now or else Into = null
        or else Weight.Base = System.Null_Address
        or else Norm_Weight'Length
                  /= Model_Runner.Numerics.Element_Count (Weight.Rows)
        or else Gate.Base = System.Null_Address
        or else Up.Base = System.Null_Address
        or else Down.Base = System.Null_Address
        or else Query'Length < Slots * Wide
        or else Residual'Length < Slots * Weight.Rows
        or else Into.all'Length < Slots * Down.Rows
        or else Gate.Columns /= Weight.Rows
        or else Up.Columns /= Weight.Rows
        or else Up.Rows /= Gate.Rows
        or else Down.Columns /= Gate.Rows
        or else Down.Rows /= Weight.Rows
        or else Weight.Columns
                  /= Model_Runner.Numerics.Element_Count (Heads)
                     * Model_Runner.Numerics.Element_Count (Value_Size)
      then
         return;
      end if;

      Packing_Of (Weight.Format, Packing, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Gate.Format, Gate_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Up.Format, Up_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Down.Format, Down_P, Known);
      if not Known then
         return;
      end if;

      Products.Open_Sequence (Steps);

      Products.Add_Attention
        (Steps, Heads, Head_Size, Value_Size, Group_Size, First, Last,
         K_Base, V_Base, KV_Width, V_Width, Scale, Cap, Added,
         Window => Window, Causal => Causal, Max_Bias => Max_Bias,
         Kept => False, Table_At => Table_At, Packed => Packed,
         Sinks_At => Sinks_At,
         Pages_At => Pages_At, Page_Shift => Page_Shift);
      if not Added then
         return;
      end if;

      Products.Add_Chained_Product
        (Steps, Weight.Base, Weight.Span, Weight.Offset, Packing,
         Natural (Weight.Rows), Natural (Weight.Columns), Added,
         Key => At_Offset (Weight.Base, Weight.Offset), Kept => False);
      if not Added then
         return;
      end if;

      --  The residual join. Its residual is the second half of the
      --  activation, which is why the two travel together.
      Products.Add_Join
        (Steps, Added, From_Step => 2,
         From_Vector => Natural (Slots * Wide), Kept => False);
      if not Added then
         return;
      end if;

      declare
         At_Norm : constant System.Address :=
           Norm_Weight (Norm_Weight'First)'Address;
      begin
         Products.Add_Norm
           (Steps, At_Norm,
            Model_Runner.Bytes.Byte_Count (Norm_Weight'Length) * 4, 0,
            Natural (Weight.Rows), Epsilon, Added,
            From_Step => 3, Key => At_Norm,
            Kept => False);
      end;
      if not Added then
         return;
      end if;

      --  Both arms read the normalization, which is not the step before the
      --  second of them.
      Products.Add_Chained_Product
        (Steps, Gate.Base, Gate.Span, Gate.Offset, Gate_P,
         Natural (Gate.Rows), Natural (Gate.Columns), Added,
         Key => At_Offset (Gate.Base, Gate.Offset), Kept => False,
         From_Step => 4);
      if not Added then
         return;
      end if;

      Products.Add_Chained_Product
        (Steps, Up.Base, Up.Span, Up.Offset, Up_P,
         Natural (Up.Rows), Natural (Up.Columns), Added,
         Key => At_Offset (Up.Base, Up.Offset), Kept => False,
         From_Step => 4);
      if not Added then
         return;
      end if;

      Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                        Alpha => Alpha, Limit => Limit);
      if not Added then
         return;
      end if;

      Products.Add_Chained_Product
        (Steps, Down.Base, Down.Span, Down.Offset, Down_P,
         Natural (Down.Rows), Natural (Down.Columns), Added,
         Key => At_Offset (Down.Base, Down.Offset), Kept => False);
      if not Added then
         return;
      end if;

      --  And the second join, whose residual is what the first one wrote.
      Products.Add_Join
        (Steps, Added, From_Step => 8, Residual_Step => 3);
      if not Added then
         return;
      end if;

      --  The queries and the residual, one after the other, in room this
      --  package keeps rather than on the stack: a round carrying a joining
      --  member's prompt is hundreds of rows at sixteen kilobytes each.
      if Fed_Room = null or else Fed_Room.all'Length < Fed_Span then
         T.Free (Fed_Room);
         T.Allocate (Fed_Span, Fed_Room);
         if Fed_Room = null then
            return;
         end if;
      end if;

      declare
         Fed : Model_Runner.Numerics.Real_Array renames
           Fed_Room.all (Fed_Room.all'First
                         .. Fed_Room.all'First + Fed_Span - 1);
      begin
         Fed (Fed'First .. Fed'First + Slots * Wide - 1) :=
           Query (Query'First .. Query'First + Slots * Wide - 1);
         Fed (Fed'First + Slots * Wide .. Fed'Last) :=
           Residual (Residual'First
                     .. Residual'First + Slots * Weight.Rows - 1);
      end;

      if Landing = null or else Landing.all'Length < Wanted then
         T.Free (Landing);
         T.Allocate (Wanted, Landing);
         if Landing = null then
            return;
         end if;
      end if;

      Products.Run
        (Engine, Steps,
         Fed_Room.all (Fed_Room.all'First
                       .. Fed_Room.all'First + Fed_Span - 1),
         Natural'Max (Positions, 1),
         Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
         Ok, Halted);

      if Ok then
         Note_Timeline (Steps, Natural'Max (Positions, 1));
      end if;

      if Halted or else not Ok then
         Ok := False;
         return;
      end if;

      Into.all (Into.all'First .. Into.all'First + Slots * Down.Rows - 1) :=
        Landing.all (Landing.all'First + Blend + Rest
                     .. Landing.all'First + Wanted - 1);
   end Attend_And_Feed;

   --------------------
   -- Dispatch_Group --
   --------------------

   procedure Dispatch_Group
     (Weights : T.View_Group;
      Vector  : T.Real_Array_Access;
      Into    : T.Target_Group;
      Status  : out E.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Apart   : Model_Runner.Numerics.Element_Count := 0)
   is
      Steps  : Products.Sequence;
      Wanted : Model_Runner.Numerics.Element_Count := 0;
      Added  : Boolean;
      Ok     : Boolean;
      Cancelled : Boolean := False;

      --  The largest of the matrices, which is the one a refusal is about:
      --  they reach the device one buffer each.
      Asked  : Interfaces.Unsigned_64 := 0;

      --  Where the matrix being added reads from.
      Skip   : Model_Runner.Numerics.Element_Count := 0;
   begin
      Status := E.Success;

      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      --  One result for each matrix, said the same way round. A caller who
      --  passes a different number of each is refused rather than served the
      --  shorter of the two.
      if Weights'Length = 0 or else Weights'Length /= Into'Length then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Open_Sequence (Steps);

      for Index in Weights'Range loop
         declare
            This : T.View renames Weights (Index);

            Packing : Products.Weight_Packing;
            Known   : Boolean;
         begin
            Packing_Of (This.Format, Packing, Known);
            if not Known then
               Status := E.Make (E.Backend_Capability_Missing);
               E.Add_Text
                 (Status, "capability",
                  Model_Runner.GGUF.Type_Name (This.Format),
                  E.Param_Identifier);
               E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                           E.Param_Identifier);
               return;
            end if;

            --  Where this matrix's vector begins, which is the front for
            --  a group of one activation and its own stretch for a group
            --  laid end to end.
            Skip := Model_Runner.Numerics.Element_Count
                      (Index - Weights'First) * Apart;

            if This.Base = System.Null_Address
              or else Vector = null
              or else Into (Into'First + (Index - Weights'First)) = null
              or else Vector.all'Length < Skip + This.Columns
              or else Into (Into'First + (Index - Weights'First)).all'Length
                        < This.Rows
            then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            Products.Add_Product
              (Steps, This.Base, This.Span, This.Offset, Packing,
               Natural (This.Rows), Natural (This.Columns), Added,
               Key => At_Offset (This.Base, This.Offset),
               At_Vector => Natural (Skip));
            if not Added then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            Asked := Interfaces.Unsigned_64'Max
              (Asked,
               Interfaces.Unsigned_64 (This.Rows)
               * Products.Row_Bytes (Packing, Natural (This.Columns)));

            Wanted := Wanted + This.Rows;
         end;
      end loop;

      if Landing = null or else Landing.all'Length < Wanted then
         T.Free (Landing);
         T.Allocate (Wanted, Landing);
         if Landing = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;

      Products.Run
        (Engine, Steps, Vector.all, 1,
         Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
         Ok, Cancelled, Cancel);

      if Ok then
         Note_Timeline (Steps, 1);
      end if;

      --  Asked to stop comes before could not compute, for the reason the
      --  single product gives: it is the truer answer.
      if Cancelled then
         Status := E.Make (E.Generation_Cancelled);
         return;
      elsif Products.Is_Stalled (Engine) then
         Status := E.Make (E.Backend_Device_Stalled);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         E.Add_Integer (Status, "limit", Long_Long_Integer (Opened_Patience));
         return;
      elsif not Ok then
         Declined (Status, Asked);
         return;
      end if;

      declare
         At_Value : Model_Runner.Numerics.Element_Count :=
           Landing.all'First;
      begin
         for Index in Weights'Range loop
            declare
               Mine : T.Real_Array_Access renames
                 Into (Into'First + (Index - Weights'First));
            begin
               Mine.all
                 (Mine.all'First
                  .. Mine.all'First + Weights (Index).Rows - 1) :=
                 Landing.all
                   (At_Value .. At_Value + Weights (Index).Rows - 1);
               At_Value := At_Value + Weights (Index).Rows;
            end;
         end loop;
      end;
   end Dispatch_Group;

   ---------------------------
   -- Normalize_And_Project --
   ---------------------------

   procedure Normalize_And_Project
     (Weights     : T.View_Group;
      Vector      : T.Real_Array_Access;
      Norm_Weight : T.Real_Array;
      Epsilon     : Model_Runner.Numerics.Real;
      Into        : T.Target_Group;
      Ok          : out Boolean;
      Spread      : Model_Runner.Numerics.Element_Count := 1;
      Turns       : Model_Runner.Numerics.Wide_Real_Array := No_Turns;
      Turned      : Natural := 0;
      Head_Size   : Natural := 0;
      Rotary      : Natural := 0;
      Split       : Boolean := False;
      Cancel      : Model_Runner.Cancellation.Token_Reference := null)
   is

      Slots : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count'Max (Spread, 1);

      Steps  : Products.Sequence;
      Wanted : Model_Runner.Numerics.Element_Count := 0;
      Added  : Boolean;
      Ran    : Boolean;
      Cancelled : Boolean := False;

      Width : Model_Runner.Numerics.Element_Count := 0;

      --  Whether the rotation goes over too. It needs a table, a head width
      --  that divides the results it reaches, and something to turn.
      Rotating : constant Boolean :=
        Turned > 0
        and then Turned <= Weights'Length
        and then Head_Size > 0
        and then Rotary > 0
        and then Rotary <= Head_Size
        and then Turns'Length
                   = Slots * Model_Runner.Numerics.Element_Count (Rotary);
   begin
      Ok := False;

      if not Ready_Now
        or else Weights'Length = 0
        or else Weights'Length /= Into'Length
        or else Vector = null
        or else Norm_Weight'Length = 0
      then
         return;
      end if;

      Width := Model_Runner.Numerics.Element_Count (Norm_Weight'Length);

      if Vector.all'Length < Slots * Width then
         return;
      end if;

      --  The normalization's own room comes first in the answer, because
      --  every step of a sequence is given room whether the host reads it
      --  back or not: what a caller indexes does not depend on what it kept.
      Wanted := Slots * Width;

      Products.Open_Sequence (Steps);

      declare
         At_Norm : constant System.Address :=
           Norm_Weight (Norm_Weight'First)'Address;
      begin
         Products.Add_Norm
           (Steps, At_Norm,
            Model_Runner.Bytes.Byte_Count (Norm_Weight'Length) * 4, 0,
            Natural (Width), Epsilon, Added,
            Key => At_Norm, Kept => False);
      end;

      if not Added then
         return;
      end if;

      --  Every matrix reads the normalization rather than the step before
      --  it, which for the second and third of them is another matrix.
      for Index in Weights'Range loop
         declare
            This : T.View renames Weights (Index);

            Mine : T.Real_Array_Access renames
              Into (Into'First + (Index - Weights'First));

            Packing : Products.Weight_Packing;
            Known   : Boolean;
         begin
            Packing_Of (This.Format, Packing, Known);

            if not Known
              or else This.Base = System.Null_Address
              or else This.Columns /= Width
              or else Mine = null
              or else Mine.all'Length < Slots * This.Rows
            then
               return;
            end if;

            --  A result the rotation reaches is not what the host reads:
            --  the turning below writes its own answer and that is the one
            --  kept, so the product's own room is stepped over.
            Products.Add_Chained_Product
              (Steps, This.Base, This.Span, This.Offset, Packing,
               Natural (This.Rows), Natural (This.Columns), Added,
               Key => At_Offset (This.Base, This.Offset),
               Kept => not (Rotating
                            and then Index - Weights'First < Turned),
               From_Step => 1);

            if not Added then
               return;
            end if;

            Wanted := Wanted + This.Rows * Slots;
         end;
      end loop;

      --  And the turning, one step for each result it reaches, each reading
      --  the product that made it.
      if Rotating then
         declare
            At_Turn : constant System.Address := Turns (Turns'First)'Address;

            Span : constant Model_Runner.Bytes.Byte_Count :=
              Model_Runner.Bytes.Byte_Count (Turns'Length) * 8;
         begin
            for Offset in 0 .. Turned - 1 loop
               declare
                  This : T.View renames Weights (Weights'First + Offset);
               begin
                  if This.Rows
                       mod Model_Runner.Numerics.Element_Count (Head_Size)
                     /= 0
                  then
                     return;
                  end if;

                  Products.Add_Rotation
                    (Steps, At_Turn, Span, 0,
                     Natural (This.Rows),
                     Natural (This.Rows)
                     / Head_Size,
                     Rotary,
                     (if Split then Products.Split else Products.Interleaved),
                     Added,
                     From_Step => 1 + Offset + 1);

                  if not Added then
                     return;
                  end if;

                  Wanted := Wanted + This.Rows * Slots;
               end;
            end loop;
         end;
      end if;

      if Landing = null or else Landing.all'Length < Wanted then
         T.Free (Landing);
         T.Allocate (Wanted, Landing);
         if Landing = null then
            return;
         end if;
      end if;

      Products.Run
        (Engine, Steps, Vector.all (Vector.all'First
                                    .. Vector.all'First + Slots * Width - 1),
         Positive (Slots),
         Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
         Ran, Cancelled, Cancel);

      if Cancelled or else not Ran then
         return;
      end if;

      Note_Timeline (Steps, Positive (Slots));

      declare
         --  Past the normalization's room, which nothing here reads.
         At_Value : Model_Runner.Numerics.Element_Count :=
           Landing.all'First + Slots * Width;

         --  Where the turned answers begin, which is after every product's
         --  room whether the host reads that room or not.
         At_Turned : Model_Runner.Numerics.Element_Count := At_Value;
      begin
         for Index in Weights'Range loop
            At_Turned := At_Turned + Weights (Index).Rows * Slots;
         end loop;

         for Index in Weights'Range loop
            declare
               Mine : T.Real_Array_Access renames
                 Into (Into'First + (Index - Weights'First));

               Take : constant Model_Runner.Numerics.Element_Count :=
                 Weights (Index).Rows * Slots;

               Turned_Here : constant Boolean :=
                 Rotating and then Index - Weights'First < Turned;

               From : constant Model_Runner.Numerics.Element_Count :=
                 (if Turned_Here then At_Turned else At_Value);
            begin
               Mine.all (Mine.all'First .. Mine.all'First + Take - 1) :=
                 Landing.all (From .. From + Take - 1);

               At_Value := At_Value + Take;

               if Turned_Here then
                  At_Turned := At_Turned + Take;
               end if;
            end;
         end loop;
      end;

      Ok := True;
   end Normalize_And_Project;

   -----------------
   -- Whole_Layer --
   -----------------

   procedure Whole_Layer
     (Residual       : T.Real_Array;
      Attention_Norm : T.Real_Array_Access;
      Feed_Norm      : T.Real_Array_Access;
      Epsilon        : Model_Runner.Numerics.Real;
      Query          : T.View;
      Key            : T.View;
      Value          : T.View;
      Turns          : Model_Runner.Numerics.Wide_Real_Array;
      Head_Size      : Natural;
      Rotary         : Natural;
      Split          : Boolean;
      At_Key         : Natural;
      At_Value       : Natural;
      Heads          : Natural;
      Value_Size     : Natural;
      Group_Size     : Natural;
      First          : Natural;
      Last           : Natural;
      K_Base         : Natural;
      V_Base         : Natural;
      KV_Width       : Natural;
      V_Width        : Natural;
      Scale          : Model_Runner.Numerics.Real;
      Cap            : Model_Runner.Numerics.Real;
      Weight         : T.View;
      Gate           : T.View;
      Up             : T.View;
      Down           : T.View;
      Unit           : Natural;
      Keys           : T.Real_Array_Access;
      Values         : T.Real_Array_Access;
      Into           : T.Real_Array_Access;
      Ok             : out Boolean;
      Positions      : Natural := 1;
      Window         : Natural := 0;
      Causal         : Boolean := True;
      Max_Bias       : Model_Runner.Numerics.Real := 0.0;
      Cancel         : Model_Runner.Cancellation.Token_Reference := null;
      Carry_In       : Boolean := False;
      Carry_Out      : Boolean := False;
      Mirror         : Boolean := True;
      Table_At       : Natural := 0;
      Query_Norm     : Model_Runner.Tensors.Real_Array_Access := null;
      Key_Norm       : Model_Runner.Tensors.Real_Array_Access := null;
      Router         : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Router_Bias    : Model_Runner.Tensors.Real_Array_Access := null;
      Gate_Stack     : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Up_Stack       : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Down_Stack     : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Feed           : Natural := 0;
      Used           : Natural := 0;
      Experts        : Natural := 0;
      Packed         : Packed_Cache := Not_Packed;
      Pack_Keys      : Packing_Shape := Not_Packing;
      Pack_Values    : Packing_Shape := Not_Packing;
      Unpacked       : Unpacking_Shape := Not_Unpacked;
      Sinks_At       : Natural := 0;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Gate_Bias      : Model_Runner.Tensors.Real_Array_Access := null;
      Up_Bias        : Model_Runner.Tensors.Real_Array_Access := null;
      Down_Bias      : Model_Runner.Tensors.Real_Array_Access := null;
      Query_Bias     : Model_Runner.Tensors.Real_Array_Access := null;
      Key_Bias       : Model_Runner.Tensors.Real_Array_Access := null;
      Value_Bias     : Model_Runner.Tensors.Real_Array_Access := null;
      Out_Bias       : Model_Runner.Tensors.Real_Array_Access := null;
      Post_Attention_Norm : Model_Runner.Tensors.Real_Array_Access := null;
      Post_Feed_Norm      : Model_Runner.Tensors.Real_Array_Access := null;
      Shifted        : Boolean := False;
      After          : Boolean := False;
      Head_Gates     : Boolean := False;
      Shared_Gate    : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Shared_Up      : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Shared_Down    : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Shared_Router  : Model_Runner.Tensors.Real_Array_Access := null;
      Linear_Mix     : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Linear_Z       : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Linear_Alpha   : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Linear_Beta    : Model_Runner.Tensors.View :=
        Model_Runner.Tensors.Empty_View;
      Conv           : Model_Runner.Tensors.Real_Array_Access := null;
      Numbers        : Model_Runner.Tensors.Real_Array_Access := null;
      Linear         : Model_Runner.Platform.Device.Products.Linear_Shape :=
        (others => <>);
      Linear_State_At : Natural := 0;
      Pages_At       : Natural := 0;
      Page_Shift     : Natural := 0;
      First_Position : Natural := 0)
   is
      --  Whether this is a hybrid's linear layer rather than attention.
      Linear_Layer : constant Boolean := T.Is_Present (Linear_Mix);

      Slots : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Natural'Max (Positions, 1));

      Width : constant Model_Runner.Numerics.Element_Count :=
        (if Linear_Layer then Linear_Mix.Columns else Query.Columns);

      --  Whether the activation the layer before carried out has been
      --  brought home already, by the road below that runs the sequence
      --  and finds it refused.
      Brought_Home : Boolean := False;

      --  The whole of it: the guards, the sequence built and run, the
      --  answers read back. Told apart from the recovery below so that
      --  every refusal, and there are many, leaves through one door.
      procedure Attempt;

      procedure Attempt is
         --  Whether the second half is a mixture, and the step numbers that
         --  move when the head normalizations and the mixture are in: the
         --  recipe below used to be seventeen fixed steps and is now counted
         --  as it goes.
         Mixed : constant Boolean := T.Is_Present (Router);

         --  Whether the feed-forward has a gate, or is the one projection
         --  up with a unit on it that Falcon, Phi-2, GPT-2 and Bert state.
         Gated : constant Boolean := T.Is_Present (Gate);

         --  Whether the two halves run side by side, both reading the
         --  normalization on the way in: a layer with no normalization
         --  before its feed-forward is one that runs it beside attention.
         Parallel : constant Boolean := not After and then Feed_Norm = null;

         Step_Norm_In, Step_Q, Step_K, Step_V, Step_Q_Turned, Step_K_Turned,
         Step_Attend, Step_Out, Step_Join, Step_Norm_Feed,
         Step_Router, Step_Route, Step_Downs, Step_Gates, Step_Mix : Natural := 0;

         --  Whether the mixture has a shared expert beside the chosen ones.
         Shared : constant Boolean := T.Is_Present (Shared_Gate);

         --  The query rows the heads take: the projection's, or half of them
         --  where the other half are the gates beside the heads.
         Q_Rows : constant Model_Runner.Numerics.Element_Count :=
           (if Head_Gates then Query.Rows / 2 else Query.Rows);

         --  A normalization's weight: the gain, and after it the shift where
         --  the normalization is the centred one.
         Norm_Span : constant Model_Runner.Numerics.Element_Count :=
           (if Shifted then 2 * Width else Width);

         Steps  : Products.Sequence;
         Added  : Boolean;
         Ran    : Boolean;
         Cancelled : Boolean := False;

         --  Where each step's answer lands in the target, which is every
         --  step's room in order whether the host reads it or not.
         At_Values : Model_Runner.Numerics.Element_Count := 0;
         At_Keys   : Model_Runner.Numerics.Element_Count := 0;
         At_Out    : Model_Runner.Numerics.Element_Count := 0;
         Wanted    : Model_Runner.Numerics.Element_Count := 0;

         Packing : Products.Weight_Packing;
         Gate_P  : Products.Weight_Packing;
         Up_P    : Products.Weight_Packing;
         Down_P  : Products.Weight_Packing;
         Q_P     : Products.Weight_Packing;
         K_P     : Products.Weight_Packing;
         V_P     : Products.Weight_Packing;
         Router_P : Products.Weight_Packing;
         Shared_Gate_P, Shared_Up_P, Shared_Down_P : Products.Weight_Packing;
         Mix_P, Z_P, Alpha_P, Beta_P : Products.Weight_Packing;
         Known   : Boolean;

         --  Every step's rows, in order, so the offsets above are a sum rather
         --  than a tally kept by hand.
         procedure Step_Room (Rows : Model_Runner.Numerics.Element_Count) is
         begin
            Wanted := Wanted + Rows * Slots;
         end Step_Room;

         --  A mixture's expert biases, where the architecture carries them:
         --  one step a stack, each reading the routing for the expert every
         --  member is, and each taking the room its source took. The two
         --  arms' go after both arms, so the combination reads the biased
         --  pair as the two steps before it; the projection down's goes
         --  after the downs and becomes what the mix reads.
         procedure Add_Biases
           (Gate_Bias, Up_Bias : T.Real_Array_Access;
            Each, Experts, Route : Natural;
            Room  : Model_Runner.Numerics.Element_Count;
            Added : out Boolean)
         is
            Gate_Step : constant Natural := Products.Length (Steps) - 1;
            Up_Step   : constant Natural := Products.Length (Steps);
         begin
            Added := True;

            if Gate_Bias = null and then Up_Bias = null then
               return;
            end if;

            --  Both or neither: a combination reads the two steps before
            --  it, and one arm biased and the other not would put an arm
            --  two steps back.
            if Gate_Bias = null or else Up_Bias = null then
               Added := False;
               return;
            end if;

            Products.Add_Bias
              (Steps, Gate_Bias.all (Gate_Bias.all'First)'Address,
               Model_Runner.Bytes.Byte_Count (Gate_Bias.all'Length) * 4, 0,
               Experts, Each, Gate_Step, Route, Added,
               Key => Gate_Bias.all (Gate_Bias.all'First)'Address,
               Kept => False);
            if not Added then
               return;
            end if;
            Step_Room (Room);

            Products.Add_Bias
              (Steps, Up_Bias.all (Up_Bias.all'First)'Address,
               Model_Runner.Bytes.Byte_Count (Up_Bias.all'Length) * 4, 0,
               Experts, Each, Up_Step, Route, Added,
               Key => Up_Bias.all (Up_Bias.all'First)'Address,
               Kept => False);
            if not Added then
               return;
            end if;
            Step_Room (Room);
         end Add_Biases;

         --  A projection's bias, added to the step just named where the
         --  layer carries one: the step's number then becomes the biased
         --  step's, so what read the projection reads it biased.
         procedure Add_Projection_Bias
           (Bias  : T.Real_Array_Access;
            Rows  : Model_Runner.Numerics.Element_Count;
            Which : in out Natural;
            Added : out Boolean;
            Kept  : Boolean := False) is
         begin
            Added := True;

            if Bias = null then
               return;
            end if;

            Products.Add_Bias
              (Steps, Bias.all (Bias.all'First)'Address,
               Model_Runner.Bytes.Byte_Count (Bias.all'Length) * 4, 0,
               1, Natural (Rows), Which, 0, Added,
               Key => Bias.all (Bias.all'First)'Address, Kept => Kept);
            if not Added then
               return;
            end if;
            Which := Products.Length (Steps);
            Step_Room (Rows);
         end Add_Projection_Bias;

         --  A normalization of the step just named, where the architecture
         --  puts one before a residual join: the step's number then becomes
         --  the normalized step's, so the join reads it normalized.
         procedure Add_Post_Norm
           (Gain  : T.Real_Array_Access;
            Rows  : Model_Runner.Numerics.Element_Count;
            Which : in out Natural;
            Added : out Boolean;
            Kept  : Boolean := False) is
         begin
            Added := True;

            if Gain = null then
               return;
            end if;

            declare
               At_Weight : constant System.Address :=
                 Gain.all (Gain.all'First)'Address;
            begin
               Products.Add_Norm
                 (Steps, At_Weight,
                  Model_Runner.Bytes.Byte_Count (Gain.all'Length) * 4, 0,
                  Natural (Rows), Epsilon, Added,
                  From_Step => Which, Key => At_Weight, Kept => Kept,
                  Shift => Shifted);
            end;
            if not Added then
               return;
            end if;
            Which := Products.Length (Steps);
            Step_Room (Rows);
         end Add_Post_Norm;

         --  A projection of the layer's input: of the normalization on the
         --  way in, or -- for an architecture that normalizes on the way out
         --  and has none -- of the activation the caller handed over, which
         --  a product not chained to any step reads.
         procedure Add_Input_Product
           (Matrix : T.View;
            P      : Products.Weight_Packing;
            Kept   : Boolean;
            Added  : out Boolean) is
         begin
            if Step_Norm_In = 0 then
               Products.Add_Product
                 (Steps, Matrix.Base, Matrix.Span, Matrix.Offset, P,
                  Natural (Matrix.Rows), Natural (Matrix.Columns), Added,
                  Key => At_Offset (Matrix.Base, Matrix.Offset), Kept => Kept);
            else
               Products.Add_Chained_Product
                 (Steps, Matrix.Base, Matrix.Span, Matrix.Offset, P,
                  Natural (Matrix.Rows), Natural (Matrix.Columns), Added,
                  Key => At_Offset (Matrix.Base, Matrix.Offset), Kept => Kept,
                  From_Step => Step_Norm_In);
            end if;
         end Add_Input_Product;

         procedure Add_Down_Bias
           (Down_Bias : T.Real_Array_Access;
            Each, Experts, Route : Natural;
            Room  : Model_Runner.Numerics.Element_Count;
            Added : out Boolean) is
         begin
            Added := True;

            if Down_Bias = null then
               return;
            end if;

            Products.Add_Bias
              (Steps, Down_Bias.all (Down_Bias.all'First)'Address,
               Model_Runner.Bytes.Byte_Count (Down_Bias.all'Length) * 4, 0,
               Experts, Each, Step_Downs, Route, Added,
               Key => Down_Bias.all (Down_Bias.all'First)'Address,
               Kept => False);
            if not Added then
               return;
            end if;
            Step_Downs := Products.Length (Steps);
            Step_Room (Room);
         end Add_Down_Bias;
      begin
         Ok := False;

         if not Ready_Now
           or else Width = 0
           or else Into = null
           --  A linear layer's four projections, its taps and its numbers
           --  hold together with the shape; attention's have the cache.
           or else (if Linear_Layer
                    then Linear_Mix.Columns /= Width
                         or else Linear_Z.Columns /= Width
                         or else Linear_Alpha.Columns /= Width
                         or else Linear_Beta.Columns /= Width
                         or else Natural (Linear_Mix.Rows) /= Linear.Mix
                         or else Natural (Linear_Z.Rows)
                                 /= Linear.Value_Heads * Linear.Head
                         or else Natural (Linear_Alpha.Rows) /= Linear.Value_Heads
                         or else Natural (Linear_Beta.Rows) /= Linear.Value_Heads
                         or else Conv = null
                         or else Natural (Conv.all'Length)
                                 /= Linear.Taps * Linear.Mix
                         or else Numbers = null
                         or else Natural (Numbers.all'Length)
                                 /= 2 * Linear.Value_Heads + Linear.Head
                         or else Natural (Weight.Columns)
                                 /= Linear.Value_Heads * Linear.Head
                         or else Head_Gates or else After
                    else Head_Size = 0
                         --  No rotation at all is an architecture that
                         --  learned a row a position, GPT-2's and Bert's,
                         --  and turns nothing.
                         or else Rotary > Head_Size
                         or else Rotary mod 2 /= 0
                         or else Heads = 0
                         or else Keys = null or else Values = null)
           --  The normalizations, as the architecture arranges them: one on
           --  the way in and one before the feed-forward, the second absent
           --  where the two halves run side by side, both absent and the
           --  two after the joins present where it normalizes on the way
           --  out. Each of the width, or twice it with a shift.
           or else (Attention_Norm = null) /= After
           or else (Attention_Norm /= null
                    and then Attention_Norm.all'Length /= Norm_Span)
           or else (Feed_Norm /= null and then Feed_Norm.all'Length /= Norm_Span)
           or else (After
                    and then (Feed_Norm /= null
                              or else Post_Attention_Norm = null
                              or else Post_Feed_Norm = null))
           --  A feed-forward without a gate takes a unit alone on its one
           --  arm, and a mixture is gated by its stacks.
           or else (not Gated and then not Mixed and then Unit not in 0 | 1)
           --  A gate beside each head is elementwise over the blend, so
           --  the value heads are as wide as the query heads; the query
           --  rows are then two a head, and the heads are a whole number.
           or else (Head_Gates
                    and then (Value_Size /= Head_Size
                              or else Query.Rows mod 2 /= 0
                              or else Natural (Q_Rows) mod Head_Size /= 0))
           --  A shared expert is a mixture's, all four parts or none.
           or else (Shared
                    and then (not Mixed
                              or else not T.Is_Present (Shared_Up)
                              or else not T.Is_Present (Shared_Down)
                              or else Shared_Router = null
                              or else Shared_Router.all'Length /= Width
                              or else Shared_Gate.Columns /= Width
                              or else Shared_Up.Columns /= Width
                              or else Shared_Up.Rows /= Shared_Gate.Rows
                              or else Shared_Down.Rows /= Width
                              or else Shared_Down.Columns /= Shared_Gate.Rows))
           or else Residual'Length < Slots * Width
           or else (not Linear_Layer
                    and then (Query.Columns /= Width
                              or else Key.Columns /= Width
                              or else Value.Columns /= Width
                              or else Turns'Length
                                      /= Slots
                                         * Model_Runner.Numerics.Element_Count
                                             (Rotary)
                              or else Keys.all'Length < Slots * Key.Rows
                              or else Values.all'Length < Slots * Value.Rows))
           or else Into.all'Length < Slots * Width
           --  A post-norm is a gain of the width; and a mixture's sum joins
           --  the residual as it sums, with no room for one before it --
           --  the one after the sum is Bert's, which the mix leaves for it.
           or else (Post_Attention_Norm /= null
                    and then Post_Attention_Norm.all'Length /= Norm_Span)
           or else (Post_Feed_Norm /= null
                    and then (Post_Feed_Norm.all'Length /= Norm_Span
                              or else (Experts > 0 and then not After)))
           --  The expert biases are a mixture's; a plain feed-forward's
           --  are the one slice each on its two projections.
           or else (not Mixed
                    and then (Gate_Bias /= null
                              or else (Up_Bias /= null
                                       and then (Gated
                                                 or else Up_Bias.all'Length
                                                         /= Up.Rows))
                              or else (Down_Bias /= null
                                       and then Down_Bias.all'Length /= Width)))
         then
            return;
         end if;

         if Linear_Layer then
            Packing_Of (Linear_Mix.Format, Mix_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Linear_Z.Format, Z_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Linear_Alpha.Format, Alpha_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Linear_Beta.Format, Beta_P, Known);
            if not Known then
               return;
            end if;
         else
            Packing_Of (Query.Format, Q_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Key.Format, K_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Value.Format, V_P, Known);
            if not Known then
               return;
            end if;
         end if;
         Packing_Of (Weight.Format, Packing, Known);
         if not Known then
            return;
         end if;

         if Mixed then
            --  The router and the stacks, and the shape they have to hold
            --  together in: one slice of each stack a member, over the
            --  width the layer has.
            Packing_Of (Router.Format, Router_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Gate_Stack.Format, Gate_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Up_Stack.Format, Up_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Down_Stack.Format, Down_P, Known);
            if not Known then
               return;
            end if;

            if Shared then
               Packing_Of (Shared_Gate.Format, Shared_Gate_P, Known);
               if not Known then
                  return;
               end if;
               Packing_Of (Shared_Up.Format, Shared_Up_P, Known);
               if not Known then
                  return;
               end if;
               Packing_Of (Shared_Down.Format, Shared_Down_P, Known);
               if not Known then
                  return;
               end if;
            end if;

            if Feed = 0 or else Used = 0 or else Experts < Used
              or else Used > Products.Max_Gather
              or else Router.Columns /= Width
              or else Natural (Router.Rows) /= Experts
              or else Gate_Stack.Columns /= Width
              or else Up_Stack.Columns /= Width
              or else Natural (Down_Stack.Columns) /= Feed
              or else Natural (Gate_Stack.Rows) /= Experts * Feed
              or else Natural (Up_Stack.Rows) /= Experts * Feed
              or else Down_Stack.Rows /= Model_Runner.Numerics.Element_Count
                                             (Experts) * Width
              or else (Router_Bias /= null
                       and then Natural (Router_Bias.all'Length) /= Experts)
            then
               return;
            end if;
         else
            if Gated then
               Packing_Of (Gate.Format, Gate_P, Known);
               if not Known then
                  return;
               end if;
            end if;
            Packing_Of (Up.Format, Up_P, Known);
            if not Known then
               return;
            end if;
            Packing_Of (Down.Format, Down_P, Known);
            if not Known then
               return;
            end if;
         end if;

         --  A head normalization's weight is one head wide, and both are
         --  read at the head size the queries and keys are projected in.
         if (Query_Norm /= null
             and then Natural (Query_Norm.all'Length) /= Head_Size)
           or else (Key_Norm /= null
                    and then Natural (Key_Norm.all'Length) /= Head_Size)
         then
            return;
         end if;

         Products.Open_Sequence (Steps);

         --  One: the normalization on the way in, of what the caller handed
         --  us -- where the architecture has one. Bert's projections read
         --  the input as it is.
         if not After then
            declare
               At_Norm : constant System.Address :=
                 Attention_Norm.all (Attention_Norm.all'First)'Address;
            begin
               Products.Add_Norm
                 (Steps, At_Norm,
                  Model_Runner.Bytes.Byte_Count (Attention_Norm.all'Length) * 4,
                  0,
                  Natural (Width), Epsilon, Added,
                  Key => At_Norm, Kept => False, Shift => Shifted);
            end;
            if not Added then
               return;
            end if;
            Step_Norm_In := Products.Length (Steps);
            Step_Room (Width);
         end if;

         --  A linear layer's front: the four projections of the
         --  normalization, the convolution of the mixed rows over the memory
         --  the ring keeps, and the rule over the state it keeps, whose
         --  answer the projection out reads as it reads attention's blend.
         if Linear_Layer then
            declare
               Shape : Products.Linear_Shape := Linear;
               Step_Mix, Step_Conv : Natural := 0;

               procedure Add_Row_Product
                 (Matrix : T.View; P : Products.Weight_Packing;
                  Which  : out Natural; Added : out Boolean) is
               begin
                  Products.Add_Chained_Product
                    (Steps, Matrix.Base, Matrix.Span, Matrix.Offset, P,
                     Natural (Matrix.Rows), Natural (Matrix.Columns), Added,
                     Key => At_Offset (Matrix.Base, Matrix.Offset), Kept => False,
                     From_Step => Step_Norm_In);
                  Which := Products.Length (Steps);
                  Step_Room (Matrix.Rows);
               end Add_Row_Product;
            begin
               Add_Row_Product (Linear_Mix, Mix_P, Step_Mix, Added);
               if not Added then
                  return;
               end if;
               Add_Row_Product (Linear_Z, Z_P, Shape.Z_Step, Added);
               if not Added then
                  return;
               end if;
               Add_Row_Product (Linear_Alpha, Alpha_P, Shape.Alpha_Step, Added);
               if not Added then
                  return;
               end if;
               Add_Row_Product (Linear_Beta, Beta_P, Shape.Beta_Step, Added);
               if not Added then
                  return;
               end if;

               Products.Add_Conv
                 (Steps, Conv.all (Conv.all'First)'Address,
                  Model_Runner.Bytes.Byte_Count (Conv.all'Length) * 4, 0,
                  Shape, Added, From_Step => Step_Mix,
                  Key => Conv.all (Conv.all'First)'Address, Kept => False);
               if not Added then
                  return;
               end if;
               Step_Conv := Products.Length (Steps);
               Step_Room (Linear_Mix.Rows);

               --  The state lies elsewhere in a slot than the memory.
               Shape.Region_At := Linear_State_At;
               Products.Add_Rule
                 (Steps, Numbers.all (Numbers.all'First)'Address,
                  Model_Runner.Bytes.Byte_Count (Numbers.all'Length) * 4, 0,
                  Shape, Added, From_Step => Step_Conv,
                  Key => Numbers.all (Numbers.all'First)'Address, Kept => False);
               if not Added then
                  return;
               end if;
               Step_Attend := Products.Length (Steps);
               Step_Room (Weight.Columns);
            end;

            goto Attended;
         end if;

         --  The queries, the keys and the values, each reading the
         --  normalization rather than the step before it.
         Add_Input_Product (Query, Q_P, False, Added);
         if not Added then
            return;
         end if;

         Step_Q := Products.Length (Steps);
         Step_Room (Query.Rows);

         --  The hybrid's queries and the gates beside its heads, picked
         --  apart: the heads read the queries, and the gates wait for the
         --  blend.
         if Head_Gates then
            declare
               Step_Full : constant Natural := Step_Q;
            begin
               Products.Add_Pick
                 (Steps, Natural (Q_Rows), Head_Size, 0, 2, Added,
                  From_Step => Step_Full, Kept => False);
               if not Added then
                  return;
               end if;
               Step_Q := Products.Length (Steps);
               Step_Room (Q_Rows);

               Products.Add_Pick
                 (Steps, Natural (Q_Rows), Head_Size, 1, 2, Added,
                  From_Step => Step_Full, Kept => False);
               if not Added then
                  return;
               end if;
               Step_Gates := Products.Length (Steps);
               Step_Room (Q_Rows);
            end;
         end if;

         Add_Projection_Bias (Query_Bias, Q_Rows, Step_Q, Added);
         if not Added then
            return;
         end if;

         --  The keys go back to a caller that wants them (Mirror) from the
         --  turning, or from here where there is none.
         At_Keys := Wanted;
         Add_Input_Product
           (Key, K_P, Mirror and then Rotary = 0 and then Key_Bias = null,
            Added);
         if not Added then
            return;
         end if;
         Step_K := Products.Length (Steps);
         Step_Room (Key.Rows);

         if Key_Bias /= null then
            At_Keys := Wanted;
         end if;
         Add_Projection_Bias (Key_Bias, Key.Rows, Step_K, Added,
                              Kept => Mirror and then Rotary = 0);
         if not Added then
            return;
         end if;

         Add_Input_Product (Value, V_P, Mirror and then Value_Bias = null, Added);
         if not Added then
            return;
         end if;
         Step_V := Products.Length (Steps);
         if Value_Bias = null then
            At_Values := Wanted;
         end if;
         Step_Room (Value.Rows);

         --  The values' bias; the host then reads the values back from the
         --  biased step.
         if Value_Bias /= null then
            At_Values := Wanted;
         end if;
         Add_Projection_Bias (Value_Bias, Value.Rows, Step_V, Added,
                              Kept => Mirror);
         if not Added then
            return;
         end if;

         --  The heads made ready in two dispatches where the device has the
         --  kernel: the queries normalized and turned into their own room,
         --  the keys normalized and turned into the cache with the values
         --  placed beside them. Six steps otherwise -- and six still where
         --  the caller wants the keys and values back (Mirror), because the
         --  fused step leaves them only in the cache.
         if Products.Readies_Heads (Engine)
           and then Rotary > 0
           and then not Mirror
           and then Table_At = 0
           and then Head_Size <= 256
           and then Natural (Key.Rows) = Natural (Value.Rows)
           and then Natural (Key.Rows) mod Head_Size = 0
         then
            declare
               At_Turn : constant System.Address := Turns (Turns'First)'Address;

               Span : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count (Turns'Length) * 8;

               Pairing : constant Products.Rotary_Pairing :=
                 (if Split then Products.Split else Products.Interleaved);

               function Weight_Of (Norm : T.Real_Array_Access)
                 return System.Address
               is (if Norm = null then System.Null_Address
                   else Norm.all (Norm.all'First)'Address);

               function Span_Of (Norm : T.Real_Array_Access)
                 return Model_Runner.Bytes.Byte_Count
               is (if Norm = null then 0
                   else Model_Runner.Bytes.Byte_Count (Norm.all'Length) * 4);
            begin
               Products.Add_Heads
                 (Steps, Step_Q, Natural (Q_Rows) / Head_Size, Head_Size,
                  Rotary, Pairing, At_Turn, Span, Epsilon, Added,
                  Weight => Weight_Of (Query_Norm),
                  Weight_Span => Span_Of (Query_Norm),
                  Key => Weight_Of (Query_Norm), Kept => False);
               if not Added then
                  return;
               end if;
               Step_Q_Turned := Products.Length (Steps);
               Step_Room (Q_Rows);

               --  A packed session's keys are turned into their own room
               --  and packed from there, with the values, by the two steps
               --  after: the fused step writes the exact cache and no other.
               if Packed.K_Bits /= 0 then
                  Products.Add_Heads
                    (Steps, Step_K, Natural (Key.Rows) / Head_Size, Head_Size,
                     Rotary, Pairing, At_Turn, Span, Epsilon, Added,
                     Weight => Weight_Of (Key_Norm),
                     Weight_Span => Span_Of (Key_Norm),
                     Key => Weight_Of (Key_Norm), Kept => False);
                  if not Added then
                     return;
                  end if;
                  Step_K_Turned := Products.Length (Steps);
                  Step_Room (Key.Rows);

                  Products.Add_Place
                    (Steps, Natural (Key.Rows), KV_Width, 0, Added,
                     From_Step => Step_K_Turned, Packed => Pack_Keys);
                  if not Added then
                     return;
                  end if;
                  Step_Room (Key.Rows);

                  Products.Add_Place
                    (Steps, Natural (Value.Rows), V_Width, 0, Added,
                     From_Step => Step_V, Packed => Pack_Values);
                  if not Added then
                     return;
                  end if;
                  Step_Room (Value.Rows);

                  goto Attend;
               end if;

               Products.Add_Heads
                 (Steps, Step_K, Natural (Key.Rows) / Head_Size, Head_Size,
                  Rotary, Pairing, At_Turn, Span, Epsilon, Added,
                  Weight => Weight_Of (Key_Norm),
                  Weight_Span => Span_Of (Key_Norm),
                  Key => Weight_Of (Key_Norm),
                  Into_Cache => True, At_First => At_Key, Stride => KV_Width,
                  V_Step => Step_V, V_At_First => At_Value, V_Stride => V_Width,
                  Kept => False);
               if not Added then
                  return;
               end if;
               Step_Room (Key.Rows);
            end;

            goto Attend;
         end if;

         --  The head normalizations, where the architecture has them: each
         --  head of the queries and of the keys over its own mean square, by
         --  a weight one head wide, before the turning reads them.
         if Query_Norm /= null then
            declare
               At_Weight : constant System.Address :=
                 Query_Norm.all (Query_Norm.all'First)'Address;
            begin
               Products.Add_Norm
                 (Steps, At_Weight,
                  Model_Runner.Bytes.Byte_Count (Query_Norm.all'Length) * 4, 0,
                  Natural (Q_Rows), Epsilon, Added,
                  From_Step => Step_Q, Key => At_Weight, Kept => False,
                  Groups => Natural (Q_Rows) / Head_Size);
            end;
            if not Added then
               return;
            end if;
            Step_Q := Products.Length (Steps);
            Step_Room (Q_Rows);
         end if;

         if Key_Norm /= null then
            declare
               At_Weight : constant System.Address :=
                 Key_Norm.all (Key_Norm.all'First)'Address;
            begin
               Products.Add_Norm
                 (Steps, At_Weight,
                  Model_Runner.Bytes.Byte_Count (Key_Norm.all'Length) * 4, 0,
                  Natural (Key.Rows), Epsilon, Added,
                  From_Step => Step_K, Key => At_Weight, Kept => False,
                  Groups => Natural (Key.Rows) / Head_Size);
            end;
            if not Added then
               return;
            end if;
            Step_K := Products.Length (Steps);
            Step_Room (Key.Rows);
         end if;

         --  No turning where the architecture turns nothing: the queries
         --  and the keys are placed and attended as the projections made
         --  them.
         if Rotary = 0 then
            Step_Q_Turned := Step_Q;
            Step_K_Turned := Step_K;
            goto Place;
         end if;

         --  The turning, of the queries and of the keys.
         declare
            At_Turn : constant System.Address := Turns (Turns'First)'Address;

            Span : constant Model_Runner.Bytes.Byte_Count :=
              Model_Runner.Bytes.Byte_Count (Turns'Length) * 8;

            Pairing : constant Products.Rotary_Pairing :=
              (if Split then Products.Split else Products.Interleaved);
         begin
            Products.Add_Rotation
              (Steps, At_Turn, Span, 0, Natural (Q_Rows),
               Natural (Q_Rows) / Head_Size, Rotary, Pairing, Added,
               From_Step => Step_Q, Kept => False);
            if not Added then
               return;
            end if;
            Step_Q_Turned := Products.Length (Steps);
            Step_Room (Q_Rows);

            Products.Add_Rotation
              (Steps, At_Turn, Span, 0, Natural (Key.Rows),
               Natural (Key.Rows) / Head_Size, Rotary, Pairing, Added,
               From_Step => Step_K, Kept => Mirror);
            if not Added then
               return;
            end if;
            Step_K_Turned := Products.Length (Steps);
            At_Keys := Wanted;
            Step_Room (Key.Rows);
         end;

         <<Place>>

         --  Into the cache, before anything attends to it -- packed, for a
         --  packed session's block.
         Products.Add_Place
           (Steps, Natural (Key.Rows), KV_Width, At_Key, Added,
            From_Step => Step_K_Turned, Table_At => Table_At,
            Packed => Pack_Keys,
            Pages_At => Pages_At, Page_Shift => Page_Shift,
            First_Position => First_Position);
         if not Added then
            return;
         end if;
         Step_Room (Key.Rows);

         Products.Add_Place
           (Steps, Natural (Value.Rows), V_Width, At_Value, Added,
            From_Step => Step_V, Table_At => Table_At,
            Packed => Pack_Values,
            Pages_At => Pages_At, Page_Shift => Page_Shift,
            First_Position => First_Position);
         if not Added then
            return;
         end if;
         Step_Room (Value.Rows);

         <<Attend>>

         --  A packed session's batch through the matrix instruction, where
         --  that is the kernel the batch would take: the layer's packed keys
         --  and values unpacked into the copy first, after the step that
         --  packed them, and the attention then reads the copy as an exact
         --  session's does, from the bases the caller says.
         if Packed.K_Bits /= 0
           and then Through_Matrix (Unpacked, Positions, Head_Size, Value_Size)
         then
            Add_Unpacking
              (Steps, Unpacked, KV_Width, V_Width,
               From => Products.Length (Steps), Added => Added);
            if not Added then
               return;
            end if;
            Step_Room (Model_Runner.Numerics.Element_Count (KV_Width));
            Step_Room (Model_Runner.Numerics.Element_Count (V_Width));

            Products.Add_Attention
              (Steps, Heads, Head_Size, Value_Size, Group_Size, First, Last,
               Unpacked.K_Base, Unpacked.V_Base, KV_Width, V_Width, Scale, Cap,
               Added,
               Window => Window, Causal => Causal, Max_Bias => Max_Bias,
               Chained => True, From_Step => Step_Q_Turned, Kept => False,
               Sinks_At => Sinks_At);
            if not Added then
               return;
            end if;
            Step_Attend := Products.Length (Steps);
            goto Attended;
         end if;

         --  Attention, against the turned queries.
         Products.Add_Attention
           (Steps, Heads, Head_Size, Value_Size, Group_Size, First, Last,
            K_Base, V_Base, KV_Width, V_Width, Scale, Cap, Added,
            Window => Window, Causal => Causal, Max_Bias => Max_Bias,
            Chained => True, From_Step => Step_Q_Turned, Kept => False,
            Table_At => Table_At, Packed => Packed, Sinks_At => Sinks_At,
            Pages_At => Pages_At, Page_Shift => Page_Shift);
         if not Added then
            return;
         end if;
         Step_Attend := Products.Length (Steps);

         <<Attended>>
         if not Linear_Layer then
            Step_Room
              (Model_Runner.Numerics.Element_Count (Heads * Value_Size));
         end if;

         --  Each head's blend through the logistic of its gate, where the
         --  query projection carried one, before the projection out reads
         --  it.
         if Head_Gates then
            Products.Add_Combination
              (Steps, 6, Added, Kept => False,
               From_Step => Step_Gates, Other_Step => Step_Attend);
            if not Added then
               return;
            end if;
            Step_Attend := Products.Length (Steps);
            Step_Room
              (Model_Runner.Numerics.Element_Count (Heads * Value_Size));
         end if;

         --  The second half, as Attend_And_Feed builds it, with the residual
         --  coming from the front of the activation rather than the back of
         --  it -- there is nothing else in it now.
         Products.Add_Chained_Product
           (Steps, Weight.Base, Weight.Span, Weight.Offset, Packing,
            Natural (Weight.Rows), Natural (Weight.Columns), Added,
            Key => At_Offset (Weight.Base, Weight.Offset), Kept => False,
            From_Step => Step_Attend);
         if not Added then
            return;
         end if;
         Step_Out := Products.Length (Steps);
         Step_Room (Weight.Rows);

         --  The bias on the way out, and the normalization Gemma puts on
         --  what attention produced, before the join reads it.
         Add_Projection_Bias (Out_Bias, Weight.Rows, Step_Out, Added);
         if not Added then
            return;
         end if;
         if not After then
            Add_Post_Norm (Post_Attention_Norm, Weight.Rows, Step_Out, Added);
            if not Added then
               return;
            end if;
         end if;

         Products.Add_Join (Steps, Added, From_Step => Step_Out, Kept => False);
         if not Added then
            return;
         end if;
         Step_Join := Products.Length (Steps);
         Step_Room (Width);

         --  And the normalization Bert puts on the sum, which is then what
         --  the feed-forward reads and what its join adds to.
         if After then
            Add_Post_Norm (Post_Attention_Norm, Width, Step_Join, Added);
            if not Added then
               return;
            end if;
         end if;

         --  The normalization before the feed-forward, of the residual as
         --  it now stands -- or, where the two halves run side by side, the
         --  one on the way in read again; and Bert's feed-forward reads the
         --  normalized sum.
         if Parallel then
            Step_Norm_Feed := Step_Norm_In;
         elsif After then
            Step_Norm_Feed := Step_Join;
         else
            declare
               At_Feed : constant System.Address :=
                 Feed_Norm.all (Feed_Norm.all'First)'Address;
            begin
               Products.Add_Norm
                 (Steps, At_Feed,
                  Model_Runner.Bytes.Byte_Count (Feed_Norm.all'Length) * 4, 0,
                  Natural (Width), Epsilon, Added,
                  From_Step => Step_Join, Key => At_Feed,
                  Kept => False, Shift => Shifted);
            end;
            if not Added then
               return;
            end if;
            Step_Norm_Feed := Products.Length (Steps);
            Step_Room (Width);
         end if;

         if Mixed then
            --  The router, the choosing, the chosen experts' three
            --  projections gathered, the unit between them, and the sum by
            --  shares with the residual added: a mixture layer, whole.
            Products.Add_Chained_Product
              (Steps, Router.Base, Router.Span, Router.Offset, Router_P,
               Natural (Router.Rows), Natural (Router.Columns), Added,
               Key => At_Offset (Router.Base, Router.Offset), Kept => False,
               From_Step => Step_Norm_Feed);
            if not Added then
               return;
            end if;
            Step_Router := Products.Length (Steps);
            Step_Room (Router.Rows);

            if Router_Bias = null then
               Products.Add_Route
                 (Steps, Experts, Used, Added, From_Step => Step_Router,
                  Kept => False);
            else
               Products.Add_Route
                 (Steps, Experts, Used, Added, From_Step => Step_Router,
                  Kept => False,
                  Bias => Router_Bias.all (Router_Bias.all'First)'Address,
                  Bias_Span =>
                    Model_Runner.Bytes.Byte_Count (Router_Bias.all'Length) * 4,
                  Bias_At => 0);
            end if;
            if not Added then
               return;
            end if;
            Step_Route := Products.Length (Steps);
            Step_Room (Model_Runner.Numerics.Element_Count (2 * Used));

            if Slots > 1 then
               --  A batch: the routing inverted, and every expert run over
               --  the positions that chose it as one dispatch a matrix,
               --  the answers by slot until the mix puts each position's
               --  back together. A token gathers its few experts straight
               --  from the routing, below. The slots a position take room
               --  for the padding of the runs, as Add_Listed_Product sizes
               --  it.
               declare
                  Padded : constant Natural :=
                    Used
                    + (15 * Natural'Min (Experts, Natural (Slots) * Used)
                       + Natural (Slots) - 1)
                      / Natural (Slots);
               begin
                  Products.Add_Invert
                    (Steps, Experts, Used, Step_Route, Added, Kept => False);
                  if not Added then
                     return;
                  end if;
                  Step_Route := Products.Length (Steps);
                  Step_Room
                    (Model_Runner.Numerics.Element_Count
                       (32 * Experts + 3 * Used));

                  Products.Add_Listed_Product
                    (Steps, Gate_Stack.Base, Gate_Stack.Span, Gate_Stack.Offset,
                     Gate_P, Natural (Gate_Stack.Rows), Feed, Natural (Width),
                     Experts, Used, Step_Route, Positive (Slots), Added,
                     Key => At_Offset (Gate_Stack.Base, Gate_Stack.Offset),
                     Kept => False, From_Step => Step_Norm_Feed);
                  if not Added then
                     return;
                  end if;
                  Step_Room (Model_Runner.Numerics.Element_Count (Padded * Feed));

                  Products.Add_Listed_Product
                    (Steps, Up_Stack.Base, Up_Stack.Span, Up_Stack.Offset,
                     Up_P, Natural (Up_Stack.Rows), Feed, Natural (Width),
                     Experts, Used, Step_Route, Positive (Slots), Added,
                     Key => At_Offset (Up_Stack.Base, Up_Stack.Offset),
                     Kept => False, From_Step => Step_Norm_Feed);
                  if not Added then
                     return;
                  end if;
                  Step_Room (Model_Runner.Numerics.Element_Count (Padded * Feed));

                  --  The two arms' biases, where the architecture carries
                  --  them, each read for the expert its slot belongs to;
                  --  the combination then reads the biased pair, which are
                  --  the two steps before it.
                  Add_Biases
                    (Gate_Bias, Up_Bias, Feed, Experts, Step_Route,
                     Model_Runner.Numerics.Element_Count (Padded * Feed), Added);
                  if not Added then
                     return;
                  end if;

                  Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                           Alpha => Alpha, Limit => Limit);
                  if not Added then
                     return;
                  end if;
                  Step_Room (Model_Runner.Numerics.Element_Count (Padded * Feed));

                  Products.Add_Listed_Product
                    (Steps, Down_Stack.Base, Down_Stack.Span, Down_Stack.Offset,
                     Down_P, Natural (Down_Stack.Rows), Natural (Width), Feed,
                     Experts, Used, Step_Route, Positive (Slots), Added,
                     Key => At_Offset (Down_Stack.Base, Down_Stack.Offset),
                     Kept => False, By_Slot => True);
                  if not Added then
                     return;
                  end if;
                  Step_Downs := Products.Length (Steps);
                  Step_Room (Model_Runner.Numerics.Element_Count (Padded) * Width);

                  Add_Down_Bias
                    (Down_Bias, Natural (Width), Experts, Step_Route,
                     Model_Runner.Numerics.Element_Count (Padded) * Width, Added);
                  if not Added then
                     return;
                  end if;
               end;
            else
               Products.Add_Gathered_Product
                 (Steps, Gate_Stack.Base, Gate_Stack.Span, Gate_Stack.Offset,
                  Gate_P, Natural (Gate_Stack.Rows), Feed, Natural (Width),
                  [others => 0], Used, Added,
                  Key => At_Offset (Gate_Stack.Base, Gate_Stack.Offset),
                  Kept => False, Chained => True, From_Step => Step_Norm_Feed,
                  Routed => Step_Route);
               if not Added then
                  return;
               end if;
               Step_Room (Model_Runner.Numerics.Element_Count (Used * Feed));

               Products.Add_Gathered_Product
                 (Steps, Up_Stack.Base, Up_Stack.Span, Up_Stack.Offset,
                  Up_P, Natural (Up_Stack.Rows), Feed, Natural (Width),
                  [others => 0], Used, Added,
                  Key => At_Offset (Up_Stack.Base, Up_Stack.Offset),
                  Kept => False, Chained => True, From_Step => Step_Norm_Feed,
                  Routed => Step_Route);
               if not Added then
                  return;
               end if;
               Step_Room (Model_Runner.Numerics.Element_Count (Used * Feed));

               Add_Biases
                 (Gate_Bias, Up_Bias, Feed, Experts, Step_Route,
                  Model_Runner.Numerics.Element_Count (Used * Feed), Added);
               if not Added then
                  return;
               end if;

               Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                           Alpha => Alpha, Limit => Limit);
               if not Added then
                  return;
               end if;
               Step_Room (Model_Runner.Numerics.Element_Count (Used * Feed));

               Products.Add_Gathered_Product
                 (Steps, Down_Stack.Base, Down_Stack.Span, Down_Stack.Offset,
                  Down_P, Natural (Down_Stack.Rows), Natural (Width), Feed,
                  [others => 0], Used, Added,
                  Key => At_Offset (Down_Stack.Base, Down_Stack.Offset),
                  Kept => False, Chained => True, Apart => Feed,
                  Routed => Step_Route);
               if not Added then
                  return;
               end if;
               Step_Downs := Products.Length (Steps);
               Step_Room (Model_Runner.Numerics.Element_Count (Used) * Width);

               Add_Down_Bias
                 (Down_Bias, Natural (Width), Experts, Step_Route,
                  Model_Runner.Numerics.Element_Count (Used) * Width, Added);
               if not Added then
                  return;
               end if;
            end if;

            Products.Add_Mix
              (Steps, Natural (Width), Used, Step_Downs, Step_Route, Added,
               Residual_Step => Step_Join,
               Kept => not Carry_Out and then not After and then not Shared);
            if not Added then
               return;
            end if;
            Step_Mix := Products.Length (Steps);
            At_Out := Wanted;
            Step_Room (Width);

            --  And the shared expert, where the mixture has one: the same
            --  gated block an expert is, over the normalized input every
            --  position, scaled by the logistic of its router's one score
            --  a position, and joined to the sum.
            if Shared then
               Products.Add_Chained_Product
                 (Steps, Shared_Gate.Base, Shared_Gate.Span, Shared_Gate.Offset,
                  Shared_Gate_P, Natural (Shared_Gate.Rows),
                  Natural (Shared_Gate.Columns), Added,
                  Key => At_Offset (Shared_Gate.Base, Shared_Gate.Offset),
                  Kept => False, From_Step => Step_Norm_Feed);
               if not Added then
                  return;
               end if;
               Step_Room (Shared_Gate.Rows);

               Products.Add_Chained_Product
                 (Steps, Shared_Up.Base, Shared_Up.Span, Shared_Up.Offset,
                  Shared_Up_P, Natural (Shared_Up.Rows),
                  Natural (Shared_Up.Columns), Added,
                  Key => At_Offset (Shared_Up.Base, Shared_Up.Offset),
                  Kept => False, From_Step => Step_Norm_Feed);
               if not Added then
                  return;
               end if;
               Step_Room (Shared_Up.Rows);

               Products.Add_Combination (Steps, 0, Added, Kept => False);
               if not Added then
                  return;
               end if;
               Step_Room (Shared_Gate.Rows);

               Products.Add_Chained_Product
                 (Steps, Shared_Down.Base, Shared_Down.Span, Shared_Down.Offset,
                  Shared_Down_P, Natural (Shared_Down.Rows),
                  Natural (Shared_Down.Columns), Added,
                  Key => At_Offset (Shared_Down.Base, Shared_Down.Offset),
                  Kept => False);
               if not Added then
                  return;
               end if;
               Step_Room (Width);

               declare
                  Step_Shared : constant Natural := Products.Length (Steps);

                  --  The router's row as a matrix of one row, resident as
                  --  a norm's weight is.
                  At_Row : constant System.Address :=
                    Shared_Router.all (Shared_Router.all'First)'Address;
               begin
                  Products.Add_Chained_Product
                    (Steps, At_Row,
                     Model_Runner.Bytes.Byte_Count (Shared_Router.all'Length) * 4,
                     0, Products.Values_F32, 1, Natural (Width), Added,
                     Key => At_Row, Kept => False, From_Step => Step_Norm_Feed);
                  if not Added then
                     return;
                  end if;
                  Step_Room (1);

                  Products.Add_Combination
                    (Steps, 7, Added, Kept => False,
                     From_Step => Step_Shared,
                     Other_Step => Products.Length (Steps));
                  if not Added then
                     return;
                  end if;
                  Step_Room (Width);
               end;

               Products.Add_Join
                 (Steps, Added, From_Step => Products.Length (Steps),
                  Residual_Step => Step_Mix,
                  Kept => not Carry_Out and then not After);
               if not Added then
                  return;
               end if;
               At_Out := Wanted;
               Step_Room (Width);
            end if;
         else
            if Gated then
               Products.Add_Chained_Product
                 (Steps, Gate.Base, Gate.Span, Gate.Offset, Gate_P,
                  Natural (Gate.Rows), Natural (Gate.Columns), Added,
                  Key => At_Offset (Gate.Base, Gate.Offset), Kept => False,
                  From_Step => Step_Norm_Feed);
               if not Added then
                  return;
               end if;
               Step_Room (Gate.Rows);
            end if;

            Products.Add_Chained_Product
              (Steps, Up.Base, Up.Span, Up.Offset, Up_P,
               Natural (Up.Rows), Natural (Up.Columns), Added,
               Key => At_Offset (Up.Base, Up.Offset), Kept => False,
               From_Step => Step_Norm_Feed);
            if not Added then
               return;
            end if;
            Step_Room (Up.Rows);

            --  Gated, the unit on the gate arm multiplied by the up arm;
            --  not, the unit alone on the one projection up, with its bias
            --  added first because the bias is the projection's.
            if Gated then
               Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                         Alpha => Alpha, Limit => Limit);
            else
               declare
                  Step_Up : Natural := Products.Length (Steps);
               begin
                  Add_Projection_Bias (Up_Bias, Up.Rows, Step_Up, Added);
                  if not Added then
                     return;
                  end if;
               end;

               Products.Add_Combination (Steps, Unit + 4, Added, Kept => False);
            end if;
            if not Added then
               return;
            end if;
            Step_Room (Up.Rows);

            Products.Add_Chained_Product
              (Steps, Down.Base, Down.Span, Down.Offset, Down_P,
               Natural (Down.Rows), Natural (Down.Columns), Added,
               Key => At_Offset (Down.Base, Down.Offset), Kept => False);
            if not Added then
               return;
            end if;
            Step_Downs := Products.Length (Steps);
            Step_Room (Down.Rows);

            --  The projection down's bias, gated or not: the one gated
            --  architecture that shifts what it projects down is jina-bert-v2.
            Add_Projection_Bias (Down_Bias, Down.Rows, Step_Downs, Added);
            if not Added then
               return;
            end if;

            --  And the normalization Gemma puts on what the feed-forward
            --  produced, before the second join reads it.
            if not After then
               Add_Post_Norm (Post_Feed_Norm, Down.Rows, Step_Downs, Added);
               if not Added then
                  return;
               end if;
            end if;

            Products.Add_Join
              (Steps, Added, From_Step => Step_Downs, Residual_Step => Step_Join,
               Kept => not Carry_Out and then not After);
            if not Added then
               return;
            end if;
            At_Out := Wanted;
            Step_Room (Width);
         end if;

         --  Bert's second, over the sum the join or the mix made: the
         --  layer's answer.
         if After then
            declare
               Step_Sum : Natural := Products.Length (Steps);
            begin
               At_Out := Wanted;
               Add_Post_Norm (Post_Feed_Norm, Width, Step_Sum, Added,
                              Kept => not Carry_Out);
               if not Added then
                  return;
               end if;
            end;
         end if;

         if Landing = null or else Landing.all'Length < Wanted then
            T.Free (Landing);
            T.Allocate (Wanted, Landing);
            if Landing = null then
               return;
            end if;
         end if;

         Products.Run
           (Engine, Steps,
            Residual (Residual'First .. Residual'First + Slots * Width - 1),
            Positive (Slots),
            Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
            Ran, Cancelled, Cancel, Carry_In, Carry_Out);

         if Cancelled or else not Ran then
            --  A layer handed back to the host after the one before carried
            --  its answer out starts from that answer, read back from where
            --  the device left it; the host's copy is a layer old.
            if not Cancelled and then Carry_In then
               declare
                  Fetched : Boolean;
               begin
                  Products.Fetch_Carried
                    (Engine,
                     Into.all (Into.all'First
                               .. Into.all'First + Slots * Width - 1),
                     Fetched);
                  Brought_Home := True;
                  if not Fetched then
                     return;
                  end if;
               end;
            end if;
            return;
         end if;

         Note_Timeline (Steps, Positive (Slots));

         --  The keys and the values, where the caller wants them here rather
         --  than out of the device's own cache afterwards.
         if Mirror then
            Values.all (Values.all'First
                        .. Values.all'First + Slots * Value.Rows - 1) :=
              Landing.all (Landing.all'First + At_Values
                           .. Landing.all'First + At_Values
                              + Slots * Value.Rows - 1);

            Keys.all (Keys.all'First .. Keys.all'First + Slots * Key.Rows - 1) :=
              Landing.all (Landing.all'First + At_Keys
                           .. Landing.all'First + At_Keys
                              + Slots * Key.Rows - 1);
         end if;

         --  The answer, where the host is the one that reads it next. Carried
         --  out it stays on the device and Landing holds nothing for it.
         if not Carry_Out then
            Into.all (Into.all'First .. Into.all'First + Slots * Width - 1) :=
              Landing.all (Landing.all'First + At_Out
                           .. Landing.all'First + At_Out + Slots * Width - 1);
         end if;

         Ok := True;
      end Attempt;
   begin
      --  What this layer asks for that the device will not do, before the
      --  sequence is built: the packed block's shape, which is the one
      --  refusal a reader can act on -- a cache asked for in a shape this
      --  device's attention does not read -- and which refuses the layer
      --  where the sequence is built rather than where it is run, so that
      --  Run never sees it. Everything else the sequence finds for itself.
      Layer_Refusal := Not_Handed;
      Products.Forget_Refusal (Engine);

      if Packed.K_Bits /= 0
        and then not Products.Takes_Packed
                       (Engine, Packed, Head_Size, Value_Size,
                        KV_Width, V_Width)
      then
         Layer_Refusal := Packed_Handed;
      end if;

      Attempt;

      --  A layer refused after the one before carried its answer out
      --  leaves the host's copy a layer old: the answer is where the
      --  device left it, and comes home so the host goes on from it. It
      --  did not, and a nibble-cached hybrid whose attention layer the
      --  device would not take went on from the linear layer's input.
      if not Ok and then Carry_In and then not Brought_Home
        and then Into /= null
      then
         declare
            Back : Boolean;
         begin
            Products.Fetch_Carried
              (Engine,
               Into.all (Into.all'First
                         .. Into.all'First + Slots * Width - 1),
               Back);
         end;
      end if;
   end Whole_Layer;

   --------------------
   -- Dispatch_Gated --
   --------------------

   procedure Dispatch_Gated
     (Gate   : T.View;
      Up     : T.View;
      Down   : T.View;
      Vector : T.Real_Array_Access;
      Spread : Model_Runner.Numerics.Element_Count;
      Unit   : Natural;
      Into   : T.Real_Array_Access;
      Status : out E.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0)
   is
      Arms : constant array (1 .. 3) of T.View := [Gate, Up, Down];

      Steps  : Products.Sequence;
      Wanted : Model_Runner.Numerics.Element_Count := 0;
      Added  : Boolean;
      Ok     : Boolean;
      Cancelled : Boolean := False;

      --  The largest of the three, for the same reason.
      Asked  : Interfaces.Unsigned_64 := 0;
   begin
      Status := E.Success;

      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      if Vector = null or else Into = null
        or else Spread = 0
        or else Vector.all'Length < Gate.Columns * Spread
        or else Into.all'Length < Down.Rows * Spread
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Open_Sequence (Steps);

      for Index in Arms'Range loop
         declare
            This : T.View renames Arms (Index);

            Packing : Products.Weight_Packing;
            Known   : Boolean;
         begin
            Packing_Of (This.Format, Packing, Known);
            if not Known then
               Status := E.Make (E.Backend_Capability_Missing);
               E.Add_Text
                 (Status, "capability",
                  Model_Runner.GGUF.Type_Name (This.Format),
                  E.Param_Identifier);
               E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                           E.Param_Identifier);
               return;
            end if;

            if This.Base = System.Null_Address then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            --  The two arms read the supplied activation; the down
            --  projection reads what the combining step wrote, which is the
            --  whole point of sending them together.
            --  Only the down projection's answer is read below. The two
            --  arms and the combined value are the device's business and
            --  now actually stay there: for a batch of a hundred and
            --  twenty-eight that is nine megabytes a layer not copied to
            --  the host to be stepped over.
            if Index = 3 then
               Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                        Alpha => Alpha, Limit => Limit);
               if not Added then
                  Status := E.Make (E.Tensor_Shape_Mismatch);
                  return;
               end if;

               Wanted := Wanted + Gate.Rows * Spread;

               Products.Add_Chained_Product
                 (Steps, This.Base, This.Span, This.Offset, Packing,
                  Natural (This.Rows), Natural (This.Columns), Added,
                  Key => At_Offset (This.Base, This.Offset));
            else
               Products.Add_Product
                 (Steps, This.Base, This.Span, This.Offset, Packing,
                  Natural (This.Rows), Natural (This.Columns), Added,
                  Key => At_Offset (This.Base, This.Offset),
                  Kept => False);
            end if;

            if not Added then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            Asked := Interfaces.Unsigned_64'Max
              (Asked,
               Interfaces.Unsigned_64 (This.Rows)
               * Products.Row_Bytes (Packing, Natural (This.Columns)));

            Wanted := Wanted + This.Rows * Spread;
         end;
      end loop;

      if Landing = null or else Landing.all'Length < Wanted then
         T.Free (Landing);
         T.Allocate (Wanted, Landing);
         if Landing = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;

      Products.Run
        (Engine, Steps, Vector.all, Positive (Spread),
         Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
         Ok, Cancelled, Cancel);

      if Ok then
         Note_Timeline (Steps, Positive (Spread));
      end if;

      if Cancelled then
         Status := E.Make (E.Generation_Cancelled);
         return;
      elsif Products.Is_Stalled (Engine) then
         Status := E.Make (E.Backend_Device_Stalled);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         E.Add_Integer (Status, "limit", Long_Long_Integer (Opened_Patience));
         return;
      elsif not Ok then
         Declined (Status, Asked);
         return;
      end if;

      --  Only the last of the four is wanted here. The arms and the combined
      --  value are the device's business and stay there.
      Into.all (Into.all'First .. Into.all'First + Down.Rows * Spread - 1) :=
        Landing.all
          (Landing.all'First + Wanted - Down.Rows * Spread
           .. Landing.all'First + Wanted - 1);
   end Dispatch_Gated;

   --------------------
   -- Dispatch_Batch --
   --------------------

   procedure Dispatch_Batch
     (Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Exact   : Boolean := False) is
   begin
      Compute (Weight, Vectors, Count, Target, Status, Cancel, Exact);
   end Dispatch_Batch;

   --  What a stack's format, shape and storage have to be before a step
   --  over it is recorded, said once for the two gathered dispatches.
   procedure Check_Stack
     (Stack   : T.View;
      Each    : Model_Runner.Numerics.Element_Count;
      Packing : out Products.Weight_Packing;
      Status  : out E.Error_Info)
   is
      Known : Boolean;
   begin
      Status := E.Success;

      Packing_Of (Stack.Format, Packing, Known);
      if not Known then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text
           (Status, "capability",
            Model_Runner.GGUF.Type_Name (Stack.Format), E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         return;
      end if;

      if Stack.Base = System.Null_Address
        or else Each = 0
        or else Stack.Rows < Each
        or else Stack.Rows mod Each /= 0
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
      end if;
   end Check_Stack;

   --  Run one sequence over one activation and hand back what it made,
   --  saying why where it did not: the same three answers Compute gives,
   --  in the same order.
   procedure Run_Sequence
     (Steps  : Products.Sequence;
      Vector : T.Real_Array_Access;
      Count  : Positive;
      Wanted : Model_Runner.Numerics.Element_Count;
      Asked  : Interfaces.Unsigned_64;
      Status : out E.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference)
   is
      Ok        : Boolean;
      Cancelled : Boolean := False;
   begin
      Status := E.Success;

      if Landing = null or else Landing.all'Length < Wanted then
         T.Free (Landing);
         T.Allocate (Wanted, Landing);
         if Landing = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;

      Products.Run
        (Engine, Steps, Vector.all, Count,
         Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1),
         Ok, Cancelled, Cancel);

      if Ok then
         Note_Timeline (Steps, Count);
      end if;

      if Cancelled then
         Status := E.Make (E.Generation_Cancelled);
      elsif Products.Is_Stalled (Engine) then
         Status := E.Make (E.Backend_Device_Stalled);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         E.Add_Integer (Status, "limit", Long_Long_Integer (Opened_Patience));
      elsif not Ok then
         Declined (Status, Asked);
      end if;
   end Run_Sequence;

   --  The three bias stacks of a mixture whose members the host chose,
   --  as steps of the sequence: the two arms' after both arms, so the
   --  combination reads the biased pair as the two steps before it, and
   --  the projection down's after the downs. Members says which expert
   --  each of the source's Count members is. Nothing added where the
   --  layer carries none.
   procedure Add_Chosen_Biases
     (Steps     : in out Products.Sequence;
      Gate_Bias : T.Real_Array_Access;
      Up_Bias   : T.Real_Array_Access;
      Feed      : Natural;
      Experts   : Natural;
      Members   : Products.Member_List;
      Count     : Positive;
      Added     : out Boolean)
   is
      Gate_Step : constant Natural := Products.Length (Steps) - 1;
      Up_Step   : constant Natural := Products.Length (Steps);
   begin
      Added := True;

      if Gate_Bias = null or else Up_Bias = null then
         Added := Gate_Bias = null and then Up_Bias = null;
         return;
      end if;

      Products.Add_Bias
        (Steps, Gate_Bias.all (Gate_Bias.all'First)'Address,
         Model_Runner.Bytes.Byte_Count (Gate_Bias.all'Length) * 4, 0,
         Experts, Feed, Gate_Step, 0, Added,
         Key => Gate_Bias.all (Gate_Bias.all'First)'Address,
         Kept => False, Members => Members, Count => Count);
      if not Added then
         return;
      end if;

      Products.Add_Bias
        (Steps, Up_Bias.all (Up_Bias.all'First)'Address,
         Model_Runner.Bytes.Byte_Count (Up_Bias.all'Length) * 4, 0,
         Experts, Feed, Up_Step, 0, Added,
         Key => Up_Bias.all (Up_Bias.all'First)'Address,
         Kept => False, Members => Members, Count => Count);
   end Add_Chosen_Biases;

   procedure Add_Chosen_Down_Bias
     (Steps     : in out Products.Sequence;
      Down_Bias : T.Real_Array_Access;
      Width     : Natural;
      Experts   : Natural;
      Members   : Products.Member_List;
      Count     : Positive;
      Added     : out Boolean) is
   begin
      Added := True;

      if Down_Bias = null then
         return;
      end if;

      Products.Add_Bias
        (Steps, Down_Bias.all (Down_Bias.all'First)'Address,
         Model_Runner.Bytes.Byte_Count (Down_Bias.all'Length) * 4, 0,
         Experts, Width, Products.Length (Steps), 0, Added,
         Key => Down_Bias.all (Down_Bias.all'First)'Address,
         Members => Members, Count => Count);
   end Add_Chosen_Down_Bias;

   --------------------
   -- Dispatch_Slice --
   --------------------

   procedure Dispatch_Slice
     (Stack   : T.View;
      Each    : Model_Runner.Numerics.Element_Count;
      Member  : Natural;
      Vectors : T.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null)
   is
      Steps   : Products.Sequence;
      Packing : Products.Weight_Packing;
      Added   : Boolean;
      Wanted  : constant Model_Runner.Numerics.Element_Count := Each * Count;
   begin
      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Check_Stack (Stack, Each, Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Vectors = null or else Target = null or else Count = 0
        or else Vectors.all'Length < Count * Stack.Columns
        or else Target.all'Length < Wanted
        or else Model_Runner.Numerics.Element_Count (Member + 1) * Each
                > Stack.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Open_Sequence (Steps);
      Products.Add_Gathered_Product
        (Steps, Stack.Base, Stack.Span, Stack.Offset, Packing,
         Natural (Stack.Rows), Natural (Each), Natural (Stack.Columns),
         [1 => Member, others => 0], 1, Added,
         Key => At_Offset (Stack.Base, Stack.Offset));
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Run_Sequence
        (Steps, Vectors, Positive (Count), Wanted,
         Interfaces.Unsigned_64 (Stack.Rows)
         * Products.Row_Bytes (Packing, Natural (Stack.Columns)),
         Status, Cancel);
      if E.Is_Error (Status) then
         return;
      end if;

      Target.all (Target.all'First .. Target.all'First + Wanted - 1) :=
        Landing.all (Landing.all'First .. Landing.all'First + Wanted - 1);
   end Dispatch_Slice;

   ---------------------
   -- Dispatch_Expert --
   ---------------------

   procedure Dispatch_Expert
     (Gates   : T.View;
      Ups     : T.View;
      Downs   : T.View;
      Feed    : Model_Runner.Numerics.Element_Count;
      Width   : Model_Runner.Numerics.Element_Count;
      Member  : Natural;
      Unit    : Natural;
      Vectors : T.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Gate_Bias : Model_Runner.Tensors.Real_Array_Access := null;
      Up_Bias   : Model_Runner.Tensors.Real_Array_Access := null;
      Down_Bias : Model_Runner.Tensors.Real_Array_Access := null)
   is
      Steps : Products.Sequence;
      Gate_Packing, Up_Packing, Down_Packing : Products.Weight_Packing;
      Added : Boolean;

      Arms   : constant Model_Runner.Numerics.Element_Count := Count * Feed;
      Outs   : constant Model_Runner.Numerics.Element_Count := Count * Width;

      --  Biased, two more of the arms' size and one more of the answer's:
      --  the biasing steps' rooms.
      Biased : constant Boolean := Gate_Bias /= null;
      Wanted : constant Model_Runner.Numerics.Element_Count :=
        3 * Arms + Outs + (if Biased then 2 * Arms + Outs else 0);
   begin
      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Check_Stack (Gates, Feed, Gate_Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Check_Stack (Ups, Feed, Up_Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Check_Stack (Downs, Width, Down_Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Vectors = null or else Target = null or else Count = 0
        or else Gates.Columns /= Width or else Ups.Columns /= Width
        or else Downs.Columns /= Feed
        or else Gates.Rows /= Ups.Rows
        or else Vectors.all'Length < Count * Width
        or else Target.all'Length < Outs
        or else Model_Runner.Numerics.Element_Count (Member + 1) * Feed
                > Gates.Rows
        or else Model_Runner.Numerics.Element_Count (Member + 1) * Width
                > Downs.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Open_Sequence (Steps);

      Products.Add_Gathered_Product
        (Steps, Gates.Base, Gates.Span, Gates.Offset, Gate_Packing,
         Natural (Gates.Rows), Natural (Feed), Natural (Width),
         [1 => Member, others => 0], 1, Added,
         Key => At_Offset (Gates.Base, Gates.Offset), Kept => False);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Add_Gathered_Product
        (Steps, Ups.Base, Ups.Span, Ups.Offset, Up_Packing,
         Natural (Ups.Rows), Natural (Feed), Natural (Width),
         [1 => Member, others => 0], 1, Added,
         Key => At_Offset (Ups.Base, Ups.Offset), Kept => False);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Add_Chosen_Biases
        (Steps, Gate_Bias, Up_Bias, Natural (Feed),
         Natural (Gates.Rows / Feed), [1 => Member, others => 0], 1, Added);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                        Alpha => Alpha, Limit => Limit);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Add_Gathered_Product
        (Steps, Downs.Base, Downs.Span, Downs.Offset, Down_Packing,
         Natural (Downs.Rows), Natural (Width), Natural (Feed),
         [1 => Member, others => 0], 1, Added,
         Key => At_Offset (Downs.Base, Downs.Offset), Chained => True,
         Kept => Down_Bias = null);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Add_Chosen_Down_Bias
        (Steps, Down_Bias, Natural (Width), Natural (Downs.Rows / Width),
         [1 => Member, others => 0], 1, Added);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Run_Sequence
        (Steps, Vectors, Positive (Count), Wanted,
         Interfaces.Unsigned_64'Max
           (Interfaces.Unsigned_64 (Gates.Rows)
            * Interfaces.Unsigned_64 (T.Row_Bytes (Gates)),
            Interfaces.Unsigned_64 (Downs.Rows)
            * Interfaces.Unsigned_64 (T.Row_Bytes (Downs))),
         Status, Cancel);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The answer is the last step's: the downs', or the bias's after.
      Target.all (Target.all'First .. Target.all'First + Outs - 1) :=
        Landing.all (Landing.all'First + Wanted - Outs
                     .. Landing.all'First + Wanted - 1);
   end Dispatch_Expert;

   ----------
   -- Hold --
   ----------

   procedure Hold
     (Weight : T.View;
      Status : out E.Error_Info)
   is
      Packing : Products.Weight_Packing;
      Known   : Boolean;
      Ok      : Boolean;
   begin
      Status := E.Success;

      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Packing_Of (Weight.Format, Packing, Known);
      if not Known or else Weight.Base = System.Null_Address then
         Status := E.Make (E.Backend_Capability_Missing);
         return;
      end if;

      declare
         Storage : Model_Runner.Bytes.Byte_Array (1 .. Weight.Span)
           with Import, Address => Weight.Base;
      begin
         Products.Hold
           (Engine, Storage, Weight.Offset, Packing,
            Natural (Weight.Rows), Natural (Weight.Columns),
            Key => Storage (Storage'First + Weight.Offset)'Address,
            Ok => Ok);
      end;

      if not Ok then
         Declined
           (Status,
            Interfaces.Unsigned_64 (Weight.Rows)
            * Interfaces.Unsigned_64 (T.Row_Bytes (Weight)));
      end if;
   end Hold;

   --------------------
   -- Dispatch_Route --
   --------------------

   procedure Dispatch_Route
     (Router      : T.View;
      Router_Bias : T.Real_Array_Access;
      Experts     : Natural;
      Used        : Natural;
      Vectors     : T.Real_Array_Access;
      Count       : Model_Runner.Numerics.Element_Count;
      Choice      : out Choice_Array;
      Shares      : out Model_Runner.Numerics.Real_Array;
      Status      : out E.Error_Info;
      Cancel      : Model_Runner.Cancellation.Token_Reference := null)
   is
      use type Interfaces.Unsigned_32;

      function Bits is new Ada.Unchecked_Conversion
        (Model_Runner.Numerics.Real, Interfaces.Unsigned_32);
      function Value is new Ada.Unchecked_Conversion
        (Interfaces.Unsigned_32, Model_Runner.Numerics.Real);

      Steps   : Products.Sequence;
      Packing : Products.Weight_Packing;
      Known   : Boolean;
      Added   : Boolean;

      Scores : constant Model_Runner.Numerics.Element_Count :=
        Count * Model_Runner.Numerics.Element_Count (Experts);
      Words  : constant Model_Runner.Numerics.Element_Count :=
        Count * Model_Runner.Numerics.Element_Count (2 * Used);
      Wanted : constant Model_Runner.Numerics.Element_Count :=
        Scores + Words;
   begin
      Choice := [others => 0];
      Shares := [others => 0.0];

      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      Packing_Of (Router.Format, Packing, Known);
      if not Known then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text
           (Status, "capability",
            Model_Runner.GGUF.Type_Name (Router.Format), E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         return;
      end if;

      if Vectors = null or else Count = 0 or else Used = 0
        or else Used > Max_Members or else Experts < Used
        or else Router.Base = System.Null_Address
        or else Natural (Router.Rows) /= Experts
        or else Vectors.all'Length < Count * Router.Columns
        or else Choice'Length < Count * Model_Runner.Numerics.Element_Count (Used)
        or else Shares'Length < Count * Model_Runner.Numerics.Element_Count (Used)
        or else (Router_Bias /= null
                 and then Natural (Router_Bias.all'Length) /= Experts)
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Open_Sequence (Steps);
      Products.Add_Product
        (Steps, Router.Base, Router.Span, Router.Offset, Packing,
         Natural (Router.Rows), Natural (Router.Columns), Added,
         Key => At_Offset (Router.Base, Router.Offset), Kept => False);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      if Router_Bias = null then
         Products.Add_Route (Steps, Experts, Used, Added);
      else
         Products.Add_Route
           (Steps, Experts, Used, Added,
            Bias => Router_Bias.all (Router_Bias.all'First)'Address,
            Bias_Span =>
              Model_Runner.Bytes.Byte_Count (Router_Bias.all'Length) * 4,
            Bias_At => 0);
      end if;
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Run_Sequence
        (Steps, Vectors, Positive (Count), Wanted,
         Interfaces.Unsigned_64 (Router.Rows)
         * Interfaces.Unsigned_64 (T.Row_Bytes (Router)),
         Status, Cancel);
      if E.Is_Error (Status) then
         return;
      end if;

      --  What the routing step wrote, position by position: the expert
      --  numbers as words and the shares as the bits of a binary32, both
      --  carried through the binary32 landing as bits.
      for Where in 0 .. Count - 1 loop
         for Slot in 0 .. Model_Runner.Numerics.Element_Count (Used) - 1 loop
            declare
               At_Word : constant Model_Runner.Numerics.Element_Count :=
                 Landing.all'First + Scores
                 + Where * Model_Runner.Numerics.Element_Count (2 * Used);
               Into : constant Model_Runner.Numerics.Element_Count :=
                 Where * Model_Runner.Numerics.Element_Count (Used) + Slot;
            begin
               Choice (Choice'First + Natural (Into)) :=
                 Natural (Bits (Landing.all (At_Word + Slot)));
               Shares (Shares'First + Into) :=
                 Value
                   (Bits (Landing.all
                            (At_Word
                             + Model_Runner.Numerics.Element_Count (Used)
                             + Slot)));
            end;
         end loop;
      end loop;
   end Dispatch_Route;

   ----------------------
   -- Dispatch_Mixture --
   ----------------------

   procedure Dispatch_Mixture
     (Gates   : T.View;
      Ups     : T.View;
      Downs   : T.View;
      Feed    : Model_Runner.Numerics.Element_Count;
      Width   : Model_Runner.Numerics.Element_Count;
      Members : Member_List;
      Count   : Positive;
      Unit    : Natural;
      Vector  : T.Real_Array_Access;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Alpha : Model_Runner.Numerics.Real := 0.0;
      Limit : Model_Runner.Numerics.Real := 0.0;
      Gate_Bias : Model_Runner.Tensors.Real_Array_Access := null;
      Up_Bias   : Model_Runner.Tensors.Real_Array_Access := null;
      Down_Bias : Model_Runner.Tensors.Real_Array_Access := null)
   is
      Steps : Products.Sequence;
      Gate_Packing, Up_Packing, Down_Packing : Products.Weight_Packing;
      Added : Boolean;

      Chosen : Products.Member_List := [others => 0];

      --  Room for every step's answer, kept or not: three of Count times
      --  Feed and one of Count times Width, in that order.
      Arms   : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Count) * Feed;
      Outs   : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Count) * Width;

      --  Biased, two more of the arms' size and one more of the answer's:
      --  the biasing steps' rooms.
      Biased : constant Boolean := Gate_Bias /= null;
      Wanted : constant Model_Runner.Numerics.Element_Count :=
        3 * Arms + Outs + (if Biased then 2 * Arms + Outs else 0);

      Asked : Interfaces.Unsigned_64 := 0;
   begin
      if not Ready_Now then
         Status := E.Make (E.Backend_Closed);
         return;
      end if;

      if Count > Max_Members then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Check_Stack (Gates, Feed, Gate_Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Check_Stack (Ups, Feed, Up_Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Check_Stack (Downs, Width, Down_Packing, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Vector = null or else Target = null
        or else Gates.Columns /= Width or else Ups.Columns /= Width
        or else Downs.Columns /= Feed
        or else Gates.Rows /= Ups.Rows
        or else Vector.all'Length < Width
        or else Target.all'Length < Outs
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      for Index in 1 .. Count loop
         if Model_Runner.Numerics.Element_Count (Members (Index) + 1) * Feed
            > Gates.Rows
           or else Model_Runner.Numerics.Element_Count (Members (Index) + 1)
                   * Width > Downs.Rows
         then
            Status := E.Make (E.Tensor_Shape_Mismatch);
            return;
         end if;

         Chosen (Index) := Members (Index);
      end loop;

      Asked := Interfaces.Unsigned_64'Max
        (Interfaces.Unsigned_64'Max
           (Interfaces.Unsigned_64 (Gates.Rows)
            * Interfaces.Unsigned_64 (T.Row_Bytes (Gates)),
            Interfaces.Unsigned_64 (Ups.Rows)
            * Interfaces.Unsigned_64 (T.Row_Bytes (Ups))),
         Interfaces.Unsigned_64 (Downs.Rows)
         * Interfaces.Unsigned_64 (T.Row_Bytes (Downs)));

      --  The gates and the ups, each gathered, both reading the activation;
      --  the unit and the multiply; the downs gathered, each reading its
      --  own stretch of what the combination made.
      Products.Open_Sequence (Steps);

      Products.Add_Gathered_Product
        (Steps, Gates.Base, Gates.Span, Gates.Offset, Gate_Packing,
         Natural (Gates.Rows), Natural (Feed), Natural (Width),
         Chosen, Count, Added,
         Key => At_Offset (Gates.Base, Gates.Offset), Kept => False);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Add_Gathered_Product
        (Steps, Ups.Base, Ups.Span, Ups.Offset, Up_Packing,
         Natural (Ups.Rows), Natural (Feed), Natural (Width),
         Chosen, Count, Added,
         Key => At_Offset (Ups.Base, Ups.Offset), Kept => False);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Add_Chosen_Biases
        (Steps, Gate_Bias, Up_Bias, Natural (Feed),
         Natural (Gates.Rows / Feed), Chosen, Count, Added);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Add_Combination (Steps, Unit, Added, Kept => False,
                                        Alpha => Alpha, Limit => Limit);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Products.Add_Gathered_Product
        (Steps, Downs.Base, Downs.Span, Downs.Offset, Down_Packing,
         Natural (Downs.Rows), Natural (Width), Natural (Feed),
         Chosen, Count, Added,
         Key => At_Offset (Downs.Base, Downs.Offset),
         Chained => True, Apart => Natural (Feed),
         Kept => Down_Bias = null);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Add_Chosen_Down_Bias
        (Steps, Down_Bias, Natural (Width), Natural (Downs.Rows / Width),
         Chosen, Count, Added);
      if not Added then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      Run_Sequence (Steps, Vector, 1, Wanted, Asked, Status, Cancel);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The answer is the last step's: the downs', or the bias's after.
      Target.all (Target.all'First .. Target.all'First + Outs - 1) :=
        Landing.all (Landing.all'First + Wanted - Outs
                     .. Landing.all'First + Wanted - 1);
   end Dispatch_Mixture;

end Model_Runner.Backend.Device;
