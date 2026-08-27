with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

with System.Storage_Elements;

--  Devices, through the host's Vulkan loader.
--
--  The loader is opened by name rather than linked, so a machine without one
--  reports no devices instead of failing to start. Everything below is
--  reached through vkGetInstanceProcAddr, which is the one entry point the
--  interface guarantees a loader exports and the only one this looks up by
--  name in the library itself.
--
--  This directory is compiled for Linux and for macOS. Every number here is
--  from the interface's own definition rather than from a host header, so
--  the two agree: the structure layouts, the enumerators and the success
--  codes are the same on both by specification. What differs is the library
--  name, and macOS is the reason the loader is looked for by two names and
--  the absence of one is an answer rather than a failure -- a Mac has no
--  loader unless somebody installed one, and then it is a translation layer
--  onto that machine's own interface.
--
--  Checked against Linux, where a device answered. Not checked against
--  macOS: no Mac was to hand, and what is claimed for it is only that
--  finding no loader reports no devices, which is the same path a Linux
--  machine without one takes.
--
--  Structures are declared here to the extent they are used and no further.
--  Where the interface defines a structure this only reads the head of --
--  the device properties, whose tail is several hundred bytes of limits --
--  it is passed a buffer large enough for the whole thing and the fields
--  that are wanted are read at their stated offsets. Transcribing a hundred
--  fields to reach the fifth would be more code to be wrong in, not less.
package body Model_Runner.Platform.Device is

   use type Interfaces.C.int;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Storage_Offset;
   use type Interfaces.C.unsigned;
   use type System.Address;

   package C renames Interfaces.C;

   --  The loader, opened once and kept for the life of the program. Closing
   --  it would mean unloading a driver while an instance made from it may
   --  still exist, which is not something to do on a whim.
   Library : System.Address := System.Null_Address;
   Tried   : Boolean := False;

   RTLD_NOW : constant C.int := 2;

   function dlopen
     (Name : C.Strings.chars_ptr; Flags : C.int) return System.Address
     with Import, Convention => C, External_Name => "dlopen";

   function dlsym
     (Handle : System.Address; Name : C.Strings.chars_ptr) return System.Address
     with Import, Convention => C, External_Name => "dlsym";

   --  The interface's own way of finding the rest of itself.
   type Get_Proc_Address is access
     function (Instance : System.Address; Name : C.Strings.chars_ptr)
       return System.Address
     with Convention => C;

   Find : Get_Proc_Address := null;

   --  What little of the interface this needs.
   type Create_Instance_Call is access
     function (Info      : System.Address;
               Allocator : System.Address;
               Instance  : access System.Address) return C.int
     with Convention => C;

   type Destroy_Instance_Call is access
     procedure (Instance : System.Address; Allocator : System.Address)
     with Convention => C;

   type Enumerate_Call is access
     function (Instance : System.Address;
               Count    : access C.unsigned;
               Devices  : System.Address) return C.int
     with Convention => C;

   type Properties_Call is access
     procedure (Device : System.Address; Properties : System.Address)
     with Convention => C;

   --  An application description and an instance request, in the layout the
   --  interface states. Both begin with a structure type and a pointer to
   --  the next structure in a chain, which is how the interface extends
   --  itself without changing what is already there.
   Structure_Application_Info : constant := 0;
   Structure_Instance_Create  : constant := 1;

   type Application_Info is record
      Kind        : C.unsigned := Structure_Application_Info;
      Next        : System.Address := System.Null_Address;
      Name        : C.Strings.chars_ptr := C.Strings.Null_Ptr;
      Version     : C.unsigned := 0;
      Engine      : C.Strings.chars_ptr := C.Strings.Null_Ptr;
      Engine_Kind : C.unsigned := 0;
      Api         : C.unsigned := 0;
   end record
     with Convention => C;

   type Instance_Create_Info is record
      Kind        : C.unsigned := Structure_Instance_Create;
      Next        : System.Address := System.Null_Address;
      Flags       : C.unsigned := 0;
      Application : System.Address := System.Null_Address;
      Layer_Count : C.unsigned := 0;
      Layers      : System.Address := System.Null_Address;
      Extension_Count : C.unsigned := 0;
      Extensions  : System.Address := System.Null_Address;
   end record
     with Convention => C;

   --  Room for the whole of the device properties structure, whose tail this
   --  does not read. Larger than the interface needs rather than exactly as
   --  large, because being wrong in this direction costs a few hundred bytes
   --  of stack and being wrong in the other lets a driver write past the end.
   Properties_Bytes : constant := 2048;

   subtype Properties_Buffer is
     System.Storage_Elements.Storage_Array (1 .. Properties_Bytes);

   --  Where the fields this reads begin, counting from the first byte of the
   --  structure: four unsigned numbers, then the device kind, then the name.
   Offset_Device_Kind : constant := 16;
   Offset_Device_Name : constant := 20;

   --  And where the limits begin, and the one limit this reads within them.
   --  The structure ahead of them is four unsigned numbers, the kind, the
   --  name and a sixteen-byte identifier, which comes to 292 -- and the
   --  limits hold sixty-four bit numbers further in, so they are aligned to
   --  eight and begin at 296 rather than at 292. The four bytes of padding
   --  are the whole difference between reading what a storage buffer may
   --  hold and reading what a uniform buffer may, which is 65536 on every
   --  device and would refuse every model. Within the limits, seven
   --  unsigned numbers stand before the one wanted here.
   Offset_Limits             : constant := 296;
   Offset_Storage_Range      : constant := Offset_Limits + 28;

   Device_Kind_Discrete : constant := 2;

   --  Queue families and devices, which is the rest of what opening one
   --  needs. A queue family is a group of queues that accept the same kinds
   --  of work; a device is made with the families it will use named up
   --  front.
   Structure_Queue_Create  : constant := 2;
   Structure_Device_Create : constant := 3;

   Queue_Compute : constant := 2;

   Memory_Device_Local  : constant := 1;
   Memory_Host_Visible  : constant := 2;
   Memory_Host_Coherent : constant := 4;
   Memory_Host_Cached   : constant := 8;

   Max_Families : constant := 16;

   type Queue_Family_Properties is record
      Flags       : C.unsigned := 0;
      Count       : C.unsigned := 0;
      Timestamps  : C.unsigned := 0;
      Granule_X   : C.unsigned := 0;
      Granule_Y   : C.unsigned := 0;
      Granule_Z   : C.unsigned := 0;
   end record
     with Convention => C;

   type Family_Array is array (1 .. Max_Families) of Queue_Family_Properties;

   type Queue_Create_Info is record
      Kind       : C.unsigned := Structure_Queue_Create;
      Next       : System.Address := System.Null_Address;
      Flags      : C.unsigned := 0;
      Family     : C.unsigned := 0;
      Count      : C.unsigned := 1;
      Priorities : System.Address := System.Null_Address;
   end record
     with Convention => C;

   type Device_Create_Info is record
      Kind            : C.unsigned := Structure_Device_Create;
      Next            : System.Address := System.Null_Address;
      Flags           : C.unsigned := 0;
      Queue_Count     : C.unsigned := 1;
      Queues          : System.Address := System.Null_Address;
      Layer_Count     : C.unsigned := 0;
      Layers          : System.Address := System.Null_Address;
      Extension_Count : C.unsigned := 0;
      Extensions      : System.Address := System.Null_Address;
      Features        : System.Address := System.Null_Address;
   end record
     with Convention => C;

   --  Interface versions, as the interface encodes them: the major number
   --  in the top ten bits and the minor in the next ten.
   --
   --  This program asked for 1.0 for as long as it had asked for anything,
   --  and that was deliberate: 1.0 is what every loader has, and nothing
   --  here needed more. The matrix instruction needs more -- a shader using
   --  it is SPIR-V 1.6, which a 1.0 instance may not accept -- so the floor
   --  moves without the promise changing. What is asked for is the best the
   --  loader answers, up to 1.3; a loader that answers nothing is a 1.0
   --  loader, because vkEnumerateInstanceVersion is itself a 1.1 function
   --  and a loader without it has no way to say it is anything else.
   Api_1_0 : constant := 16#0040_0000#;
   Api_1_1 : constant := 16#0040_1000#;
   Api_1_3 : constant := 16#0040_3000#;

   --  The version the instance was made with, which decides whether the
   --  calls that arrived after 1.0 may be made at all. Package state
   --  because the instance is: it is made once, before any device is
   --  opened, and read by every device opened afterwards.
   Instance_Api : C.unsigned := Api_1_0;

   type Version_Call is access
     function (Version : access C.unsigned) return C.int
     with Convention => C;

   function To_Version is
     new Ada.Unchecked_Conversion (System.Address, Version_Call);

   --  The cooperative matrix, and the two things a shader using one needs
   --  besides: half precision in a shader at all, and half precision in a
   --  storage buffer. All three are asked for together and refused
   --  together, because a device with one and not the others cannot run the
   --  shader and there is nothing to fall back to but the row product,
   --  which is what a device without any of them runs.
   Structure_Matrix_Features  : constant := 1000506000;
   Structure_Matrix_Shape     : constant := 1000506001;
   Structure_Half_Features    : constant := 1000082000;
   Structure_Storage_16       : constant := 1000083000;
   Structure_Subgroup         : constant := 1000094000;
   Structure_Properties_2     : constant := 1000059001;

   --  What the interface calls the component types this asks about, and the
   --  scope a shape is offered at. Half precision is nought and binary32 is
   --  one; a subgroup is three.
   Component_Half   : constant := 0;
   Component_Single : constant := 1;
   Scope_Subgroup   : constant := 3;

   type Matrix_Features is record
      Kind     : C.unsigned := Structure_Matrix_Features;
      Next     : System.Address := System.Null_Address;
      Matrices : C.unsigned := 0;
      Robust   : C.unsigned := 0;
   end record
     with Convention => C;

   type Half_Features is record
      Kind : C.unsigned := Structure_Half_Features;
      Next : System.Address := System.Null_Address;
      Half : C.unsigned := 0;
      Byte : C.unsigned := 0;
   end record
     with Convention => C;

   type Storage_Features is record
      Kind    : C.unsigned := Structure_Storage_16;
      Next    : System.Address := System.Null_Address;
      Buffer  : C.unsigned := 0;
      Uniform : C.unsigned := 0;
      Pushed  : C.unsigned := 0;
      Staged  : C.unsigned := 0;
   end record
     with Convention => C;

   --  One shape the device will multiply: how large, what the three
   --  operands and the result are made of, and what agrees on it.
   type Matrix_Shape is record
      Kind        : C.unsigned := Structure_Matrix_Shape;
      Next        : System.Address := System.Null_Address;
      M_Size      : C.unsigned := 0;
      N_Size      : C.unsigned := 0;
      K_Size      : C.unsigned := 0;
      A_Kind      : C.unsigned := 0;
      B_Kind      : C.unsigned := 0;
      C_Kind      : C.unsigned := 0;
      Result_Kind : C.unsigned := 0;
      Saturating  : C.unsigned := 0;
      Scope       : C.unsigned := 0;
   end record
     with Convention => C;

   Max_Shapes : constant := 64;

   type Shape_Array is array (1 .. Max_Shapes) of aliased Matrix_Shape;

   type Shape_Query_Call is access
     function (Device : System.Address;
               Count  : access C.unsigned;
               Room   : System.Address) return C.int
     with Convention => C;

   function To_Shape_Query is
     new Ada.Unchecked_Conversion (System.Address, Shape_Query_Call);

   --  What a device has to offer its compute shaders before the subgroup
   --  attention kernel may be dispatched: the basic operations, which is
   --  what names a subgroup and elects a lane of it, and the arithmetic
   --  ones, which is the add and the maximum the reduction is made of.
   --  VkSubgroupFeatureFlagBits, and the compute bit of VkShaderStageFlags.
   Subgroup_Basic      : constant := 16#0000_0001#;
   Subgroup_Arithmetic : constant := 16#0000_0004#;
   Stage_Is_Compute    : constant := 16#0000_0020#;

   --  How wide a subgroup is here, which the matrix instruction's shapes
   --  are stated for. The shader is written for sixty-four and says so;
   --  a device whose subgroups are another width is left on the row
   --  product rather than given a shader whose arithmetic would be
   --  arranged for a subgroup it has not got.
   type Subgroup_Properties is record
      Kind       : C.unsigned := Structure_Subgroup;
      Next       : System.Address := System.Null_Address;
      Width      : C.unsigned := 0;
      Stages     : C.unsigned := 0;
      Operations : C.unsigned := 0;
      Quads      : C.unsigned := 0;
   end record
     with Convention => C;

   --  Room for the whole of the 1.1 properties structure, whose tail this
   --  does not read, for the reason Properties_Buffer states.
   type Properties_2 is record
      Kind : C.unsigned := Structure_Properties_2;
      Next : System.Address := System.Null_Address;
      Room : Properties_Buffer := [others => 0];
   end record
     with Convention => C;

   type Properties_2_Call is access
     procedure (Device : System.Address; Properties : System.Address)
     with Convention => C;

   function To_Properties_2 is
     new Ada.Unchecked_Conversion (System.Address, Properties_2_Call);

   --  What an extension is called, as the interface reports it: a fixed
   --  name field and a revision. Read to find out whether this device will
   --  take a pointer to the host's own memory.
   Max_Extension_Name : constant := 256;
   Max_Extensions     : constant := 512;

   type Extension_Property is record
      Name    : C.char_array (1 .. Max_Extension_Name) := [others => C.nul];
      Version : C.unsigned := 0;
   end record
     with Convention => C;

   type Extension_Array is
     array (1 .. Max_Extensions) of aliased Extension_Property;

   --  What the interface says about memory: up to thirty-two kinds, each
   --  naming what it can do and which heap it comes from, then up to sixteen
   --  heaps, each with a size.
   Max_Memory_Kinds : constant := 32;
   Max_Memory_Heaps : constant := 16;

   type Memory_Kind is record
      Flags : C.unsigned := 0;
      Heap  : C.unsigned := 0;
   end record
     with Convention => C;

   type Memory_Heap is record
      Size  : Interfaces.Unsigned_64 := 0;
      Flags : C.unsigned := 0;
      Pad   : C.unsigned := 0;
   end record
     with Convention => C;

   type Memory_Kind_Array is array (1 .. Max_Memory_Kinds) of Memory_Kind;
   type Memory_Heap_Array is array (1 .. Max_Memory_Heaps) of Memory_Heap;

   type Memory_Properties is record
      Kind_Count : C.unsigned := 0;
      Kinds      : Memory_Kind_Array;
      Heap_Count : C.unsigned := 0;
      Heaps      : Memory_Heap_Array;
   end record
     with Convention => C;

   type Family_Query_Call is access
     procedure (Device   : System.Address;
                Count    : access C.unsigned;
                Families : System.Address)
     with Convention => C;

   type Memory_Query_Call is access
     procedure (Device : System.Address; Properties : System.Address)
     with Convention => C;

   type Create_Device_Call is access
     function (Physical  : System.Address;
               Info      : System.Address;
               Allocator : System.Address;
               Device    : access System.Address) return C.int
     with Convention => C;

   type Destroy_Device_Call is access
     procedure (Device : System.Address; Allocator : System.Address)
     with Convention => C;

   type Get_Queue_Call is access
     procedure (Device : System.Address;
                Family : C.unsigned;
                Index  : C.unsigned;
                Queue  : access System.Address)
     with Convention => C;

   --  What extensions a device has, asked twice: once for the count and
   --  once for the names.
   type Extension_List_Call is access
     function (Device : System.Address;
               Layer  : C.Strings.chars_ptr;
               Count  : access C.unsigned;
               Room   : System.Address) return C.int
     with Convention => C;

   function To_Extension_List is
     new Ada.Unchecked_Conversion (System.Address, Extension_List_Call);

   ------------------
   -- Is_Supported --
   ------------------

   --  Open the loader, once, and find the one entry point the rest is
   --  reached through.
   procedure Load is
      Names : constant array (1 .. 2) of C.Strings.chars_ptr :=
        [C.Strings.New_String ("libvulkan.so.1"),
         C.Strings.New_String ("libvulkan.so")];
   begin
      if Tried then
         return;
      end if;
      Tried := True;

      for Candidate of Names loop
         if Library = System.Null_Address then
            Library := dlopen (Candidate, RTLD_NOW);
         end if;
      end loop;

      for Candidate of Names loop
         declare
            Room : C.Strings.chars_ptr := Candidate;
         begin
            C.Strings.Free (Room);
         end;
      end loop;

      if Library = System.Null_Address then
         return;
      end if;

      declare
         Entry_Name : C.Strings.chars_ptr :=
           C.Strings.New_String ("vkGetInstanceProcAddr");
         Found      : constant System.Address := dlsym (Library, Entry_Name);

         function To_Finder is
           new Ada.Unchecked_Conversion (System.Address, Get_Proc_Address);
      begin
         C.Strings.Free (Entry_Name);

         if Found /= System.Null_Address then
            Find := To_Finder (Found);
         end if;
      end;
   end Load;

   function Is_Supported return Boolean is
   begin
      Load;
      return Find /= null;
   end Is_Supported;

   ------------------
   -- Entry_Point --
   ------------------

   function Entry_Point
     (Instance : System.Address; Name : String) return System.Address
   is
      Room   : C.Strings.chars_ptr := C.Strings.New_String (Name);
      Result : System.Address := System.Null_Address;
   begin
      Load;

      if Find /= null then
         Result := Find (Instance, Room);
      end if;

      C.Strings.Free (Room);
      return Result;
   end Entry_Point;

   ----------
   -- Open --
   ----------

   procedure Open (Item : in out Inventory; Found : out Boolean) is
      function To_Create is
        new Ada.Unchecked_Conversion (System.Address, Create_Instance_Call);
      function To_Enumerate is
        new Ada.Unchecked_Conversion (System.Address, Enumerate_Call);
      function To_Properties is
        new Ada.Unchecked_Conversion (System.Address, Properties_Call);

      Instance : aliased System.Address := System.Null_Address;
   begin
      Close (Item);
      Found := False;

      Load;
      if Find = null then
         return;
      end if;

      --  An instance, with no layers and no extensions: nothing here draws
      --  anything or talks to a window system.
      declare
         Create : constant Create_Instance_Call :=
           To_Create (Entry_Point (System.Null_Address, "vkCreateInstance"));

         --  A 1.1 function, asked for through the one entry point that
         --  needs no instance. A loader that does not export it is a 1.0
         --  loader by definition, which is the whole of the test.
         Ask : constant Version_Call :=
           To_Version
             (Entry_Point (System.Null_Address,
                           "vkEnumerateInstanceVersion"));

         Offered : aliased C.unsigned := Api_1_0;

         Described : aliased Application_Info;
         Request   : aliased Instance_Create_Info;
      begin
         if Create = null then
            return;
         end if;

         Instance_Api := Api_1_0;

         if Ask /= null and then Ask (Offered'Access) = 0 then
            Instance_Api := C.unsigned'Min (Offered, Api_1_3);
         end if;

         Described.Name := C.Strings.New_String ("model_runner");
         Described.Api := Instance_Api;
         Request.Application := Described'Address;

         if Create (Request'Address, System.Null_Address, Instance'Access) /= 0
         then
            --  A loader that answered and then refused what it answered.
            --  Asking for 1.0 is what this did before any of this was here,
            --  and it is what a host that cannot give more still runs.
            Instance_Api := Api_1_0;
            Described.Api := Api_1_0;

            if Create (Request'Address, System.Null_Address,
                       Instance'Access) /= 0
            then
               C.Strings.Free (Described.Name);
               return;
            end if;
         end if;

         C.Strings.Free (Described.Name);
      end;

      Item.Handle := Instance;
      Found := True;

      declare
         Enumerate : constant Enumerate_Call :=
           To_Enumerate (Entry_Point (Instance, "vkEnumeratePhysicalDevices"));
         Properties : constant Properties_Call :=
           To_Properties
             (Entry_Point (Instance, "vkGetPhysicalDeviceProperties"));

         Devices : array (1 .. Max_Devices) of aliased System.Address :=
           [others => System.Null_Address];
         Counted : aliased C.unsigned := Max_Devices;
      begin
         if Enumerate = null or else Properties = null then
            return;
         end if;

         if Enumerate (Instance, Counted'Access, Devices'Address) not in 0 | 5
         then
            --  Zero is success and five is "there were more than you asked
            --  for", which is not a failure: it means the list is full.
            return;
         end if;

         Item.Used := Natural'Min (Natural (Counted), Max_Devices);

         for Index in 1 .. Item.Used loop
            declare
               Room : Properties_Buffer := [others => 0];
            begin
               Properties (Devices (Index), Room'Address);

               declare
                  Kind : C.unsigned;
                  for Kind'Address use
                    Room (Offset_Device_Kind + 1)'Address;
                  pragma Import (Ada, Kind);

                  Text : String (1 .. Max_Name_Bytes);
                  for Text'Address use
                    Room (Offset_Device_Name + 1)'Address;
                  pragma Import (Ada, Text);

                  Last : Natural := 0;
               begin
                  Item.Discrete (Index) := Kind = Device_Kind_Discrete;

                  --  The name is a run of bytes ending at the first zero.
                  while Last < Max_Name_Bytes
                    and then Text (Last + 1) /= Character'Val (0)
                  loop
                     Last := Last + 1;
                  end loop;

                  Item.Names (Index).Last := Last;
                  Item.Names (Index).Text (1 .. Last) := Text (1 .. Last);
                  Item.Handles (Index) := Devices (Index);
               end;
            end;
         end loop;
      end;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Inventory) is
      function To_Destroy is
        new Ada.Unchecked_Conversion (System.Address, Destroy_Instance_Call);
   begin
      if Item.Handle /= System.Null_Address and then Find /= null then
         declare
            Room : C.Strings.chars_ptr :=
              C.Strings.New_String ("vkDestroyInstance");

            Destroy : constant Destroy_Instance_Call :=
              To_Destroy (Find (Item.Handle, Room));
         begin
            C.Strings.Free (Room);

            if Destroy /= null then
               Destroy (Item.Handle, System.Null_Address);
            end if;
         end;
      end if;

      Item.Handle := System.Null_Address;
      Item.Used := 0;
      Item.Discrete := [others => False];
      Item.Handles := [others => System.Null_Address];

      for Index in Item.Names'Range loop
         Item.Names (Index).Last := 0;
      end loop;
   end Close;

   -----------
   -- Count --
   -----------

   function Count (Item : Inventory) return Natural is (Item.Used);

   ----------
   -- Name --
   ----------

   function Name (Item : Inventory; Index : Positive) return String is
   begin
      if Index > Item.Used then
         return "";
      end if;

      return Item.Names (Index).Text (1 .. Item.Names (Index).Last);
   end Name;

   -----------------
   -- Is_Discrete --
   -----------------

   function Is_Discrete (Item : Inventory; Index : Positive) return Boolean is
   begin
      return Index <= Item.Used and then Item.Discrete (Index);
   end Is_Discrete;

   ---------------------------------------------------------------------------
   --  An open device
   ---------------------------------------------------------------------------

   procedure Open
     (Item  : in out Context;
      From  : Inventory;
      Index : Positive;
      Ready : out Boolean)
   is
      function To_Families is
        new Ada.Unchecked_Conversion (System.Address, Family_Query_Call);
      function To_Memory is
        new Ada.Unchecked_Conversion (System.Address, Memory_Query_Call);
      function To_Create is
        new Ada.Unchecked_Conversion (System.Address, Create_Device_Call);
      function To_Queue is
        new Ada.Unchecked_Conversion (System.Address, Get_Queue_Call);
      function To_Properties is
        new Ada.Unchecked_Conversion (System.Address, Properties_Call);

      Physical : System.Address;
   begin
      Close (Item);
      Ready := False;

      if Find = null
        or else From.Handle = System.Null_Address
        or else Index > From.Used
      then
         return;
      end if;

      Physical := From.Handles (Index);
      if Physical = System.Null_Address then
         return;
      end if;

      --  A family that accepts compute. Graphics is not asked for and not
      --  wanted: nothing here draws.
      declare
         Families : constant Family_Query_Call :=
           To_Families
             (Entry_Point (From.Handle,
                           "vkGetPhysicalDeviceQueueFamilyProperties"));

         Room    : Family_Array;
         Counted : aliased C.unsigned := Max_Families;
         Chosen  : Integer := -1;
      begin
         if Families = null then
            return;
         end if;

         Families (Physical, Counted'Access, Room'Address);

         for Which in 1 .. Natural'Min (Natural (Counted), Max_Families) loop
            if Chosen < 0
              and then (Room (Which).Flags and Queue_Compute) /= 0
              and then Room (Which).Count > 0
            then
               Chosen := Which - 1;

               --  How many queues that family offers, which decides whether
               --  a second one is a thing this host could have at all. Kept
               --  rather than acted on: submitting to two is a policy, and
               --  knowing whether two exist is the question that comes
               --  first.
               Item.Queues := Natural (Room (Which).Count);
            end if;
         end loop;

         if Chosen < 0 then
            return;
         end if;

         Item.Family := Natural (Chosen);
      end;

      --  The memory it offers: one kind the processor can write, one the
      --  device reads fastest. On a device that shares the machine's memory
      --  they are the same kind, which is what Shares_Memory reports.
      declare
         Memory : constant Memory_Query_Call :=
           To_Memory
             (Entry_Point (From.Handle,
                           "vkGetPhysicalDeviceMemoryProperties"));

         Room : Memory_Properties;

         Upload   : Integer := -1;
         Download : Integer := -1;
         Fast     : Integer := -1;
      begin
         if Memory = null then
            Item.Family := 0;
            return;
         end if;

         Memory (Physical, Room'Address);

         --  A kind the processor can write, preferring one the device also
         --  reads directly. Taking the first that the processor can write
         --  reported this machine's integrated device as not sharing its
         --  memory, because the kind that does both is further down the
         --  list than one that only the processor can reach -- a plausible
         --  answer and the wrong one.
         for Pass in 1 .. 2 loop
            for Which in 1 .. Natural'Min (Natural (Room.Kind_Count),
                                           Max_Memory_Kinds)
            loop
               declare
                  Flags : constant C.unsigned := Room.Kinds (Which).Flags;

                  Writable : constant Boolean :=
                    (Flags and Memory_Host_Visible) /= 0
                    and then (Flags and Memory_Host_Coherent) /= 0;

                  Local : constant Boolean :=
                    (Flags and Memory_Device_Local) /= 0;
               begin
                  --  The first pass takes only a kind that is both; the
                  --  second settles for one the processor can write.
                  if Upload < 0
                    and then Writable
                    and then (Local or else Pass = 2)
                  then
                     Upload := Which - 1;
                     Item.Shared := Local;
                  end if;

                  --  A kind the processor reads at the speed it reads its
                  --  own memory. Without the cached bit a read is a read of
                  --  the device's memory a word at a time and uncombined,
                  --  which is around a tenth of the bandwidth writing it
                  --  gets: this machine offers no kind that is both cached
                  --  and the device's own, and a result is read far more
                  --  than the device reads it back.
                  if Download < 0
                    and then Writable
                    and then (Flags and Memory_Host_Cached) /= 0
                  then
                     Download := Which - 1;
                  end if;

                  if Fast < 0 and then Local then
                     Fast := Which - 1;
                  end if;

                  --  And every kind the processor writes and sees without a
                  --  flush, which is the set an imported host pointer has to
                  --  be taken as one of.
                  if Writable then
                     Item.Plain_Kinds :=
                       Item.Plain_Kinds
                       or Interfaces.Shift_Left (1, Which - 1);
                  end if;
               end;
            end loop;
         end loop;

         if Upload < 0 or else Fast < 0 then
            Item.Family := 0;
            Item.Shared := False;
            return;
         end if;

         Item.Upload := Natural (Upload);

         --  A device with no cached kind reads its results out of the same
         --  memory it writes them to, which is what every device did before
         --  this was asked for.
         Item.Download :=
           (if Download < 0 then Natural (Upload) else Natural (Download));

         Item.Fast := Natural (Fast);

         for Which in 1 .. Natural'Min (Natural (Room.Heap_Count),
                                        Max_Memory_Heaps)
         loop
            if Room.Heaps (Which).Size > Item.Heap then
               Item.Heap := Room.Heaps (Which).Size;
            end if;
         end loop;
      end;

      --  What one storage buffer may hold, which is what bounds one
      --  product's matrix. Read from the same structure the name came from.
      declare
         Properties : constant Properties_Call :=
           To_Properties
             (Entry_Point (From.Handle, "vkGetPhysicalDeviceProperties"));
         Room : Properties_Buffer := [others => 0];
      begin
         if Properties /= null then
            Properties (Physical, Room'Address);

            declare
               Stated : C.unsigned;
               for Stated'Address use Room (Offset_Storage_Range + 1)'Address;
               pragma Import (Ada, Stated);
            begin
               Item.Storage := Interfaces.Unsigned_64 (Stated);
            end;
         end if;
      end;

      --  And the device itself, with the one queue.
      declare
         Create : constant Create_Device_Call :=
           To_Create (Entry_Point (From.Handle, "vkCreateDevice"));

         Priority : aliased C.C_float := 1.0;
         Wanted   : aliased Queue_Create_Info;
         Request  : aliased Device_Create_Info;

         Logical : aliased System.Address := System.Null_Address;
      begin
         if Create = null then
            Item.Family := 0;
            return;
         end if;

         Wanted.Family := C.unsigned (Item.Family);
         Wanted.Priorities := Priority'Address;
         Request.Queues := Wanted'Address;

         --  Two extensions, and only when the device has both: one says a
         --  buffer may come from somewhere outside the interface, the other
         --  says that somewhere may be the host's own memory. A device
         --  without them is opened exactly as before and is handed copies.
         declare
            Wanted_External : constant String := "VK_KHR_external_memory";
            Wanted_Host     : constant String :=
              "VK_EXT_external_memory_host";
            Wanted_Matrix   : constant String :=
              "VK_KHR_cooperative_matrix";

            Has_External, Has_Host, Has_Matrix : Boolean := False;

            --  Whether the device offers a shape this program can use, at a
            --  subgroup width the shader was written for. Both are asked
            --  before the extension is enabled, because both are questions
            --  about the physical device and neither needs a logical one.
            Usable : Boolean := False;

            --  And whether it offers subgroup arithmetic to a compute
            --  shader, which is a different question with a different
            --  answer: it is core Vulkan 1.1 and wants no extension, so a
            --  device may have it and not the matrix instruction.
            Grouped : Boolean := False;

            List  : constant Extension_List_Call :=
              To_Extension_List
                (Entry_Point (From.Handle,
                              "vkEnumerateDeviceExtensionProperties"));

            Count : aliased C.unsigned := 0;
            Room  : aliased Extension_Array;

            Names : aliased array (1 .. 3) of C.Strings.chars_ptr :=
              [others => C.Strings.Null_Ptr];

            --  The chain the device is asked for the matrix instruction
            --  through: the instruction itself, half precision in a shader,
            --  and half precision in a storage buffer. Declared here so
            --  they outlive the call that reads them.
            Matrices : aliased Matrix_Features;
            Halves   : aliased Half_Features;
            Stored   : aliased Storage_Features;
         begin
            if List /= null
              and then List (Physical, C.Strings.Null_Ptr, Count'Access,
                             System.Null_Address) = 0
              and then Count > 0
            then
               if Natural (Count) > Max_Extensions then
                  Count := C.unsigned (Max_Extensions);
               end if;

               if List (Physical, C.Strings.Null_Ptr, Count'Access,
                        Room'Address) = 0
               then
                  for Index in 1 .. Natural (Count) loop
                     declare
                        Text : constant String :=
                          C.To_Ada (Room (Index).Name, Trim_Nul => True);
                     begin
                        if Text = Wanted_External then
                           Has_External := True;
                        elsif Text = Wanted_Host then
                           Has_Host := True;
                        elsif Text = Wanted_Matrix then
                           Has_Matrix := True;
                        end if;
                     end;
                  end loop;
               end if;
            end if;

            --  What the device will multiply, how wide its subgroups are,
            --  and what it will let a compute shader do with one. All of
            --  these arrived after 1.0, so all are asked only where the
            --  instance was made with more than that.
            if Instance_Api >= Api_1_1 then
               declare
                  Widths : constant Properties_2_Call :=
                    To_Properties_2
                      (Entry_Point (From.Handle,
                                    "vkGetPhysicalDeviceProperties2"));
                  Shapes : constant Shape_Query_Call :=
                    To_Shape_Query
                      (Entry_Point
                         (From.Handle,
                          "vkGetPhysicalDeviceCooperativeMatrixProperties"
                          & "KHR"));

                  Wide     : aliased Subgroup_Properties;
                  Reported : aliased Properties_2;
                  Held     : aliased C.unsigned := Max_Shapes;
                  Offered  : aliased Shape_Array;

                  Right_Width : Boolean := False;
               begin
                  if Widths /= null then
                     Reported.Next := Wide'Address;
                     Widths (Physical, Reported'Address);
                     Right_Width := Wide.Width = 64;

                     --  The reduction needs a lane elected and the two
                     --  arithmetic operations, in a compute shader. A
                     --  device offering them in some other stage and not
                     --  this one is a device this leaves on the wide
                     --  kernel.
                     Grouped :=
                       (Wide.Operations
                        and (Subgroup_Basic or Subgroup_Arithmetic))
                       = (Subgroup_Basic or Subgroup_Arithmetic)
                       and then (Wide.Stages and Stage_Is_Compute) /= 0;
                  end if;

                  if Widths /= null and then Shapes /= null
                    and then Has_Matrix
                  then
                     if Right_Width
                       and then Shapes (Physical, Held'Access,
                                        Offered'Address) in 0 | 5
                     then
                        for Index in 1 .. Natural
                          (C.unsigned'Min (Held, Max_Shapes))
                        loop
                           --  Sixteen by sixteen by sixteen, half precision
                           --  in and binary32 out, agreed on by a subgroup:
                           --  the one shape matrix_product.comp is written
                           --  for.
                           if Offered (Index).M_Size = 16
                             and then Offered (Index).N_Size = 16
                             and then Offered (Index).K_Size = 16
                             and then Offered (Index).A_Kind = Component_Half
                             and then Offered (Index).B_Kind = Component_Half
                             and then Offered (Index).C_Kind
                                        = Component_Single
                             and then Offered (Index).Result_Kind
                                        = Component_Single
                             and then Offered (Index).Scope = Scope_Subgroup
                           then
                              Usable := True;
                           end if;
                        end loop;
                     end if;
                  end if;
               end;
            end if;

            if Has_External and then Has_Host then
               Names (1) := C.Strings.New_String (Wanted_External);
               Names (2) := C.Strings.New_String (Wanted_Host);
               Request.Extension_Count := 2;
               Request.Extensions := Names'Address;
            end if;

            if Usable then
               Names (Natural (Request.Extension_Count) + 1) :=
                 C.Strings.New_String (Wanted_Matrix);
               Request.Extension_Count := Request.Extension_Count + 1;
               Request.Extensions := Names'Address;

               Matrices.Matrices := 1;
               Halves.Half := 1;
               Halves.Next := Matrices'Address;
               Stored.Buffer := 1;
               Stored.Next := Halves'Address;
               Request.Next := Stored'Address;
            end if;

            if Create (Physical, Request'Address, System.Null_Address,
                       Logical'Access) /= 0
            then
               --  Again without the matrix instruction, which is the one
               --  of the three that asks the device for features as well
               --  as for a name. A device that refused it still has the
               --  memory extensions and still runs the row product.
               if Usable then
                  Usable := False;
                  Request.Next := System.Null_Address;
                  Request.Extension_Count := Request.Extension_Count - 1;

                  if Request.Extension_Count = 0 then
                     Request.Extensions := System.Null_Address;
                  end if;
               end if;

               if Create (Physical, Request'Address, System.Null_Address,
                          Logical'Access) /= 0
               then
                  --  And again with nothing asked for, because a device
                  --  that refused the extensions is still a device.
                  Request.Extension_Count := 0;
                  Request.Extensions := System.Null_Address;
                  Has_External := False;
                  Has_Host := False;

                  if Create (Physical, Request'Address, System.Null_Address,
                             Logical'Access) /= 0
                  then
                     for Held of Names loop
                        if C.Strings."/=" (Held, C.Strings.Null_Ptr) then
                           C.Strings.Free (Held);
                        end if;
                     end loop;
                     Item.Family := 0;
                     return;
                  end if;
               end if;
            end if;

            for Held of Names loop
               if C.Strings."/=" (Held, C.Strings.Null_Ptr) then
                  C.Strings.Free (Held);
               end if;
            end loop;

            Item.Matrices := Usable;
            Item.Subgroups := Grouped;

            --  The alignment a host pointer needs is a property this build
            --  does not ask for -- it arrives through an interface version
            --  the instance does not request -- so a page is assumed and the
            --  import is attempted. A device wanting more refuses the
            --  allocation and the caller copies instead, which is the same
            --  answer arrived at one call later.
            Item.Imports := Has_External and then Has_Host;
            Item.Import_To := (if Item.Imports then 4096 else 0);
         end;

         Item.Instance := From.Handle;
         Item.Physical := Physical;
         Item.Logical := Logical;
      end;

      declare
         Queue : constant Get_Queue_Call :=
           To_Queue (Entry_Point (From.Handle, "vkGetDeviceQueue"));

         Handle : aliased System.Address := System.Null_Address;
      begin
         if Queue /= null then
            Queue (Item.Logical, C.unsigned (Item.Family), 0, Handle'Access);
            Item.Queue := Handle;
         end if;
      end;

      Ready := Item.Logical /= System.Null_Address;
   end Open;

   procedure Close (Item : in out Context) is
      function To_Destroy is
        new Ada.Unchecked_Conversion (System.Address, Destroy_Device_Call);
   begin
      if Item.Logical /= System.Null_Address and then Find /= null then
         declare
            Room : C.Strings.chars_ptr :=
              C.Strings.New_String ("vkDestroyDevice");

            Destroy : constant Destroy_Device_Call :=
              To_Destroy (Find (System.Null_Address, Room));
         begin
            C.Strings.Free (Room);

            if Destroy /= null then
               Destroy (Item.Logical, System.Null_Address);
            end if;
         end;
      end if;

      Item.Instance := System.Null_Address;
      Item.Physical := System.Null_Address;
      Item.Logical := System.Null_Address;
      Item.Queue := System.Null_Address;
      Item.Family := 0;
      Item.Upload := 0;
      Item.Download := 0;
      Item.Fast := 0;
      Item.Shared := False;
      Item.Heap := 0;
      Item.Storage := 0;
   end Close;

   function Is_Open (Item : Context) return Boolean
   is (Item.Logical /= System.Null_Address);

   function Queue_Family (Item : Context) return Natural is (Item.Family);

   function Queue_Count (Item : Context) return Natural is (Item.Queues);

   function Shares_Memory (Item : Context) return Boolean is (Item.Shared);

   ------------------------
   -- Takes_Host_Memory --
   ------------------------

   --  Through the accessor rather than the field, because the accessor is
   --  what answers this question and a package reading its own private part
   --  around it would leave an operation nothing calls.
   function Takes_Host_Memory (Item : Context) return Boolean
   is (Item.Imports and then Shares_Memory (Item));

   ------------------------------
   -- Has_Matrix_Instruction --
   ------------------------------

   function Has_Matrix_Instruction (Item : Context) return Boolean
   is (Item.Matrices);

   -------------------------------
   -- Has_Subgroup_Arithmetic --
   -------------------------------

   function Has_Subgroup_Arithmetic (Item : Context) return Boolean
   is (Item.Subgroups);

   ---------------------
   -- Host_Alignment --
   ---------------------

   function Host_Alignment (Item : Context) return Interfaces.Unsigned_64
   is (Item.Import_To);

   --------------------------
   -- Plain_Memory_Kinds --
   --------------------------

   function Plain_Memory_Kinds (Item : Context) return Interfaces.Unsigned_32
   is (Item.Plain_Kinds);

   function Memory_Bytes (Item : Context) return Interfaces.Unsigned_64
   is (Item.Heap);

   -------------------
   -- Storage_Limit --
   -------------------

   function Storage_Limit (Item : Context) return Interfaces.Unsigned_64
   is (Item.Storage);

end Model_Runner.Platform.Device;
