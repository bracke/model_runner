with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Deallocation;
with Interfaces;
with System.Storage_Elements;

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

   --  The one projector this build carries.
   Gemma_3 : constant String := "gemma3";

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
         if Kind /= Gemma_3 then
            Status := E.Make (E.Arch_Unsupported_Projector);
            E.Add_Text
              (Status, "format", (if Kind = "" then "none" else Kind),
               E.Param_Identifier);
            E.Add_Text (Status, "supported", Gemma_3, E.Param_Identifier);
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

      Containers.Get_Integer
        (Item.Container, "clip.vision.projection_dim", 1, 65536, Number,
         Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Text_Width := Positive (Number);

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

      if Item.Size mod Item.Patch /= 0
        or else Item.Width mod Item.Heads /= 0
        or else (Item.Size / Item.Patch) mod Item.Pool_Side /= 0
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
      Item.Patch_Weights := T.Empty_View;
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

   function Rows_Per_Picture (Item : Encoder) return Positive
   is (((Item.Size / Item.Patch) / Item.Pool_Side) ** 2);

   function Row_Width (Item : Encoder) return Positive is (Item.Text_Width);

   function Projector (Item : Encoder) return String
   is (Item.Kind (1 .. Item.Kind_Last));

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
   type Row_Task is (Add_Bias, Gaussian, Soft_Max, Normalize);

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

   procedure Encode
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

      --  A matrix decoded to binary32, a head's keys, queries and values
      --  gathered contiguous, and a head's scores.
      Decoded : T.Real_Array_Access := null;
      K_Head, Q_Head, V_Head_T, Scores : T.Real_Array_Access := null;

      Resampled : Model_Runner.Images.Raster;

      Product : aliased Product_Work;
      Over_Rows : aliased Row_Work;
      Heads_Work : aliased Attention_Work;
      Blended : T.Real_Array_Access := null;

      procedure Release is
      begin
         T.Free (X);
         T.Free (Normed);
         T.Free (Q);
         T.Free (Kv);
         T.Free (V);
         T.Free (Attended);
         T.Free (Hidden);
         T.Free (Decoded);
         T.Free (K_Head);
         T.Free (Q_Head);
         T.Free (V_Head_T);
         T.Free (Scores);
         T.Free (Blended);
         Model_Runner.Images.Free (Resampled);
      end Release;

      --  Every row of Target through one of the row tasks.
      procedure Rows_Through
        (What : Row_Task;
         Target : T.Real_Array_Access;
         Total  : Element_Count;
         Row_Width : Element_Count;
         Source : T.Real_Array_Access := null;
         Bias   : T.Real_Array_Access := null;
         Weight : T.Real_Array_Access := null) is
      begin
         if E.Is_Error (Status) then
            return;
         end if;
         Over_Rows.Task_Kind := What;
         Over_Rows.Source := Source;
         Over_Rows.Target := Target;
         Over_Rows.Width := Row_Width;
         Over_Rows.Bias := Bias;
         Over_Rows.Weight := Weight;
         Over_Rows.Epsilon := Item.Epsilon;
         Over_Rows.Failed := False;
         CPU.Dispatch_Shares
           (Team, Total, Over_Rows'Unchecked_Access, Status,
            Cost => Total * Row_Width);
         if E.Is_Ok (Status) and then Over_Rows.Failed then
            Status := E.Make (E.Sampling_Non_Finite_Logit);
         end if;
      end Rows_Through;

      --  Target := Source * W, W held as Wanted rows of Row_Width in
      --  binary32, with Bias added where one is given.
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
         if E.Is_Error (Status) then
            return;
         end if;
         Product.A := Source;
         Product.A_At := Source_At;
         Product.Rows := Total;
         Product.W := W;
         Product.Wanted := Wanted;
         Product.Width := Row_Width;
         Product.C := Target;
         CPU.Dispatch_Shares
           (Team, (Wanted + Wide.Tile - 1) / Wide.Tile,
            Product'Unchecked_Access, Status,
            Cost => Total * Wanted * Row_Width);
         if Bias /= null then
            Rows_Through (Add_Bias, Target, Total, Wanted, Bias => Bias);
         end if;
      end Multiply;

      --  Target := Source * Weight, the weight decoded from the file's
      --  format to binary32 first.
      procedure Multiply
        (Source : T.Real_Array_Access;
         Total  : Element_Count;
         Weight : T.View;
         Target : T.Real_Array_Access;
         Bias   : T.Real_Array_Access := null) is
      begin
         if E.Is_Error (Status) then
            return;
         end if;
         for Row in 0 .. Weight.Rows - 1 loop
            T.Dequantize_Row
              (Weight, Row,
               Decoded (Row * Weight.Columns .. (Row + 1) * Weight.Columns - 1),
               Status);
            exit when E.Is_Error (Status);
         end loop;
         Multiply (Source, 0, Total, Decoded, Weight.Rows, Weight.Columns,
                   Target, Bias);
      end Multiply;

      --  One block's attention: every head over every position, both
      --  ways, which is what a picture is -- no position comes before
      --  another. The head's keys are gathered as a matrix of Patches
      --  rows so that the scores are a product, and its values
      --  transposed so that the blend is one too.
      procedure Attend is
         Scale : constant Real :=
           Real (N.Wide_Real'(1.0) / Elementary.Sqrt (N.Wide_Real (Head)));
      begin
         for H in 0 .. Heads - 1 loop
            exit when E.Is_Error (Status);
            for P in 0 .. Patches - 1 loop
               K_Head (P * Head .. (P + 1) * Head - 1) :=
                 Kv (P * Width + H * Head .. P * Width + (H + 1) * Head - 1);
               for D in 0 .. Head - 1 loop
                  Q_Head (P * Head + D) := Q (P * Width + H * Head + D) * Scale;
                  V_Head_T (D * Patches + P) := V (P * Width + H * Head + D);
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
              (Team, (Patches + Query_Block - 1) / Query_Block,
               Heads_Work'Unchecked_Access, Status,
               Cost => Patches * Patches * Head);
            if E.Is_Ok (Status) and then Heads_Work.Failed then
               Status := E.Make (E.Sampling_Non_Finite_Logit);
            end if;
            exit when E.Is_Error (Status);
            for P in 0 .. Patches - 1 loop
               Attended (P * Width + H * Head .. P * Width + (H + 1) * Head - 1)
                 := Blended (P * Head .. (P + 1) * Head - 1);
            end loop;
         end loop;
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
      T.Allocate (Element_Count'Max (Feed * Width,
                    Element_Count'Max (Patches * Width,
                                       Width * Patch_Elements)), Decoded);
      T.Allocate (Patches * Head, K_Head);
      T.Allocate (Patches * Head, Q_Head);
      T.Allocate (Patches * Head, V_Head_T);
      T.Allocate (Patches * Patches, Scores);
      T.Allocate (Patches * Head, Blended);

      if X = null or else Normed = null or else Q = null or else Kv = null
        or else V = null or else Attended = null or else Hidden = null
        or else Decoded = null
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
         else
            Multiply (Kv, 0, Pooled, Item.Projection_Rows, Text_Width, Width,
                      Rows);
         end if;
      end if;

      Release;

      if E.Is_Error (Status) then
         T.Free (Rows);
      end if;
   end Encode;

end Model_Runner.Vision;
