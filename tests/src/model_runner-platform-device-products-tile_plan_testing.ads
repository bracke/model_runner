--  Test-only view of the tile policy held privately by each product engine.
package Model_Runner.Platform.Device.Products.Tile_Plan_Testing is

   --  Exercise tile selection and the isolation of two engine policies.
   --  @param Narrow_Width Width selected for a narrow batch.
   --  @param Mid_Width Width selected for a mid-sized batch.
   --  @param Mid_Wide_Width Width selected for a mid-wide batch.
   --  @param Wide_Width Width selected for a wide batch.
   --  @param Narrowed_Wide Width selected when a wide batch is disallowed.
   --  @param Other_Default Width of an untouched second engine.
   --  @param First_Keeps_Routes Route policy of the changed engine.
   --  @param Other_Keeps_Routes Route policy of the untouched engine.
   procedure Exercise
     (Narrow_Width       : out Positive;
      Mid_Width          : out Positive;
      Mid_Wide_Width     : out Positive;
      Wide_Width         : out Positive;
      Narrowed_Wide      : out Positive;
      Other_Default      : out Positive;
      First_Keeps_Routes : out Boolean;
      Other_Keeps_Routes : out Boolean);

end Model_Runner.Platform.Device.Products.Tile_Plan_Testing;
