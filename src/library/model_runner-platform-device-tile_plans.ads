--  Tile-width policy for device matrix products.
--
--  Kept apart from the Vulkan engine so the measured thresholds and their
--  selection rules have one owner.  The device-products body supplies
--  only facts learned while pipelines are opened and facts about the current
--  product; this package decides which compiled tile width applies.
private package Model_Runner.Platform.Device.Tile_Plans is

   Default_Vectors  : constant := 128;
   Mid_Wide_Vectors : constant := 96;
   Wider_Vectors    : constant := 256;

   --  @param Count Number of vectors in the batch.
   --  @return Whether the narrow tile applies.
   function Narrowed (Count : Natural) return Boolean;

   --  @param Ready Whether the sixty-four-vector family is available.
   --  @param Count Number of vectors in the batch.
   --  @return Whether the sixty-four-vector tile applies.
   function Midway
     (Ready : Boolean;
      Count : Natural) return Boolean;

   --  @param Mid_Ready Whether the sixty-four-vector family is available.
   --  @param Wide_Ready Whether the ninety-six-vector family is available.
   --  @param Count Number of vectors in the batch.
   --  @return Whether the ninety-six-vector tile applies.
   function Mid_Widely
     (Mid_Ready  : Boolean;
      Wide_Ready : Boolean;
      Count : Natural) return Boolean;

   --  @param Ready Whether the 256-vector family is available.
   --  @param Narrow_Run Whether this product excludes that family.
   --  @param Count Number of vectors in the batch.
   --  @return Whether the 256-vector tile applies.
   function Widened
     (Ready      : Boolean;
      Narrow_Run : Boolean;
      Count : Natural) return Boolean;

   --  @param Mid_Ready Whether the sixty-four-vector family is available.
   --  @param Mid_Wide_Ready Whether the ninety-six-vector family is available.
   --  @param Wider_Ready Whether the 256-vector family is available.
   --  @param Narrow_Run Whether this product excludes the widest family.
   --  @param Count Number of vectors in the batch.
   --  @return Width of the selected compiled tile.
   function Width
     (Mid_Ready      : Boolean;
      Mid_Wide_Ready : Boolean;
      Wider_Ready    : Boolean;
      Narrow_Run     : Boolean;
      Count : Natural) return Positive;

end Model_Runner.Platform.Device.Tile_Plans;
