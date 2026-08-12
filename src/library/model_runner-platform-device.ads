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

private

   type Name_Text is record
      Last : Natural := 0;
      Text : String (1 .. Max_Name_Bytes) := [others => ' '];
   end record;

   type Name_List is array (1 .. Max_Devices) of Name_Text;
   type Discrete_List is array (1 .. Max_Devices) of Boolean;

   type Inventory is limited record
      Used     : Natural := 0;
      Names    : Name_List;
      Discrete : Discrete_List := [others => False];

      --  The interface's own handle, kept so that closing gives it back.
      --  Zero when nothing is open. An address rather than a pointer to
      --  anything Ada names: what is behind it belongs to the loader.
      Handle   : System.Address := System.Null_Address;
   end record;

end Model_Runner.Platform.Device;
