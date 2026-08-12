with Interfaces;

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

   Named      : String (1 .. Devices.Max_Name_Bytes) := [others => ' '];
   Named_Last : Natural := 0;

   --------------
   -- Describe --
   --------------

   function Describe return Capabilities is
      Result : Capabilities;
   begin
      Result.Kind := Backend_Device;

      --  The formats the shader decodes for itself. Everything else this
      --  program reads is packed bits with a scale in a layout of its own,
      --  and each of those is a branch in the shader and a fixture to check
      --  it against; these two are the ones a model on this machine is
      --  actually written in. The rest reach a device through --repack f32,
      --  at four bytes a weight.
      Result.Formats := [others => False];
      Result.Formats (Model_Runner.GGUF.Type_F32) := True;
      Result.Formats (Model_Runner.GGUF.Type_Q8_0) := True;
      Result.Formats (Model_Runner.GGUF.Type_Q4_0) := True;

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

      return Result;
   end Describe;

   ----------
   -- Open --
   ----------

   procedure Open (Ready : out Boolean) is
      Found : Boolean;
   begin
      if Ready_Now then
         Ready := True;
         return;
      end if;

      Close;
      Ready := False;

      Devices.Open (Held, Found);
      if not Found or else Devices.Count (Held) = 0 then
         return;
      end if;

      --  The first device the host names. Choosing between several is a
      --  thing to offer when there is a reason to prefer one, and on the
      --  machines this has been run on the reason would be a guess.
      Devices.Open (Opened, Held, 1, Found);
      if not Found then
         return;
      end if;

      Products.Open (Engine, Opened, Found);
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

      Ready_Now := True;
      Ready := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close is
   begin
      Products.Close (Engine);
      Devices.Close (Opened);
      Devices.Close (Held);
      Ready_Now := False;
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

      case Weight.Format is
         when Model_Runner.GGUF.Type_F32 =>
            Packing := Products.Values_F32;

         when Model_Runner.GGUF.Type_Q8_0 =>
            Packing := Products.Packed_Q8_0;

         when Model_Runner.GGUF.Type_Q4_0 =>
            Packing := Products.Packed_Q4_0;

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
      Status  : out E.Error_Info)
   is
      Packing : Products.Weight_Packing;
      Known   : Boolean;
      Ok      : Boolean;
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

         declare
            Storage : constant Model_Runner.Bytes.Byte_Array (1 .. Bytes)
              with Import,
                   Address =>
                     Weight.Data.all (Weight.Data.all'First + Weight.Offset)
                       'Address;
         begin
            Products.Multiply
              (Engine, Storage, Packing,
               Natural (Weight.Rows), Natural (Weight.Columns),
               Vectors.all, Positive (Count), Target.all, Ok,
               Key => Storage'Address);
         end;
      end;

      if not Ok then
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
      Status : out E.Error_Info) is
   begin
      Compute (Weight, Vector, 1, Target, Status);
   end Dispatch;

   --------------------
   -- Dispatch_Batch --
   --------------------

   procedure Dispatch_Batch
     (Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info) is
   begin
      Compute (Weight, Vectors, Count, Target, Status);
   end Dispatch_Batch;

end Model_Runner.Backend.Device;
