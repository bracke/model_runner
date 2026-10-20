with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

with Model_Runner.Backend.Device;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Philox;
with Model_Runner.Platform;
with Model_Runner.Quantization.Interleave;
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

   type View_Access is access all T.View;
   type View_List is array (Positive range <>) of View_Access;

   --  Every matrix a block or the model holds that the panel layout takes,
   --  rewritten into one arena and its view remade over it: the processor's
   --  integer products read a panel's rows together, where the file's
   --  layout has them read one at a time. The file's pages are left alone;
   --  what is not panelled stays where it lies.
   procedure Build_Panels (Item : in out Denoiser; Status : out E.Error_Info) is
      package Interleave renames Model_Runner.Quantization.Interleave;

      function Takes (Where : View_Access) return Boolean
      is (Interleave.Interleaves (Where.Format, Where.Rows, Where.Columns));

      function Blocks_Of (Where : View_Access) return Element_Count
      is (Where.Columns / Element_Count (Model_Runner.GGUF.Block_Elements (Where.Format)));

      All_Views : constant View_List :=
        [Item.Image_In'Unchecked_Access, Item.Text_In_First'Unchecked_Access,
         Item.Text_In_Second'Unchecked_Access, Item.Time_First'Unchecked_Access,
         Item.Time_Second'Unchecked_Access, Item.Modulation'Unchecked_Access, Item.Norm_Out'Unchecked_Access,
         Item.Projection_Out'Unchecked_Access];
      Count : Natural := 0;
   begin
      Status := E.Success;
      for V of All_Views loop
         Count := Count + (if Takes (V) then 1 else 0);
      end loop;
      for Layer of Item.Layers.all loop
         for V of View_List'[Layer.Query'Unchecked_Access, Layer.Key'Unchecked_Access,
                             Layer.Value'Unchecked_Access, Layer.Attention_Out'Unchecked_Access,
                             Layer.Gate_Up'Unchecked_Access, Layer.Feed_Out'Unchecked_Access]
         loop
            Count := Count + (if Takes (V) then 1 else 0);
         end loop;
      end loop;
      if Count = 0 then
         return;
      end if;

      declare
         Held  : View_List (1 .. Count);
         Bases : array (1 .. Count) of B.Byte_Count;
         Next  : Natural := 0;
         Size  : B.Byte_Count := 0;

         procedure Add (V : View_Access) is
         begin
            if Takes (V) then
               Next := Next + 1;
               Held (Next) := V;
               Bases (Next) := Size;
               Size := Size + Interleave.Panel_Bytes (V.Format, V.Rows, Blocks_Of (V));
            end if;
         end Add;

         protected Shared is
            procedure Take (Index : out Natural);
            procedure Note (Reason : E.Error_Info);
            function Reason return E.Error_Info;
         private
            Upto : Natural := 1;
            Bad  : E.Error_Info := E.Success;
         end Shared;

         protected body Shared is
            procedure Take (Index : out Natural) is
            begin
               if Upto > Held'Last or else E.Is_Error (Bad) then
                  Index := 0;
               else
                  Index := Upto;
                  Upto := Upto + 1;
               end if;
            end Take;

            procedure Note (Reason : E.Error_Info) is
            begin
               if E.Is_Ok (Bad) then
                  Bad := Reason;
               end if;
            end Note;

            function Reason return E.Error_Info is (Bad);
         end Shared;
      begin
         for V of All_Views loop
            Add (V);
         end loop;
         for Layer of Item.Layers.all loop
            Add (Layer.Query'Unchecked_Access);
            Add (Layer.Key'Unchecked_Access);
            Add (Layer.Value'Unchecked_Access);
            Add (Layer.Attention_Out'Unchecked_Access);
            Add (Layer.Gate_Up'Unchecked_Access);
            Add (Layer.Feed_Out'Unchecked_Access);
         end loop;
         B.Allocate (Size, Item.Panels);
         if Item.Panels = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;

         declare
            task type Panelling;

            task body Panelling is
               Which : Natural;
            begin
               loop
                  Shared.Take (Which);
                  exit when Which = 0;
                  declare
                     Where  : constant View_Access := Held (Which);
                     Source : B.Byte_Array (1 .. Where.Span) with Import, Address => Where.Base;
                     Taken  : Boolean;
                  begin
                     Interleave.Build
                       (Format => Where.Format, Source => Source, From => Where.Offset,
                        Target => Item.Panels.all, Into => Bases (Which), Rows => Where.Rows,
                        Blocks => Blocks_Of (Where), Ok => Taken);
                     if not Taken then
                        Shared.Note (E.Make (E.Internal_Invariant_Violated));
                     end if;
                  end;
               end loop;
            exception
               when others =>
                  Shared.Note (E.Make (E.Internal_Invariant_Violated));
            end Panelling;

            Team : array (1 .. Positive'Min (Model_Runner.Platform.Core_Count, Count)) of Panelling;
            pragma Unreferenced (Team);
         begin
            null;
         end;

         Status := Shared.Reason;
         if E.Is_Error (Status) then
            return;
         end if;
         for Index in Held'Range loop
            declare
               Fresh : T.View;
            begin
               T.Make_Panels
                 (Format  => Held (Index).Format,
                  Rows    => Held (Index).Rows,
                  Columns => Held (Index).Columns,
                  Data    => Item.Panels,
                  Offset  => Bases (Index),
                  Result  => Fresh,
                  Status  => Status);
               exit when E.Is_Error (Status);
               Held (Index).all := Fresh;
            end;
         end loop;
      end;
   end Build_Panels;

   procedure Open
     (Item   : in out Denoiser;
      Path   : String;
      Status : out E.Error_Info;
      Panels : Boolean := True)
   is
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

      if Panels then
         Build_Panels (Item, Status);
      end if;
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;
      Item.Ready := True;
   end Open;

   procedure Close (Item : in out Denoiser) is
   begin
      --  The device remembers a matrix by where its bytes lie, and these
      --  are about to go: another file mapped there would be answered with
      --  these weights.
      Model_Runner.Backend.Device.Forget_Matrices;
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
      B.Free (Item.Panels);
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

   procedure Sample
     (Item      : Denoiser;
      Rows      : Positive;
      Columns   : Positive;
      Steps     : Positive;
      Seed      : Interfaces.Unsigned_64;
      Text      : N.Real_Array;
      Text_Rows : Natural;
      Pool      : Model_Runner.Backend.CPU.Pool_Reference;
      Latent    : out N.Real_Array;
      Status    : out E.Error_Info;
      Progress  : access procedure (Step : Positive; Steps : Positive) := null;
      Turbo     : Boolean := False;
      Guidance  : N.Real := 1.0;
      Negative  : N.Real_Array := No_Rows;
      Negative_Rows : Natural := 0)
   is
      use type N.Real;
      Levels : constant N.Real_Array := (if Turbo then Turbo_Levels else Sigmas (Steps, Rows * Columns));
      Taken  : constant Positive := Levels'Length - 1;
      --  The negative prompt's velocity, where guidance asks for it.
      Away   : T.Real_Array_Access;
      Noise  : Model_Runner.Philox.Generator := Model_Runner.Philox.Seeded (Seed);
      Speed  : T.Real_Array_Access;
   begin
      Latent := [others => 0.0];
      if Item.Shape.In_Channels /= Item.Shape.Out_Channels
        or else Latent'Length /= Element_Count (Item.Shape.Out_Channels) * Element_Count (Rows * Columns)
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      Model_Runner.Philox.Draw (Noise, Latent);
      T.Allocate (Latent'Length, Speed);
      if Speed = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      Status := E.Success;
      for Step in 1 .. Taken loop
         declare
            Sigma : constant N.Real := Levels (Levels'First + Element_Count (Step) - 1);
            Next  : constant N.Real := Levels (Levels'First + Element_Count (Step));
         begin
            Velocity (Item, Latent, Rows, Columns, Sigma * 1000.0, Text, Text_Rows, Pool, Speed.all, Status);
            exit when E.Is_Error (Status);
            if Guidance /= 1.0 then
               if Away = null then
                  T.Allocate (Speed'Length, Away);
               end if;
               Velocity (Item, Latent, Rows, Columns, Sigma * 1000.0, Negative, Negative_Rows, Pool, Away.all,
                         Status);
               exit when E.Is_Error (Status);
               for I in Speed'Range loop
                  Speed (I) := Away (I) + Guidance * (Speed (I) - Away (I));
               end loop;
            end if;
            for I in Latent'Range loop
               Latent (I) := Latent (I) + (Next - Sigma) * Speed (Speed'First + (I - Latent'First));
            end loop;
         end;
         if Progress /= null then
            Progress (Step, Taken);
         end if;
      end loop;
      T.Free (Speed);
      T.Free (Away);
   end Sample;

   function Is_Ready (Item : Denoiser) return Boolean
   is (Item.Ready);

   function Config (Item : Denoiser) return Configuration
   is (Item.Shape);

   --  One evaluation's attention, a share of items at a time, an item a
   --  head and Tile query rows: each row's query over the keys it may see
   --  -- a prompt token the prompt's up to itself, an image token every
   --  one -- into A. The tile's rows read each key and value once between
   --  them, and the sums are binary32, as the products' are.
   Tile : constant := 8;

   type Attention_Work is new Model_Runner.Shares.Work with record
      Q, K, V, A : T.Real_Array_Access;
      Prompt, Total, Width, Head, Heads : Element_Count := 0;
   end record;

   overriding procedure Run (Item : in out Attention_Work; First : Element_Count; Last : Element_Count) is
      subtype Wide is N.Wide_Real;
      subtype Real is N.Real;
      use type Wide;
      use type Real;
      Scale  : constant Real := Real (1.0 / N.Sqrt (Wide (Item.Head)));
      Tiles  : constant Element_Count := (Item.Total + Tile - 1) / Tile;
      subtype Tile_Row is Element_Count range 0 .. Tile - 1;
      type Score_Rows is array (Tile_Row) of N.Real_Array (0 .. Item.Total - 1);
      type Sum_Rows is array (Tile_Row) of N.Real_Array (0 .. Item.Head - 1);
      Scores : Score_Rows;
      Sums   : Sum_Rows;
      Totals : array (Tile_Row) of Real;
   begin
      for Which in First .. Last loop
         declare
            Head   : constant Element_Count := Which / Tiles;
            Start  : constant Element_Count := (Which mod Tiles) * Tile;
            Rows   : constant Element_Count := Element_Count'Min (Tile, Item.Total - Start);
            Column : constant Element_Count := Head * Item.Head;
            --  The furthest key any row of the tile sees.
            Reach  : constant Element_Count :=
              (if Start + Rows - 1 < Item.Prompt then Start + Rows - 1 else Item.Total - 1);
         begin
            for R in 0 .. Rows - 1 loop
               declare
                  Row   : constant Element_Count := Start + R;
                  Upto  : constant Element_Count := (if Row < Item.Prompt then Row else Item.Total - 1);
                  Query : constant Element_Count := Row * Item.Width + Column;
                  Most  : Real := Real'First;
               begin
                  for Key in 0 .. Upto loop
                     declare
                        At_Key : constant Element_Count := Key * Item.Width + Column;
                        Dot    : Real := 0.0;
                     begin
                        for I in 0 .. Item.Head - 1 loop
                           Dot := Dot + Item.Q (Query + I) * Item.K (At_Key + I);
                        end loop;
                        Scores (R) (Key) := Dot * Scale;
                        Most := Real'Max (Most, Scores (R) (Key));
                     end;
                  end loop;
                  Totals (R) := 0.0;
                  for Key in 0 .. Upto loop
                     Scores (R) (Key) := Real (N.Exp (Wide (Scores (R) (Key) - Most)));
                     Totals (R) := Totals (R) + Scores (R) (Key);
                  end loop;
                  for Key in Upto + 1 .. Reach loop
                     Scores (R) (Key) := 0.0;
                  end loop;
                  Sums (R) := [others => 0.0];
               end;
            end loop;
            for Key in 0 .. Reach loop
               declare
                  At_Key : constant Element_Count := Key * Item.Width + Column;
               begin
                  for R in 0 .. Rows - 1 loop
                     declare
                        P : constant Real := Scores (R) (Key);
                     begin
                        for I in 0 .. Item.Head - 1 loop
                           Sums (R) (I) := Sums (R) (I) + P * Item.V (At_Key + I);
                        end loop;
                     end;
                  end loop;
               end;
            end loop;
            for R in 0 .. Rows - 1 loop
               declare
                  Query : constant Element_Count := (Start + R) * Item.Width + Column;
               begin
                  for I in 0 .. Item.Head - 1 loop
                     Item.A (Query + I) := Sums (R) (I) / Totals (R);
                  end loop;
               end;
            end loop;
         end;
      end loop;
   end Run;

   --  The step's work between its products, a share of rows at a time:
   --  each row's modulated norm into H; its heads' norms and turns in Q and
   --  K; its gated add of Y into X; its gated SiLU of G into Y.
   type Host_Kind is (Norm_Rows, Turn_Rows, Gate_Add, Gated_Silu);

   type Host_Work is new Model_Runner.Shares.Work with record
      Kind : Host_Kind := Norm_Rows;
      --  Which quarter of the modulation: 0 and 2 scales, 1 and 3 gates.
      Part : Element_Count := 0;
      X, H, Y, Q, K, G : T.Real_Array_Access;
      --  The modulation's two rows, the step's then nought's, and the tanh
      --  of each; the heads' gains; the rows' angles.
      Modulation, Gates, Gain_Q, Gain_K, Cosines, Sines : T.Real_Array_Access;
      W, F, D, Heads, Pairs, Prompt : Element_Count := 0;
   end record;

   overriding procedure Run (Item : in out Host_Work; First : Element_Count; Last : Element_Count) is
      subtype Wide is N.Wide_Real;
      subtype Real is N.Real;
      use type Wide;
      use type Real;
      Epsilon : constant Wide := 1.0E-6;
      W : constant Element_Count := Item.W;

      --  The modulation's offset for a row: the prompt's read nought's.
      function At_Row (Row : Element_Count) return Element_Count
      is ((if Row < Item.Prompt then 4 * W else 0) + Item.Part * W);

      procedure Heads_Of (Source, Gain : T.Real_Array_Access; Row : Element_Count) is
      begin
         for Head in 0 .. Item.Heads - 1 loop
            declare
               Base   : constant Element_Count := Row * W + Head * Item.D;
               Square : Wide := 0.0;
            begin
               for I in 0 .. Item.D - 1 loop
                  Square := Square + Wide (Source (Base + I)) ** 2;
               end loop;
               declare
                  Inverse : constant Real := Real (1.0 / N.Sqrt (Square / Wide (Item.D) + Epsilon));
               begin
                  for I in 0 .. Item.D - 1 loop
                     Source (Base + I) := Source (Base + I) * Inverse * Gain (I);
                  end loop;
               end;
               for Pair in 0 .. Item.Pairs - 1 loop
                  declare
                     C  : constant Real := Item.Cosines (Row * Item.Pairs + Pair);
                     S  : constant Real := Item.Sines (Row * Item.Pairs + Pair);
                     X0 : constant Real := Source (Base + 2 * Pair);
                     X1 : constant Real := Source (Base + 2 * Pair + 1);
                  begin
                     Source (Base + 2 * Pair) := C * X0 - S * X1;
                     Source (Base + 2 * Pair + 1) := S * X0 + C * X1;
                  end;
               end loop;
            end;
         end loop;
      end Heads_Of;
   begin
      for Row in First .. Last loop
         case Item.Kind is
            when Norm_Rows =>
               declare
                  Base : constant Element_Count := Row * W;
                  Scale : constant Element_Count := At_Row (Row);
                  Mean, Square : Wide := 0.0;
               begin
                  for I in 0 .. W - 1 loop
                     Mean := Mean + Wide (Item.X (Base + I));
                  end loop;
                  Mean := Mean / Wide (W);
                  for I in 0 .. W - 1 loop
                     Square := Square + (Wide (Item.X (Base + I)) - Mean) ** 2;
                  end loop;
                  declare
                     Inverse : constant Real := Real (1.0 / N.Sqrt (Square / Wide (W) + Epsilon));
                     Centre  : constant Real := Real (Mean);
                  begin
                     for I in 0 .. W - 1 loop
                        Item.H (Base + I) :=
                          (Item.X (Base + I) - Centre) * Inverse * (1.0 + Item.Modulation (Scale + I));
                     end loop;
                  end;
               end;
            when Turn_Rows =>
               Heads_Of (Item.Q, Item.Gain_Q, Row);
               Heads_Of (Item.K, Item.Gain_K, Row);
            when Gate_Add =>
               declare
                  Gate : constant Element_Count := At_Row (Row);
               begin
                  for I in 0 .. W - 1 loop
                     Item.X (Row * W + I) := Item.X (Row * W + I) + Item.Gates (Gate + I) * Item.Y (Row * W + I);
                  end loop;
               end;
            when Gated_Silu =>
               for I in 0 .. Item.F - 1 loop
                  declare
                     Z : constant Real := Item.G (Row * 2 * Item.F + I);
                  begin
                     Item.Y (Row * Item.F + I) :=
                       Real (Wide (Z) / (1.0 + N.Exp (-Wide (Z)))) * Item.G (Row * 2 * Item.F + Item.F + I);
                  end;
               end loop;
         end case;
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
      Times, Hidden, Modulation, Final_Scale, Gates : T.Real_Array_Access;
      Pairs : constant Element_Count := D / 2;
      Angles_Cos, Angles_Sin : T.Real_Array_Access;

      package Device renames Model_Runner.Backend.Device;
      On_Device : constant Boolean := Device.Is_Ready;

      --  How many rows one device product takes, and the room they are
      --  copied through.
      Device_Rows : constant Element_Count := 128;
      Chunk_In, Chunk_Out : T.Real_Array_Access;

      procedure Release is
      begin
         T.Free (X); T.Free (H); T.Free (Q); T.Free (K); T.Free (V); T.Free (A); T.Free (G); T.Free (Y);
         T.Free (Times); T.Free (Hidden); T.Free (Modulation); T.Free (Final_Scale); T.Free (Gates);
         T.Free (Angles_Cos); T.Free (Angles_Sin);
         T.Free (Chunk_In); T.Free (Chunk_Out);
      end Release;

      --  Target := Weight's rows times each of Count vectors.
      procedure Product
        (Weight : T.View; Vectors : T.Real_Array_Access; Count : Element_Count; Target : T.Real_Array_Access) is
      begin
         if E.Is_Error (Status) then
            return;
         elsif not On_Device then
            CPU.Dispatch_Batch (Pool, Weight, Vectors, Count, Target, Status);
            return;
         end if;
         declare
            From : Element_Count := 0;
            Ins  : constant Element_Count := Weight.Columns;
            Outs : constant Element_Count := Weight.Rows;
         begin
            while From < Count and then E.Is_Ok (Status) loop
               declare
                  Take : constant Element_Count := Element_Count'Min (Device_Rows, Count - From);
               begin
                  if Chunk_In = null or else Chunk_In'Length < Take * Ins then
                     T.Free (Chunk_In);
                     T.Allocate (Device_Rows * Ins, Chunk_In);
                  end if;
                  if Chunk_Out = null or else Chunk_Out'Length < Take * Outs then
                     T.Free (Chunk_Out);
                     T.Allocate (Device_Rows * Outs, Chunk_Out);
                  end if;
                  Chunk_In (0 .. Take * Ins - 1) := Vectors (From * Ins .. (From + Take) * Ins - 1);
                  Device.Dispatch_Batch (Weight, Chunk_In, Take, Chunk_Out, Status);
                  if E.Is_Ok (Status) then
                     Target (From * Outs .. (From + Take) * Outs - 1) := Chunk_Out (0 .. Take * Outs - 1);
                  end if;
                  From := From + Take;
               end;
            end loop;
         end;
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

      --  A's rows := each row's attention: on the device, the keys and
      --  values put in its cache and the prompt's rows asked causally, the
      --  image's over every key; or across the pool.
      procedure Attend is
         Job : aliased Attention_Work :=
           (Q => Q, K => K, V => V, A => A, Prompt => Prompt, Total => Total, Width => W, Head => D,
            Heads => Heads);
      begin
         if E.Is_Error (Status) then
            return;
         elsif not On_Device then
            CPU.Dispatch_Shares
              (Pool, Heads * ((Total + Tile - 1) / Tile), Job'Unchecked_Access, Status, Cost => Total * Total * W);
            return;
         end if;
         declare
            Keys_At   : constant Element_Count := 0;
            Values_At : constant Element_Count := Total * W;
            Ok        : Boolean;
            Queries   : constant Element_Count := 1024;

            --  Rows First .. First + Count - 1 asking, causally from the
            --  first key or over all of them.
            procedure Ask (First, Count : Element_Count; Causal : Boolean) is
               From : Element_Count := First;
            begin
               while Ok and then From < First + Count loop
                  declare
                     Take : constant Element_Count := Element_Count'Min (Queries, First + Count - From);
                  begin
                     Device.Attend
                       (Q (From * W .. (From + Take) * W - 1), Natural (Heads), Natural (D), Natural (D), 1,
                        0, (if Causal then Natural (From) else Natural (Total - 1)), Keys_At, Values_At,
                        Natural (W), Natural (W), N.Real (1.0 / N.Sqrt (N.Wide_Real (D))), 0.0,
                        A (From * W .. (From + Take) * W - 1), Ok, Positions => Natural (Take), Causal => Causal);
                     From := From + Take;
                  end;
               end loop;
            end Ask;
         begin
            Device.Reserve_Cache (2 * Total * W, 2 * Total * W, Ok);
            if Ok then
               Device.Put_Cache (Keys_At, K (0 .. Total * W - 1), Ok);
            end if;
            if Ok then
               Device.Put_Cache (Values_At, V (0 .. Total * W - 1), Ok);
            end if;
            if Ok and then Prompt > 0 then
               Ask (0, Prompt, Causal => True);
            end if;
            if Ok then
               Ask (Prompt, Image, Causal => False);
            end if;
            if not Ok then
               Status := E.Make (E.Backend_Capability_Missing);
            end if;
         end;
      end Attend;

      --  The rows' work of one kind, across the pool.
      procedure Share (Kind : Host_Kind; Part : Element_Count := 0) is
         Job : aliased Host_Work :=
           (Kind => Kind, Part => Part, X => X, H => H, Y => (if Part = 3 then A else Y), Q => Q, K => K, G => G,
            Modulation => Modulation, Gates => Gates, Gain_Q => null, Gain_K => null, Cosines => Angles_Cos,
            Sines => Angles_Sin, W => W, F => F, D => D, Heads => Heads, Pairs => Pairs, Prompt => Prompt);
      begin
         if E.Is_Ok (Status) then
            CPU.Dispatch_Shares (Pool, Total, Job'Unchecked_Access, Status, Cost => Total * W * 8);
         end if;
      end Share;

      procedure Share_Turns (Gain_Q, Gain_K : T.Real_Array_Access) is
         Job : aliased Host_Work :=
           (Kind => Turn_Rows, Part => 0, X => X, H => H, Y => Y, Q => Q, K => K, G => G,
            Modulation => Modulation, Gates => Gates, Gain_Q => Gain_Q, Gain_K => Gain_K, Cosines => Angles_Cos,
            Sines => Angles_Sin, W => W, F => F, D => D, Heads => Heads, Pairs => Pairs, Prompt => Prompt);
      begin
         if E.Is_Ok (Status) then
            CPU.Dispatch_Shares (Pool, Total, Job'Unchecked_Access, Status, Cost => Total * W * 8);
         end if;
      end Share_Turns;
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
      T.Allocate (2 * 4 * W, Gates);
      T.Allocate (W, Final_Scale);
      T.Allocate (Total * Pairs, Angles_Cos);
      T.Allocate (Total * Pairs, Angles_Sin);
      if X = null or else H = null or else Q = null or else K = null or else V = null or else A = null
        or else G = null or else Y = null or else Times = null or else Hidden = null or else Modulation = null
        or else Final_Scale = null or else Angles_Cos = null or else Angles_Sin = null or else Gates = null
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
      if E.Is_Ok (Status) then
         for I in 0 .. 2 * 4 * W - 1 loop
            Gates (I) := Real (N.Tanh (Wide (Modulation (I))));
         end loop;
      end if;

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
         Share (Norm_Rows, Part => 0);
         Product (Layer.Query, H, Total, Q);
         Product (Layer.Key, H, Total, K);
         Product (Layer.Value, H, Total, V);
         Share_Turns (Layer.Query_Norm, Layer.Key_Norm);
         Attend;
         Product (Layer.Attention_Out, A, Total, Y);
         Share (Gate_Add, Part => 1);
         Share (Norm_Rows, Part => 2);
         --  The gate's half first, the up projection's second.
         Product (Layer.Gate_Up, H, Total, G);
         Share (Gated_Silu);
         Product (Layer.Feed_Out, Y, Total, A);
         Share (Gate_Add, Part => 3);
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
