package body Untested_Surface is

   --  Grouped by why, because sixty-four separate sentences would be read
   --  by nobody and the groups are the reasons that matter.
   --
   --  Reached through a caller. Every one of these runs on an ordinary
   --  path -- a container parse, a session open, a report -- so a mistake in
   --  it fails something else. The three prefetches are a batch's streamed
   --  expert stacks, which the split mixture's test runs streamed: a copy
   --  half made fails it. What is missing is a test that names it and
   --  says what it should do, which is what would tell a wrong answer from
   --  an answer nobody looked at.
   --
   --  Asked of the host. Is_Terminal, Host_Locale and Executable_Directory
   --  answer differently on every machine and cannot be asserted against a
   --  value; what can be asked of them is their contract, and Core_Count is
   --  the one that has been.
   --
   --  Interfaces for a caller this repository does not have. A library is
   --  wider than its command, which Library_Surface already records; these
   --  are the part of that width nothing exercises either.
   --
   --  The agent loop's observer. On_Call, On_Result and On_Step are what
   --  a watcher overrides to be told of each call, each result and each
   --  step, and every `run --agent` drives them through the console's
   --  watcher; a test that names them would need a model that calls a
   --  tool, and no fixture here does -- the campaign that exercises them
   --  runs against published models, behind the gate rather than in it.
   --
   --  A split mixture's token path. Rouse and Take_Front_Route are what a
   --  token of a model whose experts stay on the processor goes through
   --  every layer -- the device's front half routes and the pool is kept
   --  awake for the experts -- and the split fixture's position-at-a-time
   --  arm runs exactly that against the processor's logits; it is named
   --  there by what it compares, not by these.
   function Is_Untested (Name : String) return Boolean is
   begin
      return Name in
         "Accepts"
         | "Add_Frame"
         | "Add_Integer"
         | "Add_Real"
         | "Answering_Locale"
         | "Capability"
         | "Category_Name"
         | "Class_Of"
         | "Color_Names"
         | "Data_Offset"
         | "Default_Severity"
         | "Divides_Into_Blocks"
         | "Enter"
         | "Executable_Directory"
         | "Finalize_Session_Plan"
         | "Flush_Sink"
         | "Generation_Progress"
         | "Has_Byte_Fallback"
         | "Has_Room"
         | "Host_Locale"
         | "Is_Cancelled"
         | "Is_Empty"
         | "Is_Float"
         | "Is_Greedy"
         | "Is_Integer"
         | "Is_Power_Of_Two"
         | "Is_Stop_Token"
         | "Is_Terminal"
         | "Is_Valid_Array_Element"
         | "Metadata_Bytes"
         | "Metadata_Element_Kind"
         | "Model_Name"
         | "Next_Seed"
         | "On_Call"
         | "On_Result"
         | "On_Step"
         | "Ordinal"
         | "Plan_For"
         | "Power"
         | "Prefetch"
         | "Prefetch_Go"
         | "Prefetch_Stacks"
         | "Product_Batch"
         | "Put_Data_Field"
         | "Put_Statistics"
         | "Put_Table"
         | "Put_Words"
         | "Record_Conversion"
         | "Recovery_Hint"
         | "Repack_Names"
         | "Role_Name"
         | "Rouse"
         | "Row_Bytes"
         | "Scalar_Size"
         | "Sequence_Length"
         | "Set_Location"
         | "Severity_Label"
         | "Storage_Bytes"
         | "Styles_Diagnostics"
         | "Take_Front_Route"
         | "Template_Condition"
         | "Template_Ready"
         | "Tensor_Data_Bytes"
         | "Tensor_Elements"
         | "Tensor_Is_Supported"
         | "To_Tensor_Type"
         | "To_Value_Type"
         | "Wide_From_Bits";
   end Is_Untested;

   -----------
   -- Count --
   -----------

   function Count return Natural is (66);

end Untested_Surface;
