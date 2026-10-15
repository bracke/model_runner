with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

with Project_Tools.Files;

package body State_Dump is

   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package Vocab renames Model_Runner.Tokenizer;
   package Containers renames Model_Runner.GGUF.Containers;
   package Files renames Model_Runner.Byte_Sources.Files;
   package S renames Ada.Streams.Stream_IO;

   use type N.Element_Count;
   use type N.Real;

   procedure Run
     (Model   : String;
      Texts   : String;
      Into    : String;
      Backend : Model_Runner.Backend.Backend_Kind;
      Top     : Positive;
      Most    : Positive;
      Result  : out Report;
      Round   : Boolean := False;
      Check   : Boolean := False)
   is
      Source    : aliased Files.File_Source;
      Container : Containers.Container;
      Engine    : aliased L.Model;
      Status    : E.Error_Info;
      List      : Ada.Text_IO.File_Type;
      Out_File  : S.File_Type;
      Out_At    : S.Stream_Access;

      procedure Say (Item : String) is
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Item);
      end Say;
      On_Device : constant Boolean :=
        Model_Runner.Backend."=" (Backend, Model_Runner.Backend.Backend_Device);
   begin
      Result := (others => <>);

      --  The processor's arithmetic as run's default has it, where asked:
      --  its products over activations rounded to bytes.
      if Round then
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (L.Quantized_Roles (L.Integer_Activations));
      end if;

      --  The device is the program's to open before a model is prepared
      --  on it; prepared unopened, every batch answered that it was
      --  closed.
      if Model_Runner.Backend."=" (Backend, Model_Runner.Backend.Backend_Device)
      then
         declare
            Awake : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Awake);
            if not Awake then
               Say ("dump-states: no device answered");
               Result.Failed := True;
               return;
            end if;
            if Round then
               Model_Runner.Backend.Device.Round_Walks
                 (Model_Runner.Platform.Device.Products.Rounds_Every);
            end if;
         end;
      end if;

      Files.Open (Source, Model, Status => Status);
      if E.Is_Ok (Status) then
         Containers.Reader.Parse (Container, Source, Status => Status);
      end if;
      if E.Is_Ok (Status) then
         --  As run prepares and opens it: the context half precision,
         --  paged on the device, so that the states trained on are the
         --  states the drafting block is handed in a run.
         L.Prepare (Engine, Container, Source, Backend => Backend,
                    Status => Status, Context => Most,
                    Cache => L.Halved, Paged => On_Device);
      end if;
      if E.Is_Error (Status) then
         Say ("dump-states: the model would not load: "
              & E.Error_Code'Image (Status.Code));
         Result.Failed := True;
         return;
      end if;

      S.Create (Out_File, S.Out_File, Into);
      Out_At := S.Stream (Out_File);
      Ada.Text_IO.Open (List, Ada.Text_IO.In_File, Texts);

      declare
         Settings : constant L.Configuration := L.Config (Engine);
         Width    : constant N.Element_Count :=
           N.Element_Count (Settings.Embedding);
         Wide     : constant N.Element_Count :=
           N.Element_Count (Settings.Vocabulary);
         Batch    : constant Positive := L.Max_Batch;

         States, Every : T.Real_Array_Access;
         Last_Row      : T.Real_Array (0 .. Wide - 1);
      begin
         T.Allocate (Width * N.Element_Count (Batch), States);
         T.Allocate (Wide * N.Element_Count (Batch), Every);

         while not Ada.Text_IO.End_Of_File (List) loop
            declare
               Path : constant String := Ada.Text_IO.Get_Line (List);
            begin
               if Path'Length = 0 then
                  goto Next_Text;
               end if;

               declare
                  Text : constant String :=
                    Project_Tools.Files.Read_Raw_File (Path);
                  Held : Vocab.Token_Array (1 .. 70_000);
                  Last : Natural := 0;
                  Live : L.Session;
               begin
                  Vocab.Encode
                    (L.Vocabulary (Engine).all, Text,
                     Add_Beginning =>
                       Vocab.Adds_Beginning (L.Vocabulary (Engine).all),
                     Add_End => False,
                     Target => Held, Last => Last, Status => Status);
                  if E.Is_Error (Status) or else Last < 2 then
                     Say ("dump-states: skipped " & Path);
                     goto Next_Text;
                  end if;
                  Last := Natural'Min (Last, Most);

                  L.Open (Live, Engine, Context => Last, Status => Status,
                          Cache => L.Halved, Paged => On_Device);
                  if E.Is_Error (Status) then
                     Say ("dump-states: no session for " & Path & ": "
                          & E.Error_Code'Image (Status.Code));
                     Result.Failed := True;
                     exit;
                  end if;

                  --  The whole record held until every batch is in, and
                  --  written then or not at all: a record cut short is a
                  --  file a reader misparses from there on.
                  declare
                     type Row_Of_States is
                       array (N.Element_Count range <>) of Float;
                     type Row_Access is access Row_Of_States;
                     procedure Free is new Ada.Unchecked_Deallocation
                       (Row_Of_States, Row_Access);
                     type Row_Of_Ids is
                       array (N.Element_Count range <>) of Interfaces.Integer_32;
                     type Ids_Access is access Row_Of_Ids;
                     procedure Free is new Ada.Unchecked_Deallocation
                       (Row_Of_Ids, Ids_Access);
                     Kept : Row_Access :=
                       new Row_Of_States (0 .. Width * N.Element_Count (Last)
                                                - 1);
                     Top_Ids : Ids_Access :=
                       new Row_Of_Ids (0 .. N.Element_Count (Last * Top) - 1);
                     Top_Lps : Row_Access :=
                       new Row_Of_States (0 .. N.Element_Count (Last * Top) - 1);
                     Lo : Positive := 1;
                  begin
                     while Lo <= Last loop
                        declare
                           Hi : constant Positive :=
                             Positive'Min (Lo + Batch - 1, Last);
                           Count : constant N.Element_Count :=
                             N.Element_Count (Hi - Lo + 1);
                        begin
                           L.Evaluate_Batch
                             (Live, Engine, Held (Lo .. Hi), Last_Row,
                              States => States, Every => Every,
                              Status => Status);
                           if E.Is_Error (Status) then
                              --  The record is cut short, so the file is
                              --  not one to read: said, and the run ends.
                              Say ("dump-states: a batch failed: "
                                   & E.Error_Code'Image (Status.Code));
                              Result.Failed := True;
                              exit;
                           end if;

                           for Row in 0 .. Count - 1 loop
                              declare
                                 At_Row : constant N.Element_Count :=
                                   Every.all'First + Row * Wide;
                                 Most_Seen : N.Real := N.Real'First;
                                 Sum : Long_Float := 0.0;
                                 Best : array (1 .. Top) of N.Element_Count :=
                                   [others => 0];
                                 Best_Of : array (1 .. Top) of N.Real :=
                                   [others => N.Real'First];
                              begin
                                 for C in 0 .. Wide - 1 loop
                                    declare
                                       V : constant N.Real :=
                                         Every.all (At_Row + C);
                                    begin
                                       if V > Most_Seen then
                                          Most_Seen := V;
                                       end if;
                                       if V > Best_Of (Top) then
                                          declare
                                             K : Positive := Top;
                                          begin
                                             while K > 1
                                               and then V > Best_Of (K - 1)
                                             loop
                                                Best_Of (K) := Best_Of (K - 1);
                                                Best (K) := Best (K - 1);
                                                K := K - 1;
                                             end loop;
                                             Best_Of (K) := V;
                                             Best (K) := C;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                                 for C in 0 .. Wide - 1 loop
                                    Sum := Sum + Long_Float
                                      (N.Exp (N.Wide_Real
                                         (Every.all (At_Row + C)
                                          - Most_Seen)));
                                 end loop;
                                 declare
                                    Norm : constant Long_Float :=
                                      Long_Float (Most_Seen)
                                      + Long_Float (N.Log (N.Wide_Real (Sum)));
                                 begin
                                    for K in 1 .. Top loop
                                       declare
                                          At_Top : constant N.Element_Count :=
                                            (N.Element_Count (Lo - 1) + Row)
                                            * N.Element_Count (Top)
                                            + N.Element_Count (K - 1);
                                       begin
                                          Top_Ids (At_Top) :=
                                            Interfaces.Integer_32 (Best (K));
                                          Top_Lps (At_Top) :=
                                            Float (Long_Float (Best_Of (K))
                                                   - Norm);
                                       end;
                                    end loop;
                                 end;
                              end;
                           end loop;

                           for I in 0 .. Width * Count - 1 loop
                              Kept (Width * N.Element_Count (Lo - 1) + I) :=
                                Float (States.all (States.all'First + I));
                           end loop;
                           Lo := Hi + 1;
                        end;
                     end loop;

                     --  The engine's own block along the text, each position
                     --  given the true token and the stack's state, against
                     --  the model's likeliest token one further on: what a
                     --  drafting round keeps, without the rounds.
                     if Check and then not Result.Failed then
                        declare
                           Logits : N.Real_Array (0 .. Wide - 1);
                           State  : N.Real_Array (0 .. Width - 1);
                           Made   : N.Real_Array (0 .. Width - 1);
                           Agreed, Asked : Natural := 0;
                        begin
                           for P in 0 .. Last - 3 loop
                              for I in State'Range loop
                                 State (I) := N.Real
                                   (Kept (Width * N.Element_Count (P) + I));
                              end loop;
                              L.Draft_Next
                                (Live, Engine, Held (P + 2), State, P,
                                 Logits, Made, Status);
                              if E.Is_Error (Status) then
                                 Say ("dump-states: the block would not run: "
                                      & E.Error_Code'Image (Status.Code));
                                 Result.Failed := True;
                                 exit;
                              end if;
                              declare
                                 Best : N.Element_Count := 0;
                              begin
                                 for C in Logits'Range loop
                                    if Logits (C) > Logits (Best) then
                                       Best := C;
                                    end if;
                                 end loop;
                                 Asked := Asked + 1;
                                 if Interfaces."="
                                      (Interfaces.Integer_32 (Best),
                                       Top_Ids (N.Element_Count (P + 1)
                                                * N.Element_Count (Top)))
                                 then
                                    Agreed := Agreed + 1;
                                 end if;
                              end;
                           end loop;
                           Say ("dump-states: " & Path & ": the block agrees"
                                & Natural'Image (Agreed) & " of"
                                & Natural'Image (Asked));
                        end;
                     end if;

                     if not Result.Failed then
                        Interfaces.Integer_32'Write
                          (Out_At, Interfaces.Integer_32 (Last));
                        Interfaces.Integer_32'Write
                          (Out_At, Interfaces.Integer_32 (Width));
                        Interfaces.Integer_32'Write
                          (Out_At, Interfaces.Integer_32 (Top));
                        for Index in 1 .. Last loop
                           Interfaces.Integer_32'Write
                             (Out_At, Interfaces.Integer_32 (Held (Index)));
                        end loop;
                        for P in 0 .. N.Element_Count (Last) - 1 loop
                           for K in 0 .. N.Element_Count (Top) - 1 loop
                              Interfaces.Integer_32'Write
                                (Out_At, Top_Ids (P * N.Element_Count (Top) + K));
                           end loop;
                           for K in 0 .. N.Element_Count (Top) - 1 loop
                              Float'Write
                                (Out_At, Top_Lps (P * N.Element_Count (Top) + K));
                           end loop;
                        end loop;
                        Row_Of_States'Write (Out_At, Kept.all);
                     end if;
                     Free (Kept);
                     Free (Top_Ids);
                     Free (Top_Lps);
                  end;

                  L.Close (Live);
                  exit when Result.Failed;
                  Result.Texts := Result.Texts + 1;
                  Result.Positions := Result.Positions + Last;
                  Say ("dump-states:" & Natural'Image (Result.Texts)
                       & " texts," & Natural'Image (Result.Positions)
                       & " positions");
               end;
            end;
            <<Next_Text>>
            exit when Result.Failed;
         end loop;

         T.Free (States);
         T.Free (Every);
      end;

      Ada.Text_IO.Close (List);
      S.Close (Out_File);
      L.Close (Engine, Status);
      Containers.Close (Container);
      Files.Close (Source);
   end Run;

end State_Dump;
