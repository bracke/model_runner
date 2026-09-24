with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Deallocation;
with Interfaces;
with System.Storage_Elements;

with Model_Runner.Backend.Device;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Kernels;
with Model_Runner.Platform;
with Model_Runner.Shares;
with Model_Runner.Text;
with Model_Runner.Vision.Plain;
with Model_Runner.Vision.Wide;

package body Model_Runner.Vision is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package K renames Model_Runner.Kernels;
   package N renames Model_Runner.Numerics;
   package Containers renames Model_Runner.GGUF.Containers;
   package CPU renames Model_Runner.Backend.CPU;

   subtype Real is N.Real;
   subtype Element_Count is N.Element_Count;

   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type Element_Count;
   use type Real;
   use type N.Wide_Real;
   use type System.Storage_Elements.Integer_Address;
   use type T.Real_Array_Access;
   use type System.Address;
   use type Interfaces.Unsigned_64;

   package Elementary is
     new Ada.Numerics.Generic_Elementary_Functions (N.Wide_Real);

   procedure Free is new Ada.Unchecked_Deallocation
     (Block_Array, Block_Array_Access);

   --  The two projectors this build carries.
   Gemma_3 : constant String := "gemma3";
   Qwen_3  : constant String := "qwen3vl_merger";

   --  Qwen2-VL's merger is Qwen3-VL's without the deepstack layers, which
   --  Qwen3-VL adds and this refuses either way: the same window merge, the
   --  same two-word position of a patch, the same full attention over the
   --  patches, the same two-projection head, the same block of a
   --  normalization, a biased attention and a gated feed-forward. So it
   --  runs the Qwen path, told apart only by the name the file carries.
   Qwen_2  : constant String := "qwen2vl_merger";

   function Is_Qwen (Item : Encoder) return Boolean
   is (Item.Kind (1 .. Item.Kind_Last) = Qwen_3
       or else Item.Kind (1 .. Item.Kind_Last) = Qwen_2);

   --  MiniCPM-V's projector, a resampler over a SigLIP encoder, which the
   --  file names for the resampler rather than the model.
   Resampler : constant String := "resampler";

   function Is_Minicpm (Item : Encoder) return Boolean
   is (Item.Kind (1 .. Item.Kind_Last) = Resampler);

   --  MiniCPM-V 4.6's projector: the same SigLIP encoder the resampler runs,
   --  but with a downsample-MLP head in place of the resampler -- a 2x2
   --  spatial merge of the patch grid, a normalization, and a widening
   --  feed-forward with an error-function unit. The file names it for the
   --  version rather than the resampler, since there is no resampler here.
   Minicpm_46 : constant String := "minicpmv4_6";

   function Is_Minicpm46 (Item : Encoder) return Boolean
   is (Item.Kind (1 .. Item.Kind_Last) = Minicpm_46);

   ------------------
   -- Bind helpers --
   ------------------

   --  A view over a named tensor of the given shape, in the file's own
   --  format, where it lies.
   procedure Bind
     (Item    : in out Encoder;
      Name    : String;
      Rows    : Element_Count;
      Columns : Element_Count;
      Result  : out T.View;
      Status  : out E.Error_Info)
   is
      Index : constant Natural := Containers.Find_Tensor (Item.Container, Name);
   begin
      Result := T.Empty_View;
      Status := E.Success;

      if Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         return;
      end if;

      if not Containers.Tensor_Is_Supported (Item.Container, Index) then
         Status := E.Make (E.Arch_Invalid_Tensor_Format);
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
         E.Add_Text
           (Status, "format",
            Model_Runner.GGUF.Type_Name
              (Containers.Tensor_Format (Item.Container, Index)),
            E.Param_Identifier);
         return;
      end if;

      --  The shape, read as rows of columns: the leading axes that
      --  multiply to Columns are the row -- a patch's three channels of
      --  fourteen by fourteen are one row of 588 -- and the rest are the
      --  rows.
      declare
         Rank : constant Positive :=
           Containers.Tensor_Rank (Item.Container, Index);
         Contiguous : Element_Count := 1;
         Remaining  : Element_Count := 1;
         Axis : Positive := 1;
      begin
         while Axis <= Rank and then Contiguous < Columns loop
            Contiguous := Contiguous
              * Element_Count
                  (Containers.Tensor_Dimension (Item.Container, Index, Axis));
            Axis := Axis + 1;
         end loop;
         while Axis <= Rank loop
            Remaining := Remaining
              * Element_Count
                  (Containers.Tensor_Dimension (Item.Container, Index, Axis));
            Axis := Axis + 1;
         end loop;

         if Contiguous /= Columns or else Remaining /= Rows then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Contiguous));
            E.Add_Integer (Status, "rows", Long_Long_Integer (Remaining));
            E.Add_Integer
              (Status, "expected_columns", Long_Long_Integer (Columns));
            E.Add_Integer (Status, "expected_rows", Long_Long_Integer (Rows));
            return;
         end if;
      end;

      T.Make
        (Format  => Containers.Tensor_Format (Item.Container, Index),
         Rows    => Rows,
         Columns => Columns,
         Base    => Item.Base,
         Span    => Item.Span,
         Offset  =>
           B.Byte_Count (Containers.Tensor_Offset (Item.Container, Index))
           - B.Byte_Count (Containers.Data_Offset (Item.Container)),
         Result  => Result,
         Status  => Status);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
      end if;
   end Bind;

   --  A vector of the given length, decoded once from a named tensor.
   procedure Bind_Vector
     (Item   : in out Encoder;
      Name   : String;
      Length : Element_Count;
      Result : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      View : T.View;
   begin
      Result := null;
      Bind (Item, Name, 1, Length, View, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      T.Allocate (Length, Result);
      if Result = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      T.Dequantize_Row (View, 0, Result.all, Status);
   end Bind_Vector;

   --  The Qwen encoder's tensors: the two temporal frames' patch weights
   --  decoded and summed once, since a still picture is the same frame
   --  twice; the position grid; each block's fused projection, output,
   --  norms and feed-forward; the post norm; and the two-step merger.
   procedure Bind_Qwen (Item : in out Encoder; Status : out E.Error_Info) is
      Width   : constant Element_Count := Element_Count (Item.Width);
      Feed    : constant Element_Count := Element_Count (Item.Feed);
      Patch_Elements : constant Element_Count :=
        3 * Element_Count (Item.Patch) ** 2;
      Text_Width : constant Element_Count := Element_Count (Item.Text_Width);
      Joined  : constant Element_Count :=
        Width * Element_Count (Item.Merge) ** 2;
   begin
      Status := E.Success;

      declare
         First, Second : T.View;
         Row : T.Real_Array_Access;
      begin
         Bind (Item, "v.patch_embd.weight", Width, Patch_Elements, First, Status);
         if E.Is_Ok (Status) then
            Bind (Item, "v.patch_embd.weight.1", Width, Patch_Elements, Second,
                  Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;
         T.Allocate (Width * Patch_Elements, Item.Patch_Sum);
         T.Allocate (Patch_Elements, Row);
         if Item.Patch_Sum = null or else Row = null then
            T.Free (Row);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
         --  And the two side by side, a row the first frame's then the
         --  second's, for a pair of frames of a video.
         T.Allocate (Width * 2 * Patch_Elements, Item.Patch_Pair_Rows);
         if Item.Patch_Pair_Rows = null then
            T.Free (Row);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
         for Source_Row in 0 .. Width - 1 loop
            T.Dequantize_Row
              (First, Source_Row,
               Item.Patch_Sum (Source_Row * Patch_Elements
                               .. (Source_Row + 1) * Patch_Elements - 1),
               Status);
            exit when E.Is_Error (Status);
            Item.Patch_Pair_Rows
              (Source_Row * 2 * Patch_Elements
               .. Source_Row * 2 * Patch_Elements + Patch_Elements - 1) :=
              Item.Patch_Sum (Source_Row * Patch_Elements
                              .. (Source_Row + 1) * Patch_Elements - 1);
            T.Dequantize_Row (Second, Source_Row, Row.all, Status);
            exit when E.Is_Error (Status);
            Item.Patch_Pair_Rows
              (Source_Row * 2 * Patch_Elements + Patch_Elements
               .. (Source_Row + 1) * 2 * Patch_Elements - 1) := Row.all;
            K.Add
              (Item.Patch_Sum (Source_Row * Patch_Elements
                               .. (Source_Row + 1) * Patch_Elements - 1),
               Row.all);
         end loop;
         T.Free (Row);
         if E.Is_Error (Status) then
            return;
         end if;
         T.Make
           (Format  => Model_Runner.GGUF.Type_F32,
            Rows    => Width,
            Columns => Patch_Elements,
            Base    => Item.Patch_Sum.all'Address,
            Span    => B.Byte_Count (Item.Patch_Sum.all'Length) * 4,
            Offset  => 0,
            Result  => Item.Patch_Both,
            Status  => Status);
         if E.Is_Error (Status) then
            return;
         end if;
         T.Make
           (Format  => Model_Runner.GGUF.Type_F32,
            Rows    => Width,
            Columns => 2 * Patch_Elements,
            Base    => Item.Patch_Pair_Rows.all'Address,
            Span    => B.Byte_Count (Item.Patch_Pair_Rows.all'Length) * 4,
            Offset  => 0,
            Result  => Item.Patch_Pair,
            Status  => Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end;

      Bind_Vector (Item, "v.patch_embd.bias", Width, Item.Patch_Bias, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The position grid: as many rows as the grid has cells, and a
      --  side that is their square root.
      declare
         Index : constant Natural :=
           Containers.Find_Tensor (Item.Container, "v.position_embd.weight");
         Cells : Element_Count := 0;
      begin
         if Index > 0
           and then Containers.Tensor_Rank (Item.Container, Index) = 2
         then
            Cells := Element_Count
              (Containers.Tensor_Dimension (Item.Container, Index, 2));
         end if;
         Item.Grid := 1;
         while Element_Count (Item.Grid + 1) ** 2 <= Cells loop
            Item.Grid := Item.Grid + 1;
         end loop;
         if Cells = 0 or else Element_Count (Item.Grid) ** 2 /= Cells then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text
              (Status, "tensor", "v.position_embd.weight", E.Param_Identifier);
            E.Add_Integer (Status, "rows", Long_Long_Integer (Cells));
            return;
         end if;
         Bind (Item, "v.position_embd.weight", Cells, Width, Item.Positions,
               Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end;

      Bind_Vector (Item, "v.post_ln.weight", Width, Item.Post_Weight, Status);
      if E.Is_Ok (Status) then
         Bind_Vector (Item, "v.post_ln.bias", Width, Item.Post_Bias, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      Item.Layers := new Block_Array (0 .. Item.Blocks - 1);
      for Index in Item.Layers'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
              & ".";
            Current : Block renames Item.Layers (Index);

            procedure Take
              (Suffix : String; Rows, Columns : Element_Count;
               Into : out T.View) is
            begin
               if E.Is_Ok (Status) then
                  Bind (Item, Prefix & Suffix, Rows, Columns, Into, Status);
               end if;
            end Take;

            procedure Take
              (Suffix : String; Length : Element_Count;
               Into : out T.Real_Array_Access) is
            begin
               if E.Is_Ok (Status) then
                  Bind_Vector (Item, Prefix & Suffix, Length, Into, Status);
               end if;
            end Take;
         begin
            Take ("ln1.weight", Width, Current.Norm_1_Weight);
            Take ("ln1.bias", Width, Current.Norm_1_Bias);
            Take ("ln2.weight", Width, Current.Norm_2_Weight);
            Take ("ln2.bias", Width, Current.Norm_2_Bias);
            Take ("attn_qkv.weight", 3 * Width, Width, Current.Fused);
            Take ("attn_qkv.bias", 3 * Width, Current.Fused_Bias);
            Take ("attn_out.weight", Width, Width, Current.Output);
            Take ("attn_out.bias", Width, Current.Output_Bias);

            --  The feed-forward's halves told apart by shape, as Gemma's
            --  are.
            if E.Is_Ok (Status) then
               declare
                  Down_Index : constant Natural :=
                    Containers.Find_Tensor
                      (Item.Container, Prefix & "ffn_down.weight");
                  Down_Widens : constant Boolean :=
                    Down_Index > 0
                    and then Element_Count
                      (Containers.Tensor_Dimension
                         (Item.Container, Down_Index, 1)) = Width;
                  In_Name  : constant String :=
                    (if Down_Widens then "ffn_down" else "ffn_up");
                  Out_Name : constant String :=
                    (if Down_Widens then "ffn_up" else "ffn_down");
               begin
                  Take (In_Name & ".weight", Feed, Width, Current.Feed_In);
                  Take (In_Name & ".bias", Feed, Current.Feed_In_Bias);
                  Take (Out_Name & ".weight", Width, Feed, Current.Feed_Out);
                  Take (Out_Name & ".bias", Width, Current.Feed_Out_Bias);
               end;
            end if;
         end;
         if E.Is_Error (Status) then
            return;
         end if;
      end loop;

      --  The merger: a window's joined rows through one square step and
      --  the Gaussian unit, then to the text width.
      Bind (Item, "mm.0.weight", Joined, Joined, Item.Merge_In, Status);
      if E.Is_Ok (Status) then
         Bind_Vector (Item, "mm.0.bias", Joined, Item.Merge_In_Bias, Status);
      end if;
      if E.Is_Ok (Status) then
         Bind (Item, "mm.2.weight", Text_Width, Joined, Item.Merge_Out, Status);
      end if;
      if E.Is_Ok (Status) then
         Bind_Vector (Item, "mm.2.bias", Text_Width, Item.Merge_Out_Bias, Status);
      end if;
   end Bind_Qwen;

   --  The MiniCPM-V resampler's tensors, over a SigLIP encoder read as
   --  Gemma's is: the patch weights and bias, a bank of learned position
   --  rows the encoder selects from by bucket, the pre-normalized blocks,
   --  and the post norm; then the resampler proper -- the learned query
   --  rows, the projection that lifts the patch states to the text width,
   --  the three attention weights and their biases, the output weights,
   --  three layer norms and the final projection.
   procedure Bind_Minicpm (Item : in out Encoder; Status : out E.Error_Info) is
      Width   : constant Element_Count := Element_Count (Item.Width);
      Feed    : constant Element_Count := Element_Count (Item.Feed);
      Text    : constant Element_Count := Element_Count (Item.Text_Width);
      Rows_Pos : Element_Count := 0;
      Pos_Index : constant Natural :=
        Containers.Find_Tensor (Item.Container, "v.position_embd.weight");

      procedure Take
        (Name : String; Rows, Columns : Element_Count; Into : out T.View) is
      begin
         if E.Is_Ok (Status) then
            Bind (Item, Name, Rows, Columns, Into, Status);
         end if;
      end Take;

      procedure Vec
        (Name : String; Length : Element_Count;
         Into : out T.Real_Array_Access) is
      begin
         if E.Is_Ok (Status) then
            Bind_Vector (Item, Name, Length, Into, Status);
         end if;
      end Vec;
   begin
      Status := E.Success;

      Bind (Item, "v.patch_embd.weight", Width,
            3 * Element_Count (Item.Patch) ** 2, Item.Patch_Weights, Status);
      Vec ("v.patch_embd.bias", Width, Item.Patch_Bias);

      --  The learned positions are a bank the encoder buckets into, of a
      --  height the file states rather than the patch count; bind it whole.
      if E.Is_Ok (Status) and then Pos_Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", "v.position_embd.weight",
                     E.Param_Identifier);
      end if;
      if E.Is_Ok (Status) then
         Rows_Pos := Element_Count
           (Containers.Tensor_Dimension (Item.Container, Pos_Index, 2));
      end if;
      Take ("v.position_embd.weight", Rows_Pos, Width, Item.Positions);
      Vec ("v.post_ln.weight", Width, Item.Post_Weight);
      Vec ("v.post_ln.bias", Width, Item.Post_Bias);

      Item.Layers := new Block_Array (0 .. Item.Blocks - 1);
      for Index in Item.Layers'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
              & ".";
            Current : Block renames Item.Layers (Index);
         begin
            Vec (Prefix & "ln1.weight", Width, Current.Norm_1_Weight);
            Vec (Prefix & "ln1.bias", Width, Current.Norm_1_Bias);
            Vec (Prefix & "ln2.weight", Width, Current.Norm_2_Weight);
            Vec (Prefix & "ln2.bias", Width, Current.Norm_2_Bias);
            Take (Prefix & "attn_q.weight", Width, Width, Current.Query);
            Vec (Prefix & "attn_q.bias", Width, Current.Query_Bias);
            Take (Prefix & "attn_k.weight", Width, Width, Current.Key);
            Vec (Prefix & "attn_k.bias", Width, Current.Key_Bias);
            Take (Prefix & "attn_v.weight", Width, Width, Current.Value);
            Vec (Prefix & "attn_v.bias", Width, Current.Value_Bias);
            Take (Prefix & "attn_out.weight", Width, Width, Current.Output);
            Vec (Prefix & "attn_out.bias", Width, Current.Output_Bias);
            --  The feed-forward's halves told apart by shape, not name:
            --  a real MiniCPM-V file names the widening half "ffn_down"
            --  and the narrowing "ffn_up", the other way round from the
            --  fixture, exactly as Gemma's converter did. The one whose
            --  columns are the model width widens.
            if E.Is_Ok (Status) then
               declare
                  Down_Index : constant Natural :=
                    Containers.Find_Tensor
                      (Item.Container, Prefix & "ffn_down.weight");
                  Down_Widens : constant Boolean :=
                    Down_Index > 0
                    and then Element_Count
                      (Containers.Tensor_Dimension
                         (Item.Container, Down_Index, 1)) = Width;
                  In_Name  : constant String :=
                    (if Down_Widens then "ffn_down" else "ffn_up");
                  Out_Name : constant String :=
                    (if Down_Widens then "ffn_up" else "ffn_down");
               begin
                  Take (Prefix & In_Name & ".weight", Feed, Width,
                        Current.Feed_In);
                  Vec (Prefix & In_Name & ".bias", Feed, Current.Feed_In_Bias);
                  Take (Prefix & Out_Name & ".weight", Width, Feed,
                        Current.Feed_Out);
                  Vec (Prefix & Out_Name & ".bias", Width,
                       Current.Feed_Out_Bias);
               end;
            end if;
         end;
         exit when E.Is_Error (Status);
      end loop;

      --  The resampler head.
      Take ("resampler.query", Element_Count (Item.Num_Query), Text,
            Item.Query_Rows);
      Take ("resampler.kv.weight", Text, Width, Item.Kv_Proj);
      Take ("resampler.attn.q.weight", Text, Text, Item.R_Attn_Q);
      Vec ("resampler.attn.q.bias", Text, Item.R_Attn_Q_B);
      Take ("resampler.attn.k.weight", Text, Text, Item.R_Attn_K);
      Vec ("resampler.attn.k.bias", Text, Item.R_Attn_K_B);
      Take ("resampler.attn.v.weight", Text, Text, Item.R_Attn_V);
      Vec ("resampler.attn.v.bias", Text, Item.R_Attn_V_B);
      Take ("resampler.attn.out.weight", Text, Text, Item.R_Attn_O);
      Vec ("resampler.attn.out.bias", Text, Item.R_Attn_O_B);
      Vec ("resampler.ln_q.weight", Text, Item.R_Ln_Q_W);
      Vec ("resampler.ln_q.bias", Text, Item.R_Ln_Q_B);
      Vec ("resampler.ln_kv.weight", Text, Item.R_Ln_Kv_W);
      Vec ("resampler.ln_kv.bias", Text, Item.R_Ln_Kv_B);
      Vec ("resampler.ln_post.weight", Text, Item.R_Ln_Post_W);
      Vec ("resampler.ln_post.bias", Text, Item.R_Ln_Post_B);
      Take ("resampler.proj.weight", Text, Text, Item.R_Proj);
   end Bind_Minicpm;

   --  MiniCPM-V 4.6's tensors: the same SigLIP encoder the resampler binds --
   --  the patch weights, the learned position bank, and the pre-normalized
   --  blocks -- but no post norm, which this file does not carry, and a
   --  downsample-MLP head in place of the resampler: the merged row's
   --  normalization, its widening, and its narrowing to the text width.
   procedure Bind_Minicpm46
     (Item : in out Encoder; Status : out E.Error_Info)
   is
      Width   : constant Element_Count := Element_Count (Item.Width);
      Feed    : constant Element_Count := Element_Count (Item.Feed);
      Text    : constant Element_Count := Element_Count (Item.Text_Width);
      Merged  : constant Element_Count :=
        Element_Count (Item.Merge_Scale) ** 2 * Width;
      Rows_Pos : Element_Count := 0;
      Pos_Index : constant Natural :=
        Containers.Find_Tensor (Item.Container, "v.position_embd.weight");

      procedure Take
        (Name : String; Rows, Columns : Element_Count; Into : out T.View) is
      begin
         if E.Is_Ok (Status) then
            Bind (Item, Name, Rows, Columns, Into, Status);
         end if;
      end Take;

      procedure Vec
        (Name : String; Length : Element_Count;
         Into : out T.Real_Array_Access) is
      begin
         if E.Is_Ok (Status) then
            Bind_Vector (Item, Name, Length, Into, Status);
         end if;
      end Vec;
   begin
      Status := E.Success;

      Bind (Item, "v.patch_embd.weight", Width,
            3 * Element_Count (Item.Patch) ** 2, Item.Patch_Weights, Status);
      Vec ("v.patch_embd.bias", Width, Item.Patch_Bias);

      if E.Is_Ok (Status) and then Pos_Index = 0 then
         Status := E.Make (E.Arch_Missing_Tensor);
         E.Add_Text (Status, "tensor", "v.position_embd.weight",
                     E.Param_Identifier);
      end if;
      if E.Is_Ok (Status) then
         Rows_Pos := Element_Count
           (Containers.Tensor_Dimension (Item.Container, Pos_Index, 2));
      end if;
      Take ("v.position_embd.weight", Rows_Pos, Width, Item.Positions);

      Item.Layers := new Block_Array (0 .. Item.Blocks - 1);
      for Index in Item.Layers'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
              & ".";
            Current : Block renames Item.Layers (Index);
         begin
            Vec (Prefix & "ln1.weight", Width, Current.Norm_1_Weight);
            Vec (Prefix & "ln1.bias", Width, Current.Norm_1_Bias);
            Vec (Prefix & "ln2.weight", Width, Current.Norm_2_Weight);
            Vec (Prefix & "ln2.bias", Width, Current.Norm_2_Bias);
            Take (Prefix & "attn_q.weight", Width, Width, Current.Query);
            Vec (Prefix & "attn_q.bias", Width, Current.Query_Bias);
            Take (Prefix & "attn_k.weight", Width, Width, Current.Key);
            Vec (Prefix & "attn_k.bias", Width, Current.Key_Bias);
            Take (Prefix & "attn_v.weight", Width, Width, Current.Value);
            Vec (Prefix & "attn_v.bias", Width, Current.Value_Bias);
            Take (Prefix & "attn_out.weight", Width, Width, Current.Output);
            Vec (Prefix & "attn_out.bias", Width, Current.Output_Bias);
            --  The feed-forward's halves told apart by shape, as in the
            --  resampler bind: the one whose columns are the model width
            --  widens.
            if E.Is_Ok (Status) then
               declare
                  Down_Index : constant Natural :=
                    Containers.Find_Tensor
                      (Item.Container, Prefix & "ffn_down.weight");
                  Down_Widens : constant Boolean :=
                    Down_Index > 0
                    and then Element_Count
                      (Containers.Tensor_Dimension
                         (Item.Container, Down_Index, 1)) = Width;
                  In_Name  : constant String :=
                    (if Down_Widens then "ffn_down" else "ffn_up");
                  Out_Name : constant String :=
                    (if Down_Widens then "ffn_up" else "ffn_down");
               begin
                  Take (Prefix & In_Name & ".weight", Feed, Width,
                        Current.Feed_In);
                  Vec (Prefix & In_Name & ".bias", Feed, Current.Feed_In_Bias);
                  Take (Prefix & Out_Name & ".weight", Width, Feed,
                        Current.Feed_Out);
                  Vec (Prefix & Out_Name & ".bias", Width,
                       Current.Feed_Out_Bias);
               end;
            end if;
         end;
         exit when E.Is_Error (Status);
      end loop;

      --  The post norm, and the intermediate windowed merger: a windowed
      --  self-attention and a two-by-two downsample MLP inserted after the
      --  window-attention layer.
      Vec ("v.post_ln.weight", Width, Item.Post_Weight);
      Vec ("v.post_ln.bias", Width, Item.Post_Bias);
      Vec ("v.vit_merger.ln1.weight", Width, Item.VM_Ln1_W);
      Vec ("v.vit_merger.ln1.bias", Width, Item.VM_Ln1_B);
      Take ("v.vit_merger.attn_q.weight", Width, Width, Item.VM_Q);
      Vec ("v.vit_merger.attn_q.bias", Width, Item.VM_Q_B);
      Take ("v.vit_merger.attn_k.weight", Width, Width, Item.VM_K);
      Vec ("v.vit_merger.attn_k.bias", Width, Item.VM_K_B);
      Take ("v.vit_merger.attn_v.weight", Width, Width, Item.VM_V);
      Vec ("v.vit_merger.attn_v.bias", Width, Item.VM_V_B);
      Take ("v.vit_merger.attn_out.weight", Width, Width, Item.VM_O);
      Vec ("v.vit_merger.attn_out.bias", Width, Item.VM_O_B);
      Vec ("v.vit_merger.ds_ln.weight", Merged, Item.VM_Ds_Ln_W);
      Vec ("v.vit_merger.ds_ln.bias", Merged, Item.VM_Ds_Ln_B);

      if E.Is_Ok (Status) then
         declare
            Up_Index : constant Natural :=
              Containers.Find_Tensor
                (Item.Container, "v.vit_merger.ds_ffn_up.weight");
         begin
            if Up_Index = 0 then
               Status := E.Make (E.Arch_Missing_Tensor);
               E.Add_Text (Status, "tensor",
                           "v.vit_merger.ds_ffn_up.weight", E.Param_Identifier);
            else
               Item.Merge_Feed := Natural
                 (Containers.Tensor_Dimension (Item.Container, Up_Index, 2));
            end if;
         end;
      end if;
      declare
         VFeed : constant Element_Count := Element_Count (Item.Merge_Feed);
      begin
         Take ("v.vit_merger.ds_ffn_up.weight", VFeed, Merged, Item.VM_Ds_Up);
         Vec ("v.vit_merger.ds_ffn_up.bias", VFeed, Item.VM_Ds_Up_B);
         Take ("v.vit_merger.ds_ffn_down.weight", Width, VFeed,
               Item.VM_Ds_Down);
         Vec ("v.vit_merger.ds_ffn_down.bias", Width, Item.VM_Ds_Down_B);
      end;

      --  The final downsample-MLP head, over the merged row.
      Vec ("mm.input_norm.weight", Merged, Item.Merge_Norm_W);
      Vec ("mm.input_norm.bias", Merged, Item.Merge_Norm_B);
      Take ("mm.up.weight", Merged, Merged, Item.Merge_Up);
      Vec ("mm.up.bias", Merged, Item.Merge_Up_B);
      Take ("mm.down.weight", Text, Merged, Item.Merge_Down);
      Vec ("mm.down.bias", Text, Item.Merge_Down_B);
   end Bind_Minicpm46;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item   : in out Encoder;
      Path   : String;
      Status : out E.Error_Info)
   is
      procedure Fail (Condition : E.Error_Info) is
      begin
         Status := Condition;
         Close (Item);
      end Fail;

      Number : Long_Long_Integer;
      Wide   : N.Wide_Real;
      Local  : E.Error_Info;
   begin
      Close (Item);
      Status := E.Success;

      Model_Runner.Byte_Sources.Files.Open (Item.File, Path, Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Containers.Reader.Parse (Item.Container, Item.File, Status => Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      --  What the file says it is.
      declare
         Kind : constant String :=
           Containers.String_Value (Item.Container, "clip.projector_type");
      begin
         if Kind /= Gemma_3 and then Kind /= Qwen_3
           and then Kind /= Qwen_2 and then Kind /= Resampler
           and then Kind /= Minicpm_46
         then
            Status := E.Make (E.Arch_Unsupported_Projector);
            E.Add_Text
              (Status, "format", (if Kind = "" then "none" else Kind),
               E.Param_Identifier);
            E.Add_Text
              (Status, "supported",
               Gemma_3 & " " & Qwen_2 & " " & Qwen_3 & " " & Resampler
               & " " & Minicpm_46,
               E.Param_Identifier);
            Fail (Status);
            return;
         end if;
         Item.Kind_Last := Kind'Length;
         Item.Kind (1 .. Kind'Length) := Kind;
      end;

      --  Its shape.
      Containers.Get_Integer
        (Item.Container, "clip.vision.image_size", 14, 4096, Number, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Size := Positive (Number);

      Containers.Get_Integer
        (Item.Container, "clip.vision.patch_size", 1, 64, Number, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Patch := Positive (Number);

      Containers.Get_Integer
        (Item.Container, "clip.vision.embedding_length", 1, 8192, Number,
         Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Width := Positive (Number);

      Containers.Get_Integer
        (Item.Container, "clip.vision.feed_forward_length", 1, 65536, Number,
         Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Feed := Positive (Number);

      Containers.Get_Integer
        (Item.Container, "clip.vision.block_count", 1, Max_Blocks, Number,
         Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Blocks := Natural (Number);

      Containers.Get_Integer
        (Item.Container, "clip.vision.attention.head_count", 1, 256, Number,
         Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Heads := Positive (Number);

      --  The text width. MiniCPM-V's resampler does not state it in a
      --  key -- its projection_dim is nought -- so it is read below from
      --  the query tensor's own width instead.
      if not Is_Minicpm (Item) then
         Containers.Get_Integer
           (Item.Container, "clip.vision.projection_dim", 1, 65536, Number,
            Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Item.Text_Width := Positive (Number);
      end if;

      Containers.Get_Float
        (Item.Container, "clip.vision.attention.layer_norm_epsilon",
         0.0, 1.0, Wide, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Epsilon := Real (Wide);

      for Channel in 1 .. 3 loop
         Containers.Get_Float_Element
           (Item.Container, "clip.vision.image_mean", Channel, Wide, Local);
         if E.Is_Ok (Local) then
            Item.Mean (Channel) := Real (Wide);
         end if;
         Containers.Get_Float_Element
           (Item.Container, "clip.vision.image_std", Channel, Wide, Local);
         if E.Is_Ok (Local) and then Wide > 0.0 then
            Item.Deviation (Channel) := Real (Wide);
         end if;
      end loop;

      --  What the Qwen encoder states of its own: the window a side, and
      --  whether any block's state is stacked beside the projection --
      --  Qwen3-VL's deepstack, which Qwen3.5's files do not carry and
      --  this build does not read.
      if Is_Qwen (Item) then
         Containers.Get_Integer
           (Item.Container, "clip.vision.spatial_merge_size", 1, 8, Number,
            Local);
         Item.Merge := (if E.Is_Ok (Local) then Positive (Number) else 2);

         declare
            Length  : Natural := 0;
            Stacked : Boolean := False;
            Flag    : Boolean;
         begin
            Containers.Get_Array_Length
              (Item.Container, "clip.vision.is_deepstack_layers",
               Model_Runner.GGUF.Value_Bool, Length, Local);
            if E.Is_Ok (Local) then
               for Index in 1 .. Length loop
                  Containers.Get_Boolean_Element
                    (Item.Container, "clip.vision.is_deepstack_layers", Index,
                     Flag, Local);
                  Stacked := Stacked or else (E.Is_Ok (Local) and then Flag);
               end loop;
            end if;
            if Stacked then
               Status := E.Make (E.Arch_Unsupported_Projector);
               E.Add_Text
                 (Status, "format", Qwen_3 & " deepstack", E.Param_Identifier);
               E.Add_Text
                 (Status, "supported",
               Gemma_3 & " " & Qwen_2 & " " & Qwen_3 & " " & Resampler
               & " " & Minicpm_46,
               E.Param_Identifier);
               Fail (Status);
               return;
            end if;
         end;
      end if;

      --  What the resampler states of its own: how many query rows it
      --  carries, and which MiniCPM-V it is. The query count also lives
      --  in the query tensor's shape, which Bind checks it against.
      if Is_Minicpm (Item) then
         --  The resampler's width and query count are the query tensor's
         --  two axes, which is where they are stated whole; the version
         --  key is kept for the record.
         declare
            QI : constant Natural :=
              Containers.Find_Tensor (Item.Container, "resampler.query");
         begin
            if QI = 0 then
               Status := E.Make (E.Arch_Missing_Tensor);
               E.Add_Text
                 (Status, "tensor", "resampler.query", E.Param_Identifier);
               Fail (Status);
               return;
            end if;
            Item.Text_Width :=
              Positive (Containers.Tensor_Dimension (Item.Container, QI, 1));
            Item.Num_Query :=
              Natural (Containers.Tensor_Dimension (Item.Container, QI, 2));
         end;
         Containers.Get_Integer
           (Item.Container, "clip.minicpmv_version", 1, 1_000_000, Number,
            Local);
         Item.Minicpm_Version :=
           (if E.Is_Ok (Local) then Natural (Number) else 2);
      end if;

      if Is_Minicpm46 (Item) then
         --  The output projection's width and the merge's side, stated as
         --  the projection dimension and the scale factor -- four patches to
         --  a merged row is a two-by-two merge, so the side is its root.
         Containers.Get_Integer
           (Item.Container, "clip.vision.projection_dim", 1, 1_000_000,
            Number, Local);
         Item.Text_Width :=
           (if E.Is_Ok (Local) then Positive (Number) else Item.Width);
         Containers.Get_Integer
           (Item.Container, "clip.vision.projector.scale_factor", 1, 64,
            Number, Local);
         declare
            Factor : constant Natural :=
              (if E.Is_Ok (Local) then Natural (Number) else 4);
            Side   : Natural := 1;
         begin
            while Side * Side < Factor loop
               Side := Side + 1;
            end loop;
            Item.Merge_Scale := Side;
         end;
         --  The layer the windowed merger is inserted after, borrowed from
         --  the first window-attention layer index, as llama.cpp borrows it.
         Containers.Get_Integer_Element
           (Item.Container, "clip.vision.wa_layer_indexes", 1, Number, Local);
         Item.Insert_Layer :=
           (if E.Is_Ok (Local) then Natural (Number) else 0);
      end if;

      if Item.Size mod Item.Patch /= 0
        or else Item.Width mod Item.Heads /= 0
        or else (not Is_Qwen (Item) and then not Is_Minicpm (Item)
                 and then not Is_Minicpm46 (Item)
                 and then (Item.Size / Item.Patch) mod Item.Pool_Side /= 0)
        or else (Is_Qwen (Item) and then (Item.Width / Item.Heads) mod 4 /= 0)
        or else (Is_Minicpm (Item) and then Item.Text_Width mod 128 /= 0)
      then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer (Status, "embedding", Long_Long_Integer (Item.Width));
         E.Add_Integer (Status, "heads", Long_Long_Integer (Item.Heads));
         Fail (Status);
         return;
      end if;

      --  The tensor section: the file's own pages where it is mapped,
      --  read into an arena where it is not.
      declare
         Data_At : constant B.Byte_Count :=
           B.Byte_Count (Containers.Data_Offset (Item.Container));
         Length  : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Data_Bytes (Item.Container));
      begin
         if Item.File.Is_Mapped
           and then Item.File.Base /= System.Null_Address
           and then Item.File.Size >= Data_At + Length
         then
            Item.Base :=
              System.Storage_Elements.To_Address
                (System.Storage_Elements.To_Integer (Item.File.Base)
                 + System.Storage_Elements.Integer_Address (Data_At));
            Item.Span := Length;
         else
            B.Allocate (Length, Item.Arena);
            if Item.Arena = null then
               Fail (E.Make (E.Memory_Allocation_Failed));
               return;
            end if;
            Item.File.Read (Data_At, Item.Arena.all, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
            Item.Base := Item.Arena.all'Address;
            Item.Span := Length;
         end if;
      end;

      --  And the tensors.
      if Is_Qwen (Item) then
         Bind_Qwen (Item, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Item.Ready := True;
         return;
      end if;

      if Is_Minicpm (Item) then
         Bind_Minicpm (Item, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Item.Ready := True;
         return;
      end if;

      if Is_Minicpm46 (Item) then
         Bind_Minicpm46 (Item, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Item.Ready := True;
         return;
      end if;

      declare
         Width   : constant Element_Count := Element_Count (Item.Width);
         Feed    : constant Element_Count := Element_Count (Item.Feed);
         Patches : constant Element_Count :=
           Element_Count ((Item.Size / Item.Patch) ** 2);
         Patch_Elements : constant Element_Count :=
           3 * Element_Count (Item.Patch) ** 2;
      begin
         Bind (Item, "v.patch_embd.weight", Width, Patch_Elements,
               Item.Patch_Weights, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Bind_Vector (Item, "v.patch_embd.bias", Width, Item.Patch_Bias, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Bind (Item, "v.position_embd.weight", Patches, Width,
               Item.Positions, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Bind_Vector (Item, "v.post_ln.weight", Width, Item.Post_Weight, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Bind_Vector (Item, "v.post_ln.bias", Width, Item.Post_Bias, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;
         Bind_Vector (Item, "mm.soft_emb_norm.weight", Width, Item.Soft_Norm,
                      Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         Item.Layers := new Block_Array (0 .. Item.Blocks - 1);
         for Index in Item.Layers'Range loop
            declare
               Prefix : constant String :=
                 "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
                 & ".";
               Current : Block renames Item.Layers (Index);

               procedure Take
                 (Suffix : String; Rows, Columns : Element_Count;
                  Into : out T.View) is
               begin
                  if E.Is_Ok (Status) then
                     Bind (Item, Prefix & Suffix, Rows, Columns, Into, Status);
                  end if;
               end Take;

               procedure Take
                 (Suffix : String; Length : Element_Count;
                  Into : out T.Real_Array_Access) is
               begin
                  if E.Is_Ok (Status) then
                     Bind_Vector (Item, Prefix & Suffix, Length, Into, Status);
                  end if;
               end Take;
            begin
               Take ("ln1.weight", Width, Current.Norm_1_Weight);
               Take ("ln1.bias", Width, Current.Norm_1_Bias);
               Take ("ln2.weight", Width, Current.Norm_2_Weight);
               Take ("ln2.bias", Width, Current.Norm_2_Bias);
               Take ("attn_q.weight", Width, Width, Current.Query);
               Take ("attn_q.bias", Width, Current.Query_Bias);
               Take ("attn_k.weight", Width, Width, Current.Key);
               Take ("attn_k.bias", Width, Current.Key_Bias);
               Take ("attn_v.weight", Width, Width, Current.Value);
               Take ("attn_v.bias", Width, Current.Value_Bias);
               Take ("attn_out.weight", Width, Width, Current.Output);
               Take ("attn_out.bias", Width, Current.Output_Bias);

               --  The two halves of the feed-forward, told apart by their
               --  shape rather than by their names: the converter that
               --  wrote the file named the one that widens "ffn_down" and
               --  the one that narrows "ffn_up", after the first vision
               --  files it wrote, and a later one may name them the other
               --  way round. The one with Width columns widens.
               if E.Is_Ok (Status) then
                  declare
                     Down_Index : constant Natural :=
                       Containers.Find_Tensor
                         (Item.Container, Prefix & "ffn_down.weight");
                     Down_Widens : constant Boolean :=
                       Down_Index > 0
                       and then Element_Count
                         (Containers.Tensor_Dimension
                            (Item.Container, Down_Index, 1)) = Width;
                     In_Name  : constant String :=
                       (if Down_Widens then "ffn_down" else "ffn_up");
                     Out_Name : constant String :=
                       (if Down_Widens then "ffn_up" else "ffn_down");
                  begin
                     Take (In_Name & ".weight", Feed, Width, Current.Feed_In);
                     Take (In_Name & ".bias", Feed, Current.Feed_In_Bias);
                     Take (Out_Name & ".weight", Width, Feed, Current.Feed_Out);
                     Take (Out_Name & ".bias", Width, Current.Feed_Out_Bias);
                  end;
               end if;
            end;
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end loop;

         --  The projection, as the file holds it: Width rows of Text_Width,
         --  the transpose of a product's weights. Decoded and turned once,
         --  so that a picture's rows are a product like every other.
         declare
            Text_Width : constant Element_Count :=
              Element_Count (Item.Text_Width);
            Stored : T.View;
            Row    : T.Real_Array_Access;
         begin
            Bind (Item, "mm.input_projection.weight", Width, Text_Width,
                  Stored, Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
            T.Allocate (Width * Text_Width, Item.Projection_Rows);
            T.Allocate (Text_Width, Row);
            if Item.Projection_Rows = null or else Row = null then
               T.Free (Row);
               Fail (E.Make (E.Memory_Allocation_Failed));
               return;
            end if;
            for Source_Row in 0 .. Width - 1 loop
               T.Dequantize_Row (Stored, Source_Row, Row.all, Status);
               exit when E.Is_Error (Status);
               for Column in 0 .. Text_Width - 1 loop
                  Item.Projection_Rows (Column * Width + Source_Row) :=
                    Row (Column);
               end loop;
            end loop;
            T.Free (Row);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
            T.Make
              (Format  => Model_Runner.GGUF.Type_F32,
               Rows    => Text_Width,
               Columns => Width,
               Base    => Item.Projection_Rows.all'Address,
               Span    => B.Byte_Count (Item.Projection_Rows.all'Length) * 4,
               Offset  => 0,
               Result  => Item.Projection,
               Status  => Status);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end;
      end;

      Item.Ready := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Encoder) is
   begin
      Item.Ready := False;
      if Item.Layers /= null then
         for Current of Item.Layers.all loop
            T.Free (Current.Norm_1_Weight);
            T.Free (Current.Norm_1_Bias);
            T.Free (Current.Norm_2_Weight);
            T.Free (Current.Norm_2_Bias);
            T.Free (Current.Query_Bias);
            T.Free (Current.Key_Bias);
            T.Free (Current.Value_Bias);
            T.Free (Current.Output_Bias);
            T.Free (Current.Fused_Bias);
            T.Free (Current.Feed_In_Bias);
            T.Free (Current.Feed_Out_Bias);
         end loop;
         Free (Item.Layers);
      end if;
      T.Free (Item.Patch_Bias);
      T.Free (Item.Post_Weight);
      T.Free (Item.Post_Bias);
      T.Free (Item.Soft_Norm);
      T.Free (Item.Projection_Rows);
      T.Free (Item.Patch_Sum);
      T.Free (Item.Patch_Pair_Rows);
      T.Free (Item.Merge_In_Bias);
      T.Free (Item.Merge_Out_Bias);
      Item.Patch_Weights := T.Empty_View;
      Item.Patch_Both := T.Empty_View;
      Item.Patch_Pair := T.Empty_View;
      Item.Merge_In := T.Empty_View;
      Item.Merge_Out := T.Empty_View;
      Item.Positions := T.Empty_View;
      B.Free (Item.Arena);
      Item.Base := System.Null_Address;
      Item.Span := 0;
      Containers.Close (Item.Container);
      Model_Runner.Byte_Sources.Files.Close (Item.File);
   end Close;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (Item : Encoder) return Boolean is (Item.Ready);

   function Image_Size (Item : Encoder) return Positive is (Item.Size);

   function Fixed_Rows (Item : Encoder) return Boolean is (not Is_Qwen (Item));

   function Placed_Rows (Item : Encoder) return Boolean is (Is_Qwen (Item));

   function Rows_Per_Picture (Item : Encoder) return Positive
   is (if Is_Qwen (Item) then Item.Most_Rows
       elsif Is_Minicpm (Item) then Item.Num_Query
       elsif Is_Minicpm46 (Item)
       then ((Item.Size / Item.Patch) / Item.Merge_Scale / Item.Merge_Scale)
              ** 2
       else ((Item.Size / Item.Patch) / Item.Pool_Side) ** 2);

   function Row_Width (Item : Encoder) return Positive is (Item.Text_Width);

   function Projector (Item : Encoder) return String
   is (Item.Kind (1 .. Item.Kind_Last));

   function Minicpm_Version (Item : Encoder) return Natural
   is (if Is_Minicpm (Item) then Item.Minicpm_Version else 0);

   ------------
   -- Encode --
   ------------

   --  A product shared out over a pool: tiles of W's rows are the items.
   type Product_Work is new Model_Runner.Shares.Work with record
      A, W, C : T.Real_Array_Access;
      A_At    : Element_Count := 0;
      Rows, Wanted, Width : Element_Count := 0;
   end record;

   overriding procedure Run
     (Item : in out Product_Work; First : Element_Count; Last : Element_Count)
   is
      A_Last : constant Element_Count :=
        Item.A_At + Item.Rows * Item.Width - 1;
   begin
      if Model_Runner.Platform.Wide_Vectors then
         Wide.Multiply
           (Item.A (Item.A_At .. A_Last), Item.Rows, Item.W.all, Item.Wanted,
            Item.Width, Item.C.all, First, Last);
      else
         Plain.Multiply
           (Item.A (Item.A_At .. A_Last), Item.Rows, Item.W.all, Item.Wanted,
            Item.Width, Item.C.all, First, Last);
      end if;
   end Run;

   --  Work over rows: a bias added, the Gaussian unit, a softmax or a
   --  layer normalization, each row on its own.
   type Row_Task is (Add_Bias, Gaussian, Gaussian_Exact, Soft_Max, Normalize);

   type Row_Work is new Model_Runner.Shares.Work with record
      Task_Kind : Row_Task := Add_Bias;
      Source, Target : T.Real_Array_Access;
      Width   : Element_Count := 0;
      Bias, Weight : T.Real_Array_Access;
      Epsilon : Real := 0.0;
      Failed  : Boolean := False with Atomic;
   end record;

   overriding procedure Run
     (Item : in out Row_Work; First : Element_Count; Last : Element_Count)
   is
      Ok : Boolean;
   begin
      for Row in First .. Last loop
         declare
            From : constant Element_Count := Row * Item.Width;
            To   : constant Element_Count := From + Item.Width - 1;
         begin
            case Item.Task_Kind is
               when Add_Bias =>
                  K.Add (Item.Target (From .. To), Item.Bias.all);
               when Gaussian =>
                  K.GELU (Item.Target (From .. To));
               when Gaussian_Exact =>
                  K.Exact_GELU (Item.Target (From .. To));
               when Soft_Max =>
                  K.Softmax (Item.Target (From .. To), Ok);
                  if not Ok then
                     Item.Failed := True;
                  end if;
               when Normalize =>
                  K.Layer_Norm
                    (Item.Source (From .. To), Item.Weight.all, Item.Bias.all,
                     Item.Epsilon, Item.Target (From .. To));
            end case;
         end;
      end loop;
   end Run;

   --  Queries a block of attention takes at once: their scores against
   --  every key are a megabyte, a core's own to soften and blend.
   Query_Block : constant Element_Count := 64;

   --  One head's attention shared out over blocks of queries: each
   --  block's scores against every key, softened, then blended over
   --  the values, on the worker the block fell to, with nothing but the
   --  keys and values read in common. The keys are held as they are,
   --  Patches rows of Head, and the values transposed -- Head rows of
   --  Patches -- which is the way round each product wants its right
   --  side.
   type Attention_Work is new Model_Runner.Shares.Work with record
      Queries, Keys, Values_T, Scores, Blended : T.Real_Array_Access;
      Patches, Head : Element_Count := 0;
      Failed : Boolean := False with Atomic;
   end record;

   overriding procedure Run
     (Item : in out Attention_Work; First : Element_Count; Last : Element_Count)
   is
      Wide_Host : constant Boolean := Model_Runner.Platform.Wide_Vectors;
      Key_Tiles : constant Element_Count :=
        (Item.Patches + Wide.Tile - 1) / Wide.Tile;
      Head_Tiles : constant Element_Count :=
        (Item.Head + Wide.Tile - 1) / Wide.Tile;
      Ok : Boolean;
   begin
      for Block in First .. Last loop
         declare
            From : constant Element_Count := Block * Query_Block;
            Rows : constant Element_Count :=
              Element_Count'Min (Query_Block, Item.Patches - From);
            Q_First : constant Element_Count := From * Item.Head;
            Q_Last  : constant Element_Count := (From + Rows) * Item.Head - 1;
            S_First : constant Element_Count := From * Item.Patches;
            S_Last  : constant Element_Count := (From + Rows) * Item.Patches - 1;
         begin
            if Wide_Host then
               Wide.Multiply
                 (Item.Queries (Q_First .. Q_Last), Rows, Item.Keys.all,
                  Item.Patches, Item.Head, Item.Scores (S_First .. S_Last),
                  0, Key_Tiles - 1);
            else
               Plain.Multiply
                 (Item.Queries (Q_First .. Q_Last), Rows, Item.Keys.all,
                  Item.Patches, Item.Head, Item.Scores (S_First .. S_Last),
                  0, Key_Tiles - 1);
            end if;

            for Row in From .. From + Rows - 1 loop
               K.Softmax
                 (Item.Scores (Row * Item.Patches .. (Row + 1) * Item.Patches - 1),
                  Ok);
               if not Ok then
                  Item.Failed := True;
               end if;
            end loop;

            if Wide_Host then
               Wide.Multiply
                 (Item.Scores (S_First .. S_Last), Rows, Item.Values_T.all,
                  Item.Head, Item.Patches, Item.Blended (Q_First .. Q_Last),
                  0, Head_Tiles - 1);
            else
               Plain.Multiply
                 (Item.Scores (S_First .. S_Last), Rows, Item.Values_T.all,
                  Item.Head, Item.Patches, Item.Blended (Q_First .. Q_Last),
                  0, Head_Tiles - 1);
            end if;
         end;
      end loop;
   end Run;

   --  MiniCPM-V's resampler cross-attention, a query at a time: each
   --  learned query over every patch, a head of a hundred and twenty-eight
   --  at once, the scores softened and blended, on the worker the query
   --  fell to. Each query keeps its own row of scores, so the workers
   --  share the keys and values but nothing they write.
   type Cross_Work is new Model_Runner.Shares.Work with record
      Queries, Keys, Values, Scores, Blended : T.Real_Array_Access;
      Width, Patches, Heads, Head : Element_Count := 0;
      Scale  : Real := 0.0;
      Failed : Boolean := False with Atomic;
   end record;

   overriding procedure Run
     (Item : in out Cross_Work; First : Element_Count; Last : Element_Count)
   is
      Ok : Boolean;
   begin
      for Query in First .. Last loop
         declare
            S_At : constant Element_Count := Query * Item.Patches;
         begin
            for H in 0 .. Item.Heads - 1 loop
               declare
                  Q_At : constant Element_Count :=
                    Query * Item.Width + H * Item.Head;
               begin
                  for J in 0 .. Item.Patches - 1 loop
                     declare
                        K_At : constant Element_Count :=
                          J * Item.Width + H * Item.Head;
                        Acc  : Real := 0.0;
                     begin
                        for D in 0 .. Item.Head - 1 loop
                           Acc := Acc
                             + Item.Queries (Q_At + D) * Item.Keys (K_At + D);
                        end loop;
                        Item.Scores (S_At + J) := Acc * Item.Scale;
                     end;
                  end loop;
                  K.Softmax
                    (Item.Scores (S_At .. S_At + Item.Patches - 1), Ok);
                  if not Ok then
                     Item.Failed := True;
                  end if;
                  for D in 0 .. Item.Head - 1 loop
                     declare
                        Acc : Real := 0.0;
                     begin
                        for J in 0 .. Item.Patches - 1 loop
                           Acc := Acc + Item.Scores (S_At + J)
                             * Item.Values
                                 (J * Item.Width + H * Item.Head + D);
                        end loop;
                        Item.Blended (Q_At + D) := Acc;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  Rows one product on the device takes at once: where the device's
   --  own batch is fastest, and the working set its shader was measured
   --  with.
   Device_Chunk : constant Element_Count := 512;

   --  What every product and row task of an encode shares: the pool, the
   --  stop request, the two work records, the scratch a matrix is decoded
   --  into and a device product's chunk of rows in and out, and the
   --  status every step reads before it starts and writes when it fails.
   type Workspace is limited record
      Team      : CPU.Pool_Reference := null;
      Cancel    : Model_Runner.Cancellation.Token_Reference := null;
      Epsilon   : Real := 0.0;
      Product   : aliased Product_Work;
      Over_Rows : aliased Row_Work;
      Decoded, In_Chunk, Out_Chunk : T.Real_Array_Access := null;
      Status    : E.Error_Info := E.Success;
      --  Where in the device's cache this picture's attention puts a
      --  block's keys and values: the cache's end as the sessions had it
      --  when the first block asked, and the same place for every block
      --  after, so the cache grows once a picture. Not yet chosen is
      --  Element_Count'Last.
      Cache_Base : Element_Count := Element_Count'Last;
   end record;

   --  Every row of Target through one of the row tasks.
   procedure Rows_Through
     (Work   : in out Workspace;
      What   : Row_Task;
      Target : T.Real_Array_Access;
      Total  : Element_Count;
      Row_Width : Element_Count;
      Source : T.Real_Array_Access := null;
      Bias   : T.Real_Array_Access := null;
      Weight : T.Real_Array_Access := null) is
   begin
      if E.Is_Error (Work.Status) then
         return;
      end if;
      Work.Over_Rows.Task_Kind := What;
      Work.Over_Rows.Source := Source;
      Work.Over_Rows.Target := Target;
      Work.Over_Rows.Width := Row_Width;
      Work.Over_Rows.Bias := Bias;
      Work.Over_Rows.Weight := Weight;
      Work.Over_Rows.Epsilon := Work.Epsilon;
      Work.Over_Rows.Failed := False;
      CPU.Dispatch_Shares
        (Work.Team, Total, Work.Over_Rows'Unchecked_Access, Work.Status,
         Cost => Total * Row_Width);
      if E.Is_Ok (Work.Status) and then Work.Over_Rows.Failed then
         Work.Status := E.Make (E.Sampling_Non_Finite_Logit);
      end if;
   end Rows_Through;

   --  Target := Source * W, W held as Wanted rows of Row_Width in
   --  binary32, with Bias added where one is given.
   procedure Multiply
     (Work   : in out Workspace;
      Source : T.Real_Array_Access;
      Source_At : Element_Count;
      Total  : Element_Count;
      W      : T.Real_Array_Access;
      Wanted : Element_Count;
      Row_Width : Element_Count;
      Target : T.Real_Array_Access;
      Bias   : T.Real_Array_Access := null) is
   begin
      if E.Is_Error (Work.Status) then
         return;
      end if;
      Work.Product.A := Source;
      Work.Product.A_At := Source_At;
      Work.Product.Rows := Total;
      Work.Product.W := W;
      Work.Product.Wanted := Wanted;
      Work.Product.Width := Row_Width;
      Work.Product.C := Target;
      CPU.Dispatch_Shares
        (Work.Team, (Wanted + Wide.Tile - 1) / Wide.Tile,
         Work.Product'Unchecked_Access, Work.Status,
         Cost => Total * Wanted * Row_Width);
      if Bias /= null then
         Rows_Through (Work, Add_Bias, Target, Total, Wanted, Bias => Bias);
      end if;
   end Multiply;

   --  Target := Source * Weight: on the device where one is open, the
   --  weights as the file holds them, uploaded once and kept; else on
   --  the pool, the weight decoded from the file's format to binary32
   --  first.
   procedure Multiply
     (Work   : in out Workspace;
      Source : T.Real_Array_Access;
      Total  : Element_Count;
      Weight : T.View;
      Target : T.Real_Array_Access;
      Bias   : T.Real_Array_Access := null) is
   begin
      if E.Is_Error (Work.Status) then
         return;
      end if;

      if Model_Runner.Backend.Device.Is_Ready then
         declare
            Columns : constant Element_Count := Weight.Columns;
            Rows_Out : constant Element_Count := Weight.Rows;
            From : Element_Count := 0;
         begin
            while E.Is_Ok (Work.Status) and then From < Total loop
               declare
                  Take : constant Element_Count :=
                    Element_Count'Min (Device_Chunk, Total - From);
               begin
                  Work.In_Chunk (0 .. Take * Columns - 1) :=
                    Source (From * Columns .. (From + Take) * Columns - 1);
                  Model_Runner.Backend.Device.Dispatch_Batch
                    (Weight, Work.In_Chunk, Take, Work.Out_Chunk, Work.Status,
                     Work.Cancel, Exact => True);
                  exit when E.Is_Error (Work.Status);
                  Target (From * Rows_Out .. (From + Take) * Rows_Out - 1) :=
                    Work.Out_Chunk (0 .. Take * Rows_Out - 1);
                  From := From + Take;
               end;
            end loop;
         end;
         if Bias /= null then
            Rows_Through
              (Work, Add_Bias, Target, Total, Weight.Rows, Bias => Bias);
         end if;
         return;
      end if;

      for Row in 0 .. Weight.Rows - 1 loop
         T.Dequantize_Row
           (Weight, Row,
            Work.Decoded (Row * Weight.Columns .. (Row + 1) * Weight.Columns - 1),
            Work.Status);
         exit when E.Is_Error (Work.Status);
      end loop;
      Multiply (Work, Source, 0, Total, Work.Decoded, Weight.Rows,
                Weight.Columns, Target, Bias);
   end Multiply;

   --  The scratch a workspace holds, for products of Total rows at most
   --  through weights of Columns_Max columns and Rows_Max rows.
   procedure Furnish
     (Work    : in out Workspace;
      Decoded : Element_Count;
      In_Width, Out_Width : Element_Count) is
   begin
      T.Allocate (Decoded, Work.Decoded);
      if Work.Decoded = null then
         Work.Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Work.Status, "category", "vision", E.Param_Identifier);
         return;
      end if;
      if Model_Runner.Backend.Device.Is_Ready then
         T.Allocate (Device_Chunk * In_Width, Work.In_Chunk);
         T.Allocate (Device_Chunk * Out_Width, Work.Out_Chunk);
         if Work.In_Chunk = null or else Work.Out_Chunk = null then
            Work.Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text (Work.Status, "category", "vision", E.Param_Identifier);
         end if;
      end if;
   end Furnish;

   procedure Clear (Work : in out Workspace) is
   begin
      T.Free (Work.Decoded);
      T.Free (Work.In_Chunk);
      T.Free (Work.Out_Chunk);
   end Clear;

   --  One block's attention: every head over every position, both
   --  ways, which is what a picture is -- no position comes before
   --  another. The head's keys are gathered as a matrix of Patches
   --  rows so that the scores are a product, and its values
   --  transposed so that the blend is one too. Queries, keys and
   --  values are read from three arrays -- or one, at three offsets --
   --  each Stride wide a patch; the blend is written to Attended, Width
   --  a patch.
   --  Queries one call of the device's attention takes: the batch its
   --  kernel was built for.
   Device_Queries : constant Element_Count := 512;

   --  The attention on the device, where one is open: the block's keys
   --  and values written into the device's cache past whatever the
   --  sessions hold there, then every patch's queries against all of
   --  them, a batch of queries a call, both ways -- which is the kernel
   --  the text model's prompts use, told that no position comes before
   --  another. The region begins where the cache ended when this
   --  picture's first block asked, and every block takes the same region
   --  again, so the cache is grown once a picture; a session that later
   --  reserves a block of its own asks for what it needs and the cache
   --  only grows. Counting the base from the cache's bytes over four was
   --  wrong by half -- the bytes hold a half-precision copy past the
   --  values -- and a base that moved by half the cache a block made the
   --  cache half again as large twenty-seven times, which is what took
   --  the machine's memory.
   --
   --  @param Took True when the device did it all; False leaves Attended
   --    untouched and the pool to do it.
   procedure Attend_On_Device
     (Work     : in out Workspace;
      Q, Kv, V : T.Real_Array_Access;
      Q_At, K_At, V_At : Element_Count;
      Stride   : Element_Count;
      Attended : T.Real_Array_Access;
      Width, Patches, Heads, Head : Element_Count;
      Took     : out Boolean)
   is
      Scale : constant Real :=
        Real (N.Wide_Real'(1.0) / Elementary.Sqrt (N.Wide_Real (Head)));
      K_Base : Element_Count;
      V_Base : Element_Count;
      Whole  : T.Real_Array_Access := null;
      Ok     : Boolean;
   begin
      Took := False;
      if not Model_Runner.Backend.Device.Is_Ready
        or else Model_Runner.Cancellation.Is_Cancelled (Work.Cancel)
      then
         return;
      end if;

      if Work.Cache_Base = Element_Count'Last then
         Work.Cache_Base := Model_Runner.Backend.Device.Cached_Elements;
      end if;
      K_Base := Work.Cache_Base;
      V_Base := K_Base + Patches * Width;

      --  Patches are read as an exact session's keys and values are, so
      --  the copy must reach as far as they do.
      Model_Runner.Backend.Device.Reserve_Cache
        (V_Base + Patches * Width, V_Base + Patches * Width, Ok);
      if not Ok then
         return;
      end if;

      --  The keys and the values, each as one run of Patches positions of
      --  Width: as they are where they lie that way, gathered where they
      --  lie Stride apart.
      if Stride = Width then
         Model_Runner.Backend.Device.Put_Cache
           (K_Base, Kv (K_At .. K_At + Patches * Width - 1), Ok);
         if Ok then
            Model_Runner.Backend.Device.Put_Cache
              (V_Base, V (V_At .. V_At + Patches * Width - 1), Ok);
         end if;
      else
         T.Allocate (Patches * Width, Whole);
         if Whole = null then
            return;
         end if;
         for P in 0 .. Patches - 1 loop
            Whole (P * Width .. (P + 1) * Width - 1) :=
              Kv (K_At + P * Stride .. K_At + P * Stride + Width - 1);
         end loop;
         Model_Runner.Backend.Device.Put_Cache (K_Base, Whole.all, Ok);
         if Ok then
            for P in 0 .. Patches - 1 loop
               Whole (P * Width .. (P + 1) * Width - 1) :=
                 V (V_At + P * Stride .. V_At + P * Stride + Width - 1);
            end loop;
            Model_Runner.Backend.Device.Put_Cache (V_Base, Whole.all, Ok);
         end if;
      end if;
      if not Ok then
         T.Free (Whole);
         return;
      end if;

      --  The queries, a batch at a time, gathered contiguous where they
      --  lie Stride apart; the blends land in Attended as they are. In
      --  binary32, off the matrix instruction: its halves moved a row of
      --  the picture by a thousandth of its norm over the blocks, and the
      --  kernel that reads the cache proper by a millionth; the products
      --  are held to binary32 the same way.
      declare
         From : Element_Count := 0;
         Was_Exact : constant Boolean :=
           Model_Runner.Backend.Device.Attends_Exactly;
      begin
         Model_Runner.Backend.Device.Attend_Exactly (True);
         while From < Patches loop
            declare
               Take : constant Element_Count :=
                 Element_Count'Min (Device_Queries, Patches - From);
            begin
               if Stride = Width then
                  Model_Runner.Backend.Device.Attend
                    (Q (Q_At + From * Width .. Q_At + (From + Take) * Width - 1),
                     Natural (Heads), Natural (Head), Natural (Head), 1,
                     0, Natural (Patches - 1),
                     K_Base, V_Base,
                     Natural (Width), Natural (Width),
                     Scale, 0.0,
                     Attended (From * Width .. (From + Take) * Width - 1), Ok,
                     Positions => Natural (Take), Causal => False);
               else
                  for P in 0 .. Take - 1 loop
                     Whole (P * Width .. (P + 1) * Width - 1) :=
                       Q (Q_At + (From + P) * Stride
                          .. Q_At + (From + P) * Stride + Width - 1);
                  end loop;
                  Model_Runner.Backend.Device.Attend
                    (Whole (0 .. Take * Width - 1),
                     Natural (Heads), Natural (Head), Natural (Head), 1,
                     0, Natural (Patches - 1),
                     K_Base, V_Base,
                     Natural (Width), Natural (Width),
                     Scale, 0.0,
                     Attended (From * Width .. (From + Take) * Width - 1), Ok,
                     Positions => Natural (Take), Causal => False);
               end if;
               exit when not Ok;
               From := From + Take;
            end;
         end loop;
         Took := Ok and then From = Patches;
         Model_Runner.Backend.Device.Attend_Exactly (Was_Exact);
      end;
      T.Free (Whole);
   end Attend_On_Device;

   procedure Attend
     (Work     : in out Workspace;
      Q, Kv, V : T.Real_Array_Access;
      Q_At, K_At, V_At : Element_Count;
      Stride   : Element_Count;
      Attended : T.Real_Array_Access;
      Width, Patches, Heads, Head : Element_Count;
      K_Head, Q_Head, V_Head_T, Scores, Blended : T.Real_Array_Access)
   is
      Scale : constant Real :=
        Real (N.Wide_Real'(1.0) / Elementary.Sqrt (N.Wide_Real (Head)));
      Heads_Work : aliased Attention_Work;
      Took : Boolean;
   begin
      if E.Is_Error (Work.Status) then
         return;
      end if;

      Attend_On_Device
        (Work, Q, Kv, V, Q_At, K_At, V_At, Stride, Attended,
         Width, Patches, Heads, Head, Took);
      if Took then
         return;
      end if;

      for H in 0 .. Heads - 1 loop
         exit when E.Is_Error (Work.Status);
         for P in 0 .. Patches - 1 loop
            K_Head (P * Head .. (P + 1) * Head - 1) :=
              Kv (K_At + P * Stride + H * Head
                  .. K_At + P * Stride + (H + 1) * Head - 1);
            for D in 0 .. Head - 1 loop
               Q_Head (P * Head + D) :=
                 Q (Q_At + P * Stride + H * Head + D) * Scale;
               V_Head_T (D * Patches + P) := V (V_At + P * Stride + H * Head + D);
            end loop;
         end loop;

         --  Scores, softmax and blend, a block of queries at a time.
         Heads_Work.Queries := Q_Head;
         Heads_Work.Keys := K_Head;
         Heads_Work.Values_T := V_Head_T;
         Heads_Work.Scores := Scores;
         Heads_Work.Blended := Blended;
         Heads_Work.Patches := Patches;
         Heads_Work.Head := Head;
         Heads_Work.Failed := False;
         CPU.Dispatch_Shares
           (Work.Team, (Patches + Query_Block - 1) / Query_Block,
            Heads_Work'Unchecked_Access, Work.Status,
            Cost => Patches * Patches * Head);
         if E.Is_Ok (Work.Status) and then Heads_Work.Failed then
            Work.Status := E.Make (E.Sampling_Non_Finite_Logit);
         end if;
         exit when E.Is_Error (Work.Status);
         for P in 0 .. Patches - 1 loop
            Attended (P * Width + H * Head .. P * Width + (H + 1) * Head - 1)
              := Blended (P * Head .. (P + 1) * Head - 1);
         end loop;
      end loop;
   end Attend;

   -----------------
   -- Plan_Slices --
   -----------------

   procedure Plan_Slices
     (Item          : Encoder;
      Width, Height : Positive;
      Overview_W, Overview_H : out Positive;
      Refined_W, Refined_H   : out Natural;
      Grid_Cols, Grid_Rows   : out Natural;
      Slices        : out Slice_List;
      Count         : out Natural)
   is
      subtype WR is N.Wide_Real;

      Slice_Side : constant Integer := Item.Size;
      --  MiniCPM-V's resampler does not merge patches, so the slice sizes
      --  align to the patch alone.
      Patch      : constant Integer := Item.Patch;

      function Truncate (X : WR) return Integer
      is (Integer (WR'Truncation (X)));

      --  Round Length to the nearest whole multiple of By, at least By.
      function Ensure_Divide (Length, By : Integer) return Integer
      is (Integer'Max
            (Integer (WR'Rounding (WR (Length) / WR (By))) * By, By));

      --  Fit a size within Slice_Side a side, aspect kept, to whole
      --  patches; upscaled to fill it where allowed, else only shrunk.
      procedure Best_Resize
        (In_W, In_H : Integer; Allow_Upscale : Boolean;
         Out_W, Out_H : out Integer)
      is
         W : Integer := In_W;
         H : Integer := In_H;
      begin
         if In_W * In_H > Slice_Side * Slice_Side or else Allow_Upscale then
            declare
               R : constant WR := WR (In_W) / WR (In_H);
            begin
               H := Truncate (WR (Slice_Side) / Elementary.Sqrt (R));
               W := Truncate (WR (H) * R);
            end;
         end if;
         Out_W := Ensure_Divide (W, Patch);
         Out_H := Ensure_Divide (H, Patch);
      end Best_Resize;

      --  The grid, of at most nine cells, whose shape sits closest to the
      --  picture's aspect: the split counts around the area ratio, each
      --  factored every way, the factor pair nearest the log aspect.
      procedure Best_Grid
        (Multiple : Integer; Log_Ratio : WR;
         Cols, Rows : out Integer)
      is
         Best_Cols : Integer := 1;
         Best_Rows : Integer := 1;
         Min_Error : WR := WR'Last;
         procedure Consider (N : Integer) is
         begin
            if N = 1 or else N > Max_Slices then
               return;
            end if;
            for M in 1 .. N loop
               if N mod M = 0 then
                  declare
                     GW : constant Integer := M;
                     GH : constant Integer := N / M;
                     Err : constant WR :=
                       abs (Log_Ratio
                            - Elementary.Log (WR (GW) / WR (GH)));
                  begin
                     if Err < Min_Error then
                        Min_Error := Err;
                        Best_Cols := GW;
                        Best_Rows := GH;
                     end if;
                  end;
               end if;
            end loop;
         end Consider;
      begin
         Consider (Multiple - 1);
         Consider (Multiple);
         Consider (Multiple + 1);
         Cols := Best_Cols;
         Rows := Best_Rows;
      end Best_Grid;

      Has_Slices : constant Boolean :=
        Width > Slice_Side or else Height > Slice_Side;
      OW, OH : Integer;
   begin
      Overview_W := 1;
      Overview_H := 1;
      Refined_W := 0;
      Refined_H := 0;
      Grid_Cols := 0;
      Grid_Rows := 0;
      Slices := [others => (others => 0)];
      Count := 0;

      Best_Resize (Width, Height, not Has_Slices, OW, OH);
      Overview_W := Positive (OW);
      Overview_H := Positive (OH);

      if not Has_Slices then
         return;
      end if;

      declare
         Log_Ratio : constant WR :=
           Elementary.Log (WR (Width) / WR (Height));
         Ratio : constant WR :=
           WR (Width) * WR (Height) / (WR (Slice_Side) * WR (Slice_Side));
         Multiple : constant Integer :=
           Integer'Min (Truncate (WR'Ceiling (Ratio)), Max_Slices);
         Cols, Rows : Integer;
      begin
         Best_Grid (Multiple, Log_Ratio, Cols, Rows);

         --  Refine: the whole grown to whole cells, each cell fit to the
         --  side to whole patches, the refined picture their tiling.
         declare
            --  The whole grown to a whole number of grid cells, then each
            --  cell fit to the side. ensure_divide here divides by the
            --  grid count, as the reference does, not by the patch.
            Refine_W : constant Integer := Ensure_Divide (Width, Cols);
            Refine_H : constant Integer := Ensure_Divide (Height, Rows);
            Cell_W : constant Integer := Integer'Max (Refine_W / Cols, 1);
            Cell_H : constant Integer := Integer'Max (Refine_H / Rows, 1);
            Best_W, Best_H : Integer;
         begin
            Best_Resize (Cell_W, Cell_H, True, Best_W, Best_H);
            Refined_W := Best_W * Cols;
            Refined_H := Best_H * Rows;
            Grid_Cols := Cols;
            Grid_Rows := Rows;
            Count := Cols * Rows;

            declare
               GX : constant Integer := Refined_W / Cols;
               GY : constant Integer := Refined_H / Rows;
               Index : Natural := 0;
            begin
               for IC in 0 .. Rows - 1 loop
                  for JC in 0 .. Cols - 1 loop
                     Index := Index + 1;
                     Slices (Index) :=
                       (Left   => JC * GX,
                        Top    => IC * GY,
                        Width  => GX,
                        Height => GY);
                  end loop;
               end loop;
            end;
         end;
      end;
   end Plan_Slices;

   procedure Encode_Gemma
     (Item    : in out Encoder;
      Picture : Model_Runner.Images.Raster;
      Team    : CPU.Pool_Reference;
      Rows    : out T.Real_Array_Access;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out E.Error_Info)
   is
      Width    : constant Element_Count := Element_Count (Item.Width);
      Feed     : constant Element_Count := Element_Count (Item.Feed);
      Heads    : constant Element_Count := Element_Count (Item.Heads);
      Head     : constant Element_Count := Width / Heads;
      Side     : constant Element_Count :=
        Element_Count (Item.Size / Item.Patch);
      Patches  : constant Element_Count := Side * Side;
      Patch_Elements : constant Element_Count :=
        3 * Element_Count (Item.Patch) ** 2;
      Pooled_Side : constant Element_Count :=
        Side / Element_Count (Item.Pool_Side);
      Pooled   : constant Element_Count := Pooled_Side * Pooled_Side;
      Text_Width : constant Element_Count := Element_Count (Item.Text_Width);

      --  The activations: every buffer is Patches rows of something.
      X, Normed, Q, Kv, V, Attended, Hidden : T.Real_Array_Access := null;

      --  A head's keys, queries and values gathered contiguous, a head's
      --  scores, and its blend.
      K_Head, Q_Head, V_Head_T, Scores, Blended : T.Real_Array_Access := null;

      Resampled : Model_Runner.Images.Raster;

      Work : Workspace;

      procedure Release is
      begin
         T.Free (X);
         T.Free (Normed);
         T.Free (Q);
         T.Free (Kv);
         T.Free (V);
         T.Free (Attended);
         T.Free (Hidden);
         T.Free (K_Head);
         T.Free (Q_Head);
         T.Free (V_Head_T);
         T.Free (Scores);
         T.Free (Blended);
         Clear (Work);
         Model_Runner.Images.Free (Resampled);
      end Release;

      --  The shared helpers, each under this encode's status.
      procedure Rows_Through
        (What : Row_Task;
         Target : T.Real_Array_Access;
         Total  : Element_Count;
         Row_Width : Element_Count;
         Source : T.Real_Array_Access := null;
         Bias   : T.Real_Array_Access := null;
         Weight : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Rows_Through (Work, What, Target, Total, Row_Width, Source, Bias, Weight);
         Status := Work.Status;
      end Rows_Through;

      procedure Multiply
        (Source : T.Real_Array_Access;
         Source_At : Element_Count;
         Total  : Element_Count;
         W      : T.Real_Array_Access;
         Wanted : Element_Count;
         Row_Width : Element_Count;
         Target : T.Real_Array_Access;
         Bias   : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Multiply (Work, Source, Source_At, Total, W, Wanted, Row_Width, Target, Bias);
         Status := Work.Status;
      end Multiply;

      procedure Multiply
        (Source : T.Real_Array_Access;
         Total  : Element_Count;
         Weight : T.View;
         Target : T.Real_Array_Access;
         Bias   : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Multiply (Work, Source, Total, Weight, Target, Bias);
         Status := Work.Status;
      end Multiply;

      procedure Attend is
      begin
         Work.Status := Status;
         Attend (Work, Q, Kv, V, 0, 0, 0, Width, Attended, Width, Patches,
                 Heads, Head, K_Head, Q_Head, V_Head_T, Scores, Blended);
         Status := Work.Status;
      end Attend;

   begin
      Rows := null;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      if Picture.Pixels = null then
         Status := E.Make (E.Generation_Empty_Prompt);
         return;
      end if;

      T.Allocate (Patches * Width, X);
      T.Allocate (Patches * Width, Normed);
      T.Allocate (Patches * Width, Q);
      T.Allocate (Patches * Width, Kv);
      T.Allocate (Patches * Width, V);
      T.Allocate (Patches * Width, Attended);
      T.Allocate (Patches * Element_Count'Max (Feed, Patch_Elements), Hidden);
      Work.Team := Team;
      Work.Cancel := Cancel;
      Work.Epsilon := Item.Epsilon;
      Furnish
        (Work,
         Element_Count'Max (Feed * Width,
                            Element_Count'Max (Patches * Width,
                                               Width * Patch_Elements)),
         Element_Count'Max (Feed, Patch_Elements),
         Element_Count'Max (Feed, Text_Width));
      if E.Is_Error (Work.Status) then
         Status := Work.Status;
         Release;
         return;
      end if;
      T.Allocate (Patches * Head, K_Head);
      T.Allocate (Patches * Head, Q_Head);
      T.Allocate (Patches * Head, V_Head_T);
      T.Allocate (Patches * Patches, Scores);
      T.Allocate (Patches * Head, Blended);

      if X = null or else Normed = null or else Q = null or else Kv = null
        or else V = null or else Attended = null or else Hidden = null
        or else K_Head = null or else Q_Head = null or else V_Head_T = null
        or else Scores = null or else Blended = null
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;

      --  The picture, at the encoder's size, as patch vectors: channel,
      --  then row, then column within the patch, each pixel scaled to
      --  the range the encoder was trained on. Hidden was sized to hold
      --  them as well as the feed-forward's rows.
      Model_Runner.Images.Resample (Picture, Item.Size, Item.Size, Resampled);
      if Resampled.Pixels = null then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;

      declare
         Patch : constant Element_Count := Element_Count (Item.Patch);
         Size  : constant B.Byte_Count := B.Byte_Count (Item.Size);
      begin
         for PY in 0 .. Side - 1 loop
            for PX in 0 .. Side - 1 loop
               declare
                  At_Patch : constant Element_Count :=
                    (PY * Side + PX) * Patch_Elements;
               begin
                  for C in Element_Count range 0 .. 2 loop
                     for KY in 0 .. Patch - 1 loop
                        for KX in 0 .. Patch - 1 loop
                           declare
                              Y : constant B.Byte_Count :=
                                B.Byte_Count (PY * Patch + KY);
                              Xp : constant B.Byte_Count :=
                                B.Byte_Count (PX * Patch + KX);
                              Value : constant Real :=
                                Real (Resampled.Pixels
                                        (3 * (Y * Size + Xp) + B.Byte_Count (C)))
                                / 255.0;
                           begin
                              Hidden (At_Patch + C * Patch * Patch
                                      + KY * Patch + KX) :=
                                (Value - Item.Mean (Positive (C + 1)))
                                / Item.Deviation (Positive (C + 1));
                           end;
                        end loop;
                     end loop;
                  end loop;
               end;
            end loop;
         end loop;
      end;
      Model_Runner.Images.Free (Resampled);

      --  Patch embedding, then where each patch is.
      Multiply (Hidden, Patches, Item.Patch_Weights, X, Item.Patch_Bias);
      if E.Is_Ok (Status) then
         for P in 0 .. Patches - 1 loop
            T.Dequantize_Row (Item.Positions, P, Normed (0 .. Width - 1), Status);
            exit when E.Is_Error (Status);
            K.Add (X (P * Width .. (P + 1) * Width - 1), Normed (0 .. Width - 1));
         end loop;
      end if;

      --  The blocks, each pre-normalized: attention over its first norm
      --  and the feed-forward over its second, both added to the stream.
      for Index in 0 .. Item.Blocks - 1 loop
         exit when E.Is_Error (Status);
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled);
            exit;
         end if;

         declare
            Current : Block renames Item.Layers (Index);
         begin
            Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                          Bias => Current.Norm_1_Bias,
                          Weight => Current.Norm_1_Weight);
            Multiply (Normed, Patches, Current.Query, Q, Current.Query_Bias);
            Multiply (Normed, Patches, Current.Key, Kv, Current.Key_Bias);
            Multiply (Normed, Patches, Current.Value, V, Current.Value_Bias);
            Attend;
            Multiply (Attended, Patches, Current.Output, Normed,
                      Current.Output_Bias);
            exit when E.Is_Error (Status);
            K.Add (X.all, Normed.all);

            Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                          Bias => Current.Norm_2_Bias,
                          Weight => Current.Norm_2_Weight);
            Multiply (Normed, Patches, Current.Feed_In, Hidden,
                      Current.Feed_In_Bias);
            Rows_Through (Gaussian, Hidden, Patches, Feed);
            Multiply (Hidden, Patches, Current.Feed_Out, Normed,
                      Current.Feed_Out_Bias);
            exit when E.Is_Error (Status);
            K.Add (X.all, Normed.all);
         end;
      end loop;

      --  The last norm, then the projector: the grid of patch states
      --  pooled Pool_Side by Pool_Side, each pooled row normalized by its
      --  root mean square under the soft-embedding gain and projected to
      --  the text width.
      if E.Is_Ok (Status) then
         Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                       Bias => Item.Post_Bias, Weight => Item.Post_Weight);
      end if;

      if E.Is_Ok (Status) then
         declare
            Span : constant Element_Count := Element_Count (Item.Pool_Side);
            Share : constant Real := 1.0 / Real (Span * Span);
         begin
            for GY in 0 .. Pooled_Side - 1 loop
               for GX in 0 .. Pooled_Side - 1 loop
                  declare
                     Row : constant Element_Count := (GY * Pooled_Side + GX) * Width;
                  begin
                     Q (Row .. Row + Width - 1) := [others => 0.0];
                     for I in 0 .. Span - 1 loop
                        for J in 0 .. Span - 1 loop
                           declare
                              P : constant Element_Count :=
                                ((GY * Span + I) * Side + GX * Span + J) * Width;
                           begin
                              for D in 0 .. Width - 1 loop
                                 Q (Row + D) := Q (Row + D) + Normed (P + D);
                              end loop;
                           end;
                        end loop;
                     end loop;
                     K.Scale (Q (Row .. Row + Width - 1), Share);
                     K.RMS_Norm
                       (Q (Row .. Row + Width - 1), Item.Soft_Norm.all,
                        Item.Epsilon, Kv (Row .. Row + Width - 1));
                  end;
               end loop;
            end loop;
         end;

         T.Allocate (Pooled * Text_Width, Rows);
         if Rows = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         elsif Model_Runner.Backend.Device.Is_Ready then
            Multiply (Kv, Pooled, Item.Projection, Rows);
         else
            Multiply (Kv, 0, Pooled, Item.Projection_Rows, Text_Width, Width,
                      Rows);
         end if;
      end if;

      Release;

      if E.Is_Error (Status) then
         T.Free (Rows);
      end if;
   end Encode_Gemma;

   --------------------
   -- Encode_Minicpm --
   --------------------

   --  MiniCPM-V over one picture: the SigLIP encoder read as Gemma's is
   --  -- the picture at the encoder's square, patch-embedded and placed
   --  by a bank of learned rows the patch grid buckets into, through the
   --  pre-normalized blocks and a post norm -- then the resampler: the
   --  patch states projected to the text width and normed; a fixed bank
   --  of learned query rows, normed; keys the states plus a sinusoidal
   --  place of the patch's row and column; query, key and value each
   --  turned into heads of a hundred and twenty-eight, the queries
   --  attending over every patch; the blend turned back, normed once
   --  more, and projected. A picture becomes Num_Query rows however many
   --  patches it has.
   procedure Encode_Minicpm
     (Item    : in out Encoder;
      Picture : Model_Runner.Images.Raster;
      Team    : CPU.Pool_Reference;
      Rows    : out T.Real_Array_Access;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out E.Error_Info)
   is
      Width    : constant Element_Count := Element_Count (Item.Width);
      Feed     : constant Element_Count := Element_Count (Item.Feed);
      Heads    : constant Element_Count := Element_Count (Item.Heads);
      Head     : constant Element_Count := Width / Heads;
      Patch_Px : constant Element_Count := Element_Count (Item.Patch);
      --  MiniCPM-V keeps a picture's aspect: the grid is the picture's
      --  own sides in whole patches, each at least one, and the picture is
      --  resampled to exactly that grid rather than to a square. The
      --  resampler makes Num_Query rows of it however many patches it is.
      Side_X   : constant Element_Count :=
        Element_Count'Max (1, Element_Count (Picture.Width) / Patch_Px);
      Side_Y   : constant Element_Count :=
        Element_Count'Max (1, Element_Count (Picture.Height) / Patch_Px);
      Target_W : constant Positive := Positive (Side_X * Patch_Px);
      Target_H : constant Positive := Positive (Side_Y * Patch_Px);
      Patches  : constant Element_Count := Side_X * Side_Y;
      Patch_Elements : constant Element_Count :=
        3 * Element_Count (Item.Patch) ** 2;

      P        : constant Element_Count := Element_Count (Item.Text_Width);
      Nq       : constant Element_Count := Element_Count (Item.Num_Query);
      D_Head   : constant Element_Count := 128;
      N_Head   : constant Element_Count := P / D_Head;
      Quarter  : constant Element_Count := P / 4;
      Half     : constant Element_Count := P / 2;
      Base_Freq : constant N.Wide_Real := 10_000.0;
      Scale    : constant Real :=
        Real (N.Wide_Real'(1.0) / Elementary.Sqrt (N.Wide_Real (D_Head)));

      --  The ViT activations, Patches rows of Width, and the head scratch.
      X, Normed, Q, Kv, V, Attended, Hidden : T.Real_Array_Access := null;
      K_Head, Q_Head, V_Head_T, Scores, Blended : T.Real_Array_Access := null;

      --  The resampler activations: the query bank and its norm, the
      --  projected states and their norm, the sinusoidal place, the keys,
      --  the three heads, the blend, its projection and norm.
      Qsrc, Qn, Kv1, Kvn, Pos, Kk, Qh, Kh, Vh, Att, Rout, Routn :
        T.Real_Array_Access := null;
      Row_Scores : T.Real_Array_Access := null;

      Resampled : Model_Runner.Images.Raster;
      Work : Workspace;
      Omega : array (0 .. Quarter - 1) of Real;

      procedure Release is
      begin
         T.Free (X); T.Free (Normed); T.Free (Q); T.Free (Kv); T.Free (V);
         T.Free (Attended); T.Free (Hidden);
         T.Free (K_Head); T.Free (Q_Head); T.Free (V_Head_T);
         T.Free (Scores); T.Free (Blended);
         T.Free (Qsrc); T.Free (Qn); T.Free (Kv1); T.Free (Kvn);
         T.Free (Pos); T.Free (Kk); T.Free (Qh); T.Free (Kh); T.Free (Vh);
         T.Free (Att); T.Free (Rout); T.Free (Routn); T.Free (Row_Scores);
         Clear (Work);
         Model_Runner.Images.Free (Resampled);
      end Release;

      procedure Rows_Through
        (What : Row_Task; Target : T.Real_Array_Access; Total : Element_Count;
         Row_Width : Element_Count; Source : T.Real_Array_Access := null;
         Bias : T.Real_Array_Access := null;
         Weight : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Rows_Through (Work, What, Target, Total, Row_Width, Source, Bias, Weight);
         Status := Work.Status;
      end Rows_Through;

      procedure Multiply
        (Source : T.Real_Array_Access; Total : Element_Count; Weight : T.View;
         Target : T.Real_Array_Access; Bias : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Multiply (Work, Source, Total, Weight, Target, Bias);
         Status := Work.Status;
      end Multiply;

      procedure Attend is
      begin
         Work.Status := Status;
         Attend (Work, Q, Kv, V, 0, 0, 0, Width, Attended, Width, Patches,
                 Heads, Head, K_Head, Q_Head, V_Head_T, Scores, Blended);
         Status := Work.Status;
      end Attend;
   begin
      Rows := null;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;
      if Picture.Pixels = null then
         Status := E.Make (E.Generation_Empty_Prompt);
         return;
      end if;

      T.Allocate (Patches * Width, X);
      T.Allocate (Patches * Width, Normed);
      T.Allocate (Patches * Width, Q);
      T.Allocate (Patches * Width, Kv);
      T.Allocate (Patches * Width, V);
      T.Allocate (Patches * Width, Attended);
      T.Allocate (Patches * Element_Count'Max (Feed, Patch_Elements), Hidden);
      Work.Team := Team;
      Work.Cancel := Cancel;
      Work.Epsilon := Item.Epsilon;
      Furnish
        (Work,
         Element_Count'Max
           (Element_Count'Max (Feed * Width, Width * Patch_Elements),
            Element_Count'Max (P * P, P * Width)),
         Element_Count'Max (Width, Element_Count'Max (Patch_Elements, P)),
         Element_Count'Max (Width, Element_Count'Max (Feed, P)));
      if E.Is_Error (Work.Status) then
         Status := Work.Status; Release; return;
      end if;
      T.Allocate (Patches * Head, K_Head);
      T.Allocate (Patches * Head, Q_Head);
      T.Allocate (Patches * Head, V_Head_T);
      T.Allocate (Patches * Patches, Scores);
      T.Allocate (Patches * Head, Blended);

      T.Allocate (Nq * P, Qsrc);
      T.Allocate (Nq * P, Qn);
      T.Allocate (Patches * P, Kv1);
      T.Allocate (Patches * P, Kvn);
      T.Allocate (Patches * P, Pos);
      T.Allocate (Patches * P, Kk);
      T.Allocate (Nq * P, Qh);
      T.Allocate (Patches * P, Kh);
      T.Allocate (Patches * P, Vh);
      T.Allocate (Nq * P, Att);
      T.Allocate (Nq * P, Rout);
      T.Allocate (Nq * P, Routn);
      T.Allocate (Nq * Patches, Row_Scores);
      T.Allocate (Nq * P, Rows);

      if X = null or else Normed = null or else Q = null or else Kv = null
        or else V = null or else Attended = null or else Hidden = null
        or else K_Head = null or else Q_Head = null or else V_Head_T = null
        or else Scores = null or else Blended = null
        or else Qsrc = null or else Qn = null or else Kv1 = null
        or else Kvn = null or else Pos = null or else Kk = null
        or else Qh = null or else Kh = null or else Vh = null
        or else Att = null or else Rout = null or else Routn = null
        or else Row_Scores = null or else Rows = null
      then
         Release; T.Free (Rows);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;

      --  The picture, at the encoder's square, as patch vectors.
      Model_Runner.Images.Resample (Picture, Target_W, Target_H, Resampled);
      if Resampled.Pixels = null then
         Release; T.Free (Rows);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;
      declare
         Patch : constant Element_Count := Element_Count (Item.Patch);
         Size  : constant B.Byte_Count := B.Byte_Count (Target_W);
      begin
         for PY in 0 .. Side_Y - 1 loop
            for PX in 0 .. Side_X - 1 loop
               declare
                  At_Patch : constant Element_Count :=
                    (PY * Side_X + PX) * Patch_Elements;
               begin
                  for C in Element_Count range 0 .. 2 loop
                     for KY in 0 .. Patch - 1 loop
                        for KX in 0 .. Patch - 1 loop
                           declare
                              Y : constant B.Byte_Count :=
                                B.Byte_Count (PY * Patch + KY);
                              Xp : constant B.Byte_Count :=
                                B.Byte_Count (PX * Patch + KX);
                              Value : constant Real :=
                                Real (Resampled.Pixels
                                        (3 * (Y * Size + Xp) + B.Byte_Count (C)))
                                / 255.0;
                           begin
                              Hidden (At_Patch + C * Patch * Patch
                                      + KY * Patch + KX) :=
                                (Value - Item.Mean (Positive (C + 1)))
                                / Item.Deviation (Positive (C + 1));
                           end;
                        end loop;
                     end loop;
                  end loop;
               end;
            end loop;
         end loop;
      end;
      Model_Runner.Images.Free (Resampled);

      --  Patch embedding, then each patch placed by the learned bank the
      --  grid buckets into -- floor(70 row / side) by seventy and floor
      --  (70 column / side), as the SigLIP position scheme selects.
      Multiply (Hidden, Patches, Item.Patch_Weights, X, Item.Patch_Bias);
      if E.Is_Ok (Status) then
         for PY in 0 .. Side_Y - 1 loop
            for PX in 0 .. Side_X - 1 loop
               declare
                  P_Index : constant Element_Count := PY * Side_X + PX;
                  Bucket  : constant Element_Count :=
                    (70 * PY / Side_Y) * 70 + (70 * PX / Side_X);
               begin
                  T.Dequantize_Row
                    (Item.Positions, Bucket, Normed (0 .. Width - 1), Status);
                  exit when E.Is_Error (Status);
                  K.Add (X (P_Index * Width .. (P_Index + 1) * Width - 1),
                         Normed (0 .. Width - 1));
               end;
            end loop;
            exit when E.Is_Error (Status);
         end loop;
      end if;

      --  The blocks, each pre-normalized.
      for Index in 0 .. Item.Blocks - 1 loop
         exit when E.Is_Error (Status);
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled);
            exit;
         end if;
         declare
            Current : Block renames Item.Layers (Index);
         begin
            Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                          Bias => Current.Norm_1_Bias,
                          Weight => Current.Norm_1_Weight);
            Multiply (Normed, Patches, Current.Query, Q, Current.Query_Bias);
            Multiply (Normed, Patches, Current.Key, Kv, Current.Key_Bias);
            Multiply (Normed, Patches, Current.Value, V, Current.Value_Bias);
            Attend;
            Multiply (Attended, Patches, Current.Output, Normed,
                      Current.Output_Bias);
            exit when E.Is_Error (Status);
            K.Add (X.all, Normed.all);

            Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                          Bias => Current.Norm_2_Bias,
                          Weight => Current.Norm_2_Weight);
            Multiply (Normed, Patches, Current.Feed_In, Hidden,
                      Current.Feed_In_Bias);
            Rows_Through (Gaussian, Hidden, Patches, Feed);
            Multiply (Hidden, Patches, Current.Feed_Out, Normed,
                      Current.Feed_Out_Bias);
            exit when E.Is_Error (Status);
            K.Add (X.all, Normed.all);
         end;
      end loop;

      --  The post norm leaves the patch states in Normed.
      if E.Is_Ok (Status) then
         Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                       Bias => Item.Post_Bias, Weight => Item.Post_Weight);
      end if;

      --  The resampler. The states to the text width and normed; the
      --  learned queries normed; the sinusoidal place; the keys.
      if E.Is_Ok (Status) then
         Multiply (Normed, Patches, Item.Kv_Proj, Kv1);
         Rows_Through (Normalize, Kvn, Patches, P, Source => Kv1,
                       Bias => Item.R_Ln_Kv_B, Weight => Item.R_Ln_Kv_W);
         for R in 0 .. Nq - 1 loop
            T.Dequantize_Row
              (Item.Query_Rows, R, Qsrc (R * P .. (R + 1) * P - 1), Status);
            exit when E.Is_Error (Status);
         end loop;
      end if;
      if E.Is_Ok (Status) then
         Rows_Through (Normalize, Qn, Nq, P, Source => Qsrc,
                       Bias => Item.R_Ln_Q_B, Weight => Item.R_Ln_Q_W);

         for I in 0 .. Quarter - 1 loop
            Omega (I) :=
              Real (N.Wide_Real'(1.0)
                / Elementary."**" (Base_Freq,
                    N.Wide_Real (I) / N.Wide_Real (Quarter)));
         end loop;
         for Pt in 0 .. Patches - 1 loop
            declare
               Rowv : constant Element_Count := Pt / Side_X;
               Colv : constant Element_Count := Pt mod Side_X;
            begin
               for I in 0 .. Quarter - 1 loop
                  declare
                     W_Omega : constant Real := Omega (I);
                     TX : constant N.Wide_Real :=
                       N.Wide_Real (W_Omega) * N.Wide_Real (Colv);
                     TY : constant N.Wide_Real :=
                       N.Wide_Real (W_Omega) * N.Wide_Real (Rowv);
                  begin
                     Pos (Pt * P + I) := Real (Elementary.Sin (TX));
                     Pos (Pt * P + Quarter + I) := Real (Elementary.Cos (TX));
                     Pos (Pt * P + Half + I) := Real (Elementary.Sin (TY));
                     Pos (Pt * P + Half + Quarter + I) :=
                       Real (Elementary.Cos (TY));
                  end;
               end loop;
            end;
         end loop;
         Kk.all := Kvn.all;
         K.Add (Kk.all, Pos.all);
      end if;

      --  Query, key and value, each turned through its own weights; the
      --  queries attend over every patch, a head at a time.
      if E.Is_Ok (Status) then
         Multiply (Qn, Nq, Item.R_Attn_Q, Qh, Item.R_Attn_Q_B);
         Multiply (Kk, Patches, Item.R_Attn_K, Kh, Item.R_Attn_K_B);
         Multiply (Kvn, Patches, Item.R_Attn_V, Vh, Item.R_Attn_V_B);
      end if;
      if E.Is_Ok (Status) then
         declare
            Cross : aliased Cross_Work;
         begin
            Cross.Queries := Qh;
            Cross.Keys := Kh;
            Cross.Values := Vh;
            Cross.Scores := Row_Scores;
            Cross.Blended := Att;
            Cross.Width := P;
            Cross.Patches := Patches;
            Cross.Heads := N_Head;
            Cross.Head := D_Head;
            Cross.Scale := Scale;
            Cross.Failed := False;
            CPU.Dispatch_Shares
              (Team, Nq, Cross'Unchecked_Access, Status,
               Cost => Nq * N_Head * Patches * D_Head);
            if E.Is_Ok (Status) and then Cross.Failed then
               Status := E.Make (E.Sampling_Non_Finite_Logit);
            end if;
         end;
      end if;

      --  The blend turned back, normed once more, and projected.
      if E.Is_Ok (Status) then
         Multiply (Att, Nq, Item.R_Attn_O, Rout, Item.R_Attn_O_B);
         Rows_Through (Normalize, Routn, Nq, P, Source => Rout,
                       Bias => Item.R_Ln_Post_B, Weight => Item.R_Ln_Post_W);
         Multiply (Routn, Nq, Item.R_Proj, Rows);
      end if;

      Release;
      if E.Is_Error (Status) then
         T.Free (Rows);
      end if;
   end Encode_Minicpm;

   ---------------------
   -- Encode_Minicpm46 --
   ---------------------

   --  MiniCPM-V 4.6 over one picture: the same SigLIP encoder the resampler
   --  runs, at the encoder's own square, and then the downsample-MLP head --
   --  each two-by-two block of the patch grid joined into one row (top-left,
   --  top-right, bottom-left, bottom-right, as llama.cpp's make_ds_idx lays
   --  them), normalized, widened through an error-function unit and narrowed
   --  to the text width. No post norm: this file carries none.
   procedure Encode_Minicpm46
     (Item    : in out Encoder;
      Picture : Model_Runner.Images.Raster;
      Team    : CPU.Pool_Reference;
      Rows    : out T.Real_Array_Access;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out E.Error_Info)
   is
      Width    : constant Element_Count := Element_Count (Item.Width);
      Feed     : constant Element_Count := Element_Count (Item.Feed);
      Heads    : constant Element_Count := Element_Count (Item.Heads);
      Head     : constant Element_Count := Width / Heads;
      Patch_Px : constant Element_Count := Element_Count (Item.Patch);
      Text     : constant Element_Count := Element_Count (Item.Text_Width);
      VFeed    : constant Element_Count := Element_Count (Item.Merge_Feed);
      Insert   : constant Natural := Item.Insert_Layer;
      Scale    : constant Real :=
        Real (N.Wide_Real'(1.0) / Elementary.Sqrt (N.Wide_Real (Head)));

      Side     : constant Element_Count :=
        Element_Count (Item.Size) / Patch_Px;
      Target_W : constant Positive := Positive (Side * Patch_Px);
      Target_H : constant Positive := Positive (Side * Patch_Px);
      Patches  : constant Element_Count := Side * Side;
      Patch_Elements : constant Element_Count := 3 * Patch_Px ** 2;

      --  The two two-by-two merges: the first over the patch grid, the
      --  second over what it left.
      Side1    : constant Element_Count := Side / 2;
      Tokens1  : constant Element_Count := Side1 * Side1;
      Side2    : constant Element_Count := Side1 / 2;
      Tokens2  : constant Element_Count := Side2 * Side2;
      Merged   : constant Element_Count := 4 * Width;

      X, Normed, Q, Kv, V, Attended, Hidden : T.Real_Array_Access := null;
      K_Head, Q_Head, V_Head_T, Scores, Blended : T.Real_Array_Access := null;
      X2, Mean1, Joined, Wide1, Joined2, Wide2 : T.Real_Array_Access := null;
      Merged_Normed : T.Real_Array_Access := null;

      Resampled : Model_Runner.Images.Raster;
      Work : Workspace;

      procedure Release is
      begin
         T.Free (X); T.Free (Normed); T.Free (Q); T.Free (Kv); T.Free (V);
         T.Free (Attended); T.Free (Hidden);
         T.Free (K_Head); T.Free (Q_Head); T.Free (V_Head_T);
         T.Free (Scores); T.Free (Blended);
         T.Free (X2); T.Free (Mean1); T.Free (Joined); T.Free (Wide1);
         T.Free (Joined2); T.Free (Wide2); T.Free (Merged_Normed);
         Clear (Work);
         Model_Runner.Images.Free (Resampled);
      end Release;

      procedure Rows_Through
        (What : Row_Task; Target : T.Real_Array_Access; Total : Element_Count;
         Row_Width : Element_Count; Source : T.Real_Array_Access := null;
         Bias : T.Real_Array_Access := null;
         Weight : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Rows_Through (Work, What, Target, Total, Row_Width, Source, Bias,
                       Weight);
         Status := Work.Status;
      end Rows_Through;

      procedure Multiply
        (Source : T.Real_Array_Access; Total : Element_Count; Weight : T.View;
         Target : T.Real_Array_Access; Bias : T.Real_Array_Access := null) is
      begin
         Work.Status := Status;
         Multiply (Work, Source, Total, Weight, Target, Bias);
         Status := Work.Status;
      end Multiply;

      procedure Attend (Count : Element_Count) is
      begin
         Work.Status := Status;
         Attend (Work, Q, Kv, V, 0, 0, 0, Width, Attended, Width, Count,
                 Heads, Head, K_Head, Q_Head, V_Head_T, Scores, Blended);
         Status := Work.Status;
      end Attend;

      --  One SigLIP block over Count tokens held in Buf: pre-norm, full
      --  attention, a Gaussian feed-forward, each with its residual.
      procedure Run_Block (Index : Natural; Count : Element_Count;
                           Buf : T.Real_Array_Access) is
         Current : Block renames Item.Layers (Index);
         Span : constant Element_Count := Count * Width;
      begin
         Rows_Through (Normalize, Normed, Count, Width, Source => Buf,
                       Bias => Current.Norm_1_Bias,
                       Weight => Current.Norm_1_Weight);
         Multiply (Normed, Count, Current.Query, Q, Current.Query_Bias);
         Multiply (Normed, Count, Current.Key, Kv, Current.Key_Bias);
         Multiply (Normed, Count, Current.Value, V, Current.Value_Bias);
         Attend (Count);
         Multiply (Attended, Count, Current.Output, Normed,
                   Current.Output_Bias);
         if E.Is_Error (Status) then
            return;
         end if;
         K.Add (Buf (Buf'First .. Buf'First + Span - 1),
                Normed (Normed'First .. Normed'First + Span - 1));

         Rows_Through (Normalize, Normed, Count, Width, Source => Buf,
                       Bias => Current.Norm_2_Bias,
                       Weight => Current.Norm_2_Weight);
         Multiply (Normed, Count, Current.Feed_In, Hidden,
                   Current.Feed_In_Bias);
         Rows_Through (Gaussian, Hidden, Count, Feed);
         Multiply (Hidden, Count, Current.Feed_Out, Normed,
                   Current.Feed_Out_Bias);
         if E.Is_Error (Status) then
            return;
         end if;
         K.Add (Buf (Buf'First .. Buf'First + Span - 1),
                Normed (Normed'First .. Normed'First + Span - 1));
      end Run_Block;

      --  The four patches of a two-by-two block, top-left, top-right,
      --  bottom-left, bottom-right, as make_ds_idx lays them: block (I, J)
      --  of a Grid-by-Grid layout takes rows (2I, 2J) and its neighbours.
      function Corner
        (Grid, I, J, Which : Element_Count) return Element_Count
      is (case Which is
             when 0 => (2 * I) * Grid + (2 * J),
             when 1 => (2 * I) * Grid + (2 * J + 1),
             when 2 => (2 * I + 1) * Grid + (2 * J),
             when others => (2 * I + 1) * Grid + (2 * J + 1));

   begin
      Rows := null;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;
      if Picture.Pixels = null then
         Status := E.Make (E.Generation_Empty_Prompt);
         return;
      end if;

      T.Allocate (Patches * Width, X);
      T.Allocate (Patches * Width, Normed);
      T.Allocate (Patches * Width, Q);
      T.Allocate (Patches * Width, Kv);
      T.Allocate (Patches * Width, V);
      T.Allocate (Patches * Width, Attended);
      T.Allocate (Patches * Element_Count'Max (Feed, Patch_Elements), Hidden);
      Work.Team := Team;
      Work.Cancel := Cancel;
      Work.Epsilon := Item.Epsilon;
      Furnish
        (Work,
         Element_Count'Max
           (Element_Count'Max (Feed * Width, Width * Patch_Elements),
            Element_Count'Max (Merged * VFeed, Merged * Merged)),
         Element_Count'Max (Width, Element_Count'Max (Patch_Elements, Merged)),
         Element_Count'Max (Width, Element_Count'Max (Feed,
                            Element_Count'Max (VFeed, Text))));
      if E.Is_Error (Work.Status) then
         Status := Work.Status; Release; return;
      end if;
      T.Allocate (Patches * Head, K_Head);
      T.Allocate (Patches * Head, Q_Head);
      T.Allocate (Patches * Head, V_Head_T);
      T.Allocate (Patches * Patches, Scores);
      T.Allocate (Patches * Head, Blended);
      T.Allocate (Tokens1 * Width, X2);
      T.Allocate (Tokens1 * Width, Mean1);
      T.Allocate (Tokens1 * Merged, Joined);
      T.Allocate (Tokens1 * VFeed, Wide1);
      T.Allocate (Tokens2 * Merged, Joined2);
      T.Allocate (Tokens2 * Merged, Wide2);
      T.Allocate (Tokens1 * Merged, Merged_Normed);
      T.Allocate (Tokens2 * Text, Rows);

      if X = null or else Normed = null or else Q = null or else Kv = null
        or else V = null or else Attended = null or else Hidden = null
        or else K_Head = null or else Q_Head = null or else V_Head_T = null
        or else Scores = null or else Blended = null or else X2 = null
        or else Mean1 = null or else Joined = null or else Wide1 = null
        or else Joined2 = null or else Wide2 = null or else Rows = null
        or else Merged_Normed = null
      then
         Release; T.Free (Rows);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;

      --  The picture at the encoder's square, as patch vectors.
      Model_Runner.Images.Resample (Picture, Target_W, Target_H, Resampled);
      if Resampled.Pixels = null then
         Release; T.Free (Rows);
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;
      declare
         Size : constant B.Byte_Count := B.Byte_Count (Target_W);
      begin
         for PY in 0 .. Side - 1 loop
            for PX in 0 .. Side - 1 loop
               declare
                  At_Patch : constant Element_Count :=
                    (PY * Side + PX) * Patch_Elements;
               begin
                  for C in Element_Count range 0 .. 2 loop
                     for KY in 0 .. Patch_Px - 1 loop
                        for KX in 0 .. Patch_Px - 1 loop
                           declare
                              Y : constant B.Byte_Count :=
                                B.Byte_Count (PY * Patch_Px + KY);
                              Xp : constant B.Byte_Count :=
                                B.Byte_Count (PX * Patch_Px + KX);
                              Value : constant Real :=
                                Real (Resampled.Pixels
                                  (3 * (Y * Size + Xp) + B.Byte_Count (C)))
                                / 255.0;
                           begin
                              Hidden (At_Patch + C * Patch_Px * Patch_Px
                                      + KY * Patch_Px + KX) :=
                                (Value - Item.Mean (Positive (C + 1)))
                                / Item.Deviation (Positive (C + 1));
                           end;
                        end loop;
                     end loop;
                  end loop;
               end;
            end loop;
         end loop;
      end;
      Model_Runner.Images.Free (Resampled);

      Multiply (Hidden, Patches, Item.Patch_Weights, X, Item.Patch_Bias);
      if E.Is_Ok (Status) then
         for PY in 0 .. Side - 1 loop
            for PX in 0 .. Side - 1 loop
               declare
                  P_Index : constant Element_Count := PY * Side + PX;
                  Bucket  : constant Element_Count :=
                    (70 * PY / Side) * 70 + (70 * PX / Side);
               begin
                  T.Dequantize_Row
                    (Item.Positions, Bucket, Normed (0 .. Width - 1), Status);
                  exit when E.Is_Error (Status);
                  K.Add (X (P_Index * Width .. (P_Index + 1) * Width - 1),
                         Normed (0 .. Width - 1));
               end;
            end loop;
            exit when E.Is_Error (Status);
         end loop;
      end if;

      --  The blocks up to the insertion point, over the whole patch grid.
      for Index in 0 .. Insert loop
         exit when E.Is_Error (Status);
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled); exit;
         end if;
         Run_Block (Index, Patches, X);
      end loop;

      --  The windowed merger's self-attention: each two-by-two window's four
      --  tokens attend among themselves, and nowhere else.
      if E.Is_Ok (Status) then
         Rows_Through (Normalize, Normed, Patches, Width, Source => X,
                       Bias => Item.VM_Ln1_B, Weight => Item.VM_Ln1_W);
         Multiply (Normed, Patches, Item.VM_Q, Q, Item.VM_Q_B);
         Multiply (Normed, Patches, Item.VM_K, Kv, Item.VM_K_B);
         Multiply (Normed, Patches, Item.VM_V, V, Item.VM_V_B);
      end if;
      if E.Is_Ok (Status) then
         for I in 0 .. Side1 - 1 loop
            for J in 0 .. Side1 - 1 loop
               declare
                  T4 : constant array (0 .. 3) of Element_Count :=
                    [Corner (Side, I, J, 0), Corner (Side, I, J, 1),
                     Corner (Side, I, J, 2), Corner (Side, I, J, 3)];
               begin
                  for H in 0 .. Heads - 1 loop
                     for A in 0 .. 3 loop
                        declare
                           Row : N.Real_Array (0 .. 3);
                           Ok  : Boolean;
                           Qa  : constant Element_Count :=
                             T4 (A) * Width + H * Head;
                        begin
                           for Bx in 0 .. 3 loop
                              declare
                                 Kb : constant Element_Count :=
                                   T4 (Bx) * Width + H * Head;
                                 Acc : N.Wide_Real := 0.0;
                              begin
                                 for D in 0 .. Head - 1 loop
                                    Acc := Acc + N.Wide_Real (Q (Qa + D))
                                      * N.Wide_Real (Kv (Kb + D));
                                 end loop;
                                 Row (Element_Count (Bx)) :=
                                   Real (Acc) * Scale;
                              end;
                           end loop;
                           K.Softmax (Row, Ok);
                           for D in 0 .. Head - 1 loop
                              declare
                                 Acc : N.Wide_Real := 0.0;
                              begin
                                 for Bx in 0 .. 3 loop
                                    Acc := Acc
                                      + N.Wide_Real (Row (Element_Count (Bx)))
                                      * N.Wide_Real
                                          (V (T4 (Bx) * Width + H * Head + D));
                                 end loop;
                                 Attended (Qa + D) := Real (Acc);
                              end;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end;
            end loop;
         end loop;
         Multiply (Attended, Patches, Item.VM_O, Normed, Item.VM_O_B);
         if E.Is_Ok (Status) then
            K.Add (X.all, Normed.all);
         end if;
      end if;

      --  The windowed merger's downsample: each two-by-two block averaged for
      --  the residual and joined for the MLP -- normalized, widened through
      --  the Gaussian unit, narrowed, and added to the average.
      if E.Is_Ok (Status) then
         for I in 0 .. Side1 - 1 loop
            for J in 0 .. Side1 - 1 loop
               declare
                  O : constant Element_Count := I * Side1 + J;
               begin
                  for D in 0 .. Width - 1 loop
                     Mean1 (O * Width + D) := 0.0;
                  end loop;
                  for N4 in 0 .. 3 loop
                     declare
                        Src : constant Element_Count :=
                          Corner (Side, I, J, Element_Count (N4)) * Width;
                        Into : constant Element_Count :=
                          O * Merged + Element_Count (N4) * Width;
                     begin
                        Joined (Into .. Into + Width - 1) :=
                          X (Src .. Src + Width - 1);
                        for D in 0 .. Width - 1 loop
                           Mean1 (O * Width + D) :=
                             Mean1 (O * Width + D) + X (Src + D) * 0.25;
                        end loop;
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         Rows_Through (Normalize, Merged_Normed, Tokens1, Merged,
                       Source => Joined,
                       Bias => Item.VM_Ds_Ln_B, Weight => Item.VM_Ds_Ln_W);
         Multiply (Merged_Normed, Tokens1, Item.VM_Ds_Up, Wide1,
                   Item.VM_Ds_Up_B);
         Rows_Through (Gaussian, Wide1, Tokens1, VFeed);
         Multiply (Wide1, Tokens1, Item.VM_Ds_Down, X2, Item.VM_Ds_Down_B);
         if E.Is_Ok (Status) then
            K.Add (X2.all, Mean1.all);
         end if;
      end if;

      --  The blocks after the insertion point, over the merged tokens.
      for Index in Insert + 1 .. Item.Blocks - 1 loop
         exit when E.Is_Error (Status);
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Status := E.Make (E.Generation_Cancelled); exit;
         end if;
         Run_Block (Index, Tokens1, X2);
      end loop;

      --  The post norm leaves the merged tokens in X2.
      if E.Is_Ok (Status) then
         Rows_Through (Normalize, Normed, Tokens1, Width, Source => X2,
                       Bias => Item.Post_Bias, Weight => Item.Post_Weight);
         X2 (0 .. Tokens1 * Width - 1) := Normed (0 .. Tokens1 * Width - 1);
      end if;

      --  The final two-by-two merge and the downsample-MLP head.
      if E.Is_Ok (Status) then
         for I in 0 .. Side2 - 1 loop
            for J in 0 .. Side2 - 1 loop
               declare
                  O : constant Element_Count := I * Side2 + J;
               begin
                  for N4 in 0 .. 3 loop
                     declare
                        Src : constant Element_Count :=
                          Corner (Side1, I, J, Element_Count (N4)) * Width;
                        Into : constant Element_Count :=
                          O * Merged + Element_Count (N4) * Width;
                     begin
                        Joined2 (Into .. Into + Width - 1) :=
                          X2 (Src .. Src + Width - 1);
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         Rows_Through (Normalize, Merged_Normed, Tokens2, Merged,
                       Source => Joined2,
                       Bias => Item.Merge_Norm_B, Weight => Item.Merge_Norm_W);
         Multiply (Merged_Normed, Tokens2, Item.Merge_Up, Wide2,
                   Item.Merge_Up_B);
         Rows_Through (Gaussian_Exact, Wide2, Tokens2, Merged);
         Multiply (Wide2, Tokens2, Item.Merge_Down, Rows, Item.Merge_Down_B);
      end if;

      if E.Is_Error (Status) then
         Release; T.Free (Rows);
         return;
      end if;
      Release;
   end Encode_Minicpm46;

   -----------------
   -- Encode_Qwen --
   -----------------

   --  The shape a picture is resized to for the Qwen encoder: the
   --  reference's smart_resize. Each side is rounded to the nearest
   --  multiple of the window in pixels, then the pair is scaled down to
   --  hold within the most rows allowed or up to reach the least, by the
   --  square root of the ratio, and rounded down or up to the multiple
   --  again. Never below one window a side.
   --  Rounding to the nearest whole number with a half going to the even
   --  one, which is what the reference's round does and what a side of
   --  sixteen past a multiple of the window turns on: eighty pixels are
   --  two windows and a half, and the reference makes them two.
   function Half_Even (X : N.Wide_Real) return Natural is
      Floor : constant N.Wide_Real := N.Wide_Real'Floor (X);
      Rest  : constant N.Wide_Real := X - Floor;
   begin
      if Rest > 0.5 or else (Rest = 0.5 and then Natural (Floor) mod 2 = 1)
      then
         return Natural (Floor) + 1;
      else
         return Natural (Floor);
      end if;
   end Half_Even;

   procedure Fitted
     (Item   : Encoder;
      Width, Height : Positive;
      Fit_Width, Fit_Height : out Positive)
   is
      Factor : constant Positive := Item.Patch * Item.Merge;
      Least  : constant Long_Long_Integer :=
        Long_Long_Integer (Item.Least_Rows) * Long_Long_Integer (Factor) ** 2;
      Most   : constant Long_Long_Integer :=
        Long_Long_Integer (Item.Most_Rows) * Long_Long_Integer (Factor) ** 2;

      function Rounded (X : N.Wide_Real) return Positive
      is (Positive'Max (Factor,
            Positive (Half_Even (X / N.Wide_Real (Factor))) * Factor));
      function Floored (X : N.Wide_Real) return Positive
      is (Positive'Max (Factor,
            Positive (N.Wide_Real'Floor (X / N.Wide_Real (Factor)))
            * Factor));
      function Ceiled (X : N.Wide_Real) return Positive
      is (Positive'Max (Factor,
            Positive (N.Wide_Real'Ceiling (X / N.Wide_Real (Factor)))
            * Factor));

      W : Positive := Rounded (N.Wide_Real (Width));
      H : Positive := Rounded (N.Wide_Real (Height));
   begin
      if Long_Long_Integer (W) * Long_Long_Integer (H) > Most then
         declare
            Beta : constant N.Wide_Real :=
              Elementary.Sqrt
                (N.Wide_Real (Long_Long_Integer (Width) * Long_Long_Integer (Height))
                 / N.Wide_Real (Most));
         begin
            W := Floored (N.Wide_Real (Width) / Beta);
            H := Floored (N.Wide_Real (Height) / Beta);
         end;
      elsif Long_Long_Integer (W) * Long_Long_Integer (H) < Least then
         declare
            Beta : constant N.Wide_Real :=
              Elementary.Sqrt
                (N.Wide_Real (Least)
                 / N.Wide_Real (Long_Long_Integer (Width) * Long_Long_Integer (Height)));
         begin
            W := Ceiled (N.Wide_Real (Width) * Beta);
            H := Ceiled (N.Wide_Real (Height) * Beta);
         end;
      end if;
      Fit_Width := W;
      Fit_Height := H;
   end Fitted;

   --  The Qwen encoder over one picture, or over one pair of frames of a
   --  video: Picture is the still, or the pair's first frame, and Second
   --  the pair's second where Paired. A still is patched from the one
   --  frame through the summed patch weights; a pair from both frames'
   --  pixels, the first's then the second's, through the two weights
   --  side by side. Everything past the patch embedding is the same.
   procedure Encode_Qwen
     (Item    : in out Encoder;
      Picture : Model_Runner.Images.Raster;
      Team    : CPU.Pool_Reference;
      Rows    : out T.Real_Array_Access;
      Grid_Rows    : out Natural;
      Grid_Columns : out Natural;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out E.Error_Info;
      Paired  : Boolean := False;
      Second  : Model_Runner.Images.Raster := (others => <>);
      Pair_Width, Pair_Height : Natural := 0)
   is
      Width    : constant Element_Count := Element_Count (Item.Width);
      Feed     : constant Element_Count := Element_Count (Item.Feed);
      Heads    : constant Element_Count := Element_Count (Item.Heads);
      Head     : constant Element_Count := Width / Heads;
      Merge    : constant Element_Count := Element_Count (Item.Merge);
      Patch    : constant Element_Count := Element_Count (Item.Patch);
      Patch_Elements : constant Element_Count := 3 * Patch ** 2;

      --  What a patch is to the embedding: one frame's pixels, or two.
      Patch_In : constant Element_Count :=
        (if Paired then 2 * Patch_Elements else Patch_Elements);
      Joined   : constant Element_Count := Width * Merge ** 2;
      Text_Width : constant Element_Count := Element_Count (Item.Text_Width);
      Grid     : constant Element_Count := Element_Count (Item.Grid);

      Fit_Width, Fit_Height : Positive;
      Side_X, Side_Y, Patches, Windows_X, Windows_Y, Windows : Element_Count;

      --  The activations: every buffer is Patches rows of something,
      --  Fused three widths a patch.
      X, Normed, Fused, Attended, Hidden : T.Real_Array_Access := null;
      K_Head, Q_Head, V_Head_T, Scores, Blended : T.Real_Array_Access := null;
      Merged : T.Real_Array_Access := null;

      --  Where each patch stands, in the walk's order: its row and column.
      type Patch_Place is record
         Row, Column : Element_Count := 0;
      end record;
      type Patch_Place_Array is array (Element_Count range <>) of Patch_Place;
      type Patch_Place_Access is access Patch_Place_Array;
      procedure Free is new Ada.Unchecked_Deallocation
        (Patch_Place_Array, Patch_Place_Access);
      Places : Patch_Place_Access := null;

      Resampled, Resampled_2 : Model_Runner.Images.Raster;
      Work : Workspace;

      procedure Release is
      begin
         T.Free (X);
         T.Free (Normed);
         T.Free (Fused);
         T.Free (Attended);
         T.Free (Hidden);
         T.Free (K_Head);
         T.Free (Q_Head);
         T.Free (V_Head_T);
         T.Free (Scores);
         T.Free (Blended);
         T.Free (Merged);
         Free (Places);
         Clear (Work);
         Model_Runner.Images.Free (Resampled);
         Model_Runner.Images.Free (Resampled_2);
      end Release;

      --  The two-part rotation of the queries and keys in Fused, in
      --  place: pair p of a head turns by the patch's row for the first
      --  half of the pairs and by its column for the second, each half
      --  counting its frequencies from the first, and a pair is an
      --  element against the one half a head away.
      procedure Turn is
         Pairs : constant Element_Count := Head / 2;
         Half  : constant Element_Count := Pairs / 2;
         Base  : constant N.Wide_Real := 10_000.0;
         Cosines, Sines : N.Wide_Real_Array (0 .. Pairs - 1);
      begin
         for P in 0 .. Patches - 1 loop
            for Pair in 0 .. Pairs - 1 loop
               declare
                  Position : constant Element_Count :=
                    (if Pair < Half then Places (P).Row else Places (P).Column);
                  Index : constant Element_Count :=
                    (if Pair < Half then Pair else Pair - Half);
                  Theta : constant N.Wide_Real :=
                    N.Wide_Real (Position)
                    * N.Power (Base, -2.0 * N.Wide_Real (Index) / N.Wide_Real (Pairs));
               begin
                  Cosines (Pair) := N.Cos (Theta);
                  Sines (Pair) := N.Sin (Theta);
               end;
            end loop;
            for Which in 0 .. 1 loop
               for H in 0 .. Heads - 1 loop
                  declare
                     Start : constant Element_Count :=
                       P * 3 * Width + Element_Count (Which) * Width + H * Head;
                  begin
                     for Pair in 0 .. Pairs - 1 loop
                        declare
                           A : constant Real := Fused (Start + Pair);
                           C : constant Real := Fused (Start + Pair + Pairs);
                        begin
                           Fused (Start + Pair) :=
                             Real (N.Wide_Real (A) * Cosines (Pair)
                                   - N.Wide_Real (C) * Sines (Pair));
                           Fused (Start + Pair + Pairs) :=
                             Real (N.Wide_Real (A) * Sines (Pair)
                                   + N.Wide_Real (C) * Cosines (Pair));
                        end;
                     end loop;
                  end;
               end loop;
            end loop;
         end loop;
      end Turn;

      --  The position grid, interpolated to the picture's patches with
      --  the corners aligned, one row into Normed's for the patch at P.
      procedure Position_Row (P : Element_Count) is
         Row    : constant Element_Count := Places (P).Row;
         Column : constant Element_Count := Places (P).Column;
         SY : constant N.Wide_Real :=
           (if Side_Y > 1
            then N.Wide_Real (Row) * N.Wide_Real (Grid - 1) / N.Wide_Real (Side_Y - 1)
            else 0.0);
         SX : constant N.Wide_Real :=
           (if Side_X > 1
            then N.Wide_Real (Column) * N.Wide_Real (Grid - 1) / N.Wide_Real (Side_X - 1)
            else 0.0);
         Y0 : constant Element_Count := Element_Count (N.Wide_Real'Floor (SY));
         X0 : constant Element_Count := Element_Count (N.Wide_Real'Floor (SX));
         Y1 : constant Element_Count := Element_Count'Min (Grid - 1, Y0 + 1);
         X1 : constant Element_Count := Element_Count'Min (Grid - 1, X0 + 1);
         FY : constant Real := Real (SY - N.Wide_Real (Y0));
         FX : constant Real := Real (SX - N.Wide_Real (X0));
         Target : constant Element_Count := P * Width;

         procedure Blend (Cell : Element_Count; Share : Real) is
         begin
            if Share = 0.0 or else E.Is_Error (Status) then
               return;
            end if;
            T.Dequantize_Row (Item.Positions, Cell, Hidden (0 .. Width - 1), Status);
            for D in 0 .. Width - 1 loop
               Normed (Target + D) := Normed (Target + D) + Share * Hidden (D);
            end loop;
         end Blend;
      begin
         Normed (Target .. Target + Width - 1) := [others => 0.0];
         Blend (Y0 * Grid + X0, (1.0 - FY) * (1.0 - FX));
         Blend (Y0 * Grid + X1, (1.0 - FY) * FX);
         Blend (Y1 * Grid + X0, FY * (1.0 - FX));
         Blend (Y1 * Grid + X1, FY * FX);
      end Position_Row;
   begin
      Rows := null;
      Grid_Rows := 0;
      Grid_Columns := 0;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      if Picture.Pixels = null or else (Paired and then Second.Pixels = null)
      then
         Status := E.Make (E.Generation_Empty_Prompt);
         return;
      end if;

      --  A still is fitted here; a pair of frames was fitted with its
      --  video, every frame the same.
      if Paired then
         Fit_Width := Pair_Width;
         Fit_Height := Pair_Height;
      else
         Fitted (Item, Picture.Width, Picture.Height, Fit_Width, Fit_Height);
      end if;
      Side_X := Element_Count (Fit_Width) / Patch;
      Side_Y := Element_Count (Fit_Height) / Patch;
      Patches := Side_X * Side_Y;
      Windows_X := Side_X / Merge;
      Windows_Y := Side_Y / Merge;
      Windows := Windows_X * Windows_Y;

      Work.Team := Team;
      Work.Cancel := Cancel;
      Work.Epsilon := Item.Epsilon;

      T.Allocate (Patches * Width, X);
      T.Allocate (Patches * Width, Normed);
      T.Allocate (Patches * 3 * Width, Fused);
      T.Allocate (Patches * Width, Attended);
      T.Allocate (Patches * Element_Count'Max (Feed, Patch_In), Hidden);
      T.Allocate (Patches * Head, K_Head);
      T.Allocate (Patches * Head, Q_Head);
      T.Allocate (Patches * Head, V_Head_T);
      T.Allocate (Patches * Patches, Scores);
      T.Allocate (Patches * Head, Blended);
      T.Allocate (Windows * Joined, Merged);
      Furnish
        (Work,
         Element_Count'Max (Joined * Joined,
                            Element_Count'Max (Feed * Width,
                                               Width * Patch_In)),
         Element_Count'Max (Joined, Element_Count'Max (Feed, Patch_In)),
         Element_Count'Max (Joined, Element_Count'Max (3 * Width, Feed)));
      Places := new Patch_Place_Array (0 .. Patches - 1);

      if X = null or else Normed = null or else Fused = null
        or else Attended = null or else Hidden = null or else K_Head = null
        or else Q_Head = null or else V_Head_T = null or else Scores = null
        or else Blended = null or else Merged = null
        or else E.Is_Error (Work.Status)
      then
         Status :=
           (if E.Is_Error (Work.Status) then Work.Status
            else E.Make (E.Memory_Allocation_Failed));
         if not E.Is_Error (Work.Status) then
            E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         end if;
         Release;
         return;
      end if;

      --  The patches, walked window by window so that a window's four
      --  lie together, each a vector of channel, row and column within
      --  the patch, scaled as the encoder was trained on.
      Model_Runner.Images.Resample
        (Picture, Fit_Width, Fit_Height, Resampled, Model_Runner.Images.Cubic);
      if Paired and then Resampled.Pixels /= null then
         Model_Runner.Images.Resample
           (Second, Fit_Width, Fit_Height, Resampled_2,
            Model_Runner.Images.Cubic);
      end if;
      if Resampled.Pixels = null
        or else (Paired and then Resampled_2.Pixels = null)
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "vision", E.Param_Identifier);
         return;
      end if;

      declare
         P : Element_Count := 0;
         Row_Bytes : constant B.Byte_Count := B.Byte_Count (Fit_Width);

         --  One frame's pixels of the patch at (PY, PX) into Hidden from
         --  Into, a channel at a time, scaled as the encoder was trained on.
         procedure Cut
           (From   : Model_Runner.Images.Raster;
            PY, PX : Element_Count;
            Into   : Element_Count) is
         begin
            for C in Element_Count range 0 .. 2 loop
               for KY in 0 .. Patch - 1 loop
                  for KX in 0 .. Patch - 1 loop
                     declare
                        Y : constant B.Byte_Count :=
                          B.Byte_Count (PY * Patch + KY);
                        Xp : constant B.Byte_Count :=
                          B.Byte_Count (PX * Patch + KX);
                        Value : constant Real :=
                          Real (From.Pixels
                                  (3 * (Y * Row_Bytes + Xp)
                                   + B.Byte_Count (C)))
                          / 255.0;
                     begin
                        Hidden (Into + C * Patch * Patch + KY * Patch + KX) :=
                          (Value - Item.Mean (Positive (C + 1)))
                          / Item.Deviation (Positive (C + 1));
                     end;
                  end loop;
               end loop;
            end loop;
         end Cut;
      begin
         for WY in 0 .. Windows_Y - 1 loop
            for WX in 0 .. Windows_X - 1 loop
               for DY in 0 .. Merge - 1 loop
                  for DX in 0 .. Merge - 1 loop
                     declare
                        PY : constant Element_Count := WY * Merge + DY;
                        PX : constant Element_Count := WX * Merge + DX;
                        At_Patch : constant Element_Count := P * Patch_In;
                     begin
                        Places (P) := (Row => PY, Column => PX);
                        Cut (Resampled, PY, PX, At_Patch);
                        if Paired then
                           Cut (Resampled_2, PY, PX, At_Patch + Patch_Elements);
                        end if;
                        P := P + 1;
                     end;
                  end loop;
               end loop;
            end loop;
         end loop;
      end;
      Model_Runner.Images.Free (Resampled);
      Model_Runner.Images.Free (Resampled_2);

      --  Patch embedding -- both temporal frames' weights, summed once,
      --  over the one frame of a still; the two side by side over the
      --  two frames of a pair -- then where each patch is, from the grid
      --  interpolated to the picture's patches.
      Multiply (Work, Hidden, Patches,
                (if Paired then Item.Patch_Pair else Item.Patch_Both),
                X, Item.Patch_Bias);
      Status := Work.Status;
      if E.Is_Ok (Status) then
         for P in 0 .. Patches - 1 loop
            Position_Row (P);
            exit when E.Is_Error (Status);
         end loop;
         if E.Is_Ok (Status) then
            K.Add (X.all, Normed.all);
         end if;
      end if;
      Work.Status := Status;

      --  The blocks: a norm, the fused projection, the rotation, the
      --  attention over every patch, the output and the feed-forward,
      --  each added to the stream.
      for Index in 0 .. Item.Blocks - 1 loop
         exit when E.Is_Error (Work.Status);
         if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
            Work.Status := E.Make (E.Generation_Cancelled);
            exit;
         end if;

         declare
            Current : Block renames Item.Layers (Index);
         begin
            Rows_Through (Work, Normalize, Normed, Patches, Width, Source => X,
                          Bias => Current.Norm_1_Bias,
                          Weight => Current.Norm_1_Weight);
            Multiply (Work, Normed, Patches, Current.Fused, Fused,
                      Current.Fused_Bias);
            exit when E.Is_Error (Work.Status);
            Turn;
            Attend (Work, Fused, Fused, Fused, 0, Width, 2 * Width, 3 * Width,
                    Attended, Width, Patches, Heads, Head,
                    K_Head, Q_Head, V_Head_T, Scores, Blended);
            Multiply (Work, Attended, Patches, Current.Output, Normed,
                      Current.Output_Bias);
            exit when E.Is_Error (Work.Status);
            K.Add (X.all, Normed.all);

            Rows_Through (Work, Normalize, Normed, Patches, Width, Source => X,
                          Bias => Current.Norm_2_Bias,
                          Weight => Current.Norm_2_Weight);
            Multiply (Work, Normed, Patches, Current.Feed_In, Hidden,
                      Current.Feed_In_Bias);
            Rows_Through (Work, Gaussian, Hidden, Patches, Feed);
            Multiply (Work, Hidden, Patches, Current.Feed_Out, Normed,
                      Current.Feed_Out_Bias);
            exit when E.Is_Error (Work.Status);
            K.Add (X.all, Normed.all);
         end;
      end loop;

      --  The last norm, then the merger: a window's patches, which the
      --  walk laid together, joined into one row of Joined, through the
      --  square step and the Gaussian unit, then to the text width.
      if E.Is_Ok (Work.Status) then
         Rows_Through (Work, Normalize, Normed, Patches, Width, Source => X,
                       Bias => Item.Post_Bias, Weight => Item.Post_Weight);
      end if;

      if E.Is_Ok (Work.Status) then
         T.Allocate (Windows * Text_Width, Rows);
         if Rows = null then
            Work.Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text (Work.Status, "category", "vision", E.Param_Identifier);
         else
            --  Normed's rows are already the joined rows: Merge ** 2
            --  consecutive patches of Width make one row of Joined. The
            --  unit between the merger's steps is the exact one, which is
            --  what the reference's merger applies where its blocks apply
            --  the approximation.
            Multiply (Work, Normed, Windows, Item.Merge_In, Merged,
                      Item.Merge_In_Bias);
            Rows_Through (Work, Gaussian_Exact, Merged, Windows, Joined);
            Multiply (Work, Merged, Windows, Item.Merge_Out, Rows,
                      Item.Merge_Out_Bias);
         end if;
      end if;

      Status := Work.Status;
      Grid_Rows := Natural (Windows_Y);
      Grid_Columns := Natural (Windows_X);
      Release;

      if E.Is_Error (Status) then
         T.Free (Rows);
         Grid_Rows := 0;
         Grid_Columns := 0;
      end if;
   end Encode_Qwen;

   -----------------
   -- Reads_Video --
   -----------------

   function Reads_Video (Item : Encoder) return Boolean
   is (Item.Ready and then (Is_Qwen (Item) or else Is_Minicpm (Item)
                            or else Is_Minicpm46 (Item)));

   ----------------
   -- Frames_Fit --
   ----------------

   procedure Frames_Fit
     (Item   : Encoder;
      Width, Height : Positive;
      Frames : Positive;
      Fit_Width, Fit_Height : out Positive;
      Status : out E.Error_Info)
   is
      Factor : constant Positive := Item.Patch * Item.Merge;

      --  The pixel budget over the video: the most a frame may have --
      --  the token ceiling's worth, or the whole budget's even share a
      --  frame where that is less, and never under the least a video
      --  plus a twentieth -- times the frames.
      Least_Pixels : constant Long_Long_Integer := Video_Least_Pixels;
      Frame_Cap : constant Long_Long_Integer :=
        Long_Long_Integer (Video_Frame_Rows) * Long_Long_Integer (Factor) ** 2;
      Per_Frame : constant Long_Long_Integer :=
        Long_Long_Integer'Max
          (Long_Long_Integer'Min
             (Frame_Cap, Video_Most_Pixels / Long_Long_Integer (Frames)),
           Long_Long_Integer
             (N.Wide_Real'Floor (N.Wide_Real (Least_Pixels) * 1.05)));
      Most  : constant Long_Long_Integer :=
        Per_Frame * Long_Long_Integer (Frames);
      Least : constant Long_Long_Integer := Video_Least_Pixels;

      --  The frames' sides, a side under the window scaled up to it
      --  first, both by the same factor and cut to whole pixels.
      H : N.Wide_Real := N.Wide_Real (Height);
      W : N.Wide_Real := N.Wide_Real (Width);

      function Rounded (X : N.Wide_Real) return Positive
      is (Positive'Max (Factor,
            Positive (Half_Even (X / N.Wide_Real (Factor))) * Factor));
      function Floored (X : N.Wide_Real) return Positive
      is (Positive'Max (Factor,
            Positive (N.Wide_Real'Floor (X / N.Wide_Real (Factor))) * Factor));
      function Ceiled (X : N.Wide_Real) return Positive
      is (Positive'Max (Factor,
            Positive (N.Wide_Real'Ceiling (X / N.Wide_Real (Factor))) * Factor));

      --  The frames' count rounded to whole pairs, which is what the
      --  budget is checked against; the scaling is by the count itself.
      Pairs_Worth : constant Long_Long_Integer :=
        Long_Long_Integer (Half_Even (N.Wide_Real (Frames) / 2.0)) * 2;

      H_Bar, W_Bar : Positive;
   begin
      Fit_Width := Factor;
      Fit_Height := Factor;
      Status := E.Success;

      if not Reads_Video (Item) then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "video", E.Param_Identifier);
         return;
      end if;

      --  MiniCPM-V has no video processor of its own: a frame is a picture,
      --  fit to the encoder's side as any picture is (the overview), and
      --  the frames of a video are all one size, so one fit serves them all.
      if Is_Minicpm (Item) then
         declare
            OW, OH : Positive;
            RW, RH, GC, GR, Cnt : Natural;
            Sl : Slice_List;
         begin
            Plan_Slices (Item, Width, Height, OW, OH, RW, RH, GC, GR, Sl, Cnt);
            Fit_Width := OW;
            Fit_Height := OH;
         end;
         return;
      end if;

      if Height < Factor or else Width < Factor then
         declare
            Scale : constant N.Wide_Real :=
              N.Wide_Real'Max (N.Wide_Real (Factor) / H,
                               N.Wide_Real (Factor) / W);
         begin
            H := N.Wide_Real'Floor (H * Scale);
            W := N.Wide_Real'Floor (W * Scale);
         end;
      end if;

      if N.Wide_Real'Max (H, W) / N.Wide_Real'Min (H, W) > 200.0 then
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "video aspect", E.Param_Identifier);
         return;
      end if;

      H_Bar := Rounded (H);
      W_Bar := Rounded (W);

      if Pairs_Worth * Long_Long_Integer (H_Bar) * Long_Long_Integer (W_Bar)
           > Most
      then
         declare
            Beta : constant N.Wide_Real :=
              Elementary.Sqrt
                (N.Wide_Real (Frames) * H * W / N.Wide_Real (Most));
         begin
            H_Bar := Floored (H / Beta);
            W_Bar := Floored (W / Beta);
         end;
      elsif Pairs_Worth * Long_Long_Integer (H_Bar) * Long_Long_Integer (W_Bar)
              < Least
      then
         declare
            Beta : constant N.Wide_Real :=
              Elementary.Sqrt
                (N.Wide_Real (Least) / (N.Wide_Real (Frames) * H * W));
         begin
            H_Bar := Ceiled (H * Beta);
            W_Bar := Ceiled (W * Beta);
         end;
      end if;

      Fit_Width := W_Bar;
      Fit_Height := H_Bar;
   end Frames_Fit;

   -------------------
   -- Encode_Frames --
   -------------------

   procedure Encode_Frames
     (Item    : in out Encoder;
      First, Second : Model_Runner.Images.Raster;
      Fit_Width, Fit_Height : Positive;
      Team    : CPU.Pool_Reference;
      Rows    : out T.Real_Array_Access;
      Grid_Rows    : out Natural;
      Grid_Columns : out Natural;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out E.Error_Info) is
   begin
      if not Reads_Video (Item) then
         Rows := null;
         Grid_Rows := 0;
         Grid_Columns := 0;
         Status := E.Make (E.Arch_Unsupported_Feature);
         E.Add_Text (Status, "feature", "video", E.Param_Identifier);
         return;
      end if;

      Encode_Qwen
        (Item, First, Team, Rows, Grid_Rows, Grid_Columns, Cancel, Status,
         Paired => True, Second => Second,
         Pair_Width => Fit_Width, Pair_Height => Fit_Height);
   end Encode_Frames;

   ------------
   -- Encode --
   ------------

   procedure Encode
     (Item    : in out Encoder;
      Picture : Model_Runner.Images.Raster;
      Team    : CPU.Pool_Reference;
      Rows    : out T.Real_Array_Access;
      Grid_Rows    : out Natural;
      Grid_Columns : out Natural;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null;
      Status  : out E.Error_Info) is
   begin
      if Is_Qwen (Item) then
         Encode_Qwen
           (Item, Picture, Team, Rows, Grid_Rows, Grid_Columns, Cancel, Status);
      elsif Is_Minicpm (Item) then
         Encode_Minicpm (Item, Picture, Team, Rows, Cancel, Status);
         Grid_Rows := (if Rows = null then 0 else Item.Num_Query);
         Grid_Columns := (if Rows = null then 0 else 1);
      elsif Is_Minicpm46 (Item) then
         Encode_Minicpm46 (Item, Picture, Team, Rows, Cancel, Status);
         declare
            Side : constant Natural :=
              (if Item.Ready
               then (Item.Size / Item.Patch) / Item.Merge_Scale
                      / Item.Merge_Scale
               else 0);
         begin
            Grid_Rows := (if Rows = null then 0 else Side);
            Grid_Columns := (if Rows = null then 0 else Side);
         end;
      else
         Encode_Gemma (Item, Picture, Team, Rows, Cancel, Status);
         declare
            Side : constant Natural :=
              (if Item.Ready then (Item.Size / Item.Patch) / Item.Pool_Side
               else 0);
         begin
            Grid_Rows := (if Rows = null then 0 else Side);
            Grid_Columns := Grid_Rows;
         end;
      end if;
   end Encode;

end Model_Runner.Vision;
