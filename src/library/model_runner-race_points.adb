package body Model_Runner.Race_Points is

   Armed : array (Point) of Action := [others => null];

   procedure Arm (Where : Point; Then_Do : not null Action) is
   begin
      Armed (Where) := Then_Do;
   end Arm;

   procedure Here (Where : Point) is
      Doing : constant Action := Armed (Where);
   begin
      if Doing /= null then
         --  Let go first: what it does may pass the point again.
         Armed (Where) := null;
         Doing.all;
      end if;
   end Here;

end Model_Runner.Race_Points;
