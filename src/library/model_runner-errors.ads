with Interfaces;

with Model_Runner.Text;

--  Structured errors shared by every subsystem.
--
--  No package below the presentation layer builds English prose. A failure is
--  reported as an Error_Info: a stable code, a severity, a recovery
--  classification, typed parameters, an optional file offset, an optional
--  cause and optional technical context frames. Only Model_Runner.Presentation
--  turns that into text, and it does so through the message catalog.
--
--  Stable identity. Each code belongs to exactly one domain and carries a
--  public diagnostic code of the form MR-GGUF-0007. The domain and the ordinal
--  are derived mechanically from the enumeration: the ordinal is the position
--  of the literal within its domain group. New codes are therefore appended at
--  the end of their group so that published diagnostic codes never move.
--
--  Message identity. The catalog key is derived from the same literal, so a
--  code and its message cannot drift apart: GGUF_Tensor_Overlap resolves to
--  error.gguf.tensor_overlap. The tests crate checks that every code resolves.
--
--  Task safety: Error_Info is a plain value with no hidden state; it may be
--  copied freely between tasks.
package Model_Runner.Errors is

   --  Subsystem that owns a diagnostic code.
   type Error_Domain is
     (Domain_None,
      Domain_CLI,
      Domain_IO,
      Domain_GGUF,
      Domain_Tokenizer,
      Domain_Template,
      Domain_Architecture,
      Domain_Tensor,
      Domain_Backend,
      Domain_Memory,
      Domain_Lifecycle,
      Domain_Generation,
      Domain_Sampling,
      Domain_Conversation,
      Domain_Grammar,
      Domain_Internal);

   --  How serious a condition is for the operation that reported it.
   type Severity_Level is
     (Severity_Information,
      Severity_Warning,
      Severity_Error,
      Severity_Internal);

   --  What a caller can do about a condition.
   type Recovery_Class is
     (Recovery_None,
      Recovery_User_Correctable,
      Recovery_Resource_Limited,
      Recovery_Unsupported,
      Recovery_Terminal);

   --  Stable diagnostic codes.
   --
   --  Literals are grouped by domain and each literal's name begins with its
   --  domain prefix. Append new literals at the end of a group; never reorder
   --  or remove one, because the published MR-DOMAIN-NNNN ordinal is the
   --  position within the group.
   type Error_Code is
     (No_Error,

      --  Command line.
      CLI_Missing_Command,
      CLI_Unknown_Command,
      CLI_Unknown_Option,
      CLI_Missing_Option_Value,
      CLI_Unexpected_Option_Value,
      CLI_Invalid_Option_Value,
      CLI_Option_Out_Of_Range,
      CLI_Repeated_Option,
      CLI_Conflicting_Prompt_Sources,
      CLI_Conflicting_System_Sources,
      CLI_Raw_Mode_Conflict,
      CLI_Missing_Model_Path,
      CLI_Unexpected_Operand,
      CLI_Invalid_Locale,
      CLI_Invalid_Color_Mode,
      CLI_Invalid_Mapping_Mode,
      CLI_No_Prompt_Available,
      CLI_Interactive_Unavailable,
      CLI_Invalid_Environment_Value,
      CLI_Option_Not_For_Command,

      --  Host input and output.
      IO_Open_Failed,
      IO_Read_Failed,
      IO_Write_Failed,
      IO_File_Too_Large,
      IO_Not_A_Regular_File,
      IO_Invalid_UTF8,
      IO_Output_Closed,
      IO_Seek_Failed,
      IO_Input_Too_Large,

      --  GGUF container.
      GGUF_Truncated,
      GGUF_Invalid_Magic,
      GGUF_Unsupported_Version,
      GGUF_Metadata_Count_Too_Large,
      GGUF_Tensor_Count_Too_Large,
      GGUF_Invalid_String_Length,
      GGUF_Invalid_UTF8,
      GGUF_Unknown_Value_Type,
      GGUF_Invalid_Array_Element_Type,
      GGUF_Array_Too_Large,
      GGUF_Empty_Metadata_Key,
      GGUF_Duplicate_Metadata_Key,
      GGUF_Empty_Tensor_Name,
      GGUF_Duplicate_Tensor_Name,
      GGUF_Invalid_Tensor_Rank,
      GGUF_Invalid_Tensor_Dimension,
      GGUF_Unknown_Tensor_Type,
      GGUF_Unsupported_Tensor_Type,
      GGUF_Block_Misalignment,
      GGUF_Invalid_Alignment,
      GGUF_Tensor_Offset_Misaligned,
      GGUF_Tensor_Out_Of_Bounds,
      GGUF_Tensor_Overlap,
      GGUF_Arithmetic_Overflow,
      GGUF_Trailing_Data,
      GGUF_Missing_Metadata_Key,
      GGUF_Metadata_Type_Mismatch,
      GGUF_Metadata_Out_Of_Range,
      GGUF_File_Changed,

      --  Tokenizer.
      Tokenizer_Missing_Model,
      Tokenizer_Unsupported_Model,
      Tokenizer_Missing_Tokens,
      Tokenizer_Invalid_Vocabulary,
      Tokenizer_Vocabulary_Too_Large,
      Tokenizer_Invalid_Token_Text,
      Tokenizer_Invalid_Token_Id,
      Tokenizer_Invalid_Merges,
      Tokenizer_Invalid_Scores,
      Tokenizer_Invalid_Token_Type,
      Tokenizer_Input_Too_Long,
      Tokenizer_Invalid_UTF8,
      Tokenizer_Buffer_Too_Small,
      Tokenizer_Missing_Byte_Fallback,

      --  Chat templates.
      Template_Missing,
      Template_Unsupported_Construct,
      Template_Syntax_Error,
      Template_Too_Large,
      Template_Nesting_Too_Deep,
      Template_Unknown_Variable,
      Template_Unknown_Filter,
      Template_Output_Too_Large,
      Template_Iteration_Limit,
      Template_Unbalanced_Block,
      Template_Unsupported_Role,
      Template_Variables_Too_Large,
      Template_Unknown_Format,

      --  Output grammars.
      Grammar_Syntax_Error,
      Grammar_Unknown_Rule,
      Grammar_Missing_Root,
      Grammar_Too_Large,
      Grammar_Nesting_Too_Deep,
      Grammar_Too_Ambiguous,
      Grammar_Rejected_Every_Token,

      --  Architecture profile.
      Arch_Missing_Identifier,
      Arch_Unsupported,
      Arch_Missing_Metadata,
      Arch_Invalid_Metadata,
      Arch_Invalid_Dimensions,
      Arch_Invalid_Head_Counts,
      Arch_Invalid_Rope,
      Arch_Unsupported_Rope_Scaling,
      Arch_Unsupported_Feature,
      Arch_Missing_Tensor,
      Arch_Invalid_Tensor_Shape,
      Arch_Invalid_Tensor_Format,
      Arch_Vocabulary_Mismatch,
      Arch_Context_Too_Large,
      Arch_Layer_Numbering_Gap,

      --  Tensor layer.
      Tensor_Invalid_Shape,
      Tensor_Rank_Too_High,
      Tensor_Invalid_Stride,
      Tensor_Out_Of_Bounds,
      Tensor_Format_Unsupported,
      Tensor_Block_Misaligned,
      Tensor_Read_Only,
      Tensor_Shape_Mismatch,
      Tensor_Non_Finite_Value,

      --  Execution backend.
      Backend_Unknown,
      Backend_Unsupported_Format,
      Backend_Capability_Missing,
      Backend_Worker_Failed,
      Backend_Queue_Full,
      Backend_Closed,
      Backend_Invalid_Worker_Count,
      Backend_No_Device,

      --  Memory planning and allocation.
      Memory_Limit_Exceeded,
      Memory_Allocation_Failed,
      Memory_Plan_Overflow,
      Memory_Invalid_Limit,

      --  Model and session lifecycle.
      Lifecycle_Invalid_State,
      Lifecycle_Model_Not_Ready,
      Lifecycle_Session_Active,
      Lifecycle_Session_Closed,
      Lifecycle_Session_Failed,
      Lifecycle_Already_Closed,
      Lifecycle_Mapping_Unavailable,
      Lifecycle_Mapping_Required,

      --  A saved session.
      Lifecycle_Cache_Unreadable,
      Lifecycle_Cache_Mismatched,

      --  Generation coordination.
      Generation_Prompt_Too_Long,
      Generation_Context_Exhausted,
      Generation_Invalid_Request,
      Generation_Cancelled,
      Generation_Output_Closed,
      Generation_No_Logits,
      Generation_Batch_Too_Large,
      Generation_Empty_Prompt,

      --  Sampling.
      Sampling_Invalid_Configuration,
      Sampling_Vocabulary_Mismatch,
      Sampling_Non_Finite_Logit,
      Sampling_No_Candidates,
      Sampling_Invalid_Distribution,

      --  Conversation construction.
      Conversation_Too_Long,
      Conversation_Invalid_Role,
      Conversation_Empty,
      Conversation_System_Unsupported,

      --  Internal invariants.
      Internal_Invariant_Violated,
      Internal_Unexpected_Exception,
      Internal_Not_Implemented,
      Internal_Localization_Failed);

   --  Kind of a typed diagnostic parameter. The kind tells the presentation
   --  layer how to format the value; it never changes the value itself.
   type Parameter_Kind is
     (Param_Text,
      Param_Path,
      Param_Identifier,
      Param_Integer,
      Param_Bytes,
      Param_Tokens,
      Param_Offset,
      Param_Boolean,
      Param_Real);

   --  One typed parameter.
   --
   --  Name is a machine-readable field name such as "path" or "offset". It is
   --  never localized and it matches the placeholder name used by the catalog
   --  message for the owning code.
   type Parameter is record
      Name       : Model_Runner.Text.Bounded;
      Kind       : Parameter_Kind := Param_Text;
      Text_Value : Model_Runner.Text.Bounded;
      Int_Value  : Long_Long_Integer := 0;
      Real_Value : Long_Float := 0.0;
      Bool_Value : Boolean := False;
   end record;

   Max_Parameters : constant := 8;
   Max_Frames     : constant := 4;

   subtype Parameter_Count is Natural range 0 .. Max_Parameters;
   subtype Frame_Count is Natural range 0 .. Max_Frames;

   type Parameter_Array is array (1 .. Max_Parameters) of Parameter;
   type Frame_Array is array (1 .. Max_Frames) of Model_Runner.Text.Bounded;

   --  A structured condition.
   --
   --  Code = No_Error means success. Every operation in this crate that can
   --  fail returns or yields an Error_Info; none of them raise an exception
   --  for an expected operational condition.
   type Error_Info is record
      Code            : Error_Code := No_Error;
      Severity        : Severity_Level := Severity_Error;
      Parameters      : Parameter_Array;
      Parameter_Total : Parameter_Count := 0;
      Has_Location    : Boolean := False;
      Location        : Interfaces.Unsigned_64 := 0;
      Cause           : Error_Code := No_Error;
      Frames          : Frame_Array;
      Frame_Total     : Frame_Count := 0;
   end record;

   Success : constant Error_Info :=
     (Code            => No_Error,
      Severity        => Severity_Information,
      Parameters      => [others => <>],
      Parameter_Total => 0,
      Has_Location    => False,
      Location        => 0,
      Cause           => No_Error,
      Frames          => [others => Model_Runner.Text.Empty],
      Frame_Total     => 0);

   --  Report whether an outcome is a success.
   --
   --  @param Item Outcome to inspect.
   --  @return True when no condition was reported.
   function Is_Ok (Item : Error_Info) return Boolean
   is (Item.Code = No_Error);

   --  Report whether an outcome carries a condition.
   --
   --  @param Item Outcome to inspect.
   --  @return True when a condition was reported.
   function Is_Error (Item : Error_Info) return Boolean
   is (Item.Code /= No_Error);

   --  Build a condition with no parameters.
   --
   --  @param Code Diagnostic code.
   --  @param Severity Severity to report; defaults to the code's own severity.
   --  @return Structured condition.
   function Make
     (Code     : Error_Code;
      Severity : Severity_Level := Severity_Error) return Error_Info;

   --  Attach a text parameter, ignoring the request when the parameter list is
   --  full so that diagnostics never fail while reporting a failure.
   --
   --  @param Item Condition to extend.
   --  @param Name Machine-readable field name.
   --  @param Value Text value; control characters are preserved here and
   --    escaped by the presentation layer.
   --  @param Kind Parameter kind used for formatting.
   procedure Add_Text
     (Item  : in out Error_Info;
      Name  : String;
      Value : String;
      Kind  : Parameter_Kind := Param_Text);

   --  Attach an integer parameter.
   --
   --  @param Item Condition to extend.
   --  @param Name Machine-readable field name.
   --  @param Value Integer value.
   --  @param Kind Parameter kind used for formatting.
   procedure Add_Integer
     (Item  : in out Error_Info;
      Name  : String;
      Value : Long_Long_Integer;
      Kind  : Parameter_Kind := Param_Integer);

   --  Attach a floating-point configuration parameter.
   --
   --  @param Item Condition to extend.
   --  @param Name Machine-readable field name.
   --  @param Value Floating-point value.
   procedure Add_Real
     (Item  : in out Error_Info;
      Name  : String;
      Value : Long_Float);

   --  Attach a boolean parameter.
   --
   --  @param Item Condition to extend.
   --  @param Name Machine-readable field name.
   --  @param Value Boolean value.
   procedure Add_Boolean
     (Item  : in out Error_Info;
      Name  : String;
      Value : Boolean);

   --  Record the file offset a condition refers to.
   --
   --  @param Item Condition to extend.
   --  @param Offset Absolute byte offset in the model file.
   procedure Set_Location
     (Item   : in out Error_Info;
      Offset : Interfaces.Unsigned_64);

   --  Record the condition that caused this one.
   --
   --  @param Item Condition to extend.
   --  @param Cause Underlying diagnostic code.
   procedure Set_Cause
     (Item  : in out Error_Info;
      Cause : Error_Code);

   --  Append a technical context frame such as a stage or tensor name.
   --
   --  Frames are shown only in verbose diagnostics. They never carry prompt
   --  text, system messages or generated output.
   --
   --  @param Item Condition to extend.
   --  @param Frame Context description.
   procedure Add_Frame
     (Item  : in out Error_Info;
      Frame : String);

   --  Look up the parameter with a given name.
   --
   --  @param Item Condition to inspect.
   --  @param Name Field name to find.
   --  @param Found True when the parameter exists.
   --  @param Result Parameter value when Found.
   procedure Find_Parameter
     (Item   : Error_Info;
      Name   : String;
      Found  : out Boolean;
      Result : out Parameter);

   --  Domain that owns a code.
   --
   --  @param Code Diagnostic code.
   --  @return Owning domain; Domain_None for No_Error.
   function Domain (Code : Error_Code) return Error_Domain;

   --  Ordinal of a code within its domain, starting at 1.
   --
   --  @param Code Diagnostic code.
   --  @return Position within the domain group; 0 for No_Error.
   function Ordinal (Code : Error_Code) return Natural;

   --  Public diagnostic code such as "MR-GGUF-0023".
   --
   --  @param Code Diagnostic code.
   --  @return Stable public identifier; empty for No_Error.
   function Diagnostic_Code (Code : Error_Code) return String;

   --  Stable domain token used in diagnostic codes and message keys.
   --
   --  @param Item Domain to name.
   --  @return Upper-case domain token such as "GGUF".
   function Domain_Token (Item : Error_Domain) return String;

   --  Catalog key for a code, such as "error.gguf.tensor_overlap".
   --
   --  @param Code Diagnostic code.
   --  @return Stable message identifier.
   function Message_Key (Code : Error_Code) return String;

   --  Default severity for a code.
   --
   --  @param Code Diagnostic code.
   --  @return Severity used when a reporter does not override it.
   function Default_Severity (Code : Error_Code) return Severity_Level;

   --  Recovery classification for a code.
   --
   --  @param Code Diagnostic code.
   --  @return How a caller can respond to the condition.
   function Recovery (Code : Error_Code) return Recovery_Class;

   --  Message key naming what a reader can do about a failure.
   --
   --  The recovery classification was computed for every diagnostic and read
   --  once, for one of its five values, so most of it was a table nothing
   --  consulted. It chooses the line a report ends with now.
   --
   --  The class decides, and for one of them the domain refines it: a bad
   --  option and a missing file are both things the caller can put right,
   --  and only one of them is put right by reading the usage. Pointing a
   --  reader at help because their path was wrong is worse than saying
   --  nothing.
   --
   --  @param Code Diagnostic to advise on.
   --  @return Catalog key, or the empty string when there is nothing useful
   --    to say -- a cancelled run and a closed pipe are not mistakes.
   function Recovery_Hint (Code : Error_Code) return String;

   --  Process exit statuses. Centralized here so that every command maps a
   --  condition to a status the same way.
   Exit_Success        : constant := 0;
   Exit_Usage          : constant := 2;
   Exit_Model_Format   : constant := 3;
   Exit_Unsupported    : constant := 4;
   Exit_Resource       : constant := 5;
   Exit_Input_Output   : constant := 6;
   Exit_Cancelled      : constant := 7;
   Exit_Internal       : constant := 8;

   --  Process exit status for a condition.
   --
   --  @param Item Condition to classify.
   --  @return Exit status in the documented exit-class set.
   function Exit_Status (Item : Error_Info) return Natural;

end Model_Runner.Errors;
