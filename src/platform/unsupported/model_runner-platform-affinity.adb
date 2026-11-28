package body Model_Runner.Platform.Affinity is
   function Choose (Count : Positive) return Core_List is ([0 .. Count - 1 => -1]);
   procedure Pin (Item : in out Binding; Processor : Integer) is
      pragma Unreferenced (Item, Processor);
   begin
      null;
   end Pin;
   overriding procedure Finalize (Item : in out Binding) is
      pragma Unreferenced (Item);
   begin
      null;
   end Finalize;
end Model_Runner.Platform.Affinity;
