with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

with System.Storage_Elements;

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
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type Model_Runner.Numerics.Element_Count;

   package C renames Interfaces.C;

   use type Model_Runner.Bytes.Byte_Count;

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

   --  A barrier between one dispatch and the next, for the case where the
   --  second reads what the first wrote. Products of the same activation
   --  need none of this -- they touch nothing in common -- but a chained one
   --  does, and without it a device is free to start the reader before the
   --  writer has finished.
   Structure_Memory_Barrier : constant := 46;
   Pipeline_Stage_Compute   : constant := 16#800#;
   Access_Shader_Read       : constant := 16#20#;
   Access_Shader_Write      : constant := 16#40#;
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

   --  Handing the device the host's own memory rather than a copy of what
   --  is in it. Three structures and one entry point:
   --
   --  the buffer is told its memory will come from outside the interface,
   --  the allocation is told which host pointer it is, and the interface is
   --  asked which memory kinds that pointer can be taken as -- because a
   --  pointer the device cannot address is a pointer it will not take, and
   --  the answer is a mask rather than a yes.
   Structure_External_Buffer : constant := 1_000_158_000 + 13;
   Structure_Import_Host     : constant := 1_000_178_000;
   Structure_Host_Properties : constant := 1_000_178_000 + 1;

   Handle_Host_Allocation : constant := 16#80#;

   type External_Buffer_Info is record
      Kind    : C.unsigned := Structure_External_Buffer;
      Next    : Address := Null_Handle;
      Handles : C.unsigned := Handle_Host_Allocation;
   end record
     with Convention => C;

   type Import_Host_Info is record
      Kind    : C.unsigned := Structure_Import_Host;
      Next    : Address := Null_Handle;
      Handle  : C.unsigned := Handle_Host_Allocation;
      Pointer : Address := Null_Handle;
   end record
     with Convention => C;

   type Host_Pointer_Properties is record
      Kind  : C.unsigned := Structure_Host_Properties;
      Next  : Address := Null_Handle;
      Kinds : C.unsigned := 0;
   end record
     with Convention => C;

   type Host_Properties_Call is access
     function (Device  : Address;
               Handle  : C.unsigned;
               Pointer : Address;
               Result  : Address) return C.int
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

   --  Bytes of push constants, which the layout declares and every dispatch
   --  writes. One number in two places is one number that can differ, so it
   --  is this one.
   Shape_Bytes : constant := 24;

   type Push_Range is record
      Stages : C.unsigned := Stage_Compute;
      Offset : C.unsigned := 0;
      Size   : C.unsigned := Shape_Bytes;
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
      Count   : C.unsigned := 1;
      First   : C.unsigned := 0;
      Packing : C.unsigned := 0;
      Base    : C.unsigned := 0;
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

   type Memory_Barrier is record
      Kind   : C.unsigned := Structure_Memory_Barrier;
      Next   : Address := Null_Handle;
      Wrote  : C.unsigned := Access_Shader_Write;
      Reads  : C.unsigned := Access_Shader_Read;
   end record
     with Convention => C;

   type Barrier_Call is access
     procedure (Buffer : Address;
                From, Into : C.unsigned;
                Flags : C.unsigned;
                Memory_Count : C.unsigned; Memories : Address;
                Buffer_Count : C.unsigned; Buffers : Address;
                Image_Count : C.unsigned; Images : Address)
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
   function To_Host_Properties is
     new Ada.Unchecked_Conversion (Address, Host_Properties_Call);
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
   function To_Barrier is
     new Ada.Unchecked_Conversion (Address, Barrier_Call);
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

   --  Take the host's own memory as a buffer, rather than a copy of it.
   --
   --  What the device is given is a page-aligned address at or before the
   --  weights and a length that covers them, so the matrix begins some way
   --  into the buffer: that distance comes back as Base and goes to the
   --  shader, which adds it to every offset it reads.
   --
   --  Every way this can fail is a False and a caller that copies instead:
   --  a device without the extensions, a pointer the device cannot address,
   --  an allocation refused. None of them is an error -- they are the same
   --  answer arrived at one call later.
   --
   --  @param Item Engine holding the device.
   --  @param Whole Where the storage the weights live in begins, and how far
   --    it runs. The device is given a page-aligned range and pages are
   --    larger than tensors, so what it is handed reaches before the matrix
   --    and past it; both ends have to stay inside memory this process
   --    owns, and this is what says where that is. A range that would leave
   --    it is copied instead.
   --  @param Span How long that storage is.
   --  @param From Where the weights are, in this process.
   --  @param Bytes How many of them.
   --  @param Buffer Receives the buffer.
   --  @param Memory Receives the memory behind it.
   --  @param Base Receives the distance from the buffer to the weights.
   --  @param Ok True when the device took the pointer.
   procedure Take_Host_Memory
     (Item   : in out Engine;
      Whole  : Address;
      Span   : Interfaces.Unsigned_64;
      From   : Address;
      Bytes  : Interfaces.Unsigned_64;
      Buffer : out Address;
      Memory : out Address;
      Base   : out Interfaces.Unsigned_64;
      Ok     : out Boolean)
   is
      use type System.Storage_Elements.Integer_Address;

      Create : constant Create_Call := To_Create (Point ("vkCreateBuffer"));
      Allocate : constant Create_Call :=
        To_Create (Point ("vkAllocateMemory"));
      Bind : constant Bind_Call := To_Bind (Point ("vkBindBufferMemory"));
      Asked : constant Host_Properties_Call :=
        To_Host_Properties (Point ("vkGetMemoryHostPointerPropertiesEXT"));

      Made : aliased Address := Null_Handle;

      Where : constant System.Storage_Elements.Integer_Address :=
        System.Storage_Elements.To_Integer (From);
   begin
      Buffer := Null_Handle;
      Memory := Null_Handle;
      Base := 0;
      Ok := False;

      if not Item.Imports or else Item.Import_To = 0
        or else Create = null or else Allocate = null or else Bind = null
        or else Asked = null or else Bytes = 0
      then
         return;
      end if;

      declare
         Align : constant System.Storage_Elements.Integer_Address :=
           System.Storage_Elements.Integer_Address (Item.Import_To);

         Start : constant System.Storage_Elements.Integer_Address :=
           Where - Where mod Align;

         Slack : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Where - Start);

         --  A whole number of whatever the device wanted, because that is
         --  what it will take: the pointer aligned and the length a
         --  multiple of the same.
         Length : constant Interfaces.Unsigned_64 :=
           ((Slack + Bytes + Item.Import_To - 1) / Item.Import_To)
           * Item.Import_To;

         Head : constant Address :=
           System.Storage_Elements.To_Address (Start);

         --  Both ends of what the device would be handed, against both
         --  ends of what this process owns. The rounding is what makes this
         --  necessary: a matrix at the end of a heap arena rounds up past
         --  the arena, and a device told to take memory nobody allocated is
         --  a fault this program would have asked for.
         Owned_First : constant System.Storage_Elements.Integer_Address :=
           System.Storage_Elements.To_Integer (Whole);
         Owned_Last  : constant System.Storage_Elements.Integer_Address :=
           Owned_First + System.Storage_Elements.Integer_Address (Span);

         Known : aliased Host_Pointer_Properties;
         Kinds : Interfaces.Unsigned_32;
         Which : Natural := 0;
      begin
         if Start < Owned_First
           or else Start + System.Storage_Elements.Integer_Address (Length)
                   > Owned_Last
         then
            return;
         end if;

         if Asked (Item.Logical, Handle_Host_Allocation, Head,
                   Known'Address) /= 0
         then
            return;
         end if;

         Kinds := Interfaces.Unsigned_32 (Known.Kinds);
         if Kinds = 0 then
            return;
         end if;

         --  A kind the pointer can be taken as and the processor writes
         --  and sees without being told to flush. Not the kind the uploads
         --  use: that one is chosen for being fast for the device to read,
         --  and a host pointer is rarely offered as it. On this machine the
         --  uploads use kind three and a host pointer is offered as kind
         --  five, which is why the first version of this imported nothing.
         Kinds := Kinds and Item.Plain;
         if Kinds = 0 then
            return;
         end if;

         while (Kinds and 1) = 0 loop
            Kinds := Interfaces.Shift_Right (Kinds, 1);
            Which := Which + 1;
         end loop;

         declare
            Outside : aliased External_Buffer_Info;
            Request : aliased Buffer_Create_Info;
         begin
            Request.Size := Length;
            Request.Next := Outside'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) /= 0
            then
               return;
            end if;
            Buffer := Made;
         end;

         declare
            Imported : aliased Import_Host_Info;
            Request  : aliased Memory_Allocate_Info;
         begin
            Imported.Pointer := Head;
            Request.Next := Imported'Address;
            Request.Size := Length;
            Request.Which := C.unsigned (Which);

            if Allocate (Item.Logical, Request'Address, Null_Handle,
                         Made'Access) /= 0
            then
               return;
            end if;
            Memory := Made;
         end;

         if Bind (Item.Logical, Buffer, Memory, 0) /= 0 then
            return;
         end if;

         Base := Slack;
         Ok := True;
      end;
   end Take_Host_Memory;

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

   --  The same for storage this does not interpret. A packed matrix is bytes
   --  until the shader reads it, and copying it as anything else would be
   --  claiming to know what it holds.
   procedure Write_Bytes
     (Item   : in out Engine;
      Memory : Address;
      Bytes  : Interfaces.Unsigned_64;
      Values : Model_Runner.Bytes.Byte_Array;
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
         Room : Model_Runner.Bytes.Byte_Array (Values'Range)
           with Import, Address => Where;
      begin
         Room := Values;
      end;

      Unmap (Item.Logical, Memory);
      Ok := True;
   end Write_Bytes;

   ---------------------------------------------------------------------------
   --  Making and releasing
   ---------------------------------------------------------------------------

   procedure Open
     (Item       : in out Engine;
      On         : Context;
      Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0)
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

      --  Through the accessor rather than the field. This package can see
      --  the private part, being a child, and reading it directly would make
      --  a public operation that answers exactly this question something
      --  nothing calls.
      Item.Heap := Memory_Bytes (On);
      Item.Imports := Takes_Host_Memory (On);
      Item.Import_To := Host_Alignment (On);
      Item.Plain := Plain_Memory_Kinds (On);
      Item.Share := Share_Host;
      Item.Budget :=
        (if Budget > 0 then Budget
         else Item.Heap / Budget_Whole * Budget_Share);

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

         --  Room for the single product's set and for one per step of the
         --  longest sequence, in one pool: three storage descriptors each.
         Sizes   : aliased Pool_Size :=
           (Kind  => Descriptor_Storage,
            Count => C.unsigned (3 * (1 + Sequence_Limit)));
         Request : aliased Descriptor_Pool_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Max_Sets := C.unsigned (1 + Sequence_Limit);
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

      --  And one set per product a sequence may hold, from the same pool
      --  and against the same layout. Allocated in one call: a pool hands
      --  out as many sets as it is asked for, and asking thirty-two times
      --  would be thirty-two round trips for the same thing.
      declare
         Allocate : constant Allocate_Sets_Call :=
           To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

         Layouts : aliased array (1 .. Sequence_Limit) of Address :=
           [others => Item.Set_Layout];
         Given   : Set_Array := [others => Null_Handle];
         First   : aliased Address := Null_Handle
           with Address => Given (Given'First)'Address;
         Request : aliased Descriptor_Set_Info;
      begin
         if Allocate = null then
            Close (Item);
            return;
         end if;

         Request.Pool := Item.Pool;
         Request.Count := C.unsigned (Sequence_Limit);
         Request.Layouts := Layouts (Layouts'First)'Address;

         if Allocate (Item.Logical, Request'Address, First'Access) /= 0 then
            Close (Item);
            return;
         end if;

         Item.Sets := Given;
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

      Item.Slice := Slice;
      Item.Patience := Patience;
      Ready := True;
   end Open;

   --------------------------
   -- Forget_Matrices --
   --------------------------

   procedure Forget_Matrices (Item : in out Engine) is
      --  Buffers belong to the instance that made them, so the entry points
      --  have to be the ones this engine was opened with.
      Ignored : constant Boolean := Set_Asking (Item);
   begin
      for Index in 1 .. Item.Used loop
         Give_Back_Buffer
           (Item, Item.Kept (Index).Buffer, Item.Kept (Index).Memory);
         Item.Kept (Index).Key := Null_Handle;
         Item.Kept (Index).Bytes := 0;
         Item.Kept (Index).Rows := 0;
         Item.Kept (Index).Columns := 0;
      end loop;

      Item.Used := 0;
      Item.Kept_Bytes := 0;
   end Forget_Matrices;

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
      Item.Kept_Bytes := 0;
      Item.Clock := 0;
      Item.Released := 0;
      Item.Taken := 0;
      Item.Heap := 0;

      --  A closed engine has given up on nothing. Forgetting this left an
      --  engine that had been given up on refusing every product after the
      --  next Open, on a device in perfect health.
      Item.Stalled := False;
      Item.Budget := 0;
      Item.Imports := False;
      Item.Import_To := 0;
      Item.Share := False;

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
   is (Item.Pipeline /= Null_Handle and then Item.Fence /= Null_Handle
       and then not Item.Stalled);

   function Is_Stalled (Item : Engine) return Boolean is (Item.Stalled);

   function Waited (Item : Engine) return Natural is (Item.Waited);

   --  The code a Vulkan wait returns when the fence has not signalled yet.
   --  Anything else that is not success is a refusal, and asking again would
   --  only put the same question.
   Timeout_Result : constant Interfaces.C.int := 2;

   ---------------------------------------------------------------------------
   --  One product
   ---------------------------------------------------------------------------

   ---------------------
   -- Give_Back_Least --
   ---------------------

   --  Release the matrix least recently multiplied by, so that another can
   --  take its place.
   --
   --  Least recently used rather than first or last. A forward pass reads
   --  every matrix of the model once in the same order, so releasing the
   --  most recent would release the one wanted next, and releasing the first
   --  would release the one wanted after that. The one wanted longest ago is
   --  the one whose turn comes last.
   --
   --  @param Item Engine holding them.
   --  @param Gone True when one was released.
   procedure Give_Back_Least (Item : in out Engine; Gone : out Boolean) is
      Oldest : Natural := 0;
   begin
      Gone := False;

      --  Among the ones that took budget, because those are the only ones
      --  releasing which makes room. An imported matrix is the host's own
      --  memory and giving it back frees none of the device's.
      for Index in 1 .. Item.Used loop
         if not Item.Kept (Index).Own
           and then (Oldest = 0
                     or else Item.Kept (Index).Used_At
                             < Item.Kept (Oldest).Used_At)
         then
            Oldest := Index;
         end if;
      end loop;

      if Oldest = 0 then
         return;
      end if;

      Give_Back_Buffer
        (Item, Item.Kept (Oldest).Buffer, Item.Kept (Oldest).Memory);
      Item.Released := Item.Released + 1;

      --  An imported matrix took none of the budget, so releasing it gives
      --  none back. Subtracting its bytes would make the budget grow every
      --  time one went, which on a model that does not fit is every token.
      if Item.Kept (Oldest).Own then
         Item.Taken := Item.Taken - 1;
      else
         Item.Kept_Bytes := Item.Kept_Bytes - Item.Kept (Oldest).Bytes;
      end if;

      --  The last one moves into the gap, because the order of this list is
      --  nothing: what says which is oldest is the count each carries.
      Item.Kept (Oldest) := Item.Kept (Item.Used);
      Item.Kept (Item.Used) :=
        (Key => Null_Handle, Buffer => Null_Handle, Memory => Null_Handle,
         Bytes => 0, Used_At => 0, Packing => Values_F32,
         Rows => 0, Columns => 0, Base => 0, Own => False);
      Item.Used := Item.Used - 1;

      Gone := True;
   end Give_Back_Least;

   --------------
   -- Resident --
   --------------

   function Resident (Item : Engine) return Natural is (Item.Used);

   function Resident_Bytes (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Kept_Bytes);

   function Capacity (Item : Engine) return Interfaces.Unsigned_64
   is (Item.Budget);

   function Given_Back (Item : Engine) return Natural is (Item.Released);

   function Imported (Item : Engine) return Natural is (Item.Taken);

   --------------
   -- Multiply --
   --------------

   ----------------
   -- Row_Bytes --
   ----------------

   function Row_Bytes
     (Packing : Weight_Packing; Columns : Natural)
      return Interfaces.Unsigned_64
   is
      --  Bytes a block takes, in the order Weight_Packing declares. A table
      --  rather than a case, because the shader's row_bytes is the same
      --  table and two lists side by side are easier to compare than two
      --  shapes of code.
      Block : constant array (Weight_Packing) of Interfaces.Unsigned_64 :=
        [Values_F32    => 4,
         Values_F16    => 2,
         Values_BF16   => 2,
         Packed_Q4_0   => 18,
         Packed_Q4_1   => 20,
         Packed_Q5_0   => 22,
         Packed_Q5_1   => 24,
         Packed_Q8_0   => 34,
         Packed_IQ4_NL => 18,
         Packed_Q2_K   => 84,
         Packed_Q3_K   => 110,
         Packed_Q4_K   => 144,
         Packed_Q5_K   => 176,
         Packed_Q6_K   => 210,
         Packed_IQ4_XS => 136];

      Per : constant Natural :=
        (case Packing is
            when Values_F32 | Values_F16 | Values_BF16 => 1,
            when Super_Packing                         => 256,
            when others                                => 32);
   begin
      --  A row is a whole number of blocks. A width that is not says the
      --  caller and the file disagree about the matrix, which is not a thing
      --  to round: zero refuses the product rather than computing one from
      --  bytes that mean something else.
      if Columns mod Per /= 0 then
         return 0;
      end if;

      return Interfaces.Unsigned_64 (Columns / Per) * Block (Packing);
   end Row_Bytes;

   ---------------------
   -- Acquire_Weights --
   ---------------------

   --  Put one matrix where the device can read it, and say how it got there.
   --
   --  Lifted out of the single product unchanged so that a sequence may do
   --  it once per step before anything is recorded. A product used to
   --  acquire its matrix and dispatch it in one breath, which is exactly
   --  what a run of products recorded together cannot do: every matrix has
   --  to be in place before the first dispatch is written down.
   --
   --  @param Item Ready engine.
   --  @param Weights Storage the matrix lies in.
   --  @param At_Byte Where in that storage the matrix begins.
   --  @param Packing How each row is packed.
   --  @param Rows Number of rows.
   --  @param Columns Number of columns.
   --  @param Weight_Bytes Bytes the matrix takes, as the caller computed it.
   --  @param Buffer Receives the device buffer holding it.
   --  @param Memory Receives the memory behind that buffer.
   --  @param Base Where in the buffer the matrix begins, which is not zero
   --    when the device took the host's own memory and had to align it.
   --  @param Borrowed True when the buffer belongs to this call and has to
   --    go back at the end of it rather than being kept.
   --  @param Ok False when the matrix could not be put anywhere.
   --  @param Key Identifies the matrix so it may be kept between calls.
   procedure Acquire_Weights
     (Item         : in out Engine;
      Weights      : Model_Runner.Bytes.Byte_Array;
      At_Byte      : Model_Runner.Bytes.Byte_Count;
      Packing      : Weight_Packing;
      Rows         : Natural;
      Columns      : Natural;
      Weight_Bytes : Interfaces.Unsigned_64;
      Buffer       : out Address;
      Memory       : out Address;
      Base         : out Interfaces.Unsigned_64;
      Borrowed     : out Boolean;
      Ok           : out Boolean;
      Key          : System.Address)
   is
      Weight_Buffer : Address renames Buffer;
      Weight_Memory : Address renames Memory;
      Weight_Base   : Interfaces.Unsigned_64 renames Base;
      Weight_Own    : Boolean := False;
      Good          : Boolean;
   begin
      Weight_Buffer := Null_Handle;
      Weight_Memory := Null_Handle;
      Weight_Base := 0;
      Borrowed := False;
      Ok := True;

      --  Is it already there? A matrix is what it is, what shape it is, and
      --  where it is. Every part of that is compared, because a caller that
      --  reuses storage would otherwise be handed somebody else's weights --
      --  and the byte count alone does not tell two matrices apart: two
      --  formats of the same width are the same length, and so are two
      --  shapes with the same number of elements.
      Item.Clock := Item.Clock + 1;

      if Key /= System.Null_Address then
         for Index in 1 .. Item.Used loop
            if Item.Kept (Index).Key = Key
              and then Item.Kept (Index).Bytes = Weight_Bytes
              and then Item.Kept (Index).Packing = Packing
              and then Item.Kept (Index).Rows = Rows
              and then Item.Kept (Index).Columns = Columns
            then
               Weight_Buffer := Item.Kept (Index).Buffer;
               Weight_Memory := Item.Kept (Index).Memory;
               Weight_Base := Item.Kept (Index).Base;
               Weight_Own := Item.Kept (Index).Own;
               Item.Kept (Index).Used_At := Item.Clock;
               exit;
            end if;
         end loop;
      end if;

      if Weight_Buffer = Null_Handle then
         --  Where the weights already are, when the caller asked for that.
         --
         --  It saves memory and never time, and the difference was measured
         --  rather than assumed. The same model and prompt on this machine:
         --  9.95 tokens a second with the weights copied to the device,
         --  2.59 with a budget holding a fifth of them and the rest uploaded
         --  again as they are wanted, and 0.80 read where they lie. So this
         --  is not the answer to a model that does not fit -- giving
         --  matrices back and uploading them again is three times better
         --  than that, which is the opposite of what this was written
         --  expecting -- it is the answer to a machine that cannot hold the
         --  model twice.
         --
         --  It costs no budget, because it is not the device's memory.
         if Item.Share
           and then Item.Imports
           and then Key /= System.Null_Address
         then
            Take_Host_Memory
              (Item,
               Whole => Weights (Weights'First)'Address,
               Span  => Interfaces.Unsigned_64 (Weights'Length),
               From  => Weights (Weights'First + At_Byte)'Address,
               Bytes => Weight_Bytes,
               Buffer => Weight_Buffer, Memory => Weight_Memory,
               Base => Weight_Base, Ok => Good);
            Weight_Own := Good;

            if not Good then
               Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
               Weight_Base := 0;
            end if;
         end if;

         if not Weight_Own then
            --  Room for it, then. A device with a heap smaller than the
            --  model used to take matrices until an allocation failed and
            --  then fail the product; now the matrix wanted longest ago
            --  goes back and this one takes its place.
            if Key /= System.Null_Address and then Item.Budget > 0 then
               declare
                  Gone : Boolean := True;
               begin
                  while Gone
                    and then Item.Used > 0
                    and then Item.Kept_Bytes + Weight_Bytes > Item.Budget
                  loop
                     Give_Back_Least (Item, Gone);
                  end loop;
               end;
            end if;

            Take (Item, Weight_Bytes, Weight_Buffer, Weight_Memory, Good);
            if not Good then
               Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
               Ok := False;
               return;
            end if;

            Write_Bytes
              (Item, Weight_Memory, Weight_Bytes,
               Weights (Weights'First + At_Byte
                        .. Weights'First + At_Byte
                           + Model_Runner.Bytes.Byte_Count (Weight_Bytes) - 1),
               Good);
            if not Good then
               Give_Back_Buffer (Item, Weight_Buffer, Weight_Memory);
               Ok := False;
               return;
            end if;
         end if;

         --  Kept if it was named and it fits, by count and by bytes.
         --  Otherwise it belongs to this call and goes back at the end of
         --  it: one matrix larger than the whole budget, on a device that
         --  will not take a host pointer, is the case that reaches this
         --  with nothing left to release, and it is handled the same way --
         --  computed, given back, correct.
         if Key /= System.Null_Address
           and then Item.Used < Max_Resident
           and then (Weight_Own
                     or else Item.Budget = 0
                     or else Item.Kept_Bytes + Weight_Bytes <= Item.Budget)
         then
            Item.Used := Item.Used + 1;
            Item.Kept (Item.Used) :=
              (Key => Key, Buffer => Weight_Buffer, Memory => Weight_Memory,
               Bytes => Weight_Bytes, Used_At => Item.Clock,
               Packing => Packing, Rows => Rows, Columns => Columns,
               Base => Weight_Base, Own => Weight_Own);

            if Weight_Own then
               Item.Taken := Item.Taken + 1;
            else
               Item.Kept_Bytes := Item.Kept_Bytes + Weight_Bytes;
            end if;
         else
            Borrowed := True;
         end if;
      end if;

   end Acquire_Weights;

   ---------------------
   -- Submit_And_Wait --
   ---------------------

   --  Hand the recorded command buffer to the queue and wait for it.
   --
   --  Lifted out of the single product unchanged, so that a sequence which
   --  records several dispatches into one buffer waits once for all of them
   --  rather than once for each. Cleaning up whatever the caller borrowed is
   --  the caller's, which is why this reports rather than releases.
   --
   --  @param Item Ready engine, with a command buffer already recorded.
   --  @param Ok False when the device did not run it.
   --  @param Cancelled True when a caller asked to stop while it ran.
   --  @param Cancel Token a caller may set to ask for a stop.
   procedure Submit_And_Wait
     (Item      : in out Engine;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference)
   is
   begin
      Ok := True;
      Cancelled := False;

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
            Ok := False;
            return;
         end if;

         Request.Buffers := Buffer_Handle'Address;

         if Reset (Item.Logical, 1, Fence_Handle'Address) /= 0
           or else Submit (Item.Queue, 1, Request'Address, Item.Fence) /= 0
         then
            Ok := False;
            return;
         end if;

         --  Waited for in slices rather than in one go, for two reasons.
         --
         --  A caller can ask to stop. Cancellation is checked between
         --  layers everywhere else in this program, and a layer on a device
         --  is one of these waits, so a wait that cannot be interrupted is
         --  the longest a stop request goes unanswered. Slicing makes that
         --  a slice rather than a whole product.
         --
         --  And the bound was wrong. A single second was a bound on the
         --  wait, and a product larger than this machine's -- a wider model,
         --  a longer batch -- can legitimately take longer, so the bound
         --  refused work that was going perfectly well. Worse, it returned
         --  with the command buffer still executing and the next call would
         --  reset and record over it while the device was reading it. The
         --  slices make the whole bound generous, because a device that has
         --  stopped answering no longer holds the thread for the whole of
         --  it; and when the bound does expire the engine is finished with
         --  rather than reused, because there is no way to take work back
         --  off a device that is not responding.
         declare
            --  Nanoseconds, which is what a Vulkan wait counts in.
            Nanoseconds : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64'Max
                (1, Interfaces.Unsigned_64 (Item.Slice * 1_000_000_000.0));

            --  How many of those the whole bound holds. A caller who asks
            --  for no patience at all gets none: zero slices is a wait that
            --  does not happen, which is the only way to reach the giving-up
            --  path without a device that has genuinely stopped answering.
            --  Clamped, because a long patience divided by a short slice
            --  is a count no Natural holds: a minute of nanosecond slices
            --  is sixty thousand million of them. The clamp is what makes
            --  a caller who asks for both an ordinary caller rather than a
            --  Constraint_Error.
            Wanted : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64
                (Duration'Max (0.0, Item.Patience) * 1_000_000_000.0)
              / Nanoseconds;

            Slices : constant Natural :=
              (if Wanted > Interfaces.Unsigned_64 (Natural'Last)
               then Natural'Last
               else Natural (Wanted));

            Answered : Boolean := False;
            Stopped  : Boolean := False;
         begin
            Item.Waited := 0;

            for Attempt in 1 .. Slices loop
               Item.Waited := Attempt;
               declare
                  Answer : constant Interfaces.C.int :=
                    Wait (Item.Logical, 1, Fence_Handle'Address, 1,
                          Nanoseconds);
               begin
                  if Answer = 0 then
                     Answered := True;
                     exit;
                  elsif Answer /= Timeout_Result then
                     --  A refusal rather than a timeout, and waiting again
                     --  would only ask the same question.
                     exit;
                  end if;
               end;

               --  Asked between slices and acted on after the device has
               --  finished, never instead of finishing: the buffers this
               --  dispatch is reading belong to it until the fence says
               --  otherwise, and giving them back sooner is how a cancelled
               --  run corrupts the next one.
               if not Stopped
                 and then Model_Runner.Cancellation."/=" (Cancel, null)
                 and then Cancel.all.Is_Requested
               then
                  Stopped := True;
               end if;
            end loop;

            if not Answered then
               --  The device did not finish inside the whole bound. Its
               --  buffers are still its own, so this engine is done: the
               --  caller is told, and nothing here touches them again.
               Item.Stalled := True;
               Ok := False;
               return;
            end if;

            if Stopped then
               Cancelled := True;
               Ok := False;
               return;
            end if;
         end;
      end;

   end Submit_And_Wait;

   -----------------
   -- One_Product --
   -----------------

   --  One matrix against one or more activations: the whole of what a
   --  product on a device is, unchanged. Both the single call and a
   --  sequence's Run reach the device through here, so there is one copy of
   --  the buffer handling, the descriptor update, the dispatch and the wait
   --  rather than two that could drift apart.
   procedure One_Product
     (Item    : in out Engine;
      Weights : Model_Runner.Bytes.Byte_Array;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Positive;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Cancelled : out Boolean;
      Key     : System.Address := System.Null_Address;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null)
   is
      Elements : constant Natural := Rows * Columns;

      --  Whichever engine is being asked, because an entry point belongs to
      --  the instance behind it.
      Ignored : constant Boolean := Set_Asking (Item);

      Wide : constant Interfaces.Unsigned_64 := Row_Bytes (Packing, Columns);

      Weight_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * Wide;
      Vector_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Columns) * Interfaces.Unsigned_64 (Count) * 4;
      Result_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Rows) * Interfaces.Unsigned_64 (Count) * 4;

      --  The matrix, kept when it has a key and made afresh when it has not.
      Weight_Buffer : Address := Null_Handle;
      Weight_Memory : Address := Null_Handle;
      Weight_Base   : Interfaces.Unsigned_64 := 0;
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
      Cancelled := False;

      --  Asked before anything is uploaded or recorded, as well as between
      --  slices of the wait further down. A request that is already standing
      --  when the product is asked for costs the device nothing, and it is
      --  the only form of this a test can arrange: a request that arrives
      --  during a wait needs a wait long enough to arrive during.
      if Model_Runner.Cancellation."/=" (Cancel, null)
        and then Cancel.all.Is_Requested
      then
         Cancelled := True;
         return;
      end if;

      if not Is_Ready (Item)
        or else Rows = 0
        or else Columns = 0
        or else Wide = 0
        or else Elements > Max_Elements
        or else Columns * Count > Max_Elements
        or else Interfaces.Unsigned_64 (Weights'Length)
                  < Interfaces.Unsigned_64 (At_Byte) + Weight_Bytes
        or else Vectors'Length
                  < Model_Runner.Numerics.Element_Count (Columns)
                    * Model_Runner.Numerics.Element_Count (Count)
        or else Target'Length
                  < Model_Runner.Numerics.Element_Count (Rows)
                    * Model_Runner.Numerics.Element_Count (Count)
      then
         return;
      end if;

      --  The matrix, wherever it has to be put to be read.
      Acquire_Weights
        (Item, Weights, At_Byte, Packing, Rows, Columns, Weight_Bytes,
         Weight_Buffer, Weight_Memory, Weight_Base, Borrowed, Good, Key);
      if not Good then
         return;
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
         Vectors (Vectors'First
                  .. Vectors'First
                     + Model_Runner.Numerics.Element_Count (Columns)
                       * Model_Runner.Numerics.Element_Count (Count) - 1),
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
         --  The weight buffer is longer than the matrix when the device
         --  took the host's memory: it starts at whatever boundary that
         --  memory had to be aligned to, and the shader is told how far in
         --  the matrix begins.
         Extent : constant array (1 .. 3) of Interfaces.Unsigned_64 :=
           [Weight_Base + Weight_Bytes, Vector_Bytes, Result_Bytes];

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
      --  declares a group to be, and one dispatch per Batch_Group vectors,
      --  which is what an invocation carries. All of them in the one command
      --  buffer: they write disjoint parts of the result and wait for
      --  nothing, so what a longer batch costs is a dispatch and not a
      --  submission.
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

         declare
            First : Natural := 0;
         begin
            while First < Count loop
               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (Rows),
                     Columns => C.unsigned (Columns),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (First),
                     Packing => C.unsigned (Weight_Packing'Pos (Packing)),
                     Base    => C.unsigned (Weight_Base));
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Shape_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer,
                     C.unsigned ((Rows + Group_Size - 1) / Group_Size), 1, 1);
               end;

               First := First + Batch_Group;
            end loop;
         end;

         if Stop (Item.Buffer) /= 0 then
            Release_Borrowed;
            return;
         end if;
      end;

      --  Hand it over and wait.
      Submit_And_Wait (Item, Good, Cancelled, Cancel);
      if not Good then
         Release_Borrowed;
         return;
      end if;

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
                  + Model_Runner.Numerics.Element_Count (Rows)
                    * Model_Runner.Numerics.Element_Count (Count) - 1)
              with Import, Address => Where;
         begin
            Target (Slice'Range) := Slice;
         end;

         Unmap (Item.Logical, Item.Result_Memory);
      end;

      Release_Borrowed;
      Ok := True;
   end One_Product;

   --------------
   -- Multiply --
   --------------

   procedure Multiply
     (Item    : in out Engine;
      Weights : Model_Runner.Bytes.Byte_Array;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Positive;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Cancelled : out Boolean;
      Key     : System.Address := System.Null_Address;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null) is
   begin
      --  A product of one, which is what a sequence of one performs. Kept as
      --  its own entry point because every caller has one matrix in hand and
      --  nothing to gain from naming a sequence to hold it.
      One_Product
        (Item, Weights, At_Byte, Packing, Rows, Columns, Vectors, Count,
         Target, Ok, Cancelled, Key, Cancel);
   end Multiply;

   -------------------
   -- Open_Sequence --
   -------------------

   procedure Open_Sequence (Steps : out Sequence) is
   begin
      Steps.Held := 0;
   end Open_Sequence;

   ------------
   -- Length --
   ------------

   function Length (Steps : Sequence) return Natural is (Steps.Held);

   -----------------
   -- Add_Product --
   -----------------

   procedure Add_Product
     (Steps   : in out Sequence;
      Weights : Model_Runner.Bytes.Byte_Array_Access;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address)
   is
      use type Model_Runner.Bytes.Byte_Array_Access;
   begin
      if Steps.Held = Sequence_Limit or else Weights = null then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Weights => Weights, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => False);
      Added := True;
   end Add_Product;

   -------------------------
   -- Add_Chained_Product --
   -------------------------

   procedure Add_Chained_Product
     (Steps   : in out Sequence;
      Weights : Model_Runner.Bytes.Byte_Array_Access;
      At_Byte : Model_Runner.Bytes.Byte_Count;
      Packing : Weight_Packing;
      Rows    : Natural;
      Columns : Natural;
      Added   : out Boolean;
      Key     : System.Address := System.Null_Address)
   is
      use type Model_Runner.Bytes.Byte_Array_Access;
   begin
      --  Nothing to chain to, no room, or a width that does not meet the
      --  one before it. Each is a refusal rather than something patched
      --  over: a product reading the wrong number of values would compute
      --  and be wrong.
      if Steps.Held = 0
        or else Steps.Held = Sequence_Limit
        or else Weights = null
        or else Columns /= Steps.Items (Steps.Held).Rows
      then
         Added := False;
         return;
      end if;

      Steps.Held := Steps.Held + 1;
      Steps.Items (Steps.Held) :=
        (Weights => Weights, At_Byte => At_Byte, Packing => Packing,
         Rows => Rows, Columns => Columns, Key => Key, Chained => True);
      Added := True;
   end Add_Chained_Product;

   ---------
   -- Run --
   ---------

   procedure Run
     (Item      : in out Engine;
      Steps     : Sequence;
      Vectors   : Model_Runner.Numerics.Real_Array;
      Count     : Positive;
      Target    : out Model_Runner.Numerics.Real_Array;
      Ok        : out Boolean;
      Cancelled : out Boolean;
      Cancel    : Model_Runner.Cancellation.Token_Reference := null)
   is
      use type Model_Runner.Bytes.Byte_Array_Access;
      use type System.Storage_Elements.Integer_Address;

      Ignored : constant Boolean := Set_Asking (Item);

      --  A storage buffer binding may not begin anywhere: a device states
      --  the boundary it wants, and no device asks for more than this.
      --  Rounding every step's share up to it is cheaper than reading the
      --  limit and far cheaper than getting it wrong, which is a validation
      --  failure on some drivers and wrong answers on others.
      Alignment : constant Interfaces.Unsigned_64 := 256;

      --  Where each product's matrix and result ended up.
      type Place is record
         Buffer   : Address := Null_Handle;
         Memory   : Address := Null_Handle;
         Base     : Interfaces.Unsigned_64 := 0;
         Borrowed : Boolean := False;
         Weight   : Interfaces.Unsigned_64 := 0;
         At_Byte  : Interfaces.Unsigned_64 := 0;
         Bytes    : Interfaces.Unsigned_64 := 0;
      end record;

      Places : array (1 .. Sequence_Limit) of Place;

      Vector_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Steps.Items (1).Columns)
        * Interfaces.Unsigned_64 (Count) * 4;

      Result_Bytes : Interfaces.Unsigned_64 := 0;
      Wanted       : Model_Runner.Numerics.Element_Count := 0;
      Good         : Boolean;

      --  Give back whatever this call borrowed, on every way out.
      procedure Release_All;

      procedure Release_All is
      begin
         for Index in 1 .. Steps.Held loop
            if Places (Index).Borrowed then
               Give_Back_Buffer
                 (Item, Places (Index).Buffer, Places (Index).Memory);
               Places (Index).Borrowed := False;
            end if;
         end loop;
      end Release_All;
   begin
      Ok := False;
      Cancelled := False;

      if Steps.Held = 0 or else not Is_Ready (Item) then
         return;
      end if;

      --  What the whole run needs, and whether it is askable at all. Every
      --  product reads the same activation, so they must agree about how
      --  wide it is; they may differ in every other way.
      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);

            Wide : constant Interfaces.Unsigned_64 :=
              Row_Bytes (This.Packing, This.Columns);

            Mine : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (This.Rows)
              * Interfaces.Unsigned_64 (Count) * 4;
         begin
            if This.Rows = 0
              or else (not This.Chained
                       and then This.Columns /= Steps.Items (1).Columns)
              or else (This.Chained
                       and then This.Columns /= Steps.Items (Index - 1).Rows)
              or else Wide = 0
              or else This.Rows * This.Columns > Max_Elements
              or else This.Columns * Count > Max_Elements
              or else This.Weights = null
              or else Interfaces.Unsigned_64 (This.Weights.all'Length)
                        < Interfaces.Unsigned_64 (This.At_Byte)
                          + Interfaces.Unsigned_64 (This.Rows) * Wide
            then
               return;
            end if;

            Places (Index).Weight :=
              Interfaces.Unsigned_64 (This.Rows) * Wide;
            Places (Index).At_Byte := Result_Bytes;
            Places (Index).Bytes := Mine;

            Result_Bytes :=
              Result_Bytes + (Mine + Alignment - 1) / Alignment * Alignment;

            Wanted := Wanted
              + Model_Runner.Numerics.Element_Count (This.Rows)
                * Model_Runner.Numerics.Element_Count (Count);
         end;
      end loop;

      if Vectors'Length
           < Model_Runner.Numerics.Element_Count (Steps.Items (1).Columns)
             * Model_Runner.Numerics.Element_Count (Count)
        or else Target'Length < Wanted
      then
         return;
      end if;

      Item.Clock := Item.Clock + 1;

      --  Every matrix in place before the first dispatch is written down.
      --  This is the whole point of the arrangement: acquiring a matrix can
      --  upload it, evict another, or take the host's own memory, and none
      --  of that may happen between two dispatches that are already
      --  recorded.
      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);
         begin
            Acquire_Weights
              (Item, This.Weights.all, This.At_Byte, This.Packing,
               This.Rows, This.Columns, Places (Index).Weight,
               Places (Index).Buffer, Places (Index).Memory,
               Places (Index).Base, Places (Index).Borrowed, Good, This.Key);
            if not Good then
               Release_All;
               return;
            end if;
         end;
      end loop;

      --  The two that change every call, grown when they have to.
      if Item.Vector_Bytes < Vector_Bytes then
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Take (Item, Vector_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
               Good);
         if not Good then
            Release_All;
            return;
         end if;
         Item.Vector_Bytes := Vector_Bytes;
      end if;

      if Item.Result_Bytes < Result_Bytes then
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good);
         if not Good then
            Release_All;
            return;
         end if;
         Item.Result_Bytes := Result_Bytes;
      end if;

      --  The activation goes over once, however many products read it.
      Write_Into
        (Item, Item.Vector_Memory, Vector_Bytes,
         Vectors (Vectors'First
                  .. Vectors'First
                     + Model_Runner.Numerics.Element_Count
                         (Steps.Items (1).Columns)
                       * Model_Runner.Numerics.Element_Count (Count) - 1),
         Good);
      if not Good then
         Release_All;
         return;
      end if;

      --  One set per product, each pointed at its own matrix and its own
      --  share of the result. A descriptor update is not recorded, so all
      --  of them are made before anything is.
      declare
         Update : constant Update_Sets_Call :=
           To_Update_Sets (Point ("vkUpdateDescriptorSets"));

         Told  : aliased Buffer_Info_Array;
         Notes : aliased Write_Array;
      begin
         if Update = null then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            Told (1) :=
              (Buffer => Places (Index).Buffer, Offset => 0,
               Extent => Places (Index).Base + Places (Index).Weight);
            --  What this product reads: the activation the caller sent,
            --  or -- for a chained one -- the result the product before it
            --  wrote, which never left the device.
            if Steps.Items (Index).Chained then
               Told (2) :=
                 (Buffer => Item.Result_Buffer,
                  Offset => Places (Index - 1).At_Byte,
                  Extent => Places (Index - 1).Bytes);
            else
               Told (2) :=
                 (Buffer => Item.Vector_Buffer, Offset => 0,
                  Extent => Vector_Bytes);
            end if;
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 3, Notes'Address, 0, Null_Handle);
         end loop;
      end;

      --  Every product in one command buffer. They read the same activation
      --  and write disjoint parts of the result, so nothing between them
      --  waits for anything and no barrier is needed -- what is saved is a
      --  submission and a fence for each product after the first.
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
         --  Looked up only when something chains. Resolving an entry point
         --  is not free, and a sequence of products that share an activation
         --  -- which is every sequence the engine names today -- would
         --  otherwise pay for a barrier it never records.
         Chains : Boolean := False;

         Barrier : Barrier_Call := null;

         Wall : aliased Memory_Barrier;

         Began : aliased Command_Begin_Info;
      begin
         if Reset_Buffer = null or else Start = null or else Stop = null
           or else Bind_Pipeline = null or else Bind_Sets = null
           or else Push = null or else Dispatch = null
         then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            Chains := Chains or else Steps.Items (Index).Chained;
         end loop;

         if Chains then
            Barrier := To_Barrier (Point ("vkCmdPipelineBarrier"));
            if Barrier = null then
               Release_All;
               return;
            end if;
         end if;

         if Reset_Buffer (Item.Buffer, 0) /= 0
           or else Start (Item.Buffer, Began'Address) /= 0
         then
            Release_All;
            return;
         end if;

         Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Pipeline);

         for Index in 1 .. Steps.Held loop
            declare
               This : Step renames Steps.Items (Index);

               Bound : aliased Address := Item.Sets (Index);
               First : Natural := 0;
            begin
               --  A chained product reads what the one before it wrote, so
               --  the device is told to finish writing before it starts
               --  reading. Products of the same activation share nothing and
               --  get no barrier, which is why this is here and not around
               --  the whole loop.
               if This.Chained then
                  Barrier
                    (Item.Buffer, Pipeline_Stage_Compute,
                     Pipeline_Stage_Compute, 0, 1, Wall'Address,
                     0, Null_Handle, 0, Null_Handle);
               end if;

               Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                          Bound'Address, 0, Null_Handle);

               while First < Count loop
                  declare
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Rows),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (First),
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    => C.unsigned (Places (Index).Base));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Shape_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned ((This.Rows + Group_Size - 1)
                                    / Group_Size), 1, 1);
                  end;

                  First := First + Batch_Group;
               end loop;
            end;
         end loop;

         if Stop (Item.Buffer) /= 0 then
            Release_All;
            return;
         end if;
      end;

      --  Once, for all of them.
      Submit_And_Wait (Item, Good, Cancelled, Cancel);
      if not Good then
         Release_All;
         return;
      end if;

      --  And what came out, product by product, out of the one mapping.
      declare
         Map   : constant Map_Call := To_Map (Point ("vkMapMemory"));
         Unmap : constant Unmap_Call := To_Unmap (Point ("vkUnmapMemory"));

         Where  : aliased Address := Null_Handle;
         Filled : Model_Runner.Numerics.Element_Count := Target'First;
      begin
         if Map (Item.Logical, Item.Result_Memory, 0, Result_Bytes, 0,
                 Where'Access) /= 0
         then
            Release_All;
            return;
         end if;

         for Index in 1 .. Steps.Held loop
            declare
               Mine : constant Model_Runner.Numerics.Element_Count :=
                 Model_Runner.Numerics.Element_Count (Steps.Items (Index).Rows)
                 * Model_Runner.Numerics.Element_Count (Count);

               Slice : Model_Runner.Numerics.Real_Array
                 (Filled .. Filled + Mine - 1)
                 with Import,
                      Address =>
                        System.Storage_Elements.To_Address
                          (System.Storage_Elements.To_Integer (Where)
                           + System.Storage_Elements.Integer_Address
                               (Places (Index).At_Byte));
            begin
               Target (Slice'Range) := Slice;
               Filled := Filled + Mine;
            end;
         end loop;

         Unmap (Item.Logical, Item.Result_Memory);
      end;

      Release_All;
      Ok := True;
   end Run;

   ---------------
   -- Multiply --
   ---------------

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

      --  This form has no caller that can be asked to stop -- it is the
      --  decoded-values one, used where a caller already holds binary32 --
      --  so nothing here reads it.
      Stopped : Boolean;
   begin
      Target := [others => 0.0];
      Ok := False;

      if Rows = 0 or else Columns = 0
        or else Elements > Max_Elements
        or else Weights'Length
                  < Model_Runner.Numerics.Element_Count (Elements)
      then
         return;
      end if;

      --  The same values, as the bytes they already are. Binary32 is what
      --  the buffer holds either way; naming it a format is the only
      --  difference between this and the general one.
      declare
         Room : constant Model_Runner.Bytes.Byte_Array
           (1 .. Model_Runner.Bytes.Byte_Count (Elements * 4))
           with Import, Address => Weights (Weights'First)'Address;
      begin
         Multiply
           (Item, Room, 0, Values_F32, Rows, Columns, Vector, 1, Target, Ok,
            Stopped, Key);
      end;
   end Multiply;

end Model_Runner.Platform.Device.Products;
