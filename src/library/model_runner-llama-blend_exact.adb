separate (Model_Runner.Llama)
procedure Blend_Exact
  (Query      : Real_Array;
   Keys       : Real_Array;
   Values     : Real_Array;
   K_Base     : Element_Count;
   V_Base     : Element_Count;
   KV_Width   : Element_Count;
   V_Width    : Element_Count;
   Heads      : Element_Count;
   Head_Size  : Element_Count;
   Value_Size : Element_Count;
   Group_Size : Element_Count;
   First      : Element_Count;
   Last       : Element_Count;
   Scale      : Real;

   --  The bound the architecture states on a score, or zero for none.
   Cap        : Real;

   --  How steeply attention falls off with distance, or zero for an
   --  architecture that says where a token is some other way, and where
   --  the query itself is. The second is not Last: for a model that
   --  reads a whole text at once every slot of the batch sees the same
   --  last position, so the query's own position never reaches here
   --  unless it is passed. It has no default for that reason.
   Max_Bias   : Real;
   Query_At   : Element_Count;

   --  One score a head that joins the softmax's denominator and takes
   --  none of the weight, or null for an architecture that states none.
   Sinks      : Model_Runner.Tensors.Real_Array_Access;

   --  The heads this call is to blend, and how far apart the rows of the
   --  score buffer are.
   --
   --  A head at a time was one buffer for all of them, which is right
   --  when one task walks the heads in order and wrong the moment two do
   --  it at once: the scores of a head are written, softmaxed and read
   --  back within its own iteration, so two heads sharing them is two
   --  heads answering with each other's arithmetic. A row apiece is what
   --  lets a share of the heads run beside another share.
   From_Head  : Element_Count;
   To_Head    : Element_Count;
   Score_Room : Element_Count;
   Scores     : in out Real_Array;
   Target     : out Real_Array;
   Ok         : out Boolean) is

   --  Overflow checking off here, and bounds checking left alone.
   --
   --  A profile of a prompt put the exact blend at eleven per cent of it
   --  and said what the eleven per cent was: fifty-four per cent of the
   --  samples on 64-bit moves and twenty per cent on `jo`, the overflow
   --  branch after every index it computes. Not one of the ten hottest
   --  instructions was a multiply. These three blends are the only loops
   --  in the engine's own arithmetic that were never given the
   --  suppressions the integer kernels carry, and it shows.
   --
   --  Overflow rather than bounds, on purpose, and the two are not the
   --  same guard. What is dropped is the check that an index computation
   --  does not wrap: every value in one is an element count of a model
   --  this program has already validated, and wrapping needs numbers far
   --  larger than the widest tensor a file may declare. What is kept is
   --  the check that the index it produces is inside the array -- so a
   --  wrap that somehow happened would still be refused rather than
   --  read, and the note at the top of this unit that says bounds and
   --  range checking are untouched stays true.
   pragma Suppress (Overflow_Check);

   --  And bounds checking, once the ranges below are proved.
   --
   --  With the overflow branch gone a second profile said the same thing
   --  again: forty-six per cent of this procedure was `cmpq` and fifteen
   --  more the address arithmetic feeding it, against twenty-nine per
   --  cent doing the multiply-adds it exists for. Six index checks an
   --  element, on indices that differ from the last by a constant.
   --
   --  So they are proved once instead, which is what the integer kernels
   --  do and say: every index this procedure forms is a fixed function
   --  of the loop bounds, so the largest of each is computed below and
   --  compared against the array it will index. A call that would step
   --  outside is refused through Ok, which is a path the caller already
   --  handles because the softmax further down can refuse too.
   pragma Suppress (Index_Check);
   pragma Suppress (Range_Check);

   --  The largest head's group, which is what fixes the reach into the
   --  keys and the values.
   Group_Top : constant Element_Count :=
     (if Group_Size = 0 then 0 else To_Head / Group_Size);
