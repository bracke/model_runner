with Interfaces;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Errors;
private with Ada.Finalization;

--  A bounded output-projection LoRA optimizer. The transformer remains frozen.
package Learning_Lora is
   package N renames Model_Runner.Numerics;
   package E renames Model_Runner.Errors;
   type Adapter is tagged limited private;
   type Dimensions is record
      Width, Vocabulary, Rank : Natural := 0;
   end record;
   --  @param Item Adapter to initialize, releasing previous storage.
   --  @param Shape Bounded matrix geometry, at most eight million factor elements.
   --  @param Seed Deterministic initialization seed; zero is mapped to one.
   --  @param Status Success, shape, finite-value or allocation diagnostic.
   procedure Initialize
     (Item : in out Adapter; Shape : Dimensions; Seed : Interfaces.Unsigned_64; Status : out E.Error_Info);
   --  @param Item Adapter whose owned storage is released.
   procedure Clear (Item : in out Adapter);
   --  @param Item Initialized adapter.
   --  @return Factor geometry, all zero when uninitialized.
   function Shape (Item : Adapter) return Dimensions;
   --  @param Item Initialized adapter.
   --  @param Down Row-major rank by width factor.
   --  @param Up Row-major vocabulary by rank factor.
   --  @param Status Success or shape diagnostic.
   procedure Get_Factors (Item : Adapter; Down, Up : out N.Real_Array; Status : out E.Error_Info);
   --  @param Item Adapter receiving finite factors of magnitude at most 1,000; optimizer state is reset.
   --  @param Down Rank by width factor.
   --  @param Up Vocabulary by rank factor.
   --  @param Status Success, shape or finite-value diagnostic; failure preserves factors.
   procedure Set_Factors (Item : in out Adapter; Down, Up : N.Real_Array; Status : out E.Error_Info);
   --  @param Item Adapter whose pending gradients are cleared.
   procedure Begin_Batch (Item : in out Adapter);
   --  @param Item Adapter to score and optionally differentiate.
   --  @param Hidden Frozen normalized transformer state, magnitude at most one million.
   --  @param Base Frozen vocabulary logits at that position.
   --  @param Target Next assistant token, zero based.
   --  @param Differentiate Add this example's exact cross-entropy gradient to the pending batch.
   --  @param Loss Stable full-vocabulary cross-entropy in natural logarithms.
   --  @param Status Success, shape or finite-value diagnostic.
   procedure Observe
     (Item : in out Adapter; Hidden, Base : N.Real_Array; Target : Natural;
      Differentiate : Boolean; Loss : out N.Wide_Real; Status : out E.Error_Info);
   --  @param Item Adapter with a nonempty pending batch.
   --  @param Down Accumulated, unaveraged gradient of the down factor.
   --  @param Up Accumulated, unaveraged gradient of the up factor.
   --  @param Status Success or lifecycle/shape diagnostic.
   procedure Gradients (Item : Adapter; Down, Up : out N.Real_Array; Status : out E.Error_Info);
   --  @param Item Adapter updated by one Adam step, then its pending batch cleared.
   --  @param Rate Positive learning rate, at most 0.01.
   --  @param Clip Positive maximum averaged gradient norm, at most 100.
   --  @param Status Success or bounded-input diagnostic.
   procedure Step (Item : in out Adapter; Rate, Clip : N.Real; Status : out E.Error_Info);
private
   type Factor is record
      Values, Gradient, Mean, Square : Model_Runner.Tensors.Real_Array_Access := null;
   end record;
   type Adapter is new Ada.Finalization.Limited_Controlled with record
      Geometry : Dimensions;
      Down, Up : Factor;
      Scores : Model_Runner.Tensors.Real_Array_Access := null;
      Samples, Steps : Natural := 0;
   end record;
   overriding procedure Finalize (Item : in out Adapter);
end Learning_Lora;
