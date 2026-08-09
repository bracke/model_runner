with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

with Reference_Transformer;
with Model_Runner.Backend;
with Tiny_Model;

package body Conformance is

   use type Model_Runner.Numerics.Element_Count;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package R renames Reference_Transformer;

   ---------
   -- Run --
   ---------

   procedure Run (Result : out Report) is
      Image : B.Byte_Array_Access;

      --  The sequences to compare. Lengths differ so that the comparison
      --  covers one token, a short context, and a context long enough that
      --  attention reads several past positions.
      type Sequence is array (Positive range <>) of Natural;

      --  Compare one sequence, evaluated by the named backend, against the
      --  independent implementation.
      procedure Compare
        (Tokens  : Sequence;
         Backend : Model_Runner.Backend.Backend_Kind :=
           Model_Runner.Backend.Backend_CPU)
      is
         Held      : aliased constant B.Byte_Array := Image.all;
         Source    : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed    : Containers.Container;
         Engine    : L.Model;
         Session   : L.Session;
         Reference : R.Model;
         Status    : E.Error_Info;
         Loaded    : Boolean;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            return;
         end if;

         L.Prepare
           (Engine, Parsed, Source, Backend => Backend, Status => Status);
         if E.Is_Error (Status) then
            Containers.Close (Parsed);
            return;
         end if;

         R.Load (Reference, Parsed, Held, Loaded);
         if not Loaded then
            L.Close (Engine, Status);
            Containers.Close (Parsed);
            return;
         end if;

         declare
            Words  : constant Natural := R.Vocabulary (Reference);
            Expected : R.Real_Vector (0 .. Words - 1) := [others => 0.0];
            Actual   : N.Real_Array (0 .. N.Element_Count (Words) - 1) :=
              [others => 0.0];
            Produced : Boolean;
            Tokens_R : R.Token_Vector (Tokens'Range);
         begin
            for Index in Tokens'Range loop
               Tokens_R (Index) := Tokens (Index);
            end loop;

            R.Run (Reference, Tokens_R, Expected, Produced);
            if not Produced then
               R.Close (Reference);
               L.Close (Engine, Status);
               Containers.Close (Parsed);
               return;
            end if;

            L.Open (Session, Engine, Status => Status);
            if E.Is_Error (Status) then
               R.Close (Reference);
               L.Close (Engine, Status);
               Containers.Close (Parsed);
               return;
            end if;

            for Index in Tokens'Range loop
               L.Evaluate
                 (Session, Engine,
                  Model_Runner.Tokenizer.Token_Id (Tokens (Index)),
                  Actual, Status => Status);
               exit when E.Is_Error (Status);
            end loop;

            if E.Is_Ok (Status) then
               Result.Sequences := Result.Sequences + 1;

               for Token in 0 .. Words - 1 loop
                  declare
                     Left  : constant Long_Float := Expected (Token);
                     Right : constant Long_Float :=
                       Long_Float (Actual (N.Element_Count (Token)));
                     Gap   : constant Long_Float := abs (Left - Right);
                     Scale : constant Long_Float :=
                       Long_Float'Max (abs Left, abs Right);
                     Relative : constant Long_Float :=
                       (if Scale > 0.0 then Gap / Scale else 0.0);
                  begin
                     Result.Compared := Result.Compared + 1;
                     Result.Worst_Abs := Long_Float'Max (Result.Worst_Abs, Gap);
                     Result.Worst_Rel :=
                       Long_Float'Max (Result.Worst_Rel, Relative);

                     --  A logit passes when it is close in absolute terms or
                     --  close in relative terms; the absolute floor keeps a
                     --  value near zero from being judged by a ratio.
                     if Gap > Absolute_Tolerance
                       and then Relative > Relative_Tolerance
                     then
                        Result.Failures := Result.Failures + 1;
                     end if;
                  end;
               end loop;
            end if;

            L.Close (Session);
         end;

         R.Close (Reference);
         L.Close (Engine, Status);
         Containers.Close (Parsed);
      end Compare;

   begin
      Result := (others => <>);

      --  Both weight formats. The quantized one matters more: until it was
      --  added, nothing offline compared quantized inference against an
      --  independent implementation, and the only check on it was two tokens
      --  recorded from another runtime against a model that is not committed.
      --  And both architectures. Qwen2 differs from Llama in a bias on
      --  each attention projection and in which elements the rotation
      --  pairs; both are arithmetic, and neither had anything independent
      --  to be checked against until the reference learned them too.
      --  And every backend. The reference backend agreeing with the CPU one
      --  says the fast path's partitioning and batching change nothing; both
      --  of them agreeing with the independent implementation says the
      --  arithmetic is right. The second is the stronger statement and it
      --  was only ever made about one of the two.
      for Backend in Model_Runner.Backend.Backend_Kind loop
         for Qwen in Boolean loop
            for Format in Tiny_Model.Weight_Format loop
               Tiny_Model.Build (Image, Format, Qwen => Qwen);

               Compare (Sequence'(1 => 4), Backend);
               Compare (Sequence'(4, 5), Backend);
               Compare (Sequence'(1, 4, 5, 6, 7), Backend);
               Compare (Sequence'(4, 4, 4, 5, 5, 6, 7, 8), Backend);

               B.Free (Image);
            end loop;
         end loop;
      end loop;

      Result.Ran := Result.Sequences = 32;
   end Run;

end Conformance;
