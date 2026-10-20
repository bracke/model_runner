with Model_Runner.Numerics;

package body Model_Runner.Qwen_Image.Prompts is

   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package Vocab renames Model_Runner.Tokenizer;

   use type E.Error_Code;
   use type N.Element_Count;
   use type T.Real_Array_Access;

   procedure Encode
     (Encoder : in out L.Model'Class;
      Prompt  : String;
      Rows    : out T.Real_Array_Access;
      Count   : out Natural;
      Status  : out E.Error_Info)
   is
      Words  : constant access constant Vocab.Vocabulary := L.Vocabulary (Encoder);
      Whole  : Vocab.Token_Array (1 .. Max_Tokens);
      Opening : Vocab.Token_Array (1 .. Max_Tokens);
      Last, Dropped : Natural;
   begin
      Rows := null;
      Count := 0;

      Vocab.Encode (Words.all, Template (Prompt), False, False, Whole, Last, Status);
      if E.Is_Error (Status) then
         if Status.Code = E.Tokenizer_Buffer_Too_Small then
            Status := E.Make (E.Tokenizer_Input_Too_Long);
         end if;
         return;
      end if;
      Vocab.Encode (Words.all, System_Turn, False, False, Opening, Dropped, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  The system turn is the template's first tokens: it ends where a
      --  marker begins, and nothing reads across a marker.
      Dropped := Natural'Min (Dropped, Last);

      Rows_Of (Encoder, Whole (1 .. Last), Dropped, Rows, Status);
      if E.Is_Ok (Status) then
         Count := Last - Dropped;
      end if;
   end Encode;

   procedure Rows_Of
     (Encoder : in out L.Model'Class;
      Tokens  : Vocab.Token_Array;
      Dropped : Natural;
      Rows    : out T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Width  : constant N.Element_Count := N.Element_Count (L.Config (Encoder).Embedding);
      Kept   : constant Natural := Tokens'Length - Natural'Min (Dropped, Tokens'Length);
      Live   : L.Session;
      Limit  : constant Positive := L.Batch_Limit (Encoder);
      States : T.Real_Array_Access;
      Logits : N.Real_Array (0 .. N.Element_Count (L.Config (Encoder).Vocabulary) - 1);
      From   : Natural := 0;
   begin
      Rows := null;
      L.Open (Live, Encoder, Context => Tokens'Length, Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;
      T.Allocate (N.Element_Count (Natural'Max (Kept, 1)) * Width, Rows);
      T.Allocate (N.Element_Count (Natural'Min (Limit, Tokens'Length)) * Width, States);
      if Rows = null or else States = null then
         T.Free (Rows);
         T.Free (States);
         L.Close (Live);
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      --  From and Upto count positions from nought.
      while From < Tokens'Length loop
         declare
            Upto : constant Natural := Natural'Min (Tokens'Length, From + Limit) - 1;
         begin
            L.Evaluate_Batch
              (Live, Encoder, Tokens (Tokens'First + From .. Tokens'First + Upto), Logits,
               States => States, Normalized => False, Status => Status);
            exit when E.Is_Error (Status);
            for Position in Natural'Max (From, Dropped) .. Upto loop
               declare
                  Into   : constant N.Element_Count := N.Element_Count (Position - Dropped) * Width;
                  Out_Of : constant N.Element_Count := N.Element_Count (Position - From) * Width;
               begin
                  Rows (Into .. Into + Width - 1) := States (Out_Of .. Out_Of + Width - 1);
               end;
            end loop;
            From := Upto + 1;
         end;
      end loop;
      T.Free (States);
      L.Close (Live);
      if E.Is_Error (Status) then
         T.Free (Rows);
      end if;
   end Rows_Of;

end Model_Runner.Qwen_Image.Prompts;
