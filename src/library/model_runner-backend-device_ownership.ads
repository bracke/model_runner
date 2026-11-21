with Interfaces;

--  Ownership of the process-global device, apart from opening hardware.
--
--  Kept as a small state machine so lease authority can be tested on hosts
--  without a compute device.  It does not make device work task-safe: the
--  backend remains a one-task interface.  It prevents an embedded exclusive
--  session and an ordinary global caller from disrupting one another.
package Model_Runner.Backend.Device_Ownership is

   type Coordinator is limited private;
   type Lease is private;

   --  Claim the ordinary global interface. Repeated claims by its documented
   --  single task are allowed; an exclusive owner refuses them.
   --
   --  @param Item Coordinator guarding one process-global device.
   --  @param Granted True unless an exclusive lease is held.
   procedure Claim_Ordinary
     (Item    : in out Coordinator;
      Granted : out Boolean);

   --  Claim the device for one exclusive owner.
   --
   --  @param Item Coordinator guarding one process-global device.
   --  @param Granted True only when no owner existed.
   --  @param Authority Lease identifying this acquisition, invalid on refusal.
   procedure Claim_Exclusive
     (Item      : in out Coordinator;
      Granted   : out Boolean;
      Authority : out Lease);

   --  Release an ordinary claim, when one exists.
   --
   --  @param Item Coordinator guarding one process-global device.
   procedure Release_Ordinary (Item : in out Coordinator);

   --  Release the acquisition identified by Authority. A stale lease is
   --  invalidated but cannot release a later acquisition.
   --
   --  @param Item Coordinator guarding one process-global device.
   --  @param Authority Lease to consume, valid or stale.
   --  @param Released True only when Authority owned the current acquisition.
   procedure Release_Exclusive
     (Item      : in out Coordinator;
      Authority : in out Lease;
      Released  : out Boolean);

   --  @param Item Coordinator to inspect.
   --  @return True while an exclusive acquisition is held.
   function Is_Exclusive (Item : Coordinator) return Boolean;

   --  @param Item Coordinator to inspect.
   --  @param Authority Lease to compare with the current acquisition.
   --  @return True only when Authority owns Item now.
   function Owns_Exclusive
     (Item      : Coordinator;
      Authority : Lease) return Boolean;

private

   type Ownership_State is (No_Owner, Ordinary_Owner, Exclusive_Owner);

   protected type Guard is
      procedure Claim_Ordinary (Granted : out Boolean);
      procedure Claim_Exclusive
        (Granted : out Boolean;
         Token   : out Interfaces.Unsigned_64);
      procedure Release_Ordinary;
      procedure Release_Exclusive
        (Token    : Interfaces.Unsigned_64;
         Released : out Boolean);
      function Is_Exclusive return Boolean;
      function Owns_Exclusive
        (Token : Interfaces.Unsigned_64) return Boolean;
   private
      State      : Ownership_State := No_Owner;
      Next_Token : Interfaces.Unsigned_64 := 1;
      Held_Token : Interfaces.Unsigned_64 := 0;
   end Guard;

   type Coordinator is limited record
      Control : Guard;
   end record;

   type Lease is record
      Token : Interfaces.Unsigned_64 := 0;
   end record;

end Model_Runner.Backend.Device_Ownership;
