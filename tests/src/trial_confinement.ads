with Hostkit;

--  Filesystem and process confinement for campaign sessions and independent checks.
package Trial_Confinement is

   --  @return Absolute Bubblewrap path on Linux, or empty when confinement is unavailable.
   function Executable return String;

   --  @param Program Absolute native executable to start inside the boundary.
   --  @param Arguments Its native argument vector, without shell interpretation.
   --  @param Writable Only host directory the child may write.
   --  @param Hidden Optional campaign directory hidden before selected paths are exposed again.
   --  @param Readable Exact additional input paths, including inputs hidden by private temporary storage.
   --  @return Bubblewrap arguments; the caller starts Executable and refuses an unavailable backend.
   function Wrap
     (Program : String; Arguments : Hostkit.String_Vectors.Vector;
      Writable : String; Hidden : String := "";
      Readable : Hostkit.String_Vectors.Vector := Hostkit.String_Vectors.Empty_Vector)
      return Hostkit.String_Vectors.Vector;

   --  @param Directory Existing scratch directory for the preflight process and diagnostics.
   --  @return True only after the host actually executes a confined native process successfully.
   function Ready (Directory : String) return Boolean;

end Trial_Confinement;
