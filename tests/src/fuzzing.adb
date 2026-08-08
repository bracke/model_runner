with Ada.Real_Time;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Numerics;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.Llama;
with Model_Runner.Templates;

with Tiny_Model;

package body Fuzzing is

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package Containers renames Model_Runner.GGUF.Containers;

   --  Wall-clock-free bound on how much work one case may cost. The parser's
   --  own limits are tightened so that a mutation cannot ask for a large
   --  allocation or a long loop before being rejected.
   function Bounds return Model_Runner.Limits.Model_Limits is
      Result : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
   begin
      Result.Max_Metadata_Entries := 256;
      Result.Max_Tensors := 256;
      Result.Max_String_Bytes := 65_536;
      Result.Max_Array_Elements := 16_384;
      Result.Max_Metadata_Pool_Bytes := 4 * 1024 * 1024;
      Result.Max_Tensor_Elements := 1024 * 1024;
      Result.Max_Tensor_Bytes := 16 * 1024 * 1024;
      Result.Max_Vocabulary := 4096;
      return Result;
   end Bounds;

   --  Deterministic per-case stream: the same seed and case number always
   --  produce the same mutation, so a failure can be replayed exactly.
   type Stream_State is record
      Value : Interfaces.Unsigned_64 := 0;
   end record;

   procedure Next (Item : in out Stream_State; Result : out Interfaces.Unsigned_64)
   is
   begin
      Item.Value := Item.Value + 16#9E37_79B9_7F4A_7C15#;
      Result := Item.Value;
      Result := (Result xor Interfaces.Shift_Right (Result, 30))
        * 16#BF58_476D_1CE4_E5B9#;
      Result := (Result xor Interfaces.Shift_Right (Result, 27))
        * 16#94D0_49BB_1331_11EB#;
      Result := Result xor Interfaces.Shift_Right (Result, 31);
   end Next;

   function Draw
     (Item  : in out Stream_State;
      Limit : Interfaces.Unsigned_64) return Interfaces.Unsigned_64
   is
      Value : Interfaces.Unsigned_64;
   begin
      Next (Item, Value);
      return (if Limit = 0 then 0 else Value mod Limit);
   end Draw;

   --------------
   -- Run_Case --
   --------------

   function Run_Case
     (Seed        : Interfaces.Unsigned_64;
      Case_Number : Positive) return Outcome
   is
      Stream : Stream_State :=
        (Value => Seed xor (Interfaces.Unsigned_64 (Case_Number) * 2_654_435_761));
      Image  : B.Byte_Array_Access;
      Result : Outcome := Rejected;
   begin
      --  Half the campaign works on quantized weights. The suppressed index,
      --  range and overflow checks are in the quantized decode loops, so a
      --  campaign that only ever mutates a model of binary32 weights never
      --  drives them at all -- it runs the forward pass down a path where
      --  every check is still in force. Which half a case falls in is derived
      --  from its number, so a reported failure still replays exactly.
      Tiny_Model.Build
        (Image,
         Format => (if Case_Number mod 2 = 0
                    then Tiny_Model.Q8_0
                    else Tiny_Model.Float32));

      declare
         Kind   : constant Interfaces.Unsigned_64 := Draw (Stream, 7);
         Length : B.Byte_Count := Image.all'Length;
      begin
         case Kind is
            when 0 =>
               --  Truncate at an arbitrary offset.
               Length := B.Byte_Count (Draw (Stream, Interfaces.Unsigned_64 (Length)));

            when 1 =>
               --  Flip one byte anywhere, which reaches counts, offsets, type
               --  tags, dimensions and tokenizer tables alike.
               declare
                  Where : constant B.Byte_Count :=
                    B.Byte_Count (Draw (Stream, Interfaces.Unsigned_64 (Length)));
                  Bit   : constant Natural := Natural (Draw (Stream, 8));
               begin
                  Image.all (Where + 1) :=
                    Image.all (Where + 1) xor B.Byte (2 ** Bit);
               end;

            when 2 =>
               --  Overwrite a header field with a large value: counts and the
               --  data-section geometry live in the first bytes.
               declare
                  Where : constant B.Byte_Count :=
                    B.Byte_Count (Draw (Stream, 24));
                  Value : constant Interfaces.Unsigned_64 :=
                    Interfaces.Shift_Left (1, Natural (Draw (Stream, 63)));
                  Patch : constant B.Byte_Array := B.Put_U64 (Value);
               begin
                  if Where + 8 <= Length then
                     Image.all (Where + 1 .. Where + 8) := Patch;
                  end if;
               end;

            when 3 =>
               --  Overwrite a 32-bit field, which is where value-type tags,
               --  tensor type identifiers and ranks live.
               declare
                  Where : constant B.Byte_Count :=
                    B.Byte_Count (Draw (Stream, Interfaces.Unsigned_64 (Length)));
                  Value : constant Interfaces.Unsigned_32 :=
                    Interfaces.Unsigned_32 (Draw (Stream, 16#1_0000#));
                  Patch : constant B.Byte_Array := B.Put_U32 (Value);
               begin
                  if Where + 4 <= Length then
                     Image.all (Where + 1 .. Where + 4) := Patch;
                  end if;
               end;

            when 4 =>
               --  Splice a run of bytes, which corrupts string lengths and
               --  UTF-8 sequences in the tokenizer and template tables.
               declare
                  Where : constant B.Byte_Count :=
                    B.Byte_Count (Draw (Stream, Interfaces.Unsigned_64 (Length)));
                  Span  : constant B.Byte_Count :=
                    B.Byte_Count (Draw (Stream, 32)) + 1;
                  Fill  : constant B.Byte :=
                    B.Byte (Draw (Stream, 256));
               begin
                  for Offset in 0 .. Span - 1 loop
                     exit when Where + Offset + 1 > Length;
                     Image.all (Where + Offset + 1) := Fill;
                  end loop;
               end;

            when 5 =>
               --  Write a control byte into the image. A bit flip reaches
               --  one only by chance, and it is worth reaching on purpose:
               --  a control character inside a string is still valid UTF-8,
               --  so a file carrying one parses and then has to be rendered
               --  by something that will not act on it.
               declare
                  Where : constant B.Byte_Count :=
                    B.Byte_Count (Draw (Stream, Interfaces.Unsigned_64 (Length)));
                  Codes : constant array (0 .. 3) of B.Byte :=
                    [16#1B#, 16#07#, 16#7F#, 16#00#];
               begin
                  if Where + 1 <= Length then
                     Image.all (Where + 1) :=
                       Codes (Natural (Draw (Stream, 4)));
                  end if;
               end;

            when others =>
               --  Append trailing bytes.
               null;
         end case;

         declare
            Bytes  : aliased constant B.Byte_Array :=
              Image.all (Image.all'First .. Image.all'First + Length - 1);
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Bytes'Access);
            Item   : Containers.Container;
            Status : E.Error_Info;
         begin
            Containers.Reader.Parse (Item, Source, Bounds, null, null, Status);

            if E.Is_Ok (Status) then
               --  An accepted container must be internally consistent: the
               --  tensor ranges it reports have to lie inside the bytes that
               --  were actually supplied.
               Result := Accepted;

               for Index in 1 .. Containers.Tensor_Count (Item) loop
                  declare
                     Start : constant Interfaces.Unsigned_64 :=
                       Containers.Tensor_Offset (Item, Index);
                     Size  : constant Interfaces.Unsigned_64 :=
                       Containers.Tensor_Bytes (Item, Index);
                  begin
                     if Start + Size > Interfaces.Unsigned_64 (Length) then
                        Result := Accepted_But_Invalid;
                     end if;
                  end;
               end loop;

               --  Whatever it says, it must be sayable. Every metadata
               --  value and key is rendered the way inspect renders them,
               --  and nothing a terminal would act on may come back: a file
               --  that steers a screen is a file accepted into a state it
               --  should not have reached, whatever else is consistent about
               --  it. One hand-built file held this; these are thousands.
               for Index in 1 .. Containers.Metadata_Count (Item) loop
                  declare
                     Shown : constant String :=
                       Containers.Value_Image (Item, Index);
                     Named : constant String :=
                       Model_Runner.Text.Escape_Controls
                         (Containers.Metadata_Key (Item, Index));
                  begin
                     if (for some Char of Shown =>
                           Character'Pos (Char) < 16#20#
                             or else Character'Pos (Char) = 16#7F#)
                       or else (for some Char of Named =>
                                  Character'Pos (Char) < 16#20#
                                    or else Character'Pos (Char) = 16#7F#)
                     then
                        Result := Accepted_But_Invalid;
                     end if;
                  end;
               end loop;

               for Index in 1 .. Containers.Tensor_Count (Item) loop
                  declare
                     Named : constant String :=
                       Model_Runner.Text.Escape_Controls
                         (Containers.Tensor_Name (Item, Index));
                  begin
                     if (for some Char of Named =>
                           Character'Pos (Char) < 16#20#
                             or else Character'Pos (Char) = 16#7F#)
                     then
                        Result := Accepted_But_Invalid;
                     end if;
                  end;
               end loop;

               --  A tokenizer that loads must report a vocabulary that its own
               --  accessors can serve.
               declare
                  Words : Model_Runner.Tokenizer.Vocabulary;
                  Load  : E.Error_Info;
               begin
                  Model_Runner.Tokenizer.Load (Words, Item, Bounds, Load);
                  if E.Is_Ok (Load) then
                     for Token in 0 .. Model_Runner.Tokenizer.Size (Words) - 1
                     loop
                        if not Model_Runner.Tokenizer.Is_Valid
                                 (Words,
                                  Model_Runner.Tokenizer.Token_Id (Token))
                        then
                           Result := Accepted_But_Invalid;
                        end if;
                     end loop;
                  end if;
                  Model_Runner.Tokenizer.Close (Words);
               end;

               --  A chat template is compiled from text the file supplies,
               --  and it is the most program-like thing a model carries: it
               --  has loops and conditionals and its own bounds. Compiling it
               --  was outside the campaign, so nothing here was ever driven
               --  by a mutated template.
               declare
                  Template : Model_Runner.Templates.Compiled;
                  Outcome  : E.Error_Info;
                  Text     : constant String :=
                    Containers.String_Value (Item, "tokenizer.chat_template");
               begin
                  if Text /= "" then
                     Model_Runner.Templates.Compile
                       (Template, Text, Bounds, Outcome);
                  end if;
                  Model_Runner.Templates.Close (Template);
               end;

               --  And preparation, which is the gate the campaign's own
               --  contract names: an invalid model must not reach an
               --  executable state. Until now nothing checked that the gate
               --  was ever reached, only that the container parsed.
               declare
                  Prepared : Model_Runner.Llama.Model;
                  Outcome  : E.Error_Info;
                  Closing  : E.Error_Info;
               begin
                  Model_Runner.Llama.Prepare
                    (Prepared, Item, Source, Bounds, null, null, Outcome);

                  --  A model that prepared is a model the engine would run,
                  --  so run it. Until now the campaign stopped here, which
                  --  left the forward pass -- and with it the quantization
                  --  kernels, the one place this project suppresses index,
                  --  range and overflow checks -- never driven by a mutated
                  --  file. Weight bytes are among the bytes being mutated.
                  --
                  --  Either outcome is acceptable: logits, or a structured
                  --  refusal such as a non-finite value found in a tensor.
                  --  What is not acceptable is an escaped exception, and the
                  --  handler around this case is what catches that.
                  if E.Is_Ok (Outcome) then
                     declare
                        Width : constant Natural :=
                          Model_Runner.Tokenizer.Size
                            (Model_Runner.Llama.Vocabulary (Prepared).all);
                     begin
                        if Width > 0 then
                           declare
                              Live   : Model_Runner.Llama.Session;
                              Opened : E.Error_Info;
                              Ran    : E.Error_Info;
                              Last : constant Model_Runner.Numerics.Element_Count
                                := Model_Runner.Numerics.Element_Count
                                     (Width - 1);
                              Logits : Model_Runner.Numerics.Real_Array
                                (0 .. Last);
                           begin
                              Model_Runner.Llama.Open
                                (Live, Prepared, Status => Opened);

                              if E.Is_Ok (Opened) then
                                 Model_Runner.Llama.Evaluate
                                   (Live, Prepared,
                                    Model_Runner.Tokenizer.Token_Id (0),
                                    Logits, Status => Ran);
                              end if;

                              Model_Runner.Llama.Close (Live);
                           end;
                        end if;
                     end;
                  end if;

                  Model_Runner.Llama.Close (Prepared, Closing);
               end;

            elsif Status.Code in E.Memory_Limit_Exceeded
                               | E.Memory_Allocation_Failed
                               | E.Tokenizer_Vocabulary_Too_Large
                               | E.GGUF_Array_Too_Large
                               | E.GGUF_Metadata_Count_Too_Large
                               | E.GGUF_Tensor_Count_Too_Large
            then
               Result := Resource_Limited;
            else
               Result := Rejected;
            end if;

            Containers.Close (Item);
         end;
      end;

      B.Free (Image);
      return Result;
   exception
      --  Anything that reaches here escaped the parser, which is exactly the
      --  outcome the campaign exists to detect.
      when others =>
         B.Free (Image);
         return Escaped_Exception;
   end Run_Case;

   ---------
   -- Run --
   ---------

   procedure Run
     (Seed   : Interfaces.Unsigned_64;
      Cases  : Positive;
      Result : out Report) is
   begin
      Result := (others => <>);
      Result.Cases := Cases;

      for Index in 1 .. Cases loop
         declare
            use type Ada.Real_Time.Time;
            Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            What    : constant Outcome := Run_Case (Seed, Index);
            Spent   : constant Duration :=
              Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
         begin
            if Spent > Case_Time_Limit then
               Result.Slow := Result.Slow + 1;
               if Result.First_Bad = 0 then
                  Result.First_Bad := Index;
               end if;
            end if;

            case What is
               when Accepted =>
                  Result.Accepted := Result.Accepted + 1;
               when Rejected =>
                  Result.Rejected := Result.Rejected + 1;
               when Resource_Limited =>
                  Result.Bounded := Result.Bounded + 1;
               when Escaped_Exception =>
                  Result.Escaped := Result.Escaped + 1;
                  if Result.First_Bad = 0 then
                     Result.First_Bad := Index;
                  end if;
               when Accepted_But_Invalid =>
                  Result.Invalid := Result.Invalid + 1;
                  if Result.First_Bad = 0 then
                     Result.First_Bad := Index;
                  end if;
               when Took_Too_Long =>
                  --  Run_Case never returns this: a case is timed here, around
                  --  the call, because the stage that overran cannot time itself.
                  null;
            end case;
         end;
      end loop;
   end Run;

end Fuzzing;
