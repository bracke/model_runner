with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Numerics;

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

         if Shape.Width = 0 or else Shape.Head_Size = 0 or else Shape.Width mod Shape.Head_Size /= 0 then
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

   function Is_Ready (Item : Denoiser) return Boolean
   is (Item.Ready);

   function Config (Item : Denoiser) return Configuration
   is (Item.Shape);

end Model_Runner.Qwen_Image;
