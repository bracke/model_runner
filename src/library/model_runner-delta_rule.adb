with Model_Runner.Delta_Rule.Plain;
with Model_Runner.Delta_Rule.Wide;

package body Model_Runner.Delta_Rule is

   Wider : Boolean := False;

   procedure Use_Wide (Allowed : Boolean) is
   begin
      Wider := Allowed;
   end Use_Wide;

   procedure Chunk
     (State        : in out Real_Array;
      From         : Element_Count;
      Written      : Slot_Origins;
      Head         : Element_Count;
      Count        : Element_Count;
      Mixed        : Real_Array;
      Stride       : Element_Count;
      Key_At       : Element_Count;
      Query_At     : Element_Count;
      Value_At     : Element_Count;
      Decay        : Real_Array;
      Rate         : Real_Array;
      Z_Gate       : Real_Array;
      Z_At         : Element_Count;
      Z_Stride     : Element_Count;
      Blend        : in out Real_Array;
      Blend_At     : Element_Count;
      Blend_Stride : Element_Count;
      State_Norm   : Real_Array;
      Epsilon      : Real;
      Scale        : Real) is
   begin
      --  One source, two compilations, and the host decides which: each
      --  is entered only where the host says it has the instructions,
      --  which it is asked once and told here.
      if Wider then
         Wide.Chunk
           (State, From, Written, Head, Count, Mixed, Stride, Key_At,
            Query_At, Value_At, Decay, Rate, Z_Gate, Z_At, Z_Stride, Blend,
            Blend_At, Blend_Stride, State_Norm, Epsilon, Scale);
      else
         Plain.Chunk
           (State, From, Written, Head, Count, Mixed, Stride, Key_At,
            Query_At, Value_At, Decay, Rate, Z_Gate, Z_At, Z_Stride, Blend,
            Blend_At, Blend_Stride, State_Norm, Epsilon, Scale);
      end if;
   end Chunk;

end Model_Runner.Delta_Rule;
