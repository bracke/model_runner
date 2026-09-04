package body Library_Surface is

   type Text_Access is access constant String;

   --  The codec's other half.
   Held : constant array (1 .. 31) of Text_Access :=
     [new String'("Get_F16"),
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

      --  Helpers.
      new String'("Ends_With"),
      new String'("Equal_Ignore_Case"),
      new String'("Failure_Name"),
      new String'("Has_Controls"),
      new String'("Host_Name"),
      new String'("In_Range"),
      new String'("Is_NaN"),
      new String'("To_Natural"),
      new String'("Wide_Bits"),

      --  Serving several callers from one model. The command serves one
      --  caller and has no reason to ask for any of this; a program serving
      --  several has every reason, and the figures that say what it is worth
      --  are in docs/serving-several-sequences.md -- a second caller is
      --  nearly free where a second run is not.
      --
      --  Admit is how a caller joins, Retire is how one leaves before it has
      --  finished, and Gathered is how many were in the last round -- which
      --  is what tells a scheduler its queue is emptying. `tests speed
      --  --serve N` is what exercises them here.
      new String'("Admit"),
      new String'("Retire"),
      new String'("Gathered"),

      --  And where a server's time went. Where a run's own phases --
      --  Llama.Time_Spent -- were on this list until the server started
      --  summing them, which is what took that one off it: a library
      --  operation the library itself calls is not surface nobody reaches.
      --  Named apart from it because the two answer about different things
      --  and a list of names cannot tell them apart.
      new String'("Time_Taken")];

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
