with System.Storage_Elements;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Zlib;

package body Model_Runner.PNG_Writer is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;

   use type Interfaces.Unsigned_32;
   use type B.Byte_Count;
   use type B.Byte;
   use type B.Byte_Array;
   use type Zlib.Status_Code;

   type CRC_Table is array (B.Byte) of Interfaces.Unsigned_32;

   --  The chunk checksum's table: CRC-32, the polynomial reflected.
   function Table_Of return CRC_Table is
      Result : CRC_Table;
   begin
      for N in B.Byte loop
         declare
            C : Interfaces.Unsigned_32 := Interfaces.Unsigned_32 (N);
         begin
            for K in 1 .. 8 loop
               C := (if (C and 1) = 1 then 16#EDB8_8320# xor Interfaces.Shift_Right (C, 1)
                     else Interfaces.Shift_Right (C, 1));
            end loop;
            Result (N) := C;
         end;
      end loop;
      return Result;
   end Table_Of;

   Table : constant CRC_Table := Table_Of;

   type Raw_Access is access Zlib.Byte_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Zlib.Byte_Array, Raw_Access);

   --  Encode's work, on whatever stack it is given.
   procedure Encode_Here
     (Width    : Positive;
      Height   : Positive;
      Channels : Channel_Count;
      Pixels   : B.Byte_Array;
      Result   : out B.Byte_Array_Access;
      Status   : out E.Error_Info);

   procedure Encode
     (Width    : Positive;
      Height   : Positive;
      Channels : Channel_Count;
      Pixels   : B.Byte_Array;
      Result   : out B.Byte_Array_Access;
      Status   : out E.Error_Info)
   is
      --  On a stack of its own, sized to the picture: the zlib crate's
      --  deflate builds arrays as large as its input on the stack, and a
      --  picture of 1536 on a side -- 9.4 MB of pixels -- overflowed the
      --  8 MB a process starts with.
      task type Encoder (Stack : System.Storage_Elements.Storage_Count) with Storage_Size => Stack;

      task body Encoder is
      begin
         Encode_Here (Width, Height, Channels, Pixels, Result, Status);
      exception
         when others =>
            Result := null;
            Status := E.Make (E.Memory_Allocation_Failed);
      end Encoder;
   begin
      Result := null;
      Status := E.Success;
      declare
         Worker : Encoder
           (System.Storage_Elements.Storage_Count (Long_Long_Integer (Pixels'Length) * 8 + 16 * 1024 ** 2));
         pragma Unreferenced (Worker);
      begin
         null;
      end;
   end Encode;

   procedure Encode_Here
     (Width    : Positive;
      Height   : Positive;
      Channels : Channel_Count;
      Pixels   : B.Byte_Array;
      Result   : out B.Byte_Array_Access;
      Status   : out E.Error_Info)
   is
      Row : constant Natural := Width * Channels;
   begin
      Result := null;
      if Long_Long_Integer (Width) * Long_Long_Integer (Height) > Max_Pixels
        or else Pixels'Length /= B.Byte_Count (Row) * B.Byte_Count (Height)
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      declare
         --  Each row behind its filter byte, one: Sub, each byte less the
         --  same channel's of the pixel to its left -- which a picture's
         --  smooth runs make small and alike -- deflated with the fixed
         --  codes. A 1024 picture so: 1.76 MB in 0.36 s, where unfiltered
         --  through dynamic codes it was 2.13 MB in 2.13 s; Sub through
         --  dynamic codes is 1.26 MB in 7 s. On the heap: a picture 4096 on
         --  a side is 64 MB of it.
         Raw : Raw_Access := new Zlib.Byte_Array (0 .. (Row + 1) * Height - 1);
      begin
         for Y in 0 .. Height - 1 loop
            Raw (Y * (Row + 1)) := 1;
            for X in 0 .. Row - 1 loop
               declare
                  Here : constant Integer := Integer (Pixels (Pixels'First + B.Byte_Count (Y * Row + X)));
                  Left : constant Integer :=
                    (if X < Channels then 0
                     else Integer (Pixels (Pixels'First + B.Byte_Count (Y * Row + X - Channels))));
               begin
                  Raw (Y * (Row + 1) + 1 + X) := Zlib.Byte ((Here - Left) mod 256);
               end;
            end loop;
         end loop;
         declare
            Done      : Zlib.Status_Code;
            Deflated  : constant Zlib.Byte_Array := Zlib.Deflate (Raw.all, 1, Done);
            Signature : constant B.Byte_Array (1 .. 8) := [137, 80, 78, 71, 13, 10, 26, 10];
            --  Signature, then the three chunks, each twelve bytes beside its
            --  data: IHDR's thirteen, the image's, IEND's none.
            Total     : constant B.Byte_Count :=
              8 + (12 + 13) + (12 + B.Byte_Count (Deflated'Length)) + 12;
            At_Byte   : B.Byte_Count;

            procedure Put (Value : B.Byte) is
            begin
               Result (At_Byte) := Value;
               At_Byte := At_Byte + 1;
            end Put;

            procedure Put_Word (Value : Interfaces.Unsigned_32) is
            begin
               for Shift in reverse 0 .. 3 loop
                  Put (B.Byte (Interfaces.Shift_Right (Value, 8 * Shift) and 16#FF#));
               end loop;
            end Put_Word;

            --  A chunk: its length, its type and data, their checksum.
            procedure Chunk (Kind : String; Data : B.Byte_Array) is
               Sum   : Interfaces.Unsigned_32 := 16#FFFF_FFFF#;
               Begun : B.Byte_Count;
            begin
               Put_Word (Interfaces.Unsigned_32 (Data'Length));
               Begun := At_Byte;
               for C of Kind loop
                  Put (B.Byte (Character'Pos (C)));
               end loop;
               for D of Data loop
                  Put (D);
               end loop;
               for Index in Begun .. At_Byte - 1 loop
                  Sum := Table (B.Byte (Sum and 16#FF#) xor Result (Index)) xor Interfaces.Shift_Right (Sum, 8);
               end loop;
               Put_Word (Sum xor 16#FFFF_FFFF#);
            end Chunk;

            function Word (Value : Natural) return B.Byte_Array
            is ([B.Byte (Value / 2 ** 24 mod 256), B.Byte (Value / 2 ** 16 mod 256), B.Byte (Value / 2 ** 8 mod 256),
                 B.Byte (Value mod 256)]);
         begin
            if Done /= Zlib.Ok then
               Free (Raw);
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
            Free (Raw);
            Result := new B.Byte_Array (1 .. Total);
            At_Byte := Result'First;
            for S of Signature loop
               Put (S);
            end loop;
            --  Eight bits a channel, colour type 6 with alpha and 2 without,
            --  deflate, adaptive filtering, no interlace.
            Chunk ("IHDR", Word (Width) & Word (Height) & [8, (if Channels = 4 then 6 else 2), 0, 0, 0]);
            declare
               Data : B.Byte_Array (1 .. B.Byte_Count (Deflated'Length));
            begin
               for Index in Data'Range loop
                  Data (Index) := B.Byte (Deflated (Deflated'First + Natural (Index - 1)));
               end loop;
               Chunk ("IDAT", Data);
            end;
            Chunk ("IEND", [1 .. 0 => 0]);
         end;
      end;
      Status := E.Success;
   end Encode_Here;

   function Numbered (Path : String; Index : Positive; Count : Positive) return String is
      Dot   : Natural := 0;
      Image : constant String := Index'Image;
   begin
      if Count = 1 then
         return Path;
      end if;
      for At_Char in reverse Path'Range loop
         exit when Path (At_Char) = '/';
         if Path (At_Char) = '.' then
            Dot := At_Char;
            exit;
         end if;
      end loop;
      return (if Dot = 0 then Path & "-" & Image (2 .. Image'Last)
              else Path (Path'First .. Dot - 1) & "-" & Image (2 .. Image'Last) & Path (Dot .. Path'Last));
   end Numbered;

end Model_Runner.PNG_Writer;
