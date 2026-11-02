with Ada.Directories;
with Ada.Numerics;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Conversion;
with Interfaces;

package body Model_Runner.Audio is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;

   subtype Wide_Real is N.Wide_Real;

   package Elementary is new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type Ada.Directories.File_Size;
   use type Ada.Streams.Stream_Element_Offset;
   use type Wide_Real;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type T.Real_Array_Access;

   function To_Float_32 is new Ada.Unchecked_Conversion (Interfaces.Unsigned_32, Interfaces.IEEE_Float_32);
   function To_Float_64 is new Ada.Unchecked_Conversion (Interfaces.Unsigned_64, Interfaces.IEEE_Float_64);

   --  The largest WAV file read whole: two gigabytes, which is more than
   --  three hours of the largest sample this reads in stereo.
   Max_File_Bytes : constant := 2 ** 31;

   procedure Refuse (Status : out E.Error_Info; Detail : String) is
   begin
      Status := E.Make (E.IO_Audio_Unreadable);
      E.Add_Text (Status, "detail", Detail, E.Param_Identifier);
   end Refuse;

   -----------------
   -- Read_Header --
   -----------------

   procedure Read_Header
     (Data   : B.Byte_Array;
      Header : out Wave_Header;
      Status : out E.Error_Info)
   is
      Ok, Ok2 : Boolean := True;
      At_Byte : B.Byte_Count := 12;
      Seen_Format : Boolean := False;
      Format_Tag  : Interfaces.Unsigned_16 := 0;
      Block_Align : Interfaces.Unsigned_16 := 0;

      function Tag (Offset : B.Byte_Count) return String is
        (if B.Has_Room (Data, Offset, 4)
         then B.To_String (Data (Data'First + Offset .. Data'First + Offset + 3))
         else "");
   begin
      Header := (others => <>);
      Status := E.Success;
      if Tag (0) /= "RIFF" or else Tag (8) /= "WAVE" then
         Refuse (Status, "not a RIFF WAVE file");
         return;
      end if;

      --  The chunks in order; the format must come before the data, as
      --  the format requires.
      loop
         if not B.Has_Room (Data, At_Byte, 8) then
            Refuse (Status, "no data chunk");
            return;
         end if;
         declare
            Name   : constant String := Tag (At_Byte);
            Length : constant B.Byte_Count := B.Byte_Count (B.Get_U32 (Data, At_Byte + 4, Ok));
            Body_At : constant B.Byte_Count := At_Byte + 8;
         begin
            if Name = "fmt " then
               if Length < 16 or else not B.Has_Room (Data, Body_At, 16) then
                  Refuse (Status, "format chunk too short");
                  return;
               end if;
               Format_Tag := B.Get_U16 (Data, Body_At, Ok);
               declare
                  Channels : constant Interfaces.Unsigned_16 := B.Get_U16 (Data, Body_At + 2, Ok);
                  Rate     : constant Interfaces.Unsigned_32 := B.Get_U32 (Data, Body_At + 4, Ok);
                  Bits     : constant Interfaces.Unsigned_16 := B.Get_U16 (Data, Body_At + 14, Ok);
               begin
                  Block_Align := B.Get_U16 (Data, Body_At + 12, Ok);
                  --  The extensible header names the encoding by the first
                  --  two bytes of its subformat's identifier.
                  if Format_Tag = 16#FFFE# then
                     if Length < 40 or else not B.Has_Room (Data, Body_At, 40) then
                        Refuse (Status, "extensible format chunk too short");
                        return;
                     end if;
                     Format_Tag := B.Get_U16 (Data, Body_At + 24, Ok2);
                  end if;
                  if Format_Tag = 1 then
                     Header.Kind := Integer_PCM;
                     if Bits not in 8 | 16 | 24 | 32 then
                        Refuse (Status, "integer samples of" & Bits'Image & " bits");
                        return;
                     end if;
                  elsif Format_Tag = 3 then
                     Header.Kind := Float_PCM;
                     if Bits not in 32 | 64 then
                        Refuse (Status, "float samples of" & Bits'Image & " bits");
                        return;
                     end if;
                  else
                     Refuse (Status, "encoding" & Format_Tag'Image & " is compressed or unknown");
                     return;
                  end if;
                  if Channels = 0 or else Channels > Max_Channels then
                     Refuse (Status, Channels'Image & " channels");
                     return;
                  end if;
                  if Rate < Min_Rate or else Rate > Max_Rate then
                     Refuse (Status, "a rate of" & Rate'Image & " Hz");
                     return;
                  end if;
                  if Natural (Block_Align) /= Natural (Channels) * Natural (Bits) / 8 then
                     Refuse (Status, "a block of" & Block_Align'Image & " bytes");
                     return;
                  end if;
                  Header.Channels := Positive (Channels);
                  Header.Rate := Positive (Rate);
                  Header.Bits := Positive (Bits);
                  Seen_Format := True;
               end;
            elsif Name = "data" then
               if not Seen_Format then
                  Refuse (Status, "data before its format");
                  return;
               end if;
               --  A length past the file's end -- what a recorder writes
               --  when it is stopped before it can say -- is taken as the
               --  file's end, whole frames only.
               declare
                  Held : constant B.Byte_Count :=
                    B.Byte_Count'Min (Length, B.Byte_Count (Data'Length) - Body_At);
                  Frame : constant B.Byte_Count := B.Byte_Count (Block_Align);
               begin
                  Header.Data_At := Body_At;
                  Header.Data_Length := Held / Frame * Frame;
                  Header.Frames := Element_Count (Held / Frame);
               end;
               return;
            end if;
            --  Chunks are padded to even lengths.
            At_Byte := Body_At + Length + Length mod 2;
         end;
      end loop;
   end Read_Header;

   ----------------------
   -- Resampled_Length --
   ----------------------

   function Resampled_Length
     (Count : Element_Count; From_Rate, To_Rate : Positive) return Element_Count
   is (if From_Rate = To_Rate then Count
       else (Count * Element_Count (To_Rate) + Element_Count (From_Rate) - 1) / Element_Count (From_Rate));

   --  The interpolating filter: a sinc windowed by Kaiser's window, tabled
   --  finely over its half and read between table points by a line.
   Zero_Crossings : constant := 16;
   Steps_Per_Unit : constant := 512;
   Kaiser_Beta    : constant Wide_Real := 9.0;
   Cutoff         : constant Wide_Real := 0.97;

   type Filter_Table is array (0 .. Zero_Crossings * Steps_Per_Unit + 1) of Wide_Real;

   --  The modified Bessel function of the first kind, order zero.
   function Bessel_I0 (X : Wide_Real) return Wide_Real is
      Sum  : Wide_Real := 1.0;
      Term : Wide_Real := 1.0;
      Half : constant Wide_Real := X / 2.0;
   begin
      for K in 1 .. 60 loop
         Term := Term * (Half / Wide_Real (K)) ** 2;
         Sum := Sum + Term;
         exit when Term < Sum * 1.0E-17;
      end loop;
      return Sum;
   end Bessel_I0;

   function Make_Filter return Filter_Table is
      Result : Filter_Table;
      Norm   : constant Wide_Real := Bessel_I0 (Kaiser_Beta);
   begin
      for I in Filter_Table'Range loop
         declare
            U : constant Wide_Real := Wide_Real (I) / Wide_Real (Steps_Per_Unit);
            R : constant Wide_Real := U / Wide_Real (Zero_Crossings);
            Sinc : constant Wide_Real :=
              (if I = 0 then 1.0 else Elementary.Sin (Ada.Numerics.Pi * U) / (Ada.Numerics.Pi * U));
         begin
            Result (I) :=
              (if R >= 1.0 then 0.0
               else Sinc * Bessel_I0 (Kaiser_Beta * Elementary.Sqrt (1.0 - R * R)) / Norm);
         end;
      end loop;
      return Result;
   end Make_Filter;

   Filter : constant Filter_Table := Make_Filter;

   --  The filter at U zero crossings from its centre.
   function Kernel (U : Wide_Real) return Wide_Real is
      A : constant Wide_Real := abs U * Wide_Real (Steps_Per_Unit);
      I : constant Integer := Integer (Wide_Real'Floor (A));
      F : constant Wide_Real := A - Wide_Real (I);
   begin
      if I >= Zero_Crossings * Steps_Per_Unit then
         return 0.0;
      end if;
      return Filter (I) + (Filter (I + 1) - Filter (I)) * F;
   end Kernel;

   --------------
   -- Resample --
   --------------

   procedure Resample
     (Input     : Real_Array;
      From_Rate : Positive;
      To_Rate   : Positive;
      Output    : out Real_Array)
   is
      --  The pass band, in cycles a sample of the input: under the lower of
      --  the two Nyquist rates, so a rate brought down does not alias.
      Band  : constant Wide_Real :=
        Cutoff * Wide_Real'Min (1.0, Wide_Real (To_Rate) / Wide_Real (From_Rate));
      Reach : constant Integer := Integer (Wide_Real'Ceiling (Wide_Real (Zero_Crossings) / Band));
      Step  : constant Wide_Real := Wide_Real (From_Rate) / Wide_Real (To_Rate);
   begin
      if From_Rate = To_Rate then
         Output := Input;
         return;
      end if;
      for O in 0 .. Element_Count (Output'Length) - 1 loop
         declare
            Centre : constant Wide_Real := Wide_Real (O) * Step;
            Base   : constant Long_Long_Integer := Long_Long_Integer (Wide_Real'Floor (Centre));
            Count  : constant Long_Long_Integer := Long_Long_Integer (Input'Length);
            Sum    : Wide_Real := 0.0;
         begin
            for K in Long_Long_Integer'Max (Base - Long_Long_Integer (Reach) + 1, 0)
              .. Long_Long_Integer'Min (Base + Long_Long_Integer (Reach), Count - 1)
            loop
               Sum := Sum + Wide_Real (Input (Input'First + Element_Count (K)))
                 * Band * Kernel ((Wide_Real (K) - Centre) * Band);
            end loop;
            Output (Output'First + O) := Real (Sum);
         end;
      end loop;
   end Resample;

   -------------------
   -- Mix_Signed_16 --
   -------------------

   procedure Mix_Signed_16
     (Data     : B.Byte_Array;
      Channels : Positive;
      Output   : out Real_Array)
   is
      Ok : Boolean;
   begin
      for F in 0 .. Element_Count (Output'Length) - 1 loop
         declare
            Sum : Wide_Real := 0.0;
         begin
            for C in 0 .. Channels - 1 loop
               declare
                  Raw : constant Interfaces.Unsigned_16 :=
                    B.Get_U16 (Data, B.Byte_Count ((F * Element_Count (Channels) + Element_Count (C)) * 2), Ok);
                  Value : constant Integer :=
                    (if Raw >= 16#8000# then Integer (Raw) - 16#1_0000# else Integer (Raw));
               begin
                  Sum := Sum + Wide_Real (Value);
               end;
            end loop;
            Output (Output'First + F) := Real (Sum / Wide_Real (Channels) / 32_768.0);
         end;
      end loop;
   end Mix_Signed_16;

   -----------------
   -- Decode_Wave --
   -----------------

   procedure Decode_Wave
     (Data        : B.Byte_Array;
      Max_Seconds : Positive;
      Samples     : out T.Real_Array_Access;
      Status      : out E.Error_Info)
   is
      Header : Wave_Header;
      Mixed  : T.Real_Array_Access;
      Ok     : Boolean;
   begin
      Samples := null;
      Read_Header (Data, Header, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if Header.Frames > Element_Count (Max_Seconds) * Element_Count (Header.Rate) then
         Status := E.Make (E.IO_Audio_Too_Long);
         E.Add_Integer (Status, "count", Long_Long_Integer (Header.Frames / Element_Count (Header.Rate)));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Seconds));
         return;
      end if;
      if Header.Frames = 0 then
         Refuse (Status, "no samples");
         return;
      end if;

      T.Allocate (Header.Frames, Mixed);
      if Mixed = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      declare
         Width : constant B.Byte_Count := B.Byte_Count (Header.Bits / 8);
      begin
         for F in 0 .. Header.Frames - 1 loop
            declare
               Sum : Wide_Real := 0.0;
            begin
               for C in 0 .. Header.Channels - 1 loop
                  declare
                     At_Byte : constant B.Byte_Count :=
                       Header.Data_At + (B.Byte_Count (F) * B.Byte_Count (Header.Channels) + B.Byte_Count (C)) * Width;
                     Value : Wide_Real;
                  begin
                     case Header.Kind is
                        when Integer_PCM =>
                           case Header.Bits is
                              when 8 =>
                                 Value := (Wide_Real (B.Get_U8 (Data, At_Byte, Ok)) - 128.0) / 128.0;
                              when 16 =>
                                 declare
                                    Raw : constant Interfaces.Unsigned_16 := B.Get_U16 (Data, At_Byte, Ok);
                                 begin
                                    Value := (if Raw >= 16#8000# then Wide_Real (Raw) - 65_536.0
                                              else Wide_Real (Raw)) / 32_768.0;
                                 end;
                              when 24 =>
                                 declare
                                    Low  : constant Interfaces.Unsigned_16 := B.Get_U16 (Data, At_Byte, Ok);
                                    High : constant Interfaces.Unsigned_8 := B.Get_U8 (Data, At_Byte + 2, Ok);
                                    Raw  : constant Interfaces.Unsigned_32 :=
                                      Interfaces.Unsigned_32 (Low) + Interfaces.Unsigned_32 (High) * 65_536;
                                 begin
                                    Value := (if Raw >= 16#80_0000# then Wide_Real (Raw) - 16_777_216.0
                                              else Wide_Real (Raw)) / 8_388_608.0;
                                 end;
                              when others =>
                                 declare
                                    Raw : constant Interfaces.Unsigned_32 := B.Get_U32 (Data, At_Byte, Ok);
                                 begin
                                    Value := (if Raw >= 16#8000_0000# then Wide_Real (Raw) - 4_294_967_296.0
                                              else Wide_Real (Raw)) / 2_147_483_648.0;
                                 end;
                           end case;
                        when Float_PCM =>
                           if Header.Bits = 32 then
                              Value := Wide_Real (To_Float_32 (B.Get_U32 (Data, At_Byte, Ok)));
                           else
                              Value := Wide_Real (To_Float_64 (B.Get_U64 (Data, At_Byte, Ok)));
                           end if;
                           --  A float sample is its value; one that is no
                           --  number, or past full scale, is held to it.
                           if not (Value = Value) then
                              Value := 0.0;
                           end if;
                           Value := Wide_Real'Max (-1.0, Wide_Real'Min (1.0, Value));
                     end case;
                     Sum := Sum + Value;
                  end;
               end loop;
               Mixed (F) := Real (Sum / Wide_Real (Header.Channels));
            end;
         end loop;
      end;

      if Header.Rate = Canonical_Rate then
         Samples := Mixed;
         return;
      end if;

      T.Allocate (Resampled_Length (Header.Frames, Header.Rate, Canonical_Rate), Samples);
      if Samples = null then
         T.Free (Mixed);
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      Resample (Mixed.all, Header.Rate, Canonical_Rate, Samples.all);
      T.Free (Mixed);
   end Decode_Wave;

   ---------------
   -- Read_Wave --
   ---------------

   procedure Read_Wave
     (Path        : String;
      Max_Seconds : Positive;
      Samples     : out T.Real_Array_Access;
      Status      : out E.Error_Info)
   is
      use Ada.Streams.Stream_IO;
      File : File_Type;
      Data : B.Byte_Array_Access;
      Size : Ada.Directories.File_Size;
   begin
      Samples := null;
      begin
         Size := Ada.Directories.Size (Path);
      exception
         when others =>
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            return;
      end;
      if Size > Max_File_Bytes then
         Status := E.Make (E.IO_File_Too_Large);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Integer (Status, "size", Long_Long_Integer (Size));
         E.Add_Integer (Status, "limit", Max_File_Bytes);
         return;
      end if;
      B.Allocate (B.Byte_Count (Size), Data);
      if Data = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      begin
         Open (File, In_File, Path, Form => "shared=no");
         declare
            Buffer : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Size))
              with Import, Address => Data.all'Address;
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            Read (File, Buffer, Last);
            Close (File);
            if Last /= Buffer'Last then
               raise End_Error;
            end if;
         end;
      exception
         when others =>
            if Is_Open (File) then
               Close (File);
            end if;
            B.Free (Data);
            Status := E.Make (E.IO_Read_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            return;
      end;
      Decode_Wave (Data.all, Max_Seconds, Samples, Status);
      B.Free (Data);
      if E.Is_Error (Status) then
         E.Add_Text (Status, "path", Path, E.Param_Path);
      end if;
   end Read_Wave;

end Model_Runner.Audio;
