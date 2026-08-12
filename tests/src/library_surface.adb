package body Library_Surface is

   type Text_Access is access constant String;

   --  The codec's other half.
   Held : constant array (1 .. 30) of Text_Access :=
     [new String'("Get_F16"),
      new String'("Put_U64"),
      new String'("Tensor_Code"),
      new String'("Value_Code"),
      new String'("Wipe"),

      --  Second opinions.
      new String'("All_Finite"),
      new String'("Row_Dot"),

      --  State a library caller needs.
      --
      --  Hidden_State is here because the embedding command stopped needing
      --  it: it evaluates in batches now and asks for every position's
      --  state at once, which only that path can give. A caller evaluating
      --  a token at a time has no other way to read what the model made of
      --  what it read, so the operation stays.
      new String'("Hidden_State"),
      new String'("Adds_End"),
      new String'("Has_Template"),
      new String'("Is_Closed"),
      new String'("Is_Loaded"),
      new String'("Is_Normal"),
      new String'("Seed_Used"),
      new String'("String_Count"),
      new String'("Unknown_Token"),

      --  Building a diagnostic.
      new String'("Add_Boolean"),
      new String'("Find_Parameter"),
      new String'("Set_Cause"),

      --  Planning a session.
      new String'("Finalize_Plan"),
      new String'("Record_Mapping"),

      --  Helpers.
      new String'("Ends_With"),
      new String'("Equal_Ignore_Case"),
      new String'("Failure_Name"),
      new String'("Has_Controls"),
      new String'("Host_Name"),
      new String'("In_Range"),
      new String'("Is_NaN"),
      new String'("To_Natural"),
      new String'("Wide_Bits")];

   ---------------
   -- Is_Listed --
   ---------------

   function Is_Listed (Name : String) return Boolean is
   begin
      for Item_Value of Held loop
         if Item_Value.all = Name then
            return True;
         end if;
      end loop;
      return False;
   end Is_Listed;

   -----------
   -- Count --
   -----------

   function Count return Natural is (Held'Length);

   ----------
   -- Item --
   ----------

   function Item (Index : Positive) return String is (Held (Index).all);

end Library_Surface;
