package body Reserved_Codes is

   package E renames Model_Runner.Errors;

   -----------------
   -- Is_Reserved --
   -----------------

   function Is_Reserved (Code : E.Error_Code) return Boolean is
   begin
      --  Named rather than listed as text, so a code that is renamed or
      --  removed fails to compile here instead of quietly falling off the
      --  list.
      --
      --  Three came off it when a round arrived: a round refuses a member
      --  that is closed or failed, and refuses more members than a batch may
      --  hold, so the three codes that said those things and had never been
      --  raised are raised now.
      case Code is
         when E.CLI_Invalid_Locale
            | E.CLI_Invalid_Mapping_Mode
            | E.IO_Write_Failed
            | E.IO_Output_Closed
            | E.IO_Seek_Failed
            | E.GGUF_Unsupported_Tensor_Type
            | E.Template_Unsupported_Role
            | E.Arch_Missing_Metadata
            | E.Arch_Invalid_Metadata
            | E.Arch_Vocabulary_Mismatch
            | E.Arch_Layer_Numbering_Gap
            | E.Tensor_Rank_Too_High
            | E.Tensor_Invalid_Stride
            | E.Tensor_Read_Only
            | E.Backend_Queue_Full
            | E.Backend_Invalid_Worker_Count
            | E.Memory_Invalid_Limit
            | E.Lifecycle_Already_Closed
            | E.Lifecycle_Mapping_Unavailable
            | E.Generation_Output_Closed
            | E.Generation_No_Logits
            | E.Conversation_Invalid_Role
            | E.Conversation_System_Unsupported
            | E.Internal_Not_Implemented
            | E.Internal_Localization_Failed =>
            return True;

         when others =>
            return False;
      end case;
   end Is_Reserved;

end Reserved_Codes;
