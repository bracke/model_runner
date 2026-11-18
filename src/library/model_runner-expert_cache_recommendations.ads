with Interfaces;

--  Qualified adaptive-expert cache decisions shared by the benchmark and
--  the runtime.  A registry entry is usable only for the exact model bytes,
--  engine build and device name that produced it.  The command line's
--  explicit --expert-cache always has precedence over this automatic layer.
package Model_Runner.Expert_Cache_Recommendations is

   --  Identity of the inference implementation linked into this executable.
   --  It combines the crate version with GNAT body versions of the evaluator,
   --  expert policy and device products, so rebuilding any of them makes an
   --  earlier recommendation inapplicable.
   --  @return Stable identity for this engine build.
   function Engine_Identity return String;

   --  SHA-256 of one model artifact, in lower-case hexadecimal.
   --  @param Path Ordinary file to hash.
   --  @return Sixty-four hexadecimal characters, or all zeroes on failure.
   function Artifact_Digest (Path : String) return String;

   --  Look up an automatically applicable reserve.
   --  @param Model_Path Exact model artifact to identify.
   --  @param Device Exact runtime device name.
   --  @param Device_Memory Exact device budget used by qualification.
   --  @param Registry_Path Registry to read; empty selects the platform path.
   --  @return Qualified reserve bytes, or zero when nothing exactly matches.
   function Find
     (Model_Path    : String;
      Device        : String;
      Device_Memory : Interfaces.Unsigned_64;
      Registry_Path : String := "") return Interfaces.Unsigned_64;

   --  Install or revoke one exact recommendation atomically.
   --
   --  Bytes zero revokes the matching model/build/device entry.  A nonzero
   --  entry is written only by a caller that has completed the qualification
   --  protocol; Protocol and Report retain the evidence route for audit.
   --  @param Model_SHA256 Digest already measured by the campaign.
   --  @param Device Exact device name used by the campaign.
   --  @param Device_Memory Exact device budget used by the campaign.
   --  @param Bytes Qualified reserve, or zero to revoke it.
   --  @param Protocol Qualification protocol identifier.
   --  @param Report Evidence report path.
   --  @param Registry_Path Destination; empty selects the platform path.
   --  @param Stored True when the complete updated registry was installed.
   procedure Save
     (Model_SHA256 : String;
      Device       : String;
      Device_Memory : Interfaces.Unsigned_64;
      Bytes        : Interfaces.Unsigned_64;
      Protocol     : String;
      Report       : String;
      Registry_Path : String := "";
      Stored       : out Boolean);

end Model_Runner.Expert_Cache_Recommendations;
