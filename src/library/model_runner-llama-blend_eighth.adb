separate (Model_Runner.Llama)
procedure Blend_Eighth
  (Held       : Cache_Precision;
   V_Held     : Cache_Precision;
   Query      : Real_Array;
   Keys       : B.Byte_Array;
   Values     : B.Byte_Array;
   Key_Scales : Real_Array;
   Val_Scales : Real_Array;
   K_Base     : Element_Count;
   V_Base     : Element_Count;
   Rows       : Element_Count;
   KV_Width   : Element_Count;
   V_Width    : Element_Count;
   Heads      : Element_Count;
   Head_Size  : Element_Count;
   Value_Size : Element_Count;
   Group_Size : Element_Count;
   First      : Element_Count;
   Last       : Element_Count;
   Scale      : Real;
   Cap        : Real;
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

   --  As in Blend_Exact above, and for the reason written there: the
   --  overflow branch after every computed index, with the bounds check
   --  that catches a wrap left in place.
   pragma Suppress (Overflow_Check);
begin
   Ok := True;

   for Head in From_Head .. To_Head loop
      declare
         Group    : constant Element_Count := Head / Group_Size;
         At_Score : constant Element_Count :=
           Scores'First + Head * Score_Room;
         Q_Origin : constant Element_Count := Query'First + Head * Head_Size;
         Usable   : Boolean;
      begin
         for Step in First .. Last loop
            if Held = Fourth then
               Scores (At_Score + Step) :=
                 K.Head_Dot_Fourth
                   (Left     => Query,
                    At_Left  => Q_Origin,
                    Right    => Keys,
                    At_Row   => B.Byte_Count (Keys'First)
                                + Byte_Of (Fourth, K_Base + Step * KV_Width,
                                           KV_Width),
                    Offset   => Group * Head_Size,
                    Scales   => Key_Scales,
                    At_Scale => Key_Scales'First
                                + Scale_Of (Fourth, K_Base + Step * KV_Width,
                                            KV_Width),
                    Span     => Head_Size)
                 * Scale;
            else
               declare
                  Origin : constant B.Byte_Count :=
                    B.Byte_Count (Keys'First)
                    + B.Byte_Count (K_Base + Step * KV_Width
                                    + Group * Head_Size);
                  Row    : constant Real :=
                    Key_Scales (Key_Scales'First + Rows + Step);
               begin
                  Scores (At_Score + Step) :=
                    K.Head_Dot_Eighth
                      (Left     => Query,
                       At_Left  => Q_Origin,
                       Right    => Keys,
                       At_Right => Origin,
                       Scale    => Row,
                       Span     => Head_Size)
                    * Scale;
               end;
            end if;
         end loop;

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

         --  A run of components at a time rather than one, and summed
         --  in binary32, for the reasons written out in Blend_Exact: a
         --  position's values are contiguous, and a map in binary32 is
         --  eight lanes an instruction where binary64 is four.
         declare
            Run : constant Element_Count := 64;
            At_Component : Element_Count := 0;
         begin
            while At_Component < Value_Size loop
               declare
                  Here : constant Element_Count :=
                    Element_Count'Min (Run, Value_Size - At_Component);
                  Sums : Real_Array (0 .. Here - 1) := [others => 0.0];
               begin
                  if V_Held = Fourth then
                     K.Blend_Run_Fourth
                       (Sums      => Sums,
                        Weights   => Scores,
                        At_Weight => At_Score + First,
                        Scales    => Val_Scales,
                        At_Scale  => Val_Scales'First
                                     + Scale_Of (Fourth, V_Base + First * V_Width,
                                                 V_Width),
                        Blocks    => Blocks_Of (Fourth, V_Width),
                        Values    => Values,
                        At_Row    => Values'First
                                     + Byte_Of (Fourth, V_Base + First * V_Width,
                                                V_Width),
                        Row_Bytes => Row_Bytes (Fourth, V_Width),
                        Offset    => Group * Value_Size + At_Component,
                        Steps     => Last - First + 1);
                  else
                     K.Blend_Run_Eighth
                       (Sums      => Sums,
                        Weights   => Scores,
                        At_Weight => At_Score + First,
                        Scales    => Val_Scales,
                        At_Scale  => Val_Scales'First + Rows + First,
                        Values    => Values,
                        At_Value  =>
                          Values'First
                          + B.Byte_Count (V_Base + First * V_Width
                                          + Group * Value_Size
                                          + At_Component),
                        Stride    => V_Width,
                        Steps     => Last - First + 1);
                  end if;

                  for Component in 0 .. Here - 1 loop
                     Target (Target'First + Head * Value_Size
                             + At_Component + Component) :=
                       Sums (Component);
                  end loop;

                  At_Component := At_Component + Here;
               end;
            end loop;
         end;
      end;
   end loop;
end Blend_Eighth;
