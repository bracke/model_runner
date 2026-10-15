with Ada.Directories;
with Ada.Unchecked_Deallocation;
with Interfaces;
with Ada.Real_Time;
with Ada.Streams.Stream_IO;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Numerics;
with Model_Runner.Quantization;
with Model_Runner.Tensors;
with Model_Runner.Text;

with Fixtures;
with Quantizer;
with Recipes;

package body Quantize_Run is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Quantization;
   package Containers renames Model_Runner.GGUF.Containers;
   package Files renames Model_Runner.Byte_Sources.Files;
   package T renames Model_Runner.Tensors;

   use type B.Byte_Count;
   use type G.Tensor_Type;
   use type G.U64;
   use type G.Value_Type;
   subtype Element_Count is N.Element_Count;

   use type B.Byte;
   use type N.Real;
   use type T.Real_Array_Access;
   use type Quantizer.Target;
   use type N.Element_Count;
   use type B.Byte_Array_Access;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_16;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
      package Say renames Model_Runner.Text;
   begin
      if Item.Missing then
         return "nothing written: " & Item.Detail (1 .. Item.Detail_Up);
      end if;

      if not Item.Ran then
         return "wrote nothing: " & Item.Detail (1 .. Item.Detail_Up);
      end if;

      return
        Natural'Image (Item.Tensors) & " tensors,"
        & Natural'Image (Item.Converted) & " converted,"
        & Natural'Image (Item.Copied) & " copied"
        & (if Item.Bumped = 0 then ""
           else "," & Natural'Image (Item.Bumped) & " above the base")
        & (if Item.Weighted + Item.Unweighted = 0 then ""
           else "," & Natural'Image (Item.Weighted) & " weighted,"
                & Natural'Image (Item.Unweighted) & " not weighted by the "
                & "matrix")
        & (if Item.Bytes_Out = 0 then ""
           else ";" & Long_Long_Integer'Image (Item.Bytes_In)
                & " bytes in," & Long_Long_Integer'Image (Item.Bytes_Out)
                & " out")
        & (if not Item.Compared then ""
           else "; against it:" & Natural'Image (Item.Same)
                & " tensors the same,"
                & Natural'Image (Item.Differing) & " differing,"
                & Natural'Image (Item.Absent) & " absent"
                & (if Item.Odd_Up = 0 then ""
                   else "; first odd " & Item.First_Odd (1 .. Item.Odd_Up))
                & (if Item.First_Up = 0 then ""
                   else "; first apart " & Item.First_Apart (1 .. Item.First_Up)
                        & " by" & Long_Long_Integer'Image (Item.Apart_Bytes)
                        & " bytes,"
                        & Long_Long_Integer'Image (Item.Apart_Total)
                        & " bytes apart in all"))
        & "; took " & Say.Image (Long_Float (Item.Seconds), 2) & " s";
   end Summary;

   -----------------
   -- Read_Matrix --
   -----------------

   --  One tensor's importance, as a vector over its columns -- and, for a
   --  tensor of experts, one such vector an expert, laid end to end.
   --
   --  The file holds the sum of the squares of everything that met each
   --  column and, beside it, how many rows went into that sum: one count
   --  for a matrix, and one an expert for a stack of them, since each
   --  expert saw only the rows routed to it. What a caller wants is the
   --  mean, so the division happens here and slice by slice, each by its
   --  own count, as common/imatrix-loader does it: a count of zero is an
   --  expert nothing reached, which is given a weight of one rather than an
   --  infinity.
   procedure Read_Matrix
     (From   : in out Files.File_Source;
      File   : Containers.Container;
      Sums   : Positive;
      Counts : Positive;
      Into   : out T.Real_Array_Access;
      Status : out E.Error_Info);

   procedure Read_Matrix
     (From   : in out Files.File_Source;
      File   : Containers.Container;
      Sums   : Positive;
      Counts : Positive;
      Into   : out T.Real_Array_Access;
      Status : out E.Error_Info)
   is
      Wide : constant Element_Count :=
        Element_Count (Containers.Tensor_Elements (File, Sums));
      Many : constant Element_Count :=
        Element_Count (Containers.Tensor_Elements (File, Counts));

      Raw   : B.Byte_Array_Access :=
        new B.Byte_Array (0 .. B.Byte_Count (Wide) * 4 - 1);
      Tally : B.Byte_Array_Access :=
        new B.Byte_Array (0 .. B.Byte_Count (Many) * 4 - 1);
      Held  : T.Real_Array_Access;
      Ok    : Boolean;
   begin
      Into := null;

      Files.Read
        (From, B.Byte_Count (Containers.Tensor_Offset (File, Sums)),
         Raw.all, Status);
      if E.Is_Ok (Status) then
         Files.Read
           (From, B.Byte_Count (Containers.Tensor_Offset (File, Counts)),
            Tally.all, Status);
      end if;
      if E.Is_Error (Status) then
         B.Free (Raw);
         B.Free (Tally);
         return;
      end if;

      T.Allocate (Wide, Into);
      T.Allocate (Many, Held);

      Q.Decode_Blocks (G.Type_F32, Tally.all, 0, Many, Held.all, Ok);
      if Ok then
         Q.Decode_Blocks (G.Type_F32, Raw.all, 0, Wide, Into.all, Ok);
      end if;

      if not Ok then
         Into.all := [others => 1.0];
      else
         declare
            Slice : constant Element_Count := Wide / Many;
         begin
            for Which in 0 .. Many - 1 loop
               for Index in Which * Slice .. (Which + 1) * Slice - 1 loop
                  Into.all (Into.all'First + Index) :=
                    (if Held.all (Held.all'First + Which) > 0.0
                     then Into.all (Into.all'First + Index)
                          / Held.all (Held.all'First + Which)
                     else 1.0);
               end loop;
            end loop;
         end;
      end if;

      T.Free (Held);
      B.Free (Raw);
      B.Free (Tally);
   end Read_Matrix;

   --  Bytes to a file a slice at a time, read where they lie: a tensor is
   --  hundreds of megabytes, and a stream array that size on the stack is
   --  a storage error.
   procedure Write_Bytes
     (Output : Ada.Streams.Stream_IO.File_Type; Data : B.Byte_Array);

   procedure Write_Bytes
     (Output : Ada.Streams.Stream_IO.File_Type; Data : B.Byte_Array)
   is
      Slice   : constant B.Byte_Count := 1024 * 1024;
      At_Byte : B.Byte_Count := Data'First;
   begin
      while At_Byte <= Data'Last loop
         declare
            Upto : constant B.Byte_Count :=
              B.Byte_Count'Min (Data'Last, At_Byte + Slice - 1);
            Room : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Upto - At_Byte + 1));
            for Room'Address use Data (At_Byte)'Address;
            pragma Import (Ada, Room);
         begin
            Ada.Streams.Stream_IO.Write (Output, Room);
            At_Byte := Upto + 1;
         end;
      end loop;
   end Write_Bytes;

   --  The zeros a tensor is followed by.
   procedure Write_Zeros
     (Output : Ada.Streams.Stream_IO.File_Type; Count : B.Byte_Count);

   procedure Write_Zeros
     (Output : Ada.Streams.Stream_IO.File_Type; Count : B.Byte_Count) is
   begin
      if Count > 0 then
         Write_Bytes (Output, B.Byte_Array'(1 .. Count => 0));
      end if;
   end Write_Zeros;

   --  The number llama.cpp writes in general.file_type for what was asked:
   --  its llama_ftype. A pure k-quant is the mixture of the same name with
   --  the policy turned off, which is what `llama-quantize --pure` writes
   --  for it.
   function File_Type_Of
     (Wanted : Quantizer.Target;
      Mixed  : Recipes.Recipe;
      Mixture : Boolean) return Interfaces.Unsigned_32
   is (if Mixture
       then (case Mixed is
                when Recipes.Q2_K_Mix => 10,
                when Recipes.Q3_K_S => 11,
                when Recipes.Q3_K_M => 12,
                when Recipes.Q3_K_L => 13,
                when Recipes.Q4_K_S => 14,
                when Recipes.Q4_K_M => 15,
                when Recipes.Q5_K_S => 16,
                when Recipes.Q5_K_M => 17)
       else (case Wanted is
                when Quantizer.Q4_0 => 2,
                when Quantizer.Q4_1 => 3,
                when Quantizer.Q8_0 => 7,
                when Quantizer.Q5_0 => 8,
                when Quantizer.Q5_1 => 9,
                when Quantizer.Q2_K => 10,
                when Quantizer.Q3_K => 12,
                when Quantizer.Q4_K => 15,
                when Quantizer.Q5_K => 17,
                when Quantizer.Q6_K => 18,
                when Quantizer.IQ4_NL => 25,
                when Quantizer.IQ4_XS => 30));

   --  Whether a key is one the writer sets itself rather than copies.
   --
   --  The split keys describe the source's files and not the one written;
   --  the alignment is written by the builder, which then follows it; and
   --  the file type, the quantization version and an importance matrix's
   --  record describe the quantizing, which is this one's.
   function Set_Here (Key : String) return Boolean
   is (Key = "general.alignment"
       or else Key = "general.file_type"
       or else Key = "general.quantization_version"
       or else Key = "split.no"
       or else Key = "split.count"
       or else Key = "split.tensors.count"
       or else (Key'Length > 17
                and then Key (Key'First .. Key'First + 16)
                         = "quantize.imatrix."));

   -------------
   -- Compare --
   -------------

   --  Two files, tensor by tensor. What is compared is the bytes of the
   --  tensors they share: the headers differ for reasons that are not the
   --  encoding -- key order, alignment padding, what a writer chose to put
   --  in its general.file_type -- and none of those is the question.
   procedure Compare (Mine, Theirs : String; Result : in out Report);

   procedure Compare (Mine, Theirs : String; Result : in out Report) is
      One, Two   : aliased Files.File_Source;
      Here, Over : Containers.Container;
      Status     : E.Error_Info;
   begin
      if not Ada.Directories.Exists (Theirs) then
         return;
      end if;

      Files.Open (One, Mine, Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Files.Open (Two, Theirs, Status => Status);
      if E.Is_Error (Status) then
         Files.Close (One);
         return;
      end if;

      Containers.Reader.Parse (Here, One, Status => Status);
      if E.Is_Error (Status) then
         Files.Close (Two);
         Files.Close (One);
         return;
      end if;

      Containers.Reader.Parse (Over, Two, Status => Status);
      if E.Is_Error (Status) then
         Containers.Close (Here);
         Files.Close (Two);
         Files.Close (One);
         return;
      end if;

      Result.Compared := True;

      for Index in 1 .. Containers.Tensor_Count (Here) loop
         declare
            Name : constant String := Containers.Tensor_Name (Here, Index);
            Mate : constant Natural := Containers.Find_Tensor (Over, Name);
         begin
            if Mate = 0
              or else Containers.Tensor_Bytes (Here, Index)
                      /= Containers.Tensor_Bytes (Over, Mate)
              or else Containers.Tensor_Format (Here, Index)
                      /= Containers.Tensor_Format (Over, Mate)
            then
               Result.Absent := Result.Absent + 1;

               if Result.Odd_Up = 0 then
                  declare
                     Told : constant String :=
                       Name & " ours "
                       & G.Tensor_Type'Image
                           (Containers.Tensor_Format (Here, Index))
                       & " theirs "
                       & (if Mate = 0 then "absent"
                          else G.Tensor_Type'Image
                                 (Containers.Tensor_Format (Over, Mate)));
                     Room : constant Natural :=
                       Natural'Min (Told'Length, Result.First_Odd'Length);
                  begin
                     Result.First_Odd (1 .. Room) :=
                       Told (Told'First .. Told'First + Room - 1);
                     Result.Odd_Up := Room;
                  end;
               end if;
            else
               declare
                  Bytes : constant G.U64 :=
                    Containers.Tensor_Bytes (Here, Index);

                  Ours : B.Byte_Array_Access :=
                    new B.Byte_Array (0 .. B.Byte_Count (Bytes) - 1);
                  Yours : B.Byte_Array_Access :=
                    new B.Byte_Array (0 .. B.Byte_Count (Bytes) - 1);

                  Apart : Long_Long_Integer := 0;
               begin
                  Files.Read
                    (One,
                     B.Byte_Count (Containers.Tensor_Offset (Here, Index)),
                     Ours.all, Status);
                  Files.Read
                    (Two,
                     B.Byte_Count (Containers.Tensor_Offset (Over, Mate)),
                     Yours.all, Status);

                  for Which in Ours.all'Range loop
                     if Ours.all (Which) /= Yours.all (Which) then
                        Apart := Apart + 1;
                     end if;
                  end loop;

                  Result.Apart_Total := Result.Apart_Total + Apart;

                  if Apart = 0 then
                     Result.Same := Result.Same + 1;
                  else
                     Result.Differing := Result.Differing + 1;
                     if Result.First_Up = 0 then
                        declare
                           Room : constant Natural :=
                             Natural'Min (Name'Length, Result.First_Apart'Length);
                        begin
                           Result.First_Apart (1 .. Room) :=
                             Name (Name'First .. Name'First + Room - 1);
                           Result.First_Up := Room;
                           Result.Apart_Bytes := Apart;
                        end;
                     end if;
                  end if;

                  B.Free (Ours);
                  B.Free (Yours);
               end;
            end if;
         end;
      end loop;

      Containers.Close (Over);
      Containers.Close (Here);
      Files.Close (Two);
      Files.Close (One);
   end Compare;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path    : String;
      Format  : String;
      Into    : String;
      Against : String;
      Matrix  : String;
      Result  : out Report)
   is
      procedure Note (Item : String);

      procedure Note (Item : String) is
         Room : constant Natural :=
           Natural'Min (Item'Length, Result.Detail'Length);
      begin
         Result.Detail (1 .. Room) :=
           Item (Item'First .. Item'First + Room - 1);
         Result.Detail_Up := Room;
      end Note;

      Wanted  : Quantizer.Target;
      Known   : Boolean;

      --  A mixture, where the name was one. A recipe writes its base
      --  format nearly everywhere and something else on the tensors
      --  llama.cpp has decided deserve it.
      Mixed   : Recipes.Recipe;
      Mixture : Boolean;

      Started : Ada.Real_Time.Time;
   begin
      Result := (others => <>);

      Quantizer.Named (Format, Wanted, Known);
      Recipes.Named (Format, Mixed, Mixture);

      if Mixture then
         Wanted := Recipes.Base_Of (Mixed);
      elsif not Known then
         Result.Missing := True;
         Note ("this writes twelve formats and the k-quant mixtures, and "
               & "not " & Format);
         return;
      end if;

      if not Ada.Directories.Exists (Path) then
         Result.Missing := True;
         Note ("no model at that path");
         return;
      end if;

      Started := Ada.Real_Time.Clock;

      declare
         Source : aliased Files.File_Source;
         Item   : Containers.Container;
         Status : E.Error_Info;

         --  The importance matrix, read as the container it is: one vector
         --  a weight tensor named `<tensor>.in_sum2`, and beside it a
         --  `<tensor>.counts` holding how many rows went into the sum.
         Weights_Source : aliased Files.File_Source;
         Weights_File   : Containers.Container;
         Have_Weights   : Boolean := False;

         Maker  : Fixtures.Builder;

         Model_Shape : Recipes.Shape;
         Walked      : Recipes.Progress;

         Output  : Ada.Streams.Stream_IO.File_Type;
         Writing : Boolean := False;
      begin
         if Matrix /= "" then
            Files.Open (Weights_Source, Matrix, Status => Status);
            if E.Is_Error (Status) then
               Note ("the matrix would not open: "
                     & E.Error_Code'Image (Status.Code));
               return;
            end if;

            Containers.Reader.Parse
              (Weights_File, Weights_Source, Status => Status);
            if E.Is_Error (Status) then
               Files.Close (Weights_Source);
               Note ("the matrix would not parse: "
                     & E.Error_Code'Image (Status.Code));
               return;
            end if;

            Have_Weights := True;
         end if;
         Files.Open (Source, Path, Status => Status);
         if E.Is_Error (Status) then
            Note ("the model would not open: "
                  & E.Error_Code'Image (Status.Code));
            goto Close_Matrix;
         end if;

         Containers.Reader.Parse (Item, Source, Status => Status);
         if E.Is_Error (Status) then
            Files.Close (Source);
            Note ("the model would not parse: "
                  & E.Error_Code'Image (Status.Code));
            goto Close_Matrix;
         end if;

         --  One file of several holds some of the tensors and all of the
         --  keys that say so; written out alone it would be a model with
         --  most of itself missing that claimed to be whole.
         if Containers.Shard_Count (Item) > 1 then
            Note ("a model split across"
                  & Natural'Image (Containers.Shard_Count (Item))
                  & " files; join them first (llama-gguf-split --merge)");
            goto Give_Up;
         end if;

         --  What the policy asks about the model, where a mixture was
         --  named. The architecture decides several branches and the
         --  grouping decides one, and a model the transcription does not
         --  cover is refused rather than written wrongly.
         if Mixture then
            declare
               Kind : constant String :=
                 (if Containers.Has (Item, "general.architecture")
                  then Containers.String_Value (Item, "general.architecture")
                  else "");

               function Number (Key : String; Default : Natural) return Natural
               is
                  Held : Long_Long_Integer;
                  Told : E.Error_Info;
               begin
                  if not Containers.Has (Item, Kind & Key) then
                     return Default;
                  end if;
                  Containers.Get_Integer
                    (Item, Kind & Key, 0, Long_Long_Integer (Natural'Last),
                     Held, Told);
                  return (if E.Is_Error (Told) then Default
                          else Natural (Held));
               end Number;

               Heads    : constant Natural := Number (".attention.head_count", 1);
               KV_Heads : constant Natural :=
                 Number (".attention.head_count_kv", Heads);
               Experts  : constant Natural := Number (".expert_count", 0);

               Held   : Long_Long_Integer := 0;
               Values : Natural := 0;
            begin
               for Which in 1 .. Containers.Tensor_Count (Item) loop
                  Held := Held
                    + Long_Long_Integer
                        (Containers.Tensor_Elements (Item, Which));
                  if Recipes.Is_Attention_Value
                       (Containers.Tensor_Name (Item, Which))
                  then
                     Values := Values + 1;
                  end if;
               end loop;

               if not Recipes.Fits (Kind, Experts, Held) then
                  Note ("this model is one llama.cpp's mixture policy treats "
                        & "specially and this transcription does not: " & Kind);
                  goto Give_Up;
               end if;

               Model_Shape :=
                 (Layers  => Number (".block_count", 0),
                  Grouped =>
                    (if KV_Heads = 0 then 1 else Heads / KV_Heads),
                  Tied    =>
                    Containers.Find_Tensor (Item, "output.weight") = 0,
                  Values  => Values);
            end;
         end if;

         --  The data section follows the source's alignment where it named
         --  one, as llama.cpp's writer does: the key is copied and the
         --  writer then pads to it. Copying the key while padding to the
         --  default wrote a file whose offsets broke the rule it stated.
         Fixtures.Reset
           (Maker,
            Alignment =>
              (if Containers.Has (Item, "general.alignment")
               then Containers.Alignment (Item) else 0));

         --  Every metadata entry, in the order the file holds them, each
         --  written as the type it was read as. A key this does not know
         --  how to write is a key the output would not carry, and a model
         --  missing a key it needs is a model that will not open -- so an
         --  unknown kind stops the run rather than being skipped quietly.
         for Index in 1 .. Containers.Metadata_Count (Item) loop
            declare
               Key  : constant String := Containers.Metadata_Key (Item, Index);
               Kind : constant G.Value_Type :=
                 Containers.Metadata_Kind (Item, Index);

               Whole : Long_Long_Integer;
               Real  : N.Wide_Real;
               Flag  : Boolean;
               Said  : E.Error_Info;
            begin
               if Set_Here (Key) then
                  goto Next_Key;
               end if;

               case Kind is
                  when G.Value_String =>
                     Fixtures.Add_String
                       (Maker, Key, Containers.String_Value (Item, Key));

                  when G.Value_UInt8 | G.Value_Int8 | G.Value_UInt16
                     | G.Value_Int16 | G.Value_UInt32 | G.Value_Int32
                     | G.Value_UInt64 | G.Value_Int64 =>
                     Containers.Get_Integer
                       (Item, Key, Long_Long_Integer'First,
                        Long_Long_Integer'Last, Whole, Said);
                     if E.Is_Error (Said) then
                        Note ("a metadata number would not read: " & Key);
                        goto Give_Up;
                     end if;
                     Fixtures.Add_Integer (Maker, Key, Kind, Whole);

                  when G.Value_Float32 | G.Value_Float64 =>
                     Containers.Get_Float
                       (Item, Key, N.Wide_Real'First,
                        N.Wide_Real'Last, Real, Said);
                     if E.Is_Error (Said) then
                        Note ("a metadata number would not read: " & Key);
                        goto Give_Up;
                     end if;
                     if Kind = G.Value_Float64 then
                        Fixtures.Add_F64 (Maker, Key, Real);
                     else
                        Fixtures.Add_F32 (Maker, Key, N.Real (Real));
                     end if;

                  when G.Value_Bool =>
                     Containers.Get_Boolean (Item, Key, Flag, Said);
                     if E.Is_Error (Said) then
                        Note ("a metadata flag would not read: " & Key);
                        goto Give_Up;
                     end if;
                     Fixtures.Add_Bool (Maker, Key, Flag);

                  when G.Value_Array =>
                     declare
                        Of_Kind : constant G.Value_Type :=
                          Containers.Metadata_Element_Kind (Item, Index);
                        Length  : Natural;
                     begin
                        Containers.Get_Array_Length
                          (Item, Key, Of_Kind, Length, Said);
                        if E.Is_Error (Said) then
                           Note ("an array would not measure: " & Key);
                           goto Give_Up;
                        end if;

                        Fixtures.Begin_Array (Maker, Key, Of_Kind, Length);

                        for Which in 1 .. Length loop
                           case Of_Kind is
                              when G.Value_String =>
                                 declare
                                    Room : Natural;
                                 begin
                                    Containers.Get_String_Element_Length
                                      (Item, Key, Which, Room, Said);
                                    if E.Is_Error (Said) then
                                       Note ("a string would not measure in "
                                             & Key);
                                       goto Give_Up;
                                    end if;

                                    declare
                                       Text : String (1 .. Room);
                                       Used : Natural;
                                    begin
                                       Containers.Get_String_Element
                                         (Item, Key, Which, Text, Used, Said);
                                       if E.Is_Error (Said) then
                                          Note ("a string would not read in "
                                                & Key);
                                          goto Give_Up;
                                       end if;
                                       Fixtures.String_Element
                                         (Maker, Text (1 .. Used));
                                    end;
                                 end;

                              when G.Value_Float32 | G.Value_Float64 =>
                                 Containers.Get_Float_Element
                                   (Item, Key, Which, Real, Said);
                                 if E.Is_Error (Said) then
                                    Note ("a number would not read in " & Key);
                                    goto Give_Up;
                                 end if;
                                 if Of_Kind = G.Value_Float64 then
                                    Fixtures.F64_Element (Maker, Real);
                                 else
                                    Fixtures.Float_Element
                                      (Maker, N.Real (Real));
                                 end if;

                              when G.Value_Bool =>
                                 Containers.Get_Boolean_Element
                                   (Item, Key, Which, Flag, Said);
                                 if E.Is_Error (Said) then
                                    Note ("a flag would not read in " & Key);
                                    goto Give_Up;
                                 end if;
                                 Fixtures.Bool_Element (Maker, Flag);

                              when G.Value_UInt8 | G.Value_Int8
                                 | G.Value_UInt16 | G.Value_Int16
                                 | G.Value_UInt32 | G.Value_Int32
                                 | G.Value_UInt64 | G.Value_Int64 =>
                                 Containers.Get_Integer_Element
                                   (Item, Key, Which, Whole, Said);
                                 if E.Is_Error (Said) then
                                    Note ("a number would not read in " & Key);
                                    goto Give_Up;
                                 end if;
                                 Fixtures.Integer_Element
                                   (Maker, Of_Kind, Whole);

                              when G.Value_Array =>
                                 Note ("an array of arrays, which this does "
                                       & "not write: " & Key);
                                 goto Give_Up;
                           end case;
                        end loop;

                        Fixtures.End_Array (Maker);
                     end;

               end case;

               <<Next_Key>>
            end;
         end loop;

         --  And the keys that describe this quantizing: llama.cpp's
         --  file-type number and quantization version, and where a matrix
         --  was used, what it was, as llama-quantize records it.
         Fixtures.Add_U32 (Maker, "general.quantization_version", 2);
         Fixtures.Add_U32
           (Maker, "general.file_type",
            File_Type_Of (Wanted, Mixed, Mixture));

         if Have_Weights then
            declare
               Entries : Natural := 0;
               Chunks  : Long_Long_Integer := 0;
               Said    : E.Error_Info;
               Tail    : constant String := ".in_sum2";
            begin
               for Which in 1 .. Containers.Tensor_Count (Weights_File) loop
                  declare
                     Named : constant String :=
                       Containers.Tensor_Name (Weights_File, Which);
                  begin
                     if Named'Length > Tail'Length
                       and then Named (Named'Last - Tail'Length + 1
                                       .. Named'Last) = Tail
                     then
                        Entries := Entries + 1;
                     end if;
                  end;
               end loop;

               Fixtures.Add_String (Maker, "quantize.imatrix.file", Matrix);

               if Containers.Has (Weights_File, "imatrix.datasets") then
                  declare
                     Room : Natural;
                  begin
                     Containers.Get_String_Element_Length
                       (Weights_File, "imatrix.datasets", 1, Room, Said);
                     if E.Is_Ok (Said) then
                        declare
                           Text : String (1 .. Room);
                           Used : Natural;
                        begin
                           Containers.Get_String_Element
                             (Weights_File, "imatrix.datasets", 1, Text,
                              Used, Said);
                           if E.Is_Ok (Said) then
                              Fixtures.Add_String
                                (Maker, "quantize.imatrix.dataset",
                                 Text (1 .. Used));
                           end if;
                        end;
                     end if;
                  end;
               end if;

               Fixtures.Add_U32
                 (Maker, "quantize.imatrix.entries_count",
                  Interfaces.Unsigned_32 (Entries));

               if Containers.Has (Weights_File, "imatrix.chunk_count") then
                  Containers.Get_Integer
                    (Weights_File, "imatrix.chunk_count", 0,
                     Long_Long_Integer (Interfaces.Unsigned_32'Last),
                     Chunks, Said);
                  if E.Is_Ok (Said) and then Chunks > 0 then
                     Fixtures.Add_U32
                       (Maker, "quantize.imatrix.chunks_count",
                        Interfaces.Unsigned_32 (Chunks));
                  end if;
               end if;
            end;
         end if;

         Result.Tensors := Containers.Tensor_Count (Item);

         declare
            Count : constant Natural := Result.Tensors;

            --  What each tensor becomes, decided before anything is
            --  written: the head lists every tensor's format and size, and
            --  it is written first.
            type Plan is record
               Format  : Quantizer.Target := Quantizer.Q8_0;
               As_Half : Boolean := False;
               Convert : Boolean := False;
               Bytes   : B.Byte_Count := 0;
            end record;

            type Plan_List is array (1 .. Count) of Plan;
            type Plan_List_Access is access Plan_List;
            procedure Free is new Ada.Unchecked_Deallocation
              (Plan_List, Plan_List_Access);

            type Order_List is array (1 .. Count) of Natural;
            type Order_List_Access is access Order_List;
            procedure Free is new Ada.Unchecked_Deallocation
              (Order_List, Order_List_Access);

            Plans : Plan_List_Access := new Plan_List;
            Order : Order_List_Access := new Order_List;
            Head  : B.Byte_Array_Access := null;
            Fine  : Boolean := True;
         begin
            --  llama.cpp's order, which is what its counters count in: by
            --  layer, then by name.
            for Index in 1 .. Count loop
               Order (Index) := Index;
            end loop;
            for Index in 2 .. Count loop
               declare
                  Moving : constant Natural := Order (Index);
                  Name   : constant String :=
                    Containers.Tensor_Name (Item, Moving);
                  Place  : Natural := Index;
               begin
                  while Place > 1
                    and then Recipes.Comes_Before
                               (Name,
                                Containers.Tensor_Name
                                  (Item, Order (Place - 1)))
                  loop
                     Order (Place) := Order (Place - 1);
                     Place := Place - 1;
                  end loop;
                  Order (Place) := Moving;
               end;
            end loop;

            for Step in 1 .. Count loop
               declare
                  Index : constant Natural := Order (Step);
                  Name  : constant String := Containers.Tensor_Name (Item, Index);
                  Kind  : constant G.Tensor_Type :=
                    Containers.Tensor_Format (Item, Index);
                  Rank  : constant Positive :=
                    Containers.Tensor_Rank (Item, Index);
                  Elements : constant G.U64 :=
                    Containers.Tensor_Elements (Item, Index);
                  Columns : constant Long_Long_Integer :=
                    Long_Long_Integer
                      (Containers.Tensor_Dimension (Item, Index, 1));

                  This : Plan renames Plans (Index);
               begin
                  This.Bytes :=
                    B.Byte_Count (Containers.Tensor_Bytes (Item, Index));

                  --  A norm, a bias, a router, a convolution: what
                  --  llama.cpp leaves as it stands is copied as it stands.
                  if Recipes.Allows (Name, Rank) then
                     declare
                        Chosen : constant Quantizer.Target :=
                          (if Mixture
                           then Recipes.Type_For
                                  (Mixed, Name, Model_Shape, Walked, Columns)
                           else Wanted);

                        Fitted : constant Recipes.Fitted :=
                          Recipes.Fall_Back (Chosen, Columns);
                     begin
                        if Fitted.Refused then
                           Note ("rows of" & Long_Long_Integer'Image (Columns)
                                 & " in " & Name & " do not divide into "
                                 & Quantizer.Name_Of (Chosen)
                                 & " blocks, and llama.cpp has no fallback "
                                 & "for that format either");
                           Fine := False;
                           exit;
                        end if;

                        This.Format := Fitted.Format;
                        This.As_Half := Fitted.As_Half;
                        This.Convert :=
                          (if Fitted.As_Half then Kind /= G.Type_F16
                           else Kind /= Quantizer.Type_Of (Fitted.Format));

                        if This.Convert then
                           This.Bytes :=
                             (if Fitted.As_Half
                              then B.Byte_Count (Elements) * 2
                              else B.Byte_Count
                                     (Elements
                                      / G.U64 (Quantizer.Block_Of
                                                 (Fitted.Format)))
                                   * Quantizer.Bytes_Of (Fitted.Format));
                        end if;
                     end;
                  end if;
               end;
            end loop;

            if not Fine then
               Free (Plans);
               Free (Order);
               goto Give_Up;
            end if;

            --  The head, then the tensors one at a time: the file is never
            --  held whole, and neither is more than one tensor of it.
            for Index in 1 .. Count loop
               declare
                  Rank  : constant Positive :=
                    Containers.Tensor_Rank (Item, Index);
                  Shape : Fixtures.Dimension_List (1 .. Rank);
               begin
                  for Which in 1 .. Rank loop
                     Shape (Which) :=
                       Containers.Tensor_Dimension (Item, Index, Which);
                  end loop;

                  Fixtures.Plan_Tensor
                    (Maker, Containers.Tensor_Name (Item, Index), Shape,
                     (if not Plans (Index).Convert
                      then Containers.Tensor_Format (Item, Index)
                      elsif Plans (Index).As_Half then G.Type_F16
                      else Quantizer.Type_Of (Plans (Index).Format)),
                     Plans (Index).Bytes);
               end;
            end loop;

            if Into /= "" then
               Fixtures.Build_Head (Maker, Head);
               if Head = null then
                  Free (Plans);
                  Free (Order);
                  Note ("the file would not assemble");
                  goto Give_Up;
               end if;

               Ada.Streams.Stream_IO.Create
                 (Output, Ada.Streams.Stream_IO.Out_File, Into);
               Writing := True;
               Write_Bytes (Output, Head.all);
               B.Free (Head);
            end if;

            for Index in 1 .. Count loop
               declare
                  This  : Plan renames Plans (Index);
                  Name  : constant String := Containers.Tensor_Name (Item, Index);
                  Kind  : constant G.Tensor_Type :=
                    Containers.Tensor_Format (Item, Index);
                  Rank  : constant Positive :=
                    Containers.Tensor_Rank (Item, Index);
                  Elements : constant G.U64 :=
                    Containers.Tensor_Elements (Item, Index);
                  Bytes : constant G.U64 := Containers.Tensor_Bytes (Item, Index);
                  --  Absolute already: Tensor_Offset is from the start of
                  --  the file and not from the data section, which the spec
                  --  says and adding Data_Offset to it does not.
                  At_Byte : constant G.U64 :=
                    Containers.Tensor_Offset (Item, Index);

                  Row : constant Element_Count :=
                    Element_Count (Containers.Tensor_Dimension (Item, Index, 1));

                  --  The matrices a tensor stacks: one, or one an expert.
                  Stacked : constant Element_Count :=
                    (if Rank >= 3
                     then Element_Count
                            (Containers.Tensor_Dimension (Item, Index, 3))
                     else 1);

                  Raw : B.Byte_Array_Access :=
                    new B.Byte_Array (0 .. B.Byte_Count (Bytes) - 1);
               begin
                  Files.Read
                    (Source, B.Byte_Count (At_Byte), Raw.all, Status);
                  if E.Is_Error (Status) then
                     B.Free (Raw);
                     Free (Plans);
                     Free (Order);
                     Note ("a tensor would not read: " & Name & " "
                           & E.Error_Code'Image (Status.Code));
                     goto Give_Up;
                  end if;

                  Result.Bytes_In := Result.Bytes_In + Long_Long_Integer (Bytes);

                  if not This.Convert then
                     if Writing then
                        Write_Bytes (Output, Raw.all);
                     end if;
                     Result.Copied := Result.Copied + 1;
                  else
                     declare
                        Values : T.Real_Array_Access;
                        Ok     : Boolean;
                     begin
                        T.Allocate (N.Element_Count (Elements), Values);

                        --  Blocks and not elements, which is what
                        --  Decode_Blocks counts: a Q8_0 tensor of a million
                        --  elements is thirty-one thousand blocks, and asking
                        --  for a million of them is asking for thirty-two
                        --  times the tensor.
                        Q.Decode_Blocks
                          (Kind, Raw.all, 0,
                           N.Element_Count (Elements)
                           / N.Element_Count (G.Block_Elements (Kind)),
                           Values.all, Ok);
                        B.Free (Raw);

                        if not Ok then
                           T.Free (Values);
                           Free (Plans);
                           Free (Order);
                           Note ("a tensor would not decode: " & Name);
                           goto Give_Up;
                        end if;

                        if This.As_Half then
                           declare
                              Halves : B.Byte_Array_Access :=
                                new B.Byte_Array
                                  (0 .. B.Byte_Count (Elements) * 2 - 1);
                           begin
                              for Which in Values.all'Range loop
                                 declare
                                    Bits : constant Interfaces.Unsigned_16 :=
                                      Interfaces.Unsigned_16
                                        (N.To_Half (Values.all (Which)));
                                    At_Half : constant B.Byte_Count :=
                                      B.Byte_Count (Which - Values.all'First)
                                      * 2;
                                 begin
                                    Halves.all (At_Half) :=
                                      B.Byte (Bits and 16#FF#);
                                    Halves.all (At_Half + 1) :=
                                      B.Byte (Interfaces.Shift_Right (Bits, 8));
                                 end;
                              end loop;
                              if Writing then
                                 Write_Bytes (Output, Halves.all);
                              end if;
                              B.Free (Halves);
                           end;

                           if Have_Weights then
                              Result.Unweighted := Result.Unweighted + 1;
                           end if;
                        else
                           declare
                              --  What the matrix says this tensor's columns
                              --  are worth, if it names it: a row's worth,
                              --  or a row's worth an expert.
                              Named : constant Natural :=
                                (if Have_Weights
                                 then Containers.Find_Tensor
                                        (Weights_File, Name & ".in_sum2")
                                 else 0);

                              Counted : constant Natural :=
                                (if Named = 0 then 0
                                 else Containers.Find_Tensor
                                        (Weights_File, Name & ".counts"));

                              Sized : constant Boolean :=
                                Named /= 0 and then Counted /= 0
                                and then Containers.Tensor_Elements
                                           (Weights_File, Named)
                                         = G.U64 (Row * Stacked)
                                and then Containers.Tensor_Elements
                                           (Weights_File, Counted) > 0
                                and then Containers.Tensor_Elements
                                           (Weights_File, Named)
                                         mod Containers.Tensor_Elements
                                               (Weights_File, Counted) = 0;

                              Heft : T.Real_Array_Access := null;

                              Per_Matrix : constant Element_Count :=
                                N.Element_Count (Elements) / Stacked;
                           begin
                              --  A matrix that names a tensor and is the
                              --  wrong size for it is a matrix for another
                              --  model, and llama.cpp stops rather than
                              --  quantize most of it unweighted unnoticed --
                              --  all but the embedding, which it lets by.
                              if Named /= 0 and then not Sized
                                and then Name /= "token_embd.weight"
                                and then Name /= "per_layer_token_embd.weight"
                              then
                                 T.Free (Values);
                                 Free (Plans);
                                 Free (Order);
                                 Note ("the matrix's entry for " & Name
                                       & " is not the size of the tensor");
                                 goto Give_Up;
                              end if;

                              if Sized then
                                 Read_Matrix
                                   (Weights_Source, Weights_File, Named,
                                    Counted, Heft, Status);

                                 if E.Is_Error (Status) then
                                    T.Free (Values);
                                    Free (Plans);
                                    Free (Order);
                                    Note ("the matrix would not read for "
                                          & Name);
                                    goto Give_Up;
                                 end if;
                              end if;

                              --  An expert at a time, each with its own
                              --  slice of the matrix, as llama.cpp does: the
                              --  experts saw different rows.
                              for Expert in 0 .. Stacked - 1 loop
                                 declare
                                    From : constant Element_Count :=
                                      Values.all'First + Expert * Per_Matrix;
                                    Written : B.Byte_Array_Access;
                                 begin
                                    if Heft = null then
                                       Quantizer.Encode_Into
                                         (Values.all
                                            (From .. From + Per_Matrix - 1),
                                          This.Format, Written);
                                    else
                                       Quantizer.Encode_Weighted_Into
                                         (Values.all
                                            (From .. From + Per_Matrix - 1),
                                          Heft.all
                                            (Heft.all'First + Expert * Row
                                             .. Heft.all'First
                                                + (Expert + 1) * Row - 1),
                                          This.Format, Written);
                                    end if;

                                    if Writing then
                                       Write_Bytes (Output, Written.all);
                                    end if;
                                    B.Free (Written);
                                 end;
                              end loop;

                              --  Weighted only where the matrix changed what
                              --  was written: Q8_0 takes no matrix.
                              if Heft /= null
                                and then Quantizer.Has_Weighted_Path
                                           (This.Format)
                              then
                                 Result.Weighted := Result.Weighted + 1;
                              elsif Have_Weights then
                                 Result.Unweighted := Result.Unweighted + 1;
                              end if;

                              if Heft /= null then
                                 T.Free (Heft);
                              end if;
                           end;
                        end if;

                        T.Free (Values);
                     end;

                     Result.Converted := Result.Converted + 1;

                     if This.As_Half or else This.Format /= Wanted then
                        Result.Bumped := Result.Bumped + 1;
                     end if;
                  end if;

                  if Raw /= null then
                     B.Free (Raw);
                  end if;

                  Result.Bytes_Out :=
                    Result.Bytes_Out + Long_Long_Integer (This.Bytes);

                  if Writing then
                     Write_Zeros
                       (Output, Fixtures.Padding_After (Maker, This.Bytes));
                  end if;
               end;
            end loop;

            Free (Plans);
            Free (Order);
         end;

         if Writing then
            Ada.Streams.Stream_IO.Close (Output);
            Writing := False;
         end if;

         Result.Ran := True;

         <<Give_Up>>
         if Writing then
            Ada.Streams.Stream_IO.Close (Output);
         end if;
         Containers.Close (Item);
         Files.Close (Source);

         <<Close_Matrix>>
         if Have_Weights then
            Containers.Close (Weights_File);
            Files.Close (Weights_Source);
         end if;
      end;

      --  And the comparison, which is a second reading of two files and not
      --  a property of the writing above: it is what says two encoders read
      --  the same rule the same way.
      if Against /= "" and then Into /= "" and then Result.Ran then
         Compare (Into, Against, Result);
      end if;

      Result.Seconds :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   end Run;

end Quantize_Run;
