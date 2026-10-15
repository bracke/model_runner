with Ada.Directories;
with Ada.Real_Time;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

with Project_Tools.Files;

with Fixtures;

package body Imatrix_Run is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package Vocab renames Model_Runner.Tokenizer;
   package Containers renames Model_Runner.GGUF.Containers;
   package Files renames Model_Runner.Byte_Sources.Files;
   package CPU renames Model_Runner.Backend.CPU;

   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type N.Element_Count;
   use type N.Real;
   use type T.Real_Array_Access;
   use type Ada.Real_Time.Time;
   use type Model_Runner.GGUF.U64;

   --  One matrix's running total: a sum of squares a column, and how many
   --  rows went into them.
   type Tally is record
      Name  : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Sums  : T.Real_Array_Access := null;
      Rows  : Long_Long_Integer := 0;
   end record;

   --  As many as the model has: a list that doubles when it fills. It was
   --  five hundred and twelve and stopped there without a word, which is
   --  fewer matrices than a model of seventy-odd layers holds. It starts
   --  at eight, so that the suite's two-layer fixture already grows it.
   type Tally_List is array (Positive range <>) of Tally;
   type Tally_List_Access is access Tally_List;

   procedure Free is new Ada.Unchecked_Deallocation
     (Tally_List, Tally_List_Access);

   --  The watcher itself.
   type Collector is limited new L.Watcher with record
      Held : Tally_List_Access := null;
      Up   : Natural := 0;
   end record;

   --  The fewest rows a product must have to be counted, as llama-imatrix
   --  has it.
   Fewest_Rows : constant := 16;

   -------------
   -- Counted --
   -------------

   function Counted (Which : String; Rows : Natural) return Boolean
   is (Rows >= Fewest_Rows
       and then Which'Length >= 4
       and then Which (Which'First .. Which'First + 3) = "blk.");

   overriding procedure Note
     (Item   : in out Collector;
      Which  : String;
      Values : N.Real_Array;
      Rows   : N.Element_Count);

   overriding procedure Note
     (Item   : in out Collector;
      Which  : String;
      Values : N.Real_Array;
      Rows   : N.Element_Count)
   is
      Width : constant N.Element_Count :=
        (if Rows = 0 then 0 else Values'Length / Rows);
      Slot  : Natural := 0;
   begin
      if Width = 0 or else not Counted (Which, Natural (Rows)) then
         return;
      end if;

      for Index in 1 .. Item.Up loop
         if Model_Runner.Text.To_String (Item.Held (Index).Name) = Which then
            Slot := Index;
            exit;
         end if;
      end loop;

      if Slot = 0 then
         if Item.Held = null or else Item.Up = Item.Held'Length then
            declare
               Grown : constant Tally_List_Access :=
                 new Tally_List
                   (1 .. (if Item.Held = null then 8
                          else 2 * Item.Held'Length));
            begin
               if Item.Held /= null then
                  Grown (1 .. Item.Up) := Item.Held (1 .. Item.Up);
                  Free (Item.Held);
               end if;
               Item.Held := Grown;
            end;
         end if;
         Item.Up := Item.Up + 1;
         Slot := Item.Up;
         Item.Held (Slot).Name := Model_Runner.Text.To_Bounded (Which);
         T.Allocate (Width, Item.Held (Slot).Sums);
         if Item.Held (Slot).Sums = null then
            Item.Up := Item.Up - 1;
            return;
         end if;
         Item.Held (Slot).Sums.all := [others => 0.0];
      end if;

      --  A matrix met by a batch is met by every row of it, and the sums
      --  are over rows: the same column of every row adds into the same
      --  place.
      if Item.Held (Slot).Sums.all'Length /= Width then
         return;
      end if;

      for Row in 0 .. Rows - 1 loop
         declare
            At_Row : constant N.Element_Count := Values'First + Row * Width;
         begin
            for Column in 0 .. Width - 1 loop
               Item.Held (Slot).Sums.all (Column) :=
                 Item.Held (Slot).Sums.all (Column)
                 + Values (At_Row + Column) * Values (At_Row + Column);
            end loop;
         end;
      end loop;

      Item.Held (Slot).Rows :=
        Item.Held (Slot).Rows + Long_Long_Integer (Rows);
   end Note;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
      package Say renames Model_Runner.Text;
   begin
      if Item.Missing then
         return "nothing collected: " & Item.Detail (1 .. Item.Detail_Up);
      end if;

      if not Item.Ran then
         return "collected nothing: " & Item.Detail (1 .. Item.Detail_Up);
      end if;

      return
        Natural'Image (Item.Tokens) & " tokens,"
        & Natural'Image (Item.Chunks) & " chunks,"
        & Natural'Image (Item.Matrices) & " matrices seen"
        & "; took " & Say.Image (Long_Float (Item.Seconds), 2) & " s";
   end Summary;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path    : String;
      Text    : String;
      Chunk   : Positive := 512;
      Chunks  : Natural := 0;
      Threads : Positive;
      Into    : String;
      Result  : out Report)
   is
      procedure Note_It (Item : String);

      procedure Note_It (Item : String) is
         Room : constant Natural :=
           Natural'Min (Item'Length, Result.Detail'Length);
      begin
         Result.Detail (1 .. Room) :=
           Item (Item'First .. Item'First + Room - 1);
         Result.Detail_Up := Room;
      end Note_It;

      Started : Ada.Real_Time.Time;
   begin
      Result := (others => <>);

      if not Ada.Directories.Exists (Path) then
         Result.Missing := True;
         Note_It ("no model at that path");
         return;
      end if;

      if not Ada.Directories.Exists (Text) then
         Result.Missing := True;
         Note_It ("no corpus at that path");
         return;
      end if;

      if Chunk > L.Max_Batch then
         Result.Missing := True;
         Note_It ("a chunk is one pass and a pass holds at most"
                  & Natural'Image (L.Max_Batch) & " tokens");
         return;
      end if;

      Started := Ada.Real_Time.Clock;

      declare
         Source    : aliased Files.File_Source;
         Container : Containers.Container;
         Engine    : aliased L.Model;
         Status    : E.Error_Info;

         Watching  : aliased Collector;
      begin
         Files.Open (Source, Path, Status => Status);
         if E.Is_Error (Status) then
            Note_It ("the model would not open: "
                     & E.Error_Code'Image (Status.Code));
            return;
         end if;

         Containers.Reader.Parse (Container, Source, Status => Status);
         if E.Is_Error (Status) then
            Files.Close (Source);
            Note_It ("the model would not parse: "
                     & E.Error_Code'Image (Status.Code));
            return;
         end if;

         L.Prepare
           (Engine, Container, Source, Threads => Threads, Status => Status);
         if E.Is_Error (Status) then
            Containers.Close (Container);
            Files.Close (Source);
            Note_It ("the model would not prepare: "
                     & E.Error_Code'Image (Status.Code));
            return;
         end if;

         declare
            Body_Text : constant String :=
              Project_Tools.Files.Read_Raw_File (Text);

            Held : Vocab.Token_Array (1 .. 70_000);
            Last : Natural := 0;

            Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
            Where : constant CPU.Pool_Reference :=
              (if Threads = 1 then null else Team'Unchecked_Access);
         begin
            --  As llama-imatrix reads it: the marker where the vocabulary
            --  adds one, and every chunk begun with it, below.
            Vocab.Encode
              (L.Vocabulary (Engine).all, Body_Text,
               Add_Beginning =>
                 Vocab.Adds_Beginning (L.Vocabulary (Engine).all),
               Add_End => False,
               Target => Held, Last => Last, Status => Status);

            if E.Is_Error (Status) or else Last = 0 then
               Note_It ("the corpus would not encode: "
                        & E.Error_Code'Image (Status.Code));
               goto Give_Back;
            end if;

            Result.Tokens := Last;

            if Last < Chunk then
               Note_It ("the corpus is shorter than one chunk");
               goto Give_Back;
            end if;

            declare
               Rounds : constant Natural :=
                 (if Chunks = 0 then Last / Chunk
                  else Natural'Min (Chunks, Last / Chunk));

               Settings : constant L.Configuration := L.Config (Engine);
               Logits   : T.Real_Array_Access;

               Live : L.Session;
            begin
               T.Allocate
                 (N.Element_Count (Settings.Vocabulary), Logits);

               for Round in 1 .. Rounds loop
                  declare
                     From : constant Natural := (Round - 1) * Chunk + 1;
                     Upto : constant Natural := From + Chunk - 1;
                  begin
                     --  Each chunk begun as a text is, where the model begins
                     --  one with a marker: llama-imatrix puts the marker in
                     --  place of every chunk's first token, and this began
                     --  only the first with it, whatever the vocabulary said.
                     if Vocab.Adds_Beginning (L.Vocabulary (Engine).all) then
                        Held (From) :=
                          Vocab.Beginning_Token (L.Vocabulary (Engine).all);
                     end if;

                     --  At the chunk's length rather than the model's own.
                     L.Open
                       (Live, Engine, Context => Chunk, Workers => Where,
                        Status => Status);
                     if E.Is_Error (Status) then
                        Note_It ("a session would not open");
                        exit;
                     end if;

                     --  Watching only for the evaluation: what a session
                     --  does opening and closing is not a product anybody
                     --  asked about.
                     L.Watch (Live, Watching'Unchecked_Access);

                     L.Evaluate_Batch
                       (Live, Engine, Held (From .. Upto), Logits.all,
                        Status => Status);

                     L.Watch (Live, null);
                     L.Close (Live);

                     if E.Is_Error (Status) then
                        Note_It ("a chunk would not evaluate: "
                                 & E.Error_Code'Image (Status.Code));
                        exit;
                     end if;

                     Result.Chunks := Result.Chunks + 1;
                  end;
               end loop;

               T.Free (Logits);
            end;

            if Result.Chunks = 0 or else Watching.Up = 0 then
               Note_It ("nothing was collected");
               goto Give_Back;
            end if;

            --  And the file. Two tensors a matrix -- the sums and the count
            --  that turns them into means -- named the way llama.cpp names
            --  them, because the point of writing one is that its own
            --  quantizer reads it.
            declare
               Maker : Fixtures.Builder;
               Made  : B.Byte_Array_Access := null;
            begin
               Fixtures.Add_String (Maker, "general.type", "imatrix");
               Fixtures.Add_U32
                 (Maker, "imatrix.chunk_count",
                  Interfaces.Unsigned_32 (Result.Chunks));
               Fixtures.Add_U32
                 (Maker, "imatrix.chunk_size",
                  Interfaces.Unsigned_32 (Chunk));
               Fixtures.Begin_Array
                 (Maker, "imatrix.datasets",
                  Model_Runner.GGUF.Value_String, 1);
               Fixtures.String_Element (Maker, Text);
               Fixtures.End_Array (Maker);

               for Index in 1 .. Watching.Up loop
                  declare
                     Name : constant String :=
                       Model_Runner.Text.To_String (Watching.Held (Index).Name);
                     Wide : constant N.Element_Count :=
                       Watching.Held (Index).Sums.all'Length;

                     One : constant N.Real_Array (0 .. 0) :=
                       [0 => N.Real (Watching.Held (Index).Rows)];

                     --  A stack of experts is told here as one matrix:
                     --  the engine names the stack and not the expert a
                     --  row was routed to, so what it would write is one
                     --  sum where llama.cpp keeps one an expert, divided
                     --  by counts that are not each expert's. Left out,
                     --  the quantizer writes the stack unweighted, which
                     --  is what it does for any tensor a matrix omits.
                     Owner : constant Natural :=
                       Containers.Find_Tensor (Container, Name);
                     Stack : constant Boolean :=
                       Owner /= 0
                       and then Containers.Tensor_Rank (Container, Owner) >= 3
                       and then Containers.Tensor_Dimension
                                  (Container, Owner, 3) > 1;
                  begin
                     if Stack then
                        goto Next_Matrix;
                     end if;
                     Result.Matrices := Result.Matrices + 1;

                     Fixtures.Add_Tensor
                       (Maker, Name & ".in_sum2",
                        [1 => Model_Runner.GGUF.U64 (Wide)],
                        Model_Runner.GGUF.Type_F32,
                        Fixtures.Encode_F32 (Watching.Held (Index).Sums.all));

                     Fixtures.Add_Tensor
                       (Maker, Name & ".counts",
                        [1 => 1],
                        Model_Runner.GGUF.Type_F32,
                        Fixtures.Encode_F32 (One));
                     <<Next_Matrix>>
                  end;
               end loop;

               Fixtures.Build (Maker, Made);

               if Made = null then
                  Note_It ("the matrix would not assemble");
                  goto Give_Back;
               end if;

               declare
                  Output : Ada.Streams.Stream_IO.File_Type;
               begin
                  Ada.Streams.Stream_IO.Create
                    (Output, Ada.Streams.Stream_IO.Out_File, Into);

                  --  A slice at a time, read where it lies: the whole file
                  --  as one stack array is a storage error for a model of
                  --  many wide matrices.
                  declare
                     Slice   : constant B.Byte_Count := 1024 * 1024;
                     At_Byte : B.Byte_Count := Made.all'First;
                  begin
                     while At_Byte <= Made.all'Last loop
                        declare
                           Upto : constant B.Byte_Count :=
                             B.Byte_Count'Min
                               (Made.all'Last, At_Byte + Slice - 1);
                           Room : Ada.Streams.Stream_Element_Array
                             (1 .. Ada.Streams.Stream_Element_Offset
                                     (Upto - At_Byte + 1));
                           for Room'Address use Made.all (At_Byte)'Address;
                           pragma Import (Ada, Room);
                        begin
                           Ada.Streams.Stream_IO.Write (Output, Room);
                           At_Byte := Upto + 1;
                        end;
                     end loop;
                  end;

                  Ada.Streams.Stream_IO.Close (Output);
               end;

               B.Free (Made);
               Result.Ran := True;
            end;

            <<Give_Back>>
            for Index in 1 .. Watching.Up loop
               if Watching.Held (Index).Sums /= null then
                  T.Free (Watching.Held (Index).Sums);
               end if;
            end loop;
            if Watching.Held /= null then
               Free (Watching.Held);
            end if;

            --  The workers, before the block that holds them ends. A pool
            --  nobody closes keeps its tasks alive and the block waits for
            --  them for ever -- which is what this did, and which looked
            --  like a slow collection rather than a stopped one because
            --  the summary was written into a buffer nothing flushed.
            CPU.Close (Team);
         exception
            --  Closed on the way out as well: a pool left open by an
            --  exception kept its workers waiting, and leaving the block
            --  waited on them for ever instead of saying what went wrong.
            when others =>
               CPU.Close (Team);
               raise;
         end;

         L.Close (Engine, Status);
         Containers.Close (Container);
         Files.Close (Source);
      end;

      Result.Seconds :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   end Run;

end Imatrix_Run;
