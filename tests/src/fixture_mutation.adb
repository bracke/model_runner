with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;

with Interfaces;

with Model_Runner.Backend.Device;
with Model_Runner.Backend;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Tensors;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

with Project_Tools.Text;
with Reference_Transformer;
with Tiny_Model;

package body Fixture_Mutation is

   use type Interfaces.Unsigned_8;
   use type Model_Runner.Backend.Backend_Kind;
   use type Tiny_Model.Weight_Format;
   use type Interfaces.Unsigned_32;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package R renames Reference_Transformer;

   --  A binary32 and the word holding its bits are the same four bytes; the
   --  conversion says so where the compiler can see it.
   function To_Real is new Ada.Unchecked_Conversion
     (Interfaces.Unsigned_32, N.Real);
   function To_Word is new Ada.Unchecked_Conversion
     (N.Real, Interfaces.Unsigned_32);

   --  The shapes a supported model comes in. Named here rather than taken
   --  from the conformance sweep because the two ask different questions of
   --  the same fixtures, and a shape this cannot build is a shape this must
   --  not claim to have asked about.
   subtype Shape_Kind is Tiny_Model.Fixture_Shape;
   use all type Tiny_Model.Fixture_Shape;

   ---------
   -- Run --
   ---------

   procedure Run
     (Result : out Report;
      Say    : access procedure (Line : String) := null)
   is
      --  A short sequence, long enough that attention reads a past position
      --  and short enough that the whole run stays well inside a second.
      --  What is being asked is whether a tensor is read at all, and one
      --  position of context is enough to ask it.
      Tokens : constant Model_Runner.Tokenizer.Token_Array :=
        [Model_Runner.Tokenizer.Token_Id (4),
         Model_Runner.Tokenizer.Token_Id (5),
         Model_Runner.Tokenizer.Token_Id (6)];

      Words  : constant Natural := Tiny_Model.Vocabulary;

      use type Model_Runner.Tensors.Real_Array_Access;
      use type Tiny_Model.Fixture_Architecture;

      --  What one evaluation answers with, which is not the same thing for
      --  every architecture: a distribution over the vocabulary for a model
      --  that has a projection, and every position's state for the one that
      --  has none.
      --
      --  One row wide enough for either, filled as far as the answer goes
      --  and zero after it. The comparison is of two answers to the same
      --  question, so a tail that is zero in both says nothing either way,
      --  and a row per architecture would be two shapes of the same test.
      Room : constant Natural :=
        Natural'Max (Words, Tokens'Length * Tiny_Model.Deep_Embedding);

      subtype Logit_Row is N.Real_Array (0 .. N.Element_Count (Room) - 1);

      --  Build one architecture in one shape and one format.
      procedure Raise_Fixture
        (Image  : out B.Byte_Array_Access;
         Kind   : Tiny_Model.Fixture_Architecture;
         Shape  : Shape_Kind;
         Format : Tiny_Model.Weight_Format) is
      begin
         --  Through the one mapping that says what a shape is, which the
         --  conformance sweep builds through as well. They said it
         --  separately once and disagreed about the stretched one.
         Tiny_Model.Build_Shaped (Image, Format, Kind, Shape);
      end Raise_Fixture;

      --  Evaluate one image and report the logits it produced.
      --  The image is taken by reference rather than by value. It used to be
      --  copied into a constant of this frame, which is a copy of the whole
      --  file on the stack: at two blocks of eight elements that is nothing,
      --  and at six blocks of two hundred and fifty-six with a mixture behind
      --  each it is a storage error rather than a slow test.
      procedure Answer
        (Image   : not null B.Byte_Array_Access;
         Backend : Model_Runner.Backend.Backend_Kind;
         Batched : Boolean;
         Logits  : out Logit_Row;
         Ok      : out Boolean;

         --  Why not, when not. The caller used to print its own status,
         --  which was the parse's and always clean.
         Why     : out E.Error_Info)
      is
         Source  : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
         Parsed  : Containers.Container;
         Engine  : L.Model;
         Session : L.Session;
         Status  : E.Error_Info;
      begin
         Logits := [others => 0.0];
         Ok     := False;
         Why    := E.Success;

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            Why := Status;
            return;
         end if;

         L.Prepare (Engine, Parsed, Source, Backend => Backend,
                    Status => Status);
         if E.Is_Error (Status) then
            Why := Status;
            Containers.Close (Parsed);
            return;
         end if;

         L.Open (Session, Engine, Status => Status);
         if E.Is_Error (Status) then
            Why := Status;
            L.Close (Engine, Status);
            Containers.Close (Parsed);
            return;
         end if;

         --  A token at a time, or the whole sequence in one pass. A tensor
         --  one path reads and the other does not is a difference between two
         --  implementations of the same model, and this is where it would
         --  show: the batched path kept a final normalization of its own
         --  once, and only a conformance sweep noticed.
         --  A model with no projection is asked for what it does have.
         --  Asking it for a distribution is refused by name, and a check
         --  that took the refusal for an unreadable fixture would report
         --  every tensor of that architecture as one nothing reads.
         if not L.Config (Engine).Has_Head then
            declare
               None  : N.Real_Array (1 .. 0);
               Width : constant N.Element_Count :=
                 N.Element_Count (L.Config (Engine).Embedding);
               States : Model_Runner.Tensors.Real_Array_Access := null;
            begin
               Model_Runner.Tensors.Allocate
                 (Tokens'Length * Width, States);

               if States = null then
                  Why := E.Make (E.Memory_Allocation_Failed);
                  L.Close (Session);
                  L.Close (Engine, Status);
                  Containers.Close (Parsed);
                  return;
               end if;

               L.Evaluate_Batch
                 (Session, Engine, Tokens, None, States => States,
                  Status => Status);

               if E.Is_Ok (Status) then
                  Logits (0 .. Tokens'Length * Width - 1) :=
                    States.all (0 .. Tokens'Length * Width - 1);
               end if;

               Model_Runner.Tensors.Free (States);
            end;

         --  A distribution is asked for in exactly the vocabulary's width,
         --  which is not the width of this row: the row is wide enough for
         --  either answer and a model with a head fills the first part of
         --  it. Handing over the whole row was refused as a shape mismatch
         --  by every model that has one.
         elsif Batched then
            L.Evaluate_Batch
              (Session, Engine, Tokens,
               Logits (0 .. N.Element_Count (Words) - 1), Status => Status);
         else
            for Token of Tokens loop
               L.Evaluate
                 (Session, Engine, Token,
                  Logits (0 .. N.Element_Count (Words) - 1),
                  Status => Status);
               exit when E.Is_Error (Status);
            end loop;
         end if;

         Ok  := E.Is_Ok (Status);
         Why := Status;

         L.Close (Session);
         L.Close (Engine, Status);
         Containers.Close (Parsed);
      end Answer;

      --  Move every element of one tensor of an image, in place.
      --
      --  @param Image  Bytes to change.
      --  @param Parsed The container describing them.
      --  @param Index  Which tensor.
      procedure Displace
        (Image  : in out B.Byte_Array;
         Parsed : Containers.Container;
         Index  : Positive;
         Harder : Boolean := False)
      is
         use type B.Byte_Count;

         --  Where the tensor's bytes begin in the file. The container reports
         --  this from the start of the file rather than from the start of the
         --  data section, and adding the section's own offset to it puts
         --  every tensor past the first one somewhere it is not: the first
         --  version did, and the second half of every fixture then read as
         --  tensors nothing answered to, because the bytes moved were the
         --  ones past the end that this refuses to touch.
         First : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Offset (Parsed, Index));
         Count : constant B.Byte_Count :=
           B.Byte_Count (Containers.Tensor_Bytes (Parsed, Index));

         Plain_Floats : constant Boolean :=
           Containers.Tensor_Format (Parsed, Index)
             = Model_Runner.GGUF.Type_F32;

         --  How far to move it. The second pass moves it sixty-four times
         --  as far, for the tensors a fixture is too insensitive to notice
         --  the first pass in -- a router that ranks four experts needs
         --  enough to change the ranking, not merely enough to change the
         --  scores.
         Reach : constant N.Real :=
           (if Harder then 64.0 * N.Real (Displacement)
            else N.Real (Displacement));
         Mask  : constant Interfaces.Unsigned_8 :=
           (if Harder then 16#30# else 16#03#);
      begin
         if Count = 0 or else First + Count > Image'Length then
            return;
         end if;

         --  A tensor of binary32 is moved as numbers: four bytes an element,
         --  little-endian, read into a word and converted rather than
         --  overlaid on a Real, because an overlay is an aliasing the
         --  compiler is entitled not to believe in -- and the first version
         --  of this moved nothing at all while reporting what it had failed
         --  to move as read by nobody.
         --
         --  Anything else is moved as bytes. A half format and a quantized
         --  block are different encodings of the same question, and changing
         --  their bytes changes what they decode to; decoding each format
         --  here would be a second decoder to keep correct, which is the one
         --  thing this file must not become.
         if Plain_Floats then
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
                     --  the mean removes whatever a projection adds equally
                     --  to every element of the row it produces. Moving every
                     --  element the same way does exactly that; moving them
                     --  alternately does it too, because a row of even length
                     --  holds the same alternation as every other row, so
                     --  every output element still moves by the same amount.
                     --  A hash has no period to line up with a row length, so
                     --  what it moves is the direction of the row rather than
                     --  its offset.
                     Held := Held
                       + (if (Interfaces.Shift_Right
                                (Interfaces.Unsigned_32 (Which mod 65_536)
                                 * 2_654_435_761, 17) and 1) = 0
                          then Reach
                          else -Reach);

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
         else
            for Which in 0 .. Count - 1 loop
               declare
                  At_Byte : constant B.Byte_Count :=
                    Image'First + First + Which;
               begin
                  --  The low bits, so that a block's scale keeps its
                  --  magnitude and an exponent keeps its range: what is
                  --  wanted is a different model, not an infinite one.
                  Image (At_Byte) := Image (At_Byte) xor Mask;
               end;
            end loop;
         end if;
      end Displace;

      --  Move every tensor of one fixture in turn, read by one backend on one
      --  path, and record the ones no logit answered to.
      procedure Examine
        (Kind    : Tiny_Model.Fixture_Architecture;
         Shape   : Shape_Kind;
         Format  : Tiny_Model.Weight_Format;
         Backend : Model_Runner.Backend.Backend_Kind;
         Batched : Boolean)
      is
         Image  : B.Byte_Array_Access;
         Parsed : Containers.Container;
         Given  : Logit_Row := [others => 0.0];
         Ok     : Boolean;
         Status : E.Error_Info;

         --  Tensors of this fixture whose answer is smaller than a
         --  disagreement, and which ones. Named rather than counted alone:
         --  a count says a fixture is quiet somewhere, and what is worth
         --  acting on is which part of it.
         Hushed : Natural := 0;
         Refusal : E.Error_Info;
         Named  : Ada.Strings.Unbounded.Unbounded_String;

         --  What a report has to name to be acted on: the same fixture has to
         --  be findable again out of nine hundred of them.
         function Where return String
         is (Tiny_Model.Fixture_Architecture'Image (Kind)
             & " " & Shape_Kind'Image (Shape)
             & " " & Tiny_Model.Weight_Format'Image (Format)
             & " " & Model_Runner.Backend.Backend_Kind'Image (Backend)
             & (if Batched then " batched" else " a token at a time"));
      begin
         Raise_Fixture (Image, Kind, Shape, Format);

         if Image = null then
            Result.Refused := Result.Refused + 1;
            return;
         end if;

         declare
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
         end;

         if E.Is_Error (Status) then
            Result.Refused := Result.Refused + 1;
            B.Free (Image);
            return;
         end if;

         --  What the independent implementation asks this file for, against
         --  what the file holds. Asked once a fixture rather than once a
         --  tensor: the list is the same however the file is read.
         if Backend = Model_Runner.Backend.Backend_CPU and then not Batched
         then
            declare
               Names  : aliased Ada.Strings.Unbounded.Unbounded_String;
               Second : R.Model;
               Loaded : Boolean;
            begin
               R.Load (Second, Parsed, Image.all, Loaded, Names'Access);
               R.Close (Second);

               for Index in 1 .. Containers.Tensor_Count (Parsed) loop
                  declare
                     Name : constant String :=
                       Containers.Tensor_Name (Parsed, Index);
                  begin
                     if not Project_Tools.Text.Contains
                              (Ada.Strings.Unbounded.To_String (Names),
                               Name & Character'Val (10))
                     then
                        Result.Unwanted := Result.Unwanted + 1;

                        if Say /= null then
                           Say (Where & " writes " & Name
                                & ", which the independent implementation "
                                & "never asks for");
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end if;

         Answer (Image, Backend, Batched, Given, Ok, Refusal);

         if not Ok then
            Result.Refused := Result.Refused + 1;

            if Say /= null then
               Say (Where & " would not evaluate: "
                    & E.Error_Code'Image (Refusal.Code)
                    & ", so nothing was asked of it");
            end if;

            Containers.Close (Parsed);
            B.Free (Image);
            return;
         end if;

         for Index in 1 .. Containers.Tensor_Count (Parsed) loop
            declare
               --  On the heap, for the reason the image is not copied
               --  onto the stack above.
               Moved : B.Byte_Array_Access := new B.Byte_Array'(Image.all);
               Other : Logit_Row := [others => 0.0];
               Heard : Boolean := False;
               Fine  : Boolean;

               --  The largest a logit moved, which answers both questions
               --  this asks: whether anything moved at all, and whether what
               --  moved would be called a disagreement.
               Moved_By : N.Real := 0.0;
            begin
               Displace (Moved.all, Parsed, Index);

               Answer (Moved, Backend, Batched, Other, Fine, Refusal);
               B.Free (Moved);

               Result.Examined := Result.Examined + 1;

               --  A fixture whose model stops loading when a tensor moves has
               --  certainly read it: the refusal is an answer. So is a logit
               --  that stopped being a number, which a moved quantized block
               --  can produce and which no comparison of magnitudes would
               --  report, every comparison against a value that is not a
               --  number being false.
               if not Fine then
                  Heard := True;
               else
                  for Which in Given'Range loop
                     if not N.Is_Finite (Other (Which)) then
                        Heard    := True;
                        Moved_By := N.Real'Last;
                     else
                        Moved_By :=
                          N.Real'Max
                            (Moved_By, abs (Given (Which) - Other (Which)));
                     end if;
                  end loop;

                  Heard := Moved_By > N.Real (Noticed);
               end if;

               --  A tensor that did not answer is asked again, moved
               --  sixteen times as far, before it is called unread. What is
               --  being asked is whether anything reads it -- not whether
               --  this fixture is sensitive to it -- and the two are
               --  different questions with different answers: the deep
               --  superblock fixture saturates its attention, so moving a
               --  query bias by a quarter leaves the same position winning
               --  every softmax and the same logits coming out. Answering
               --  only to the larger move is recorded rather than passed
               --  over, because a fixture that cannot feel a small mistake
               --  in a tensor is a fixture whose comparisons of that tensor
               --  are worth less than their count.
               if not Heard then
                  declare
                     Further : B.Byte_Array_Access :=
                       new B.Byte_Array'(Image.all);
                     Again   : Logit_Row := [others => 0.0];
                     Sound   : Boolean;
                  begin
                     Displace (Further.all, Parsed, Index, Harder => True);
                     Answer (Further, Backend, Batched, Again, Sound, Refusal);
                     B.Free (Further);

                     if not Sound then
                        Heard := True;
                     else
                        for Which in Given'Range loop
                           if not N.Is_Finite (Again (Which))
                             or else abs (Given (Which) - Again (Which))
                                     > N.Real (Noticed)
                           then
                              Heard := True;
                           end if;
                        end loop;
                     end if;

                     if Heard then
                        Result.Faint := Result.Faint + 1;
                     end if;
                  end;
               end if;

               --  Read, but by less than a comparison would call a
               --  disagreement. Counted where the fixture is named, so that
               --  a run says which fixture holds them rather than only how
               --  many there are.
               if Heard and then Moved_By <= N.Real (Disagreement) then
                  Result.Quiet := Result.Quiet + 1;
                  Hushed := Hushed + 1;
                  Ada.Strings.Unbounded.Append
                    (Named,
                     (if Hushed > 1 then ", " else " ")
                     & Containers.Tensor_Name (Parsed, Index));
               end if;

               if not Heard then
                  Result.Unread := Result.Unread + 1;

                  if Say /= null then
                     Say (Where & " writes "
                          & Containers.Tensor_Name (Parsed, Index)
                          & ", which no logit answered to");
                  end if;
               end if;
            end;
         end loop;

         --  Said once for the fixture rather than once for each tensor:
         --  what is worth knowing is which fixture is the quiet one and how
         --  much of it is quiet, and a line a tensor would bury that in
         --  hundreds.
         if Hushed > 0 and then Say /= null then
            Say (Where & ":" & Natural'Image (Hushed) & " of"
                 & Natural'Image (Containers.Tensor_Count (Parsed))
                 & " tensors move a logit by less than a comparison would"
                 & " call a disagreement --"
                 & Ada.Strings.Unbounded.To_String (Named));
         end if;

         Containers.Close (Parsed);
         B.Free (Image);
      end Examine;

      --  What a fixture is moved in, and what reads it.
      --
      --  Formats: binary32, both half formats, one block-quantized and one
      --  superblock-quantized. Not all fifteen: what a format changes is how
      --  a tensor's bytes decode, and whether a decoded tensor is read is the
      --  same question in each of them. The conformance sweep crosses all
      --  fifteen against the reference; this asks something else of five.
      --
      --  Shapes: all of them, because the shape decides which tensors a file
      --  holds at all. A mixture has a router and stacked experts no other
      --  shape writes, and a stretched rotation has its table of divisors;
      --  neither was ever moved while only the plain shape was built.
      --
      --  Paths: a token at a time and a whole sequence in one pass, on the
      --  processor and on the binary64 backend. The device is asked for
      --  separately below, because it may not be there.
      Formats : constant array (1 .. 5) of Tiny_Model.Weight_Format :=
        [Tiny_Model.F32, Tiny_Model.F16, Tiny_Model.BF16,
         Tiny_Model.Q4_0, Tiny_Model.Q4_K];

      type Reading is record
         Backend : Model_Runner.Backend.Backend_Kind;
         Batched : Boolean;
      end record;

      Readings : constant array (1 .. 3) of Reading :=
        [(Model_Runner.Backend.Backend_CPU, False),
         (Model_Runner.Backend.Backend_CPU, True),
         (Model_Runner.Backend.Backend_Reference, False)];
   begin
      Result := (others => <>);

      for Kind in Tiny_Model.Fixture_Architecture loop
         for Shape in Shape_Kind loop
            --  A mixture belongs to an architecture with a gate to route to.
            --  The two with none would be handed a router in front of experts
            --  that are not there, which the engine refuses -- and a refusal
            --  every time says nothing about which tensors are read.
            if Tiny_Model.Cannot_Hold (Kind, Shape) then
               --  Declared unable to hold this shape, so it is built and
               --  required to refuse. A pair that starts loading is as much
               --  a finding as one that stops: it means a skip is being
               --  taken that nothing needs any more, and every skip costs
               --  the sweep comparisons it could have made.
               declare
                  Image  : B.Byte_Array_Access;
                  Logits : Logit_Row := [others => 0.0];
                  Ok     : Boolean;
                  Why    : E.Error_Info;
               begin
                  Raise_Fixture (Image, Kind, Shape, Tiny_Model.F32);

                  if Image /= null then
                     Answer (Image, Model_Runner.Backend.Backend_CPU,
                             False, Logits, Ok, Why);
                     Result.Declared := Result.Declared + 1;

                     if Ok and then Say /= null then
                        Say (Tiny_Model.Fixture_Architecture'Image (Kind)
                             & " " & Shape_Kind'Image (Shape)
                             & " is declared a shape this architecture "
                             & "cannot hold, and it loaded");
                        Result.Unread := Result.Unread + 1;
                     end if;

                     B.Free (Image);
                  end if;
               end;
            else
               for Format of Formats loop
                  for Read of Readings loop
                     --  A model that attends both ways has no reading a
                     --  token at a time, so neither the processor's
                     --  single-token path nor the backend that declines
                     --  batching is a way to read one. Asking anyway
                     --  produced a refusal a reader would take for a fault.
                     if Kind in Tiny_Model.Bert | Tiny_Model.Nomic_Bert
                              | Tiny_Model.Jina_Bert_V2
                       and then not Read.Batched
                     then
                        Result.Unasked := Result.Unasked + 1;
                     else
                        Examine
                          (Kind, Shape, Format, Read.Backend, Read.Batched);
                     end if;
                  end loop;
               end loop;
            end if;
         end loop;
      end loop;

      --  And the device, on the plain shape, when there is one. A tensor the
      --  shader never reads answers to nothing there and to everything here,
      --  which is a difference between two decoders rather than a fixture
      --  that cannot fail -- and it is worth the same question.
      declare
         Ready : Boolean;
      begin
         Model_Runner.Backend.Device.Open (Ready);

         if Ready then
            for Kind in Tiny_Model.Fixture_Architecture loop
               for Format of Formats loop
                  --  A token at a time, except for the model that has no
                  --  such reading: asked that way it was batched anyway and
                  --  the report said otherwise, which is a line that names
                  --  a path nothing took.
                  Examine (Kind, Plain, Format,
                           Model_Runner.Backend.Backend_Device,
                           Batched =>
                             Kind in Tiny_Model.Bert | Tiny_Model.Nomic_Bert
                              | Tiny_Model.Jina_Bert_V2);
               end loop;
            end loop;
         elsif Say /= null then
            Say ("no device, so no tensor was moved under the shader");
         end if;
      end;
   end Run;

end Fixture_Mutation;
