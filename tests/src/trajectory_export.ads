with Model_Runner.Errors;

--  Read-only trajectory validation and explicit local export. No replay, tool
--  execution, network upload or inferred verification result occurs here.
package Trajectory_Export is
   --  Validate a self-contained export, including every embedded helper and
   --  verifier result. Source files and tools are never opened or replayed.
   --  @param Path Export JSON, bounded to 128 MiB before parsing.
   --  @param Status Success or structured invalid/read failure.
   procedure Validate_Export (Path : String; Status : out Model_Runner.Errors.Error_Info);
   --  @param Episode_Path One explicitly selected complete event stream.
   --  @param Output_Path New JSON destination; existing files are never overwritten.
   --  @param Verification_Path Optional independent verdict bound to this capture's SHA-256.
   --  @param Include_Content Explicit permission to include source, prompts and tool output.
   --  @param Status Structured invalid-input, read or write failure; no partial success.
   procedure Export
     (Episode_Path, Output_Path, Verification_Path : String; Include_Content : Boolean;
      Status : out Model_Runner.Errors.Error_Info);

   --  @param Mode validate, validate-export or export.
   --  @param Episode_Path One selected episode; no implicit directory selection.
   --  @param Output_Path Required only for export.
   --  @param Verification_Path Optional independent-verification manifest.
   --  @param Include_Content Explicit content selection; absent exports counts and hashes only.
   --  @param Clean Whether the requested operation completed.
   procedure Run
     (Mode, Episode_Path, Output_Path, Verification_Path : String;
      Include_Content : Boolean; Clean : out Boolean);
end Trajectory_Export;
