with Hostkit;

--  Pinned historical tasks from real Ada repositories, outside all adapter fitting data.
package Transfer_Curriculum is
   Tasks : constant Positive := 6;
   --  @param Which Pinned historical task index.
   --  @return Stable evaluation task identifier.
   function Name (Which : Positive) return String;
   --  @param Which Pinned historical task index.
   --  @return Original repository's directory name in the Ada workspace.
   function Repository (Which : Positive) return String;
   --  @param Which Pinned historical task index.
   --  @return Complete historical fix commit identifier.
   function Revision (Which : Positive) return String;
   --  @param Which Pinned historical task index.
   --  @return Frozen work instructions, without a reference implementation.
   function Notes (Which : Positive) return String;
   --  @param Which Pinned historical task index.
   --  @return Exact permitted source paths for the task's independent scope check.
   function Paths (Which : Positive) return Hostkit.String_Vectors.Vector;
   --  @param Root New snapshot project; its independent test is Root & ".hidden_test.adb".
   --  @param Workspace Directory containing the three original read-only repositories.
   --  @param Which Pinned historical task.
   --  @param Reference Apply only the historical fix's permitted files for grader qualification.
   --  @param Clean Whether snapshot construction, compiler smoke and trusted Git initialization succeed.
   procedure Make
     (Root, Workspace : String; Which : Positive; Reference : Boolean; Clean : out Boolean);
end Transfer_Curriculum;
