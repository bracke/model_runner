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
      case Code is
         when E.CLI_Invalid_Locale
            | E.CLI_Invalid_Mapping_Mode
            | E.IO_Write_Failed
            | E.IO_Output_Closed
            | E.IO_Seek_Failed
            | E.GGUF_Unsupported_Tensor_Type
            | E.GGUF_File_Changed
            | E.Tokenizer_Missing_Byte_Fallback
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
            | E.Lifecycle_Session_Closed
            | E.Lifecycle_Session_Failed
            | E.Lifecycle_Already_Closed
            | E.Lifecycle_Mapping_Unavailable
            | E.Generation_Output_Closed
            | E.Generation_No_Logits
            | E.Generation_Batch_Too_Large
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
