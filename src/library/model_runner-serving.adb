with Model_Runner.Limits;

with Model_Runner.Backend;

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

   --  Rows one round may have. What a batch is bounded at, because a round
   --  is a batch whose rows belong to several sessions.
   Row_Limit : constant := L.Max_Batch;

   ------------
   -- Open --
   ------------

   procedure Open
     (Item    : in out Server;
      Source  : in out Model_Runner.Llama.Model'Class;
      Workers : Model_Runner.Backend.CPU.Pool_Reference := null;
      Context : Natural := 0;
      Gather  : Positive := Default_Gather;
      Budget  : Boolean := False;
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
      Item.Budget := Budget;
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
            S.Close (Item.Seats (Which).Sampler);
         end if;

         --  The session outlives the member, so it is closed here and not
         --  in Retire: this is where a seat stops existing.
         if Item.Seats (Which).Seated then
            L.Close (Item.Seats (Which).Session);
            Item.Seats (Which).Seated := False;
         end if;

         Item.Seats (Which).State := Free;
         Item.Seats (Which).Held := 0;
         Item.Seats (Which).Total := 0;
         Item.Seats (Which).Why := Still_Going;
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

      if Prompt'Length > Max_Prompt then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer
           (Status, "input", Long_Long_Integer (Prompt'Length));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Prompt));
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

         --  The seat's own session, opened once and rewound after that. A
         --  rewind invalidates the cache and the history and releases
         --  nothing, so the second caller in a seat pays none of what the
         --  first one paid.
         if Seat_Here.Seated then
            L.Reset (Seat_Here.Session);
         else
            L.Open
              (Seat_Here.Session, Item.Source.all,
               Context => Item.Context,
               Session_Bounds => Model_Runner.Limits.Default_Session_Limits,
               Workers => Item.Workers,
               Status => Status);

            if E.Is_Error (Status) then
               return;
            end if;

            Seat_Here.Seated := True;

            --  Once, where the session is made: Account clears what it has
            --  counted, and a seat that cleared it for every caller would
            --  report the last one rather than the server.
            if Item.Budget then
               L.Account (Seat_Here.Session, True);
            end if;
         end if;

         --  The sampler is the caller's rather than the seat's: two callers
         --  in one seat are two temperatures, two penalties and two seeds.
         --  It is a candidate list and two windows, not a cache, so opening
         --  one a caller is not what serving was spending its time on.
         S.Close (Seat_Here.Sampler);
         S.Open
           (Seat_Here.Sampler, With_Terms.Sampling,
            Settings.Vocabulary, With_Terms.Seed, Status);

         if E.Is_Error (Status) then
            return;
         end if;

         --  The prompt, copied and not read. What reads it is the rounds
         --  that follow, a stretch at a time and beside everyone else's
         --  next token, which is the whole of what admitting a caller is
         --  meant to cost.
         Seat_Here.Prompt (1 .. Prompt'Length) := Prompt;
         Seat_Here.Length := Prompt'Length;
         Seat_Here.Read := 0;

         Seat_Here.State := Running;
         Seat_Here.Why := Still_Going;
         Seat_Here.Held := 0;
         Seat_Here.Total := 0;
         Seat_Here.Next := V.No_Token;
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
      --  Which seats are in this round, in the order they were found. That
      --  order is the members' order everywhere below: the rows go in it and
      --  the logits come back in it.
      Chosen : array (1 .. Item.Gather) of Natural := [others => 0];
      Share  : array (1 .. Item.Gather) of Positive := [others => 1];
      Taken  : Natural := 0;

      --  Rows the round will have. A member generating brings one; a member
      --  still reading brings the next stretch of its prompt.
      Rows : Natural := 0;

      --  How many members are still reading, and how long a stretch each of
      --  them may bring. The row budget is shared out rather than handed to
      --  whoever is asked first: eight members each taking a hundred and
      --  twenty-eight rows do not fit in one round, and the ones left out
      --  wait a round for nothing while the ones let in are no faster for
      --  having a longer stretch.
      Readers : Natural := 0;
      Stretch : Positive := Prefill_Batch;
   begin
      Status := E.Success;
      Item.Last_Round := 0;

      if not Item.Open_Now or else Item.Source = null then
         Status := E.Make (E.Lifecycle_Session_Closed);
         return;
      end if;

      for Which in Item.Seats'Range loop
         if Item.Seats (Which).State = Running
           and then Item.Seats (Which).Why = Still_Going
           and then Item.Seats (Which).Read < Item.Seats (Which).Length
         then
            Readers := Readers + 1;
         end if;
      end loop;

      if Readers > 0 then
         Stretch :=
           Positive'Max
             (1,
              Positive'Min
                (Prefill_Batch,
                 (Row_Limit - Natural'Min (Item.Gather, Row_Limit / 2))
                 / Readers));
      end if;

      for Which in Item.Seats'Range loop
         exit when Taken = Item.Gather;

         if Item.Seats (Which).State = Running
           and then Item.Seats (Which).Why = Still_Going
         then
            declare
               Here : Seat renames Item.Seats (Which);

               Wants : constant Positive :=
                 (if Here.Read < Here.Length
                  then Natural'Min (Stretch, Here.Length - Here.Read)
                  else 1);
            begin
               --  A round is bounded like any other batch, and a member
               --  that does not fit in this one waits for the next. Left
               --  out rather than cut short, because a member's stretch is
               --  already the size the bound was chosen for.
               exit when Taken > 0 and then Rows + Wants > Row_Limit;

               Taken := Taken + 1;
               Chosen (Taken) := Which;
               Share (Taken) := Wants;
               Rows := Rows + Wants;
            end;
         end if;
      end loop;

      if Taken = 0 then
         return;
      end if;

      declare
         Group  : L.Session_Group (1 .. Taken);
         Counts : L.Row_Counts (1 .. Taken);
         Tokens : V.Token_Array (1 .. Rows);

         At_Row : Natural := 0;
      begin
         for Row in 1 .. Taken loop
            declare
               Here : Seat renames Item.Seats (Chosen (Row));
            begin
               Group (Row) := Here.Session'Unchecked_Access;
               Counts (Row) := Share (Row);

               if Here.Read < Here.Length then
                  Tokens (At_Row + 1 .. At_Row + Share (Row)) :=
                    Here.Prompt (Here.Read + 1 .. Here.Read + Share (Row));
               else
                  Tokens (At_Row + 1) := Here.Next;
               end if;

               At_Row := At_Row + Share (Row);
            end;
         end loop;

         L.Evaluate_Round
           (Members => Group, Source => Item.Source.all,
            Tokens => Tokens, Logits => Item.Rows,
            Cancel => Cancel, Shares => Counts, Status => Status);

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
               if Here.Read < Here.Length then
                  Here.Read := Here.Read + Share (Row);
               end if;

               --  A member still reading says nothing: what comes back for
               --  it is the distribution after the stretch it just read,
               --  and the next stretch is what it wants, not a token.
               if Here.Read >= Here.Length then
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

         --  The session stays, rewound where the next caller takes the
         --  seat. What goes is the member: its sampler, its tokens and its
         --  claim on the seat.
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

   function Time_Taken
     (Item : Server) return Model_Runner.Llama.Phase_Times
   is
      Whole : Model_Runner.Llama.Phase_Times := [others => 0.0];
   begin
      for Here of Item.Seats loop
         if Here.Seated then
            declare
               Its : constant Model_Runner.Llama.Phase_Times :=
                 L.Time_Spent (Here.Session);
            begin
               for Phase in Model_Runner.Llama.Phase loop
                  Whole (Phase) := Whole (Phase) + Its (Phase);
               end loop;
            end;
         end if;
      end loop;

      return Whole;
   end Time_Taken;

   function Rounds (Item : Server) return Natural is (Item.Rounds_Made);
   function Gathered (Item : Server) return Natural is (Item.Last_Round);
   function Produced (Item : Server) return Natural is (Item.Tokens_Made);

end Model_Runner.Serving;
