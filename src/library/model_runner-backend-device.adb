with Model_Runner.Bytes;
with Model_Runner.Platform.Device.Products;

package body Model_Runner.Backend.Device is

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Bytes.Byte_Array_Access;
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

   function Imported return Natural is (Products.Imported (Engine));

   -----------------
   -- Given_Back --
   -----------------

   function Given_Back return Natural is (Products.Given_Back (Engine));

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
        or else Weight.Data = null
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
           or else Weight.Data.all'Length < Weight.Offset + Bytes
         then
            Status := E.Make (E.Tensor_Shape_Mismatch);
            return;
         end if;

         --  The whole storage, and where in it this matrix begins. Not the
         --  matrix alone: a device reading the weights where they lie is
         --  handed a page-aligned range, and a range described by the matrix
         --  alone would be one nobody could check the ends of.
         declare
            Storage : Model_Runner.Bytes.Byte_Array
              (1 .. Weight.Data.all'Length)
              with Import, Address => Weight.Data.all'Address;
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
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "capability", "matrix_vector",
                     E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
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

            if This.Data = null
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
              (Steps, This.Data, This.Offset, Packing,
               Natural (This.Rows), Natural (This.Columns), Added,
               Key => This.Data.all
                        (This.Data.all'First + This.Offset)'Address);
            if not Added then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

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
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "capability", "matrix_vector",
                     E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
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
