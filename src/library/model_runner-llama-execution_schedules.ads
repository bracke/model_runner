with Model_Runner.Errors;

--  Bounded execution order, separate from physical weight ownership.
--  This package describes visits only; adapters supply activation and message
--  dependencies. A state slot owns neither weights nor session allocations.
package Model_Runner.Llama.Execution_Schedules is

   --  All identities are zero based except Visit, which starts at one.
   --  State_Layer preserves physical slots on the first visit and appends
   --  separate slots for later visits, including their convolution history.
   type Execution_Step is record
      Physical_Layer : Natural := 0;
      Visit          : Positive := 1;
      Logical_Layer  : Natural := 0;
      State_Layer    : Natural := 0;
   end record;

   --  Repeat [First_Layer, End_Layer); the end is exclusive.
   --  Model-specific restrictions belong in the architecture adapter.
   type Loop_Configuration is record
      First_Layer     : Natural := 0;
      End_Layer       : Natural := 0;
      Iteration_Count : Positive := 1;
   end record;

   type Schedule is private;

   --  Construct a single-pass order with one state slot per physical layer.
   --
   --  @param Layer_Count Number of physical layers, nonzero and bounded.
   --  @param Item Result, empty on failure.
   --  @param Status Arch_Invalid_Metadata with key when the count is invalid.
   --  @param Max_Steps Additional caller limit on logical steps and state slots.
   procedure Build
     (Layer_Count : Natural;
      Item        : out Schedule;
      Status      : out Model_Runner.Errors.Error_Info;
      Max_Steps   : Natural := Max_Block_Count);

   --  Construct prelude, repeated region, epilogue without copying weights.
   --
   --  @param Layer_Count Number of physical layers, nonzero and bounded.
   --  @param Configuration Half-open loop region and visit count.
   --  @param Item Result, empty on failure, including after a previous success.
   --  @param Status Arch_Invalid_Metadata with key for an invalid region
   --    or a physical or logical count over the bound.
   --  @param Max_Steps Additional caller limit on logical steps and state slots.
   procedure Build
     (Layer_Count   : Natural;
      Configuration : Loop_Configuration;
      Item          : out Schedule;
      Status        : out Model_Runner.Errors.Error_Info;
      Max_Steps     : Natural := Max_Block_Count);

   --  Number of logical steps, also the number of independently owned slots.
   --
   --  @param Item Schedule to inspect.
   --  @return Zero for an unbuilt or rejected schedule.
   function Length (Item : Schedule) return Natural;

   --  Resolve one logical identity; an empty or out-of-range order is refused.
   --
   --  @param Item Schedule to inspect.
   --  @param Logical_Layer Zero-based execution position.
   --  @param Step Resolved identities, cleared on failure.
   --  @param Status Arch_Invalid_Metadata with key when the position does not exist.
   procedure Resolve
     (Item          : Schedule;
      Logical_Layer : Natural;
      Step          : out Execution_Step;
      Status        : out Model_Runner.Errors.Error_Info);

private

   type Step_Array is array (0 .. Max_Block_Count - 1) of Execution_Step;

   type Schedule is record
      Count : Natural := 0;
      Steps : Step_Array := [others => <>];
   end record;

end Model_Runner.Llama.Execution_Schedules;
