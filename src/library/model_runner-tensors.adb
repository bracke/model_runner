with Ada.Unchecked_Deallocation;

with Interfaces;

with Model_Runner.Arithmetic;
with Model_Runner.Quantization;

package body Model_Runner.Tensors is

   use type System.Address;

   --  Weights come from a model file and may be infinities or not-a-numbers,
   --  so the kernels here can produce one. That is data, not a fault: callers
   --  test with Kernels.All_Finite and report it. Validity checking raises on
   --  the value before any of them can look, so it is suppressed for the same
   --  reason it is in Numerics and the sampler. Bounds and range checking are
   --  untouched.
   pragma Suppress (Validity_Check);

   use type Element_Count;

   --  How many elements a row kernel decodes before consuming them. Large
   --  enough that the per-span cost is negligible, small enough that the
   --  decoded values stay in the nearest cache and the stack cost is fixed
   --  whatever the row width.
   Max_Chunk : constant Element_Count := 1024;

   --  The chunk rounded down to a whole number of blocks, so a span never
   --  splits one. A block wider than the chunk decodes one block at a time.
   function Chunk_Elements (Per_Block : Element_Count) return Element_Count
   is (if Per_Block = 0 then Max_Chunk
       elsif Per_Block >= Max_Chunk then Per_Block
       else Max_Chunk / Per_Block * Per_Block);

   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Arithmetic.Checked;

   package A renames Model_Runner.Arithmetic;
   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package Q renames Model_Runner.Quantization;

   procedure Deallocate is
     new Ada.Unchecked_Deallocation (Real_Array, Real_Array_Access);

   procedure Deallocate_Halves is
     new Ada.Unchecked_Deallocation (Half_Array, Half_Array_Access);

   --------------
   -- Allocate --
   --------------

   procedure Allocate (Length : Element_Count; Result : out Real_Array_Access) is
   begin
      Result := new Real_Array (0 .. Length - 1);
      Result.all := [others => 0.0];
   exception
      when Storage_Error =>
         Result := null;
   end Allocate;

   ----------
   -- Free --
   ----------

   procedure Free (Item : in out Real_Array_Access) is
   begin
      if Item /= null then
         Deallocate (Item);
      end if;
      Item := null;
   end Free;

   procedure Allocate (Length : Element_Count; Result : out Half_Array_Access)
   is
   begin
      Result := new Half_Array (0 .. Length - 1);
      Result.all := [others => 0];
   exception
      when Storage_Error =>
         Result := null;
   end Allocate;

   procedure Free (Item : in out Half_Array_Access) is
   begin
      if Item /= null then
         Deallocate_Halves (Item);
      end if;
      Item := null;
   end Free;

   ----------------
   -- Is_Present --
   ----------------

   function Is_Present (Item : View) return Boolean
   is (Item.Base /= System.Null_Address
       and then Item.Rows > 0 and then Item.Columns > 0);

   ----------------
   -- Row_Bytes --
   ----------------

   function Row_Bytes (Item : View) return B.Byte_Count is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
   begin
      if Per_Block = 0 then
         return 0;
      else
         return B.Byte_Count (Item.Columns / Per_Block)
           * B.Byte_Count (G.Block_Bytes (Item.Format));
      end if;
   end Row_Bytes;

   ---------------
   -- Elements --
   ---------------

   function Elements (Item : View) return Element_Count
   is (Item.Rows * Item.Columns);

   ----------
   -- Make --
   ----------

   --  The owned form, said in terms of the borrowed one: a buffer this
   --  program allocated is a buffer at an address with a length, and nothing
   --  below this line needs to know which it was handed.
   procedure Make
     (Format  : G.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Data    : B.Byte_Array_Access;
      Offset  : B.Byte_Count;
      Result  : out View;
      Status  : out E.Error_Info) is
   begin
      if Data = null then
         Result := Empty_View;
         Status := E.Make (E.Tensor_Out_Of_Bounds);
         return;
      end if;

      Make (Format, Rows, Columns, Data.all'Address,
            B.Byte_Count (Data.all'Length), Offset, Result, Status);
   end Make;

   procedure Make
     (Format  : G.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Base    : System.Address;
      Span    : B.Byte_Count;
      Offset  : B.Byte_Count;
      Result  : out View;
      Status  : out E.Error_Info)
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      Result := Empty_View;

      if not Q.Is_Decodable (Format) then
         Status := E.Make (E.Tensor_Format_Unsupported);
         E.Add_Text (Status, "format", G.Type_Name (Format), E.Param_Identifier);
         return;
      end if;

      if Rows = 0 or else Columns = 0 or else Base = System.Null_Address then
         Status := E.Make (E.Tensor_Invalid_Shape);
         E.Add_Integer (Status, "rows", Long_Long_Integer (Rows));
         E.Add_Integer (Status, "columns", Long_Long_Integer (Columns));
         return;
      end if;

      if Per_Block = 0 or else Columns mod Per_Block /= 0 then
         Status := E.Make (E.Tensor_Block_Misaligned);
         E.Add_Text (Status, "format", G.Type_Name (Format), E.Param_Identifier);
         E.Add_Integer (Status, "columns", Long_Long_Integer (Columns));
         return;
      end if;

      declare
         Per_Row : constant A.Checked :=
           A.To_Checked (Interfaces.Unsigned_64 (Columns / Per_Block))
           * A.To_Checked (G.Block_Bytes (Format));
         Total   : constant A.Checked :=
           Per_Row * A.To_Checked (Interfaces.Unsigned_64 (Rows));
         Finish  : constant A.Checked :=
           Total + A.To_Checked (Interfaces.Unsigned_64 (Offset));
      begin
         if not A.Is_Valid (Finish) then
            Status := E.Make (E.Tensor_Invalid_Shape);
            return;
         end if;

         if B.Byte_Count (A.Value (Finish)) > Span then
            Status := E.Make (E.Tensor_Out_Of_Bounds);
            E.Add_Integer
              (Status, "offset", Long_Long_Integer (Offset), E.Param_Offset);
            E.Add_Integer
              (Status, "size", Long_Long_Integer (A.Value (Total)),
               E.Param_Bytes);
            E.Add_Integer
              (Status, "available", Long_Long_Integer (Span),
               E.Param_Bytes);
            return;
         end if;

         Result :=
           (Format  => Format,
            Rows    => Rows,
            Columns => Columns,
            Base    => Base,
            Span    => Span,
            Offset  => Offset,
            Length  => B.Byte_Count (A.Value (Total)));
         Status := E.Success;
      end;
   end Make;

   --------------
   -- Row_Dot --
   --------------

   function Row_Dot
     (Item   : View;
      Row    : Element_Count;
      Vector : Real_Array) return Real
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Sums : Model_Runner.Numerics.Wide_Real_Array (0 .. 0) := [others => 0.0];
      Ok   : Boolean;
   begin
      if not Is_Present (Item)
        or else Row >= Item.Rows
        or else Per_Block = 0
        or else Vector'Length /= Item.Columns
      then
         return 0.0;
      end if;

      --  The same kernel the matrix product uses, with one input vector, so
      --  a row computed alone and the same row computed inside a batch give
      --  the same bits.
      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;
      begin
         Q.Accumulate_Dot
           (Format  => Item.Format,
            Data    => Held,
            Offset  => Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item),
            Blocks  => Item.Columns / Per_Block,
            Vectors => Vector,
            First   => Vector'First,
            Stride  => Item.Columns,
            Count   => 1,
            Sums    => Sums,
            Ok      => Ok);
      end;

      return (if Ok then Real (Sums (0)) else 0.0);
   end Row_Dot;

   ---------------------
   -- Dequantize_Row --
   ---------------------

   procedure Dequantize_Row
     (Item   : View;
      Row    : Element_Count;
      Target : out Real_Array;
      Status : out E.Error_Info)
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Block_Size : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (Item.Format));
      Base   : B.Byte_Count;
      Ok     : Boolean;
      Column : Element_Count := 0;
   begin
      Target := [others => 0.0];

      if not Is_Present (Item)
        or else Row >= Item.Rows
        or else Target'Length /= Item.Columns
      then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
         E.Add_Integer (Status, "row", Long_Long_Integer (Row));
         E.Add_Integer (Status, "rows", Long_Long_Integer (Item.Rows));
         return;
      end if;

      Base := Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item);

      while Column < Item.Columns loop
         declare
            Remaining : constant Element_Count := Item.Columns - Column;
            Span      : constant Element_Count :=
              Element_Count'Min (Chunk_Elements (Per_Block), Remaining);
            Blocks    : constant Element_Count := Span / Per_Block;
         begin
            declare
               Held : B.Byte_Array (1 .. Item.Span)
                 with Import, Address => Item.Base;
            begin
               Q.Decode_Blocks
                 (Item.Format, Held, Base, Blocks,
                  Target (Target'First + Column
                          .. Target'First + Column + Span - 1), Ok);
            end;
            if not Ok then
               Status := E.Make (E.Tensor_Out_Of_Bounds);
               return;
            end if;

            Column := Column + Span;
            Base := Base + Block_Size * B.Byte_Count (Blocks);
         end;
      end loop;

      Status := E.Success;
   end Dequantize_Row;

   --------------------
   -- Mat_Vec_Range --
   --------------------

   procedure Mat_Vec_Range
     (Item   : View;
      Vector : Real_Array;
      Target : in out Real_Array;
      First  : Element_Count;
      Last   : Element_Count) is
   begin
      if not Is_Present (Item) or else First > Last or else Last >= Item.Rows
      then
         return;
      end if;

      --  One input vector is the same work arranged the same way, so a token
      --  evaluated alone and the same token evaluated inside a batch produce
      --  identical bits rather than merely close ones.
      Mat_Mul_Range (Item, Vector, 1, Target, First, Last);
   end Mat_Vec_Range;

   --------------
   -- Mat_Vec --
   --------------

   procedure Mat_Vec
     (Item   : View;
      Vector : Real_Array;
      Target : in out Real_Array;
      Status : out E.Error_Info) is
   begin
      if not Is_Present (Item)
        or else Vector'Length /= Item.Columns
        or else Target'Length /= Item.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "rows", Long_Long_Integer (Item.Rows));
         E.Add_Integer (Status, "columns", Long_Long_Integer (Item.Columns));
         E.Add_Integer (Status, "input", Long_Long_Integer (Vector'Length));
         E.Add_Integer (Status, "output", Long_Long_Integer (Target'Length));
         return;
      end if;

      Mat_Vec_Range (Item, Vector, Target, 0, Item.Rows - 1);
      Status := E.Success;
   end Mat_Vec;

   --------------------
   -- Mat_Mul_Range --
   --------------------

   procedure Mat_Mul_Range
     (Item    : View;
      Vectors : Real_Array;
      Count   : Element_Count;
      Target  : in out Real_Array;
      First   : Element_Count;
      Last    : Element_Count)
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Blocks : Element_Count;
      Sums   : Model_Runner.Numerics.Wide_Real_Array (0 .. Count - 1);
      Ok     : Boolean;
   begin
      if not Is_Present (Item)
        or else First > Last
        or else Last >= Item.Rows
        or else Count = 0
        or else Per_Block = 0
        or else Vectors'Length < Count * Item.Columns
        or else Target'Length < Count * Item.Rows
      then
         return;
      end if;

      Blocks := Item.Columns / Per_Block;

      --  Declared once around the row loop rather than once a row: an
      --  overlay costs nothing to enter, and nothing to leave, but saying so
      --  once reads better than saying it for every row.
      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;
      begin
         for Row in First .. Last loop
            Sums := [others => 0.0];

            --  One call for the whole row. The multiply is folded into the
            --  decode, so the weights are never written out in any form:
            --  there is no span buffer to size, to fill or to read back.
            Q.Accumulate_Dot
              (Format  => Item.Format,
               Data    => Held,
               Offset  => Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item),
               Blocks  => Blocks,
               Vectors => Vectors,
               First   => Vectors'First,
               Stride  => Item.Columns,
               Count   => Count,
               Sums    => Sums,
               Ok      => Ok);

            for Which in 0 .. Count - 1 loop
               Target (Target'First + Which * Item.Rows + Row) :=
                 (if Ok then Real (Sums (Which)) else 0.0);
            end loop;
         end loop;
      end;
   end Mat_Mul_Range;

   ---------------------------
   -- Mat_Mul_Range_Packed --
   ---------------------------

   procedure Mat_Mul_Range_Packed
     (Item    : View;
      Values  : Model_Runner.Quantization.Integers.Signed_Array;
      Scales  : Real_Array;
      Totals  : Model_Runner.Quantization.Integers.Sum_Array;
      Count   : Element_Count;
      Target  : in out Real_Array;
      First   : Element_Count;
      Last    : Element_Count;
      Handled : out Boolean)
   is
      package QI renames Model_Runner.Quantization.Integers;

      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Blocks : Element_Count;
      Ok     : Boolean;
   begin
      Handled := False;

      if not Is_Present (Item)
        or else First > Last
        or else Last >= Item.Rows
        or else Count = 0
        or else Per_Block = 0
        or else not QI.Has_Integer_Kernel (Item.Format)
        or else not QI.Is_Packable (Item.Columns)
        or else Values'Length < Count * Item.Columns
        or else Target'Length < Count * Item.Rows
      then
         return;
      end if;

      Blocks := Item.Columns / Per_Block;

      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;

         --  A tile's worth of accumulators, row major. Declared once around
         --  the loop rather than once a tile: it is a fixed number of wide
         --  reals and saying so once reads better.
         Tiled : Model_Runner.Numerics.Wide_Real_Array
           (0 .. QI.Row_Tile * Count - 1);

         --  How many rows to take at once, which depends on how many
         --  vectors there are: see Wanted_Tile.
         Wanted : constant Element_Count := QI.Wanted_Tile (Count);

         At_Row : Element_Count := First;
      begin
         while At_Row <= Last loop
            declare
               Here : constant Element_Count :=
                 Element_Count'Min (Wanted, Last - At_Row + 1);
            begin
               Tiled := [others => 0.0];

               --  Four rows against one reading of the activation. The row
               --  loop that was here read it once per row, which is the
               --  same bytes out of the same cache line four times.
               QI.Accumulate_Rows
                 (Format    => Item.Format,
                  Data      => Held,
                  Offset    =>
                    Item.Offset + B.Byte_Count (At_Row) * Row_Bytes (Item),
                  Row_Bytes => Row_Bytes (Item),
                  Rows      => Here,
                  Blocks    => Blocks,
                  Values    => Values,
                  Scales    => Scales,
                  Totals    => Totals,
                  First     => 0,
                  Stride    => Item.Columns,
                  Count     => Count,
                  Sums      => Tiled,
                  Ok        => Ok);

               --  A tile the integer path refuses is a tile nobody has
               --  computed, and the range is all or nothing: reporting it
               --  here sends the whole share back to the floating-point path
               --  rather than leaving some rows right and some zero.
               if not Ok then
                  return;
               end if;

               --  The vector outside and the row inside, which is the
               --  order the target is laid out in and not the order the
               --  tile is.
               --
               --  A target keeps a whole vector's answers together, so
               --  consecutive rows of one vector are consecutive words;
               --  written the other way round, every step of the inner
               --  loop moved Item.Rows words along -- eight kilobytes for
               --  a two-thousand-row tensor, a cache line touched and
               --  abandoned for each of eight hundred and eighty writes a
               --  tile. Turned about, the writes are contiguous and it is
               --  the reads that stride, inside a seven-kilobyte tile that
               --  is in the nearest cache whichever way it is walked.
               --
               --  The same values reach the same places; a profile put
               --  this procedure at five per cent of a prompt and this
               --  loop at most of it.
               for Which in 0 .. Count - 1 loop
                  for Row in 0 .. Here - 1 loop
                     Target (Target'First + Which * Item.Rows + At_Row + Row)
                       := Real (Tiled (Row * Count + Which));
                  end loop;
               end loop;

               At_Row := At_Row + Here;
            end;
         end loop;
      end;

      Handled := True;
   end Mat_Mul_Range_Packed;

end Model_Runner.Tensors;
