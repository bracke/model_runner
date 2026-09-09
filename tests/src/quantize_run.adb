with Ada.Directories;
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
   use type B.Byte;
   use type N.Element_Count;
   use type B.Byte_Array_Access;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;

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
        & (if Item.Bytes_Out = 0 then ""
           else ";" & Long_Long_Integer'Image (Item.Bytes_In)
                & " bytes in," & Long_Long_Integer'Image (Item.Bytes_Out)
                & " out")
        & (if not Item.Compared then ""
           else "; against it:" & Natural'Image (Item.Same)
                & " tensors the same,"
                & Natural'Image (Item.Differing) & " differing,"
                & Natural'Image (Item.Absent) & " absent"
                & (if Item.First_Up = 0 then ""
                   else "; first apart " & Item.First_Apart (1 .. Item.First_Up)
                        & " by" & Long_Long_Integer'Image (Item.Apart_Bytes)
                        & " bytes,"
                        & Long_Long_Integer'Image (Item.Apart_Total)
                        & " bytes apart in all"))
        & "; took " & Say.Image (Long_Float (Item.Seconds), 2) & " s";
   end Summary;

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
      Started : Ada.Real_Time.Time;
   begin
      Result := (others => <>);

      Quantizer.Named (Format, Wanted, Known);
      if not Known then
         Result.Missing := True;
         Note ("this writes q8_0, q4_0, q4_1, q5_0, q5_1, q4_k and q6_k, "
               & "and not " & Format);
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

         Maker  : Fixtures.Builder;
         Made   : B.Byte_Array_Access := null;
      begin
         Files.Open (Source, Path, Status => Status);
         if E.Is_Error (Status) then
            Note ("the model would not open: "
                  & E.Error_Code'Image (Status.Code));
            return;
         end if;

         Containers.Reader.Parse (Item, Source, Status => Status);
         if E.Is_Error (Status) then
            Files.Close (Source);
            Note ("the model would not parse: "
                  & E.Error_Code'Image (Status.Code));
            return;
         end if;

         --  Every metadata entry, in the order the file holds them. A key
         --  this does not know how to write is a key the output would not
         --  carry, and a model missing a key it needs is a model that will
         --  not open -- so an unknown kind stops the run rather than being
         --  skipped quietly.
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

                     if Kind = G.Value_UInt64 or else Kind = G.Value_Int64 then
                        Fixtures.Add_U64
                          (Maker, Key, Interfaces.Unsigned_64 (Whole));
                     elsif Kind = G.Value_Int32 then
                        Fixtures.Add_I32
                          (Maker, Key, Interfaces.Integer_32 (Whole));
                     else
                        Fixtures.Add_U32
                          (Maker, Key, Interfaces.Unsigned_32 (Whole));
                     end if;

                  when G.Value_Float32 | G.Value_Float64 =>
                     Containers.Get_Float
                       (Item, Key, N.Wide_Real'First,
                        N.Wide_Real'Last, Real, Said);
                     if E.Is_Error (Said) then
                        Note ("a metadata number would not read: " & Key);
                        goto Give_Up;
                     end if;
                     Fixtures.Add_F32 (Maker, Key, N.Real (Real));

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
                                 Fixtures.Float_Element (Maker, N.Real (Real));

                              when others =>
                                 Containers.Get_Integer_Element
                                   (Item, Key, Which, Whole, Said);
                                 if E.Is_Error (Said) then
                                    Note ("a number would not read in " & Key);
                                    goto Give_Up;
                                 end if;

                                 if Of_Kind = G.Value_UInt64
                                   or else Of_Kind = G.Value_Int64
                                 then
                                    Fixtures.UInt64_Element
                                      (Maker, Interfaces.Unsigned_64 (Whole));
                                 else
                                    Fixtures.Int32_Element
                                      (Maker, Interfaces.Integer_32 (Whole));
                                 end if;
                           end case;
                        end loop;

                        Fixtures.End_Array (Maker);
                     end;

               end case;
            end;
         end loop;

         --  And every tensor, converted or carried.
         Result.Tensors := Containers.Tensor_Count (Item);

         for Index in 1 .. Result.Tensors loop
            declare
               Name  : constant String := Containers.Tensor_Name (Item, Index);
               Kind  : constant G.Tensor_Type :=
                 Containers.Tensor_Format (Item, Index);
               Rank  : constant Positive := Containers.Tensor_Rank (Item, Index);
               Count : constant G.U64 :=
                 Containers.Tensor_Elements (Item, Index);
               Bytes : constant G.U64 := Containers.Tensor_Bytes (Item, Index);
               --  Absolute already: Tensor_Offset is from the start of the
               --  file and not from the data section, which the spec says
               --  and adding Data_Offset to it does not.
               At_Byte : constant G.U64 :=
                 Containers.Tensor_Offset (Item, Index);

               Shape : Fixtures.Dimension_List (1 .. Rank);

               --  A tensor is re-encoded when it is more than a vector and
               --  its elements fill whole blocks. A norm or a bias is a
               --  vector and stays what it is, which is what every
               --  quantized file does with them.
               Convert : constant Boolean :=
                 Rank > 1
                 and then Count mod G.U64 (Quantizer.Block_Of (Wanted)) = 0
                 and then Kind /= Quantizer.Type_Of (Wanted);

               Raw : B.Byte_Array_Access :=
                 new B.Byte_Array (0 .. B.Byte_Count (Bytes) - 1);
            begin
               for Which in 1 .. Rank loop
                  Shape (Which) :=
                    Containers.Tensor_Dimension (Item, Index, Which);
               end loop;

               Files.Read
                 (Source, B.Byte_Count (At_Byte), Raw.all, Status);
               if E.Is_Error (Status) then
                  B.Free (Raw);
                  Note ("a tensor would not read: " & Name & " "
                        & E.Error_Code'Image (Status.Code));
                  goto Give_Up;
               end if;

               Result.Bytes_In := Result.Bytes_In + Long_Long_Integer (Bytes);

               if Convert then
                  declare
                     Values : T.Real_Array_Access;
                     Ok : Boolean;
                  begin
                     T.Allocate (N.Element_Count (Count), Values);

                     --  Blocks and not elements, which is what Decode_Blocks
                     --  counts: a Q8_0 tensor of a million elements is
                     --  thirty-one thousand blocks, and asking for a million
                     --  of them is asking for thirty-two times the tensor.
                     Q.Decode_Blocks
                       (Kind, Raw.all, 0,
                        N.Element_Count (Count)
                        / N.Element_Count (G.Block_Elements (Kind)),
                        Values.all, Ok);

                     if not Ok then
                        T.Free (Values);
                        B.Free (Raw);
                        Note ("a tensor would not decode: " & Name);
                        goto Give_Up;
                     end if;

                     declare
                        Written : constant B.Byte_Array :=
                          Quantizer.Encode (Values.all, Wanted);
                     begin
                        Fixtures.Add_Tensor
                          (Maker, Name, Shape,
                           Quantizer.Type_Of (Wanted), Written);
                        Result.Bytes_Out :=
                          Result.Bytes_Out
                          + Long_Long_Integer (Written'Length);
                     end;

                     T.Free (Values);
                     Result.Converted := Result.Converted + 1;
                  end;
               else
                  Fixtures.Add_Tensor (Maker, Name, Shape, Kind, Raw.all);
                  Result.Bytes_Out :=
                    Result.Bytes_Out + Long_Long_Integer (Bytes);
                  Result.Copied := Result.Copied + 1;
               end if;

               B.Free (Raw);
            end;
         end loop;

         if Into /= "" then
            Fixtures.Build (Maker, Made);

            if Made = null then
               Note ("the file would not assemble");
               goto Give_Up;
            end if;

            declare
               Output : Ada.Streams.Stream_IO.File_Type;
            begin
               Ada.Streams.Stream_IO.Create
                 (Output, Ada.Streams.Stream_IO.Out_File, Into);

               --  A slice at a time. The whole file as one stack array is
               --  six hundred megabytes of it, which is a storage error and
               --  was.
               declare
                  Slice : constant B.Byte_Count := 1024 * 1024;
                  At_Byte : B.Byte_Count := 0;
               begin
                  while At_Byte < Made.all'Length loop
                     declare
                        Room : constant B.Byte_Count :=
                          B.Byte_Count'Min
                            (Slice, Made.all'Length - At_Byte);

                        Out_Room : Ada.Streams.Stream_Element_Array
                          (1 .. Ada.Streams.Stream_Element_Offset (Room));
                     begin
                        for Which in Out_Room'Range loop
                           Out_Room (Which) :=
                             Ada.Streams.Stream_Element
                               (Made.all (Made.all'First + At_Byte
                                          + B.Byte_Count (Which - 1)));
                        end loop;
                        Ada.Streams.Stream_IO.Write (Output, Out_Room);
                        At_Byte := At_Byte + Room;
                     end;
                  end loop;
               end;

               Ada.Streams.Stream_IO.Close (Output);
            end;

            B.Free (Made);
         end if;

         Result.Ran := True;

         <<Give_Up>>
         Containers.Close (Item);
         Files.Close (Source);
      end;

      --  And the comparison, which is a second reading of two files and not
      --  a property of the writing above: it is what says two encoders read
      --  the same rule the same way.
      if Against /= "" and then Into /= "" then
         Compare (Into, Against, Result);
      end if;

      Result.Seconds :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   end Run;

end Quantize_Run;