begin
   Ok := True;

   --  Nothing to do is not a refusal.
   if To_Head < From_Head or else Last < First then
      return;
   end if;

   --  Every index the loops below will form, at its largest. The
   --  products are of dimensions a model file declared and this program
   --  validated when it read them, which is the same footing the row
   --  kernels' own reach check stands on.
   if Group_Size = 0
     or else Head_Size = 0
     or else Scores'Length < To_Head * Score_Room + Last + 1
     or else Query'Length < To_Head * Head_Size + Head_Size
     or else Keys'Length
               < K_Base + Last * KV_Width + Group_Top * Head_Size
                 + Head_Size
     or else Values'Length
               < V_Base + Last * V_Width + Group_Top * Value_Size
                 + Value_Size
     or else Target'Length < To_Head * Value_Size + Value_Size
   then
      Ok := False;
      return;
   end if;

   --  Every head's scores first, with the position outside the head.
   --
   --  A head at a time walked the whole key cache for itself, and the
   --  next head walked it again: a 1419-position context is 363 kilobytes
   --  of keys a group, streamed once for each of the heads that share
   --  them. With the position outside, the heads of a share read the same
   --  key row one after another and it is in the nearest cache for all
   --  but the first -- the same change the value blend below already
   --  had made to it, for the same reason, and this loop was left.
   --
   --  It is worth what it is worth because this loop is sixty-five per
   --  cent of attending and twenty-seven per cent of a processor prompt:
   --  emptying it takes a 1419-token prompt from 16.11 s to 11.96.
   --
   --  Bit for bit what it replaces. Each score is the same expression
   --  over the same components in the same order; what changed is which
   --  score is computed when, and no two of them touch.
   --  A block of positions at a time, and every head across that block
   --  before the next one.
   --
   --  Neither of the two obvious orders. Position outside head reads the
   --  key cache once, which is what the paragraph above is about, but it
   --  asks for one score at a time and a score costs a horizontal fold
   --  of about twenty cycles standing behind eight multiply-adds worth
   --  eight -- four per cent of a prompt, measured by removing it. Head
   --  outside position lets eight keys share one fold, and walks the
   --  whole cache again for every head.
   --
   --  Eight positions at a time has both: the eight key rows a block
   --  needs are eight kilobytes for this architecture and stay in the
   --  nearest cache while all thirty-two heads read them, and each head
   --  gets its eight scores from one run with one fold at the end.
   --
   --  Both loops are inside the kernel now and neither is written here.
   --  They were: a block loop around a head loop around a call, and the
   --  call was ten arguments and six reach comparisons and three index
   --  checks in front of sixty-four multiply-adds. Handing it the whole
   --  range instead proves the reach once and issues the runs in place,
   --  which is four per cent of the instructions a prompt executes.
   K.Head_Scores_Across
     (Query     => Query,
      At_Query  => Query'First,
      Keys      => Keys,
      At_Key    => Keys'First + K_Base + First * KV_Width,
      Stride    => KV_Width,
      Steps     => Last - First + 1,
      Span      => Head_Size,
      From_Head => From_Head,
      To_Head   => To_Head,
      Share     => Group_Size,
      Room      => Score_Room,
      Scale     => Scale,
      Scores    => Scores,
      At_Score  => Scores'First + First);

   for Head in From_Head .. To_Head loop
      declare
         At_Score : constant Element_Count :=
           Scores'First + Head * Score_Room;
         Usable   : Boolean;
      begin

         --  The bound afterwards, in a loop of its own, and only when
         --  there is one. Applied inside the loop above it cost every
         --  architecture a test per score -- twelve tokens went from
         --  1.83 s to 2.07 s and the processor time with it, for a
         --  feature one architecture of six uses.
         --  And the fall-off with distance, in a loop of its own for the
         --  same reason and under the same guard. Unsigned, because the
         --  one architecture that takes it reads a whole text and a
         --  position is as far from what follows it as from what came
         --  before.
         declare
            Slope : constant Real := Head_Slope (Max_Bias, Head, Heads);
         begin
            if Slope > 0.0 then
               for Step in First .. Last loop
                  Scores (At_Score + Step) :=
                    Scores (At_Score + Step)
                    - Slope
                      * Real (abs (Integer (Step) - Integer (Query_At)));
               end loop;
            end if;
         end;

         if Cap > 0.0 then
            for Step in First .. Last loop
               Scores (At_Score + Step) :=
                 Capped (Scores (At_Score + Step), Cap);
            end loop;
         end if;

         --  With this head's sink where the architecture states one,
         --  which joins the denominator and takes none of the weight.
         if Sinks /= null then
            K.Softmax
              (Scores (At_Score + First .. At_Score + Last),
               Sinks.all (Sinks.all'First + Element_Count (Head)),
               Usable);
         else
            K.Softmax
              (Scores (At_Score + First .. At_Score + Last), Usable);
         end if;
         if not Usable then
            Ok := False;
            return;
         end if;

      end;
   end loop;

   --  The blend, with the positions outside the heads.
   --
   --  Eight heads share one key head's values -- that is what a grouped
   --  query is -- so the shape this replaces read the same values eight
   --  times over, once for each head that wanted them, and a whole
   --  position range is far larger than the nearest cache. A tile of
   --  sixteen positions is sixteen kilobytes of values against
   --  thirty-two of cache, and every head after the first reads them
   --  where the first left them.
   --
   --  It is the same argument the score loop above makes about eight
   --  positions at a time, made about the other half of attention. What
   --  it costs is the accumulators: they live in memory between tiles
   --  rather than only at the ends, which is a load and a store of each
   --  every sixteen positions.
   --
   --  A run of components at a time rather than all of them because the
   --  run is on the stack and a head's width is a model's to choose;
   --  summed in binary32 and not the binary64 this once kept, for the
   --  reason the score dot product gives.
   declare
      Run   : constant Element_Count := 64;
      Rooms : constant Element_Count := To_Head - From_Head + 1;

      --  A tile only where there is something to reuse. A tile costs a
      --  load and a store of every accumulator at each of its ends, and
      --  buys the second and later heads their values out of the nearest
      --  cache; a range short enough to sit in that cache whole has
      --  nothing to buy and pays anyway. Generating is the case: a run
      --  of sixty-four tokens looks back over seventy positions and lost
      --  a fifth of itself to tiles it did not need.
      Tile  : constant Element_Count :=
        (if Last - First + 1 <= 128 then Last - First + 1 else 16);

      At_Component : Element_Count := 0;
   begin
      while At_Component < Value_Size loop
         declare
            Here : constant Element_Count :=
              Element_Count'Min (Run, Value_Size - At_Component);

            Sums : Real_Array (0 .. Rooms * Here - 1) := [others => 0.0];

            At_Step : Element_Count := First;
         begin
            while At_Step <= Last loop
               declare
                  Take : constant Element_Count :=
                    Element_Count'Min (Tile, Last - At_Step + 1);
               begin
                  for Head in From_Head .. To_Head loop
                     declare
                        Group : constant Element_Count :=
                          Head / Group_Size;
                        Mine  : constant Element_Count :=
                          (Head - From_Head) * Here;
                     begin
                        K.Blend_Run
                          (Sums      => Sums (Mine .. Mine + Here - 1),
                           Weights   => Scores,
                           At_Weight =>
                             Scores'First + Head * Score_Room + At_Step,
                           Values    => Values,
                           At_Value  =>
                             Values'First + V_Base + At_Step * V_Width
                             + Group * Value_Size + At_Component,
                           Stride    => V_Width,
                           Steps     => Take);
                     end;
                  end loop;

                  At_Step := At_Step + Take;
               end;
            end loop;

            for Head in From_Head .. To_Head loop
               declare
                  Mine : constant Element_Count :=
                    (Head - From_Head) * Here;
               begin
                  for Component in 0 .. Here - 1 loop
                     Target (Target'First + Head * Value_Size
                             + At_Component + Component) :=
                       Sums (Mine + Component);
                  end loop;
               end;
            end loop;

            At_Component := At_Component + Here;
         end;
      end loop;
   end;
end Blend_Exact;
