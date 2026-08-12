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

      --  Find an entry point by name, through the loader's own finder.
      function Entry_Point
        (Instance : System.Address; Name : String) return System.Address
      is
         Room   : C.Strings.chars_ptr := C.Strings.New_String (Name);
         Result : constant System.Address := Find (Instance, Room);
      begin
         C.Strings.Free (Room);
         return Result;
      end Entry_Point;

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

         Described : aliased Application_Info;
         Request   : aliased Instance_Create_Info;
      begin
         if Create = null then
            return;
         end if;

         Described.Name := C.Strings.New_String ("model_runner");
         Described.Api := 16#0040_0000#;   --  1.0, which is all this uses
         Request.Application := Described'Address;

         if Create (Request'Address, System.Null_Address, Instance'Access) /= 0
         then
            C.Strings.Free (Described.Name);
            return;
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

      function Entry_Point
        (Instance : System.Address; Name : String) return System.Address
      is
         Room   : C.Strings.chars_ptr := C.Strings.New_String (Name);
         Result : constant System.Address := Find (Instance, Room);
      begin
         C.Strings.Free (Room);
         return Result;
      end Entry_Point;

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

         Upload : Integer := -1;
         Fast   : Integer := -1;
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

                  if Fast < 0 and then Local then
                     Fast := Which - 1;
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
         Item.Fast := Natural (Fast);

         for Which in 1 .. Natural'Min (Natural (Room.Heap_Count),
                                        Max_Memory_Heaps)
         loop
            if Room.Heaps (Which).Size > Item.Heap then
               Item.Heap := Room.Heaps (Which).Size;
            end if;
         end loop;
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

         if Create (Physical, Request'Address, System.Null_Address,
                    Logical'Access) /= 0
         then
            Item.Family := 0;
            return;
         end if;

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

      Item.Physical := System.Null_Address;
      Item.Logical := System.Null_Address;
      Item.Queue := System.Null_Address;
      Item.Family := 0;
      Item.Upload := 0;
      Item.Fast := 0;
      Item.Shared := False;
      Item.Heap := 0;
   end Close;

   function Is_Open (Item : Context) return Boolean
   is (Item.Logical /= System.Null_Address);

   function Queue_Family (Item : Context) return Natural is (Item.Family);

   function Shares_Memory (Item : Context) return Boolean is (Item.Shared);

   function Memory_Bytes (Item : Context) return Interfaces.Unsigned_64
   is (Item.Heap);

end Model_Runner.Platform.Device;
