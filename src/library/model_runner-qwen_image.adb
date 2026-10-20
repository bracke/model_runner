with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Shares;

package body Model_Runner.Qwen_Image is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package Containers renames Model_Runner.GGUF.Containers;

   subtype Element_Count is N.Element_Count;

   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type Element_Count;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;
   use type T.Real_Array_Access;
   use type Model_Runner.GGUF.U64;

   procedure Free is new Ada.Unchecked_Deallocation (Block_Array, Block_Array_Access);

   --  The two ways the file is published: the checkpoint's own names
   --  under ComfyUI's prefix, or the same names with none.
   Prefixed : constant String := "model.diffusion_model.";

   Blocks_Named : constant String := "transformer_blocks.";

   --  The rotation's three axes -- frame, row, column -- and how many of a
   --  head's pairs each turns, in that order: a head of 128 is the model's,
   --  and no other is turned.
   Axis_Pairs : constant array (0 .. 2) of Natural := [8, 28, 28];
   Rotated_Head : constant := 2 * (8 + 28 + 28);

   --  A view over a named tensor of the given shape, in the file's own
   --  format, where it lies.
   procedure Bind
     (Item    : in out Denoiser;
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
            Model_Runner.GGUF.Type_Name (Containers.Tensor_Format (Item.Container, Index)),
            E.Param_Identifier);
         return;
      end if;

      --  A matrix is two axes, the columns first; a gain is one.
      declare
         Rank : constant Positive := Containers.Tensor_Rank (Item.Container, Index);
         Have_Columns : constant Element_Count :=
           Element_Count (Containers.Tensor_Dimension (Item.Container, Index, 1));
         Have_Rows : constant Element_Count :=
           (if Rank >= 2 then Element_Count (Containers.Tensor_Dimension (Item.Container, Index, 2)) else 1);
      begin
         if Rank > 2 or else Have_Columns /= Columns or else Have_Rows /= Rows then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "columns", Long_Long_Integer (Have_Columns));
            E.Add_Integer (Status, "rows", Long_Long_Integer (Have_Rows));
            E.Add_Integer (Status, "expected_columns", Long_Long_Integer (Columns));
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

   --  A gain of the given length, decoded once.
   procedure Bind_Vector
     (Item   : in out Denoiser;
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

   --  A dimension of a named tensor, or nought where it has none.
   function Dimension_Of (Item : Denoiser; Name : String; Axis : Positive) return Natural is
      Index : constant Natural := Containers.Find_Tensor (Item.Container, Name);
   begin
      if Index = 0 or else Containers.Tensor_Rank (Item.Container, Index) < Axis
        or else Containers.Tensor_Dimension (Item.Container, Index, Axis) > 1_048_576
      then
         return 0;
      end if;
      return Natural (Containers.Tensor_Dimension (Item.Container, Index, Axis));
   end Dimension_Of;

   procedure Open (Item : in out Denoiser; Path : String; Status : out E.Error_Info) is
      procedure Fail (Condition : E.Error_Info) is
      begin
         Status := Condition;
         Close (Item);
      end Fail;
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

      --  Known by its names. A file that says it is something is that
      --  something, whatever tensors it also holds.
      declare
         Said   : constant String := Containers.String_Value (Item.Container, "general.architecture");
         Prefix : constant String :=
           (if Containers.Find_Tensor (Item.Container, Prefixed & "img_in.weight") > 0 then Prefixed else "");

         function Named (Suffix : String) return String is (Prefix & Suffix);

         function Block_Named (Index : Natural; Suffix : String) return String
         is (Named (Blocks_Named & Index'Image (2 .. Index'Image'Last) & "." & Suffix));

         Shape : Configuration renames Item.Shape;
      begin
         if Said /= ""
           or else Containers.Find_Tensor (Item.Container, Named ("img_in.weight")) = 0
           or else Containers.Find_Tensor (Item.Container, Named ("modulation.1.weight")) = 0
         then
            Status := E.Make (E.Arch_Unsupported);
            E.Add_Text (Status, "architecture", (if Said = "" then "none" else Said), E.Param_Identifier);
            E.Add_Text (Status, "supported", "qwen-image-2.1", E.Param_Identifier);
            Fail (Status);
            return;
         end if;

         --  The configuration, off the shapes.
         Shape.In_Channels := Dimension_Of (Item, Named ("img_in.weight"), 1);
         Shape.Width := Dimension_Of (Item, Named ("img_in.weight"), 2);
         Shape.Context := Dimension_Of (Item, Named ("txt_in.in_layer.weight"), 1);
         Shape.Out_Channels := Dimension_Of (Item, Named ("proj_out.weight"), 2);
         Shape.Head_Size := Dimension_Of (Item, Block_Named (0, "attn.norm_q.weight"), 1);
         Shape.Feed := Dimension_Of (Item, Block_Named (0, "img_mlp.out.weight"), 1);

         --  The blocks, counted by the highest numbered, none missing
         --  below it.
         declare
            Lead  : constant String := Named (Blocks_Named);
            Count : Natural := 0;
         begin
            for Index in 1 .. Containers.Tensor_Count (Item.Container) loop
               declare
                  Name : constant String := Containers.Tensor_Name (Item.Container, Index);
                  Last : Natural;
               begin
                  if Name'Length > Lead'Length
                    and then Name (Name'First .. Name'First + Lead'Length - 1) = Lead
                  then
                     Last := Name'First + Lead'Length - 1;
                     while Last < Name'Last and then Name (Last + 1) in '0' .. '9' loop
                        Last := Last + 1;
                     end loop;
                     if Last >= Name'First + Lead'Length and then Last - (Name'First + Lead'Length) < 4 then
                        Count := Natural'Max
                          (Count, Natural'Value (Name (Name'First + Lead'Length .. Last)) + 1);
                     end if;
                  end if;
               end;
            end loop;
            if Count = 0 or else Count > Max_Blocks then
               Status := E.Make (E.Arch_Missing_Tensor);
               E.Add_Text (Status, "tensor", Block_Named (0, "attn.to_q.weight"), E.Param_Identifier);
               Fail (Status);
               return;
            end if;
            for Index in 0 .. Count - 1 loop
               if Containers.Find_Tensor (Item.Container, Block_Named (Index, "attn.to_q.weight")) = 0 then
                  Status := E.Make (E.Arch_Layer_Numbering_Gap);
                  E.Add_Integer (Status, "layer", Long_Long_Integer (Index));
                  Fail (Status);
                  return;
               end if;
            end loop;
            Shape.Blocks := Count;
         end;

         if Shape.Width = 0 or else Shape.Head_Size /= Rotated_Head or else Shape.Width mod Shape.Head_Size /= 0 then
            Status := E.Make (E.Arch_Invalid_Dimensions);
            E.Add_Integer (Status, "embedding", Long_Long_Integer (Shape.Width));
            E.Add_Integer (Status, "heads", Long_Long_Integer (Shape.Head_Size));
            Fail (Status);
            return;
         end if;
         Shape.Heads := Shape.Width / Shape.Head_Size;

         --  The tensor section: the file's own pages where it is mapped,
         --  read into an arena where it is not.
         declare
            Data_At : constant B.Byte_Count := B.Byte_Count (Containers.Data_Offset (Item.Container));
            Length  : constant B.Byte_Count := B.Byte_Count (Containers.Tensor_Data_Bytes (Item.Container));
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

         --  And every tensor, held to the shape the others imply.
         declare
            Width   : constant Element_Count := Element_Count (Shape.Width);
            Feed    : constant Element_Count := Element_Count (Shape.Feed);
            Head    : constant Element_Count := Element_Count (Shape.Head_Size);
            Context : constant Element_Count := Element_Count (Shape.Context);

            --  Each bound in turn, the first refusal kept.
            procedure Matrix (Name : String; Rows, Columns : Element_Count; Result : out T.View) is
            begin
               if E.Is_Ok (Status) then
                  Bind (Item, Name, Rows, Columns, Result, Status);
               else
                  Result := T.Empty_View;
               end if;
            end Matrix;

            procedure Gain (Name : String; Length : Element_Count; Result : out T.Real_Array_Access) is
            begin
               if E.Is_Ok (Status) then
                  Bind_Vector (Item, Name, Length, Result, Status);
               else
                  Result := null;
               end if;
            end Gain;
         begin
            Matrix (Named ("img_in.weight"), Width, Element_Count (Shape.In_Channels), Item.Image_In);
            Gain (Named ("txt_in.text_norm.weight"), Context, Item.Text_Norm);
            Matrix (Named ("txt_in.in_layer.weight"), Width, Context, Item.Text_In_First);
            Matrix (Named ("txt_in.out_layer.weight"), Width, Width, Item.Text_In_Second);
            Matrix (Named ("time_text_embed.timestep_embedder.linear_1.weight"), Width, Time_Width,
                    Item.Time_First);
            Matrix (Named ("time_text_embed.timestep_embedder.linear_2.weight"), Width, Width, Item.Time_Second);
            Matrix (Named ("modulation.1.weight"), 4 * Width, Width, Item.Modulation);
            Matrix (Named ("norm_out.linear.weight"), Width, Width, Item.Norm_Out);
            Matrix (Named ("proj_out.weight"), Element_Count (Shape.Out_Channels), Width, Item.Projection_Out);
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;

            Item.Layers := new Block_Array (1 .. Shape.Blocks);
            for Index in Item.Layers'Range loop
               declare
                  Layer : Block renames Item.Layers (Index);
                  At_Block : constant Natural := Index - 1;
               begin
                  Matrix (Block_Named (At_Block, "attn.to_q.weight"), Width, Width, Layer.Query);
                  Matrix (Block_Named (At_Block, "attn.to_k.weight"), Width, Width, Layer.Key);
                  Matrix (Block_Named (At_Block, "attn.to_v.weight"), Width, Width, Layer.Value);
                  Matrix (Block_Named (At_Block, "attn.to_out.0.weight"), Width, Width, Layer.Attention_Out);
                  Gain (Block_Named (At_Block, "attn.norm_q.weight"), Head, Layer.Query_Norm);
                  Gain (Block_Named (At_Block, "attn.norm_k.weight"), Head, Layer.Key_Norm);
                  Matrix (Block_Named (At_Block, "img_mlp.out.weight"), Width, Feed, Layer.Feed_Out);
                  Matrix (Block_Named (At_Block, "img_mlp.gate_up.weight"), 2 * Feed, Width, Layer.Gate_Up);
               end;
            end loop;
            if E.Is_Error (Status) then
               Fail (Status);
               return;
            end if;
         end;
      end;

      Item.Ready := True;
   end Open;

   procedure Close (Item : in out Denoiser) is
   begin
      if Item.Layers /= null then
         for Layer of Item.Layers.all loop
            T.Free (Layer.Query_Norm);
            T.Free (Layer.Key_Norm);
         end loop;
         Free (Item.Layers);
      end if;
      T.Free (Item.Text_Norm);
      Item.Image_In := T.Empty_View;
      Item.Text_In_First := T.Empty_View;
      Item.Text_In_Second := T.Empty_View;
      Item.Time_First := T.Empty_View;
      Item.Time_Second := T.Empty_View;
      Item.Modulation := T.Empty_View;
      Item.Norm_Out := T.Empty_View;
      Item.Projection_Out := T.Empty_View;
      B.Free (Item.Arena);
      Item.Base := System.Null_Address;
      Item.Span := 0;
      Item.Shape := (others => <>);
      Item.Ready := False;
      Containers.Close (Item.Container);
      Model_Runner.Byte_Sources.Files.Close (Item.File);
   end Close;

   function Sigmas (Steps : Positive; Image_Tokens : Positive) return N.Real_Array is
      subtype Real is N.Real;
      use type Real;
      Base_Tokens : constant Real := 256.0;
      Most_Tokens : constant Real := 8192.0;
      Base_Shift  : constant Real := 0.5;
      Most_Shift  : constant Real := 0.9;
      Terminal    : constant Real := 0.02;
      Slope       : constant Real := (Most_Shift - Base_Shift) / (Most_Tokens - Base_Tokens);
      Mu          : constant Real := Real (Image_Tokens) * Slope + (Base_Shift - Slope * Base_Tokens);
      Lifted      : constant Real := Real (N.Exp (N.Wide_Real (Mu)));
      Result      : N.Real_Array (0 .. Element_Count (Steps));
   begin
      for I in Result'Range loop
         declare
            T_Value : constant Real := 1.0 - Real (I) / Real (Steps);
         begin
            Result (I) := (if T_Value <= 0.0 then 0.0 else Lifted / (Lifted + (1.0 / T_Value - 1.0)));
         end;
      end loop;
      if Steps > 1 then
         declare
            Stretch : constant Real := (1.0 - Result (Result'Last - 1)) / (1.0 - Terminal);
         begin
            if Stretch > 0.0 then
               for I in Result'First .. Result'Last - 1 loop
                  Result (I) := 1.0 - (1.0 - Result (I)) / Stretch;
               end loop;
            end if;
         end;
      end if;
      Result (Result'Last) := 0.0;
      return Result;
   end Sigmas;

   function Is_Ready (Item : Denoiser) return Boolean
   is (Item.Ready);

   function Config (Item : Denoiser) return Configuration
   is (Item.Shape);


   --  One evaluation's attention, a share of (row, head) items at a time:
   --  each row's query over the keys it may see -- a prompt token the
   --  prompt's up to itself, an image token every one -- into A.
   type Attention_Work is new Model_Runner.Shares.Work with record
      Q, K, V, A : T.Real_Array_Access;
      Prompt, Total, Width, Head, Heads : Element_Count := 0;
   end record;

   overriding procedure Run (Item : in out Attention_Work; First : Element_Count; Last : Element_Count) is
      subtype Wide is N.Wide_Real;
      subtype Real is N.Real;
      use type Wide;
      Scale  : constant Wide := 1.0 / N.Sqrt (Wide (Item.Head));
      Scores : N.Wide_Real_Array (0 .. Item.Total - 1);
      Sums   : N.Wide_Real_Array (0 .. Item.Head - 1);
   begin
      for Which in First .. Last loop
         declare
            Row   : constant Element_Count := Which / Item.Heads;
            Head  : constant Element_Count := Which mod Item.Heads;
            Upto  : constant Element_Count := (if Row < Item.Prompt then Row else Item.Total - 1);
            Query : constant Element_Count := Row * Item.Width + Head * Item.Head;
            Most  : Wide := Wide'First;
            Sum   : Wide := 0.0;
         begin
            for Key in 0 .. Upto loop
               declare
                  At_Key : constant Element_Count := Key * Item.Width + Head * Item.Head;
                  Dot    : Real := 0.0;
                  use type Real;
               begin
                  for I in 0 .. Item.Head - 1 loop
                     Dot := Dot + Item.Q (Query + I) * Item.K (At_Key + I);
                  end loop;
                  Scores (Key) := Wide (Dot) * Scale;
                  Most := Wide'Max (Most, Scores (Key));
               end;
            end loop;
            Sums := [others => 0.0];
            for Key in 0 .. Upto loop
               declare
                  Weight : constant Wide := N.Exp (Scores (Key) - Most);
                  At_Key : constant Element_Count := Key * Item.Width + Head * Item.Head;
               begin
                  Sum := Sum + Weight;
                  for I in 0 .. Item.Head - 1 loop
                     Sums (I) := Sums (I) + Weight * Wide (Item.V (At_Key + I));
                  end loop;
               end;
            end loop;
            for I in 0 .. Item.Head - 1 loop
               Item.A (Query + I) := Real (Sums (I) / Sum);
            end loop;
         end;
      end loop;
   end Run;

   ---------------
   -- Velocity --
   ---------------

   procedure Velocity
     (Item      : Denoiser;
      Latent    : N.Real_Array;
      Rows      : Positive;
      Columns   : Positive;
      Timestep  : N.Real;
      Text      : N.Real_Array;
      Text_Rows : Natural;
      Pool      : Model_Runner.Backend.CPU.Pool_Reference;
      Result    : out N.Real_Array;
      Status    : out E.Error_Info)
   is
      package CPU renames Model_Runner.Backend.CPU;
      subtype Real is N.Real;
      subtype Wide is N.Wide_Real;
      use type Real;
      use type Wide;

      Shape   : Configuration renames Item.Shape;
      W       : constant Element_Count := Element_Count (Shape.Width);
      F       : constant Element_Count := Element_Count (Shape.Feed);
      D       : constant Element_Count := Element_Count (Shape.Head_Size);
      Heads   : constant Element_Count := Element_Count (Shape.Heads);
      Image   : constant Element_Count := Element_Count (Rows) * Element_Count (Columns);
      Prompt  : constant Element_Count := Element_Count (Text_Rows);
      Total   : constant Element_Count := Prompt + Image;
      Epsilon : constant Wide := 1.0E-6;

      --  Every row a token, Total of them: the prompt's, then the image's.
      X, H, Q, K, V, A, G, Y : T.Real_Array_Access;
      --  The time's two rows: the step's, then nought's; and what the
      --  modulation and the last norm make of them.
      Times, Hidden, Modulation, Final_Scale : T.Real_Array_Access;
      Pairs : constant Element_Count := D / 2;
      Angles_Cos, Angles_Sin : T.Real_Array_Access;

      procedure Release is
      begin
         T.Free (X); T.Free (H); T.Free (Q); T.Free (K); T.Free (V); T.Free (A); T.Free (G); T.Free (Y);
         T.Free (Times); T.Free (Hidden); T.Free (Modulation); T.Free (Final_Scale);
         T.Free (Angles_Cos); T.Free (Angles_Sin);
      end Release;

      --  Target := Weight's rows times each of Count vectors.
      procedure Product
        (Weight : T.View; Vectors : T.Real_Array_Access; Count : Element_Count; Target : T.Real_Array_Access) is
      begin
         if E.Is_Ok (Status) then
            CPU.Dispatch_Batch (Pool, Weight, Vectors, Count, Target, Status);
         end if;
      end Product;

      function Silu (Value : Real) return Real
      is (Real (Wide (Value) / (1.0 + N.Exp (-Wide (Value)))));

      --  A row's layer norm without gain or shift, then times one plus
      --  Scale's row Which.
      procedure Modulated_Norm
        (Source, Target : T.Real_Array_Access; Row : Element_Count; Scale : T.Real_Array_Access;
         Scale_At : Element_Count)
      is
         Base : constant Element_Count := Row * W;
         Mean, Square : Wide := 0.0;
      begin
         for I in 0 .. W - 1 loop
            Mean := Mean + Wide (Source (Base + I));
         end loop;
         Mean := Mean / Wide (W);
         for I in 0 .. W - 1 loop
            Square := Square + (Wide (Source (Base + I)) - Mean) ** 2;
         end loop;
         declare
            Inverse : constant Wide := 1.0 / N.Sqrt (Square / Wide (W) + Epsilon);
         begin
            for I in 0 .. W - 1 loop
               Target (Base + I) :=
                 Real ((Wide (Source (Base + I)) - Mean) * Inverse * (1.0 + Wide (Scale (Scale_At + I))));
            end loop;
         end;
      end Modulated_Norm;

      --  Which of the time's rows a token reads: nought's for the prompt.
      function Time_Row (Row : Element_Count) return Element_Count
      is (if Row < Prompt then 1 else 0);

      --  Each head of a row normalized by its root mean square and Gain,
      --  then turned by the row's angles.
      procedure Norm_And_Turn (Source : T.Real_Array_Access; Gain : T.Real_Array_Access) is
      begin
         for Row in 0 .. Total - 1 loop
            for Head in 0 .. Heads - 1 loop
               declare
                  Base   : constant Element_Count := Row * W + Head * D;
                  Square : Wide := 0.0;
               begin
                  for I in 0 .. D - 1 loop
                     Square := Square + Wide (Source (Base + I)) ** 2;
                  end loop;
                  declare
                     Inverse : constant Wide := 1.0 / N.Sqrt (Square / Wide (D) + Epsilon);
                  begin
                     for I in 0 .. D - 1 loop
                        Source (Base + I) := Real (Wide (Source (Base + I)) * Inverse * Wide (Gain (I)));
                     end loop;
                  end;
                  for Pair in 0 .. Pairs - 1 loop
                     declare
                        C  : constant Real := Angles_Cos (Row * Pairs + Pair);
                        S  : constant Real := Angles_Sin (Row * Pairs + Pair);
                        X0 : constant Real := Source (Base + 2 * Pair);
                        X1 : constant Real := Source (Base + 2 * Pair + 1);
                     begin
                        Source (Base + 2 * Pair) := C * X0 - S * X1;
                        Source (Base + 2 * Pair + 1) := S * X0 + C * X1;
                     end;
                  end loop;
               end;
            end loop;
         end loop;
      end Norm_And_Turn;

      --  A's rows := each row's attention, across the pool.
      procedure Attend is
         Job : aliased Attention_Work :=
           (Q => Q, K => K, V => V, A => A, Prompt => Prompt, Total => Total, Width => W, Head => D,
            Heads => Heads);
      begin
         if E.Is_Ok (Status) then
            CPU.Dispatch_Shares (Pool, Total * Heads, Job'Unchecked_Access, Status, Cost => Total * Total * W);
         end if;
      end Attend;
   begin
      Result := [others => 0.0];
      Status := E.Success;
      if not Item.Ready
        or else Latent'Length /= Element_Count (Shape.In_Channels) * Image
        or else Result'Length /= Element_Count (Shape.Out_Channels) * Image
        or else Text'Length /= Prompt * Element_Count (Shape.Context)
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      T.Allocate (Total * Element_Count'Max (W, Element_Count (Shape.Context)), X);
      T.Allocate (Total * Element_Count'Max (W, Element_Count (Shape.Context)), H);
      T.Allocate (Total * W, Q);
      T.Allocate (Total * W, K);
      T.Allocate (Total * W, V);
      T.Allocate (Total * W, A);
      T.Allocate (Total * 2 * F, G);
      T.Allocate (Total * Element_Count'Max (W, F), Y);
      T.Allocate (2 * W, Times);
      T.Allocate (2 * W, Hidden);
      T.Allocate (2 * 4 * W, Modulation);
      T.Allocate (W, Final_Scale);
      T.Allocate (Total * Pairs, Angles_Cos);
      T.Allocate (Total * Pairs, Angles_Sin);
      if X = null or else H = null or else Q = null or else K = null or else V = null or else A = null
        or else G = null or else Y = null or else Times = null or else Hidden = null or else Modulation = null
        or else Final_Scale = null or else Angles_Cos = null or else Angles_Sin = null
      then
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      --  The time, twice: a sinusoid, cosines first, through two linears
      --  with a SiLU between and one after.
      declare
         Half     : constant Element_Count := Time_Width / 2;
         Sinusoid : T.Real_Array_Access;
      begin
         T.Allocate (2 * Time_Width, Sinusoid);
         for Which in Element_Count range 0 .. 1 loop
            declare
               Time : constant Wide := (if Which = 0 then Wide (Timestep) else 0.0);
            begin
               for J in 0 .. Half - 1 loop
                  declare
                     Frequency : constant Wide := N.Exp (-N.Log (10_000.0) * Wide (J) / Wide (Half));
                  begin
                     Sinusoid (Which * Time_Width + J) := Real (N.Cos (Time * Frequency));
                     Sinusoid (Which * Time_Width + Half + J) := Real (N.Sin (Time * Frequency));
                  end;
               end loop;
            end;
         end loop;
         Product (Item.Time_First, Sinusoid, 2, Hidden);
         T.Free (Sinusoid);
      end;
      for I in 0 .. 2 * W - 1 loop
         Hidden (I) := Silu (Hidden (I));
      end loop;
      Product (Item.Time_Second, Hidden, 2, Times);
      for I in 0 .. 2 * W - 1 loop
         Times (I) := Silu (Times (I));
      end loop;
      Product (Item.Modulation, Times, 2, Modulation);
      Product (Item.Norm_Out, Times, 1, Final_Scale);

      --  The prompt's rows: a gain of one plus the stored one, then two
      --  linears with the tanh form of the Gaussian unit between.
      declare
         C : constant Element_Count := Element_Count (Shape.Context);
      begin
         for Row in 0 .. Prompt - 1 loop
            declare
               Square : Wide := 0.0;
            begin
               for I in 0 .. C - 1 loop
                  Square := Square + Wide (Text (Text'First + Row * C + I)) ** 2;
               end loop;
               declare
                  Inverse : constant Wide := 1.0 / N.Sqrt (Square / Wide (C) + Epsilon);
               begin
                  for I in 0 .. C - 1 loop
                     H (Row * C + I) := Real (Wide (Text (Text'First + Row * C + I)) * Inverse
                                              * (1.0 + Wide (Item.Text_Norm (I))));
                  end loop;
               end;
            end;
         end loop;
         if Prompt > 0 then
            Product (Item.Text_In_First, H, Prompt, Y);
            for I in 0 .. Prompt * W - 1 loop
               declare
                  Z : constant Wide := Wide (Y (I));
               begin
                  Y (I) := Real (0.5 * Z * (1.0 + N.Tanh (0.797_884_560_802_865_4 * (Z + 0.044_715 * Z ** 3))));
               end;
            end loop;
            Product (Item.Text_In_Second, Y, Prompt, X);
         end if;
      end;

      --  The image's rows, a latent pixel's channels each, behind them.
      declare
         Channels : constant Element_Count := Element_Count (Shape.In_Channels);
         Pixels   : T.Real_Array_Access;
         Rows_Out : T.Real_Array_Access;
      begin
         T.Allocate (Image * Channels, Pixels);
         T.Allocate (Image * W, Rows_Out);
         for Pixel in 0 .. Image - 1 loop
            for Channel in 0 .. Channels - 1 loop
               Pixels (Pixel * Channels + Channel) := Latent (Latent'First + Channel * Image + Pixel);
            end loop;
         end loop;
         Product (Item.Image_In, Pixels, Image, Rows_Out);
         X (Prompt * W .. Total * W - 1) := Rows_Out (0 .. Image * W - 1);
         T.Free (Pixels);
         T.Free (Rows_Out);
      end;

      --  Where each token is: a prompt token at (p, p, p), the image at
      --  the frame the prompt reached, its rows and columns about nought.
      for Row in 0 .. Total - 1 loop
         declare
            Place : array (0 .. 2) of Wide;
            Pair  : Element_Count := 0;
         begin
            if Row < Prompt then
               Place := [others => Wide (Row)];
            else
               declare
                  Pixel : constant Element_Count := Row - Prompt;
                  Down  : constant Integer := Integer (Pixel / Element_Count (Columns));
                  Along : constant Integer := Integer (Pixel mod Element_Count (Columns));
               begin
                  Place := [Wide (Prompt), Wide (Down - (Rows - Rows / 2)), Wide (Along - (Columns - Columns / 2))];
               end;
            end if;
            for Axis in Axis_Pairs'Range loop
               for J in 0 .. Axis_Pairs (Axis) - 1 loop
                  declare
                     Omega : constant Real :=
                       Real (1.0 / N.Exp (N.Log (10_000.0) * Wide (2 * J) / Wide (2 * Axis_Pairs (Axis))));
                     Angle : constant Real := Real (Place (Axis)) * Omega;
                  begin
                     Angles_Cos (Row * Pairs + Pair) := Real (N.Cos (Wide (Angle)));
                     Angles_Sin (Row * Pairs + Pair) := Real (N.Sin (Wide (Angle)));
                     Pair := Pair + 1;
                  end;
               end loop;
            end loop;
         end;
      end loop;

      --  The blocks.
      for Layer of Item.Layers.all loop
         exit when E.Is_Error (Status);
         for Row in 0 .. Total - 1 loop
            Modulated_Norm (X, H, Row, Modulation, Time_Row (Row) * 4 * W);
         end loop;
         Product (Layer.Query, H, Total, Q);
         Product (Layer.Key, H, Total, K);
         Product (Layer.Value, H, Total, V);
         exit when E.Is_Error (Status);
         Norm_And_Turn (Q, Layer.Query_Norm);
         Norm_And_Turn (K, Layer.Key_Norm);
         Attend;
         Product (Layer.Attention_Out, A, Total, Y);
         exit when E.Is_Error (Status);
         for Row in 0 .. Total - 1 loop
            declare
               Gate : constant Element_Count := Time_Row (Row) * 4 * W + W;
            begin
               for I in 0 .. W - 1 loop
                  X (Row * W + I) :=
                    Real (Wide (X (Row * W + I))
                          + N.Tanh (Wide (Modulation (Gate + I))) * Wide (Y (Row * W + I)));
               end loop;
            end;
         end loop;

         for Row in 0 .. Total - 1 loop
            Modulated_Norm (X, H, Row, Modulation, Time_Row (Row) * 4 * W + 2 * W);
         end loop;
         Product (Layer.Gate_Up, H, Total, G);
         exit when E.Is_Error (Status);
         --  The gate's half first, the up projection's second.
         for Row in 0 .. Total - 1 loop
            for I in 0 .. F - 1 loop
               Y (Row * F + I) := Silu (G (Row * 2 * F + I)) * G (Row * 2 * F + F + I);
            end loop;
         end loop;
         Product (Layer.Feed_Out, Y, Total, A);
         exit when E.Is_Error (Status);
         for Row in 0 .. Total - 1 loop
            declare
               Gate : constant Element_Count := Time_Row (Row) * 4 * W + 3 * W;
            begin
               for I in 0 .. W - 1 loop
                  X (Row * W + I) :=
                    Real (Wide (X (Row * W + I))
                          + N.Tanh (Wide (Modulation (Gate + I))) * Wide (A (Row * W + I)));
               end loop;
            end;
         end loop;
      end loop;

      --  The image's rows out: the last norm scaled by the step's time,
      --  then the way out, a latent pixel's channels each.
      if E.Is_Ok (Status) then
         declare
            Channels : constant Element_Count := Element_Count (Shape.Out_Channels);
            Normed, Answer : T.Real_Array_Access;
         begin
            T.Allocate (Image * W, Normed);
            T.Allocate (Image * Channels, Answer);
            for Pixel in 0 .. Image - 1 loop
               declare
                  Row : constant Element_Count := Prompt + Pixel;
               begin
                  Modulated_Norm (X, H, Row, Final_Scale, 0);
                  Normed (Pixel * W .. Pixel * W + W - 1) := H (Row * W .. Row * W + W - 1);
               end;
            end loop;
            Product (Item.Projection_Out, Normed, Image, Answer);
            if E.Is_Ok (Status) then
               for Pixel in 0 .. Image - 1 loop
                  for Channel in 0 .. Channels - 1 loop
                     Result (Result'First + Channel * Image + Pixel) := Answer (Pixel * Channels + Channel);
                  end loop;
               end loop;
            end if;
            T.Free (Normed);
            T.Free (Answer);
         end;
      end if;
      Release;
   end Velocity;

end Model_Runner.Qwen_Image;
