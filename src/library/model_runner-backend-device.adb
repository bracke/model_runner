with Model_Runner.Bytes;
with Model_Runner.Platform.Device.Products;

package body Model_Runner.Backend.Device is

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Bytes.Byte_Count;

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

      --  One format. Everything else this program decodes is packed bits
      --  with a scale, and unpacking those is a shader per format.
      Result.Formats := [others => False];
      Result.Formats (Model_Runner.GGUF.Type_F32) := True;

      Result.Alignment := 4;
      Result.Supports_Matrix_Vector := True;

      --  A batch would be a second shader and a second thing to check. One
      --  vector at a time is what this computes, and saying so is what makes
      --  the engine hand it one at a time rather than find out.
      Result.Supports_Batched := False;
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

   --------------
   -- Dispatch --
   --------------

   procedure Dispatch
     (Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Ok : Boolean;
   begin
      Status := E.Success;

      if not Ready_Now then
         Status := E.Make (E.Lifecycle_Invalid_State);
         return;
      end if;

      if Weight.Format /= Model_Runner.GGUF.Type_F32 then
         Status := E.Make (E.Backend_Unsupported_Format);
         E.Add_Text
           (Status, "format",
            Model_Runner.GGUF.Type_Name (Weight.Format), E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
         return;
      end if;

      if Vector = null or else Target = null
        or else Weight.Data = null
        or else Vector.all'Length < Weight.Columns
        or else Target.all'Length < Weight.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      --  The weights, as the values they already are. A binary32 view is a
      --  run of them at a known offset, so what the device is handed is the
      --  model's own storage read as what it holds -- no copy on this side
      --  of the interface.
      declare
         Count : constant Model_Runner.Numerics.Element_Count :=
           Weight.Rows * Weight.Columns;

         Values : constant Real_Array (0 .. Count - 1)
           with Import,
                Address =>
                  Weight.Data.all (Weight.Data.all'First + Weight.Offset)
                    'Address;
      begin
         Products.Multiply
           (Engine, Values, Vector.all,
            Natural (Weight.Rows), Natural (Weight.Columns),
            Target.all, Ok,
            Key => Values'Address);
      end;

      if not Ok then
         Status := E.Make (E.Backend_Capability_Missing);
         E.Add_Text (Status, "capability", "matrix_vector",
                     E.Param_Identifier);
         E.Add_Text (Status, "backend", Backend_Name (Backend_Device),
                     E.Param_Identifier);
      end if;
   end Dispatch;

   ---------------------
   -- Dispatch_Batch --
   ---------------------

   procedure Dispatch_Batch
     (Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Room : T.Real_Array_Access := null;
   begin
      Status := E.Success;

      if Vectors = null or else Target = null or else Count = 0 then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      T.Allocate (Weight.Rows, Room);
      if Room = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      for Which in 0 .. Count - 1 loop
         declare
            From : constant Model_Runner.Numerics.Element_Count :=
              Which * Weight.Columns;
            Into : constant Model_Runner.Numerics.Element_Count :=
              Which * Weight.Rows;

            Line : T.Real_Array_Access := null;
         begin
            if Vectors.all'Length < From + Weight.Columns
              or else Target.all'Length < Into + Weight.Rows
            then
               T.Free (Room);
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            --  One vector of the batch, as its own run of values, because
            --  the device is handed a vector rather than a slice of one.
            T.Allocate (Weight.Columns, Line);
            if Line = null then
               T.Free (Room);
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;

            Line.all :=
              Vectors.all (Vectors.all'First + From
                           .. Vectors.all'First + From + Weight.Columns - 1);

            Dispatch (Weight, Line, Room, Status);
            T.Free (Line);

            if E.Is_Error (Status) then
               T.Free (Room);
               return;
            end if;

            Target.all (Target.all'First + Into
                        .. Target.all'First + Into + Weight.Rows - 1) :=
              Room.all;
         end;
      end loop;

      T.Free (Room);
   end Dispatch_Batch;

end Model_Runner.Backend.Device;
