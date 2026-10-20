with Ada.Containers.Generic_Array_Sort;
with Ada.Exceptions;

with Interfaces;

with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

package body Model_Runner.Safetensors is

   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package J renames Jsonlib.Documents;

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;
   use type J.Value_Kind;

   --  The header is refused, saying why.
   Refused : exception;

   procedure Refuse (Status : out E.Error_Info; Detail : String) is
   begin
      Status := E.Make (E.GGUF_Safetensors_Header_Invalid);
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   --  Read's work, which may leave the table part filled when it refuses.
   procedure Fill
     (Into   : in out Table;
      Source : in out Model_Runner.Byte_Sources.Source'Class;
      Status : out E.Error_Info)
   is
      Size   : constant Model_Runner.Bytes.Byte_Count := Source.Size;
      Prefix : Model_Runner.Bytes.Byte_Array (0 .. 7);
      Length : G.U64 := 0;
   begin
      Into.Tensors.Clear;
      Into.Names.Clear;
      Into.By_Name.Clear;
      Into.Start := 0;

      if Size < 8 then
         Status := E.Make (E.GGUF_Truncated);
         E.Add_Integer (Status, "offset", Long_Long_Integer (Size), E.Param_Offset);
         return;
      end if;
      Source.Read (0, Prefix, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      for Index in reverse Prefix'Range loop
         Length := Interfaces.Shift_Left (Length, 8) or G.U64 (Prefix (Index));
      end loop;
      if Length < 2 or else Length > Max_Header then
         Refuse (Status, "its header says it is" & Length'Image & " bytes long");
         return;
      end if;
      if G.U64 (Size) - 8 < Length then
         Status := E.Make (E.GGUF_Truncated);
         E.Add_Integer (Status, "offset", Long_Long_Integer (Size), E.Param_Offset);
         return;
      end if;

      declare
         Header : Model_Runner.Bytes.Byte_Array (0 .. Model_Runner.Bytes.Byte_Count (Length) - 1);
      begin
         Source.Read (8, Header, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Into.Start := 8 + Model_Runner.Bytes.Byte_Count (Length);

         declare
            Text     : String (1 .. Natural (Length));
            Document : J.Document;
            Error    : Jsonlib.Errors.Error_Info;
            Room     : constant G.U64 := G.U64 (Size - Into.Start);
         begin
            for Index in Text'Range loop
               Text (Index) := Character'Val (Header (Model_Runner.Bytes.Byte_Count (Index - 1)));
            end loop;
            --  Duplicate names are refused by the parser: a name read twice
            --  is a header that says two things about one tensor.
            Jsonlib.Parsers.Parse (Text, Document, Error, Jsonlib.Parsers.Default_Options);
            if Jsonlib.Errors.Failed (Error) then
               Refuse (Status, "its header is not JSON, or names a tensor twice");
               return;
            end if;

            declare
               Root : constant J.Node := J.Root (Document);

               --  A member that is a whole number of at least nought.
               function Count_Of (Item : J.Node; What : String) return G.U64 is
               begin
                  if J.Kind (Document, Item) /= J.Integer_Value or else J.As_Integer (Document, Item) < 0 then
                     raise Refused with What;
                  end if;
                  return G.U64 (J.As_Integer (Document, Item));
               end Count_Of;
            begin
               if J.Kind (Document, Root) /= J.Object_Value then
                  Refuse (Status, "its header is not a JSON object");
                  return;
               end if;
               if J.Length (Document, Root) > Max_Tensors + 1 then
                  Status := E.Make (E.GGUF_Tensor_Count_Too_Large);
                  E.Add_Integer (Status, "count", Long_Long_Integer (J.Length (Document, Root)));
                  E.Add_Integer (Status, "limit", Max_Tensors);
                  return;
               end if;

               for Index in 1 .. J.Length (Document, Root) loop
                  declare
                     Named : constant String := J.Name (Document, Root, Index);
                     Item  : constant J.Node := J.Element (Document, Root, Index);
                     Info  : Tensor_Info;
                     Width : G.U64;
                  begin
                     if Named = "__metadata__" then
                        if J.Kind (Document, Item) /= J.Object_Value then
                           Refuse (Status, "its __metadata__ is not an object");
                           return;
                        end if;
                     elsif Named'Length = 0 then
                        Status := E.Make (E.GGUF_Empty_Tensor_Name);
                        return;
                     elsif J.Kind (Document, Item) /= J.Object_Value
                       or else not J.Has_Member (Document, Item, "dtype")
                       or else not J.Has_Member (Document, Item, "shape")
                       or else not J.Has_Member (Document, Item, "data_offsets")
                       or else J.Kind (Document, J.Member (Document, Item, "dtype")) /= J.String_Value
                       or else J.Kind (Document, J.Member (Document, Item, "shape")) /= J.Array_Value
                       or else J.Kind (Document, J.Member (Document, Item, "data_offsets")) /= J.Array_Value
                       or else J.Length (Document, J.Member (Document, Item, "data_offsets")) /= 2
                     then
                        Refuse (Status, "tensor " & Named & " is not given a dtype, a shape and two data_offsets");
                        return;
                     else
                        declare
                           Kind    : constant String := J.As_String (Document, J.Member (Document, Item, "dtype"));
                           Shape   : constant J.Node := J.Member (Document, Item, "shape");
                           Offsets : constant J.Node := J.Member (Document, Item, "data_offsets");
                           First, Last : G.U64;
                        begin
                           if Kind = "F32" then
                              Info.Element := G.Type_F32;
                              Width := 4;
                           elsif Kind = "F16" then
                              Info.Element := G.Type_F16;
                              Width := 2;
                           elsif Kind = "BF16" then
                              Info.Element := G.Type_BF16;
                              Width := 2;
                           else
                              Status := E.Make (E.GGUF_Unsupported_Tensor_Type);
                              E.Add_Text (Status, "tensor", Named, E.Param_Identifier);
                              E.Add_Text (Status, "format", Kind, E.Param_Identifier);
                              return;
                           end if;

                           if J.Length (Document, Shape) > Max_Rank then
                              Status := E.Make (E.GGUF_Invalid_Tensor_Rank);
                              E.Add_Text (Status, "tensor", Named, E.Param_Identifier);
                              E.Add_Integer (Status, "rank", Long_Long_Integer (J.Length (Document, Shape)));
                              return;
                           end if;
                           Info.Rank := J.Length (Document, Shape);
                           for Axis in 1 .. Info.Rank loop
                              Info.Shape (Axis) :=
                                Count_Of (J.Element (Document, Shape, Axis), "tensor " & Named & "'s shape");
                              if Info.Shape (Axis) /= 0 and then Info.Elements > G.U64'Last / Info.Shape (Axis) then
                                 Status := E.Make (E.GGUF_Arithmetic_Overflow);
                                 return;
                              end if;
                              Info.Elements := Info.Elements * Info.Shape (Axis);
                           end loop;
                           if Info.Elements > G.U64'Last / Width then
                              Status := E.Make (E.GGUF_Arithmetic_Overflow);
                              return;
                           end if;

                           First := Count_Of (J.Element (Document, Offsets, 1), "tensor " & Named & "'s data_offsets");
                           Last := Count_Of (J.Element (Document, Offsets, 2), "tensor " & Named & "'s data_offsets");
                           if Last < First or else Last - First /= Info.Elements * Width then
                              Refuse (Status, "tensor " & Named
                                      & "'s byte range is not as long as its dtype and shape say");
                              return;
                           end if;
                           if Last > Room then
                              Status := E.Make (E.GGUF_Tensor_Out_Of_Bounds);
                              E.Add_Text (Status, "tensor", Named, E.Param_Identifier);
                              return;
                           end if;
                           Info.Data_Offset := Into.Start + Model_Runner.Bytes.Byte_Count (First);
                           Info.Data_Length := Model_Runner.Bytes.Byte_Count (Last - First);
                        end;
                        Into.Tensors.Append (Info);
                        Into.Names.Append (Named);
                        Into.By_Name.Insert (Named, Natural (Into.Tensors.Length));
                     end if;
                  end;
               end loop;
            end;
         exception
            when Problem : Refused =>
               Refuse (Status, Ada.Exceptions.Exception_Message (Problem) & " is not a count");
               return;
         end;
      end;

      --  No two ranges overlap: sorted by where each begins, each ends
      --  where the next begins or before.
      declare
         type Order_Array is array (Positive range <>) of Positive;
         Order : Order_Array (1 .. Natural (Into.Tensors.Length));

         function Before (Left, Right : Positive) return Boolean
         is (Into.Tensors (Left).Data_Offset < Into.Tensors (Right).Data_Offset);

         procedure Sort is new Ada.Containers.Generic_Array_Sort (Positive, Positive, Order_Array, Before);
      begin
         for Index in Order'Range loop
            Order (Index) := Index;
         end loop;
         Sort (Order);
         for Index in Order'First + 1 .. Order'Last loop
            declare
               Earlier : constant Tensor_Info := Into.Tensors (Order (Index - 1));
               Later   : constant Tensor_Info := Into.Tensors (Order (Index));
            begin
               if Later.Data_Length > 0
                 and then Earlier.Data_Offset + Earlier.Data_Length > Later.Data_Offset
               then
                  Status := E.Make (E.GGUF_Tensor_Overlap);
                  E.Add_Text (Status, "tensor", Into.Names (Order (Index)), E.Param_Identifier);
                  E.Add_Text (Status, "other", Into.Names (Order (Index - 1)), E.Param_Identifier);
                  return;
               end if;
            end;
         end loop;
      end;

      Status := E.Success;
   end Fill;

   procedure Read
     (Into   : in out Table;
      Source : in out Model_Runner.Byte_Sources.Source'Class;
      Status : out E.Error_Info) is
   begin
      Fill (Into, Source, Status);
      if E.Is_Error (Status) then
         Into.Tensors.Clear;
         Into.Names.Clear;
         Into.By_Name.Clear;
         Into.Start := 0;
      end if;
   end Read;

   function Count (Item : Table) return Natural
   is (Natural (Item.Tensors.Length));

   function Info (Item : Table; Index : Positive) return Tensor_Info
   is (Item.Tensors (Index));

   function Name (Item : Table; Index : Positive) return String
   is (Item.Names (Index));

   function Find (Item : Table; Named : String) return Natural is
      Position : constant Index_Maps.Cursor := Item.By_Name.Find (Named);
   begin
      return (if Index_Maps.Has_Element (Position) then Index_Maps.Element (Position) else 0);
   end Find;

   function Data_Start (Item : Table) return Model_Runner.Bytes.Byte_Count
   is (Item.Start);

end Model_Runner.Safetensors;
