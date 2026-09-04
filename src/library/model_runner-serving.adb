with Model_Runner.Limits;

package body Model_Runner.Serving is

   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package S renames Model_Runner.Sampling;
   package T renames Model_Runner.Tensors;
   package V renames Model_Runner.Tokenizer;

   use type E.Error_Code;
   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type V.Token_Id;

   --  Tokens a prompt is read in at once. What generation uses, and the
   --  reason is the same: a batch is bounded, and handing a whole long
   --  prompt to one call is asking for a shape the engine never promised.
   Prefill_Batch : constant := 128;

   ------------
   -- Open --
   ------------

   procedure Open
     (Item    : in out Server;
      Source  : in out Model_Runner.Llama.Model'Class;
      Workers : Model_Runner.Backend.CPU.Pool_Reference := null;
      Context : Natural := 0;
      Gather  : Positive := Default_Gather;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Settings : constant L.Configuration := L.Config (Source);
   begin
      Status := E.Success;

      if Item.Open_Now then
         Close (Item);
      end if;

      Item.Source := Source'Unchecked_Access;
      Item.Workers := Workers;
      Item.Context := Context;
      Item.Gather := Positive'Min (Gather, Item.Capacity);
      Item.Width := N.Element_Count (Settings.Vocabulary);

      --  One round's logits, a row a member, taken once. A server that
      --  allocated this a round would be allocating in the loop it exists
      --  to make cheap.
      T.Allocate (N.Element_Count (Item.Gather) * Item.Width, Item.Rows);

      if Item.Rows = null then
         Item.Source := null;
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      Item.Rounds_Made := 0;
      Item.Last_Round := 0;
      Item.Tokens_Made := 0;
      Item.Open_Now := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Server) is
      Ignored : E.Error_Info;
   begin
      for Which in Item.Seats'Range loop
         if Item.Seats (Which).State /= Free then
            L.Close (Item.Seats (Which).Session);
            S.Close (Item.Seats (Which).Sampler);
            Item.Seats (Which).State := Free;
            Item.Seats (Which).Held := 0;
            Item.Seats (Which).Total := 0;
            Item.Seats (Which).Why := Still_Going;
         end if;
      end loop;

      T.Free (Item.Rows);
      Item.Source := null;
      Item.Open_Now := False;
      pragma Unreferenced (Ignored);
   end Close;

   --  Whether a token ends this member.
   function Stops_Here (At_Seat : Seat; Token : Token_Id) return Boolean is
   begin
      for Stop of At_Seat.Terms.Stops loop
         if Stop /= V.No_Token and then Stop = Token then
            return True;
         end if;
      end loop;

      return False;
   end Stops_Here;

   --  Say a token on this member's behalf, and decide whether it goes on.
   --
   --  Room is what is left of the member's context. A member that has filled
   --  it is finished whatever its limit said, because the next round would
   --  have nowhere to put the position.
   procedure Say (At_Seat : in out Seat; Token : Token_Id; Room : Natural) is
   begin
      if At_Seat.Held < At_Seat.Said'Length then
         At_Seat.Held := At_Seat.Held + 1;
         At_Seat.Said (At_Seat.Held) := Token;
      end if;

      At_Seat.Total := At_Seat.Total + 1;
      S.Record_Token (At_Seat.Sampler, Token);

      if Stops_Here (At_Seat, Token) then
         At_Seat.Why := Reached_A_Stop;
      elsif At_Seat.Terms.Limit > 0
        and then At_Seat.Total >= At_Seat.Terms.Limit
      then
         At_Seat.Why := Reached_Its_Limit;
      elsif Room = 0 then
         At_Seat.Why := Filled_The_Context;
      end if;
   end Say;

   ------------
   -- Admit --
   ------------

   procedure Admit
     (Item       : in out Server;
      Prompt     : Token_Array;
      With_Terms : Terms;
      Who        : out Member_Id;
      Cancel     : Model_Runner.Cancellation.Token_Reference := null;
      Status     : out Model_Runner.Errors.Error_Info)
   is
      Free_Seat : Natural := 0;
   begin
      Who := No_Member;
      Status := E.Success;

      if not Item.Open_Now or else Item.Source = null then
         Status := E.Make (E.Lifecycle_Session_Closed);
         return;
      end if;

      if Prompt'Length = 0 then
         Status := E.Make (E.Generation_Empty_Prompt);
         return;
      end if;

      for Which in Item.Seats'Range loop
         if Item.Seats (Which).State = Free then
            Free_Seat := Which;
            exit;
         end if;
      end loop;

      --  A full server is not a failure of the caller's request, and saying
      --  so by name is what lets one wait rather than guess.
      if Free_Seat = 0 then
         Status := E.Make (E.Generation_Batch_Too_Large);
         E.Add_Integer (Status, "capacity", Long_Long_Integer (Item.Capacity));
         return;
      end if;

      declare
         Seat_Here : Seat renames Item.Seats (Free_Seat);
         Settings  : constant L.Configuration := L.Config (Item.Source.all);
      begin
         Seat_Here.Terms := With_Terms;

         L.Open
           (Seat_Here.Session, Item.Source.all,
            Context => Item.Context,
            Session_Bounds => Model_Runner.Limits.Default_Session_Limits,
            Workers => Item.Workers,
            Status => Status);

         if E.Is_Error (Status) then
            return;
         end if;

         S.Open
           (Seat_Here.Sampler, With_Terms.Sampling,
            Settings.Vocabulary, With_Terms.Seed, Status);

         if E.Is_Error (Status) then
            L.Close (Seat_Here.Session);
            return;
         end if;

         --  The prompt, in batches. Only the last batch's distribution is
         --  wanted, which is what the engine gives back either way.
         declare
            Aside : T.Real_Array_Access := null;
            At_Token : Natural := Prompt'First;
         begin
            T.Allocate (Item.Width, Aside);

            if Aside = null then
               S.Close (Seat_Here.Sampler);
               L.Close (Seat_Here.Session);
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;

            while At_Token <= Prompt'Last loop
               declare
                  Upto : constant Natural :=
                    Natural'Min (At_Token + Prefill_Batch - 1, Prompt'Last);
               begin
                  L.Evaluate_Batch
                    (Seat_Here.Session, Item.Source.all,
                     Prompt (At_Token .. Upto), Aside.all,
                     Cancel => Cancel, Status => Status);

                  exit when E.Is_Error (Status);
                  At_Token := Upto + 1;
               end;
            end loop;

            if E.Is_Error (Status) then
               T.Free (Aside);
               S.Close (Seat_Here.Sampler);
               L.Close (Seat_Here.Session);
               return;
            end if;

            --  The first token this member will say, through its own
            --  sampler: a member joins a round with something to
            --  contribute rather than with a prompt to catch up on.
            S.Sample (Seat_Here.Sampler, Aside.all, Seat_Here.Next, Status);
            T.Free (Aside);

            if E.Is_Error (Status) then
               S.Close (Seat_Here.Sampler);
               L.Close (Seat_Here.Session);
               return;
            end if;
         end;

         Seat_Here.State := Running;
         Seat_Here.Why := Still_Going;
         Seat_Here.Held := 0;
         Seat_Here.Total := 0;

         --  That first token is the member's first output, not a spare: it
         --  is what the prompt produced, and a caller reading this member
         --  wants it. It goes into a round as well, which is where the
         --  model reads it -- said once here and read once there.
         Say (Seat_Here, Seat_Here.Next,
              Room =>
                L.Capacity (Seat_Here.Session)
                - L.Position (Seat_Here.Session));

         Item.Tokens_Made := Item.Tokens_Made + 1;
         Who := Member_Id (Free_Seat);
      end;
   end Admit;

   ----------
   -- Step --
   ----------

   procedure Step
     (Item   : in out Server;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Status : out Model_Runner.Errors.Error_Info)
   is
      --  Which seats are in this round, in the order they were found. The
      --  order is the members' order everywhere below: the tokens go in it
      --  and the rows come back in it.
      Chosen : array (1 .. Item.Gather) of Natural := [others => 0];
      Taken  : Natural := 0;
   begin
      Status := E.Success;
      Item.Last_Round := 0;

      if not Item.Open_Now or else Item.Source = null then
         Status := E.Make (E.Lifecycle_Session_Closed);
         return;
      end if;

      for Which in Item.Seats'Range loop
         exit when Taken = Item.Gather;

         if Item.Seats (Which).State = Running
           and then Item.Seats (Which).Why = Still_Going
         then
            Taken := Taken + 1;
            Chosen (Taken) := Which;
         end if;
      end loop;

      if Taken = 0 then
         return;
      end if;

      declare
         Group  : L.Session_Group (1 .. Taken);
         Tokens : V.Token_Array (1 .. Taken);
      begin
         for Row in 1 .. Taken loop
            Group (Row) :=
              Item.Seats (Chosen (Row)).Session'Unchecked_Access;
            Tokens (Row) := Item.Seats (Chosen (Row)).Next;
         end loop;

         L.Evaluate_Round
           (Members => Group, Source => Item.Source.all,
            Tokens => Tokens, Logits => Item.Rows,
            Cancel => Cancel, Status => Status);

         if E.Is_Error (Status) then
            --  A round that refused committed nothing, so every member of
            --  it is where it was. Retiring them is the honest answer: the
            --  refusal is about the pass, and a caller asked to retry a
            --  pass it cannot see is a caller asked to guess.
            for Row in 1 .. Taken loop
               Item.Seats (Chosen (Row)).Why := Refused;
            end loop;

            return;
         end if;

         Item.Rounds_Made := Item.Rounds_Made + 1;
         Item.Last_Round := Taken;

         for Row in 1 .. Taken loop
            declare
               Here : Seat renames Item.Seats (Chosen (Row));

               Base : constant N.Element_Count :=
                 N.Element_Count (Row - 1) * Item.Width;

               Token : Token_Id;
               Said  : E.Error_Info;
            begin
               S.Sample
                 (Here.Sampler,
                  Item.Rows.all (Base .. Base + Item.Width - 1),
                  Token, Said);

               if E.Is_Error (Said) then
                  Here.Why := Refused;

                  if not E.Is_Error (Status) then
                     Status := Said;
                  end if;
               else
                  Here.Next := Token;
                  Say (Here, Token,
                       Room =>
                         L.Capacity (Here.Session)
                         - L.Position (Here.Session));
                  Item.Tokens_Made := Item.Tokens_Made + 1;
               end if;
            end;
         end loop;
      end;
   end Step;

   ----------
   -- Take --
   ----------

   procedure Take
     (Item : in out Server;
      Who  : Member_Id;
      Into : out Token_Array;
      Last : out Natural;
      Done : out Boolean) is
   begin
      Last := 0;
      Done := True;

      if Who = No_Member
        or else Natural (Who) > Item.Capacity
        or else Item.Seats (Natural (Who)).State = Free
      then
         return;
      end if;

      declare
         Here : Seat renames Item.Seats (Natural (Who));
         Room : constant Natural :=
           Natural'Min (Here.Held, Into'Length);
      begin
         for Offset in 0 .. Room - 1 loop
            Into (Into'First + Offset) := Here.Said (Offset + 1);
         end loop;

         Last := Room;

         --  What was not asked for stays, moved down: a caller with a small
         --  buffer gets the rest next time rather than losing it.
         for Offset in 1 .. Here.Held - Room loop
            Here.Said (Offset) := Here.Said (Room + Offset);
         end loop;

         Here.Held := Here.Held - Room;
         Done := Here.Why /= Still_Going and then Here.Held = 0;
      end;
   end Take;

   ------------
   -- Retire --
   ------------

   procedure Retire (Item : in out Server; Who : Member_Id) is
   begin
      if Who = No_Member or else Natural (Who) > Item.Capacity then
         return;
      end if;

      declare
         Here : Seat renames Item.Seats (Natural (Who));
      begin
         if Here.State = Free then
            return;
         end if;

         L.Close (Here.Session);
         S.Close (Here.Sampler);
         Here.State := Free;
         Here.Why := Still_Going;
         Here.Held := 0;
         Here.Total := 0;
      end;
   end Retire;

   -----------
   -- Ended --
   -----------

   function Ended (Item : Server; Who : Member_Id) return Ending
   is (if Who = No_Member or else Natural (Who) > Item.Capacity
       then Still_Going
       else Item.Seats (Natural (Who)).Why);

   function Serving (Item : Server) return Natural is
      Count : Natural := 0;
   begin
      for Here of Item.Seats loop
         if Here.State /= Free and then Here.Why = Still_Going then
            Count := Count + 1;
         end if;
      end loop;

      return Count;
   end Serving;

   function Rounds (Item : Server) return Natural is (Item.Rounds_Made);
   function Gathered (Item : Server) return Natural is (Item.Last_Round);
   function Produced (Item : Server) return Natural is (Item.Tokens_Made);

end Model_Runner.Serving;
