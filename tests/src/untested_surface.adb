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
   --  Asked of the host. Confirmed_Line and Edited_Line, as Answered_Yes
   --  and Typed_Line, wait for a person at the terminal; Started_Below is
   --  where the session was started, which a test would have to change
   --  under every other case running. Answered_Yes and Typed_Line wait for a person
   --  at the terminal the suite is run from: called here, they would hold
   --  the run until someone typed. Release_Terminal_Mode says what to
   --  put back when the program is told
   --  to end at a prompt, which ends the process: the suite cannot be told
   --  to end and go on; a run on a terminal, killed at its prompt, is how
   --  that is seen.
   --
   --  Interfaces for a caller this repository does not have. A library is
   --  wider than its command, which Library_Surface already records; these
   --  are the part of that width nothing exercises either.
   --
   --  A session's look at its project. Recover_Here opens the project in
   --  the directory the session was started in and prints what
   --  Work.Recover_On_Opening says, which its own test asserts; what is left
   --  is the current directory, which a test would have to change under
   --  every other case running.
   --
   --  The agent loop's observer. On_Turn and On_Step are what a watcher
   --  overrides to be told of each turn's calls and each step, and every
   --  `run --agent` drives them through the console's watcher; the loop's
   --  scripted case overrides On_Call and On_Result, and has no use for
   --  these two.
   --
   --  A split mixture's token path. Rouse and Take_Front_Route are what a
   --  token of a model whose experts stay on the processor goes through
   --  every layer -- the device's front half routes and the pool is kept
   --  awake for the experts -- and the split fixture's position-at-a-time
   --  arm runs exactly that against the processor's logits; it is named
   --  there by what it compares, not by these.
   --
   --  The project state's file operations. Read_Text, Write_Text,
   --  Write_Whole, Files_In and Discard_Tree are a private package of the
   --  framework, which a test
   --  cannot name; every record the state's tests read and every change
   --  they commit goes through them, and a torn or wrong write fails the
   --  round trip and recovery tests that read it back.
   --
   --  The command line's commands and what they share. Do_Run, Do_Embed,
   --  Do_Inspect, Do_Models, Choose_Model, Show_Help and Show_Version, and
   --  the helpers Read_File, Read_Standard_Input, Say_Device_Room,
   --  Free_Reals and Free_Text, are private packages of the command line's
   --  execution, which a test cannot name; every command-line test reaches
   --  them through Dispatch, as a command run from the shell does.
   --  Private to the framework. Remembered is Read_Memory's, which no test
   --  can name; the retrieval key's hand-edit test and readiness's scan
   --  hold what it gives. Delete_If_Present and Make_Directory are Files',
   --  the state's own writes, which every test that keeps a record runs.
   --
   --  Private to the command line. Execute.Support and Execute.Acquisition
   --  decide how a run runs -- its backend, workers, arithmetic, paging,
   --  panels, rotation, bounds, the model an alias names -- and every run
   --  command's test goes through them; being private, no test names them.
   --
   --  Not yet looked at. Until 2026-10-18 the check saw no function at all
   --  -- "   function " is a character shorter than "   procedure ", and was
   --  held to the same thirteen -- and these are the functions it found
   --  then, named by no test. Most are reached through a caller; none has
   --  been looked at one by one yet. Each is to come off as a test names
   --  it, or to move to a group above with its reason.
   --  (72 of them, from Action_Name on, after Remembered, in the list.)

   function Is_Untested (Name : String) return Boolean is
   begin
      return Name in
         "Add_Frame"
         | "Add_Real"
         | "Answered_Yes"
         | "Answering_Locale"
         | "Category_Name"
         | "Color_Names"
         | "Default_Severity"
         | "Divides_Into_Blocks"
         | "Enter"
         | "Finalize_Session_Plan"
         | "Flush_Sink"
         | "Generation_Progress"
         | "Has_Byte_Fallback"
         | "Has_Room"
         | "Is_Cancelled"
         | "Is_Float"
         | "Is_Greedy"
         | "Is_Integer"
         | "Is_Power_Of_Two"
         | "Is_Stop_Token"
         | "Recover_Here"
         | "Is_Valid_Array_Element"
         | "Metadata_Bytes"
         | "Next_Seed"
         | "On_Step"
         | "On_Turn"
         | "Ordinal"
         | "Prefetch_Go"
         | "Product_Batch"
         | "Put_Data_Field"
         | "Put_Embedding_Statistics"
         | "Put_Statistics"
         | "Put_Table"
         | "Put_Words"
         | "Record_Conversion"
         | "Recovery_Hint"
         | "Repack_Names"
         | "Rouse"
         | "Scalar_Size"
         | "Sequence_Length"
         | "Set_Location"
         | "Severity_Label"
         | "Storage_Bytes"
         | "Styles_Diagnostics"
         | "Take_Front_Route"
         | "Template_Condition"
         | "Tensor_Data_Bytes"
         | "Tensor_Is_Supported"
         | "To_Tensor_Type"
         | "To_Value_Type"
         | "Typed_Line"
         | "Release_Terminal_Mode"
         | "Wide_From_Bits"
         | "Write_Text"
         | "Write_Whole"
         | "Files_In"
         | "Discard_Tree"
         | "Show_Version"
         | "Show_Help"
         | "Do_Inspect"
         | "Do_Embed"
         | "Free_Reals"
         | "Free_Text"
         | "Read_Standard_Input"
         | "Say_Device_Room"
         | "Do_Run"
         | "Choose_Model"
         | "Do_Models"
         | "Remembered"
         | "Delete_If_Present"
         | "Make_Directory"
         | "Asked_Rotation"
         | "Chosen_Arithmetic"
         | "Model_Bounds"
         | "Panel_Cache_For"
         | "Resolved_Backend"
         | "Selected_Workers"
         | "Session_Paging"
         | "With_Panels"
         | "Resolve_Alias"
         | "Confirmed_Line"
         | "Edited_Line"
         | "Started_Below"
         | "Attends_Packed_Heads"
         | "Attention_Head_Room"
         | "Available_Memory"
         | "Block_Drafts"
         | "Byte_Sign_Ones_Address"
         | "Cache_Bound"
         | "Cache_Bytes_For"
         | "Carry_Lost"
         | "Config_File"
         | "Decodes_Dearly"
         | "Device_Context"
         | "Entry_Point"
         | "Feed_Width"
         | "Float_Shares"
         | "Grid_Address"
         | "Has_Integer_Dot"
         | "Has_Matrix_Instruction"
         | "Has_Sized_Subgroups"
         | "Has_Subgroup_Arithmetic"
         | "Heap_Budget"
         | "Host_Alignment"
         | "Hub_Proxy"
         | "Hub_Token"
         | "Integer_Shares"
         | "IQ1M_Scales_Address"
         | "Is_Grid"
         | "Is_Jamba"
         | "Is_Mamba2"
         | "Is_MLA"
         | "Is_Packable"
         | "Is_RWKV"
         | "Is_Stalled"
         | "Last_Refusal"
         | "Models_File"
         | "Normalizes_After"
         | "Offset_Signs_Address"
         | "Offset_Words_Address"
         | "One_State_Slot"
         | "Packs_Vectors"
         | "Panel_Row_Bytes"
         | "Panels_Unasked"
         | "Physical_Memory"
         | "Plain_Memory_Kinds"
         | "Proxy_Bypass"
         | "Pure_SSM"
         | "Queues"
         | "Resolve_Model_Path"
         | "Resolve_Session_Path"
         | "Room_Beside"
         | "Run_Capabilities"
         | "Runs_Linear"
         | "Scale_Shuffle_Address"
         | "Search_Path"
         | "Second_Kind"
         | "Second_Memory_Bytes"
         | "Sessions_Directory"
         | "Shares_Host"
         | "Shares_Memory"
         | "Sign_Ones_Address"
         | "Sign_Shuffle_Address"
         | "Storage_Limit"
         | "Stores_Pair"
         | "Submissions"
         | "Takes_Few_Together"
         | "Takes_Host_Memory"
         | "Tiled_Products"
         | "Token_Bytes"
         | "Unsupported_Reason"
         | "Untiled_Products"
         | "User_Templates_Directory"
         | "Wanted_Tile"
         | "Weights_Mapped";
   end Is_Untested;

   -----------
   -- Count --
   -----------

   function Count return Natural is (69);

end Untested_Surface;
