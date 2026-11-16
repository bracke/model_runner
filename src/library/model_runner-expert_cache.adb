with Ada.Unchecked_Deallocation;

package body Model_Runner.Expert_Cache is

   use type Interfaces.Unsigned_64;

   --  Scores carry ten fractional bits.  Their half-life is 128 routing
   --  observations, following the useful part of llama.cpp's LRFU policy
   --  while keeping the decision bit-for-bit deterministic on every host.
   Point          : constant Interfaces.Unsigned_64 := 2 ** 10;
   Half_Life      : constant Interfaces.Unsigned_64 := 128;
   Maximum_Points : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last - Point;

   procedure Release is new Ada.Unchecked_Deallocation
     (Entry_Array, Entry_Array_Access);

   function Position_Of
     (Item : Policy; Layer : Natural; Expert : Natural) return Natural
   is (Layer * Item.Experts + Expert);

   function Valid
     (Item : Policy; Layer : Natural; Expert : Natural) return Boolean
   is (Item.Entries /= null
       and then Layer < Item.Layers
       and then Expert < Item.Experts);

   function Decayed
     (Item : Policy; Value : Cache_Entry) return Interfaces.Unsigned_64
   is
      Age    : constant Interfaces.Unsigned_64 := Item.Clock - Value.Seen_At;
      Halves : constant Interfaces.Unsigned_64 := Age / Half_Life;
   begin
      if Halves >= 64 then
         return 0;
      end if;
      return Interfaces.Shift_Right (Value.Points, Natural (Halves));
   end Decayed;

   -----------
   -- Clear --
   -----------

   procedure Clear (Item : in out Policy) is
   begin
      if Item.Entries /= null then
         Release (Item.Entries);
      end if;
      Item.Layers := 0;
      Item.Experts := 0;
      Item.Capacity := 0;
      Item.Clock := 0;
      Item.Counts := (others => 0);
   end Clear;

   ---------------
   -- Configure --
   ---------------

   procedure Configure
     (Item     : in out Policy;
      Layers   : Natural;
      Experts  : Natural;
      Capacity : Natural)
   is
      Count : Natural;
   begin
      Clear (Item);
      if Layers = 0 or else Experts = 0 then
         return;
      end if;
      if Layers > Natural'Last / Experts then
         return;
      end if;
      Count := Layers * Experts;
      Item.Layers := Layers;
      Item.Experts := Experts;
      Item.Capacity := Natural'Min (Capacity, Experts);
      Item.Entries := new Entry_Array'(0 .. Count - 1 => (others => <>));
   end Configure;

   ------------------------
   -- Current_Statistics --
   ------------------------

   function Current_Statistics (Item : Policy) return Statistics
   is (Item.Counts);

   ------------------------
   -- Capacity_Per_Layer --
   ------------------------

   function Capacity_Per_Layer (Item : Policy) return Natural
   is (Item.Capacity);

   ------------------
   -- Expert_Count --
   ------------------

   function Expert_Count (Item : Policy) return Natural is (Item.Experts);

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Policy) is
   begin
      Clear (Item);
   end Finalize;

   -----------------
   -- Is_Resident --
   -----------------

   function Is_Resident
     (Item : Policy; Layer : Natural; Expert : Natural) return Boolean
   is (Valid (Item, Layer, Expert)
       and then Item.Entries (Position_Of (Item, Layer, Expert)).Resident);

   -----------------
   -- Layer_Count --
   -----------------

   function Layer_Count (Item : Policy) return Natural is (Item.Layers);

   -------------
   -- Observe --
   -------------

   procedure Observe
     (Item    : in out Policy;
      Layer   : Natural;
      Expert  : Natural;
      Outcome : out Observation_Outcome)
   is
      Resident_Count : Natural := 0;
      Victim         : Natural := 0;
      Have_Victim    : Boolean := False;
      Victim_Score   : Interfaces.Unsigned_64 := 0;
      Victim_Seen    : Interfaces.Unsigned_64 := 0;
   begin
      Item.Counts.Observations := Item.Counts.Observations + 1;
      Item.Clock := Item.Clock + 1;
      Outcome := Cache_Miss;

      if not Valid (Item, Layer, Expert) then
         Item.Counts.Misses := Item.Counts.Misses + 1;
         return;
      end if;

      declare
         Selected : Cache_Entry renames
           Item.Entries (Position_Of (Item, Layer, Expert));
         Old      : constant Interfaces.Unsigned_64 := Decayed (Item, Selected);
      begin
         Selected.Points :=
           (if Old > Maximum_Points then Interfaces.Unsigned_64'Last
            else Old + Point);
         Selected.Seen_At := Item.Clock;

         if Selected.Resident then
            Item.Counts.Hits := Item.Counts.Hits + 1;
            Outcome := Cache_Hit;
            return;
         end if;
      end;

      Item.Counts.Misses := Item.Counts.Misses + 1;
      if Item.Capacity = 0 then
         return;
      end if;

      for Which in 0 .. Item.Experts - 1 loop
         declare
            Candidate : Cache_Entry renames
              Item.Entries (Position_Of (Item, Layer, Which));
         begin
            if Candidate.Resident then
               Resident_Count := Resident_Count + 1;
               declare
                  Candidate_Score : constant Interfaces.Unsigned_64 :=
                    Decayed (Item, Candidate);
               begin
                  if not Have_Victim
                    or else Candidate_Score < Victim_Score
                    or else (Candidate_Score = Victim_Score
                             and then Candidate.Seen_At < Victim_Seen)
                    or else (Candidate_Score = Victim_Score
                             and then Candidate.Seen_At = Victim_Seen
                             and then Which < Victim)
                  then
                     Victim := Which;
                     Victim_Score := Candidate_Score;
                     Victim_Seen := Candidate.Seen_At;
                     Have_Victim := True;
                  end if;
               end;
            end if;
         end;
      end loop;

      declare
         Selected : Cache_Entry renames
           Item.Entries (Position_Of (Item, Layer, Expert));
      begin
         if Resident_Count < Item.Capacity
           or else (Have_Victim and then Decayed (Item, Selected) > Victim_Score)
         then
            if Resident_Count >= Item.Capacity then
               Item.Entries (Position_Of (Item, Layer, Victim)).Resident := False;
               Item.Counts.Evictions := Item.Counts.Evictions + 1;
            end if;
            Selected.Resident := True;
            Item.Counts.Promotions := Item.Counts.Promotions + 1;
            Outcome := Promote;
         end if;
      end;
   end Observe;

   -----------
   -- Score --
   -----------

   function Score
     (Item : Policy; Layer : Natural; Expert : Natural)
      return Interfaces.Unsigned_64
   is
   begin
      if not Valid (Item, Layer, Expert) then
         return 0;
      end if;
      return Decayed
        (Item, Item.Entries (Position_Of (Item, Layer, Expert)));
   end Score;

end Model_Runner.Expert_Cache;
