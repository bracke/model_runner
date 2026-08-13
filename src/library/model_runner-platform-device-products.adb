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
      Share_Host : Boolean := False)
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
      Item.Kept_Bytes := 0;
      Item.Clock := 0;
      Item.Released := 0;
      Item.Taken := 0;
      Item.Heap := 0;
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
   is (Item.Pipeline /= Null_Handle and then Item.Fence /= Null_Handle);

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

   ---------------
   -- Multiply --
   ---------------

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
      Key     : System.Address := System.Null_Address)
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
      Weight_Own    : Boolean := False;
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
   end Multiply;

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
            Key);
      end;
   end Multiply;

end Model_Runner.Platform.Device.Products;
