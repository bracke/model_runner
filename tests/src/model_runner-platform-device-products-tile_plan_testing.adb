with Model_Runner.Platform.Device.Tile_Plans;

package body Model_Runner.Platform.Device.Products.Tile_Plan_Testing is

   package Tiles renames Model_Runner.Platform.Device.Tile_Plans;

   procedure Exercise
     (Narrow_Width       : out Positive;
      Mid_Width          : out Positive;
      Mid_Wide_Width     : out Positive;
      Wide_Width         : out Positive;
      Narrowed_Wide      : out Positive;
      Other_Default      : out Positive;
      First_Keeps_Routes : out Boolean;
      Other_Keeps_Routes : out Boolean)
   is
      First : Engine;
      Other : Engine;
   begin
      First.Tile_Plan.Mid_Ready := True;
      First.Tile_Plan.Mid_Wide_Ready := True;
      First.Tile_Plan.Wider_Ready := True;

      Narrow_Width := Tiles.Width (True, True, True, False, 22);
      Mid_Width := Tiles.Width (True, True, True, False, 48);
      Mid_Wide_Width := Tiles.Width (True, True, True, False, 80);
      Wide_Width := Tiles.Width (True, True, True, False, 400);

      First.Tile_Plan.Narrow_Run := True;
      Narrowed_Wide := Tiles.Width (True, True, True, True, 400);
      Other_Default := Tiles.Width
        (Other.Tile_Plan.Mid_Ready, Other.Tile_Plan.Mid_Wide_Ready,
         Other.Tile_Plan.Wider_Ready, Other.Tile_Plan.Narrow_Run, 80);

      First.Tile_Plan.Route_Keeps := True;
      First_Keeps_Routes := First.Tile_Plan.Route_Keeps;
      Other_Keeps_Routes := Other.Tile_Plan.Route_Keeps;

      --  Exercise the predicates directly so their boundary behavior is
      --  independently checked rather than inferred from a Vulkan result.
      if not Tiles.Narrowed (22)
        or else not Tiles.Midway (True, 48)
        or else not Tiles.Mid_Widely (True, True, 80)
        or else Tiles.Widened (True, True, 400)
      then
         raise Program_Error with "inconsistent tile predicates";
      end if;
   end Exercise;

end Model_Runner.Platform.Device.Products.Tile_Plan_Testing;
