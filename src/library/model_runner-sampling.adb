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

   --  The largest top-k selected rather than sorted.
   --
   --  Selection keeps the chosen few in order as it goes, so it costs about
   --  one comparison per candidate plus a shift whenever one displaces
   --  another. Sorting costs a logarithm per candidate whatever k is. Where
   --  the two cross is a judgement, and this is where it is made; both
   --  produce the same k in the same order, because the order below is
   --  total, so nothing but the time depends on which runs.
   Selection_Limit : constant := 512;

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

      if not N.Is_Finite (Item.Typical_P)
        or else Item.Typical_P <= 0.0
        or else Item.Typical_P > 1.0
      then
         Reject ("typical_p", Item.Typical_P);
         return;
      end if;

      if not N.Is_Finite (Item.Tail_Free)
        or else Item.Tail_Free <= 0.0
        or else Item.Tail_Free > 1.0
      then
         Reject ("tail_free", Item.Tail_Free);
         return;
      end if;

      if not N.Is_Finite (Item.XTC_Probability)
        or else Item.XTC_Probability < 0.0
        or else Item.XTC_Probability > 1.0
      then
         Reject ("xtc_probability", Item.XTC_Probability);
         return;
      end if;

      if not N.Is_Finite (Item.XTC_Threshold)
        or else Item.XTC_Threshold <= 0.0
        or else Item.XTC_Threshold > 1.0
      then
         Reject ("xtc_threshold", Item.XTC_Threshold);
         return;
      end if;

      if not N.Is_Finite (Item.DRY_Multiplier)
        or else Item.DRY_Multiplier < 0.0
        or else Item.DRY_Multiplier > 100.0
      then
         Reject ("dry_multiplier", Item.DRY_Multiplier);
         return;
      end if;

      --  Above one, because a base of one raises to one however long the
      --  repetition runs, which is a penalty that does not grow -- and
      --  below one it shrinks with length, which is the opposite of what
      --  this is for.
      if not N.Is_Finite (Item.DRY_Base) or else Item.DRY_Base <= 1.0
        or else Item.DRY_Base > 100.0
      then
         Reject ("dry_base", Item.DRY_Base);
         return;
      end if;

      --  Two versions exist and this implements the second. Refusing the
      --  first by name beats treating it as the second: they steer
      --  differently, and a caller who asked for one and silently got the
      --  other would be measuring the wrong thing.
      if Item.Mirostat /= 0 and then Item.Mirostat /= 2 then
         Status := E.Make (E.Sampling_Invalid_Configuration);
         E.Add_Text (Status, "field", "mirostat", E.Param_Identifier);
         E.Add_Integer (Status, "value", Long_Long_Integer (Item.Mirostat));
         return;
      end if;

      if not N.Is_Finite (Item.Mirostat_Tau)
        or else Item.Mirostat_Tau <= 0.0
        or else Item.Mirostat_Tau > 100.0
      then
         Reject ("mirostat_tau", Item.Mirostat_Tau);
         return;
      end if;

      if not N.Is_Finite (Item.Mirostat_Eta)
        or else Item.Mirostat_Eta <= 0.0
        or else Item.Mirostat_Eta > 10.0
      then
         Reject ("mirostat_eta", Item.Mirostat_Eta);
         return;
      end if;

      --  Mirostat replaces the truncation filters, so asking for both is
      --  asking for two answers to one question. Refused rather than
      --  resolved by precedence: a caller who set top-p and mirostat has a
      --  belief about what happens, and whichever way it were resolved that
      --  belief would be wrong half the time.
      if Item.Mirostat /= 0
        and then (Item.Top_K /= 0
                  or else Item.Top_P < 1.0
                  or else Item.Min_P > 0.0
                  or else Item.Typical_P < 1.0
                  or else Item.Tail_Free < 1.0
                  or else Item.XTC_Probability > 0.0)
      then
         Status := E.Make (E.Sampling_Invalid_Configuration);
         E.Add_Text (Status, "field", "mirostat", E.Param_Identifier);
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

         --  A top-k of a few dozen out of tens of thousands is worth
         --  selecting rather than sorting, and selecting needs somewhere to
         --  keep what it has chosen so far that is not the array it is
         --  reading. A large top-k is not worth it -- keeping k in order
         --  costs more per candidate than sorting does -- so only a small
         --  one gets the room.
         if Config.Top_K > 0
           and then Element_Count (Config.Top_K) <= Selection_Limit
         then
            Item.Chosen :=
              new Candidate_Array (0 .. Element_Count (Config.Top_K) - 1);
         end if;
         Item.Masked := new Mask_Array (0 .. Vocabulary - 1);
         Item.Masked.all := [others => False];
         Item.Stepped := new Mask_Array (0 .. Vocabulary - 1);
         Item.Stepped.all := [others => False];
         Item.History :=
           new History_Array (0 .. Natural'Max (Config.Repeat_Window, 1) - 1);
         Item.Ordered :=
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
      Item.Ordered_Held := 0;
      Item.Mu := 2.0 * Config.Mirostat_Tau;
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
         Free_History (Item.Ordered);
      end if;
      if Item.Chosen /= null then
         Free_Candidates (Item.Chosen);
      end if;

      if Item.Stepped /= null then
         Free_Mask (Item.Stepped);
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

   --  Biases survive a reset: they are what the caller asked for, not
   --  something the run accumulated.
   --  Mirostat starts each run with its target at twice tau, which is the
   --  value the algorithm is defined to start from.
   procedure Reset (Item : in out Sampler) is
   begin
      Item.Used := 0;
      Item.Next_Slot := 0;
      Item.Ordered_Held := 0;
      Item.Mu := 2.0 * Item.Settings.Mirostat_Tau;
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

   -------------------------
   -- Release_Step_Mask --
   -------------------------

   procedure Release_Step_Mask (Item : in out Sampler) is
   begin
      if Item.Stepped /= null then
         Item.Stepped.all := [others => False];
      end if;
   end Release_Step_Mask;

   ----------------------
   -- Forbid_For_Step --
   ----------------------

   procedure Forbid_For_Step (Item : in out Sampler; Token : Token_Id) is
   begin
      if Item.Stepped /= null
        and then Token >= 0
        and then Natural (Token) < Item.Vocabulary
      then
         Item.Stepped.all (Natural (Token)) := True;
      end if;
   end Forbid_For_Step;

   -------------------
   -- Record_Token --
   -------------------

   procedure Order_History (Item : in out Sampler);

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

      Order_History (Item);
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
   --  The window sorted and deduplicated, which Record_Token does once for
   --  every question In_History is then asked -- and it is asked once a
   --  token of the vocabulary.
   --
   --  An insertion sort because the window is sixty-four entries by default
   --  and never large: what it costs is bounded by the window and what it
   --  saves is bounded by the vocabulary, and the vocabulary is five
   --  hundred times the window.
   procedure Order_History (Item : in out Sampler) is
      Held : Natural := 0;
   begin
      if Item.Ordered = null then
         Item.Ordered_Held := 0;
         return;
      end if;

      for Index in 0 .. Item.Used - 1 loop
         declare
            Token : constant Token_Id := Item.History.all (Index);
            Place : Natural := Held;
         begin
            while Place > 0
              and then Item.Ordered.all (Place - 1) > Token
            loop
               Item.Ordered.all (Place) := Item.Ordered.all (Place - 1);
               Place := Place - 1;
            end loop;

            --  Repeats are dropped: the question is membership, and
            --  Occurrences counts for itself.
            if Place > 0 and then Item.Ordered.all (Place - 1) = Token then
               while Place < Held loop
                  Item.Ordered.all (Place) := Item.Ordered.all (Place + 1);
                  Place := Place + 1;
               end loop;
            else
               Item.Ordered.all (Place) := Token;
               Held := Held + 1;
            end if;
         end;
      end loop;

      Item.Ordered_Held := Held;
   end Order_History;

   function In_History (Item : Sampler; Token : Token_Id) return Boolean is
      Low  : Natural := 0;
      High : Integer := Item.Ordered_Held - 1;
   begin
      if Item.Ordered = null or else Item.Ordered_Held = 0 then
         return False;
      end if;

      while Low <= High loop
         declare
            Middle : constant Natural := Low + (High - Low) / 2;
            Here   : constant Token_Id := Item.Ordered.all (Middle);
         begin
            if Here = Token then
               return True;
            elsif Here < Token then
               Low := Middle + 1;
            else
               High := Middle - 1;
            end if;
         end;
      end loop;

      return False;
   end In_History;

   --  The history in the order it happened, oldest first.
   --
   --  The ring above is written round and round; a sequence question needs
   --  it straightened out, because what it asks is what followed what.
   function In_Order (Item : Sampler; Index : Natural) return Token_Id is
      Room : constant Natural := Item.History.all'Length;
      From : constant Natural :=
        (if Item.Used < Room then 0 else Item.Next_Slot);
   begin
      return Item.History.all ((From + Index) mod Room);
   end In_Order;

   --  How hard to penalize a token for continuing something already said.
   --
   --  The recent tokens end in some suffix; if that suffix appeared earlier,
   --  whatever followed it then is a step down a path already walked, and
   --  this is what it costs to take it again. The longest such match wins,
   --  and the cost grows as the base raised to how far past the allowed
   --  length that match runs.
   --
   --  Bounded by the window the history keeps, which is what --repeat-window
   --  sets: this can only see repetition it can remember.
   function Sequence_Penalty
     (Item : Sampler; Token : Token_Id) return Real
   is
      Longest : Natural := 0;
   begin
      if Item.History = null or else Item.Used < 2 then
         return 0.0;
      end if;

      --  Every place the token was said before. What matters is not that it
      --  was said but what came before it: if the words leading up to it
      --  then are the words leading up to now, saying it again continues
      --  the repetition.
      for Where in 0 .. Item.Used - 1 loop
         if In_Order (Item, Where) = Token then
            declare
               Run : Natural := 0;
            begin
               while Run < Where
                 and then Run < Item.Used
                 and then In_Order (Item, Where - 1 - Run)
                          = In_Order (Item, Item.Used - 1 - Run)
               loop
                  Run := Run + 1;
               end loop;

               if Run > Longest then
                  Longest := Run;
               end if;
            end;
         end if;
      end loop;

      if Longest <= Item.Settings.DRY_Allowed_Length then
         return 0.0;
      end if;

      return Item.Settings.DRY_Multiplier
             * Item.Settings.DRY_Base
               ** Natural (Longest - Item.Settings.DRY_Allowed_Length);
   end Sequence_Penalty;

   --  What the caller added to this token, or nothing. Walked rather than
   --  looked up: the list is at most sixty-four long and a token that has no
   --  bias is the common case, which a vocabulary-sized table would make
   --  fast and expensive.
   function Bias_Of (Item : Sampler; Token : Token_Id) return Real is
   begin
      for Index in 1 .. Item.Bias_Used loop
         if Item.Biases (Index).Token = Token then
            return Item.Biases (Index).Amount;
         end if;
      end loop;
      return 0.0;
   end Bias_Of;

   --  One token's logit with everything that acts on tokens applied: the
   --  caller's bias, the sequence penalty, and the three repetition
   --  penalties. Not the temperature, which is not about the token.
   --
   --  Here rather than in the sampling loop because the greedy path needs
   --  the same answer. It did not get it: penalties were applied where the
   --  candidates are built, which greedy skips entirely, so every penalty
   --  this program has quietly did nothing at temperature zero. A run that
   --  repeats itself is exactly the run a caller reaches for --repeat-penalty
   --  and --temperature 0 together.
   function Adjusted
     (Item   : Sampler;
      Logits : Real_Array;
      Index  : Element_Count) return Real
   is
      Value : Real := Logits (Logits'First + Index);
   begin
      if Item.Bias_Used > 0 then
         Value := Value + Bias_Of (Item, Token_Id (Index));
      end if;

      if Item.Settings.DRY_Multiplier > 0.0 then
         Value := Value - Sequence_Penalty (Item, Token_Id (Index));
      end if;

      if Item.Settings.Repeat_Penalty /= 1.0
        and then In_History (Item, Token_Id (Index))
      then
         Value :=
           (if Value > 0.0
            then Value / Item.Settings.Repeat_Penalty
            else Value * Item.Settings.Repeat_Penalty);
      end if;

      --  Counted once, and used by both penalties. Asking the history twice
      --  for the same token would double the cost of a loop that already
      --  walks the window for every candidate.
      if Item.Settings.Frequency_Penalty /= 0.0
        or else Item.Settings.Presence_Penalty /= 0.0
      then
         declare
            Seen : constant Natural := Occurrences (Item, Token_Id (Index));
         begin
            if Seen > 0 then
               Value :=
                 Value
                 - Item.Settings.Frequency_Penalty * Real (Seen)
                 - Item.Settings.Presence_Penalty;
            end if;
         end;
      end if;

      return Value;
   end Adjusted;

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
         if not Item.Masked.all (Natural (Index))
           and then not Item.Stepped.all (Natural (Index))
         then
            declare
               pragma Suppress (Validity_Check);

               Value : constant Real := Adjusted (Item, Logits, Index);
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

   ----------
   -- Bias --
   ----------

   procedure Bias
     (Item   : in out Sampler;
      Token  : Token_Id;
      Amount : Real;
      Status : out E.Error_Info) is
   begin
      Status := E.Success;

      if not Item.Open_Flag
        or else Natural (Token) >= Item.Vocabulary
      then
         Status := E.Make (E.Sampling_Vocabulary_Mismatch);
         E.Add_Integer (Status, "token", Long_Long_Integer (Token));
         E.Add_Integer
           (Status, "expected", Long_Long_Integer (Item.Vocabulary));
         return;
      end if;

      for Index in 1 .. Item.Bias_Used loop
         if Item.Biases (Index).Token = Token then
            Item.Biases (Index).Amount := Amount;
            return;
         end if;
      end loop;

      if Item.Bias_Used = Max_Biases then
         Status := E.Make (E.Sampling_Invalid_Configuration);
         E.Add_Text (Status, "field", "logit_bias", E.Param_Identifier);
         return;
      end if;

      Item.Bias_Used := Item.Bias_Used + 1;
      Item.Biases (Item.Bias_Used) := (Token => Token, Amount => Amount);
   end Bias;

   function Bias_Count (Item : Sampler) return Natural is (Item.Bias_Used);

   -------------
   -- Explain --
   -------------

   procedure Explain
     (Item   : Sampler;
      Logits : Real_Array;
      Chosen : Token_Id;
      Wanted : Natural;
      Report : out Explanation;
      Status : out E.Error_Info)
   is
      Room : constant Natural := Natural'Min (Wanted, Max_Alternatives);

      Largest : Real := 0.0;
      Total   : N.Wide_Real := 0.0;

      --  The best few, kept as they are met rather than by sorting the
      --  vocabulary: a caller wants five of thirty-two thousand, and sorting
      --  the rest to find them is the mistake the sampler already made once.
      Best_Token : Token_List (1 .. Max_Alternatives) :=
        [others => Model_Runner.Tokenizer.No_Token];
      Best_Logit : Model_Runner.Numerics.Real_List (1 .. Max_Alternatives) :=
        [others => 0.0];
      Kept : Natural := 0;
   begin
      Report := (others => <>);

      if not Item.Open_Flag then
         Status := E.Make (E.Sampling_Invalid_Configuration);
         return;
      end if;

      if Logits'Length /= Element_Count (Item.Vocabulary) then
         Status := E.Make (E.Sampling_Vocabulary_Mismatch);
         E.Add_Integer
           (Status, "expected", Long_Long_Integer (Item.Vocabulary));
         E.Add_Integer (Status, "actual", Long_Long_Integer (Logits'Length));
         return;
      end if;

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

      Largest := Logits (Logits'First);
      for Index in Logits'Range loop
         if Logits (Index) > Largest then
            Largest := Logits (Index);
         end if;
      end loop;

      for Index in Logits'Range loop
         Total := Total
           + N.Exp (N.Wide_Real (Logits (Index)) - N.Wide_Real (Largest));
      end loop;

      if Total <= 0.0 or else not N.Is_Finite (Total) then
         Status := E.Make (E.Sampling_Invalid_Distribution);
         return;
      end if;

      --  The chosen one, whatever the sampler made of the rest.
      if Natural (Chosen) < Item.Vocabulary then
         Report.Chosen := Chosen;
         Report.Log_Of :=
           Real (N.Wide_Real (Logits (Logits'First + Element_Count (Chosen)))
                 - N.Wide_Real (Largest) - N.Log (Total));
      end if;

      for Index in 0 .. Element_Count (Item.Vocabulary) - 1 loop
         declare
            Value : constant Real := Logits (Logits'First + Index);
            Where : Natural := 0;
         begin
            if Kept < Room then
               Kept := Kept + 1;
               Where := Kept;
            elsif Room > 0 and then Value > Best_Logit (Kept) then
               Where := Kept;
            end if;

            if Where > 0 then
               --  Into place, so the list stays in order and the last of it
               --  is always the weakest kept.
               while Where > 1 and then Best_Logit (Where - 1) < Value loop
                  Best_Logit (Where) := Best_Logit (Where - 1);
                  Best_Token (Where) := Best_Token (Where - 1);
                  Where := Where - 1;
               end loop;

               Best_Logit (Where) := Value;
               Best_Token (Where) := Token_Id (Index);
            end if;
         end;
      end loop;

      Report.Count := Kept;
      for Index in 1 .. Kept loop
         Report.Tokens (Index) := Best_Token (Index);
         Report.Log_Values (Index) :=
           Real (N.Wide_Real (Best_Logit (Index)) - N.Wide_Real (Largest)
                 - N.Log (Total));
      end loop;

      Status := E.Success;
   end Explain;

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
         if not Item.Masked.all (Natural (Index))
           and then not Item.Stepped.all (Natural (Index))
         then
            declare
               --  Suppressed for the same reason as the loop above: the
               --  arithmetic below can leave a value the check would fire on
               --  before anything can ask whether it did.
               pragma Suppress (Validity_Check);

               Value : Real := Adjusted (Item, Logits, Index);
            begin
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

      --  5  order the candidates, or select the head of the order when
      --      that is all the filters below will look at.
      if Item.Chosen /= null
        and then Element_Count (Item.Settings.Top_K) < Count
      then
         declare
            Wanted : constant Element_Count :=
              Element_Count (Item.Settings.Top_K);
            Kept   : Element_Count := 0;
         begin
            for Index in 0 .. Count - 1 loop
               declare
                  Value : constant Candidate := Item.Working.all (Index);
               begin
                  if Kept < Wanted
                    or else Ranks_Before (Value, Item.Chosen.all (Kept - 1))
                  then
                     --  Where it belongs among the ones kept so far.
                     declare
                        Place : Element_Count := Kept;
                     begin
                        if Kept = Wanted then
                           Place := Kept - 1;
                        else
                           Kept := Kept + 1;
                        end if;

                        while Place > 0
                          and then Ranks_Before
                                     (Value, Item.Chosen.all (Place - 1))
                        loop
                           Item.Chosen.all (Place) :=
                             Item.Chosen.all (Place - 1);
                           Place := Place - 1;
                        end loop;

                        Item.Chosen.all (Place) := Value;
                     end;
                  end if;
               end;
            end loop;

            Item.Working.all (0 .. Kept - 1) := Item.Chosen.all (0 .. Kept - 1);
            Count := Kept;
         end;
      else
         Sort (Item.Working.all (0 .. Count - 1));
      end if;

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

      --  Mirostat instead of the filters, when it is on. It keeps the
      --  candidates whose surprise is under a running target and leaves the
      --  rest; the target moves after the choice, at the end of this
      --  procedure. The configuration refuses mirostat together with any of
      --  the filters, so nothing below can also have run.
      if Item.Settings.Mirostat = 2 then
         declare
            Kept : Element_Count := 1;
         begin
            for Index in 0 .. Surviving - 1 loop
               exit when Item.Working.all (Index).Probability <= 0.0;

               --  Surprise in bits, which is what tau is in.
               declare
                  Bits : constant Real :=
                    Real (-N.Log
                            (N.Wide_Real
                               (Item.Working.all (Index).Probability))
                          / N.Log (2.0));
               begin
                  exit when Bits > Item.Mu;
                  Kept := Index + 1;
               end;
            end loop;

            Surviving := Kept;
         end;
      end if;

      --  6a  tail-free: cut where the sorted curve stops falling steeply.
      --
      --  The second differences of the sorted probabilities say how fast
      --  the curve is bending. Normalized, they are a distribution over
      --  where the bend happens, and the cut goes at the point their
      --  cumulative reaches the threshold.
      if Item.Settings.Tail_Free < 1.0 and then Surviving > 2 then
         declare
            Bend  : N.Wide_Real := 0.0;
            Taken : N.Wide_Real := 0.0;
            Kept  : Element_Count := Surviving;

            function Second (Index : Element_Count) return N.Wide_Real is
              (abs (N.Wide_Real (Item.Working.all (Index).Probability)
                    - 2.0 * N.Wide_Real
                              (Item.Working.all (Index + 1).Probability)
                    + N.Wide_Real
                        (Item.Working.all (Index + 2).Probability)));
         begin
            for Index in 0 .. Surviving - 3 loop
               Bend := Bend + Second (Index);
            end loop;

            if Bend > 0.0 then
               for Index in 0 .. Surviving - 3 loop
                  Taken := Taken + Second (Index);
                  if Taken / Bend >= N.Wide_Real (Item.Settings.Tail_Free)
                  then
                     Kept := Index + 2;
                     exit;
                  end if;
               end loop;

               Surviving := Element_Count'Max (1, Kept);
            end if;
         end;
      end if;

      --  6b  locally typical: keep the candidates whose surprise is nearest
      --  the distribution's own entropy, until they reach the threshold.
      --
      --  Nearest, not highest, so this reorders. The survivors are compacted
      --  back into probability order afterwards, because everything below
      --  and the draw itself read the array as sorted.
      if Item.Settings.Typical_P < 1.0 and then Surviving > 1 then
         declare
            Entropy : N.Wide_Real := 0.0;

            type Distance_Array is
              array (Element_Count range 0 .. Surviving - 1) of N.Wide_Real;
            Away : Distance_Array := [others => 0.0];

            type Order_Array is
              array (Element_Count range 0 .. Surviving - 1) of Element_Count;
            Order : Order_Array;

            Taken : N.Wide_Real := 0.0;
            Kept  : Element_Count := 0;

            type Keep_Array is
              array (Element_Count range 0 .. Surviving - 1) of Boolean;
            Keep : Keep_Array := [others => False];
         begin
            for Index in 0 .. Surviving - 1 loop
               declare
                  P : constant N.Wide_Real :=
                    N.Wide_Real (Item.Working.all (Index).Probability);
               begin
                  if P > 0.0 then
                     Entropy := Entropy - P * N.Log (P);
                  end if;
               end;
            end loop;

            for Index in 0 .. Surviving - 1 loop
               declare
                  P : constant N.Wide_Real :=
                    N.Wide_Real (Item.Working.all (Index).Probability);
               begin
                  Away (Index) :=
                    (if P > 0.0 then abs (-N.Log (P) - Entropy) else 0.0);
               end;
               Order (Index) := Index;
            end loop;

            --  Nearest first. Insertion sort over what top-k has already
            --  cut down to, which is tens of candidates rather than the
            --  vocabulary.
            for Index in 1 .. Surviving - 1 loop
               declare
                  Where : Element_Count := Index;
                  Held  : constant Element_Count := Order (Index);
               begin
                  while Where > 0
                    and then Away (Order (Where - 1)) > Away (Held)
                  loop
                     Order (Where) := Order (Where - 1);
                     Where := Where - 1;
                  end loop;
                  Order (Where) := Held;
               end;
            end loop;

            for Index in 0 .. Surviving - 1 loop
               Keep (Order (Index)) := True;
               Kept := Kept + 1;
               Taken := Taken
                 + N.Wide_Real
                     (Item.Working.all (Order (Index)).Probability);
               exit when Taken >= N.Wide_Real (Item.Settings.Typical_P);
            end loop;

            --  Back into probability order, which is the order they were
            --  already in: the kept ones keep their places relative to each
            --  other and the rest close up behind them.
            declare
               Into : Element_Count := 0;
            begin
               for Index in 0 .. Surviving - 1 loop
                  if Keep (Index) then
                     Item.Working.all (Into) := Item.Working.all (Index);
                     Into := Into + 1;
                  end if;
               end loop;
               Surviving := Element_Count'Max (1, Into);
            end;
         end;
      end if;

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

      --  8a  exclude the top choices, some of the time.
      --
      --  Every filter above keeps the likeliest; this throws them away. When
      --  two or more candidates are above the threshold, all but the least
      --  probable of those go, and what is left begins with the one that was
      --  just under them.
      if Item.Settings.XTC_Probability > 0.0 and then Surviving > 1 then
         declare
            Draw : N.Wide_Real;
            Over : Element_Count := 0;
         begin
            Uniform (Item.State, Draw);

            if Draw < N.Wide_Real (Item.Settings.XTC_Probability) then
               for Index in 0 .. Surviving - 1 loop
                  exit when Item.Working.all (Index).Probability
                            < Item.Settings.XTC_Threshold;
                  Over := Index + 1;
               end loop;

               --  Two or more, or there is nothing to exclude: removing the
               --  only likely candidate would leave the tail alone, which is
               --  not what this is for.
               if Over > 1 then
                  for Index in 0 .. Surviving - Over loop
                     Item.Working.all (Index) :=
                       Item.Working.all (Index + Over - 1);
                  end loop;
                  Surviving := Surviving - Over + 1;
               end if;
            end if;
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

         --  And what that choice was worth, for mirostat's target to steer
         --  by. The surprise is measured against the distribution it drew
         --  from, which is the truncated one: measuring against the model's
         --  own would steer by a number this sampler does not control.
         if Item.Settings.Mirostat = 2 then
            declare
               Chosen : N.Wide_Real := 0.0;
            begin
               for Index in 0 .. Surviving - 1 loop
                  if Item.Working.all (Index).Token = Token then
                     Chosen :=
                       N.Wide_Real (Item.Working.all (Index).Probability)
                       / Total;
                     exit;
                  end if;
               end loop;

               if Chosen > 0.0 then
                  Item.Mu :=
                    Item.Mu
                    - Item.Settings.Mirostat_Eta
                      * (Real (-N.Log (Chosen) / N.Log (2.0))
                         - Item.Settings.Mirostat_Tau);
               end if;
            end;
         end if;
      end;

      Status := E.Success;
   end Sample;

end Model_Runner.Sampling;
