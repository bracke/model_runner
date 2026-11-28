with Model_Runner.Backend.CPU.Packing_Testing;
package body Model_Runner.Llama.Adapter_Testing is

   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Numerics.Element_Count;

   function Device_Expert_Contracts_Match (Item : Model) return Boolean is
      package E renames Model_Runner.Errors;
      package T renames Model_Runner.Tensors;
      use type T.Weight_Role;
      Gate, Up, Down : T.View;
      Status : E.Error_Info;
      Checked : Boolean := False;
      function Same (Left, Right : T.View) return Boolean is
        (Left.Role = Right.Role and then Left.Reference_Activations = Right.Reference_Activations);
   begin
      if not Item.Ready or else Item.Layers = null then
         return False;
      end if;
      for Current of Item.Layers.all loop
         if Current.Experts /= null then
            for Which in Current.Experts'Range loop
               Device_Expert_Views
                 (Current, Which, Current.Experts (Which).Gate.Rows,
                  Current.Experts (Which).Down.Rows, Gate, Up, Down, Status);
               if not E.Is_Ok (Status)
                 or else not Same (Gate, Current.Experts (Which).Gate)
                 or else not Same (Up, Current.Experts (Which).Up)
                 or else not Same (Down, Current.Experts (Which).Down)
               then
                  return False;
               end if;
               Checked := True;
            end loop;
         end if;
      end loop;
      return Checked;
   end Device_Expert_Contracts_Match;

   procedure Pick_Experts (Scores : Real_Array; Result : out Real_Array) is
      Ids : Choice_List (0 .. 7);
   begin
      Pick_Eight_Of_128 (Scores, Ids);
      for I in Ids'Range loop Result (Result'First + Element_Count (I)) := Real (Ids (I)); end loop;
   end Pick_Experts;

   function Mixture_Storage (Live : Session) return System.Address is
      package PT renames Model_Runner.Backend.CPU.Packing_Testing;
      use type System.Address;
      First : constant System.Address := PT.Storage (Live.Mixture_Super);
   begin
      return (if First /= System.Null_Address then First else PT.Storage (Live.Mixture_Plain));
   end Mixture_Storage;
   function Has_Head_Rows (Live : Session) return Boolean is (Live.Inkling_Head_Rows /= null);
   procedure Grouped_Draft_Dots (Queries, Key : Real_Array; Width, Many : Element_Count;
                                 Result : out Real_Array) is
   begin
      Draft_Dots (Queries, Key, Width, Many, Result);
   end Grouped_Draft_Dots;
   procedure Grouped_Draft_Values (Value, Gains : Real_Array; Into : in out Real_Array;
                                   Stride, Many : Element_Count) is
   begin
      Draft_Values (Value, Gains, Into, Stride, Many);
   end Grouped_Draft_Values;

   function Scalar_Exp (Value : Real) return Real is (Reference_Attention_Exp (Value));
   procedure Vector_Exp (Values : in out Real_Array; Subtract : Real) is
   begin Draft_Exp (Values, Subtract); end Vector_Exp;
   procedure Vector_Activate (Gate : in out Real_Array; Up : Real_Array) is
   begin Draft_Activate (Gate, Up); end Vector_Activate;
   procedure Rotation (Values : in out Real_Array; Heads, Width : Element_Count;
                       Position : Natural; Base : Wide_Real; Reused : Boolean) is
      Table : Real_Array (7 .. 7 + Width - 1);
   begin
      if Reused then
         Draft_Rotation (Width, Position, Base, Table);
         Draft_Apply_Rotation (Values, Heads, Width, Table);
      else Draft_Rotate (Values, Heads, Width, Position, Base);
      end if;
   end Rotation;
   function Plan_Slots (Live : Session) return Natural is
     (if Live.Inkling_Plans = null then 0 else Live.Inkling_Plans'Length);
   function Residual_Runs (Live : Session) return Interfaces.Unsigned_64 is (Live.Draft_Residual_Runs);
   procedure Residual_Project
     (Live : in out Session; Weight : Model_Runner.Tensors.View; Input : Real_Array; Count : Positive;
      Output : in out Real_Array; Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null)
   is
      package T renames Model_Runner.Tensors;
      Saved : constant Model_Runner.Cancellation.Token_Reference := Live.Stopping;
      Data : T.Real_Array_Access := new Real_Array'(Input);
      Into : T.Real_Array_Access := new Real_Array'(Output);
      Room : T.Real_Array_Access := new Real_Array (Output'Range);
   begin
      Live.Stopping := Cancel;
      Draft_Product_Add (Live, Weight, Data, Element_Count (Count), Into, Room, Status);
      Output := Into.all;
      Live.Stopping := Saved;
      T.Free (Data); T.Free (Into); T.Free (Room);
   exception
      when others =>
         Live.Stopping := Saved;
         T.Free (Data); T.Free (Into); T.Free (Room); raise;
   end Residual_Project;

   procedure Proposal_Project
     (Live : Session; Weight : Model_Runner.Tensors.View; Input : Real_Array; Count : Positive;
      Output : in out Real_Array; Status : out Model_Runner.Errors.Error_Info)
   is
      package T renames Model_Runner.Tensors;
      Data : T.Real_Array_Access := new Real_Array'(Input);
      Into : T.Real_Array_Access := new Real_Array'(Output);
   begin
      Draft_Project_Proposals (Live, Weight, Data, Element_Count (Count), Into, Status);
      Output := Into.all;
      T.Free (Data); T.Free (Into);
   exception
      when others => T.Free (Data); T.Free (Into); raise;
   end Proposal_Project;

   procedure Accumulate
     (Live : in out Session; Weight : Model_Runner.Tensors.View;
      Input : Model_Runner.Numerics.Real_Array; Count : Model_Runner.Numerics.Element_Count;
      Output : in out Model_Runner.Numerics.Real_Array; Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null)
   is
      Saved : constant Model_Runner.Cancellation.Token_Reference := Live.Stopping;
   begin
      Live.Stopping := Cancel;
      Apply_Adapters_Batch (Live, Weight, Input, Count, Output, Status);
      Live.Stopping := Saved;
   exception
      when others => Live.Stopping := Saved; raise;
   end Accumulate;

   procedure Project
     (Live : Session; Weight : Model_Runner.Tensors.View; Input : Model_Runner.Numerics.Real_Array;
      Count : Positive; Output : out Model_Runner.Numerics.Real_Array;
      Status : out Model_Runner.Errors.Error_Info)
   is
      package T renames Model_Runner.Tensors;
      Data, Result : T.Real_Array_Access := null;
   begin
      Output := [others => 0.0];
      T.Allocate (Input'Length, Data);
      T.Allocate (Output'Length, Result);
      if Data = null or else Result = null then
         Status := Model_Runner.Errors.Make (Model_Runner.Errors.Memory_Allocation_Failed);
      else
         Data.all := Input;
         if Count = 1 then
            Product (Live, Weight, Data, Result, Status);
         else
            Product_Batch (Live, Weight, Data, Model_Runner.Numerics.Element_Count (Count), Result, Status);
         end if;
         Output := Result.all;
      end if;
      T.Free (Data);
      T.Free (Result);
   exception
      when others => T.Free (Data); T.Free (Result); raise;
   end Project;

   function Stem (Which : Projection) return String is
     (case Which is
        when Attention_Query => "attn_q", when Attention_Key => "attn_k",
        when Attention_Value => "attn_v", when Attention_Output => "attn_output",
        when Feed_Gate => "ffn_gate", when Feed_Up => "ffn_up", when Feed_Down => "ffn_down");

   procedure Read_Projection
     (Item : Model; Layer_Index : Natural; Which : Projection;
      Result : out Model_Runner.Tensors.View; Status : out Model_Runner.Errors.Error_Info)
   is
      package T renames Model_Runner.Tensors;
      package E renames Model_Runner.Errors;
   begin
      Result := T.Empty_View;
      Status := E.Success;
      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
      elsif Item.Layers = null or else Layer_Index not in Item.Layers'Range then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
      else
         Result := (case Which is
                      when Attention_Query => Item.Layers (Layer_Index).Query,
                      when Attention_Key => Item.Layers (Layer_Index).Key,
                      when Attention_Value => Item.Layers (Layer_Index).Value,
                      when Attention_Output => Item.Layers (Layer_Index).Attention_Out,
                      when Feed_Gate => Item.Layers (Layer_Index).Gate,
                      when Feed_Up => Item.Layers (Layer_Index).Up,
                      when Feed_Down => Item.Layers (Layer_Index).Down);
         if not T.Is_Present (Result) then
            Status := E.Make (E.Arch_Missing_Tensor);
         end if;
      end if;
   end Read_Projection;

   procedure Poison_Scratch (Live : in out Session; Value : Model_Runner.Numerics.Real) is
   begin
      if Live.Inkling_Arena /= null then
         Live.Inkling_Arena.all := [others => Value];
      end if;
   end Poison_Scratch;

end Model_Runner.Llama.Adapter_Testing;
