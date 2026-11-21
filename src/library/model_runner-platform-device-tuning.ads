--  Durable, exact-match launch choices for one device and shader build.
--
--  This package only describes and stores choices. Loading a record does not
--  apply it to a device; the caller decides when a validated profile is used.
package Model_Runner.Platform.Device.Tuning is

   Schema_Version   : constant := 1;
   Max_Key_Bytes    : constant := 512;
   Max_Record_Bytes : constant := 4 * 1024;

   subtype Workgroup_Count is Positive range 1 .. 4_096;
   subtype Position_Count is Positive range 1 .. 16 * 1024 * 1024;
   subtype Slice_Count is Positive range 1 .. 1_024;
   subtype Batch_Count is Positive range 1 .. 4_096;

   --  Choices whose current constants are always safe fallbacks. The record
   --  is intentionally smaller than the set of device implementation knobs:
   --  a tuning campaign may propose only a value represented here.
   type Launch_Choices is record
      Attention_Workgroups  : Workgroup_Count := 256;
      Attention_Slice_Least : Position_Count := 256;
      Attention_Slice_Limit : Slice_Count := 16;
      Row_Product_Workgroup : Workgroup_Count := 256;
      Packed_Bundle_Least   : Position_Count := 256;
      Packed_Cuts_A_Round   : Boolean := True;
      Matrix_Row_Crossover  : Batch_Count := 9;
   end record;

   Default_Choices : constant Launch_Choices := (others => <>);

   --  Digest of every embedded shader whose dispatch policy a profile may
   --  change. The explicit tuner and ordinary profile loading share this
   --  value so that either side changing invalidates the same record.
   --
   --  @return Stable text for the affected shader set in this build.
   function Shader_Stamp return String;

   --  Whether every value names a compiled and measured alternative.
   --
   --  @param Value Complete launch policy to validate.
   --  @return True only when every field is on its fixed candidate list.
   function Is_Supported (Value : Launch_Choices) return Boolean;

   type Tuning_Key is private;

   --  Make the exact-match key for a device, shader set and executable.
   --  A missing identity or stamp, a control character, or a key past the
   --  fixed bound makes an invalid key.
   --
   --  @param Identity Device and driver facts.
   --  @param Shader_Stamp Digest or version of all affected shader programs.
   --  @param Program_Stamp Stamp of the executable that selects the programs.
   --  @return The bounded key, possibly invalid.
   function Create_Key
     (Identity      : Device_Identity;
      Shader_Stamp  : String;
      Program_Stamp : String) return Tuning_Key;

   --  @param Key Key to inspect.
   --  @return True when it can name and validate a profile.
   function Is_Valid (Key : Tuning_Key) return Boolean;

   --  @param Key Key to render.
   --  @return Its canonical text, or empty text for an invalid key.
   function Image (Key : Tuning_Key) return String;

   --  Default profile path beneath the cache home, beside the prefill cache.
   --
   --  @param Key Exact-match key.
   --  @return The path, or empty text when no cache path or valid key exists.
   function Profile_Path (Key : Tuning_Key) return String;

   --  Read a profile only when it is complete, known, in range and keyed
   --  exactly as Expected. Any failure is an ordinary cache miss.
   --
   --  @param Path File to read.
   --  @param Expected Key the file must carry.
   --  @param Value Choices read, or the safe defaults.
   --  @param Found True only for a wholly valid exact-match record.
   procedure Load
     (Path     : String;
      Expected : Tuning_Key;
      Value    : out Launch_Choices;
      Found    : out Boolean);

   --  Write a canonical record to a sibling temporary file and atomically
   --  replace Path. Invalid keys are not written.
   --
   --  @param Path Destination file.
   --  @param Key Exact-match key written into the record.
   --  @param Value Choices to store.
   --  @param Written True after the durable replacement succeeds.
   procedure Store
     (Path    : String;
      Key     : Tuning_Key;
      Value   : Launch_Choices;
      Written : out Boolean);

private

   type Tuning_Key is record
      Last : Natural range 0 .. Max_Key_Bytes := 0;
      Text : String (1 .. Max_Key_Bytes) := [others => ' '];
   end record;

end Model_Runner.Platform.Device.Tuning;
