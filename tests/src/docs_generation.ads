--  Deterministic documentation generation from the Ada registries.
--
--  The error-code reference is generated rather than written by hand, so it
--  cannot drift from the enumeration it documents. Generation is deterministic:
--  the same source always produces the same bytes.
--
--  Task safety: a run uses one task.
package Docs_Generation is

   --  Write the error-code reference.
   --
   --  @param Root Repository root directory.
   --  @param Written True when the file was produced.
   procedure Write_Error_Reference (Root : String; Written : out Boolean);

   --  Report whether the file on disk matches what would be generated.
   --
   --  Used as a check so that a stale committed reference is a failure rather
   --  than a surprise.
   --
   --  @param Root Repository root directory.
   --  @return True when the committed file is current.
   function Error_Reference_Is_Current (Root : String) return Boolean;

end Docs_Generation;
