separate (Model_Runner.Platform.Device.Products)
procedure Open
  (Item       : in out Engine;
   On         : Context;
   Ready      : out Boolean;
   Budget     : Interfaces.Unsigned_64 := 0;
   Share_Host : Boolean := False;
   Slice      : Duration := 0.020;
   Patience   : Duration := 60.0)
is
   Made    : aliased Address := Null_Handle;
   Granted : Boolean;
begin
   Close (Item);
   Ready := False;

   if not Is_Open (On) then
      return;
   end if;

   Life.Claim (Granted);
   if not Granted then
      return;
   end if;
   Item.Owns_Slot := True;

   Item.Instance := On.Instance;
   Life.Select_Instance (Item.Instance);

   --  Through the accessor rather than the field. This package can see
   --  the private part, being a child, and reading it directly would make
   --  a public operation that answers exactly this question something
   --  nothing calls.
   Item.Heap := Memory_Bytes (On);
   Item.Budget_Heaps := Budget_Bytes (On);
   Item.Imports := Takes_Host_Memory (On);
   Item.Import_To := Host_Alignment (On);
   Item.Storage := Storage_Limit (On);
   Item.Aligned := Storage_Alignment (On);
   Item.Tick := Timestamp_Period (On);
   Item.Plain := Plain_Memory_Kinds (On);
   Item.Share := Share_Host;
   --  The budget, by heap. Unasked, it is what it always was: the share
   --  of the largest heap, and the second heap holds nothing. A budget
   --  named by the caller fills the first tier to that share and puts
   --  the rest in the second, so a test that names a few kilobytes
   --  still evicts, and a caller who names more than the first heap's
   --  share gets the second heap rather than the driver's refusal.
   --
   --  The second heap is taken by default now, as far as the host can
   --  afford it. It was not, for a reason that has since gone: on the
   --  integrated part this was built on, the two heaps together hold
   --  11.8 GB of an 11.26 GB mixture, and holding it cost about
   --  twenty-five gigabytes of a thirty-gigabyte host -- the buffers
   --  counted as shmem and pool pages both, two bytes of system memory
   --  for every byte on the device -- and the desktop was killed for want
   --  of memory, twice. Measured again, the same mixture holds 11.15 GB
   --  on the device for 10.95 GB of the host's memory, no shmem at all:
   --  one to one. And leaving it out cost that mixture every layer: a
   --  mixture whose stacks do not all fit the budget does not go to the
   --  device whole, so it went piecemeal, its context on the host, at
   --  18.7 tokens a second where the second heap gives 33.4 -- llama.cpp
   --  reads 32.5. So the second heap's share is in the default budget,
   --  but only as much of it as leaves Host_Reserve of the host's memory
   --  available when the device is opened; where the host will not say
   --  what is available, it is left out as before. A budget is a bound,
   --  not an allocation: a model that fits the first heap takes what it
   --  took.
   Item.Second := Second_Kind (On);
   Item.Second_Heap :=
     (if Item.Second >= 0 then Second_Memory_Bytes (On) else 0);

   declare
      First_Share  : constant Interfaces.Unsigned_64 :=
        Item.Heap / Budget_Whole * Budget_Share;
      Second_Share : constant Interfaces.Unsigned_64 :=
        (if Item.Second >= 0
         then Second_Memory_Bytes (On) / Budget_Whole * Budget_Share
         else 0);
   begin
      if Budget = 0 then
         declare
            Available : constant Interfaces.Unsigned_64 :=
              Model_Runner.Platform.Available_Memory;

            Room : constant Interfaces.Unsigned_64 :=
              (if Available > Host_Reserve + First_Share
               then Available - Host_Reserve - First_Share
               else 0);
         begin
            Item.Tier_Limit :=
              [First_Share, Interfaces.Unsigned_64'Min (Second_Share, Room)];
         end;
      elsif Item.Second < 0 then
         Item.Tier_Limit := [Budget, 0];
      else
         --  The second heap takes what the first's share does not
         --  cover, up to its own share; past both, the first is asked
         --  for the rest and the driver's answer is the bound, as it
         --  always was for a budget past the heap.
         Item.Tier_Limit (1) :=
           Interfaces.Unsigned_64'Min (Budget, First_Share);
         Item.Tier_Limit (2) :=
           Interfaces.Unsigned_64'Min
             (Budget - Item.Tier_Limit (1), Second_Share);
         Item.Tier_Limit (1) := Budget - Item.Tier_Limit (2);
      end if;

      Item.Budget := Item.Tier_Limit (1) + Item.Tier_Limit (2);
   end;

   Item.Tier_Kept := [others => 0];
   Item.Tier_Spare := [others => 0];

   Item.Logical := On.Logical;
   Item.Queue := On.Queue;
   Item.Family := On.Family;
   Item.Upload := On.Upload;
   Item.Download := On.Download;

   --  The shader.
   declare
      Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
      Words  : aliased constant Model_Runner.Shaders.Word_Array :=
        Model_Runner.Shaders.Row_Product;
      Request : aliased Shader_Create_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      Request.Size := Interfaces.C.size_t (Words'Length * 4);
      Request.Code := Words'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Shader := Made;
   end;

   --  The same kernel's LOW_BITS compilation, which decodes the twelve
   --  low-bit formats and nothing else. It asks nothing of the device the
   --  first does not, so a device that took the first takes this.
   declare
      Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
      Words  : aliased constant Model_Runner.Shaders.Word_Array :=
        Model_Runner.Shaders.Low_Dots.Row_Product_Low;
      Request : aliased Shader_Create_Info;
   begin
      Request.Size := Interfaces.C.size_t (Words'Length * 4);
      Request.Code := Words'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Low_Shader := Made;
   end;

   --  Native reference integer products use the existing descriptor layout
   --  and bounded rounded-activation buffer; no extra runtime or weight copy.
   if Has_Integer_Dot (On) then
      declare
         Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Words : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super_Reference;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;
            if Create (Item.Logical, Request'Address, Null_Handle, Made'Access) = 0 then
               Item.Reference_Shader := Made;
            end if;
         end if;
      end;
   end if;

   --  The super-block row product's module, made only where the device
   --  offers a subgroup to reduce across and the setting of its width to
   --  thirty-two. A refusal leaves Wave_Shader null and the engine binds
   --  the eight-lane kernel.
   if Has_Subgroup_Arithmetic (On) and then Has_Sized_Subgroups (On) then
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Wave_Shader := Made;
            end if;
         end if;
      end;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super5;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Wave_Shader5 := Made;
            end if;
         end if;
      end;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super6;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Wave_Shader6 := Made;
            end if;

            --  And the two compilations over a few positions at once,
            --  and Q4_K's gate and up at once for one and for a few.
            declare
               Glu  : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Super.Row_Product_Super_Glu;
               Glus : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Super.Row_Product_Super_Glu_Multi;
               Four : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Super.Row_Product_Super_Multi;
               Six  : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Super.Row_Product_Super6_Multi;
               Five : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Super.Row_Product_Super5_Multi;
            begin
               Request.Size := Interfaces.C.size_t (Four'Length * 4);
               Request.Code := Four'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Many_Shader4 := Made;
               end if;

               Request.Size := Interfaces.C.size_t (Five'Length * 4);
               Request.Code := Five'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Many_Shader5 := Made;
               end if;

               Request.Size := Interfaces.C.size_t (Six'Length * 4);
               Request.Code := Six'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Many_Shader6 := Made;
               end if;

               Request.Size := Interfaces.C.size_t (Glu'Length * 4);
               Request.Code := Glu'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Glu_Shader := Made;
               end if;

               Request.Size := Interfaces.C.size_t (Glus'Length * 4);
               Request.Code := Glus'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Glu_Many_Shader := Made;
               end if;
            end;

            --  And the integer walks and their rounding, where the
            --  device was opened with the integer dot: see Round_Walks.
            if Has_Integer_Dot (On) then
               declare
                  Dots  : aliased constant Model_Runner.Shaders.Word_Array
                    := Model_Runner.Shaders.Super
                         .Row_Product_Super_Multi_Dots;
                  Glus  : aliased constant Model_Runner.Shaders.Word_Array
                    := Model_Runner.Shaders.Super
                         .Row_Product_Super_Glu_Multi_Dots;
                  Round : aliased constant Model_Runner.Shaders.Word_Array
                    := Model_Runner.Shaders.Round_Vectors;
                  Five  : aliased constant Model_Runner.Shaders.Word_Array
                    := Model_Runner.Shaders.Super
                         .Row_Product_Super5_Multi_Dots;
                  Six   : aliased constant Model_Runner.Shaders.Word_Array
                    := Model_Runner.Shaders.Super
                         .Row_Product_Super6_Multi_Dots;
               begin
                  Request.Size := Interfaces.C.size_t (Five'Length * 4);
                  Request.Code := Five'Address;
                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Dots_Shader5 := Made;
                  end if;

                  Request.Size := Interfaces.C.size_t (Six'Length * 4);
                  Request.Code := Six'Address;
                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Dots_Shader6 := Made;
                  end if;

                  Request.Size := Interfaces.C.size_t (Dots'Length * 4);
                  Request.Code := Dots'Address;
                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Dots_Shader := Made;
                  end if;

                  Request.Size := Interfaces.C.size_t (Glus'Length * 4);
                  Request.Code := Glus'Address;
                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Glu_Dots_Shader := Made;
                  end if;

                  Request.Size := Interfaces.C.size_t (Round'Length * 4);
                  Request.Code := Round'Address;
                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Round_Shader := Made;
                  end if;
               end;
            end if;
         end if;
      end;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super6_Long;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Long_Shader6 := Made;
            end if;
         end if;
      end;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super6_Mid;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Mid_Shader6 := Made;
            end if;
         end if;
      end;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super_Long;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Long_Shader := Made;
            end if;
         end if;
      end;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Super.Row_Product_Super5_Long;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Long_Shader5 := Made;
            end if;
         end if;
      end;

      for Packing in Low_Packing loop
         declare
            Create : constant Create_Call :=
              To_Create (Point ("vkCreateShaderModule"));
            Words  : aliased constant Model_Runner.Shaders.Word_Array :=
              (case Packing is
                 when Packed_IQ3_S =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq3_S,
                 when Packed_IQ2_XXS =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq2_Xxs,
                 when Packed_IQ2_XS =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq2_Xs,
                 when Packed_IQ2_S =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq2_S,
                 when Packed_IQ3_XXS =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq3_Xxs,
                 when Packed_IQ1_S =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq1_S,
                 when Packed_IQ1_M =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Iq1_M,
                 when Packed_TQ1_0 =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Tq1_0,
                 when Packed_TQ2_0 =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Tq2_0,
                 when Packed_Q1_0 =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Q1_0,
                 when Packed_Q2_0 =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Q2_0,
                 when Packed_NVFP4 =>
                   Model_Runner.Shaders.Low.Row_Product_Wave_Nvfp4);
            Request : aliased Shader_Create_Info;
         begin
            if Create /= null then
               Request.Size := Interfaces.C.size_t (Words'Length * 4);
               Request.Code := Words'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Low_Wave_Shaders (Packing) := Made;
               end if;
            end if;
         end;
      end loop;

      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Words  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Words'Length * 4);
            Request.Code := Words'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Q8_Wave_Shader := Made;
            end if;

            --  And its four-row compilation, for short rows.
            declare
               Short : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_Short;
            begin
               Request.Size := Interfaces.C.size_t (Short'Length * 4);
               Request.Code := Short'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Q8_Short_Shader := Made;
               end if;
               Request.Size := Interfaces.C.size_t (Words'Length * 4);
               Request.Code := Words'Address;
            end;

            --  Its gate-and-up compilations, long rows and short.
            declare
               Glu   : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_Glu;
               Glu_S : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_Short_Glu;
            begin
               Request.Size := Interfaces.C.size_t (Glu'Length * 4);
               Request.Code := Glu'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Q8_Glu_Shader := Made;
               end if;
               Request.Size := Interfaces.C.size_t (Glu_S'Length * 4);
               Request.Code := Glu_S'Address;
               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Q8_Glu_Short_Shader := Made;
               end if;
            end;

            --  And its compilations over several vectors, plain and
            --  gate-and-up.
            for Count in Multi_Count loop
               declare
                  Pair : aliased constant Model_Runner.Shaders.Word_Array :=
                    (case Count is
                       when 2 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V2_Glu,
                       when 3 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V3_Glu,
                       when 4 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V4_Glu);
               begin
                  Request.Size := Interfaces.C.size_t (Pair'Length * 4);
                  Request.Code := Pair'Address;
                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Q8_Glu_Multi_Shaders (Count) := Made;
                  end if;
               end;
            end loop;

            for Count in Q8_Count loop
               declare
                  More : aliased constant Model_Runner.Shaders.Word_Array :=
                    (case Count is
                       when 2 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V2,
                       when 3 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V3,
                       when 4 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V4,
                       when 5 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V5,
                       when 6 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V6,
                       when 7 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V7,
                       when 8 => Model_Runner.Shaders.Low.Row_Product_Wave_Q8_0_V8);
               begin
                  Request.Size := Interfaces.C.size_t (More'Length * 4);
                  Request.Code := More'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Q8_Multi_Shaders (Count) := Made;
                  end if;
               end;
            end loop;

            --  And both again as integers, where the device has the
            --  integer dot; see Round_Walks.
            if Has_Integer_Dot (On) then
               for Count in Q8_Count loop
                  declare
                     Dots : aliased constant Model_Runner.Shaders.Word_Array :=
                       (case Count is
                          when 2 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V2_Dots,
                          when 3 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V3_Dots,
                          when 4 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V4_Dots,
                          when 5 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V5_Dots,
                          when 6 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V6_Dots,
                          when 7 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V7_Dots,
                          when 8 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V8_Dots);
                  begin
                     Request.Size := Interfaces.C.size_t (Dots'Length * 4);
                     Request.Code := Dots'Address;
                     if Create (Item.Logical, Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Q8_Dots_Shaders (Count) := Made;
                     end if;
                  end;
               end loop;

               for Count in Multi_Count loop
                  declare
                     Glus : aliased constant Model_Runner.Shaders.Word_Array :=
                       (case Count is
                          when 2 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V2_Dots_Glu,
                          when 3 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V3_Dots_Glu,
                          when 4 => Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q8_0_V4_Dots_Glu);
                  begin
                     Request.Size := Interfaces.C.size_t (Glus'Length * 4);
                     Request.Code := Glus'Address;
                     if Create (Item.Logical, Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Item.Q8_Glu_Dots_Shaders (Count) := Made;
                     end if;
                  end;
               end loop;
            end if;
         end if;
      end;

      --  And the two IQ4 formats'.
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));

         procedure Module
           (Words : Model_Runner.Shaders.Word_Array; Into : out Address)
         is
            Request : aliased Shader_Create_Info;
         begin
            Into := Null_Handle;
            if Create /= null then
               Request.Size := Interfaces.C.size_t (Words'Length * 4);
               Request.Code := Words'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Into := Made;
               end if;
            end if;
         end Module;
      begin
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Iq4_Nl,
                 Item.NL_Wave_Shader);
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Mxfp4,
                 Item.MX_Wave_Shader);
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Mxfp4_Glu,
                 Item.MX_Glu_Shader);
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Iq4_Xs,
                 Item.XS_Wave_Shader);
         --  And their walks as integers, where the device has the dot.
         if Has_Integer_Dot (On) then
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq4_Nl_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ4_NL));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq4_Xs_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ4_XS));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Mxfp4_Dots,
                    Item.Dots_Wave_Shaders (Packed_MXFP4));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq3_S_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ3_S));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq2_Xxs_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ2_XXS));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq2_Xs_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ2_XS));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq2_S_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ2_S));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq3_Xxs_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ3_XXS));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq1_S_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ1_S));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Iq1_M_Dots,
                    Item.Dots_Wave_Shaders (Packed_IQ1_M));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q2_K_Dots,
                    Item.Dots_Wave_Shaders (Packed_Q2_K));
            Module (Model_Runner.Shaders.Low_Dots.Row_Product_Wave_Q3_K_Dots,
                    Item.Dots_Wave_Shaders (Packed_Q3_K));
         end if;
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Q2_K,
                 Item.Q2K_Wave_Shader);
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Q3_K,
                 Item.Q3K_Wave_Shader);
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Q4_0,
                 Item.Legacy_Wave_Shaders (Packed_Q4_0));
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Q4_1,
                 Item.Legacy_Wave_Shaders (Packed_Q4_1));
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Q5_0,
                 Item.Legacy_Wave_Shaders (Packed_Q5_0));
         Module (Model_Runner.Shaders.Low.Row_Product_Wave_Q5_1,
                 Item.Legacy_Wave_Shaders (Packed_Q5_1));
         Module (Model_Runner.Shaders.Super.Row_Product_Half_F16,
                 Item.Half_Wave_Shaders (Values_F16));
         Module (Model_Runner.Shaders.Super.Row_Product_Half_Bf16,
                 Item.Half_Wave_Shaders (Values_BF16));
      end;
   end if;

   --  The second kernel's module.
   declare
      Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
      Words  : aliased constant Model_Runner.Shaders.Word_Array :=
        Model_Runner.Shaders.Combine;
      Request : aliased Shader_Create_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      Request.Size := Interfaces.C.size_t (Words'Length * 4);
      Request.Code := Words'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Blender := Made;

      --  And the normalization, from its own source. A device that
      --  refuses it is left doing its normalizing on the host, which is
      --  what every device did before this.
      declare
         Normed : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Norm;
      begin
         Request.Size := Interfaces.C.size_t (Normed'Length * 4);
         Request.Code := Normed'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Normer := Made;
         end if;
      end;

      --  And its rounding compilation, where the walks may round.
      if Has_Integer_Dot (On) then
         declare
            Normed : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Norm_Rounds;
         begin
            Request.Size := Interfaces.C.size_t (Normed'Length * 4);
            Request.Code := Normed'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Round_Normer := Made;
            end if;
         end;
      end if;

      --  And a mixture's routing and its weighted sum, the same story
      --  again: a device that refuses either runs its mixtures a
      --  submission at a time, as every device did before.
      declare
         Routed : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Route;
         Mixed  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Mix;
         Biased : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Bias;
         Picked : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Pick;
         Conved : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Conv;
         Ruled  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Rule;
         Held   : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Rule_Held;
         Single : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Rule_Held_Single;
         Replay : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Rule_Replay;
      begin
         Request.Size := Interfaces.C.size_t (Routed'Length * 4);
         Request.Code := Routed'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Router := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Mixed'Length * 4);
         Request.Code := Mixed'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Mixer := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Biased'Length * 4);
         Request.Code := Biased'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Biaser := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Picked'Length * 4);
         Request.Code := Picked'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Picker := Made;
         end if;

         declare
            Assembled : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Assemble;
         begin
            Request.Size := Interfaces.C.size_t (Assembled'Length * 4);
            Request.Code := Assembled'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Assembler := Made;
            end if;
         end;

         declare
            Small : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Rwkv;
            Wkv   : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Rwkv_Wkv;
         begin
            Request.Size := Interfaces.C.size_t (Small'Length * 4);
            Request.Code := Small'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Rwkver := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Wkv'Length * 4);
            Request.Code := Wkv'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Wkver := Made;
            end if;
         end;

         declare
            Around : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Mamba2;
            Scan   : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Mamba2_Scan;
         begin
            Request.Size := Interfaces.C.size_t (Around'Length * 4);
            Request.Code := Around'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Mambaer := Made;
            end if;

            Request.Size := Interfaces.C.size_t (Scan'Length * 4);
            Request.Code := Scan'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Scanner := Made;
            end if;
         end;

         declare
            One : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Mamba_Scan;
         begin
            Request.Size := Interfaces.C.size_t (One'Length * 4);
            Request.Code := One'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Scanner1 := Made;
            end if;
         end;

         Request.Size := Interfaces.C.size_t (Conved'Length * 4);
         Request.Code := Conved'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Conver := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Ruled'Length * 4);
         Request.Code := Ruled'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Ruler := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Held'Length * 4);
         Request.Code := Held'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Held_Ruler := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Single'Length * 4);
         Request.Code := Single'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Single_Ruler := Made;
         end if;

         Request.Size := Interfaces.C.size_t (Replay'Length * 4);
         Request.Code := Replay'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Replayer := Made;
         end if;
      end;

      --  And the heads step, which stands for three of the others: a
      --  device that refuses it dispatches those three.
      declare
         Readied : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Heads;
      begin
         Request.Size := Interfaces.C.size_t (Readied'Length * 4);
         Request.Code := Readied'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Header := Made;
         end if;
      end;

      --  And the merge of a split attention's slices.
      declare
         Merged : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Merge;
      begin
         Request.Size := Interfaces.C.size_t (Merged'Length * 4);
         Request.Code := Merged'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Merger := Made;
         end if;
      end;

      --  And a batch's routing inverted.
      declare
         Inverted : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Invert;
      begin
         Request.Size := Interfaces.C.size_t (Inverted'Length * 4);
         Request.Code := Inverted'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Inverter := Made;
         end if;
      end;

      --  And the thin product.
      declare
         Thinned : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Thin;
      begin
         Request.Size := Interfaces.C.size_t (Thinned'Length * 4);
         Request.Code := Thinned'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Thinner := Made;
         end if;
      end;

      --  And the gather read down its columns.
      declare
         Folded : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Fold;
      begin
         Request.Size := Interfaces.C.size_t (Folded'Length * 4);
         Request.Code := Folded'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Folder := Made;
         end if;
      end;

      --  And the binary32 tile.
      declare
         Tiled32 : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.F32_Tile;
      begin
         Request.Size := Interfaces.C.size_t (Tiled32'Length * 4);
         Request.Code := Tiled32'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.F32_Tiler := Made;
         end if;
      end;

      --  And the rotation, which is the same story: a device that
      --  refuses it turns on the host, as every device did before.
      declare
         Turned : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Rotate;
      begin
         Request.Size := Interfaces.C.size_t (Turned'Length * 4);
         Request.Code := Turned'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Turner := Made;
         end if;
      end;

      --  And the cache write, the same again.
      declare
         Placed : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Place;
      begin
         Request.Size := Interfaces.C.size_t (Placed'Length * 4);
         Request.Code := Placed'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Placer := Made;
         end if;
      end;

      --  And the cache read back.
      declare
         Fetched : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Place_Fetch;
      begin
         Request.Size := Interfaces.C.size_t (Fetched'Length * 4);
         Request.Code := Fetched'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Fetcher := Made;
         end if;
      end;
   end;

   --  The third kernel's module.
   declare
      Create : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
      Words  : aliased constant Model_Runner.Shaders.Word_Array :=
        Model_Runner.Shaders.Attend.Attention;
      Request : aliased Shader_Create_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      Request.Size := Interfaces.C.size_t (Words'Length * 4);
      Request.Code := Words'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Attender := Made;

      --  And the packed kernel, over a cache of bytes or nibbles and
      --  scales, compiled twice as attention.comp is: with subgroup
      --  operations where the device offers them to a compute shader,
      --  and through shared memory alone everywhere else. Allowed to
      --  fail on its own: a device that refuses it attends a packed
      --  session on the host.
      declare
         Plain  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Attend.Attention_Packed;
         Packed : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Attend.Attention_Packed_Subgroups;
      begin
         Request.Size := Interfaces.C.size_t (Plain'Length * 4);
         Request.Code := Plain'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Packed_Plain := Made;
         end if;

         if Has_Subgroup_Arithmetic (On) then
            Request.Size := Interfaces.C.size_t (Packed'Length * 4);
            Request.Code := Packed'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Packed_Attend := Made;
            end if;
         end if;
      end;

      --  And the kernel that packs a step's rows into such a cache,
      --  which finds a row's largest the same two ways.
      declare
         Plain  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Pack;
         Packer : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Pack_Subgroups;
      begin
         Request.Size := Interfaces.C.size_t (Plain'Length * 4);
         Request.Code := Plain'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Packer_Plain := Made;
         end if;

         if Has_Subgroup_Arithmetic (On) then
            Request.Size := Interfaces.C.size_t (Packer'Length * 4);
            Request.Code := Packer'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Packer := Made;
            end if;
         end if;
      end;

      --  And the one that unpacks a layer of it into the copy for a
      --  batch, which is worth having only where the matrix kernel is
      --  -- whose module is made below, so the pipeline is what is
      --  gated on it.
      declare
         Unpacker : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Unpack;
      begin
         Request.Size := Interfaces.C.size_t (Unpacker'Length * 4);
         Request.Code := Unpacker'Address;

         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) = 0
         then
            Item.Unpacker := Made;
         end if;
      end;

      --  And the same source compiled with SUBGROUPS, where the device
      --  offers them. Allowed to fail on its own: a device that takes
      --  the wide kernel and refuses this one attends as it always did.
      if Has_Subgroup_Arithmetic (On) then
         declare
            Grouped : aliased constant Model_Runner.Shaders.Word_Array :=
              Model_Runner.Shaders.Attend.Attention_Subgroups;
         begin
            Request.Size := Interfaces.C.size_t (Grouped'Length * 4);
            Request.Code := Grouped'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Grouped := Made;
            end if;
         end;

         --  And once more with QUERY_TILE. It needs the subgroup one to
         --  have been made, because a block reduces per query per tile
         --  and that is what the subgroup operations are for.
         if Item.Grouped /= Null_Handle then
            declare
               Blocked : aliased constant
                 Model_Runner.Shaders.Word_Array :=
                   Model_Runner.Shaders.Attend.Attention_Tiled;
            begin
               Request.Size :=
                 Interfaces.C.size_t (Blocked'Length * 4);
               Request.Code := Blocked'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Query_Tile := Made;
               end if;
            end;

            --  And once more with HALVED, which reads the cache in half
            --  precision. It is the subgroup one again -- a round binds
            --  it -- so it needs the same device offer, and it is
            --  allowed to fail on its own: a device that refuses it
            --  reads the cache proper as it always did.
            declare
               Halved : aliased constant
                 Model_Runner.Shaders.Word_Array :=
                   Model_Runner.Shaders.Attend.Attention_Halved;
            begin
               Request.Size :=
                 Interfaces.C.size_t (Halved'Length * 4);
               Request.Code := Halved'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Halver_Attend := Made;
               end if;
            end;

            --  And a fifth with GROUPED beside it, a bundle of heads to
            --  a workgroup. Made only where the fourth was: it is the
            --  same kernel with the same cache and the fourth is what a
            --  round falls back to.
            if Item.Halver_Attend /= Null_Handle then
               declare
                  Bundled : aliased constant
                    Model_Runner.Shaders.Word_Array :=
                      Model_Runner.Shaders.Attend.Attention_Bundled;
               begin
                  Request.Size :=
                    Interfaces.C.size_t (Bundled'Length * 4);
                  Request.Code := Bundled'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Bundled_Attend := Made;
                  end if;
               end;
            end if;

            --  And a token's flash attention over the copy.
            declare
               Token : aliased constant
                 Model_Runner.Shaders.Word_Array :=
                   Model_Runner.Shaders.Attend.Attention_Token;
            begin
               Request.Size := Interfaces.C.size_t (Token'Length * 4);
               Request.Code := Token'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Token_Attend := Made;
               end if;
            end;

            --  And the same over a packed cache.
            declare
               Token : aliased constant
                 Model_Runner.Shaders.Word_Array :=
                   Model_Runner.Shaders.Attend.Attention_Token_Packed;
            begin
               Request.Size := Interfaces.C.size_t (Token'Length * 4);
               Request.Code := Token'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Packed_Token_Attend := Made;
               end if;
            end;

            --  And a sixth, GROUPED over the cache proper, beside the
            --  subgroup one it falls back to.
            declare
               Bundled : aliased constant
                 Model_Runner.Shaders.Word_Array :=
                   Model_Runner.Shaders.Attend.Attention_Bundle_Exact;
            begin
               Request.Size := Interfaces.C.size_t (Bundled'Length * 4);
               Request.Code := Bundled'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Exact_Bundled_Attend := Made;
               end if;
            end;

            --  And a seventh, GROUPED over the cache proper a word at
            --  a time, for the pair.
            declare
               Paired : aliased constant
                 Model_Runner.Shaders.Word_Array :=
                   Model_Runner.Shaders.Attend.Attention_Grouped_Exact;
            begin
               Request.Size := Interfaces.C.size_t (Paired'Length * 4);
               Request.Code := Paired'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Exact_Paired_Attend := Made;
               end if;
            end;
         end if;
      end if;
   end;

   --  And the two that only some devices get: the matrix product and
   --  the half-precision copy its operand needs. Made together, because
   --  neither is any use without the other, and made at all only where
   --  the device said it offers the instruction at the shape the shader
   --  is written for.
   Item.Matrices := Has_Matrix_Instruction (On);

   --  And attention through the same instruction, which belongs here
   --  rather than beside the other attending modules: it is wanted only
   --  where the instruction is, and whether it is has just been decided.
   --  Allowed to fail on its own -- a device that takes the matrix
   --  product and refuses this one attends as it did before.
   if Item.Matrices then
      declare
         Create  : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Attends : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Attend.Attention_Matrix;
         Request : aliased Shader_Create_Info;
      begin
         if Create /= null then
            Request.Size := Interfaces.C.size_t (Attends'Length * 4);
            Request.Code := Attends'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) = 0
            then
               Item.Attend_Matrix := Made;
            end if;

            --  And the same words staging a head twice as wide.
            declare
               Wide : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Matrix_Wide;
            begin
               Request.Size := Interfaces.C.size_t (Wide'Length * 4);
               Request.Code := Wide'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Matrix_Wide := Made;
               end if;
            end;

            --  And one between, eighty wide.
            declare
               Mid : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Matrix_Mid;
            begin
               Request.Size := Interfaces.C.size_t (Mid'Length * 4);
               Request.Code := Mid'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Matrix_Mid := Made;
               end if;
            end;

            --  And twice as wide again.
            declare
               Wider : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Matrix_Wider;
            begin
               Request.Size := Interfaces.C.size_t (Wider'Length * 4);
               Request.Code := Wider'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Matrix_Wider := Made;
               end if;
            end;

            --  And the short span's split kernel for heads of 128.
            declare
               Split : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Split;
            begin
               Request.Size := Interfaces.C.size_t (Split'Length * 4);
               Request.Code := Split'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Split := Made;
               end if;
            end;

            --  And for heads of sixty-four, of eighty and of 256.
            declare
               Split : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Split_Narrow;
            begin
               Request.Size := Interfaces.C.size_t (Split'Length * 4);
               Request.Code := Split'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Split_Narrow := Made;
               end if;
            end;

            declare
               Split : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Split_Mid;
            begin
               Request.Size := Interfaces.C.size_t (Split'Length * 4);
               Request.Code := Split'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Split_Mid := Made;
               end if;
            end;

            declare
               Split : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Split_Wider;
            begin
               Request.Size := Interfaces.C.size_t (Split'Length * 4);
               Request.Code := Split'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Split_Wider := Made;
               end if;
            end;

            --  And the absorbed latent's.
            declare
               Latent : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Latent;
            begin
               Request.Size := Interfaces.C.size_t (Latent'Length * 4);
               Request.Code := Latent'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Latent := Made;
               end if;
            end;

            --  And its batch's, tiles of 128 (WIDE_TILE).
            declare
               Batch : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Latent_Batch;
            begin
               Request.Size := Interfaces.C.size_t (Batch'Length * 4);
               Request.Code := Batch'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Latent_Batch := Made;
               end if;
            end;

            --  And a short cache's, the key split between the subgroups
            --  (SPLIT_DEPTH).
            declare
               Split : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Latent_Split;
            begin
               Request.Size := Interfaces.C.size_t (Split'Length * 4);
               Request.Code := Split'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Latent_Split := Made;
               end if;
            end;

            --  And a packed group's, two tiles a workgroup (PACK_PAIR).
            declare
               Packed : aliased constant Model_Runner.Shaders.Word_Array :=
                 Model_Runner.Shaders.Attend.Attention_Latent_Packed;
            begin
               Request.Size := Interfaces.C.size_t (Packed'Length * 4);
               Request.Code := Packed'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Attend_Latent_Packed := Made;
               end if;
            end;
         end if;
      end;
   end if;

   if Item.Matrices then
      declare
         Create : constant Create_Call :=
           To_Create (Point ("vkCreateShaderModule"));
         Tiles  : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Matrix_Product;
         Copy   : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Half_Batch;
         More   : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Matrix_Extra;
         Thin   : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Matrix_Narrow;
         Thin_More : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Matrix_Narrow_Extra;
         Listed : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Mid_Tiles.Matrix_Listed;
         Listed_More : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Mid_Tiles.Matrix_Listed_Extra;
         Listed_Five : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Mid_Tiles.Matrix_Listed_Five;
         Listed_Wide : aliased constant Model_Runner.Shaders.Word_Array :=
           Model_Runner.Shaders.Mid_Tiles.Matrix_Listed_Wide;
         Listed_Wide_More :
           aliased constant Model_Runner.Shaders.Word_Array :=
             Model_Runner.Shaders.Mid_Tiles.Matrix_Listed_Wide_Extra;
         Request : aliased Shader_Create_Info;
      begin
         if Create = null then
            Close (Item);
            return;
         end if;

         Request.Size := Interfaces.C.size_t (Tiles'Length * 4);
         Request.Code := Tiles'Address;

         --  A module the device refuses is not a fault. The shader is
         --  SPIR-V 1.6 and names an extension; a device that took the
         --  extension and will not take the module is a device this
         --  leaves on the row product, which is what every device
         --  without the instruction runs anyway.
         if Create (Item.Logical, Request'Address, Null_Handle,
                    Made'Access) /= 0
         then
            Item.Matrices := False;
         else
            Item.Matrix := Made;

            Request.Size := Interfaces.C.size_t (Copy'Length * 4);
            Request.Code := Copy'Address;

            if Create (Item.Logical, Request'Address, Null_Handle,
                       Made'Access) /= 0
            then
               Item.Matrices := False;
            else
               Item.Halver := Made;

               --  And the sixth, from the same source compiled with the
               --  other eight formats. This one is allowed to fail on
               --  its own: it is left null and those eight go to the row
               --  product, while the six the fourth decodes carry on.
               Request.Size := Interfaces.C.size_t (More'Length * 4);
               Request.Code := More'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Extra := Made;
               end if;

               --  And the two narrow tiles, on the same terms: refused,
               --  they leave a small batch on the wide tile.
               Request.Size := Interfaces.C.size_t (Thin'Length * 4);
               Request.Code := Thin'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Narrow := Made;
               end if;

               Request.Size :=
                 Interfaces.C.size_t (Thin_More'Length * 4);
               Request.Code := Thin_More'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Narrow_More := Made;
               end if;

               Request.Size := Interfaces.C.size_t (Listed'Length * 4);
               Request.Code := Listed'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Listed_Tile := Made;
               end if;

               Request.Size :=
                 Interfaces.C.size_t (Listed_More'Length * 4);
               Request.Code := Listed_More'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Listed_Tile_More := Made;
               end if;

               Request.Size :=
                 Interfaces.C.size_t (Listed_Five'Length * 4);
               Request.Code := Listed_Five'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Listed_Tile_Five := Made;
               end if;

               Request.Size :=
                 Interfaces.C.size_t (Listed_Wide'Length * 4);
               Request.Code := Listed_Wide'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Listed_Tile_Wide := Made;
               end if;

               Request.Size :=
                 Interfaces.C.size_t (Listed_Wide_More'Length * 4);
               Request.Code := Listed_Wide_More'Address;

               if Create (Item.Logical, Request'Address, Null_Handle,
                          Made'Access) = 0
               then
                  Item.Listed_Tile_Wide_More := Made;
               end if;

               declare
                  Words : aliased constant Model_Runner.Shaders.Word_Array :=
                    Model_Runner.Shaders.Low_Tiles.Matrix_Low;
               begin
                  Request.Size := Interfaces.C.size_t (Words'Length * 4);
                  Request.Code := Words'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Low_Tile := Made;
                  end if;
               end;

               --  And the wider tile's three, all or none in use.
               declare
                  procedure Module
                    (Words : Model_Runner.Shaders.Word_Array;
                     Into  : out Address)
                  is
                     Held : aliased constant Model_Runner.Shaders.Word_Array
                       := Words;
                  begin
                     Into := Null_Handle;
                     Request.Size := Interfaces.C.size_t (Held'Length * 4);
                     Request.Code := Held'Address;

                     if Create (Item.Logical, Request'Address, Null_Handle,
                                Made'Access) = 0
                     then
                        Into := Made;
                     end if;
                  end Module;
               begin
                  Module (Model_Runner.Shaders.Matrix_Wider, Item.Wider);
                  Module (Model_Runner.Shaders.Matrix_Wider_Extra,
                          Item.Wider_More);
                  Module (Model_Runner.Shaders.Low_Tiles.Matrix_Wider_Low,
                          Item.Wider_Low);
                  Module (Model_Runner.Shaders.Low_Tiles.Matrix_Tap_Short,
                          Item.Tap_Short);
                  Module (Model_Runner.Shaders.Low_Tiles.Matrix_Tap_Tall,
                          Item.Tap_Tall);
                  Module (Model_Runner.Shaders.Mid_Tiles.Matrix_Mid,
                          Item.Mid);
                  Module (Model_Runner.Shaders.Mid_Tiles.Matrix_Mid_Extra,
                          Item.Mid_More);
                  Module (Model_Runner.Shaders.Mid_Tiles.Matrix_Mid_Low,
                          Item.Mid_Low);
                  Module (Model_Runner.Shaders.Mid_Tiles.Matrix_Mid_Wide,
                          Item.Mid_Wide);
                  Module
                    (Model_Runner.Shaders.Mid_Tiles.Matrix_Mid_Wide_Extra,
                     Item.Mid_Wide_More);
                  Module
                    (Model_Runner.Shaders.Mid_Tiles.Matrix_Mid_Wide_Low,
                     Item.Mid_Wide_Low);
               end;

               declare
                  Words : aliased constant Model_Runner.Shaders.Word_Array :=
                    Model_Runner.Shaders.Low_Tiles.Matrix_Narrow_Low;
               begin
                  Request.Size := Interfaces.C.size_t (Words'Length * 4);
                  Request.Code := Words'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Narrow_Low := Made;
                  end if;
               end;

               declare
                  Words : aliased constant Model_Runner.Shaders.Word_Array :=
                    Model_Runner.Shaders.Low_Tiles.Matrix_Listed_Low;
               begin
                  Request.Size := Interfaces.C.size_t (Words'Length * 4);
                  Request.Code := Words'Address;

                  if Create (Item.Logical, Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Tile_Low := Made;
                  end if;
               end;
            end if;
         end if;
      end;
   end if;

   --  Six storage buffers, and what a set of them looks like.
   declare
      Create : constant Create_Call :=
        To_Create (Point ("vkCreateDescriptorSetLayout"));

      Bindings : aliased Binding_Array;
      Request  : aliased Set_Layout_Create_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      for Index in Bindings'Range loop
         Bindings (Index).Binding := C.unsigned (Index - 1);
      end loop;

      Request.Bindings := Bindings'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Set_Layout := Made;
   end;

   --  The layout of the pipeline: that set, and the two numbers the
   --  shader is told about the shape.
   declare
      Create : constant Create_Call :=
        To_Create (Point ("vkCreatePipelineLayout"));

      Sets    : aliased Address := Item.Set_Layout;
      Pushes  : aliased Push_Range;
      Request : aliased Pipeline_Layout_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      Request.Sets := Sets'Address;
      Request.Pushes := Pushes'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Layout := Made;
   end;

   --  And the pipelines, all from the one module.
   --
   --  Five of them, differing only in the two constants the shader takes:
   --  how wide a workgroup is and how many vectors an invocation carries.
   --  They were five modules until the fourth one put the generated Ada
   --  over the size this repository accepts, which was the right thing to
   --  be told -- ninety-six kilobytes of SPIR-V a copy, and the copies
   --  differed by one integer.
   declare
      Create : constant Create_Pipelines_Call :=
        To_Create_Pipelines (Point ("vkCreateComputePipelines"));

      Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
      Request : aliased Compute_Pipeline_Info;

      type Told_Entries is array (1 .. 2) of aliased Specialization_Entry;
      type Told_Values is array (1 .. 2) of aliased C.unsigned;

      Entries : aliased Told_Entries :=
        [(Which => 0, At_Was => 0, Span => 4),
         (Which => 1, At_Was => 4, Span => 4)];

      Values : aliased Told_Values := [Group_Size, Batch_Group];
      Told   : aliased Specialization_Info;

      --  Made and reported rather than made and required: a device that
      --  refuses one of the narrower shapes runs every count on the one
      --  before it, which is what every device did before that shape
      --  existed. Only the first is a fault.
      procedure Line (Width, Group : C.unsigned; Into : out Address);

      procedure Line (Width, Group : C.unsigned; Into : out Address) is
      begin
         Values := [Width, Group];
         Request.Stage.Specialized := Told'Address;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Into := Made;
         end if;
      end Line;
   begin
      if Create = null then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      Told.Count := 2;
      Told.Entries := Entries (Entries'First)'Address;
      Told.Span := 8;
      Told.Values := Values (Values'First)'Address;

      Request.Stage.Module := Item.Shader;
      Request.Stage.Name := Name;
      Request.Layout := Item.Layout;

      Line (Group_Size, Batch_Group, Item.Pipeline);

      if Item.Pipeline = Null_Handle then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      for Count in Row_Line_Array'Range loop
         Line (Group_Size, C.unsigned (Count), Item.Row_Lines (Count));
      end loop;

      Line (Half_Group, 1, Item.Half_Group_Line);
      Line (Group_Size, Wide_Group, Item.Wide_Line);

      --  And the low-bit compilation's, one for each of those but the
      --  narrowed one, which is a sixteen-format tuning.
      Request.Stage.Module := Item.Low_Shader;
      Line (Group_Size, Batch_Group, Item.Low_Pipeline);

      for Count in Row_Line_Array'Range loop
         Line (Group_Size, C.unsigned (Count), Item.Low_Row_Lines (Count));
      end loop;

      Line (Group_Size, Wide_Group, Item.Low_Wide_Line);

      --  The rounding the integer walks read, at its own width.
      if Item.Round_Shader /= Null_Handle then
         Request.Stage.Module := Item.Round_Shader;
         Line (Group_Size, 1, Item.Round_Line);
      end if;

      if Item.Reference_Shader /= Null_Handle then
         Request.Stage.Module := Item.Reference_Shader;
         Line (Group_Size, 1, Item.Reference_Line);
      end if;

      Request.Stage.Module := Item.Shader;

      if Item.Low_Pipeline = Null_Handle then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      --  The super-block row product, from its module, at a workgroup of
      --  sixty-four pinned to a subgroup of sixty-four -- one subgroup a
      --  workgroup, which is what lets the device honour the width. It
      --  carries one vector, the generating width.
      if Item.Wave_Shader /= Null_Handle then
         declare
            Reqsize : aliased Required_Size_Info;
         begin
            Reqsize.Required := Wave_Lanes;
            Request.Stage.Next := Reqsize'Address;
            Request.Stage.Flags := Require_Full_Subgroups;

            Request.Stage.Module := Item.Wave_Shader;
            Line (Wave_Lanes, 1, Item.Wave_Line);

            if Item.Wave_Shader5 /= Null_Handle then
               Request.Stage.Module := Item.Wave_Shader5;
               Line (Wave_Lanes, 1, Item.Wave_Line5);
            end if;

            if Item.Wave_Shader6 /= Null_Handle then
               Request.Stage.Module := Item.Wave_Shader6;
               Line (Wave_Lanes, 1, Item.Wave_Line6);
            end if;

            --  The positions a pipeline carries are its second constant.
            for Count in Many_Count loop
               if Item.Many_Shader4 /= Null_Handle then
                  Request.Stage.Module := Item.Many_Shader4;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Many_Lines4 (Count));
               end if;
               if Item.Many_Shader5 /= Null_Handle then
                  Request.Stage.Module := Item.Many_Shader5;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Many_Lines5 (Count));
               end if;
               if Item.Many_Shader6 /= Null_Handle then
                  Request.Stage.Module := Item.Many_Shader6;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Many_Lines6 (Count));
               end if;
               if Item.Glu_Many_Shader /= Null_Handle then
                  Request.Stage.Module := Item.Glu_Many_Shader;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Glu_Many_Lines (Count));
               end if;
               if Item.Dots_Shader /= Null_Handle then
                  Request.Stage.Module := Item.Dots_Shader;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Dots_Lines (Count));
               end if;
               if Item.Dots_Shader5 /= Null_Handle then
                  Request.Stage.Module := Item.Dots_Shader5;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Dots_Lines5 (Count));
               end if;
               if Item.Dots_Shader6 /= Null_Handle then
                  Request.Stage.Module := Item.Dots_Shader6;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Dots_Lines6 (Count));
               end if;
               if Item.Glu_Dots_Shader /= Null_Handle then
                  Request.Stage.Module := Item.Glu_Dots_Shader;
                  Line (Wave_Lanes, C.unsigned (Count),
                        Item.Glu_Dots_Lines (Count));
               end if;
            end loop;

            if Item.Glu_Shader /= Null_Handle then
               Request.Stage.Module := Item.Glu_Shader;
               Line (Wave_Lanes, 1, Item.Glu_Line);
            end if;

            if Item.Long_Shader6 /= Null_Handle then
               Request.Stage.Module := Item.Long_Shader6;
               Line (Wave_Lanes, 1, Item.Long_Line6);
            end if;

            if Item.Mid_Shader6 /= Null_Handle then
               Request.Stage.Module := Item.Mid_Shader6;
               Line (Wave_Lanes, 1, Item.Mid_Line6);
            end if;

            if Item.Long_Shader /= Null_Handle then
               Request.Stage.Module := Item.Long_Shader;
               Line (Wave_Lanes, 1, Item.Long_Line);
            end if;

            if Item.Long_Shader5 /= Null_Handle then
               Request.Stage.Module := Item.Long_Shader5;
               Line (Wave_Lanes, 1, Item.Long_Line5);
            end if;

            Reqsize.Required := Low_Wave_Lanes;

            for Packing in Low_Packing loop
               if Item.Low_Wave_Shaders (Packing) /= Null_Handle then
                  Request.Stage.Module := Item.Low_Wave_Shaders (Packing);
                  Line (Low_Wave_Lanes, 1, Item.Low_Wave_Lines (Packing));
               end if;
            end loop;

            if Item.Q8_Wave_Shader /= Null_Handle then
               Request.Stage.Module := Item.Q8_Wave_Shader;
               Line (Low_Wave_Lanes, 1, Item.Q8_Wave_Line);
            end if;

            if Item.Q8_Short_Shader /= Null_Handle then
               Request.Stage.Module := Item.Q8_Short_Shader;
               Line (Low_Wave_Lanes, 1, Item.Q8_Short_Line);
            end if;

            for Count in Q8_Count loop
               if Item.Q8_Multi_Shaders (Count) /= Null_Handle then
                  Request.Stage.Module := Item.Q8_Multi_Shaders (Count);
                  Line (Low_Wave_Lanes, 1, Item.Q8_Multi_Lines (Count));
               end if;
               if Item.Q8_Dots_Shaders (Count) /= Null_Handle then
                  Request.Stage.Module := Item.Q8_Dots_Shaders (Count);
                  Line (Low_Wave_Lanes, 1, Item.Q8_Dots_Lines (Count));
               end if;
            end loop;

            for Count in Multi_Count loop
               if Item.Q8_Glu_Multi_Shaders (Count) /= Null_Handle then
                  Request.Stage.Module := Item.Q8_Glu_Multi_Shaders (Count);
                  Line (Low_Wave_Lanes, 1, Item.Q8_Glu_Multi_Lines (Count));
               end if;
               if Item.Q8_Glu_Dots_Shaders (Count) /= Null_Handle then
                  Request.Stage.Module := Item.Q8_Glu_Dots_Shaders (Count);
                  Line (Low_Wave_Lanes, 1, Item.Q8_Glu_Dots_Lines (Count));
               end if;
            end loop;

            if Item.Q8_Glu_Shader /= Null_Handle then
               Request.Stage.Module := Item.Q8_Glu_Shader;
               Line (Low_Wave_Lanes, 1, Item.Q8_Glu_Line);
            end if;

            if Item.Q8_Glu_Short_Shader /= Null_Handle then
               Request.Stage.Module := Item.Q8_Glu_Short_Shader;
               Line (Low_Wave_Lanes, 1, Item.Q8_Glu_Short_Line);
            end if;

            if Item.NL_Wave_Shader /= Null_Handle then
               Request.Stage.Module := Item.NL_Wave_Shader;
               Line (Low_Wave_Lanes, 1, Item.NL_Wave_Line);
            end if;

            if Item.MX_Wave_Shader /= Null_Handle then
               Request.Stage.Module := Item.MX_Wave_Shader;
               Line (Low_Wave_Lanes, 1, Item.MX_Wave_Line);
            end if;

            if Item.MX_Glu_Shader /= Null_Handle then
               Request.Stage.Module := Item.MX_Glu_Shader;
               Line (Low_Wave_Lanes, 1, Item.MX_Glu_Line);
            end if;

            if Item.XS_Wave_Shader /= Null_Handle then
               Request.Stage.Module := Item.XS_Wave_Shader;
               Line (Low_Wave_Lanes, 1, Item.XS_Wave_Line);
            end if;

            if Item.Q2K_Wave_Shader /= Null_Handle then
               Request.Stage.Module := Item.Q2K_Wave_Shader;
               Line (Low_Wave_Lanes, 1, Item.Q2K_Wave_Line);
            end if;

            if Item.Q3K_Wave_Shader /= Null_Handle then
               Request.Stage.Module := Item.Q3K_Wave_Shader;
               Line (Low_Wave_Lanes, 1, Item.Q3K_Wave_Line);
            end if;

            for Packing in Legacy_Packing loop
               if Item.Legacy_Wave_Shaders (Packing) /= Null_Handle then
                  Request.Stage.Module := Item.Legacy_Wave_Shaders (Packing);
                  Line (Low_Wave_Lanes, 1,
                        Item.Legacy_Wave_Lines (Packing));
               end if;
            end loop;

            for Packing in Half_Packing loop
               if Item.Half_Wave_Shaders (Packing) /= Null_Handle then
                  Request.Stage.Module := Item.Half_Wave_Shaders (Packing);
                  Line (Low_Wave_Lanes, 1, Item.Half_Wave_Lines (Packing));
               end if;
            end loop;

            --  And each of those over a few vectors at once, made from
            --  the same compilation at its second constant.
            declare
               procedure Many (Module : Address; Packing : Weight_Packing);

               --  Two to eight positions, as Q4_K's.
               procedure Many (Module : Address; Packing : Weight_Packing)
               is
               begin
                  if Module /= Null_Handle then
                     Request.Stage.Module := Module;
                     for Count in Many_Count loop
                        Line (Low_Wave_Lanes, C.unsigned (Count),
                              Item.Wave_Multi_Lines (Packing) (Count));
                     end loop;
                  end if;
               end Many;
            begin
               for Packing in Low_Packing loop
                  Many (Item.Low_Wave_Shaders (Packing), Packing);
               end loop;
               Many (Item.NL_Wave_Shader, Packed_IQ4_NL);
               Many (Item.MX_Wave_Shader, Packed_MXFP4);
               Many (Item.XS_Wave_Shader, Packed_IQ4_XS);

               --  The integer walks, at the same counts.
               for Packing in Weight_Packing loop
                  if Item.Dots_Wave_Shaders (Packing) /= Null_Handle then
                     Request.Stage.Module := Item.Dots_Wave_Shaders (Packing);
                     for Count in Many_Count loop
                        Line (Low_Wave_Lanes, C.unsigned (Count),
                              Item.Dots_Multi_Lines (Packing) (Count));
                     end loop;
                  end if;
               end loop;
               Many (Item.Q2K_Wave_Shader, Packed_Q2_K);
               Many (Item.Q3K_Wave_Shader, Packed_Q3_K);
               for Packing in Legacy_Packing loop
                  Many (Item.Legacy_Wave_Shaders (Packing), Packing);
               end loop;
               for Packing in Half_Packing loop
                  Many (Item.Half_Wave_Shaders (Packing), Packing);
               end loop;
            end;

            Request.Stage.Module := Item.Shader;
            Request.Stage.Next := Null_Handle;
            Request.Stage.Flags := 0;
         end;
      end if;

      C.Strings.Free (Name);
   end;
   --  And the second kernel's pipeline, against the same layout.
   declare
      Create : constant Create_Pipelines_Call :=
        To_Create_Pipelines (Point ("vkCreateComputePipelines"));

      Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
      Request : aliased Compute_Pipeline_Info;
   begin
      if Create = null then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      Request.Stage.Module := Item.Blender;
      Request.Stage.Name := Name;
      Request.Layout := Item.Layout;

      if Create (Item.Logical, Null_Handle, 1, Request'Address,
                 Null_Handle, Made'Access) /= 0
      then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      Item.Blend_Line := Made;

      --  And the normalization's, on the same layout and after the
      --  request has its entry point and its layout -- which is the
      --  whole of what a pipeline needs and what creating one before
      --  those were set does not have.
      if Item.Normer /= Null_Handle then
         Request.Stage.Module := Item.Normer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Norm_Line := Made;
         end if;
      end if;

      if Item.Round_Normer /= Null_Handle then
         Request.Stage.Module := Item.Round_Normer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Norm_Round_Line := Made;
         end if;
      end if;

      if Item.Router /= Null_Handle then
         Request.Stage.Module := Item.Router;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Route_Line := Made;
         end if;
      end if;

      if Item.Header /= Null_Handle then
         Request.Stage.Module := Item.Header;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Heads_Line := Made;
         end if;
      end if;

      if Item.Merger /= Null_Handle then
         Request.Stage.Module := Item.Merger;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Merge_Line := Made;
         end if;
      end if;

      if Item.Inverter /= Null_Handle then
         Request.Stage.Module := Item.Inverter;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Invert_Line := Made;
         end if;
      end if;

      if Item.Thinner /= Null_Handle then
         Request.Stage.Module := Item.Thinner;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Thin_Line := Made;
         end if;
      end if;

      if Item.Folder /= Null_Handle then
         Request.Stage.Module := Item.Folder;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Fold_Line := Made;
         end if;
      end if;

      if Item.F32_Tiler /= Null_Handle then
         Request.Stage.Module := Item.F32_Tiler;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.F32_Tile_Line := Made;
         end if;
      end if;

      if Item.Mixer /= Null_Handle then
         Request.Stage.Module := Item.Mixer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Mix_Line := Made;
         end if;
      end if;

      if Item.Biaser /= Null_Handle then
         Request.Stage.Module := Item.Biaser;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Bias_Line := Made;
         end if;
      end if;

      if Item.Picker /= Null_Handle then
         Request.Stage.Module := Item.Picker;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Pick_Line := Made;
         end if;
      end if;

      if Item.Assembler /= Null_Handle then
         Request.Stage.Module := Item.Assembler;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Assemble_Line := Made;
         end if;
      end if;

      if Item.Rwkver /= Null_Handle then
         Request.Stage.Module := Item.Rwkver;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Rwkv_Line := Made;
         end if;
      end if;

      if Item.Wkver /= Null_Handle then
         Request.Stage.Module := Item.Wkver;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Wkv_Line := Made;
         end if;
      end if;

      if Item.Mambaer /= Null_Handle then
         Request.Stage.Module := Item.Mambaer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Mamba_Line := Made;
         end if;
      end if;

      if Item.Scanner /= Null_Handle then
         Request.Stage.Module := Item.Scanner;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Scan_Line := Made;
         end if;
      end if;

      if Item.Scanner1 /= Null_Handle then
         Request.Stage.Module := Item.Scanner1;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Scan1_Line := Made;
         end if;
      end if;

      if Item.Conver /= Null_Handle then
         Request.Stage.Module := Item.Conver;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Conv_Line := Made;
         end if;
      end if;

      if Item.Ruler /= Null_Handle then
         Request.Stage.Module := Item.Ruler;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Rule_Line := Made;
         end if;
      end if;

      if Item.Held_Ruler /= Null_Handle then
         Request.Stage.Module := Item.Held_Ruler;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Held_Rule_Line := Made;
         end if;
      end if;

      if Item.Single_Ruler /= Null_Handle then
         Request.Stage.Module := Item.Single_Ruler;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Single_Rule_Line := Made;
         end if;
      end if;

      if Item.Replayer /= Null_Handle then
         Request.Stage.Module := Item.Replayer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Replay_Line := Made;
         end if;
      end if;

      if Item.Turner /= Null_Handle then
         Request.Stage.Module := Item.Turner;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Turn_Line := Made;
         end if;
      end if;

      if Item.Placer /= Null_Handle then
         Request.Stage.Module := Item.Placer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Place_Line := Made;
         end if;
      end if;

      if Item.Fetcher /= Null_Handle then
         Request.Stage.Module := Item.Fetcher;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Fetch_Line := Made;
         end if;
      end if;

      C.Strings.Free (Name);
   end;

   --  And the third kernel's pipeline, against the same layout.
   declare
      Create : constant Create_Pipelines_Call :=
        To_Create_Pipelines (Point ("vkCreateComputePipelines"));

      Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
      Request : aliased Compute_Pipeline_Info;
      Pin     : aliased Required_Size_Info;
   begin
      if Create = null then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      Request.Stage.Module := Item.Attender;
      Request.Stage.Name := Name;
      Request.Layout := Item.Layout;

      if Create (Item.Logical, Null_Handle, 1, Request'Address,
                 Null_Handle, Made'Access) /= 0
      then
         C.Strings.Free (Name);
         Close (Item);
         return;
      end if;

      Item.Attend_Line := Made;

      --  And the subgroup one, if its module was made. A refusal here is
      --  not a fault either.
      if Item.Grouped /= Null_Handle then
         Request.Stage.Module := Item.Grouped;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Group_Line := Made;
         end if;
      end if;

      if Item.Group_Line /= Null_Handle
        and then Item.Query_Tile /= Null_Handle
      then
         Request.Stage.Module := Item.Query_Tile;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Tile_Line := Made;
         end if;
      end if;

      if Item.Halver_Attend /= Null_Handle then
         Request.Stage.Module := Item.Halver_Attend;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Halved_Line := Made;
         end if;
      end if;

      if Item.Packed_Attend /= Null_Handle then
         Request.Stage.Module := Item.Packed_Attend;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Packed_Line := Made;
         end if;
      end if;

      if Item.Packed_Plain /= Null_Handle then
         Request.Stage.Module := Item.Packed_Plain;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Packed_Plain_Line := Made;
         end if;
      end if;

      if Item.Packer /= Null_Handle then
         Request.Stage.Module := Item.Packer;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Pack_Line := Made;
         end if;
      end if;

      if Item.Packer_Plain /= Null_Handle then
         Request.Stage.Module := Item.Packer_Plain;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Pack_Plain_Line := Made;
         end if;
      end if;

      --  Bound where the device offers no subgroup operations, or where
      --  a test asks.
      Item.Plain_Packing := Item.Packed_Line = Null_Handle;

      if Item.Halved_Line /= Null_Handle
        and then Item.Bundled_Attend /= Null_Handle
      then
         Request.Stage.Module := Item.Bundled_Attend;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Bundle_Line := Made;
         end if;

         --  And a token's flash attention at every group of up to eight
         --  heads and every head width a lane's registers hold.  The shader
         --  has four subgroup result slots for its 128 lanes, so this is a
         --  32-lane-subgroup pipeline, not merely a shader that happens to
         --  use subgroup operations.  Without size control the ordinary
         --  attention lines remain the safe fallback.
         if Item.Token_Attend /= Null_Handle
           and then Has_Sized_Subgroups (On)
         then
            declare
               type Two_Entries is array (1 .. 2) of Specialization_Entry
                 with Convention => C;
               type Two_Values is array (1 .. 2) of C.unsigned
                 with Convention => C;
               Which : aliased constant Two_Entries :=
                 [(Which => 1, At_Was => 0, Span => 4),
                  (Which => 2, At_Was => 4, Span => 4)];
               Value : aliased Two_Values := [1, 64];
               Told  : aliased Specialization_Info;
            begin
               Told.Count := 2;
               Told.Entries := Which'Address;
               Told.Span := 8;
               Told.Values := Value'Address;
               Pin.Required := 32;
               Request.Stage.Next := Pin'Address;
               Request.Stage.Flags := Require_Full_Subgroups;
               Request.Stage.Specialized := Told'Address;
               for Packed in Boolean loop
                  Request.Stage.Module :=
                    (if Packed then Item.Packed_Token_Attend
                     else Item.Token_Attend);
                  for Rows in 1 .. Token_Group_Most loop
                     for Width in 1 .. Token_Width_Most loop
                        Value :=
                          [C.unsigned (Rows), C.unsigned (64 * Width)];
                        if Request.Stage.Module /= Null_Handle
                          and then (Width <= 2
                                    or else (Width <= 4 and then Rows * Width <= 8)
                                    or else (Width = 8 and then Rows <= 4))
                          and then Create (Item.Logical, Null_Handle, 1,
                                           Request'Address, Null_Handle,
                                           Made'Access) = 0
                        then
                           if Packed then
                              Item.Packed_Token_Lines (Rows) (Width) :=
                                Made;
                           else
                              Item.Token_Lines (Rows) (Width) := Made;
                           end if;
                        end if;
                     end loop;
                  end loop;
               end loop;
               Request.Stage.Specialized := Null_Handle;
               Request.Stage.Next := Null_Handle;
               Request.Stage.Flags := 0;
               Request.Stage.Module := Item.Bundled_Attend;
            end;
         end if;

         --  And the same words at the width of each whole group four
         --  does not divide, for a token attending out of the copy.
         declare
            Which  : aliased Specialization_Entry :=
              (Which => 1, At_Was => 0, Span => 4);
            Value  : aliased C.unsigned := 0;
            Told   : aliased Specialization_Info;
         begin
            Told.Count := 1;
            Told.Entries := Which'Address;
            Told.Span := 4;
            Told.Values := Value'Address;
            Request.Stage.Specialized := Told'Address;

            for Width in Whole_Lines'Range loop
               Value := C.unsigned (Width);

               if Create (Item.Logical, Null_Handle, 1, Request'Address,
                          Null_Handle, Made'Access) = 0
               then
                  Item.Whole_Halved_Line (Width) := Made;
               end if;
            end loop;

            Request.Stage.Specialized := Null_Handle;
         end;
      end if;

      if Item.Group_Line /= Null_Handle
        and then Item.Exact_Bundled_Attend /= Null_Handle
      then
         Request.Stage.Module := Item.Exact_Bundled_Attend;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Exact_Bundle_Line := Made;
         end if;

         --  And the same words at the width of each whole group four
         --  does not divide, told through the shader's second
         --  specialization constant.
         declare
            Which  : aliased Specialization_Entry :=
              (Which => 1, At_Was => 0, Span => 4);
            Value  : aliased C.unsigned := 0;
            Told   : aliased Specialization_Info;
         begin
            Told.Count := 1;
            Told.Entries := Which'Address;
            Told.Span := 4;
            Told.Values := Value'Address;
            Request.Stage.Specialized := Told'Address;

            for Width in Whole_Lines'Range loop
               Value := C.unsigned (Width);

               if Create (Item.Logical, Null_Handle, 1, Request'Address,
                          Null_Handle, Made'Access) = 0
               then
                  Item.Whole_Bundle_Line (Width) := Made;
               end if;
            end loop;

            Request.Stage.Specialized := Null_Handle;
         end;
      end if;

      if Item.Group_Line /= Null_Handle
        and then Item.Exact_Paired_Attend /= Null_Handle
      then
         Request.Stage.Module := Item.Exact_Paired_Attend;

         declare
            Which  : aliased Specialization_Entry :=
              (Which => 1, At_Was => 0, Span => 4);
            Value  : aliased C.unsigned := Pair_Bundle;
            Told   : aliased Specialization_Info;
         begin
            Told.Count := 1;
            Told.Entries := Which'Address;
            Told.Span := 4;
            Told.Values := Value'Address;
            Request.Stage.Specialized := Told'Address;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) = 0
            then
               Item.Pair_Bundle_Line := Made;
            end if;

            Request.Stage.Specialized := Null_Handle;
         end;
      end if;

      --  The matrix attention's at subgroups of sixty-four, whole, as
      --  the matrix products are: it numbers its subgroups by sixty-four
      --  lanes. Refused, the attention is the other kernels'.
      Pin.Required := Matrix_Lanes;
      Request.Stage.Next := Pin'Address;
      Request.Stage.Flags := Require_Full_Subgroups;

      if Item.Attend_Matrix /= Null_Handle then
         Request.Stage.Module := Item.Attend_Matrix;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Attend := Made;
         end if;
      end if;

      if Item.Attend_Matrix_Wide /= Null_Handle then
         Request.Stage.Module := Item.Attend_Matrix_Wide;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Wide_Attend := Made;
         end if;
      end if;

      if Item.Attend_Matrix_Mid /= Null_Handle then
         Request.Stage.Module := Item.Attend_Matrix_Mid;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Mid_Attend := Made;
         end if;
      end if;

      if Item.Attend_Matrix_Wider /= Null_Handle then
         Request.Stage.Module := Item.Attend_Matrix_Wider;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Wider_Attend := Made;
         end if;
      end if;

      --  Four subgroups of sixty-four, fixed in its source.
      if Item.Attend_Split /= Null_Handle then
         Request.Stage.Module := Item.Attend_Split;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Split_Attend := Made;
         end if;
      end if;

      if Item.Attend_Split_Narrow /= Null_Handle then
         Request.Stage.Module := Item.Attend_Split_Narrow;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Split_Narrow_Attend := Made;
         end if;
      end if;

      if Item.Attend_Split_Mid /= Null_Handle then
         Request.Stage.Module := Item.Attend_Split_Mid;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Split_Mid_Attend := Made;
         end if;
      end if;

      if Item.Attend_Split_Wider /= Null_Handle then
         Request.Stage.Module := Item.Attend_Split_Wider;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Matrix_Split_Wider_Attend := Made;
         end if;
      end if;

      --  Four subgroups of sixty-four, fixed in its source.
      if Item.Attend_Latent /= Null_Handle then
         Request.Stage.Module := Item.Attend_Latent;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Latent_Attend := Made;
         end if;
      end if;

      if Item.Attend_Latent_Batch /= Null_Handle then
         Request.Stage.Module := Item.Attend_Latent_Batch;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Latent_Batch_Attend := Made;
         end if;
      end if;

      if Item.Attend_Latent_Split /= Null_Handle then
         Request.Stage.Module := Item.Attend_Latent_Split;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Latent_Split_Attend := Made;
         end if;
      end if;

      if Item.Attend_Latent_Packed /= Null_Handle then
         Request.Stage.Module := Item.Attend_Latent_Packed;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Latent_Packed_Attend := Made;
         end if;
      end if;

      --  And each of the four again for a batch attending far:
      --  Matrix_Queries a subgroup, as the plain pipeline answers, and
      --  Matrix_Deep_Queries a workgroup, its subgroups reading the
      --  same keys and values in step. Thirty-two queries a subgroup
      --  had read them less often too, but held twice the registers:
      --  Qwen3 8B's prompt of 16,447 read in 111 s that way, 101 this,
      --  and a head of 256 lost by it where this gains.
      declare
         type Three_Entries is array (1 .. 3) of Specialization_Entry
           with Convention => C;
         type Three_Values is array (1 .. 3) of C.unsigned
           with Convention => C;

         Which : aliased constant Three_Entries :=
           [(Which => 1, At_Was => 0, Span => 4),
            (Which => 2, At_Was => 4, Span => 4),
            (Which => 3, At_Was => 8, Span => 4)];
         Value : aliased constant Three_Values :=
           [C.unsigned (Matrix_Queries),
            C.unsigned (Matrix_Deep_Queries_Held / Matrix_Queries),
            C.unsigned (64 * Matrix_Deep_Queries_Held / Matrix_Queries)];
         Wider : aliased constant Three_Values :=
           [C.unsigned (Matrix_Queries),
            C.unsigned (Matrix_Deep_Queries / Matrix_Queries),
            C.unsigned (64 * Matrix_Deep_Queries / Matrix_Queries)];
         Told  : aliased Specialization_Info;

         procedure Deep (Module : Address; Line : out Address) is
         begin
            Line := Null_Handle;
            if Module /= Null_Handle then
               Request.Stage.Module := Module;
               if Create (Item.Logical, Null_Handle, 1, Request'Address,
                          Null_Handle, Made'Access) = 0
               then
                  Line := Made;
               end if;
            end if;
         end Deep;
      begin
         Told.Count := 3;
         Told.Entries := Which'Address;
         Told.Span := 12;
         Told.Values := Value'Address;
         Request.Stage.Specialized := Told'Address;

         Deep (Item.Attend_Matrix, Item.Matrix_Deep_Attend);
         Deep (Item.Attend_Matrix_Mid, Item.Matrix_Mid_Deep_Attend);
         Told.Values := Wider'Address;
         Deep (Item.Attend_Matrix_Wide, Item.Matrix_Wide_Deep_Attend);
         Deep (Item.Attend_Matrix_Wider, Item.Matrix_Wider_Deep_Attend);

         --  And heads of 128 at eight subgroups, held as the narrower
         --  heads' are, for attention every position of which sees
         --  every other.
         Told.Values := Value'Address;
         Deep (Item.Attend_Matrix_Wide, Item.Matrix_Wide_Deep8_Attend);

         Request.Stage.Specialized := Null_Handle;
      end;

      --  And for a few positions at once: each width at one, two and
      --  four subgroups of sixteen rows, the fourth constant set.
      declare
         type Four_Entries is array (1 .. 4) of Specialization_Entry
           with Convention => C;
         type Four_Values is array (1 .. 4) of C.unsigned
           with Convention => C;

         Which : aliased constant Four_Entries :=
           [(Which => 1, At_Was => 0, Span => 4),
            (Which => 2, At_Was => 4, Span => 4),
            (Which => 3, At_Was => 8, Span => 4),
            (Which => 4, At_Was => 12, Span => 4)];
         Value : aliased Four_Values;
         Told  : aliased Specialization_Info;

         Modules : constant array (1 .. 4) of Address :=
           [Item.Attend_Matrix, Item.Attend_Matrix_Mid,
            Item.Attend_Matrix_Wide, Item.Attend_Matrix_Wider];
         Subs : constant array (1 .. 3) of C.unsigned := [1, 2, 4];
      begin
         Told.Count := 4;
         Told.Entries := Which'Address;
         Told.Span := 16;
         Told.Values := Value'Address;
         Request.Stage.Specialized := Told'Address;

         for Width in Modules'Range loop
            for Many in Subs'Range loop
               Item.Few_Attend (Width, Many) := Null_Handle;
               if Modules (Width) /= Null_Handle then
                  Value :=
                    [C.unsigned (Matrix_Queries), Subs (Many),
                     C."*" (64, Subs (Many)), 1];
                  Request.Stage.Module := Modules (Width);
                  if Create (Item.Logical, Null_Handle, 1, Request'Address,
                             Null_Handle, Made'Access) = 0
                  then
                     Item.Few_Attend (Width, Many) := Made;
                  end if;
               end if;
            end loop;
         end loop;

         Request.Stage.Specialized := Null_Handle;
      end;

      Request.Stage.Next := Null_Handle;
      Request.Stage.Flags := 0;

      --  And the unpacking of a packed layer into the copy that
      --  kernel reads, which is worth having only where it is.
      if Item.Unpacker /= Null_Handle
        and then Item.Matrix_Attend /= Null_Handle
      then
         Request.Stage.Module := Item.Unpacker;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) = 0
         then
            Item.Unpack_Line := Made;
         end if;
      end if;

      C.Strings.Free (Name);
   end;

   --  And the two pipelines the matrix product needs, against the same
   --  layout as the other three. A device that takes the module and
   --  refuses the pipeline is left on the row product for the same
   --  reason.
   if Item.Matrices then
      declare
         Create : constant Create_Pipelines_Call :=
           To_Create_Pipelines (Point ("vkCreateComputePipelines"));

         Name    : C.Strings.chars_ptr := C.Strings.New_String ("main");
         Request : aliased Compute_Pipeline_Info;
         Pin     : aliased Required_Size_Info;
      begin
         if Create = null then
            C.Strings.Free (Name);
            Close (Item);
            return;
         end if;

         Pin.Required := Matrix_Lanes;
         Request.Stage.Module := Item.Matrix;
         Request.Stage.Name := Name;
         Request.Layout := Item.Layout;

         --  Every one of these at subgroups of sixty-four, whole: the
         --  kernels number their subgroups by sixty-four lanes, and at
         --  another width two subgroups would take one tile's work
         --  each. A device that will not run them so refuses them, and
         --  is left on the row product.
         Request.Stage.Next := Pin'Address;
         Request.Stage.Flags := Require_Full_Subgroups;

         if Create (Item.Logical, Null_Handle, 1, Request'Address,
                    Null_Handle, Made'Access) /= 0
         then
            Item.Matrices := False;
         else
            Item.Matrix_Line := Made;

            Request.Stage.Module := Item.Halver;

            if Create (Item.Logical, Null_Handle, 1, Request'Address,
                       Null_Handle, Made'Access) /= 0
            then
               Item.Matrices := False;
            else
               Item.Halve_Line := Made;

               --  And the second tile, if its module was made. A
               --  refusal here is not a fault either.
               if Item.Extra /= Null_Handle then
                  Request.Stage.Module := Item.Extra;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Extra_Line := Made;
                  end if;
               end if;

               --  And the wide tile at thirty-two vectors, for listed
               --  products.
               if Item.Listed_Tile /= Null_Handle then
                  Request.Stage.Module := Item.Listed_Tile;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Line := Made;
                  end if;
               end if;

               if Item.Listed_Tile_More /= Null_Handle then
                  Request.Stage.Module := Item.Listed_Tile_More;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_More_Line := Made;
                  end if;
               end if;

               if Item.Listed_Tile_Five /= Null_Handle then
                  Request.Stage.Module := Item.Listed_Tile_Five;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Five_Line := Made;
                  end if;
               end if;

               --  And at Listed_Wide_Vectors, for the long runs.
               if Item.Listed_Tile_Wide /= Null_Handle then
                  Request.Stage.Module := Item.Listed_Tile_Wide;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Wide_Line := Made;
                  end if;
               end if;

               if Item.Listed_Tile_Wide_More /= Null_Handle then
                  Request.Stage.Module := Item.Listed_Tile_Wide_More;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Wide_More_Line := Made;
                  end if;
               end if;

               if Item.Narrow /= Null_Handle then
                  Request.Stage.Module := Item.Narrow;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Narrow_Line := Made;
                  end if;
               end if;

               if Item.Narrow_More /= Null_Handle then
                  Request.Stage.Module := Item.Narrow_More;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Narrow_More_Line := Made;
                  end if;
               end if;

               if Item.Low_Tile /= Null_Handle then
                  Request.Stage.Module := Item.Low_Tile;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Low_Tile_Line := Made;
                  end if;
               end if;

               --  The wider tile's three, and whether all three came.
               declare
                  procedure Line (Module : Address; Into : out Address) is
                  begin
                     Into := Null_Handle;
                     if Module /= Null_Handle then
                        Request.Stage.Module := Module;
                        if Create (Item.Logical, Null_Handle, 1,
                                   Request'Address, Null_Handle,
                                   Made'Access) = 0
                        then
                           Into := Made;
                        end if;
                     end if;
                  end Line;
               begin
                  Line (Item.Wider, Item.Wider_Line);
                  Line (Item.Wider_More, Item.Wider_More_Line);
                  Line (Item.Wider_Low, Item.Wider_Low_Line);
                  Line (Item.Tap_Short, Item.Tap_Short_Line);
                  Line (Item.Tap_Tall, Item.Tap_Tall_Line);
                  Line (Item.Mid, Item.Mid_Line);
                  Line (Item.Mid_More, Item.Mid_More_Line);
                  Line (Item.Mid_Low, Item.Mid_Low_Line);
                  Line (Item.Mid_Wide, Item.Mid_Wide_Line);
                  Line (Item.Mid_Wide_More, Item.Mid_Wide_More_Line);
                  Line (Item.Mid_Wide_Low, Item.Mid_Wide_Low_Line);
                  Item.Tile_Plan.Mid_Ready :=
                    Item.Mid_Line /= Null_Handle
                    and then Item.Mid_More_Line /= Null_Handle
                    and then Item.Mid_Low_Line /= Null_Handle;
                  Item.Tile_Plan.Mid_Wide_Ready :=
                    Item.Mid_Wide_Line /= Null_Handle
                    and then Item.Mid_Wide_More_Line /= Null_Handle
                    and then Item.Mid_Wide_Low_Line /= Null_Handle;
                  Item.Tile_Plan.Wider_Ready :=
                    Item.Wider_Line /= Null_Handle
                    and then Item.Wider_More_Line /= Null_Handle
                    and then Item.Wider_Low_Line /= Null_Handle;
               end;

               if Item.Narrow_Low /= Null_Handle then
                  Request.Stage.Module := Item.Narrow_Low;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Narrow_Low_Line := Made;
                  end if;
               end if;

               if Item.Listed_Tile_Low /= Null_Handle then
                  Request.Stage.Module := Item.Listed_Tile_Low;

                  if Create (Item.Logical, Null_Handle, 1,
                             Request'Address, Null_Handle,
                             Made'Access) = 0
                  then
                     Item.Listed_Low_Line := Made;
                  end if;
               end if;
            end if;
         end if;

         C.Strings.Free (Name);
      end;
   end if;

   --  Somewhere to keep one set of descriptors, and the set itself.
   declare
      Create : constant Create_Call :=
        To_Create (Point ("vkCreateDescriptorPool"));

      --  Room for the single product's set and for one per step of the
      --  longest sequence, in one pool: six storage descriptors each,
      --  which is what the set layout declares. A pool sized for five
      --  of them hands out sets whose sixth descriptor was never
      --  allocated, and a device asked to write one wrote nothing --
      --  every product read whatever the binding held last.
      Sizes   : aliased Pool_Size :=
        (Kind  => Descriptor_Storage,
         Count => C.unsigned (7 * (1 + 2 * Sequence_Limit)));
      Request : aliased Descriptor_Pool_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      Request.Max_Sets := C.unsigned (1 + 2 * Sequence_Limit);
      Request.Sizes := Sizes'Address;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Pool := Made;
   end;

   declare
      Allocate : constant Allocate_Sets_Call :=
        To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

      Layouts : aliased Address := Item.Set_Layout;
      Request : aliased Descriptor_Set_Info;
   begin
      if Allocate = null then
         Close (Item);
         return;
      end if;

      Request.Pool := Item.Pool;
      Request.Layouts := Layouts'Address;

      if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
         Close (Item);
         return;
      end if;

      Item.Descriptor := Made;
   end;

   --  And one set per product a sequence may hold, from the same pool
   --  and against the same layout. Allocated in one call: a pool hands
   --  out as many sets as it is asked for, and asking thirty-two times
   --  would be thirty-two round trips for the same thing.
   declare
      Allocate : constant Allocate_Sets_Call :=
        To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

      Layouts : aliased array (1 .. Sequence_Limit) of Address :=
        [others => Item.Set_Layout];
      Given   : Set_Array := [others => Null_Handle];
      First   : aliased Address := Null_Handle
        with Address => Given (Given'First)'Address;
      Request : aliased Descriptor_Set_Info;
   begin
      if Allocate = null then
         Close (Item);
         return;
      end if;

      Request.Pool := Item.Pool;
      Request.Count := C.unsigned (Sequence_Limit);
      Request.Layouts := Layouts (Layouts'First)'Address;

      if Allocate (Item.Logical, Request'Address, First'Access) /= 0 then
         Close (Item);
         return;
      end if;

      Item.Sets := Given;
   end;

   --  And a second array of them, for the sequence the host records
   --  while the device is still on the one before it.
   declare
      Allocate : constant Allocate_Sets_Call :=
        To_Allocate_Sets (Point ("vkAllocateDescriptorSets"));

      Layouts : aliased array (1 .. Sequence_Limit) of Address :=
        [others => Item.Set_Layout];
      Given   : Set_Array := [others => Null_Handle];
      First   : aliased Address := Null_Handle
        with Address => Given (Given'First)'Address;
      Request : aliased Descriptor_Set_Info;
   begin
      if Allocate = null then
         Close (Item);
         return;
      end if;

      Request.Pool := Item.Pool;
      Request.Count := C.unsigned (Sequence_Limit);
      Request.Layouts := Layouts (Layouts'First)'Address;

      if Allocate (Item.Logical, Request'Address, First'Access) /= 0 then
         Close (Item);
         return;
      end if;

      Item.Sets_Two := Given;
   end;

   --  A pool of commands and one buffer to record into.
   declare
      Create : constant Create_Call :=
        To_Create (Point ("vkCreateCommandPool"));

      Request : aliased Command_Pool_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      Request.Family := C.unsigned (Item.Family);

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Commands := Made;
   end;

   declare
      Allocate : constant Allocate_Buffers_Call :=
        To_Allocate_Buffers (Point ("vkAllocateCommandBuffers"));

      Request : aliased Command_Buffer_Info;
   begin
      if Allocate = null then
         Close (Item);
         return;
      end if;

      Request.Pool := Item.Commands;

      if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
         Close (Item);
         return;
      end if;

      Item.Buffer := Made;
   end;

   declare
      Allocate : constant Allocate_Buffers_Call :=
        To_Allocate_Buffers (Point ("vkAllocateCommandBuffers"));

      Request : aliased Command_Buffer_Info;
   begin
      if Allocate = null then
         Close (Item);
         return;
      end if;

      Request.Pool := Item.Commands;

      if Allocate (Item.Logical, Request'Address, Made'Access) /= 0 then
         Close (Item);
         return;
      end if;

      Item.Buffer_Two := Made;
   end;

   --  And something to wait on.
   declare
      Create : constant Create_Call :=
        To_Create (Point ("vkCreateFence"));

      Request : aliased Fence_Create_Info;
   begin
      if Create = null then
         Close (Item);
         return;
      end if;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Fence := Made;

      if Create (Item.Logical, Request'Address, Null_Handle, Made'Access)
         /= 0
      then
         Close (Item);
         return;
      end if;

      Item.Fence_Two := Made;
   end;

   --  Turn_Line already proves that the device's enabled Float64 path can
   --  build a pipeline. Keep this optional, as the existing rotation is.
   if Item.Turn_Line /= Null_Handle then
      declare
         Make_Shader : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Make_Line : constant Create_Pipelines_Call := To_Create_Pipelines (Point ("vkCreateComputePipelines"));
         Words : aliased constant Model_Runner.Shaders.Word_Array := Model_Runner.Shaders.Combine_Native;
         Shader : aliased Shader_Create_Info;
         Request : aliased Compute_Pipeline_Info;
         Name : C.Strings.chars_ptr := C.Strings.New_String ("main");
      begin
         Shader.Size := Interfaces.C.size_t (Words'Length * 4);
         Shader.Code := Words'Address;
         if Make_Shader /= null and then Make_Line /= null
           and then Make_Shader (Item.Logical, Shader'Address, Null_Handle, Made'Access) = 0
         then
            Item.Native_Blender := Made;
            Request.Stage.Module := Made;
            Request.Stage.Name := Name;
            Request.Layout := Item.Layout;
            if Make_Line (Item.Logical, Null_Handle, 1, Request'Address, Null_Handle, Made'Access) = 0 then
               Item.Native_Blend_Line := Made;
            end if;
         end if;
         C.Strings.Free (Name);
      end;
   end if;

   --  Reference packing uses the same optional Float64 capability as the
   --  existing native control pipeline. A refusal keeps host packing.
   if Item.Turn_Line /= Null_Handle and then Item.Reference_Line /= Null_Handle then
      declare
         Make_Shader : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Make_Line : constant Create_Pipelines_Call := To_Create_Pipelines (Point ("vkCreateComputePipelines"));
         Words : aliased constant Model_Runner.Shaders.Word_Array := Model_Runner.Shaders.Round_Reference;
         Shader : aliased Shader_Create_Info;
         Request : aliased Compute_Pipeline_Info;
         Name : C.Strings.chars_ptr := C.Strings.New_String ("main");
      begin
         Shader.Size := Interfaces.C.size_t (Words'Length * 4); Shader.Code := Words'Address;
         if Make_Shader /= null and then Make_Line /= null
           and then Make_Shader (Item.Logical, Shader'Address, Null_Handle, Made'Access) = 0
         then
            Item.Reference_Round_Shader := Made;
            Request.Stage.Module := Made; Request.Stage.Name := Name; Request.Layout := Item.Layout;
            if Make_Line (Item.Logical, Null_Handle, 1, Request'Address, Null_Handle, Made'Access) = 0 then
               Item.Reference_Round_Line := Made;
            end if;
         end if;
         C.Strings.Free (Name);
      end;
   end if;

   if Item.Turn_Line /= Null_Handle and then Item.Reference_Round_Line /= Null_Handle then
      declare
         Make_Shader : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Make_Line : constant Create_Pipelines_Call := To_Create_Pipelines (Point ("vkCreateComputePipelines"));
         Words : aliased constant Model_Runner.Shaders.Word_Array := Model_Runner.Shaders.Reference_Activation;
         Shader : aliased Shader_Create_Info;
         Request : aliased Compute_Pipeline_Info;
         Name : C.Strings.chars_ptr := C.Strings.New_String ("main");
      begin
         Shader.Size := Interfaces.C.size_t (Words'Length * 4); Shader.Code := Words'Address;
         if Make_Shader /= null and then Make_Line /= null
           and then Make_Shader (Item.Logical, Shader'Address, Null_Handle, Made'Access) = 0
         then
            Item.Reference_Activation_Shader := Made;
            Request.Stage.Module := Made; Request.Stage.Name := Name; Request.Layout := Item.Layout;
            if Make_Line (Item.Logical, Null_Handle, 1, Request'Address, Null_Handle, Made'Access) = 0 then
               Item.Reference_Activation_Line := Made;
            end if;
         end if;
         C.Strings.Free (Name);
      end;
   end if;

   --  Turn_Line proves enabled Float64 support for the ordered grid fold.
   if Item.Turn_Line /= Null_Handle and then Item.Reference_Round_Line /= Null_Handle then
      declare
         Make_Shader : constant Create_Call := To_Create (Point ("vkCreateShaderModule"));
         Make_Line : constant Create_Pipelines_Call := To_Create_Pipelines (Point ("vkCreateComputePipelines"));
         Words : aliased constant Model_Runner.Shaders.Word_Array := Model_Runner.Shaders.Row_Product_GSQ_Reference;
         Shader : aliased Shader_Create_Info;
         Request : aliased Compute_Pipeline_Info;
         Name : C.Strings.chars_ptr := C.Strings.New_String ("main");
      begin
         Shader.Size := Interfaces.C.size_t (Words'Length * 4); Shader.Code := Words'Address;
         if Make_Shader /= null and then Make_Line /= null
           and then Make_Shader (Item.Logical, Shader'Address, Null_Handle, Made'Access) = 0
         then
            Item.Reference_GSQ_Shader := Made;
            Request.Stage.Module := Made; Request.Stage.Name := Name; Request.Layout := Item.Layout;
            if Make_Line (Item.Logical, Null_Handle, 1, Request'Address, Null_Handle, Made'Access) = 0 then
               Item.Reference_GSQ_Line := Made;
            end if;
         end if;
         C.Strings.Free (Name);
      end;
   end if;

   Item.Slice := Slice;
   Item.Patience := Patience;
   Ready := True;
exception
   when others =>
      Close (Item);
      raise;
end Open;
