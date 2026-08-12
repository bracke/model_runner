with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

with Model_Runner.Shaders;

--  Products on a device, through the same interface the parent opened it
--  with.
--
--  A weight handed over once stays. What that costs is a table of what is
--  held, keyed by where the matrix lives in the model's own storage; what it
--  buys is that the second product with the same matrix moves a vector
--  rather than a matrix, which on any real model is every product but the
--  first.
--
--  Handles here are addresses. The interface has two kinds -- ones that are
--  pointers and ones that are sixty-four bit numbers -- and on the machines
--  this program targets both are eight bytes, so one Ada type carries both.
--  A thirty-two bit host would need them told apart, and this does not
--  claim to run on one.
--
--  Every structure is declared with the fields the interface states, in
--  order. Where C would pad between a four-byte field and an eight-byte one
--  the Ada compiler pads the same way for a record with C convention, which
--  is what that convention is for.
package body Model_Runner.Platform.Device.Products is

   use type Interfaces.C.int;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type Model_Runner.Numerics.Element_Count;

   package C renames Interfaces.C;

   subtype Address is System.Address;

   Null_Handle : constant Address := System.Null_Address;

   --  What the interface calls the structures this passes.
   Structure_Submit            : constant := 4;
   Structure_Memory_Allocate   : constant := 5;
   Structure_Fence_Create      : constant := 8;
   Structure_Buffer_Create     : constant := 12;
   Structure_Shader_Create     : constant := 16;
   Structure_Stage_Create      : constant := 18;
   Structure_Compute_Pipeline  : constant := 29;
   Structure_Pipeline_Layout   : constant := 30;
   Structure_Set_Layout        : constant := 32;
   Structure_Descriptor_Pool   : constant := 33;
   Structure_Descriptor_Set    : constant := 34;
   Structure_Write_Descriptor  : constant := 35;
   Structure_Command_Pool      : constant := 39;
   Structure_Command_Buffer    : constant := 40;
   Structure_Command_Begin     : constant := 42;

   Usage_Storage_Buffer : constant := 16#20#;
   Sharing_Exclusive    : constant := 0;
   Descriptor_Storage   : constant := 7;
   Stage_Compute        : constant := 16#20#;
   Bind_Point_Compute   : constant := 1;
   Level_Primary        : constant := 0;
   Use_Once             : constant := 1;

   --  How many invocations one group has, which the shader states as well.
   --  The two have to agree: the dispatch below asks for one group per this
   --  many rows.
   Group_Size : constant := 64;

   ---------------------------------------------------------------------------
   --  Structures
   ---------------------------------------------------------------------------

   type Buffer_Create_Info is record
      Kind         : C.unsigned := Structure_Buffer_Create;
      Next         : Address := Null_Handle;
      Flags        : C.unsigned := 0;
      Size         : Interfaces.Unsigned_64 := 0;
      Usage        : C.unsigned := Usage_Storage_Buffer;
      Sharing      : C.unsigned := Sharing_Exclusive;
      Family_Count : C.unsigned := 0;
      Families     : Address := Null_Handle;
   end record
     with Convention => C;

   type Memory_Requirements is record
      Size      : Interfaces.Unsigned_64 := 0;
      Alignment : Interfaces.Unsigned_64 := 0;
      Kinds     : C.unsigned := 0;
   end record
     with Convention => C;

   type Memory_Allocate_Info is record
      Kind  : C.unsigned := Structure_Memory_Allocate;
      Next  : Address := Null_Handle;
      Size  : Interfaces.Unsigned_64 := 0;
      Which : C.unsigned := 0;
   end record
     with Convention => C;

   type Set_Layout_Binding is record
      Binding  : C.unsigned := 0;
      Kind     : C.unsigned := Descriptor_Storage;
      Count    : C.unsigned := 1;
      Stages   : C.unsigned := Stage_Compute;
      Samplers : Address := Null_Handle;
   end record
     with Convention => C;

   type Binding_Array is array (1 .. 3) of Set_Layout_Binding;

   type Set_Layout_Create_Info is record
      Kind     : C.unsigned := Structure_Set_Layout;
      Next     : Address := Null_Handle;
      Flags    : C.unsigned := 0;
      Count    : C.unsigned := 3;
      Bindings : Address := Null_Handle;
   end record
     with Convention => C;

   type Pool_Size is record
      Kind  : C.unsigned := Descriptor_Storage;
      Count : C.unsigned := 3;
   end record
     with Convention => C;

   type Descriptor_Pool_Info is record
      Kind       : C.unsigned := Structure_Descriptor_Pool;
      Next       : Address := Null_Handle;
      Flags      : C.unsigned := 0;
      Max_Sets   : C.unsigned := 1;
      Size_Count : C.unsigned := 1;
      Sizes      : Address := Null_Handle;
   end record
     with Convention => C;

   type Descriptor_Set_Info is record
      Kind    : C.unsigned := Structure_Descriptor_Set;
      Next    : Address := Null_Handle;
      Pool    : Address := Null_Handle;
      Count   : C.unsigned := 1;
      Layouts : Address := Null_Handle;
   end record
     with Convention => C;

   type Buffer_Info is record
      Buffer : Address := Null_Handle;
      Offset : Interfaces.Unsigned_64 := 0;
      Extent : Interfaces.Unsigned_64 := 0;
   end record
     with Convention => C;

   type Buffer_Info_Array is array (1 .. 3) of aliased Buffer_Info;

   type Write_Descriptor is record
      Kind        : C.unsigned := Structure_Write_Descriptor;
      Next        : Address := Null_Handle;
      Target      : Address := Null_Handle;
      Binding     : C.unsigned := 0;
      First       : C.unsigned := 0;
      Count       : C.unsigned := 1;
      Descriptor  : C.unsigned := Descriptor_Storage;
      Images      : Address := Null_Handle;
      Buffers     : Address := Null_Handle;
      Texels      : Address := Null_Handle;
   end record
     with Convention => C;

   type Write_Array is array (1 .. 3) of aliased Write_Descriptor;

   type Push_Range is record
      Stages : C.unsigned := Stage_Compute;
      Offset : C.unsigned := 0;
      Size   : C.unsigned := 8;
   end record
     with Convention => C;

   type Pipeline_Layout_Info is record
      Kind        : C.unsigned := Structure_Pipeline_Layout;
      Next        : Address := Null_Handle;
      Flags       : C.unsigned := 0;
      Set_Count   : C.unsigned := 1;
      Sets        : Address := Null_Handle;
      Push_Count  : C.unsigned := 1;
      Pushes      : Address := Null_Handle;
   end record
     with Convention => C;

   type Shader_Create_Info is record
      Kind  : C.unsigned := Structure_Shader_Create;
      Next  : Address := Null_Handle;
      Flags : C.unsigned := 0;
      Size  : Interfaces.C.size_t := 0;
      Code  : Address := Null_Handle;
   end record
     with Convention => C;

   type Stage_Create_Info is record
      Kind          : C.unsigned := Structure_Stage_Create;
      Next          : Address := Null_Handle;
      Flags         : C.unsigned := 0;
      Stage         : C.unsigned := Stage_Compute;
      Module        : Address := Null_Handle;
      Name          : C.Strings.chars_ptr := C.Strings.Null_Ptr;
      Specialized   : Address := Null_Handle;
   end record
     with Convention => C;

   type Compute_Pipeline_Info is record
      Kind     : C.unsigned := Structure_Compute_Pipeline;
      Next     : Address := Null_Handle;
      Flags    : C.unsigned := 0;
      Stage    : Stage_Create_Info;
      Layout   : Address := Null_Handle;
      Base     : Address := Null_Handle;
      Base_Num : C.int := 0;
   end record
     with Convention => C;

   type Command_Pool_Info is record
      Kind   : C.unsigned := Structure_Command_Pool;
      Next   : Address := Null_Handle;
      Flags  : C.unsigned := 2;   --  reset a buffer without resetting a pool
      Family : C.unsigned := 0;
   end record
     with Convention => C;

   type Command_Buffer_Info is record
      Kind  : C.unsigned := Structure_Command_Buffer;
      Next  : Address := Null_Handle;
      Pool  : Address := Null_Handle;
      Level : C.unsigned := Level_Primary;
      Count : C.unsigned := 1;
   end record
     with Convention => C;

   type Command_Begin_Info is record
      Kind        : C.unsigned := Structure_Command_Begin;
      Next        : Address := Null_Handle;
      Flags       : C.unsigned := Use_Once;
      Inheritance : Address := Null_Handle;
   end record
     with Convention => C;

   type Submit_Info is record
      Kind         : C.unsigned := Structure_Submit;
      Next         : Address := Null_Handle;
      Wait_Count   : C.unsigned := 0;
      Waits        : Address := Null_Handle;
      Wait_Stages  : Address := Null_Handle;
      Buffer_Count : C.unsigned := 1;
      Buffers      : Address := Null_Handle;
      Signal_Count : C.unsigned := 0;
      Signals      : Address := Null_Handle;
   end record
     with Convention => C;

   type Fence_Create_Info is record
      Kind  : C.unsigned := Structure_Fence_Create;
      Next  : Address := Null_Handle;
      Flags : C.unsigned := 0;
   end record
     with Convention => C;

   --  What the shader is told about the shape, in the order it declares.
   type Shape_Constants is record
      Rows    : C.unsigned := 0;
      Columns : C.unsigned := 0;
   end record
     with Convention => C;

   ---------------------------------------------------------------------------
   --  Entry points
   ---------------------------------------------------------------------------

   type Create_Call is access
     function (Device : Address; Info : Address; Allocator : Address;
               Result : access Address) return C.int
     with Convention => C;

   type Destroy_Call is access
     procedure (Device : Address; Item : Address; Allocator : Address)
     with Convention => C;

   type Requirements_Call is access
     procedure (Device : Address; Buffer : Address; Result : Address)
     with Convention => C;

   type Bind_Call is access
     function (Device : Address; Buffer : Address; Memory : Address;
               Offset : Interfaces.Unsigned_64) return C.int
     with Convention => C;

   type Map_Call is access
     function (Device : Address; Memory : Address;
               Offset : Interfaces.Unsigned_64;
               Size   : Interfaces.Unsigned_64;
               Flags  : C.unsigned;
               Data   : access Address) return C.int
     with Convention => C;

   type Unmap_Call is access
     procedure (Device : Address; Memory : Address)
     with Convention => C;

   type Allocate_Sets_Call is access
     function (Device : Address; Info : Address;
               Sets : access Address) return C.int
     with Convention => C;

   type Update_Sets_Call is access
     procedure (Device : Address; Write_Count : C.unsigned; Writes : Address;
                Copy_Count : C.unsigned; Copies : Address)
     with Convention => C;

   type Create_Pipelines_Call is access
     function (Device : Address; Cache : Address; Count : C.unsigned;
               Info : Address; Allocator : Address;
               Result : access Address) return C.int
     with Convention => C;

   type Allocate_Buffers_Call is access
     function (Device : Address; Info : Address;
               Buffers : access Address) return C.int
     with Convention => C;

   type Begin_Call is access
     function (Buffer : Address; Info : Address) return C.int
     with Convention => C;

   type End_Call is access
     function (Buffer : Address) return C.int
     with Convention => C;

   type Reset_Buffer_Call is access
     function (Buffer : Address; Flags : C.unsigned) return C.int
     with Convention => C;

   type Bind_Pipeline_Call is access
     procedure (Buffer : Address; Point : C.unsigned; Pipeline : Address)
     with Convention => C;

   type Bind_Sets_Call is access
     procedure (Buffer : Address; Point : C.unsigned; Layout : Address;
                First : C.unsigned; Count : C.unsigned; Sets : Address;
                Dynamic_Count : C.unsigned; Dynamic : Address)
     with Convention => C;

   type Push_Call is access
     procedure (Buffer : Address; Layout : Address; Stages : C.unsigned;
                Offset : C.unsigned; Size : C.unsigned; Values : Address)
     with Convention => C;

   type Dispatch_Call is access
     procedure (Buffer : Address; X, Y, Z : C.unsigned)
     with Convention => C;

   type Submit_Call is access
     function (Queue : Address; Count : C.unsigned; Info : Address;
               Fence : Address) return C.int
     with Convention => C;

   type Wait_Call is access
     function (Device : Address; Count : C.unsigned; Fences : Address;
               All_Of : C.unsigned;
               Timeout : Interfaces.Unsigned_64) return C.int
     with Convention => C;

   type Reset_Fences_Call is access
     function (Device : Address; Count : C.unsigned;
               Fences : Address) return C.int
     with Convention => C;

   function To_Create is
     new Ada.Unchecked_Conversion (Address, Create_Call);
   function To_Destroy is
     new Ada.Unchecked_Conversion (Address, Destroy_Call);
   function To_Requirements is
     new Ada.Unchecked_Conversion (Address, Requirements_Call);
   function To_Bind is new Ada.Unchecked_Conversion (Address, Bind_Call);
   function To_Map is new Ada.Unchecked_Conversion (Address, Map_Call);
   function To_Unmap is new Ada.Unchecked_Conversion (Address, Unmap_Call);
   function To_Allocate_Sets is
     new Ada.Unchecked_Conversion (Address, Allocate_Sets_Call);
   function To_Update_Sets is
     new Ada.Unchecked_Conversion (Address, Update_Sets_Call);
   function To_Create_Pipelines is
     new Ada.Unchecked_Conversion (Address, Create_Pipelines_Call);
   function To_Allocate_Buffers is
     new Ada.Unchecked_Conversion (Address, Allocate_Buffers_Call);
   function To_Begin is new Ada.Unchecked_Conversion (Address, Begin_Call);
   function To_End is new Ada.Unchecked_Conversion (Address, End_Call);
   function To_Reset_Buffer is
     new Ada.Unchecked_Conversion (Address, Reset_Buffer_Call);
   function To_Bind_Pipeline is
     new Ada.Unchecked_Conversion (Address, Bind_Pipeline_Call);
   function To_Bind_Sets is
     new Ada.Unchecked_Conversion (Address, Bind_Sets_Call);
   function To_Push is new Ada.Unchecked_Conversion (Address, Push_Call);
   function To_Dispatch is
     new Ada.Unchecked_Conversion (Address, Dispatch_Call);
   function To_Submit is new Ada.Unchecked_Conversion (Address, Submit_Call);
   function To_Wait is new Ada.Unchecked_Conversion (Address, Wait_Call);
   function To_Reset_Fences is
     new Ada.Unchecked_Conversion (Address, Reset_Fences_Call);

   --  The instance every entry point below is found through. Set from the
   --  engine whose operation is running, because an entry point belongs to
   --  the instance it was found through and outlives none of them.
   --
   --  It used to be set once, when an engine was opened, and left. Closing
   --  an engine and then the device under it left this naming an instance
   --  that no longer existed, and the next engine's Open -- which releases
   --  before it makes -- asked that dead instance for vkDestroyBuffer. The
   --  loader does not return null for an invalid instance; it aborts the
   --  process, which is what it did.
   Instance_Of : Address := Null_Handle;

   --  Null when there is no instance to ask, so that a caller releasing an
   --  engine that was never made asks nobody rather than asking a handle
   --  that is not one.
   function Point (Name : String) return Address
   is (if Instance_Of = Null_Handle
       then Null_Handle
       else Entry_Point (Instance_Of, Name));

   --  Point this engine's instance at the loader before anything is asked of
   --  it. A function so that it can be a declaration in the operations that
   --  need it, which is how it comes before their first entry point.
   function Set_Asking (Item : Engine) return Boolean is
   begin
      Instance_Of := Item.Instance;
      return True;
   end Set_Asking;

   --  Make a buffer and the memory behind it, both released by the caller.
   procedure Take
     (Item   : in out Engine;
      Bytes  : Interfaces.Unsigned_64;
      Buffer : out Address;
      Memory : out Address;
      Ok     : out Boolean)
   is
      Create : constant Create_Call := To_Create (Point ("vkCreateBuffer"));
      Wants  : constant Requirements_Call :=
        To_Requirements (Point ("vkGetBufferMemoryRequirements"));
      Allocate : constant Create_Call :=
        To_Create (Point ("vkAllocateMemory"));
      Bind : constant Bind_Call := To_Bind (Point ("vkBindBufferMemory"));

      Made : aliased Address := Null_Handle;
   begin
      Buffer := Null_Handle;
      Memory := Null_Handle;
      Ok := False;

      if Create = null or else Wants = null or else Allocate = null
        or else Bind = null or else Bytes = 0
      then
         return;
      end if;

      declare
         Request : aliased Buffer_Create_Info;
      begin
         Request.Size := Bytes;
         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            return;
         end if;
         Buffer := Made;
      end;

      declare
         Needed  : aliased Memory_Requirements;
         Request : aliased Memory_Allocate_Info;
      begin
         Wants (Item.Logical, Buffer, Needed'Address);
         Request.Size := Needed.Size;
         Request.Which := C.unsigned (Item.Upload);

         if Allocate (Item.Logical, Request'Address, Null_Handle,
                      Made'Access) /= 0
         then
            return;
         end if;
         Memory := Made;
      end;

      Ok := Bind (Item.Logical, Buffer, Memory, 0) = 0;
   end Take;

   procedure Give_Back_Buffer
     (Item : in out Engine; Buffer : in out Address; Memory : in out Address)
   is
      Destroy : constant Destroy_Call :=
        To_Destroy (Point ("vkDestroyBuffer"));
      Free : constant Destroy_Call := To_Destroy (Point ("vkFreeMemory"));
   begin
      if Buffer /= Null_Handle and then Destroy /= null
        and then Item.Logical /= Null_Handle
      then
         Destroy (Item.Logical, Buffer, Null_Handle);
      end if;
      Buffer := Null_Handle;

      if Memory /= Null_Handle and then Free /= null
        and then Item.Logical /= Null_Handle
      then
         Free (Item.Logical, Memory, Null_Handle);
      end if;
      Memory := Null_Handle;
   end Give_Back_Buffer;

   --  Copy values into a buffer's memory.
   procedure Write_Into
     (Item   : in out Engine;
      Memory : Address;
      Bytes  : Interfaces.Unsigned_64;
      Values : Model_Runner.Numerics.Real_Array;
      Ok     : out Boolean)
   is
      Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
      Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

      Where : aliased Address := Null_Handle;
   begin
      Ok := False;

      if Map = null or else Unmap = null then
         return;
      end if;

      if Map (Item.Logical, Memory, 0, Bytes, 0, Where'Access) /= 0 then
         return;
      end if;

      declare
         Room : Model_Runner.Numerics.Real_Array (Values'Range)
           with Import, Address => Where;
      begin
         Room := Values;
      end;

      Unmap (Item.Logical, Memory);
      Ok := True;
   end Write_Into;

   ---------------------------------------------------------------------------
   --  Making and releasing
   ---------------------------------------------------------------------------

   procedure Open
     (Item  : in out Engine;
      On    : Context;
      Ready : out Boolean)
   is
      Made : aliased Address := Null_Handle;
   begin
      Close (Item);
      Ready := False;

      if not Is_Open (On) then
         return;
      end if;

      Item.Instance := On.Instance;
      Instance_Of := Item.Instance;

      Item.Logical := On.Logical;
      Item.Queue := On.Queue;
      Item.Family := On.Family;
      Item.Upload := On.Upload;

      --  The shader.
      declare
         Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Row_Product;
         Request : aliased Shader_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Size := Interfaces.C.size_t (Words'Length * 4);
         Request.Code := Words'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Shader := Made;
      end;

      --  Three storage buffers, and what a set of them looks like.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateDescriptorSetLayout"));

         Bindings : aliased Binding_Array;
         Request  : aliased Set_Layout_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         for Index in Bindings'Range loop
            Bindings (Index).Binding := C.unsigned (Index - 1);
         end loop;

         Request.Bindings := Bindings'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Set_Layout := Made;
      end;

      --  The layout of the pipeline: that set, and the two numbers the
      --  shader is told about the shape.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreatePipelineLayout"));

         Sets    : aliased Address := Item.Set_Layout;
         Pushes  : aliased Push_Range;
         Request : aliased Pipeline_Layout_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Sets := Sets'Address;
         Request.Pushes := Pushes'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Layout := Made;
      end;

      --  And the pipeline.
      declare
         Create : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));

         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;
      begin
         if Create = null then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Request.Stage.Module := Item.Shader;
         Request.Stage.Name := Name;
         Request.Layout := Item.Layout;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) /= 0
         then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         C.Strings.Free (Name);
         Item.Pipeline := Made;
      end;

      --  Somewhere to keep one set of descriptors, and the set itself.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateDescriptorPool"));

         Sizes   : aliased Pool_Size;
         Request : aliased Descriptor_Pool_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Sizes := Sizes'Address;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Pool := Made;
      end;

      declare
         Allocate : constant Allocate_Sets_Call :=
           To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

         Layouts : aliased Address := Item.Set_Layout;
         Request : aliased Descriptor_Set_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Pool;
         Request.Layouts := Layouts'Address;

         if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Descriptor := Made;
      end;

      --  A pool of commands and one buffer to record into.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateCommandPool"));

         Request : aliased Command_Pool_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Family := C.unsigned (Item.Family);

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Commands := Made;
      end;

      declare
         Allocate : constant Allocate_Buffers_Call :=
           To_Allocate_Buffers (Point ("vkAllocateCommandBuffers"));

         Request : aliased Command_Buffer_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Commands;

         if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Buffer := Made;
      end;

      --  And something to wait on.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateFence"));

         Request : aliased Fence_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
            /= 0
         then
            Close (Item);
            return;
         end if;

         Item.Fence := Made;
      end;

      Ready := True;
   end Open;

   procedure Close (Item : in out Engine) is
      --  Whatever this engine was opened on, which is nothing at all for an
      --  engine that never was.
      Restore : constant Address := Instance_Of;

      procedure Give_Back (Handle : in out Address; Name : String) is
         Destroy : constant Destroy_Call := To_Destroy (Point (Name));
      begin
         if Handle /= Null_Handle
           and then Item.Logical /= Null_Handle
           and then Destroy /= null
         then
            Destroy (Item.Logical, Handle, Null_Handle);
         end if;
         Handle := Null_Handle;
      end Give_Back;
   begin
      Instance_Of := Item.Instance;

      --  Everything the device was holding for a model, then the two that
      --  change every call.
      for Index in 1 .. Item.Used loop
         Give_Back_Buffer
           (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory);
         Item.Kept (Index).Key := Null_Handle;
         Item.Kept (Index).Bytes := 0;
      end loop;
      Item.Used := 0;

      Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
      Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
      Item.Vector_Bytes := 0;
      Item.Result_Bytes := 0;

      --  In the reverse of the order they were made, and each only if it
      --  was. The command buffer goes with its pool and the descriptor set
      --  with its own, so neither is given back on its own.
      Give_Back (Item.Fence, "vkDestroyFence");
      Item.Buffer := Null_Handle;
      Give_Back (Item.Commands, "vkDestroyCommandPool");
      Item.Descriptor := Null_Handle;
      Give_Back (Item.Pool, "vkDestroyDescriptorPool");
      Give_Back (Item.Pipeline, "vkDestroyPipeline");
      Give_Back (Item.Layout, "vkDestroyPipelineLayout");
      Give_Back (Item.Set_Layout, "vkDestroyDescriptorSetLayout");
      Give_Back (Item.Shader, "vkDestroyShaderModule");

      Item.Logical := Null_Handle;
      Item.Queue := Null_Handle;
      Item.Family := 0;
      Item.Upload := 0;
      Item.Instance := Null_Handle;

      --  Whoever was asking before this, if anyone was. Close is called from
      --  Open, and Open has an instance of its own to go back to.
      Instance_Of := Restore;
   end Close;

   function Is_Ready (Item : Engine) return Boolean
   is (Item.Pipeline /= Null_Handle and then Item.Fence /= Null_Handle);

   ---------------------------------------------------------------------------
   --  One product
   ---------------------------------------------------------------------------

   --------------
   -- Resident --
   --------------

   function Resident (Item : Engine) return Natural is (Item.Used);

   --------------
   -- Multiply --
   --------------

   procedure Multiply
     (Item    : in out Engine;
      Weights : Model_Runner.Numerics.Real_Array;
      Vector  : Model_Runner.Numerics.Real_Array;
      Rows    : Natural;
      Columns : Natural;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Key     : System.Address := System.Null_Address)
   is
      Elements : constant Natural := Rows * Columns;

      --  Whichever engine is being asked, because an entry point belongs to
      --  the instance behind it.
      Ignored : constant Boolean := Set_Asking (Item);

      Weight_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Elements) * 4;
      Vector_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns) * 4;
      Result_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * 4;

      --  The matrix, kept when it has a key and made afresh when it has not.
      Weight_Buffer : Address := Null_Handle;
      Weight_Memory : Address := Null_Handle;
      Borrowed      : Boolean := False;

      procedure Release_Borrowed is
      begin
         if Borrowed then
            Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
            Borrowed := False;
         end if;
      end Release_Borrowed;

      Good : Boolean;
   begin
      Target := [others => 0.0];
      Ok := False;

      if not Is_Ready (Item)
        or else Rows = 0
        or else Columns = 0
        or else Elements > Max_Elements
        or else Weights'Length < Elements
        or else Vector'Length < Columns
        or else Target'Length < Rows
      then
         return;
      end if;

      --  Is it already there? A matrix is what it is and where it is: the
      --  same address with a different length is a different matrix, and
      --  the length is checked so that a caller reusing storage cannot be
      --  handed somebody else's weights.
      if Key /= System.Null_Address then
         for Index in 1 .. Item.Used loop
            if Item.Kept (Index).Key = Key
              and then Item.Kept (Index).Bytes = Weight_Bytes
            then
               Weight_Buffer := Item.Kept (Index).Buffer;
               Weight_Memory := Item.Kept (Index).Memory;
               exit;
            end if;
         end loop;
      end if;

      if Weight_Buffer = Null_Handle then
         Take (Item, Weight_Bytes, Weight_Buffer, Weight_Memory, Good);
         if not Good then
            Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
            return;
         end if;

         Write_Into
           (Item, Weight_Memory, Weight_Bytes,
            Weights (Weights'First
                     .. Weights'First
                        + Model_Runner.Numerics.Element_Count (Elements) - 1),
            Good);
         if not Good then
            Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
            return;
         end if;

         --  Kept if it was named and there is room; otherwise it belongs to
         --  this call and goes back at the end of it.
         if Key /= System.Null_Address and then Item.Used < Max_Resident then
            Item.Used := Item.Used + 1;
            Item.Kept (Item.Used) :=
              (Key => Key, Buffer => Weight_Buffer, Memory => Weight_Memory,
               Bytes => Weight_Bytes);
         else
            Borrowed := True;
         end if;
      end if;

      --  The two that change every call, grown when they have to.
      if Item.Vector_Bytes < Vector_Bytes then
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Take (Item, Vector_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            Release_Borrowed;
            return;
         end if;
         Item.Vector_Bytes := Vector_Bytes;
      end if;

      if Item.Result_Bytes < Result_Bytes then
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good);
         if not Good then
            Release_Borrowed;
            return;
         end if;
         Item.Result_Bytes := Result_Bytes;
      end if;

      Write_Into
        (Item, Item.Vector_Memory, Vector_Bytes,
         Vector (Vector'First
                 .. Vector'First
                    + Model_Runner.Numerics.Element_Count (Columns) - 1),
         Good);
      if not Good then
         Release_Borrowed;
         return;
      end if;

      --  What the shader is pointed at.
      declare
         Update : constant Update_Sets_Call :=
           To_Update_Sets (Point ("vkUpdateDescriptorSets"));

         Buffers : constant array (1 .. 3) of Address :=
           [Weight_Buffer, Item.Vector_Buffer, Item.Result_Buffer];
         Extent : constant array (1 .. 3) of Interfaces.Unsigned_64 :=
           [Weight_Bytes, Vector_Bytes, Result_Bytes];

         Told  : aliased Buffer_Info_Array;
         Notes : aliased Write_Array;
      begin
         if Update = null then
            Release_Borrowed;
            return;
         end if;

         for Index in Told'Range loop
            Told (Index).Buffer := Buffers (Index);
            Told (Index).Extent := Extent (Index);

            Notes (Index).Target := Item.Descriptor;
            Notes (Index).Binding := C.unsigned (Index - 1);
            Notes (Index).Buffers := Told (Index)'Address;
         end loop;

         Update (Item.Logical, 3, Notes'Address, 0, Null_Handle);
      end;

      --  The work: one group per sixty-four rows, which is what the shader
      --  declares a group to be.
      declare
         Reset_Buffer : constant Reset_Buffer_Call :=
           To_Reset_Buffer (Point ("vkResetCommandBuffer"));
         Start : constant Begin_Call :=
           To_Begin (Point ("vkBeginCommandBuffer"));
         Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
         Bind_Pipeline : constant Bind_Pipeline_Call :=
           To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
         Bind_Sets : constant Bind_Sets_Call :=
           To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
         Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
         Dispatch : constant Dispatch_Call :=
           To_Dispatch (Point ("vkCmdDispatch"));

         Shape : aliased Shape_Constants :=
           (Rows => C.unsigned (Rows), Columns => C.unsigned (Columns));

         Sets  : aliased Address := Item.Descriptor;
         Began : aliased Command_Begin_Info;
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            Release_Borrowed;
            return;
         end if;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            Release_Borrowed;
            return;
         end if;

         Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Pipeline);
         Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                    Sets'Address, 0, Null_Handle);
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0, 8, Shape'Address);
         Dispatch
           (Item.Buffer,
            C.unsigned ((Rows + Group_Size - 1) / Group_Size), 1, 1);

         if Stop (Item.Buffer) /= 0 then
            Release_Borrowed;
            return;
         end if;
      end;

      --  Hand it over and wait.
      declare
         Submit : constant Submit_Call := To_Submit (Point ("vkQueueSubmit"));
         Wait   : constant Wait_Call := To_Wait (Point ("vkWaitForFences"));
         Reset  : constant Reset_Fences_Call :=
           To_Reset_Fences (Point ("vkResetFences"));

         Buffer_Handle : aliased Address := Item.Buffer;
         Fence_Handle  : aliased Address := Item.Fence;
         Request       : aliased Submit_Info;
      begin
         if Submit = null or else Wait = null or else Reset = null then
            Release_Borrowed;
            return;
         end if;

         Request.Buffers := Buffer_Handle'Address;

         if Reset (Item.Logical, 1, Fence_Handle'Address) /= 0
           or else Submit (Item.Queue, 1, Request'Address, Item.Fence) /= 0
         then
            Release_Borrowed;
            return;
         end if;

         --  A second is far longer than any product here takes, and it is a
         --  bound rather than a wait: a device that has stopped answering
         --  should give the caller back its thread.
         if Wait (Item.Logical, 1, Fence_Handle'Address, 1,
                  1_000_000_000) /= 0
         then
            Release_Borrowed;
            return;
         end if;
      end;

      --  And what came out.
      declare
         Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

         Where : aliased Address := Null_Handle;
      begin
         if Map (Item.Logical, Item.Result_Memory, 0, Result_Bytes, 0,
                 Where'Access) /= 0
         then
            Release_Borrowed;
            return;
         end if;

         declare
            Slice : Model_Runner.Numerics.Real_Array
              (Target'First
               .. Target'First
                  + Model_Runner.Numerics.Element_Count (Rows) - 1)
              with Import, Address => Where;
         begin
            Target (Slice'Range) := Slice;
         end;

         Unmap (Item.Logical, Item.Result_Memory);
      end;

      Release_Borrowed;
      Ok := True;
   end Multiply;

end Model_Runner.Platform.Device.Products;
