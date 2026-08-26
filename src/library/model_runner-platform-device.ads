with Interfaces;

with System;

--  What compute devices the host can reach.
--
--  This is the first of the pieces a device backend needs, and it is the one
--  that decides whether there is anything to talk to. Nothing here computes:
--  it loads the host's Vulkan loader if there is one, asks it what physical
--  devices exist, and reports their names.
--
--  Availability. A device is a host facility, not a requirement. A machine
--  with no loader, no driver or no device reports none, and the caller falls
--  back to a backend that runs on the processor. Nothing here fails a build,
--  a load or a run for the absence of a device -- the whole point of asking
--  is to be told no.
--
--  Why loaded rather than linked. Linking the loader would make a binary
--  that will not start on a machine without it, which is most machines this
--  program is useful on. The library is opened by name at the moment it is
--  first asked for, and a machine that does not have it is a machine with no
--  devices rather than a machine that cannot run the program.
--
--  Task safety: an Inventory belongs to one task. Opening one is not
--  reentrant.
package Model_Runner.Platform.Device is

   --  Largest number of devices reported. A machine with more has the rest
   --  ignored rather than the list truncated silently at an unstated point.
   Max_Devices : constant := 8;

   --  Longest device name reported, in bytes. The interface that supplies
   --  them fixes this at 256.
   Max_Name_Bytes : constant := 256;

   --  Report whether this build can reach a device interface at all.
   --
   --  False on a host with no loader, and on a host this build has no body
   --  for. It says nothing about whether any device exists.
   --
   --  @return True when the interface could be loaded.
   function Is_Supported return Boolean;

   --  What the host has.
   type Inventory is limited private;

   --  Ask the host what devices it has.
   --
   --  @param Item Inventory to fill; released first.
   --  @param Found True when the interface answered, whether or not it named
   --    any device.
   procedure Open (Item : in out Inventory; Found : out Boolean);

   --  Release an inventory. Idempotent.
   --
   --  @param Item Inventory to release.
   procedure Close (Item : in out Inventory);

   --  How many devices the host named.
   --
   --  @param Item Inventory to inspect.
   --  @return Device count, zero when none were named.
   function Count (Item : Inventory) return Natural;

   --  What a device calls itself.
   --
   --  Reported as the interface gave it, with the trailing padding removed.
   --  It is a name from a driver, so it is data: nothing here interprets it
   --  and the presentation layer escapes it like any other untrusted text.
   --
   --  @param Item Inventory to inspect.
   --  @param Index Device number, from one.
   --  @return The name, or an empty string when there is no such device.
   function Name (Item : Inventory; Index : Positive) return String;

   --  Whether a device is one that has its own memory.
   --
   --  An integrated device shares the processor's, which changes what
   --  moving data to it costs and nothing else about what it can do.
   --
   --  @param Item Inventory to inspect.
   --  @param Index Device number, from one.
   --  @return True for a discrete device.
   function Is_Discrete (Item : Inventory; Index : Positive) return Boolean;

   --  An open device: something that can be given work.
   --
   --  Opening one asks the host for a queue that accepts compute, and finds
   --  the two kinds of memory anything running on it needs -- one the
   --  processor can write, and one the device reads fastest. On a device
   --  that shares the machine's memory those are the same kind, which is
   --  what makes an integrated device cheap to hand data to and no faster
   --  to read it back from.
   type Context is limited private;

   --  Open the numbered device.
   --
   --  @param Item Context to fill; released first.
   --  @param From Inventory the device was named in.
   --  @param Index Device number, from one.
   --  @param Ready True when the device opened and offers a compute queue.
   procedure Open
     (Item  : in out Context;
      From  : Inventory;
      Index : Positive;
      Ready : out Boolean);

   --  Release a device. Idempotent.
   --
   --  @param Item Context to release.
   procedure Close (Item : in out Context);

   --  Report whether a context has a device behind it.
   --
   --  @param Item Context to inspect.
   --  @return True when it is open.
   function Is_Open (Item : Context) return Boolean;

   --  Which family of queues the compute queue came from.
   --
   --  Reported because it is the one number about a device that decides
   --  what work it will accept, and a reader chasing a refusal wants it.
   --
   --  @param Item Open context.
   --  @return Family number, or zero when the context is not open.
   function Queue_Family (Item : Context) return Natural;

   --  How many queues the chosen family offers.
   --
   --  One is common and two or more is not rare. This program submits to a
   --  single queue and waits on it; whether it could submit to two is
   --  decided here rather than guessed, and reported by `inspect` so the
   --  answer is a fact about the host rather than an assumption in a plan.
   --
   --  @param Item Open context.
   --  @return Queues the family has, or zero when no context is open.
   function Queue_Count (Item : Context) return Natural;

   --  Whether the memory the processor writes is also the memory the device
   --  reads.
   --
   --  True on a device that shares the machine's memory. It decides whether
   --  handing over a model costs a copy or costs nothing.
   --
   --  @param Item Open context.
   --  @return True when one kind of memory serves both.
   function Shares_Memory (Item : Context) return Boolean;

   --  Report whether the device will take the host's own memory directly.
   --
   --  True only where the device says it can and where it shares the host's
   --  memory, because importing memory the device would have to copy anyway
   --  buys nothing and hides where the copy happens.
   --
   --  @param Item Open device.
   --  @return True when a host pointer can become a buffer.
   function Takes_Host_Memory (Item : Context) return Boolean;

   --  Which memory kinds the processor writes and reads directly.
   --
   --  @param Item Open device.
   --  @return Mask over the device's memory kinds.
   function Plain_Memory_Kinds
     (Item : Context) return Interfaces.Unsigned_32;

   --  Whether this device will multiply a tile of a matrix in one
   --  instruction, at the shape the batched product is written for.
   --
   --  True only where the device offers VK_KHR_cooperative_matrix with a
   --  sixteen-by-sixteen-by-sixteen half-precision shape agreed on by a
   --  subgroup, where a subgroup here is sixty-four wide, and where the
   --  loader let the instance be made at more than Vulkan 1.0 -- a shader
   --  using the instruction is SPIR-V 1.6, which a 1.0 instance may refuse.
   --  Every other host answers False and runs the row product, which is
   --  what this program did everywhere until there was something else.
   --
   --  @param Item Open device.
   --  @return True when the matrix product may be dispatched here.
   function Has_Matrix_Instruction (Item : Context) return Boolean;

   --  What a host pointer must be aligned to before this device will take
   --  it.
   --
   --  @param Item Open device.
   --  @return Alignment in bytes, or zero when the device takes none.
   function Host_Alignment (Item : Context) return Interfaces.Unsigned_64;

   --  How much memory the device says it has, in bytes.
   --
   --  The largest heap it reports. On a device that shares the machine's
   --  memory this is a share of that memory rather than a separate store.
   --
   --  @param Item Open context.
   --  @return Bytes, or zero when the context is not open.
   function Memory_Bytes (Item : Context) return Interfaces.Unsigned_64;

   --  The largest storage buffer a shader on this device may read.
   --
   --  A matrix reaches a shader as one buffer, so this is the bound on what
   --  one product's weights may be, and it is the device's own answer rather
   --  than a number chosen here. Asked for because the bound that used to
   --  stand in its place was chosen here, was two hundred and sixty-eight
   --  million elements, and refused every model whose output projection is
   --  wider than that -- which is every model above about four billion
   --  parameters, on a device whose real answer is four gigabytes.
   --
   --  @param Item Open context.
   --  @return Bytes, or zero when the context is not open.
   function Storage_Limit (Item : Context) return Interfaces.Unsigned_64;

