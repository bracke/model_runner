with Ada.Unchecked_Conversion;

with Interfaces;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

with Tiny_Model;

package body Fixture_Mutation is

   use type Interfaces.Unsigned_32;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;

   --  A binary32 and the word holding its bits are the same four bytes; the
   --  conversion says so where the compiler can see it.
   function To_Real is new Ada.Unchecked_Conversion
     (Interfaces.Unsigned_32, N.Real);
   function To_Word is new Ada.Unchecked_Conversion
     (N.Real, Interfaces.Unsigned_32);

   ---------
   -- Run --
   ---------

   procedure Run
     (Result : out Report;
      Say    : access procedure (Line : String) := null) is
      --  A short sequence, long enough that attention reads a past position
      --  and short enough that the whole run stays a few seconds. What is
      --  being asked is whether a tensor is read at all, and one position of
      --  context is enough to ask it.
      Tokens : constant Model_Runner.Tokenizer.Token_Array :=
        [Model_Runner.Tokenizer.Token_Id (4),
         Model_Runner.Tokenizer.Token_Id (5),
         Model_Runner.Tokenizer.Token_Id (6)];

      Words  : constant Natural := Tiny_Model.Vocabulary;

      subtype Logit_Row is N.Real_Array (0 .. N.Element_Count (Words) - 1);

      --  Evaluate one image and report the logits it produced.
      --
      --  The image is passed by value into a source the model reads from, as
      --  every other user of these fixtures does.
      procedure Answer
        (Image  : B.Byte_Array;
         Logits : out Logit_Row;
         Ok     : out Boolean)
      is
         Held    : aliased constant B.Byte_Array := Image;
         Source  : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed  : Containers.Container;
         Engine  : L.Model;
         Session : L.Session;
         Status  : E.Error_Info;
      begin
         Logits := [others => 0.0];
         Ok     := False;

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            return;
         end if;

         L.Prepare (Engine, Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            Containers.Close (Parsed);
            return;
         end if;

         L.Open (Session, Engine, Status => Status);
         if E.Is_Error (Status) then
            L.Close (Engine, Status);
            Containers.Close (Parsed);
            return;
         end if;

         for Token of Tokens loop
            L.Evaluate (Session, Engine, Token, Logits, Status => Status);
            exit when E.Is_Error (Status);
         end loop;

         Ok := E.Is_Ok (Status);

         L.Close (Session);
         L.Close (Engine, Status);
         Containers.Close (Parsed);
      end Answer;

      --  Move every element of one tensor of an image, in place.
      --
      --  Only a binary32 fixture is moved, which is why the run builds one:
      --  moving a quantized element means decoding its block, changing it and
      --  encoding the block again, and what is being asked here has nothing
      --  to do with the format.
      --
      --  @param Image  Bytes to change.
      --  @param Parsed The container describing them.
      --  @param Index  Which tensor.
      procedure Displace
        (Image  : in out B.Byte_Array;
         Parsed : Containers.Container;
         Index  : Positive)
      is
         use type B.Byte_Count;

         --  Where the tensor's bytes begin in the file. The container
         --  reports this from the start of the file rather than from the
         --  start of the data section, and adding the section's own offset
         --  to it puts every tensor past the first one somewhere it is not:
         --  the first version did, and every tensor of the second half of
         --  every fixture then read as one nothing answered to, because the
         --  bytes moved were the ones past the end that this refuses to
         --  touch.
         First : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Offset (Parsed, Index));
         Count : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Bytes (Parsed, Index));
      begin
         if Count = 0 or else First + Count > Image'Length then
            return;
         end if;

         --  Four bytes an element, little-endian, which is what the
         --  reader takes them for. Read into an unsigned word and converted
         --  rather than overlaid on a Real: an overlay is an aliasing the
         --  compiler is entitled not to believe in, and the first version of
         --  this moved nothing at all for half the tensors in every file
         --  while reporting them as read by nobody.
         declare
            Elements : constant B.Byte_Count := Count / 4;
         begin
            for Which in 0 .. Elements - 1 loop
               declare
                  At_Byte : constant B.Byte_Count :=
                    Image'First + First + 4 * Which;
                  Word    : Interfaces.Unsigned_32 :=
                    Interfaces.Unsigned_32 (Image (At_Byte))
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Image (At_Byte + 1)), 8)
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Image (At_Byte + 2)), 16)
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Image (At_Byte + 3)), 24);
                  Held    : N.Real := To_Real (Word);
               begin
                  --  Moved by a displacement whose sign follows a hash of
                  --  the element's index rather than a pattern with a
                  --  period. Two simpler rules failed first, and both
                  --  failed the same way: a normalization that subtracts
                  --  the mean removes whatever a projection adds equally to
                  --  every element of the row it produces. Moving every
                  --  element the same way does exactly that; moving them
                  --  alternately does it too, because a row of even length
                  --  holds the same alternation as every other row, so
                  --  every output element still moves by the same amount.
                  --  A hash has no period to line up with a row length, so
                  --  what it moves is the direction of the row and not its
                  --  offset.
                  Held := Held
                    + (if (Interfaces.Shift_Right
                             (Interfaces.Unsigned_32 (Which mod 65_536)
                              * 2_654_435_761, 17) and 1) = 0
                       then N.Real (Displacement)
                       else -N.Real (Displacement));
                  Word := To_Word (Held);

                  Image (At_Byte) :=
                    B.Byte (Word and 16#FF#);
                  Image (At_Byte + 1) :=
                    B.Byte (Interfaces.Shift_Right (Word, 8) and 16#FF#);
                  Image (At_Byte + 2) :=
                    B.Byte (Interfaces.Shift_Right (Word, 16) and 16#FF#);
                  Image (At_Byte + 3) :=
                    B.Byte (Interfaces.Shift_Right (Word, 24) and 16#FF#);
               end;
            end loop;
         end;
      end Displace;

   begin
      Result := (others => <>);

      for Kind in Tiny_Model.Fixture_Architecture loop
         declare
            Image  : B.Byte_Array_Access;
            Parsed : Containers.Container;
            Plain  : Logit_Row := [others => 0.0];
            Ok     : Boolean;
            Status : E.Error_Info;
         begin
            Tiny_Model.Build (Image, Tiny_Model.F32, Kind => Kind);

            if Image = null then
               Result.Refused := Result.Refused + 1;
            else
               --  Parsed once for the tensor table; every evaluation below
               --  parses its own copy, because a model reads through the
               --  container it was prepared with.
               declare
                  Held   : aliased constant B.Byte_Array := Image.all;
                  Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
                    (Held'Access);
               begin
                  Containers.Reader.Parse (Parsed, Source, Status => Status);

                  if E.Is_Error (Status) then
                     Result.Refused := Result.Refused + 1;
                  else
                     Answer (Image.all, Plain, Ok);

                     if not Ok then
                        Result.Refused := Result.Refused + 1;
                     else
                        for Index in 1 .. Containers.Tensor_Count (Parsed) loop
                           declare
                              Moved : B.Byte_Array := Image.all;
                              Other : Logit_Row := [others => 0.0];
                              Heard : Boolean := False;
                              Fine  : Boolean;
                           begin
                              Displace (Moved, Parsed, Index);
                              Answer (Moved, Other, Fine);

                              Result.Examined := Result.Examined + 1;

                              --  A fixture whose model stops loading when a
                              --  tensor moves has certainly read it: the
                              --  refusal is an answer.
                              if not Fine then
                                 Heard := True;
                              else
                                 for Which in Plain'Range loop
                                    if abs (Plain (Which) - Other (Which))
                                       > N.Real (Noticed)
                                    then
                                       Heard := True;
                                    end if;
                                 end loop;
                              end if;

                              if not Heard then
                                 Result.Unread := Result.Unread + 1;

                                 if Say /= null then
                                    Say (Tiny_Model.Fixture_Architecture'Image
                                           (Kind) & " writes "
                                         & Containers.Tensor_Name
                                             (Parsed, Index)
                                         & ", which no logit answered to");
                                 end if;
                              end if;
                           end;
                        end loop;
                     end if;

                     Containers.Close (Parsed);
                  end if;
               end;

               B.Free (Image);
            end if;
         end;
      end loop;
   end Run;

end Fixture_Mutation;
