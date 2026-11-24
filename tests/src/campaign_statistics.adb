with Ada.Containers.Vectors;
with Jsonlib.Serializers;

package body Campaign_Statistics is

   package J renames Jsonlib.Documents;
   use type J.Value_Kind;
   package Values is new Ada.Containers.Vectors (Positive, Long_Float);
   package Sorted is new Values.Generic_Sorting;

   function Median (List : Values.Vector) return Long_Float is
      Copy : Values.Vector := List;
      Count : constant Natural := Natural (Copy.Length);
   begin
      if Count = 0 then
         return -1.0;
      end if;
      Sorted.Sort (Copy);
      return (if Count mod 2 = 1 then Copy (Count / 2 + 1)
              else (Copy (Count / 2) + Copy (Count / 2 + 1)) / 2.0);
   end Median;

   function Describe
     (From : J.Document; Attempts : J.Node; Default_Only : Boolean := False) return String is
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      Arms : constant J.Node := J.New_Array (Doc);
      Comparisons : constant J.Node := J.New_Array (Doc);
      function Text (Item : J.Node; Key : String) return String is
         Value : constant J.Node := J.Member (From, Item, Key);
      begin
         return (if J.Is_Present (Value) and then J.Kind (From, Value) = J.String_Value
                 then J.As_String (From, Value) else "");
      end Text;
      function Number (Item : J.Node; Key : String) return Long_Float is
         Value : constant J.Node := J.Member (From, Item, Key);
      begin
         return (if J.Is_Present (Value) and then J.Kind (From, Value) in J.Integer_Value | J.Float_Value
                 then J.As_Float (From, Value) else -1.0);
      end Number;
      procedure Count (Into : J.Node; Key : String; N : Natural) is
      begin
         J.Insert (Doc, Into, Key, J.New_Integer (Doc, Long_Long_Integer (N)));
      end Count;
      procedure Metric (Into : J.Node; Key : String; N : Long_Float) is
      begin
         J.Insert (Doc, Into, Key, (if N < 0.0 then J.New_Null (Doc) else J.New_Float (Doc, N)));
      end Metric;
   begin
      J.Set_Root (Doc, Root);
      J.Insert (Doc, Root, "scope", J.New_String (Doc, "descriptive; no independence or significance claim"));
      J.Insert (Doc, Root, "arms", Arms);
      J.Insert (Doc, Root, "comparisons", Comparisons);
      for Arm in 1 .. (if Default_Only then 2 else 4) loop
         declare
            Name : constant String :=
              (if Default_Only then (if Arm = 1 then "base" else "adapted")
               else (case Arm is when 1 => "base-off", when 2 => "adapted-off",
                                when 3 => "base-on", when others => "adapted-on"));
            Item : constant J.Node := J.New_Object (Doc);
            Passed, Failed, Infrastructure, Ungraded : Natural := 0;
            Times, Tokens, Calls : Values.Vector;
         begin
            J.Insert (Doc, Item, "arm", J.New_String (Doc, Name));
            for Index in 1 .. J.Length (From, Attempts) loop
               declare
                  Row : constant J.Node := J.Element (From, Attempts, Index);
               begin
                  if Text (Row, "arm") = Name then
                     if Text (Row, "grade") = "passed" then
                        Passed := Passed + 1;
                     elsif Text (Row, "grade") = "failed" then
                        Failed := Failed + 1;
                     elsif Text (Row, "grade") = "ungraded" then
                        Ungraded := Ungraded + 1;
                     else
                        Infrastructure := Infrastructure + 1;
                     end if;
                     if Number (Row, "work_seconds") >= 0.0 then
                        Times.Append (Number (Row, "work_seconds"));
                     end if;
                     if Number (Row, "generated_tokens") >= 0.0 then
                        Tokens.Append (Number (Row, "generated_tokens"));
                     end if;
                     if Number (Row, "calls") >= 0.0 then
                        Calls.Append (Number (Row, "calls"));
                     end if;
                  end if;
               end;
            end loop;
            Count (Item, "passed", Passed);
            Count (Item, "failed", Failed);
            Count (Item, "infrastructure_errors", Infrastructure);
            Count (Item, "ungraded", Ungraded);
            Count (Item, "time_observations", Natural (Times.Length));
            Metric (Item, "median_work_seconds_all", Median (Times));
            Metric (Item, "median_generated_tokens_all", Median (Tokens));
            Metric (Item, "median_calls_all", Median (Calls));
            J.Append (Doc, Arms, Item);
         end;
      end loop;
      for Mode in 1 .. (if Default_Only then 1 else 2) loop
         declare
            Thinking : constant Boolean := Mode = 2;
            Base : constant String := (if Default_Only then "base" elsif Thinking then "base-on" else "base-off");
            Adapted : constant String :=
              (if Default_Only then "adapted" elsif Thinking then "adapted-on" else "adapted-off");
            Item : constant J.Node := J.New_Object (Doc);
            Wins, Losses, Both_Pass, Both_Fail, Missing, Ineligible : Natural := 0;
            Base_Times, Adapted_Times : Values.Vector;
         begin
            if Default_Only then
               J.Insert (Doc, Item, "thinking_mode", J.New_String (Doc, "unchanged native default"));
            else
               J.Insert (Doc, Item, "thinking", J.New_Boolean (Doc, Thinking));
            end if;
            for Index in 1 .. J.Length (From, Attempts) loop
               declare
                  Row : constant J.Node := J.Element (From, Attempts, Index);
                  Other : J.Node := J.No_Node;
               begin
                  if Text (Row, "arm") = Base then
                     for Candidate in 1 .. J.Length (From, Attempts) loop
                        declare
                           Entry_Row : constant J.Node := J.Element (From, Attempts, Candidate);
                        begin
                           if Text (Entry_Row, "arm") = Adapted
                             and then Text (Entry_Row, "task") = Text (Row, "task")
                             and then Number (Entry_Row, "seed") = Number (Row, "seed")
                           then
                              Other := Entry_Row;
                              exit;
                           end if;
                        end;
                     end loop;
                     if not J.Is_Present (Other) then
                        Missing := Missing + 1;
                     elsif Text (Row, "grade") not in "passed" | "failed"
                       or else Text (Other, "grade") not in "passed" | "failed"
                     then
                        Ineligible := Ineligible + 1;
                     elsif Text (Row, "grade") = "passed" and then Text (Other, "grade") = "passed" then
                        Both_Pass := Both_Pass + 1;
                        if Number (Row, "work_seconds") >= 0.0 and then Number (Other, "work_seconds") >= 0.0 then
                           Base_Times.Append (Number (Row, "work_seconds"));
                           Adapted_Times.Append (Number (Other, "work_seconds"));
                        end if;
                     elsif Text (Row, "grade") = "passed" then
                        Losses := Losses + 1;
                     elsif Text (Other, "grade") = "passed" then
                        Wins := Wins + 1;
                     else
                        Both_Fail := Both_Fail + 1;
                     end if;
                  end if;
               end;
            end loop;
            Count (Item, "adapted_wins", Wins);
            Count (Item, "adapted_losses", Losses);
            Count (Item, "both_passed", Both_Pass);
            Count (Item, "both_failed", Both_Fail);
            Count (Item, "missing_pairs", Missing);
            Count (Item, "ineligible_pairs", Ineligible);
            Count (Item, "both_solved_time_pairs", Natural (Base_Times.Length));
            Metric (Item, "base_median_work_seconds_both_solved", Median (Base_Times));
            Metric (Item, "adapted_median_work_seconds_both_solved", Median (Adapted_Times));
            J.Append (Doc, Comparisons, Item);
         end;
      end loop;
      return Jsonlib.Serializers.To_String (Doc);
   end Describe;

end Campaign_Statistics;