private

   type Name_Text is record
      Last : Natural := 0;
      Text : String (1 .. Max_Name_Bytes) := [others => ' '];
   end record;

   type Name_List is array (1 .. Max_Devices) of Name_Text;
   type Discrete_List is array (1 .. Max_Devices) of Boolean;

   --  What Open found, kept for the operations above. The handles are the
   --  host's own and mean nothing here.
   --  Find one of the host interface's entry points by name.
   --
   --  Private because what an entry point is belongs to whatever interface
   --  the host has, and only the children of this package have any use for
   --  one. An instance is needed for all but a handful of them, which is
   --  why the context keeps the one it was opened from.
   function Entry_Point
     (Instance : System.Address; Name : String) return System.Address;

   type Context is limited record
      Instance : System.Address := System.Null_Address;
      Physical : System.Address := System.Null_Address;
      Logical  : System.Address := System.Null_Address;
      Queue    : System.Address := System.Null_Address;

      Family   : Natural := 0;
      Queues   : Natural := 0;
      Upload   : Natural := 0;

      --  The kind to allocate a buffer the processor reads back out of.
      --
      --  Upload is chosen for what the device reads: memory it owns, which
      --  the processor writes through a combining buffer and cannot read
      --  back at any speed at all. Reading is what a result is for, so a
      --  result is allocated out of a kind the processor caches even when
      --  that means the device reaches across the bus for it. Same kind as
      --  Upload where the device offers no cached one.
      Download : Natural := 0;

      Fast     : Natural := 0;
      Shared   : Boolean := False;
      Heap     : Interfaces.Unsigned_64 := 0;

      --  What the device says one storage buffer may hold. Read where the
      --  name and the kind are read, from the same structure.
      Storage  : Interfaces.Unsigned_64 := 0;

      --  Whether this device will take a pointer to the host's own memory
      --  as a buffer, instead of being given a copy of what is in it, and
      --  what that pointer has to be aligned to. On a device that shares
      --  the host's memory the copy is the same memory twice, which for a
      --  model is a gigabyte of it.
      Imports  : Boolean := False;
      Import_To : Interfaces.Unsigned_64 := 0;

      --  Whether the device took the cooperative matrix extension and
      --  offers the shape the batched product is written for.
      Matrices : Boolean := False;

      --  Which memory kinds the processor can both write and see without
      --  being told to flush, as a mask over the device's list. An imported
      --  host pointer can be taken as some kinds and not others, and the one
      --  chosen has to be in both sets.
      Plain_Kinds : Interfaces.Unsigned_32 := 0;
   end record;

   type Address_List is array (1 .. Max_Devices) of System.Address;

   type Inventory is limited record
      Used     : Natural := 0;
      Names    : Name_List;
      Discrete : Discrete_List := [others => False];

      --  The host's own handle for each device, kept so that one of them
      --  can be opened afterwards.
      Handles  : Address_List := [others => System.Null_Address];

      --  The interface's own handle, kept so that closing gives it back.
      --  Zero when nothing is open. An address rather than a pointer to
      --  anything Ada names: what is behind it belongs to the loader.
      Handle   : System.Address := System.Null_Address;
   end record;

end Model_Runner.Platform.Device;
