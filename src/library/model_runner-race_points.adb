package body Model_Runner.Race_Points is

   type Action_Array is array (Point) of Action;

   protected Hooks is
      procedure Arm (Where : Point; Then_Do : not null Action);
      procedure Disarm (Where : Point);
      procedure Take (Where : Point; Doing : out Action);
   private
      Armed : Action_Array := [others => null];
   end Hooks;

   protected body Hooks is
      procedure Arm (Where : Point; Then_Do : not null Action) is
      begin
         Armed (Where) := Then_Do;
      end Arm;

      procedure Disarm (Where : Point) is
      begin
         Armed (Where) := null;
      end Disarm;

      procedure Take (Where : Point; Doing : out Action) is
      begin
         Doing := Armed (Where);
         Armed (Where) := null;
      end Take;
   end Hooks;

   procedure Arm (Where : Point; Then_Do : not null Action) is
   begin
      Hooks.Arm (Where, Then_Do);
   end Arm;

   procedure Disarm (Where : Point) is
   begin
      Hooks.Disarm (Where);
   end Disarm;

   procedure Here (Where : Point) is
      Doing : Action;
   begin
      --  Take atomically, but invoke outside the protected action: callbacks
      --  deliberately block to hold a race ordering in place.
      Hooks.Take (Where, Doing);
      if Doing /= null then
         Doing.all;
      end if;
   end Here;

end Model_Runner.Race_Points;
