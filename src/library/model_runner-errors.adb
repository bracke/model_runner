package body Model_Runner.Errors is

   package T renames Model_Runner.Text;

   --  Return the segment of Image before the first underscore. Every code
   --  literal is named Prefix_Rest, so this is the domain prefix.
   function Name_Prefix (Image : String) return String is
   begin
      for Index in Image'Range loop
         if Image (Index) = '_' then
            return Image (Image'First .. Index - 1);
         end if;
      end loop;
      return Image;
   end Name_Prefix;

   --  Return the segment of Image after the first underscore.
   function Name_Remainder (Image : String) return String is
   begin
      for Index in Image'Range loop
         if Image (Index) = '_' then
            return Image (Index + 1 .. Image'Last);
         end if;
      end loop;
      return "";
   end Name_Remainder;

   ------------
   -- Domain --
   ------------

   function Domain (Code : Error_Code) return Error_Domain is
      Prefix : constant String := Name_Prefix (Error_Code'Image (Code));
   begin
      if Code = No_Error then
         return Domain_None;
      elsif Prefix = "CLI" then
         return Domain_CLI;
      elsif Prefix = "IO" then
         return Domain_IO;
      elsif Prefix = "GGUF" then
         return Domain_GGUF;
      elsif Prefix = "TOKENIZER" then
         return Domain_Tokenizer;
      elsif Prefix = "TEMPLATE" then
         return Domain_Template;
      elsif Prefix = "ARCH" then
         return Domain_Architecture;
      elsif Prefix = "TENSOR" then
         return Domain_Tensor;
      elsif Prefix = "BACKEND" then
         return Domain_Backend;
      elsif Prefix = "MEMORY" then
         return Domain_Memory;
      elsif Prefix = "LIFECYCLE" then
         return Domain_Lifecycle;
      elsif Prefix = "GENERATION" then
         return Domain_Generation;
      elsif Prefix = "SAMPLING" then
         return Domain_Sampling;
      elsif Prefix = "CONVERSATION" then
         return Domain_Conversation;
      elsif Prefix = "GRAMMAR" then
         return Domain_Grammar;
      elsif Prefix = "TOOLS" then
         return Domain_Tools;
      else
         return Domain_Internal;
      end if;
   end Domain;

   ------------------
   -- Domain_Token --
   ------------------

   function Domain_Token (Item : Error_Domain) return String is
   begin
      case Item is
         when Domain_None         => return "";
         when Domain_CLI          => return "CLI";
         when Domain_IO           => return "IO";
         when Domain_GGUF         => return "GGUF";
         when Domain_Tokenizer    => return "TOK";
         when Domain_Template     => return "TMPL";
         when Domain_Architecture => return "ARCH";
         when Domain_Tensor       => return "TENSOR";
         when Domain_Backend      => return "BACKEND";
         when Domain_Memory       => return "MEM";
         when Domain_Lifecycle    => return "LIFE";
         when Domain_Generation   => return "GEN";
         when Domain_Sampling     => return "SAMPLE";
         when Domain_Conversation => return "CONV";
         when Domain_Grammar      => return "GRAM";
         when Domain_Tools        => return "TOOLS";
         when Domain_Internal     => return "INTERNAL";
      end case;
   end Domain_Token;

   --  Catalog segment for a domain. Kept separate from Domain_Token because
   --  message keys spell the domain out while diagnostic codes abbreviate it.
   function Key_Segment (Item : Error_Domain) return String is
   begin
      case Item is
         when Domain_None         => return "none";
         when Domain_CLI          => return "cli";
         when Domain_IO           => return "io";
         when Domain_GGUF         => return "gguf";
         when Domain_Tokenizer    => return "tokenizer";
         when Domain_Template     => return "template";
         when Domain_Architecture => return "architecture";
         when Domain_Tensor       => return "tensor";
         when Domain_Backend      => return "backend";
         when Domain_Memory       => return "memory";
         when Domain_Lifecycle    => return "lifecycle";
         when Domain_Generation   => return "generation";
         when Domain_Sampling     => return "sampling";
         when Domain_Conversation => return "conversation";
         when Domain_Grammar      => return "grammar";
         when Domain_Tools        => return "tools";
         when Domain_Internal     => return "internal";
      end case;
   end Key_Segment;

   -------------
   -- Ordinal --
   -------------

   function Ordinal (Code : Error_Code) return Natural is
      Target : constant Error_Domain := Domain (Code);
      Count  : Natural := 0;
   begin
      if Code = No_Error then
         return 0;
      end if;

      for Candidate in Error_Code loop
         if Candidate /= No_Error and then Domain (Candidate) = Target then
            Count := Count + 1;
            if Candidate = Code then
               return Count;
            end if;
         end if;
      end loop;

      return 0;
   end Ordinal;

   ---------------------
   -- Diagnostic_Code --
   ---------------------

   function Diagnostic_Code (Code : Error_Code) return String is
      Number : constant Natural := Ordinal (Code);
      Text   : String (1 .. 4) := "0000";
      Rest   : Natural := Number;
   begin
      if Code = No_Error then
         return "";
      end if;

      for Index in reverse Text'Range loop
         Text (Index) :=
           Character'Val (Character'Pos ('0') + (Rest mod 10));
         Rest := Rest / 10;
      end loop;

      return "MR-" & Domain_Token (Domain (Code)) & "-" & Text;
   end Diagnostic_Code;

   -----------------
   -- Message_Key --
   -----------------

   function Message_Key (Code : Error_Code) return String is
   begin
      if Code = No_Error then
         return "";
      end if;

      return "error." & Key_Segment (Domain (Code)) & "."
        & T.To_Lower (Name_Remainder (Error_Code'Image (Code)));
   end Message_Key;

   ----------------------
   -- Default_Severity --
   ----------------------

   function Default_Severity (Code : Error_Code) return Severity_Level is
   begin
      case Domain (Code) is
         when Domain_None     => return Severity_Information;
         when Domain_Internal => return Severity_Internal;
         when others          => return Severity_Error;
      end case;
   end Default_Severity;

   --------------
   -- Recovery --
   --------------

   function Recovery (Code : Error_Code) return Recovery_Class is
   begin
      case Code is
         when No_Error =>
            return Recovery_None;

         when GGUF_Unsupported_Version
            | GGUF_Unsupported_Tensor_Type
            | Tokenizer_Unsupported_Model
            | Tokenizer_Missing_Byte_Fallback
            | Template_Unsupported_Construct
            | Template_Unsupported_Role
            | Arch_Unsupported
            | Arch_Unsupported_Rope_Scaling
            | Arch_Unsupported_Feature
            | Arch_No_Output_Head
            | Arch_Text_Not_Whole
            | Tensor_Format_Unsupported
            | Backend_Unsupported_Format
            | Backend_Capability_Missing
            | Conversation_System_Unsupported
            | Tools_Not_In_Template
            | Internal_Not_Implemented =>
            return Recovery_Unsupported;

         when Memory_Limit_Exceeded
            | Memory_Allocation_Failed
            | Memory_Plan_Overflow
            | Lifecycle_Mapping_Required
            | Backend_Queue_Full
            | Generation_Context_Exhausted
            | Tokenizer_Input_Too_Long
            | Conversation_Too_Long
            | Template_Output_Too_Large
            | Template_Variables_Too_Large
            | Tools_Too_Many
            | Tools_Too_Large
            | IO_File_Too_Large =>
            return Recovery_Resource_Limited;

         when Generation_Cancelled | Generation_Output_Closed =>
            return Recovery_None;

         when others =>
            case Domain (Code) is
               when Domain_CLI | Domain_Conversation =>
                  return Recovery_User_Correctable;
               when Domain_IO =>
                  return Recovery_User_Correctable;
               when Domain_Internal | Domain_Lifecycle =>
                  return Recovery_Terminal;
               when others =>
                  return Recovery_None;
            end case;
      end case;
   end Recovery;

   ----------
   -- Make --
   ----------

   function Make
     (Code     : Error_Code;
      Severity : Severity_Level := Severity_Error) return Error_Info
   is
      Result : Error_Info;
   begin
      Result.Code := Code;
      Result.Severity :=
        (if Code = No_Error then Severity_Information
         elsif Default_Severity (Code) = Severity_Internal then Severity_Internal
         else Severity);
      return Result;
   end Make;

   --  Append a parameter when there is room. A full list is silently kept as
   --  is: reporting a failure must never fail.
   procedure Append (Item : in out Error_Info; Value : Parameter) is
   begin
      if Item.Parameter_Total < Max_Parameters then
         Item.Parameter_Total := Item.Parameter_Total + 1;
         Item.Parameters (Item.Parameter_Total) := Value;
      end if;
   end Append;

   --------------
   -- Add_Text --
   --------------

   procedure Add_Text
     (Item  : in out Error_Info;
      Name  : String;
      Value : String;
      Kind  : Parameter_Kind := Param_Text)
   is
      Entry_Value : Parameter;
   begin
      Entry_Value.Name := T.To_Bounded (Name);
      Entry_Value.Kind := Kind;
      Entry_Value.Text_Value := T.To_Bounded (Value);
      Append (Item, Entry_Value);
   end Add_Text;

   -----------------
   -- Add_Integer --
   -----------------

   procedure Add_Integer
     (Item  : in out Error_Info;
      Name  : String;
      Value : Long_Long_Integer;
      Kind  : Parameter_Kind := Param_Integer)
   is
      Entry_Value : Parameter;
   begin
      Entry_Value.Name := T.To_Bounded (Name);
      Entry_Value.Kind := Kind;
      Entry_Value.Int_Value := Value;
      Entry_Value.Text_Value := T.To_Bounded (T.Image (Value));
      Append (Item, Entry_Value);
   end Add_Integer;

   --------------
   -- Add_Real --
   --------------

   procedure Add_Real
     (Item  : in out Error_Info;
      Name  : String;
      Value : Long_Float)
   is
      Entry_Value : Parameter;
   begin
      Entry_Value.Name := T.To_Bounded (Name);
      Entry_Value.Kind := Param_Real;
      Entry_Value.Real_Value := Value;
      Entry_Value.Text_Value := T.To_Bounded (T.Image (Value, 4));
      Append (Item, Entry_Value);
   end Add_Real;

   -----------------
   -- Add_Boolean --
   -----------------

   procedure Add_Boolean
     (Item  : in out Error_Info;
      Name  : String;
      Value : Boolean)
   is
      Entry_Value : Parameter;
   begin
      Entry_Value.Name := T.To_Bounded (Name);
      Entry_Value.Kind := Param_Boolean;
      Entry_Value.Bool_Value := Value;
      Entry_Value.Text_Value :=
        T.To_Bounded (if Value then "true" else "false");
      Append (Item, Entry_Value);
   end Add_Boolean;

   ------------------
   -- Set_Location --
   ------------------

   procedure Set_Location
     (Item   : in out Error_Info;
      Offset : Interfaces.Unsigned_64) is
   begin
      Item.Has_Location := True;
      Item.Location := Offset;
   end Set_Location;

   ---------------
   -- Set_Cause --
   ---------------

   procedure Set_Cause
     (Item  : in out Error_Info;
      Cause : Error_Code) is
   begin
      Item.Cause := Cause;
   end Set_Cause;

   ---------------
   -- Add_Frame --
   ---------------

   procedure Add_Frame
     (Item  : in out Error_Info;
      Frame : String) is
   begin
      if Item.Frame_Total < Max_Frames then
         Item.Frame_Total := Item.Frame_Total + 1;
         Item.Frames (Item.Frame_Total) := T.To_Bounded (Frame);
      end if;
   end Add_Frame;

   --------------------
   -- Find_Parameter --
   --------------------

   procedure Find_Parameter
     (Item   : Error_Info;
      Name   : String;
      Found  : out Boolean;
      Result : out Parameter) is
   begin
      for Index in 1 .. Item.Parameter_Total loop
         if T.To_String (Item.Parameters (Index).Name) = Name then
            Found := True;
            Result := Item.Parameters (Index);
            return;
         end if;
      end loop;

      Found := False;
      Result := (others => <>);
   end Find_Parameter;

   -----------------
   -- Exit_Status --
   -----------------

   --------------------
   -- Recovery_Hint --
   --------------------

   function Recovery_Hint (Code : Error_Code) return String is
   begin
      case Recovery (Code) is
         when Recovery_None | Recovery_Terminal =>
            return "";

         when Recovery_User_Correctable =>
            return (if Domain (Code) = Domain_CLI
                    then "diagnostic.hint.usage"
                    else "");

         when Recovery_Resource_Limited =>
            return "diagnostic.hint.resource";

         when Recovery_Unsupported =>
            return "diagnostic.hint.unsupported";
      end case;
   end Recovery_Hint;

   function Exit_Status (Item : Error_Info) return Natural is
   begin
      if Item.Code = No_Error or else Item.Code = Generation_Output_Closed then
         return Exit_Success;
      elsif Item.Code = Generation_Cancelled then
         return Exit_Cancelled;
      elsif Recovery (Item.Code) = Recovery_Unsupported then
         return Exit_Unsupported;
      end if;

      case Domain (Item.Code) is
         when Domain_None =>
            return Exit_Success;

         --  A grammar comes from the command line, as a conversation's
         --  shape does: a grammar that will not compile is something the
         --  caller wrote, not something the model did.
         --  Tools come from the command line too, and a call this cannot
         --  read is the one exception: that is what the model wrote, not
         --  what the caller typed.
         when Domain_CLI | Domain_Conversation | Domain_Grammar =>
            return Exit_Usage;

         when Domain_Tools =>
            return
              (if Item.Code = Tools_Call_Malformed
               then Exit_Model_Format
               else Exit_Usage);

         when Domain_IO =>
            return Exit_Input_Output;

         when Domain_GGUF
            | Domain_Tokenizer
            | Domain_Architecture
            | Domain_Tensor =>
            return Exit_Model_Format;

         when Domain_Memory =>
            return Exit_Resource;

         when Domain_Backend =>
            --  A backend that refuses a format or an operation is a fault in
            --  this program. A backend nobody has is a name the caller
            --  typed, and exits as the usage error it is.
            return
              (if Item.Code = Backend_Unknown
               then Exit_Usage
               else Exit_Internal);

         when Domain_Template =>
            --  Same division: a template that will not compile is the
            --  model's, and a chat format nobody carries is a name the
            --  caller typed.
            return
              (if Item.Code = Template_Unknown_Format
               then Exit_Usage
               else Exit_Model_Format);

         when Domain_Lifecycle =>
            return
              (if Item.Code = Lifecycle_Mapping_Required
               then Exit_Resource
               else Exit_Internal);

         when Domain_Generation =>
            return
              (if Item.Code in Generation_Prompt_Too_Long
                             | Generation_Invalid_Request
                             | Generation_Empty_Prompt
                             | Generation_Batch_Too_Large
               then Exit_Usage
               elsif Item.Code = Generation_Context_Exhausted
               then Exit_Resource
               else Exit_Internal);

         when Domain_Sampling =>
            return
              (if Item.Code = Sampling_Invalid_Configuration
               then Exit_Usage
               else Exit_Internal);

         when Domain_Internal =>
            return Exit_Internal;
      end case;
   end Exit_Status;

end Model_Runner.Errors;
