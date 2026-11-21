package body Model_Runner.Platform.Device.Tile_Plans is

   Narrow_Vectors   : constant := 32;
   Narrow_Limit     : constant := Narrow_Vectors;
   Mid_Vectors      : constant := 64;
   Wider_Least      : constant := 224;

   function Narrowed (Count : Natural) return Boolean
   is (Count <= Narrow_Limit);

   function Midway
     (Ready : Boolean;
      Count : Natural) return Boolean
   is (Ready
       and then not Narrowed (Count)
       and then Count <= Mid_Vectors);

   function Mid_Widely
     (Mid_Ready  : Boolean;
      Wide_Ready : Boolean;
      Count : Natural) return Boolean
   is (Wide_Ready
       and then not Narrowed (Count)
       and then not Midway (Mid_Ready, Count)
       and then Count <= Mid_Wide_Vectors);

   function Widened
     (Ready      : Boolean;
      Narrow_Run : Boolean;
      Count : Natural) return Boolean
   is (Ready
       and then not Narrow_Run
       and then Count > Wider_Least);

   function Width
     (Mid_Ready      : Boolean;
      Mid_Wide_Ready : Boolean;
      Wider_Ready    : Boolean;
      Narrow_Run     : Boolean;
      Count : Natural) return Positive
   is (if Narrowed (Count) then Narrow_Vectors
       elsif Midway (Mid_Ready, Count) then Mid_Vectors
       elsif Mid_Widely (Mid_Ready, Mid_Wide_Ready, Count)
       then Mid_Wide_Vectors
       elsif Widened (Wider_Ready, Narrow_Run, Count) then Wider_Vectors
       else Default_Vectors);

end Model_Runner.Platform.Device.Tile_Plans;
