package body Model_Runner.Llama.Execution_Schedules is

   package E renames Model_Runner.Errors;

   procedure Build
     (Layer_Count : Natural;
      Item        : out Schedule;
      Status      : out E.Error_Info;
      Max_Steps   : Natural := Max_Block_Count)
   is
   begin
      Build (Layer_Count, (0, Layer_Count, 1), Item, Status, Max_Steps);
   end Build;

   procedure Build
     (Layer_Count   : Natural;
      Configuration : Loop_Configuration;
      Item          : out Schedule;
      Status        : out E.Error_Info;
      Max_Steps     : Natural := Max_Block_Count)
   is
      Bound : constant Natural := Natural'Min (Max_Steps, Max_Block_Count);
      Width : Natural;
      Total : Natural;
      Next  : Natural := 0;

      procedure Append_Step (Physical, State : Natural; Visit : Positive) is
      begin
         Item.Steps (Next) := (Physical, Visit, Next, State);
         Next := Next + 1;
      end Append_Step;
   begin
      Item := (others => <>);
      if Layer_Count = 0 or else Layer_Count > Bound then
         Status := E.Make (E.Arch_Invalid_Metadata);
         E.Add_Text (Status, "key", "execution_schedule.layer_count");
         return;
      end if;
      if Configuration.First_Layer >= Configuration.End_Layer
        or else Configuration.End_Layer > Layer_Count
      then
         Status := E.Make (E.Arch_Invalid_Metadata);
         E.Add_Text (Status, "key", "execution_schedule.loop_region");
         return;
      end if;

      Width := Configuration.End_Layer - Configuration.First_Layer;
      --  Check before multiplying. Even Positive'Last passes must be refused
      --  without overflow, allocation or a walk through the requested visits.
      if Configuration.Iteration_Count - 1 > (Bound - Layer_Count) / Width then
         Status := E.Make (E.Arch_Invalid_Metadata);
         E.Add_Text (Status, "key", "execution_schedule.logical_count");
         return;
      end if;
      Total := Layer_Count + (Configuration.Iteration_Count - 1) * Width;

      for Physical in 0 .. Configuration.First_Layer - 1 loop
         Append_Step (Physical, Physical, 1);
      end loop;
      for Visit in 1 .. Configuration.Iteration_Count loop
         for Physical in Configuration.First_Layer .. Configuration.End_Layer - 1 loop
            Append_Step
              (Physical,
               (if Visit = 1 then Physical
                else Layer_Count + (Visit - 2) * Width + Physical - Configuration.First_Layer),
               Visit);
         end loop;
      end loop;
      for Physical in Configuration.End_Layer .. Layer_Count - 1 loop
         Append_Step (Physical, Physical, 1);
      end loop;
      Item.Count := Total;
      Status := E.Success;
   end Build;

   function Length (Item : Schedule) return Natural is (Item.Count);

   procedure Resolve
     (Item          : Schedule;
      Logical_Layer : Natural;
      Step          : out Execution_Step;
      Status        : out E.Error_Info)
   is
   begin
      Step := (others => <>);
      if Logical_Layer >= Item.Count then
         Status := E.Make (E.Arch_Invalid_Metadata);
         E.Add_Text (Status, "key", "execution_schedule.logical_layer");
         return;
      end if;
      Step := Item.Steps (Logical_Layer);
      Status := E.Success;
   end Resolve;

end Model_Runner.Llama.Execution_Schedules;
