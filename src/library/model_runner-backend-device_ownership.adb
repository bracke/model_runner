package body Model_Runner.Backend.Device_Ownership is

   use type Interfaces.Unsigned_64;

   protected body Guard is
      procedure Claim_Ordinary (Granted : out Boolean) is
      begin
         Granted := State /= Exclusive_Owner;
         if Granted and then State = No_Owner then
            State := Ordinary_Owner;
         end if;
      end Claim_Ordinary;

      procedure Claim_Exclusive
        (Granted : out Boolean;
         Token   : out Interfaces.Unsigned_64) is
      begin
         Granted := State = No_Owner;
         Token := 0;
         if Granted then
            State := Exclusive_Owner;
            Held_Token := Next_Token;
            Token := Held_Token;
            Next_Token := Next_Token + 1;
            if Next_Token = 0 then
               Next_Token := 1;
            end if;
         end if;
      end Claim_Exclusive;

      procedure Release_Ordinary is
      begin
         if State = Ordinary_Owner then
            State := No_Owner;
         end if;
      end Release_Ordinary;

      procedure Release_Exclusive
        (Token    : Interfaces.Unsigned_64;
         Released : out Boolean) is
      begin
         Released := State = Exclusive_Owner
           and then Token /= 0
           and then Token = Held_Token;
         if Released then
            State := No_Owner;
            Held_Token := 0;
         end if;
      end Release_Exclusive;

      function Is_Exclusive return Boolean is
        (State = Exclusive_Owner);

      function Owns_Exclusive
        (Token : Interfaces.Unsigned_64) return Boolean is
        (State = Exclusive_Owner
         and then Token /= 0
         and then Token = Held_Token);
   end Guard;

   procedure Claim_Ordinary
     (Item    : in out Coordinator;
      Granted : out Boolean) is
   begin
      Item.Control.Claim_Ordinary (Granted);
   end Claim_Ordinary;

   procedure Claim_Exclusive
     (Item      : in out Coordinator;
      Granted   : out Boolean;
      Authority : out Lease) is
   begin
      Authority.Token := 0;
      Item.Control.Claim_Exclusive (Granted, Authority.Token);
   end Claim_Exclusive;

   procedure Release_Ordinary (Item : in out Coordinator) is
   begin
      Item.Control.Release_Ordinary;
   end Release_Ordinary;

   procedure Release_Exclusive
     (Item      : in out Coordinator;
      Authority : in out Lease;
      Released  : out Boolean) is
   begin
      Item.Control.Release_Exclusive (Authority.Token, Released);
      Authority.Token := 0;
   end Release_Exclusive;

   function Is_Exclusive (Item : Coordinator) return Boolean is
     (Item.Control.Is_Exclusive);

   function Owns_Exclusive
     (Item      : Coordinator;
      Authority : Lease) return Boolean
   is (Item.Control.Owns_Exclusive (Authority.Token));

end Model_Runner.Backend.Device_Ownership;
