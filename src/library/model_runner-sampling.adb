with Ada.Containers.Generic_Array_Sort;
with Ada.Unchecked_Deallocation;

package body Model_Runner.Sampling is

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Wide_Real;
   use type Model_Runner.Tokenizer.Token_Id;

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;

   subtype Element_Count is N.Element_Count;

   procedure Free_Candidates is
     new Ada.Unchecked_Deallocation (Candidate_Array, Candidate_Array_Access);
   procedure Free_History is
     new Ada.Unchecked_Deallocation (History_Array, History_Array_Access);
   procedure Free_Mask is
     new Ada.Unchecked_Deallocation (Mask_Array, Mask_Array_Access);

   --  Total order over candidates: higher logit first, and among equal logits
   --  the lower token identifier first. Being a total order rather than a
   --  partial one is what makes the sort, and therefore every filter built on
   --  it, reproducible.
   function Ranks_Before (Left, Right : Candidate) return Boolean
   is (Left.Logit > Right.Logit
       or else (Left.Logit = Right.Logit and then Left.Token < Right.Token));

   procedure Sort is
     new Ada.Containers.Generic_Array_Sort
       (Index_Type   => Element_Count,
        Element_Type => Candidate,
        Array_Type   => Candidate_Array,
        "<"          => Ranks_Before);

   ---------------------------------------------------------------------------
   --  Pseudorandom generator
   ---------------------------------------------------------------------------

   --  SplitMix64, used only to expand a single seed into the four words
   --  xoshiro256++ needs. Seeding a xoshiro state directly from a small
   --  integer would leave it with too few set bits for many outputs.
   procedure Expand (Seed : in out Interfaces.Unsigned_64;
                     Value : out Interfaces.Unsigned_64) is
   begin
      Seed := Seed + 16#9E37_79B9_7F4A_7C15#;
      Value := Seed;
      Value := (Value xor Interfaces.Shift_Right (Value, 30))
        * 16#BF58_476D_1CE4_E5B9#;
      Value := (Value xor Interfaces.Shift_Right (Value, 27))
        * 16#94D0_49BB_1331_11EB#;
      Value := Value xor Interfaces.Shift_Right (Value, 31);
   end Expand;

   --  Initialize the generator from a seed.
   procedure Seed_Generator
     (State : out Generator_State;
      Seed  : Interfaces.Unsigned_64)
   is
      Running : Interfaces.Unsigned_64 := Seed;
   begin
      for Index in State'Range loop
         Expand (Running, State (Index));
      end loop;

      --  An all-zero state is the one fixed point of xoshiro; it cannot be
      --  produced by SplitMix64 in practice, but the guard costs nothing.
      if State = Generator_State'[others => 0] then
         State (0) := 16#9E37_79B9_7F4A_7C15#;
      end if;
   end Seed_Generator;

   --  xoshiro256++ next output.
   procedure Next (State : in out Generator_State;
                   Value : out Interfaces.Unsigned_64)
   is
      function Rotate
        (Item : Interfaces.Unsigned_64; Count : Natural)
         return Interfaces.Unsigned_64
      is (Interfaces.Rotate_Left (Item, Count));

      Temporary : constant Interfaces.Unsigned_64 :=
        Interfaces.Shift_Left (State (1), 17);
   begin
      Value := Rotate (State (0) + State (3), 23) + State (0);

      State (2) := State (2) xor State (0);
      State (3) := State (3) xor State (1);
      State (1) := State (1) xor State (2);
      State (0) := State (0) xor State (3);
      State (2) := State (2) xor Temporary;
      State (3) := Rotate (State (3), 45);
   end Next;

   --  Draw a value in the half-open interval 0 .. 1.
   procedure Uniform (State : in out Generator_State;
                      Value : out N.Wide_Real)
   is
      Raw : Interfaces.Unsigned_64;
   begin
      Next (State, Raw);
      --  53 bits is the mantissa width of the accumulation format, so every
      --  representable value in the interval is reachable and none is favoured.
      Value := N.Wide_Real (Interfaces.Shift_Right (Raw, 11))
        / N.Wide_Real (2 ** 53);
   end Uniform;

   --------------
   -- Validate --
   --------------

   procedure Validate
     (Item   : Configuration;
      Status : out E.Error_Info)
   is
      procedure Reject (Field : String; Value : Real) is
      begin
         Status := E.Make (E.Sampling_Invalid_Configuration);
         E.Add_Text (Status, "field", Field, E.Param_Identifier);
         E.Add_Real (Status, "value", Long_Float (Value));
      end Reject;
   begin
      Status := E.Success;

      if not N.Is_Finite (Item.Temperature) or else Item.Temperature < 0.0 then
         Reject ("temperature", Item.Temperature);
         return;
      end if;

      if not N.Is_Finite (Item.Top_P)
        or else Item.Top_P <= 0.0
        or else Item.Top_P > 1.0
      then
         Reject ("top_p", Item.Top_P);
         return;
      end if;

      if not N.Is_Finite (Item.Min_P)
        or else Item.Min_P < 0.0
        or else Item.Min_P > 1.0
      then
         Reject ("min_p", Item.Min_P);
         return;
      end if;

      if not N.Is_Finite (Item.Repeat_Penalty)
        or else Item.Repeat_Penalty <= 0.0
      then
         Reject ("repeat_penalty", Item.Repeat_Penalty);
         return;
      end if;

      --  Bounded on both sides rather than required positive: a negative
      --  value is meaningful here, and what has to be refused is a magnitude
      --  large enough to make every logit in the window infinite.
      if not N.Is_Finite (Item.Frequency_Penalty)
        or else abs Item.Frequency_Penalty > 100.0
      then
         Reject ("frequency_penalty", Item.Frequency_Penalty);
         return;
      end if;

      if not N.Is_Finite (Item.Presence_Penalty)
        or else abs Item.Presence_Penalty > 100.0
      then
         Reject ("presence_penalty", Item.Presence_Penalty);
         return;
      end if;
   end Validate;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item       : in out Sampler;
      Config     : Configuration;
      Vocabulary : Natural;
      Seed       : Seed_Value;
      Status     : out E.Error_Info) is
   begin
      Close (Item);
      Validate (Config, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Vocabulary = 0 then
         Status := E.Make (E.Sampling_Vocabulary_Mismatch);
         E.Add_Integer (Status, "vocabulary", 0);
         return;
      end if;

      Item.Settings := Config;
      Item.Vocabulary := Vocabulary;
      Item.Seed := Seed;
      Seed_Generator (Item.State, Seed);

      begin
         Item.Working :=
           new Candidate_Array (0 .. Element_Count (Vocabulary) - 1);
         Item.Masked := new Mask_Array (0 .. Vocabulary - 1);
         Item.Masked.all := [others => False];
         Item.History :=
           new History_Array (0 .. Natural'Max (Config.Repeat_Window, 1) - 1);
         Item.History.all := [others => Model_Runner.Tokenizer.No_Token];
      exception
         when Storage_Error =>
            Close (Item);
            Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text (Status, "category", "sampling_workspace",
                        E.Param_Identifier);
            return;
      end;

      Item.Used := 0;
      Item.Next_Slot := 0;
      Item.Open_Flag := True;
      Status := E.Success;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Sampler) is
   begin
      if Item.Working /= null then
         Free_Candidates (Item.Working);
      end if;
      if Item.History /= null then
         Free_History (Item.History);
      end if;
      if Item.Masked /= null then
         Free_Mask (Item.Masked);
      end if;

      Item.Open_Flag := False;
      Item.Vocabulary := 0;
      Item.Used := 0;
      Item.Next_Slot := 0;
   exception
      when others =>
         Item.Open_Flag := False;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Sampler) is
   begin
      Close (Item);
   end Finalize;

   -----------
   -- Reset --
   -----------

   procedure Reset (Item : in out Sampler) is
   begin
      Item.Used := 0;
      Item.Next_Slot := 0;
      Seed_Generator (Item.State, Item.Seed);
   end Reset;

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Item : Sampler) return Boolean is (Item.Open_Flag);

   ----------------
   -- Seed_Used --
   ----------------

   function Seed_Used (Item : Sampler) return Seed_Value is (Item.Seed);

   ------------
   -- Forbid --
   ------------

   procedure Forbid (Item : in out Sampler; Token : Token_Id) is
   begin
      if Item.Masked /= null
        and then Token >= 0
        and then Natural (Token) < Item.Vocabulary
      then
         Item.Masked.all (Natural (Token)) := True;
      end if;
   end Forbid;

   -------------------
   -- Record_Token --
   -------------------

   procedure Record_Token (Item : in out Sampler; Token : Token_Id) is
   begin
      if Item.History = null or else Item.Settings.Repeat_Window = 0 then
         return;
      end if;

      Item.History.all (Item.Next_Slot) := Token;
      Item.Next_Slot := (Item.Next_Slot + 1) mod Item.History.all'Length;
      if Item.Used < Item.History.all'Length then
         Item.Used := Item.Used + 1;
      end if;
   end Record_Token;

   --  How many times a token appears in the recent history.
   function Occurrences (Item : Sampler; Token : Token_Id) return Natural is
      Seen : Natural := 0;
   begin
      if Item.History = null then
         return 0;
      end if;

      for Index in 0 .. Item.Used - 1 loop
         if Item.History.all (Index) = Token then
            Seen := Seen + 1;
         end if;
      end loop;
      return Seen;
   end Occurrences;

   --  Report whether a token appears in the recent history.
   function In_History (Item : Sampler; Token : Token_Id) return Boolean is
   begin
      if Item.History = null then
         return False;
      end if;

      for Index in 0 .. Item.Used - 1 loop
         if Item.History.all (Index) = Token then
            return True;
         end if;
      end loop;
      return False;
   end In_History;

   --  Select greedily: the highest logit, breaking ties towards the lowest
   --  token identifier. Deliberately separate from the probabilistic path so
   --  that it cannot touch the generator.
   procedure Select_Greedy
     (Item   : Sampler;
      Logits : Real_Array;
      Token  : out Token_Id;
      Status : out E.Error_Info)
   is
      Best       : Token_Id := Model_Runner.Tokenizer.No_Token;
      Best_Logit : Real := 0.0;
   begin
      Status := E.Success;

      for Index in 0 .. Element_Count (Item.Vocabulary) - 1 loop
         if not Item.Masked.all (Natural (Index)) then
            declare
               Value : constant Real := Logits (Logits'First + Index);
            begin
               if Best = Model_Runner.Tokenizer.No_Token
                 or else Value > Best_Logit
               then
                  Best := Token_Id (Index);
                  Best_Logit := Value;
               end if;
            end;
         end if;
      end loop;

      Token := Best;

      if Best = Model_Runner.Tokenizer.No_Token then
         Status := E.Make (E.Sampling_No_Candidates);
      end if;
   end Select_Greedy;

   ------------
   -- Sample --
   ------------

   procedure Sample
     (Item   : in out Sampler;
      Logits : Real_Array;
      Token  : out Token_Id;
      Status : out E.Error_Info)
   is
      Count     : Element_Count := 0;
      Surviving : Element_Count := 0;
   begin
      Token := Model_Runner.Tokenizer.No_Token;

      --  1  vocabulary size
      if not Item.Open_Flag then
         Status := E.Make (E.Sampling_Invalid_Configuration);
         return;
      end if;

      if Logits'Length /= Element_Count (Item.Vocabulary) then
         Status := E.Make (E.Sampling_Vocabulary_Mismatch);
         E.Add_Integer (Status, "expected", Long_Long_Integer (Item.Vocabulary));
         E.Add_Integer (Status, "actual", Long_Long_Integer (Logits'Length));
         return;
      end if;

      --  2  non-finite logits
      --
      --  Suppressed at the call site as well as inside Is_Finite: the check
      --  fires when the argument is evaluated, before the predicate written
      --  to answer the question ever runs. A logit that is not a number is a
      --  diagnostic this loop reports, not a fault.
      declare
         pragma Suppress (Validity_Check);
      begin
         for Index in Logits'Range loop
            if not N.Is_Finite (Logits (Index)) then
               Status := E.Make (E.Sampling_Non_Finite_Logit);
               E.Add_Integer
                 (Status, "token", Long_Long_Integer (Index - Logits'First));
               return;
            end if;
         end loop;
      end;

      --  Greedy mode short-circuits the whole probabilistic pipeline and does
      --  not consume random state.
      if Is_Greedy (Item.Settings) then
         Select_Greedy (Item, Logits, Token, Status);
         return;
      end if;

      --  3  forbidden-token masks, and 4  repetition penalty. Both act on the
      --  logits in token order, before any reordering, so that the history
      --  lookup stays a direct comparison.
      for Index in 0 .. Element_Count (Item.Vocabulary) - 1 loop
         if not Item.Masked.all (Natural (Index)) then
            declare
               --  Suppressed for the same reason as the loop above: the
               --  arithmetic below can leave a value the check would fire on
               --  before anything can ask whether it did.
               pragma Suppress (Validity_Check);

               Value : Real := Logits (Logits'First + Index);
            begin
               if Item.Settings.Repeat_Penalty /= 1.0
                 and then In_History (Item, Token_Id (Index))
               then
                  Value :=
                    (if Value > 0.0
                     then Value / Item.Settings.Repeat_Penalty
                     else Value * Item.Settings.Repeat_Penalty);
               end if;

               --  Counted once, and used by both penalties. Asking the
               --  history twice for the same token would double the cost of
               --  a loop that already walks the window for every candidate.
               if Item.Settings.Frequency_Penalty /= 0.0
                 or else Item.Settings.Presence_Penalty /= 0.0
               then
                  declare
                     Seen : constant Natural :=
                       Occurrences (Item, Token_Id (Index));
                  begin
                     if Seen > 0 then
                        Value :=
                          Value
                          - Item.Settings.Frequency_Penalty * Real (Seen)
                          - Item.Settings.Presence_Penalty;
                     end if;
                  end;
               end if;

               --  5  temperature
               Value := Value / Item.Settings.Temperature;

               --  The inputs were all finite and the result need not be: a
               --  large logit divided by a small temperature overflows, and a
               --  penalty below one multiplies. Reported, like a logit that
               --  arrived non-finite, rather than trapping here.
               if not N.Is_Finite (Value) then
                  Status := E.Make (E.Sampling_Non_Finite_Logit);
                  E.Add_Integer
                    (Status, "token", Long_Long_Integer (Index));
                  return;
               end if;

               Item.Working.all (Count) :=
                 (Token => Token_Id (Index), Logit => Value, Probability => 0.0);
               Count := Count + 1;
            end;
         end if;
      end loop;

      if Count = 0 then
         Status := E.Make (E.Sampling_No_Candidates);
         return;
      end if;

      Sort (Item.Working.all (0 .. Count - 1));

      --  6  top-k
      Surviving := Count;
      if Item.Settings.Top_K > 0
        and then Element_Count (Item.Settings.Top_K) < Surviving
      then
         Surviving := Element_Count (Item.Settings.Top_K);
      end if;

      --  Softmax over the surviving candidates, so that the probability
      --  filters below operate on a proper distribution.
      declare
         Largest : constant Real := Item.Working.all (0).Logit;
         Total   : N.Wide_Real := 0.0;
      begin
         for Index in 0 .. Surviving - 1 loop
            declare
               Weight : constant N.Wide_Real :=
                 N.Exp (N.Wide_Real (Item.Working.all (Index).Logit)
                        - N.Wide_Real (Largest));
            begin
               Item.Working.all (Index).Probability := Real (Weight);
               Total := Total + Weight;
            end;
         end loop;

         if Total <= 0.0 or else not N.Is_Finite (Total) then
            Status := E.Make (E.Sampling_Invalid_Distribution);
            return;
         end if;

         for Index in 0 .. Surviving - 1 loop
            Item.Working.all (Index).Probability :=
              Real (N.Wide_Real (Item.Working.all (Index).Probability) / Total);
         end loop;
      end;

      --  7  top-p: the shortest prefix whose cumulative probability reaches
      --  the threshold. At least one candidate always survives.
      if Item.Settings.Top_P < 1.0 then
         declare
            Cumulative : N.Wide_Real := 0.0;
            Kept       : Element_Count := Surviving;
         begin
            for Index in 0 .. Surviving - 1 loop
               Cumulative :=
                 Cumulative + N.Wide_Real (Item.Working.all (Index).Probability);
               if Cumulative >= N.Wide_Real (Item.Settings.Top_P) then
                  Kept := Index + 1;
                  exit;
               end if;
            end loop;
            Surviving := Element_Count'Max (1, Kept);
         end;
      end if;

      --  8  minimum-p, relative to the most probable surviving candidate.
      if Item.Settings.Min_P > 0.0 then
         declare
            Threshold : constant Real :=
              Item.Settings.Min_P * Item.Working.all (0).Probability;
            Kept      : Element_Count := 1;
         begin
            for Index in 1 .. Surviving - 1 loop
               exit when Item.Working.all (Index).Probability < Threshold;
               Kept := Index + 1;
            end loop;
            Surviving := Kept;
         end;
      end if;

      --  9  renormalize the survivors
      declare
         Total : N.Wide_Real := 0.0;
      begin
         for Index in 0 .. Surviving - 1 loop
            Total := Total + N.Wide_Real (Item.Working.all (Index).Probability);
         end loop;

         if Total <= 0.0 or else not N.Is_Finite (Total) then
            Status := E.Make (E.Sampling_Invalid_Distribution);
            return;
         end if;

         --  10  selection by inverse transform over the sorted survivors.
         declare
            Draw       : N.Wide_Real;
            Cumulative : N.Wide_Real := 0.0;
         begin
            Uniform (Item.State, Draw);
            Draw := Draw * Total;

            Token := Item.Working.all (Surviving - 1).Token;
            for Index in 0 .. Surviving - 1 loop
               Cumulative :=
                 Cumulative + N.Wide_Real (Item.Working.all (Index).Probability);
               if Draw < Cumulative then
                  Token := Item.Working.all (Index).Token;
                  exit;
               end if;
            end loop;
         end;
      end;

      Status := E.Success;
   end Sample;

end Model_Runner.Sampling;
