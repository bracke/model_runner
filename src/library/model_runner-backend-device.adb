with System;
with System.Storage_Elements;

with Model_Runner.Bytes;
with Model_Runner.Platform.Device.Products;

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
      --  Read from Is_Supported rather than listed here, because a list here
      --  is a second copy of one: the two lists that have to agree are the
      --  shader's branches and this, and the test that compares them
      --  multiplies a matrix in each format on the device.
      Result.Formats := [others => False];
      for Format in Model_Runner.GGUF.Tensor_Type loop
         Result.Formats (Format) := Model_Runner.GGUF.Is_Supported (Format);
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

   function Cached_Bytes return Interfaces.Unsigned_64
   is (Products.Cached_Bytes (Engine));

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
     (Weight  : T.View;
      Packing : out Products.Weight_Packing;
      Known   : out Boolean) is
   begin
      Packing := Products.Values_F32;
      Known := True;

      --  One arm per format the shader decodes, which is every format this
      --  program reads. The others in Tensor_Type are the ones the parser
      --  recognizes and nothing here decodes -- Q8_1, Q8_K -- and a model in
      --  one of those is refused before it reaches a backend at all.
      case Weight.Format is
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
      Cancel  : Model_Runner.Cancellation.Token_Reference := null)
   is
      Packing   : Products.Weight_Packing;
      Known     : Boolean;
      Ok        : Boolean;
      Cancelled : Boolean := False;

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

      Packing_Of (Weight, Packing, Known);
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
         declare
            Storage : Model_Runner.Bytes.Byte_Array (1 .. Weight.Span)
              with Import, Address => Weight.Base;
         begin
            Products.Multiply
              (Engine, Storage, Weight.Offset, Packing,
               Natural (Weight.Rows), Natural (Weight.Columns),
               Vectors.all, Positive (Count), Target.all, Ok, Cancelled,
               Key => Storage (Storage'First + Weight.Offset)'Address,
               Cancel => Cancel);
         end;
      end;

      --  Asked to stop comes before could not compute, because it is the
      --  truer answer: the product did reach the device and did run there.
      if Cancelled then
         Status := E.Make (E.Generation_Cancelled);
      elsif Products.Is_Stalled (Engine) then
         --  The device did not finish inside the whole bound. Its own code
         --  rather than the one for a machine with no device, which is what
         --  this used to borrow: there is a device, nothing about this model
         --  or this request was wrong, and what a caller can do about it --
         --  wait for whatever else is using the device, or say they are
         --  willing to wait longer -- is not what the other message
         --  suggests. A diagnostic that sends a reader the wrong way is
         --  worse than a vague one.
         Status := E.Make (E.Backend_Device_Stalled);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         E.Add_Integer
           (Status, "limit", Long_Long_Integer (Opened_Patience));
      elsif not Ok then
         Declined (Status, Asked);
      end if;
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
     (Elements : Model_Runner.Numerics.Element_Count;
      Ok       : out Boolean) is
   begin
      if not Ready_Now then
         Ok := False;
         return;
      end if;

      Products.Reserve (Engine, Elements, Ok);
   end Reserve_Cache;

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
      Max_Bias   : Model_Runner.Numerics.Real := 0.0)
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

      Packing_Of (Weight, Packing, Known);
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
         Kept => False);
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
      Lifted      : Boolean := False;
      Max_Bias    : Model_Runner.Numerics.Real := 0.0;
      Table_At    : Natural := 0)
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

      Packing_Of (Weight, Packing, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Gate, Gate_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Up, Up_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Down, Down_P, Known);
      if not Known then
         return;
      end if;

      Products.Open_Sequence (Steps);

      Products.Add_Attention
        (Steps, Heads, Head_Size, Value_Size, Group_Size, First, Last,
         K_Base, V_Base, KV_Width, V_Width, Scale, Cap, Added,
         Window => Window, Causal => Causal, Max_Bias => Max_Bias,
         Kept => False, Table_At => Table_At);
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
            From_Step => 3, Lifted => Lifted, Key => At_Norm,
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

      Products.Add_Combination (Steps, Unit, Added, Kept => False);
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
      Cancel  : Model_Runner.Cancellation.Token_Reference := null)
   is
      Steps  : Products.Sequence;
      Wanted : Model_Runner.Numerics.Element_Count := 0;
      Added  : Boolean;
      Ok     : Boolean;
      Cancelled : Boolean := False;

      --  The largest of the matrices, which is the one a refusal is about:
      --  they reach the device one buffer each.
      Asked  : Interfaces.Unsigned_64 := 0;
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
            Packing_Of (This, Packing, Known);
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

            if This.Base = System.Null_Address
              or else Vector = null
              or else Into (Into'First + (Index - Weights'First)) = null
              or else Vector.all'Length < This.Columns
              or else Into (Into'First + (Index - Weights'First)).all'Length
                        < This.Rows
            then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            Products.Add_Product
              (Steps, This.Base, This.Span, This.Offset, Packing,
               Natural (This.Rows), Natural (This.Columns), Added,
               Key => At_Offset (This.Base, This.Offset));
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
      Lifted      : Boolean := False;
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
            Lifted => Lifted, Key => At_Norm, Kept => False);
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
            Packing_Of (This, Packing, Known);

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
      Attention_Norm : T.Real_Array;
      Feed_Norm      : T.Real_Array;
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
      Lifted         : Boolean := False;
      Max_Bias       : Model_Runner.Numerics.Real := 0.0;
      Cancel         : Model_Runner.Cancellation.Token_Reference := null;
      Carry_In       : Boolean := False;
      Carry_Out      : Boolean := False;
      Mirror         : Boolean := True)
   is

      Slots : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Natural'Max (Positions, 1));

      Width : constant Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Attention_Norm'Length);

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
      Known   : Boolean;

      --  Every step's rows, in order, so the offsets above are a sum rather
      --  than a tally kept by hand.
      procedure Step_Room (Rows : Model_Runner.Numerics.Element_Count) is
      begin
         Wanted := Wanted + Rows * Slots;
      end Step_Room;
   begin
      Ok := False;

      if not Ready_Now
        or else Width = 0
        or else Head_Size = 0
        or else Rotary = 0
        or else Rotary > Head_Size
        or else Rotary mod 2 /= 0
        or else Heads = 0
        or else Keys = null or else Values = null or else Into = null
        or else Feed_Norm'Length /= Attention_Norm'Length
        or else Residual'Length < Slots * Width
        or else Query.Columns /= Width
        or else Key.Columns /= Width
        or else Value.Columns /= Width
        or else Turns'Length
                  /= Slots * Model_Runner.Numerics.Element_Count (Rotary)
        or else Keys.all'Length < Slots * Key.Rows
        or else Values.all'Length < Slots * Value.Rows
        or else Into.all'Length < Slots * Width
      then
         return;
      end if;

      Packing_Of (Query, Q_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Key, K_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Value, V_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Weight, Packing, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Gate, Gate_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Up, Up_P, Known);
      if not Known then
         return;
      end if;
      Packing_Of (Down, Down_P, Known);
      if not Known then
         return;
      end if;

      Products.Open_Sequence (Steps);

      --  One: the normalization on the way in, of what the caller handed us.
      declare
         At_Norm : constant System.Address :=
           Attention_Norm (Attention_Norm'First)'Address;
      begin
         Products.Add_Norm
           (Steps, At_Norm,
            Model_Runner.Bytes.Byte_Count (Attention_Norm'Length) * 4, 0,
            Natural (Width), Epsilon, Added,
            Lifted => Lifted, Key => At_Norm, Kept => False);
      end;
      if not Added then
         return;
      end if;
      Step_Room (Width);

      --  Two, three and four: the queries, the keys and the values, each
      --  reading the normalization rather than the step before it.
      Products.Add_Chained_Product
        (Steps, Query.Base, Query.Span, Query.Offset, Q_P,
         Natural (Query.Rows), Natural (Query.Columns), Added,
         Key => At_Offset (Query.Base, Query.Offset), Kept => False,
         From_Step => 1);
      if not Added then
         return;
      end if;
      Step_Room (Query.Rows);

      Products.Add_Chained_Product
        (Steps, Key.Base, Key.Span, Key.Offset, K_P,
         Natural (Key.Rows), Natural (Key.Columns), Added,
         Key => At_Offset (Key.Base, Key.Offset), Kept => False,
         From_Step => 1);
      if not Added then
         return;
      end if;
      Step_Room (Key.Rows);

      Products.Add_Chained_Product
        (Steps, Value.Base, Value.Span, Value.Offset, V_P,
         Natural (Value.Rows), Natural (Value.Columns), Added,
         Key => At_Offset (Value.Base, Value.Offset), Kept => Mirror,
         From_Step => 1);
      if not Added then
         return;
      end if;
      At_Values := Wanted;
      Step_Room (Value.Rows);

      --  Five and six: the turning, of the queries and of the keys.
      declare
         At_Turn : constant System.Address := Turns (Turns'First)'Address;

         Span : constant Model_Runner.Bytes.Byte_Count :=
           Model_Runner.Bytes.Byte_Count (Turns'Length) * 8;

         Pairing : constant Products.Rotary_Pairing :=
           (if Split then Products.Split else Products.Interleaved);
      begin
         Products.Add_Rotation
           (Steps, At_Turn, Span, 0, Natural (Query.Rows),
            Natural (Query.Rows) / Head_Size, Rotary, Pairing, Added,
            From_Step => 2, Kept => False);
         if not Added then
            return;
         end if;
         Step_Room (Query.Rows);

         Products.Add_Rotation
           (Steps, At_Turn, Span, 0, Natural (Key.Rows),
            Natural (Key.Rows) / Head_Size, Rotary, Pairing, Added,
            From_Step => 3, Kept => Mirror);
         if not Added then
            return;
         end if;
         At_Keys := Wanted;
         Step_Room (Key.Rows);
      end;

      --  Seven and eight: into the cache, before anything attends to it.
      Products.Add_Place
        (Steps, Natural (Key.Rows), KV_Width, At_Key, Added,
         From_Step => 6);
      if not Added then
         return;
      end if;
      Step_Room (Key.Rows);

      Products.Add_Place
        (Steps, Natural (Value.Rows), V_Width, At_Value, Added,
         From_Step => 4);
      if not Added then
         return;
      end if;
      Step_Room (Value.Rows);

      --  Nine: attention, against the queries five steps back.
      Products.Add_Attention
        (Steps, Heads, Head_Size, Value_Size, Group_Size, First, Last,
         K_Base, V_Base, KV_Width, V_Width, Scale, Cap, Added,
         Window => Window, Causal => Causal, Max_Bias => Max_Bias,
         Chained => True, From_Step => 5, Kept => False);
      if not Added then
         return;
      end if;
      Step_Room
        (Model_Runner.Numerics.Element_Count (Heads * Value_Size));

      --  Ten through seventeen: the second half, as Attend_And_Feed builds
      --  it, with the residual coming from the front of the activation
      --  rather than the back of it -- there is nothing else in it now.
      Products.Add_Chained_Product
        (Steps, Weight.Base, Weight.Span, Weight.Offset, Packing,
         Natural (Weight.Rows), Natural (Weight.Columns), Added,
         Key => At_Offset (Weight.Base, Weight.Offset), Kept => False);
      if not Added then
         return;
      end if;
      Step_Room (Weight.Rows);

      Products.Add_Join (Steps, Added, From_Step => 10, Kept => False);
      if not Added then
         return;
      end if;
      Step_Room (Width);

      declare
         At_Feed : constant System.Address :=
           Feed_Norm (Feed_Norm'First)'Address;
      begin
         Products.Add_Norm
           (Steps, At_Feed,
            Model_Runner.Bytes.Byte_Count (Feed_Norm'Length) * 4, 0,
            Natural (Width), Epsilon, Added,
            From_Step => 11, Lifted => Lifted, Key => At_Feed,
            Kept => False);
      end;
      if not Added then
         return;
      end if;
      Step_Room (Width);

      Products.Add_Chained_Product
        (Steps, Gate.Base, Gate.Span, Gate.Offset, Gate_P,
         Natural (Gate.Rows), Natural (Gate.Columns), Added,
         Key => At_Offset (Gate.Base, Gate.Offset), Kept => False,
         From_Step => 12);
      if not Added then
         return;
      end if;
      Step_Room (Gate.Rows);

      Products.Add_Chained_Product
        (Steps, Up.Base, Up.Span, Up.Offset, Up_P,
         Natural (Up.Rows), Natural (Up.Columns), Added,
         Key => At_Offset (Up.Base, Up.Offset), Kept => False,
         From_Step => 12);
      if not Added then
         return;
      end if;
      Step_Room (Up.Rows);

      Products.Add_Combination (Steps, Unit, Added, Kept => False);
      if not Added then
         return;
      end if;
      Step_Room (Gate.Rows);

      Products.Add_Chained_Product
        (Steps, Down.Base, Down.Span, Down.Offset, Down_P,
         Natural (Down.Rows), Natural (Down.Columns), Added,
         Key => At_Offset (Down.Base, Down.Offset), Kept => False);
      if not Added then
         return;
      end if;
      Step_Room (Down.Rows);

      Products.Add_Join
        (Steps, Added, From_Step => 16, Residual_Step => 11,
         Kept => not Carry_Out);
      if not Added then
         return;
      end if;
      At_Out := Wanted;
      Step_Room (Width);

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
         return;
      end if;

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
      Cancel : Model_Runner.Cancellation.Token_Reference := null)
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
            Packing_Of (This, Packing, Known);
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
               Products.Add_Combination (Steps, Unit, Added, Kept => False);
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
      Cancel  : Model_Runner.Cancellation.Token_Reference := null) is
   begin
      Compute (Weight, Vectors, Count, Target, Status, Cancel);
   end Dispatch_Batch;

end Model_Runner.Backend.Device;
