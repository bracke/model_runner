with Ada.Exceptions;
with Model_Runner.Arithmetic;
with Model_Runner.UTF8;

package body Model_Runner.GGUF.Containers.Reader is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Arithmetic.Checked;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;

   package A renames Model_Runner.Arithmetic;
   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.Cancellation;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package P renames Model_Runner.Progress;

   --  Growth policy for the shared byte pool. The pool doubles until it can
   --  hold the request, which keeps the number of reallocations logarithmic
   --  while the total stays bounded by Max_Metadata_Pool_Bytes.
   Initial_Pool : constant B.Byte_Count := 4096;

   --  Parser state threaded through the private routines below.
   type State is record
      Cursor : B.Byte_Count := 0;
      Size   : B.Byte_Count := 0;
   end record;

   -----------------------------------------------------------------------
   --  Diagnostics
   -----------------------------------------------------------------------

   --  Return the text a pool slice refers to. The parent body has an
   --  equivalent private helper; a child body cannot see it, so the one line
   --  of storage arithmetic is repeated here rather than widening the parent's
   --  visible interface for the benefit of one caller.
   function Pool_Text (Item : Container; Part : Slice) return String is
   begin
      if Item.Pool = null or else Part.Length = 0
        or else Part.Offset + Part.Length > Item.Pool_Used
      then
         return "";
      end if;

      return B.To_String
        (Item.Pool.all (Item.Pool.all'First + Part.Offset
                        .. Item.Pool.all'First + Part.Offset + Part.Length - 1));
   end Pool_Text;

   --  Build a structural diagnostic anchored at a file offset.
   function At_Offset
     (Code   : E.Error_Code;
      Offset : B.Byte_Count) return E.Error_Info
   is
      Result : E.Error_Info := E.Make (Code);
   begin
      E.Set_Location (Result, Interfaces.Unsigned_64 (Offset));
      return Result;
   end At_Offset;

   -----------------------------------------------------------------------
   --  Pool management
   -----------------------------------------------------------------------

   --  Reserve room for Extra more bytes in the pool, reporting the limit.
   procedure Reserve
     (Item   : in out Container;
      Extra  : B.Byte_Count;
      Status : out E.Error_Info)
   is
      Needed : constant A.Checked :=
        A.To_Checked (Interfaces.Unsigned_64 (Item.Pool_Used))
        + A.To_Checked (Interfaces.Unsigned_64 (Extra));
   begin
      Status := E.Success;

      if not A.Is_Valid (Needed) then
         Status := E.Make (E.GGUF_Arithmetic_Overflow);
         return;
      end if;

      if A.Value (Needed) > Item.Bounds.Max_Metadata_Pool_Bytes then
         Status := E.Make (E.Memory_Limit_Exceeded);
         E.Add_Text (Status, "category", "metadata_storage", E.Param_Identifier);
         E.Add_Integer
           (Status, "requested", Long_Long_Integer (A.Value (Needed)),
            E.Param_Bytes);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Item.Bounds.Max_Metadata_Pool_Bytes),
            E.Param_Bytes);
         return;
      end if;

      if Item.Pool /= null
        and then B.Byte_Count (A.Value (Needed)) <= Item.Pool.all'Length
      then
         return;
      end if;

      declare
         Capacity : B.Byte_Count :=
           (if Item.Pool = null then Initial_Pool
            else B.Byte_Count (Item.Pool.all'Length));
         Fresh    : B.Byte_Array_Access;
      begin
         while Capacity < B.Byte_Count (A.Value (Needed)) loop
            if Capacity > B.Byte_Count'Last / 2 then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
            Capacity := Capacity * 2;
         end loop;

         B.Allocate (Capacity, Fresh);
         if Fresh = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Integer
              (Status, "requested", Long_Long_Integer (Capacity), E.Param_Bytes);
            return;
         end if;

         if Item.Pool /= null and then Item.Pool_Used > 0 then
            Fresh.all (Fresh.all'First .. Fresh.all'First + Item.Pool_Used - 1) :=
              Item.Pool.all (Item.Pool.all'First
                             .. Item.Pool.all'First + Item.Pool_Used - 1);
         end if;

         B.Free (Item.Pool);
         Item.Pool := Fresh;
      end;
   end Reserve;

   -----------------------------------------------------------------------
   --  Primitive readers
   -----------------------------------------------------------------------

   --  Read Length bytes at the cursor and advance it.
   procedure Take
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out State;
      Length : B.Byte_Count;
      Target : out B.Byte_Array;
      Status : out E.Error_Info)
   is
      Next : constant A.Checked :=
        A.To_Checked (Interfaces.Unsigned_64 (Item.Cursor))
        + A.To_Checked (Interfaces.Unsigned_64 (Length));
   begin
      Target := [others => 0];

      if not A.Is_Valid (Next) then
         Status := At_Offset (E.GGUF_Arithmetic_Overflow, Item.Cursor);
         return;
      end if;

      if B.Byte_Count (A.Value (Next)) > Item.Size then
         Status := At_Offset (E.GGUF_Truncated, Item.Cursor);
         E.Add_Integer
           (Status, "length", Long_Long_Integer (Length), E.Param_Bytes);
         E.Add_Integer
           (Status, "size", Long_Long_Integer (Item.Size), E.Param_Bytes);
         return;
      end if;

      Source.Read (Item.Cursor, Target, Status);
      if E.Is_Ok (Status) then
         Item.Cursor := B.Byte_Count (A.Value (Next));
      end if;
   end Take;

   --  Read an unsigned 64-bit little-endian value at the cursor.
   procedure Take_U64
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out State;
      Value  : out Interfaces.Unsigned_64;
      Status : out E.Error_Info)
   is
      Buffer : B.Byte_Array (1 .. 8);
      Ok     : Boolean;
   begin
      Value := 0;
      Take (Source, Item, 8, Buffer, Status);
      if E.Is_Ok (Status) then
         Value := B.Get_U64 (Buffer, 0, Ok);
      end if;
   end Take_U64;

   --  Read an unsigned 32-bit little-endian value at the cursor.
   procedure Take_U32
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out State;
      Value  : out Interfaces.Unsigned_32;
      Status : out E.Error_Info)
   is
      Buffer : B.Byte_Array (1 .. 4);
      Ok     : Boolean;
   begin
      Value := 0;
      Take (Source, Item, 4, Buffer, Status);
      if E.Is_Ok (Status) then
         Value := B.Get_U32 (Buffer, 0, Ok);
      end if;
   end Take_U32;

   --  Read a GGUF string: a 64-bit length followed by that many bytes. The
   --  bytes are validated as UTF-8 and appended to the pool.
   --  Largest run of bytes examined in one step when checking an encoding.
   --
   --  Every length in a file is chosen by whoever wrote the file, so no
   --  object may be sized from one. Bytes already in the pool are looked at
   --  a window of this size at a time instead.
   Copy_Chunk : constant B.Byte_Count := 64 * 1024;

   --  Append a run of source bytes to the metadata pool.
   --
   --  The run is checked against the end of the file before any of it is
   --  taken, so a file that merely claims a large run is refused as truncated
   --  rather than asking for the storage first. The pool is grown to hold it
   --  and the bytes land there directly: no object is ever sized by a length
   --  the file chose.
   procedure Take_Into_Pool
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out Container;
      Cursor : in out State;
      Length : B.Byte_Count;
      Result : out Slice;
      Status : out E.Error_Info)
   is
      Next : constant A.Checked :=
        A.To_Checked (Interfaces.Unsigned_64 (Cursor.Cursor))
        + A.To_Checked (Interfaces.Unsigned_64 (Length));
   begin
      Result := (0, 0);

      if not A.Is_Valid (Next) then
         Status := At_Offset (E.GGUF_Arithmetic_Overflow, Cursor.Cursor);
         return;
      end if;

      if B.Byte_Count (A.Value (Next)) > Cursor.Size then
         Status := At_Offset (E.GGUF_Truncated, Cursor.Cursor);
         E.Add_Integer
           (Status, "length", Long_Long_Integer (Length), E.Param_Bytes);
         E.Add_Integer
           (Status, "size", Long_Long_Integer (Cursor.Size), E.Param_Bytes);
         return;
      end if;

      Reserve (Item, Length, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Result := (Offset => Item.Pool_Used, Length => Length);

      if Length > 0 then
         declare
            First : constant B.Byte_Count :=
              Item.Pool.all'First + Item.Pool_Used;
         begin
            if Length <= Copy_Chunk then
               --  Into a buffer here, then placed. The buffer is sized by
               --  the run but only on this side of the bound, so what sizes
               --  it is the bound and not the file.
               declare
                  Buffer : B.Byte_Array (1 .. Length);
               begin
                  Source.Read (Cursor.Cursor, Buffer, Status);

                  if E.Is_Error (Status) then
                     Result := (0, 0);
                     return;
                  end if;

                  Item.Pool.all (First .. First + Length - 1) := Buffer;
               end;
            else
               --  Past the bound, straight into the pool: nothing may be
               --  sized by a length the file chose.
               Source.Read
                 (Cursor.Cursor, Item.Pool.all (First .. First + Length - 1),
                  Status);

               if E.Is_Error (Status) then
                  Result := (0, 0);
                  return;
               end if;
            end if;
         end;

         Item.Pool_Used := Item.Pool_Used + Length;
         Cursor.Cursor := Cursor.Cursor + Length;
      end if;

      Status := E.Success;
   end Take_Into_Pool;

   --  Report whether a run already in the pool is well-formed UTF-8.
   --
   --  Checked a window at a time, because the run may be as long as the
   --  string limit allows and a String of that length is exactly the object
   --  this must not create. Each window is first pulled back to a sequence
   --  boundary, so a sequence split by the window edge is judged whole in
   --  the next window rather than truncated in this one.
   function Pool_Is_Valid_UTF8
     (Item : Container; Run : Slice) return Boolean
   is
      Position : B.Byte_Count := 0;
   begin
      if Run.Length = 0 then
         return True;
      end if;

      --  Almost every run is a key or a token and fits a window whole. The
      --  windowing below exists for the ones that do not.
      if Run.Length <= Copy_Chunk then
         declare
            Only : constant B.Byte_Count := Item.Pool.all'First + Run.Offset;
         begin
            return Model_Runner.UTF8.Is_Valid
              (B.To_String (Item.Pool.all (Only .. Only + Run.Length - 1)));
         end;
      end if;

      while Position < Run.Length loop
         declare
            Rest   : constant B.Byte_Count := Run.Length - Position;
            Window : B.Byte_Count := (if Rest < Copy_Chunk then Rest else Copy_Chunk);
            First  : constant B.Byte_Count :=
              Item.Pool.all'First + Run.Offset + Position;
         begin
            if Window < Rest then
               --  Walk back to the last byte that can begin a sequence. It
               --  is within three bytes of the edge or the run is malformed
               --  whatever the next window holds.
               declare
                  Back : B.Byte_Count := 0;
                  Need : Natural := 0;
               begin
                  loop
                     Need := Model_Runner.UTF8.Sequence_Length
                       (Character'Val
                          (Item.Pool.all (First + Window - 1 - Back)));
                     exit when Need > 0;

                     if Back = 3 then
                        return False;
                     end if;
                     Back := Back + 1;
                  end loop;

                  --  Keep the sequence whole: if this window cannot hold all
                  --  of it, it belongs to the next one.
                  if B.Byte_Count (Need) > Back + 1 then
                     Window := Window - (Back + 1);
                  end if;
               end;

               if Window = 0 then
                  return False;
               end if;
            end if;

            if not Model_Runner.UTF8.Is_Valid
                     (B.To_String (Item.Pool.all (First .. First + Window - 1)))
            then
               return False;
            end if;

            Position := Position + Window;
         end;
      end loop;

      return True;
   end Pool_Is_Valid_UTF8;

   procedure Take_String
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out Container;
      Cursor : in out State;
      Result : out Slice;
      Status : out E.Error_Info)
   is
      Length : Interfaces.Unsigned_64;
      Origin : constant B.Byte_Count := Cursor.Cursor;
   begin
      Result := (0, 0);
      Take_U64 (Source, Cursor, Length, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Length > Item.Bounds.Max_String_Bytes then
         Status := At_Offset (E.GGUF_Invalid_String_Length, Origin);
         E.Add_Integer
           (Status, "length", Long_Long_Integer (Length), E.Param_Bytes);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Item.Bounds.Max_String_Bytes), E.Param_Bytes);
         return;
      end if;

      Take_Into_Pool
        (Source, Item, Cursor, B.Byte_Count (Length), Result, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if not Pool_Is_Valid_UTF8 (Item, Result) then
         --  Give the pool back, so that a rejected string leaves the
         --  container exactly as large as it was.
         Item.Pool_Used := Result.Offset;
         Result := (0, 0);
         Status := At_Offset (E.GGUF_Invalid_UTF8, Origin);
         return;
      end if;
   end Take_String;

   -----------------------------------------------------------------------
   --  Metadata
   -----------------------------------------------------------------------

   --  Read one scalar value of a known type into an entry.
   procedure Take_Scalar
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out Container;
      Cursor : in out State;
      Kind   : Value_Type;
      Target : in out Metadata_Entry;
      Status : out E.Error_Info)
   is
      Width  : constant B.Byte_Count := Scalar_Size (Kind);
      Buffer : B.Byte_Array (1 .. B.Byte_Count'Max (Width, 1));
      Ok     : Boolean;
   begin
      if Kind = Value_String then
         Take_String (Source, Item, Cursor, Target.Payload, Status);
         return;
      end if;

      Take (Source, Cursor, Width, Buffer, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      case Kind is
         when Value_UInt8 =>
            Target.Unsigned := Interfaces.Unsigned_64 (B.Get_U8 (Buffer, 0, Ok));
            Target.Signed := Long_Long_Integer (Target.Unsigned);
         when Value_Int8 =>
            Target.Signed := Long_Long_Integer (B.Get_I8 (Buffer, 0, Ok));
         when Value_UInt16 =>
            Target.Unsigned := Interfaces.Unsigned_64 (B.Get_U16 (Buffer, 0, Ok));
            Target.Signed := Long_Long_Integer (Target.Unsigned);
         when Value_Int16 =>
            Target.Signed := Long_Long_Integer (B.Get_I16 (Buffer, 0, Ok));
         when Value_UInt32 =>
            Target.Unsigned := Interfaces.Unsigned_64 (B.Get_U32 (Buffer, 0, Ok));
            Target.Signed := Long_Long_Integer (Target.Unsigned);
         when Value_Int32 =>
            Target.Signed := Long_Long_Integer (B.Get_I32 (Buffer, 0, Ok));
         when Value_Float32 =>
            Target.Number := N.Wide_Real (B.Get_F32 (Buffer, 0, Ok));
         when Value_Bool =>
            Target.Flag := B.Get_Bool (Buffer, 0, Ok);
         when Value_UInt64 =>
            Target.Unsigned := B.Get_U64 (Buffer, 0, Ok);
            --  A value above Long_Long_Integer'Last cannot be range checked in
            --  the signed domain; it is clamped and will fail any range check
            --  a caller performs.
            Target.Signed :=
              (if Target.Unsigned > Interfaces.Unsigned_64 (Long_Long_Integer'Last)
               then Long_Long_Integer'Last
               else Long_Long_Integer (Target.Unsigned));
         when Value_Int64 =>
            Target.Signed := Long_Long_Integer (B.Get_I64 (Buffer, 0, Ok));
         when Value_Float64 =>
            Target.Number := B.Get_F64 (Buffer, 0, Ok);
         when Value_String | Value_Array =>
            Ok := False;
      end case;

      if not Ok then
         Status := At_Offset (E.GGUF_Truncated, Cursor.Cursor);
      end if;
   end Take_Scalar;

   --  Read an array metadata value. String elements are appended to the pool
   --  individually and recorded as slices; numeric elements are appended as
   --  one contiguous payload and decoded on demand.
   procedure Take_Array
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out Container;
      Cursor : in out State;
      Target : in out Metadata_Entry;
      Status : out E.Error_Info)
   is
      Origin       : constant B.Byte_Count := Cursor.Cursor;
      Element_Code : Interfaces.Unsigned_32;
      Count        : Interfaces.Unsigned_64;
      Known        : Boolean;
   begin
      Take_U32 (Source, Cursor, Element_Code, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Target.Element_Kind := To_Value_Type (Element_Code, Known);
      if not Known then
         Status := At_Offset (E.GGUF_Unknown_Value_Type, Origin);
         E.Add_Integer (Status, "code", Long_Long_Integer (Element_Code));
         return;
      end if;

      if not Is_Valid_Array_Element (Target.Element_Kind) then
         Status := At_Offset (E.GGUF_Invalid_Array_Element_Type, Origin);
         return;
      end if;

      Take_U64 (Source, Cursor, Count, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Count > Interfaces.Unsigned_64 (Item.Bounds.Max_Array_Elements) then
         Status := At_Offset (E.GGUF_Array_Too_Large, Origin);
         E.Add_Integer (Status, "count", Long_Long_Integer (Count));
         E.Add_Integer
           (Status, "limit", Long_Long_Integer (Item.Bounds.Max_Array_Elements));
         return;
      end if;

      Target.Length := Natural (Count);

      if Target.Element_Kind = Value_String then
         Target.First_Slice := Natural (Item.Slices.Length) + 1;

         for Index in 1 .. Target.Length loop
            declare
               Element : Slice;
            begin
               Take_String (Source, Item, Cursor, Element, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Item.Slices.Append (Element);
            end;
         end loop;

         Status := E.Success;
         return;
      end if;

      declare
         Width : constant B.Byte_Count := Scalar_Size (Target.Element_Kind);
         Total : constant A.Checked :=
           A.To_Checked (Count) * A.To_Checked (Interfaces.Unsigned_64 (Width));
      begin
         if not A.Is_Valid (Total) then
            Status := At_Offset (E.GGUF_Arithmetic_Overflow, Origin);
            return;
         end if;

         Take_Into_Pool
           (Source, Item, Cursor, B.Byte_Count (A.Value (Total)),
            Target.Payload, Status);
      end;
   end Take_Array;

   --  Read one metadata entry, including its key and value.
   procedure Take_Entry
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out Container;
      Cursor : in out State;
      Status : out E.Error_Info)
   is
      Origin  : constant B.Byte_Count := Cursor.Cursor;
      Element : Metadata_Entry;
      Code    : Interfaces.Unsigned_32;
      Known   : Boolean;
   begin
      Take_String (Source, Item, Cursor, Element.Key, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Key : constant String := Pool_Text (Item, Element.Key);
      begin
         if Key = "" then
            Status := At_Offset (E.GGUF_Empty_Metadata_Key, Origin);
            return;
         end if;

         if Item.Metadata_Map.Contains (Key) then
            Status := At_Offset (E.GGUF_Duplicate_Metadata_Key, Origin);
            E.Add_Text (Status, "key", Key, E.Param_Identifier);
            return;
         end if;

         Take_U32 (Source, Cursor, Code, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Element.Kind := To_Value_Type (Code, Known);
         if not Known then
            Status := At_Offset (E.GGUF_Unknown_Value_Type, Cursor.Cursor);
            E.Add_Text (Status, "key", Key, E.Param_Identifier);
            E.Add_Integer (Status, "code", Long_Long_Integer (Code));
            return;
         end if;

         if Element.Kind = Value_Array then
            Take_Array (Source, Item, Cursor, Element, Status);
         else
            Element.Length := 1;
            Take_Scalar (Source, Item, Cursor, Element.Kind, Element, Status);
         end if;

         if E.Is_Error (Status) then
            return;
         end if;

         Item.Entries.Append (Element);
         Item.Metadata_Map.Insert (Key, Natural (Item.Entries.Length));
      end;
   end Take_Entry;

   -----------------------------------------------------------------------
   --  Tensor descriptors
   -----------------------------------------------------------------------

   --  Read one tensor descriptor and validate everything that does not need
   --  the data-section offset, which is not known until all descriptors have
   --  been read.
   procedure Take_Tensor
     (Source : in out Model_Runner.Byte_Sources.Source'Class;
      Item   : in out Container;
      Cursor : in out State;
      Status : out E.Error_Info)
   is
      Origin  : constant B.Byte_Count := Cursor.Cursor;
      Element : Tensor_Entry;
      Rank    : Interfaces.Unsigned_32;
      Code    : Interfaces.Unsigned_32;
      Known   : Boolean;
      Total   : A.Checked := A.To_Checked (Interfaces.Unsigned_64'(1));
   begin
      Take_String (Source, Item, Cursor, Element.Name, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Name : constant String := Pool_Text (Item, Element.Name);
      begin
         if Name = "" then
            Status := At_Offset (E.GGUF_Empty_Tensor_Name, Origin);
            return;
         end if;

         if Item.Tensor_Map.Contains (Name) then
            Status := At_Offset (E.GGUF_Duplicate_Tensor_Name, Origin);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            return;
         end if;

         Take_U32 (Source, Cursor, Rank, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         if Rank = 0
           or else Rank > Interfaces.Unsigned_32 (Max_Rank)
           or else Rank > Interfaces.Unsigned_32 (Item.Bounds.Max_Tensor_Rank)
         then
            Status := At_Offset (E.GGUF_Invalid_Tensor_Rank, Origin);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "rank", Long_Long_Integer (Rank));
            return;
         end if;

         Element.Rank := Positive (Rank);
         Element.Dimensions := [others => 1];

         for Axis in 1 .. Element.Rank loop
            declare
               Extent : Interfaces.Unsigned_64;
            begin
               Take_U64 (Source, Cursor, Extent, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               if Extent = 0 then
                  Status := At_Offset (E.GGUF_Invalid_Tensor_Dimension, Origin);
                  E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
                  E.Add_Integer (Status, "axis", Long_Long_Integer (Axis));
                  return;
               end if;

               Element.Dimensions (Axis) := Extent;
               Total := Total * A.To_Checked (Extent);
            end;
         end loop;

         if not A.Is_Valid (Total) then
            Status := At_Offset (E.GGUF_Arithmetic_Overflow, Origin);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            return;
         end if;

         Element.Elements := A.Value (Total);

         if Element.Elements > Item.Bounds.Max_Tensor_Elements then
            Status := At_Offset (E.GGUF_Invalid_Tensor_Dimension, Origin);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer
              (Status, "elements", Long_Long_Integer (Element.Elements));
            E.Add_Integer
              (Status, "limit",
               Long_Long_Integer (Item.Bounds.Max_Tensor_Elements));
            return;
         end if;

         Take_U32 (Source, Cursor, Code, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Element.Format := To_Tensor_Type (Code, Known);
         if not Known then
            Status := At_Offset (E.GGUF_Unknown_Tensor_Type, Origin);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "code", Long_Long_Integer (Code));
            return;
         end if;

         --  The contiguous dimension has to hold whole quantization blocks.
         --  This is a structural property of the container and is checked here
         --  even for formats this crate does not execute.
         if not Divides_Into_Blocks (Element.Format, Element.Dimensions (1)) then
            Status := At_Offset (E.GGUF_Block_Misalignment, Origin);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Text
              (Status, "format", Type_Name (Element.Format), E.Param_Identifier);
            E.Add_Integer
              (Status, "dimension",
               Long_Long_Integer (Element.Dimensions (1)));
            E.Add_Integer
              (Status, "block",
               Long_Long_Integer (Block_Elements (Element.Format)));
            return;
         end if;

         declare
            Blocks : constant A.Checked :=
              A.To_Checked (Element.Elements)
              / A.To_Checked (Block_Elements (Element.Format));
            Size   : constant A.Checked :=
              Blocks * A.To_Checked (Block_Bytes (Element.Format));
         begin
            if not A.Is_Valid (Size) then
               Status := At_Offset (E.GGUF_Arithmetic_Overflow, Origin);
               E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
               return;
            end if;

            Element.Size := A.Value (Size);

            if Element.Size > Item.Bounds.Max_Tensor_Bytes then
               Status := At_Offset (E.GGUF_Invalid_Tensor_Dimension, Origin);
               E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
               E.Add_Integer
                 (Status, "size", Long_Long_Integer (Element.Size),
                  E.Param_Bytes);
               return;
            end if;
         end;

         Take_U64 (Source, Cursor, Element.Relative, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         Item.Tensors.Append (Element);
         Item.Tensor_Map.Insert (Name, Natural (Item.Tensors.Length));
      end;
   end Take_Tensor;

   -----------------------------------------------------------------------
   --  Whole-container validation
   -----------------------------------------------------------------------

   --  Resolve the data-section alignment from general.alignment.
   procedure Resolve_Alignment
     (Item   : in out Container;
      Status : out E.Error_Info)
   is
      Index : constant Natural := Find (Item, "general.alignment");
   begin
      Status := E.Success;
      Item.Align := Default_Alignment;

      if Index = 0 then
         return;
      end if;

      declare
         Found : Metadata_Entry renames Item.Entries (Index);
      begin
         if not Is_Integer (Found.Kind) then
            Status := E.Make (E.GGUF_Metadata_Type_Mismatch);
            E.Add_Text (Status, "key", "general.alignment", E.Param_Identifier);
            E.Add_Text (Status, "expected", "integer", E.Param_Identifier);
            return;
         end if;

         if Found.Signed <= 0
           or else not A.Is_Power_Of_Two (Interfaces.Unsigned_64 (Found.Signed))
           or else Found.Signed > 65_536
         then
            Status := E.Make (E.GGUF_Invalid_Alignment);
            E.Add_Integer (Status, "alignment", Found.Signed);
            return;
         end if;

         Item.Align := Interfaces.Unsigned_64 (Found.Signed);
      end;
   end Resolve_Alignment;

   --  Compute each tensor's absolute range and check it against the file, then
   --  check that no two ranges overlap.
   procedure Validate_Ranges
     (Item   : in out Container;
      Status : out E.Error_Info)
   is
      Count   : constant Natural := Natural (Item.Tensors.Length);
      Highest : Interfaces.Unsigned_64 := Item.Data_Start;
      Order   : array (1 .. Count) of Natural;
   begin
      Status := E.Success;

      for Index in 1 .. Count loop
         declare
            Element : Tensor_Entry := Item.Tensors (Index);
            Start   : constant A.Checked :=
              A.To_Checked (Item.Data_Start) + A.To_Checked (Element.Relative);
            Finish  : constant A.Checked := Start + A.To_Checked (Element.Size);
         begin
            if not A.Is_Valid (Finish) then
               Status := E.Make (E.GGUF_Arithmetic_Overflow);
               E.Add_Text
                 (Status, "tensor", Pool_Text (Item, Element.Name),
                  E.Param_Identifier);
               return;
            end if;

            --  Each tensor starts at an aligned offset within the data
            --  section. A writer that violates this produces a file whose
            --  tensors cannot be read with the alignment guarantees the
            --  kernels rely on.
            if Element.Relative mod Item.Align /= 0 then
               Status := E.Make (E.GGUF_Tensor_Offset_Misaligned);
               E.Add_Text
                 (Status, "tensor", Pool_Text (Item, Element.Name),
                  E.Param_Identifier);
               E.Add_Integer
                 (Status, "offset", Long_Long_Integer (Element.Relative),
                  E.Param_Offset);
               E.Add_Integer
                 (Status, "alignment", Long_Long_Integer (Item.Align));
               return;
            end if;

            if A.Value (Finish) > Item.Total_Size then
               Status := E.Make (E.GGUF_Tensor_Out_Of_Bounds);
               E.Add_Text
                 (Status, "tensor", Pool_Text (Item, Element.Name),
                  E.Param_Identifier);
               E.Add_Integer
                 (Status, "offset", Long_Long_Integer (A.Value (Start)),
                  E.Param_Offset);
               E.Add_Integer
                 (Status, "size", Long_Long_Integer (Element.Size),
                  E.Param_Bytes);
               E.Add_Integer
                 (Status, "file_size", Long_Long_Integer (Item.Total_Size),
                  E.Param_Bytes);
               return;
            end if;

            Element.Absolute := A.Value (Start);
            Item.Tensors.Replace_Element (Index, Element);

            if A.Value (Finish) > Highest then
               Highest := A.Value (Finish);
            end if;
         end;
      end loop;

      --  Sort descriptor positions by absolute offset with an insertion sort.
      --  Tensor counts are bounded by Max_Tensors and descriptors are already
      --  nearly ordered in practice, so the quadratic worst case is bounded
      --  and never reached for a well-formed file.
      for Index in 1 .. Count loop
         Order (Index) := Index;
      end loop;

      for Index in 2 .. Count loop
         declare
            Current : constant Natural := Order (Index);
            Probe   : Natural := Index - 1;
         begin
            while Probe >= 1
              and then Item.Tensors (Order (Probe)).Absolute
                       > Item.Tensors (Current).Absolute
            loop
               Order (Probe + 1) := Order (Probe);
               Probe := Probe - 1;
            end loop;
            Order (Probe + 1) := Current;
         end;
      end loop;

      for Index in 2 .. Count loop
         declare
            Previous : Tensor_Entry renames Item.Tensors (Order (Index - 1));
            Current  : Tensor_Entry renames Item.Tensors (Order (Index));
         begin
            if Previous.Absolute + Previous.Size > Current.Absolute then
               Status := E.Make (E.GGUF_Tensor_Overlap);
               E.Add_Text
                 (Status, "tensor", Pool_Text (Item, Current.Name),
                  E.Param_Identifier);
               E.Add_Text
                 (Status, "other", Pool_Text (Item, Previous.Name),
                  E.Param_Identifier);
               E.Add_Integer
                 (Status, "offset", Long_Long_Integer (Current.Absolute),
                  E.Param_Offset);
               return;
            end if;
         end;
      end loop;

      Item.Data_Bytes :=
        (if Highest >= Item.Data_Start then Highest - Item.Data_Start else 0);

      if not Item.Bounds.Allow_Trailing_Data
        and then Highest < Item.Total_Size
      then
         Status := E.Make (E.GGUF_Trailing_Data);
         E.Add_Integer
           (Status, "offset", Long_Long_Integer (Highest), E.Param_Offset);
         E.Add_Integer
           (Status, "extra", Long_Long_Integer (Item.Total_Size - Highest),
            E.Param_Bytes);
      end if;
   end Validate_Ranges;

   -----------
   -- Parse --
   -----------

   procedure Parse
     (Item     : in out Container;
      Source   : in out Model_Runner.Byte_Sources.Source'Class;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null;
      Status   : out E.Error_Info)
   is
      Cursor         : State;
      Magic_Value    : Interfaces.Unsigned_32;
      Version_Value  : Interfaces.Unsigned_32;
      Tensor_Total   : Interfaces.Unsigned_64;
      Metadata_Total : Interfaces.Unsigned_64;

      --  Abandon the parse, releasing everything acquired so far.
      procedure Fail (Reason : E.Error_Info) is
      begin
         Close (Item);
         Status := Reason;
      end Fail;

      --  Report cancellation between sections.
      function Cancelled return Boolean is (C.Is_Cancelled (Cancel));

   begin
      Close (Item);
      Item.Bounds := Bounds;
      Item.Total_Size := Interfaces.Unsigned_64 (Source.Size);
      Cursor.Size := Source.Size;
      Cursor.Cursor := 0;
      Status := E.Success;

      P.Publish (Observer, P.Load_Progress (P.Reading_Header));

      Take_U32 (Source, Cursor, Magic_Value, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      if Magic_Value /= Magic then
         Fail (At_Offset (E.GGUF_Invalid_Magic, 0));
         return;
      end if;

      Take_U32 (Source, Cursor, Version_Value, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      if Version_Value < Minimum_Version or else Version_Value > Maximum_Version
      then
         declare
            Reason : E.Error_Info := At_Offset (E.GGUF_Unsupported_Version, 4);
         begin
            E.Add_Integer (Reason, "version", Long_Long_Integer (Version_Value));
            E.Add_Integer
              (Reason, "minimum", Long_Long_Integer (Minimum_Version));
            E.Add_Integer
              (Reason, "maximum", Long_Long_Integer (Maximum_Version));
            Fail (Reason);
            return;
         end;
      end if;

      Item.Format := Version_Value;

      Take_U64 (Source, Cursor, Tensor_Total, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      Take_U64 (Source, Cursor, Metadata_Total, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      if Tensor_Total > Interfaces.Unsigned_64 (Bounds.Max_Tensors) then
         declare
            Reason : E.Error_Info :=
              At_Offset (E.GGUF_Tensor_Count_Too_Large, 8);
         begin
            E.Add_Integer (Reason, "count", Long_Long_Integer (Tensor_Total));
            E.Add_Integer
              (Reason, "limit", Long_Long_Integer (Bounds.Max_Tensors));
            Fail (Reason);
            return;
         end;
      end if;

      if Metadata_Total
        > Interfaces.Unsigned_64 (Bounds.Max_Metadata_Entries)
      then
         declare
            Reason : E.Error_Info :=
              At_Offset (E.GGUF_Metadata_Count_Too_Large, 16);
         begin
            E.Add_Integer (Reason, "count", Long_Long_Integer (Metadata_Total));
            E.Add_Integer
              (Reason, "limit",
               Long_Long_Integer (Bounds.Max_Metadata_Entries));
            Fail (Reason);
            return;
         end;
      end if;

      P.Publish
        (Observer, P.Load_Progress (P.Reading_Metadata, 0, Metadata_Total));

      for Index in 1 .. Natural (Metadata_Total) loop
         if Cancelled then
            Fail (E.Make (E.Generation_Cancelled));
            return;
         end if;

         Take_Entry (Source, Item, Cursor, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         if Index mod 64 = 0 then
            P.Publish
              (Observer,
               P.Load_Progress
                 (P.Reading_Metadata,
                  Interfaces.Unsigned_64 (Index), Metadata_Total));
         end if;
      end loop;

      P.Publish
        (Observer,
         P.Load_Progress (P.Reading_Tensor_Descriptors, 0, Tensor_Total));

      for Index in 1 .. Natural (Tensor_Total) loop
         if Cancelled then
            Fail (E.Make (E.Generation_Cancelled));
            return;
         end if;

         Take_Tensor (Source, Item, Cursor, Status);
         if E.Is_Error (Status) then
            Fail (Status);
            return;
         end if;

         if Index mod 256 = 0 then
            P.Publish
              (Observer,
               P.Load_Progress
                 (P.Reading_Tensor_Descriptors,
                  Interfaces.Unsigned_64 (Index), Tensor_Total));
         end if;
      end loop;

      P.Publish (Observer, P.Load_Progress (P.Validating_Model));

      Resolve_Alignment (Item, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      declare
         Aligned : constant A.Checked :=
           A.Align_Up
             (A.To_Checked (Interfaces.Unsigned_64 (Cursor.Cursor)), Item.Align);
      begin
         if not A.Is_Valid (Aligned)
           or else A.Value (Aligned) > Item.Total_Size
         then
            Fail (At_Offset (E.GGUF_Truncated, Cursor.Cursor));
            return;
         end if;
         Item.Data_Start := A.Value (Aligned);
      end;

      if Cancelled then
         Fail (E.Make (E.Generation_Cancelled));
         return;
      end if;

      Validate_Ranges (Item, Status);
      if E.Is_Error (Status) then
         Fail (Status);
         return;
      end if;

      Item.Valid := True;
      Status := E.Success;
   exception
      --  A malformed file must never escape as an exception. Anything that
      --  reaches here is a defect in this package, reported as an internal
      --  invariant violation with the container released.
      when Occurrence : others =>
         Close (Item);
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "gguf.parse");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Parse;

end Model_Runner.GGUF.Containers.Reader;
