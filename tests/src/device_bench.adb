with Ada.Calendar;
with Ada.Text_IO;

with Model_Runner.Bytes;
with Model_Runner.Numerics;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Platform.Device;

package body Device_Bench is

   package N renames Model_Runner.Numerics;
   package Devices renames Model_Runner.Platform.Device;
   package Products renames Model_Runner.Platform.Device.Products;

   ------------
   -- Report --
   ------------

   procedure Report is
      use type Ada.Calendar.Time;

      Held   : Devices.Inventory;
      Found  : Boolean;
      Opened : Devices.Context;
      Engine : Products.Engine;
      Ready  : Boolean;

      Rounds : constant := 20;

      --  Time one shape and say what it cost, per call and per position.
      procedure Take
        (Heads   : Natural;
         Wide    : Natural;
         Steps   : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0);

      --  The engine's own shape, not a tidy one. A model with grouped
      --  queries has fewer key heads than query heads, so a position's keys
      --  are narrower than its queries, and the cache holds every layer of
      --  the whole context rather than the few positions being attended to.
      --  Both of those change what the kernel reads and neither was in the
      --  first shapes measured here.
      procedure Take
        (Heads   : Natural;
         Wide    : Natural;
         Steps   : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0)
      is
         use type N.Element_Count;

         --  How wide one position's keys are: a group a head unless heads
         --  share, and then a group per group.
         Groups : constant Natural := Heads / Sharing;
         Narrow : constant Natural := Groups * Wide;

         Span  : constant Natural := Heads * Wide;

         --  How many positions the cache has room for, against how many are
         --  attended to. A layer of a real model holds the whole context.
         Kept  : constant Natural := (if Room = 0 then Steps else Room);

         --  On the heap: a cache of two thousand positions across
         --  thirty-two heads is thirty-two megabytes, which is a stack
         --  overflow rather than a benchmark.
         type Values is access N.Real_Array;

         Cache : constant Values :=
           new N.Real_Array
             (0 .. N.Element_Count (Layers) * N.Element_Count (Kept)
                   * N.Element_Count (Narrow) * 2 - 1);
         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);

         Started : Ada.Calendar.Time;
         Spent   : Duration;
         Ok      : Boolean;

         --  Two multiply-adds a component of a key, and two a component of a
         --  value, for every head and every position.
         Work : constant Long_Float :=
           4.0 * Long_Float (Heads) * Long_Float (Wide) * Long_Float (Steps);
      begin
         Cache.all := [others => 0.125];
         Asked.all := [others => 0.25];

         --  The cache put there once, as a layer would: a position is
         --  written when it is computed, not re-sent for every call that
         --  reads it. What is timed below is the kernel and nothing else.
         Products.Reserve (Engine, Cache.all'Length, Ok);
         if not Ok then
            Ada.Text_IO.Put_Line ("  no room for the cache");
            return;
         end if;

         Products.Put_Cache (Engine, 0, Cache.all, Ok);
         if not Ok then
            Ada.Text_IO.Put_Line ("  the cache would not be written");
            return;
         end if;

         Started := Ada.Calendar.Clock;

         for Round in 1 .. Rounds loop
            Products.Attend_Resident
              (Engine, Asked.all,
               Heads => Heads, Head_Size => Wide, Value_Size => Wide,
               First => 0, Last => Steps - 1,
               K_Base => 0,
               V_Base => Layers * Kept * Narrow,
               KV_Width => Narrow, V_Width => Narrow,
               Group_Size => Sharing,
               Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
            exit when not Ok;
         end loop;

         Spent := (Ada.Calendar.Clock - Started) / Rounds;

         --  And what writing one position into that cache costs, which is
         --  what a layer does twice a token and what stood between the
         --  kernel's time and the engine's.
         declare
            Row     : constant N.Real_Array (0 .. N.Element_Count (Span) - 1)
              := [others => 0.5];
            Writing : Ada.Calendar.Time;
            Each    : Duration;
         begin
            Writing := Ada.Calendar.Clock;
            for Round in 1 .. Rounds * 10 loop
               Products.Put_Cache (Engine, 0, Row, Ok);
            end loop;
            Each := (Ada.Calendar.Clock - Writing) / (Rounds * 10);

            Ada.Text_IO.Put_Line
              ("    a cache write of" & Natural'Image (Span) & " values:"
               & Duration'Image (Each) & " s");
         end;

         Ada.Text_IO.Put_Line
           ("  heads" & Natural'Image (Heads)
            & ", wide" & Natural'Image (Wide)
            & ", positions" & Natural'Image (Steps)
            & (if Ok then "" else "  REFUSED")
            & " :" & Duration'Image (Spent) & " s a call, "
            & Long_Float'Image (Work / Long_Float (Spent) / 1.0E9)
            & " Gflop/s, cache"
            & Natural'Image (Natural (Cache.all'Length) / 256) & " KiB");
      end Take;

      --  As Take, but with a matrix product submitted before each attention,
      --  which is what a layer does around it. A call timed on an idle
      --  device is not a call in a layer.
      procedure Busy
        (Heads   : Natural;
         Wide    : Natural;
         Steps_Count : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0)
      is
         use type N.Element_Count;
         use type Model_Runner.Bytes.Byte_Count;

         Groups : constant Natural := Heads / Sharing;
         Narrow : constant Natural := Groups * Wide;
         Span   : constant Natural := Heads * Wide;
         Kept   : constant Natural := (if Room = 0 then Steps_Count else Room);

         type Values is access N.Real_Array;

         Cache : constant Values :=
           new N.Real_Array
             (0 .. N.Element_Count (Layers) * N.Element_Count (Kept)
                   * N.Element_Count (Narrow) * 2 - 1);
         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);

         Rows : constant Natural := Span;
         Cols : constant Natural := Span;

         Weights : constant Model_Runner.Bytes.Byte_Array_Access :=
           new Model_Runner.Bytes.Byte_Array
             (1 .. Model_Runner.Bytes.Byte_Count (Rows * Cols * 4));
         Product : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Rows) - 1);

         Started : Ada.Calendar.Time;
         Spent   : Duration;
         Ok      : Boolean;
         Halted  : Boolean;
      begin
         Cache.all := [others => 0.125];
         Asked.all := [others => 0.25];
         Weights.all := [others => 0];

         Products.Reserve (Engine, Cache.all'Length, Ok);
         if not Ok then
            return;
         end if;
         Products.Put_Cache (Engine, 0, Cache.all, Ok);
         if not Ok then
            return;
         end if;

         --  The product on its own first, so that what the attention adds
         --  beside it can be told from what the product costs. A pair timed
         --  without this says only that a matrix of four million weights is
         --  not free.
         Started := Ada.Calendar.Clock;
         for Round in 1 .. Rounds loop
            Products.Multiply
              (Engine, Weights.all, 0, Products.Values_F32, Rows, Cols,
               Asked.all, 1, Product.all, Ok, Halted);
         end loop;

         Ada.Text_IO.Put_Line
           ("    the product alone:"
            & Duration'Image ((Ada.Calendar.Clock - Started) / Rounds)
            & " s");

         Started := Ada.Calendar.Clock;

         for Round in 1 .. Rounds loop
            Products.Multiply
              (Engine, Weights.all, 0, Products.Values_F32, Rows, Cols,
               Asked.all, 1, Product.all, Ok, Halted);

            Products.Attend_Resident
              (Engine, Asked.all,
               Heads => Heads, Head_Size => Wide, Value_Size => Wide,
               Group_Size => Sharing, First => 0, Last => Steps_Count - 1,
               K_Base => 0, V_Base => Layers * Kept * Narrow,
               KV_Width => Narrow, V_Width => Narrow,
               Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
            exit when not Ok;
         end loop;

         Spent := (Ada.Calendar.Clock - Started) / Rounds;

         Ada.Text_IO.Put_Line
           ("    a product and an attention together:"
            & Duration'Image (Spent) & " s a pair");

         --  The pair apart and the pair together, alternating within one
         --  loop rather than as two blocks of rounds.
         --
         --  Two blocks was wrong and the wrongness was not subtle: three
         --  runs of it said the joined pair saved 0.456, 0.553 and 0.848 ms
         --  and three later runs of the same binary said it lost 1.036,
         --  0.307 and 0.589 ms. Whatever moved between the blocks -- this
         --  machine has other people's work on it -- landed entirely on
         --  whichever arm ran second. Alternating puts the same drift
         --  through both arms, so what is left is the difference between
         --  them.
         --
         --  Each row below is also said with a layer's other submissions
         --  around the pair, because a submission costs waiting and a
         --  device that already has work queued is not idle to be waited
         --  on. That is measurable here and nowhere else in this file.
         declare
            Order  : Products.Sequence;
            Added  : Boolean;
            Landed : constant Values :=
              new N.Real_Array
                (0 .. N.Element_Count (Span) + N.Element_Count (Rows) - 1);

            Apart, Together : Duration := 0.0;
            Since : Ada.Calendar.Time;

            --  What a layer submits besides these two.
            Beside : constant := 3;

            --  How many rounds each arm gets. Ten times the other rows
            --  here: what is looked for is one submission against a pair
            --  costing milliseconds.
            Turns : constant Natural := Rounds * 10;

            procedure Pair_Apart (Busy_Too : Boolean);
            procedure Pair_Together (Busy_Too : Boolean);

            --  Attention submitted, its blend brought back, and the
            --  projection sent after it.
            procedure Pair_Apart (Busy_Too : Boolean) is
            begin
               if Busy_Too then
                  for Each in 1 .. Beside loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;
               end if;

               Products.Attend_Resident
                 (Engine, Asked.all,
                  Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                  Group_Size => Sharing, First => 0, Last => Steps_Count - 1,
                  K_Base => 0, V_Base => Layers * Kept * Narrow,
                  KV_Width => Narrow, V_Width => Narrow,
                  Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
               Products.Multiply
                 (Engine, Weights.all, 0, Products.Values_F32,
                  Rows, Cols, Got.all, 1, Product.all, Ok, Halted);
            end Pair_Apart;

            --  The two named together, as one command buffer.
            procedure Pair_Together (Busy_Too : Boolean) is
            begin
               if Busy_Too then
                  for Each in 1 .. Beside loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;
               end if;

               Products.Run
                 (Engine, Order, Asked.all, 1, Landed.all, Ok, Halted);
            end Pair_Together;
         begin
            Products.Open_Sequence (Order);
            Products.Add_Attention
              (Order, Heads, Wide, Wide, Sharing, 0, Steps_Count - 1,
               0, Layers * Kept * Narrow, Narrow, Narrow, 0.125, 0.0, Added);
            Products.Add_Chained_Product
              (Order, Weights.all'Address,
               Model_Runner.Bytes.Byte_Count (Weights.all'Length), 0,
               Products.Values_F32, Rows, Cols, Added);

            if not Added then
               Ada.Text_IO.Put_Line
                 ("    the pair would not record as a sequence");
            else
               for Idle in reverse Boolean'Range loop
                  Apart := 0.0;
                  Together := 0.0;

                  for Round in 1 .. Turns loop
                     Since := Ada.Calendar.Clock;
                     Pair_Apart (Busy_Too => not Idle);
                     Apart := Apart + (Ada.Calendar.Clock - Since);

                     Since := Ada.Calendar.Clock;
                     Pair_Together (Busy_Too => not Idle);
                     Together := Together + (Ada.Calendar.Clock - Since);
                  end loop;

                  Ada.Text_IO.Put_Line
                    ("    " & (if Idle then "alone:     " else "in a layer:")
                     & " apart" & Duration'Image (Apart / Turns)
                     & " s, together" & Duration'Image (Together / Turns)
                     & " s, saved"
                     & Duration'Image ((Apart - Together) / Turns) & " s");
               end loop;
            end if;
         end;

         --  What a query's round trip is worth, which is the thing that
         --  would have to pay for moving rotation and the cache write onto
         --  a device.
         --
         --  A layer makes its queries with a product, rotates them on the
         --  processor, writes the position's keys and values, and only then
         --  attends -- so the queries come back and go over again. Moving
         --  that work would let the attention chain to the product, and
         --  this is what it would win: a product with an attention chained
         --  to it, against the same product with the attention reading an
         --  activation that was uploaded. Alternated round by round, and
         --  said with a layer's other submissions around it, for the reason
         --  the row above gives.
         declare
            Linked, Split : Products.Sequence;
            Added  : Boolean;
            Landed : constant Values :=
              new N.Real_Array
                (0 .. N.Element_Count (Span) * 2 - 1);

            Over, Kept_There : Duration := 0.0;
            Since : Ada.Calendar.Time;

            Beside : constant := 3;
            Turns  : constant Natural := Rounds * 10;
         begin
            --  The product that makes the queries, then attention reading
            --  them where they lie.
            Products.Open_Sequence (Linked);
            Products.Add_Product
              (Linked, Weights.all'Address,
               Model_Runner.Bytes.Byte_Count (Weights.all'Length), 0,
               Products.Values_F32, Span, Cols, Added);
            Products.Add_Attention
              (Linked, Heads, Wide, Wide, Sharing, 0, Steps_Count - 1,
               0, Layers * Kept * Narrow, Narrow, Narrow, 0.125, 0.0, Added,
               Chained => True);

            --  The same product, and an attention reading queries that were
            --  uploaded -- which is what the engine does today, because the
            --  rotation happens between the two.
            Products.Open_Sequence (Split);
            Products.Add_Product
              (Split, Weights.all'Address,
               Model_Runner.Bytes.Byte_Count (Weights.all'Length), 0,
               Products.Values_F32, Span, Cols, Added);

            if not Added then
               Ada.Text_IO.Put_Line ("    the pair would not record");
            else
               for Round in 1 .. Turns loop
                  Since := Ada.Calendar.Clock;
                  for Each in 1 .. Beside loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;
                  Products.Run
                    (Engine, Split, Asked.all, 1,
                     Landed.all (Landed.all'First
                                 .. Landed.all'First
                                    + N.Element_Count (Span) - 1),
                     Ok, Halted);
                  Products.Attend_Resident
                    (Engine, Asked.all,
                     Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                     Group_Size => Sharing, First => 0,
                     Last => Steps_Count - 1,
                     K_Base => 0, V_Base => Layers * Kept * Narrow,
                     KV_Width => Narrow, V_Width => Narrow,
                     Scale => 0.125, Cap => 0.0, Target => Got.all,
                     Ok => Ok);
                  Over := Over + (Ada.Calendar.Clock - Since);

                  Since := Ada.Calendar.Clock;
                  for Each in 1 .. Beside loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;
                  Products.Run
                    (Engine, Linked, Asked.all, 1, Landed.all, Ok, Halted);
                  Kept_There := Kept_There + (Ada.Calendar.Clock - Since);
               end loop;

               Ada.Text_IO.Put_Line
                 ("    queries over" & Duration'Image (Over / Turns)
                  & " s, queries kept there"
                  & Duration'Image (Kept_There / Turns) & " s, saved"
                  & Duration'Image ((Over - Kept_There) / Turns) & " s");
            end if;
         end;

         --  A layer's shape: four products around one attention, and the
         --  same four without it. The difference is what the attention adds
         --  where it is actually called, which is the question a pair of
         --  one product could only hint at -- and it read 0.703 ms one run
         --  and 1.810 ms the next, so this says both figures every time
         --  rather than one of them.
         for Attempt in 1 .. 3 loop
            declare
               Bare : Duration;
               Both : Duration;

               --  What a layer submits: the queries, keys and values as one,
               --  the attention output, the gate and up as one, and the
               --  projection down. Four, whatever the grouping does to them.
               Sends : constant := 4;
            begin
               Started := Ada.Calendar.Clock;
               for Round in 1 .. Rounds loop
                  for Each in 1 .. Sends loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;
               end loop;
               Bare := (Ada.Calendar.Clock - Started) / Rounds;

               Started := Ada.Calendar.Clock;
               for Round in 1 .. Rounds loop
                  for Each in 1 .. Sends loop
                     Products.Multiply
                       (Engine, Weights.all, 0, Products.Values_F32,
                        Rows, Cols, Asked.all, 1, Product.all, Ok, Halted);
                  end loop;

                  Products.Attend_Resident
                    (Engine, Asked.all,
                     Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                     Group_Size => Sharing, First => 0, Last => Steps_Count - 1,
                     K_Base => 0, V_Base => Layers * Kept * Narrow,
                     KV_Width => Narrow, V_Width => Narrow,
                     Scale => 0.125, Cap => 0.0, Target => Got.all,
                     Ok => Ok);
               end loop;
               Both := (Ada.Calendar.Clock - Started) / Rounds;

               Ada.Text_IO.Put_Line
                 ("    four products" & Duration'Image (Bare)
                  & " s, with an attention" & Duration'Image (Both)
                  & " s, the attention" & Duration'Image (Both - Bare)
                  & " s");
            end;
         end loop;

         --  And the same attention reading a different layer's region every
         --  call, as a token does: twenty-two of them, ninety megabytes
         --  apart end to end. Every call above read the first layer's keys,
         --  which after the first is a region already warm.
         Started := Ada.Calendar.Clock;

         for Round in 1 .. Rounds loop
            declare
               Layer : constant Natural := (Round - 1) mod Layers;
            begin
               Products.Attend_Resident
                 (Engine, Asked.all,
                  Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                  Group_Size => Sharing, First => 0, Last => Steps_Count - 1,
                  K_Base => Layer * Kept * Narrow,
                  V_Base => Layers * Kept * Narrow
                            + Layer * Kept * Narrow,
                  KV_Width => Narrow, V_Width => Narrow,
                  Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
               exit when not Ok;
            end;
         end loop;

         Ada.Text_IO.Put_Line
           ("    attention walking every layer's region:"
            & Duration'Image ((Ada.Calendar.Clock - Started) / Rounds)
            & " s a call");
      end Busy;

      --  A whole prompt evaluated the way the batched evaluator evaluates
      --  one: every position of every layer, one call each, over a cache
      --  the size the engine reserves.
      --
      --  This exists because a figure got worse and the reason was guessed
      --  at rather than measured. Wiring the batched evaluator to attend on
      --  the device moved the 110-token prompt from 2.504 s to 2.894 s, and
      --  what was written down was a suspicion: that the cost is the count
      --  of separate submissions and their fences rather than the
      --  arithmetic. This says the number that suspicion predicts, so the
      --  two can be compared instead of one of them being believed.
      --
      --  @param Heads Query heads.
      --  @param Wide How wide a head is.
      --  @param Steps How many positions the prompt has.
      --  @param Sharing How many query heads share a group of keys.
      --  @param Layers How many layers the model has.
      --  @param Room How deep the reserved context is.
      procedure Prompt
        (Heads   : Natural;
         Wide    : Natural;
         Steps   : Natural;
         Sharing : Natural := 1;
         Layers  : Natural := 1;
         Room    : Natural := 0)
      is
         use type N.Element_Count;

         Groups : constant Natural := Heads / Sharing;
         Narrow : constant Natural := Groups * Wide;
         Span   : constant Natural := Heads * Wide;
         Kept   : constant Natural := (if Room = 0 then Steps else Room);

         type Values is access N.Real_Array;

         Cache : constant Values :=
           new N.Real_Array
             (0 .. N.Element_Count (Layers) * N.Element_Count (Kept)
                   * N.Element_Count (Narrow) * 2 - 1);
         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Span) - 1);

         Started : Ada.Calendar.Time;
         Calls   : Natural := 0;
         Spent   : Duration;
         Ok      : Boolean;
      begin
         Cache.all := [others => 0.125];
         Asked.all := [others => 0.25];

         Products.Reserve (Engine, Cache.all'Length, Ok);
         if not Ok then
            Ada.Text_IO.Put_Line ("    no room for the cache");
            return;
         end if;
         Products.Put_Cache (Engine, 0, Cache.all, Ok);
         if not Ok then
            Ada.Text_IO.Put_Line ("    the cache would not be written");
            return;
         end if;

         Started := Ada.Calendar.Clock;

         for Layer in 0 .. Layers - 1 loop
            for Step in 0 .. Steps - 1 loop
               --  Each position attends to itself and everything before it,
               --  which is what makes the arithmetic grow while the number
               --  of submissions does not.
               Products.Attend_Resident
                 (Engine, Asked.all,
                  Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                  Group_Size => Sharing, First => 0, Last => Step,
                  K_Base => Layer * Kept * Narrow,
                  V_Base => Layers * Kept * Narrow + Layer * Kept * Narrow,
                  KV_Width => Narrow, V_Width => Narrow,
                  Scale => 0.125, Cap => 0.0, Target => Got.all, Ok => Ok);
               Calls := Calls + 1;
               exit when not Ok;
            end loop;
            exit when not Ok;
         end loop;

         Spent := Ada.Calendar.Clock - Started;

         Ada.Text_IO.Put_Line
           ("    a call a position:" & Duration'Image (Spent)
            & " s," & Natural'Image (Calls) & " calls,"
            & Duration'Image (Spent / Natural'Max (Calls, 1)) & " s a call");

         --  And the same work as one call a layer. The arithmetic is the
         --  same triangle either way; what differs is how many times it is
         --  submitted and waited on.
         declare
            Batched : constant Values :=
              new N.Real_Array
                (0 .. N.Element_Count (Steps) * N.Element_Count (Span) - 1);
            Blends  : constant Values :=
              new N.Real_Array
                (0 .. N.Element_Count (Steps) * N.Element_Count (Span) - 1);
         begin
            Batched.all := [others => 0.25];
            Calls := 0;
            Started := Ada.Calendar.Clock;

            for Layer in 0 .. Layers - 1 loop
               Products.Attend_Resident
                 (Engine, Batched.all,
                  Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                  Group_Size => Sharing, First => 0, Last => 0,
                  K_Base => Layer * Kept * Narrow,
                  V_Base => Layers * Kept * Narrow + Layer * Kept * Narrow,
                  KV_Width => Narrow, V_Width => Narrow,
                  Scale => 0.125, Cap => 0.0, Target => Blends.all,
                  Ok => Ok, Positions => Steps);
               Calls := Calls + 1;
               exit when not Ok;
            end loop;

            Spent := Ada.Calendar.Clock - Started;

            Ada.Text_IO.Put_Line
              ("    a call a layer:  " & Duration'Image (Spent)
               & " s," & Natural'Image (Calls) & " calls,"
               & Duration'Image (Spent / Natural'Max (Calls, 1))
               & " s a call");
         end;
      end Prompt;

      --  What the batched product reaches at the shapes a layer actually
      --  asks for, rather than at a tidy square.
      --
      --  A prompt's budget says projecting runs at about 790 gigaflops a
      --  second and feeding at 1662, on the same kernel and the same
      --  format. Something about the shapes differs and the budget cannot
      --  say what, because it times a phase and a phase is four products.
      --  This times one.
      procedure Tiles is
         use type N.Element_Count;
         use type Model_Runner.Bytes.Byte_Count;
         use type Model_Runner.Bytes.Byte_Array_Access;

         type Values is access N.Real_Array;

         Vectors : constant := 128;
         Seconds : constant Duration := 0.30;

         type Shape is record
            Name    : String (1 .. 10);
            Rows    : Positive;
            Columns : Positive;
            Wide    : Positive := Vectors;
         end record;

         --  TinyLlama's own, and the vocabulary projection that closes a
         --  run. The two narrow ones are the grouped keys and values: an
         --  eighth of the rows of the query beside them, at the same width.
         Table : constant array (1 .. 17) of Shape :=
           [("query     ",  2048, 2048, 128),
            ("keys      ",   256, 2048, 128),
            ("out proj  ",  2048, 2048, 128),
            ("gate, up  ",  5632, 2048, 128),
            ("down      ",  2048, 5632, 128),
            ("vocabulary", 32000, 2048, 128),

            --  And the narrow one again at wider batches. A workgroup
            --  takes thirty-two rows and a hundred and twenty-eight
            --  vectors, so two hundred and fifty-six rows against a
            --  hundred and twenty-eight vectors is eight workgroups on
            --  twelve compute units. If that is what is wrong, a wider
            --  batch is more workgroups and says so.
            ("keys   x2 ",   256, 2048, 256),
            ("keys   x4 ",   256, 2048, 512),
            ("keys   x8 ",   256, 2048, 1024),
            ("query  x4 ",  2048, 2048, 512),

            --  And the whole curve in rows, at one batch. A workgroup takes
            --  thirty-two rows, so this is one workgroup to sixty-four, and
            --  the same k for all of them. If what binds the narrow shape
            --  is a cost a dispatch pays before it computes anything, the
            --  time stops falling as the rows do and says where.
            ("rows 32   ",    32, 2048, 128),
            ("rows 64   ",    64, 2048, 128),
            ("rows 128  ",   128, 2048, 128),
            ("rows 256  ",   256, 2048, 128),
            ("rows 512  ",   512, 2048, 128),
            ("rows 1024 ",  1024, 2048, 128),
            ("rows 2048 ",  2048, 2048, 128)];
      begin
         for Which of Table loop
            declare
               Blocks : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count (Which.Columns / 32) * 34;

               Room : constant Model_Runner.Bytes.Byte_Count :=
                 Blocks * Model_Runner.Bytes.Byte_Count (Which.Rows);

               Asked : constant Values :=
                 new N.Real_Array
                   (0 .. N.Element_Count (Which.Columns)
                         * N.Element_Count (Which.Wide) - 1);
               Got   : constant Values :=
                 new N.Real_Array
                   (0 .. N.Element_Count (Which.Rows)
                         * N.Element_Count (Which.Wide) - 1);

               Weights : Model_Runner.Bytes.Byte_Array_Access;
               Started : Ada.Calendar.Time;
               Calls   : Natural := 0;
               Spent   : Duration := 0.0;
               Ok      : Boolean := True;
               Halted  : Boolean;
            begin
               Model_Runner.Bytes.Allocate (Room, Weights);
               exit when Weights = null;

               Asked.all := [others => 0.25];
               --  A pattern, and one whose arithmetic stays inside a
               --  machine integer for a seventy-megabyte matrix: the
               --  vocabulary projection has more bytes than a Natural
               --  multiplied by thirty-seven can hold.
               for Index in Weights.all'Range loop
                  Weights.all (Index) :=
                    Model_Runner.Bytes.Byte (Natural (Index mod 251));
               end loop;

               Started := Ada.Calendar.Clock;

               loop
                  Products.Multiply
                    (Engine, Weights.all, 0, Products.Packed_Q8_0,
                     Which.Rows, Which.Columns, Asked.all, Which.Wide,
                     Got.all, Ok, Halted,
                     Key => Weights.all (Weights.all'First)'Address);
                  exit when not Ok;
                  Calls := Calls + 1;
                  Spent := Ada.Calendar.Clock - Started;
                  exit when Spent >= Seconds;
               end loop;

               if Ok and then Calls > 0 then
                  declare
                     Each : constant Long_Float :=
                       Long_Float (Spent) / Long_Float (Calls);

                     Rate : constant Long_Float :=
                       2.0 * Long_Float (Which.Rows)
                       * Long_Float (Which.Columns)
                       * Long_Float (Which.Wide) / Each / 1.0E9;
                  begin
                     Ada.Text_IO.Put_Line
                       ("    " & Which.Name
                        & Duration'Image (Duration (Each)) & " s a product,"
                        & Long_Float'Image (Rate) & " Gflop/s,"
                        & Natural'Image (Which.Rows) & " by"
                        & Natural'Image (Which.Columns) & ","
                        & Natural'Image (Which.Wide) & " vectors");
                  end;
               else
                  Ada.Text_IO.Put_Line
                    ("    " & Which.Name & " the device would not take it");
               end if;

               Products.Forget_Matrices (Engine);
               Model_Runner.Bytes.Free (Weights);
            end;
         end loop;
      end Tiles;

      --  What a weight byte costs when exactly one vector reads it, format
      --  by format, on the row product.
      --
      --  A generated token is one vector against every matrix in the model,
      --  so it reads every weight once and reuses nothing. If that path were
      --  bound by the bus, every format would move the same bytes in the
      --  same time and the only difference between them would be how many
      --  bytes a row is. This says whether it is.
      --
      --  Absolute seconds rather than a ratio against the processor, which
      --  is what `tests benchmark` prints: a ratio cannot say which side
      --  moved, and the question here is entirely about one side.
      procedure Formats is
         use type N.Element_Count;
         use type Model_Runner.Bytes.Byte_Count;
         use type Model_Runner.Bytes.Byte_Array_Access;

         type Values is access N.Real_Array;

         Rows    : constant := 2048;
         Columns : constant := 4096;
         Seconds : constant Duration := 0.30;

         type Shape is record
            Packing  : Products.Weight_Packing;
            Name     : String (1 .. 6);
            Elements : Positive;
            Bytes    : Positive;
         end record;

         --  Binary32 is here as the floor: it decodes to nothing at all, so
         --  whatever it reaches is what this device does with a row product
         --  when the decode is free.
         Table : constant array (1 .. 15) of Shape :=
           [(Products.Values_F32,   "f32   ",   1,   4),
            (Products.Values_F16,   "f16   ",   1,   2),
            (Products.Values_BF16,  "bf16  ",   1,   2),
            (Products.Packed_Q4_0,  "q4_0  ",  32,  18),
            (Products.Packed_Q4_1,  "q4_1  ",  32,  20),
            (Products.Packed_Q5_0,  "q5_0  ",  32,  22),
            (Products.Packed_Q5_1,  "q5_1  ",  32,  24),
            (Products.Packed_Q8_0,  "q8_0  ",  32,  34),
            (Products.Packed_IQ4_NL, "iq4nl ", 32,  18),
            (Products.Packed_Q2_K,  "q2_k  ", 256,  84),
            (Products.Packed_Q3_K,  "q3_k  ", 256, 110),
            (Products.Packed_Q4_K,  "q4_k  ", 256, 144),
            (Products.Packed_Q5_K,  "q5_k  ", 256, 176),
            (Products.Packed_Q6_K,  "q6_k  ", 256, 210),
            (Products.Packed_IQ4_XS, "iq4xs ", 256, 136)];

         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Columns) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Rows) - 1);
      begin
         Asked.all := [others => 0.25];

         for Which of Table loop
            declare
               Width : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count (Columns / Which.Elements)
                 * Model_Runner.Bytes.Byte_Count (Which.Bytes);

               Room : constant Model_Runner.Bytes.Byte_Count :=
                 Width * Model_Runner.Bytes.Byte_Count (Rows);

               Weights : Model_Runner.Bytes.Byte_Array_Access;
               Started : Ada.Calendar.Time;
               Calls   : Natural := 0;
               Spent   : Duration := 0.0;
               Ok      : Boolean := True;
               Halted  : Boolean;
            begin
               Model_Runner.Bytes.Allocate (Room, Weights);
               exit when Weights = null;

               --  A pattern rather than zeroes: a block of zeroes has a
               --  zero scale, and a device that reads one is doing the same
               --  work as a device that reads any other, but a reader of
               --  this would rightly ask.
               for Index in Weights.all'Range loop
                  Weights.all (Index) :=
                    Model_Runner.Bytes.Byte ((Natural (Index) * 37) mod 251);
               end loop;

               Started := Ada.Calendar.Clock;

               loop
                  Products.Multiply
                    (Engine, Weights.all, 0, Which.Packing, Rows, Columns,
                     Asked.all, 1, Got.all, Ok, Halted,
                     Key => Weights.all (Weights.all'First)'Address);
                  exit when not Ok;
                  Calls := Calls + 1;
                  Spent := Ada.Calendar.Clock - Started;
                  exit when Spent >= Seconds;
               end loop;

               if Ok and then Calls > 0 then
                  declare
                     Each : constant Long_Float :=
                       Long_Float (Spent) / Long_Float (Calls);

                     --  Nanoseconds an element and gigabytes a second, so
                     --  that a format which reads fewer bytes and takes
                     --  longer says so in both directions at once.
                     Cell : constant Long_Float :=
                       Each * 1.0E9
                       / (Long_Float (Rows) * Long_Float (Columns));

                     Rate : constant Long_Float :=
                       Long_Float (Room) / Each / 1.0E9;
                  begin
                     Ada.Text_IO.Put_Line
                       ("    " & Which.Name
                        & Duration'Image (Duration (Each)) & " s a product,"
                        & Long_Float'Image (Cell) & " ns an element,"
                        & Long_Float'Image (Rate) & " GB/s,"
                        & Model_Runner.Bytes.Byte_Count'Image (Room / 1024)
                        & " KiB");
                  end;
               else
                  Ada.Text_IO.Put_Line
                    ("    " & Which.Name & " the device would not take it");
               end if;

               Products.Forget_Matrices (Engine);
               Model_Runner.Bytes.Free (Weights);
            end;
         end loop;
      end Formats;

      --  Whether reserving a cache costs the weights their place.
      --
      --  The engine keeps a model's matrices on the device and gives the
      --  least-wanted one back when the next will not fit a budget that is a
      --  fixed share of the heap, decided when the device opened. A cache
      --  reserved afterwards takes device memory that budget knows nothing
      --  about. If that is what makes a wired run slow, then cycling
      --  products through more matrices than the budget holds gets slower
      --  once a cache is reserved, and the count given back rises.
      procedure Squeeze (Wide : Natural; Many : Natural; Cache : Natural) is
         use type N.Element_Count;
         use type Model_Runner.Bytes.Byte_Count;

         type Values is access N.Real_Array;
         type Bytes_Access is access Model_Runner.Bytes.Byte_Array;

         Weights : constant Bytes_Access :=
           new Model_Runner.Bytes.Byte_Array
             (1 .. Model_Runner.Bytes.Byte_Count (Many)
                   * Model_Runner.Bytes.Byte_Count (Wide * Wide * 4));

         Asked : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Wide) - 1);
         Got   : constant Values :=
           new N.Real_Array (0 .. N.Element_Count (Wide) - 1);

         Room : Values;

         Started : Ada.Calendar.Time;
         Ok      : Boolean;
         Halted  : Boolean;

         Before, After : Natural;
      begin
         Weights.all := [others => 0];
         Asked.all := [others => 0.25];

         if Cache > 0 then
            Room := new N.Real_Array (0 .. N.Element_Count (Cache) - 1);
            Room.all := [others => 0.0];
            Products.Reserve (Engine, Room.all'Length, Ok);
            if not Ok then
               Ada.Text_IO.Put_Line ("    no room for the cache");
               return;
            end if;
         end if;

         --  Once through to settle what is kept, then the timed pass.
         --  Each with a key of its own, which is what asks the device to
         --  keep it. Without one nothing is kept and the question is not
         --  being put at all -- the first pass at this measured that and
         --  reported nothing kept, which was the test failing to ask rather
         --  than the device declining.
         for Round in 1 .. Many loop
            declare
               At_Byte : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count ((Round - 1) * Wide * Wide * 4);
            begin
               Products.Multiply
                 (Engine, Weights.all, At_Byte,
                  Products.Values_F32, Wide, Wide, Asked.all, 1, Got.all,
                  Ok, Halted,
                  Key => Weights.all (Weights.all'First + At_Byte)'Address);
            end;
         end loop;

         Before := Products.Given_Back (Engine);
         Started := Ada.Calendar.Clock;

         for Pass in 1 .. 3 loop
            for Round in 1 .. Many loop
               declare
                  At_Byte : constant Model_Runner.Bytes.Byte_Count :=
                    Model_Runner.Bytes.Byte_Count
                      ((Round - 1) * Wide * Wide * 4);
               begin
                  Products.Multiply
                    (Engine, Weights.all, At_Byte,
                     Products.Values_F32, Wide, Wide, Asked.all, 1, Got.all,
                     Ok, Halted,
                     Key =>
                       Weights.all (Weights.all'First + At_Byte)'Address);
               end;
            end loop;
         end loop;

         After := Products.Given_Back (Engine);

         Ada.Text_IO.Put_Line
           ("    cache" & Natural'Image (Cache / 262_144) & " MiB:"
            & Duration'Image ((Ada.Calendar.Clock - Started) / (3 * Many))
            & " s a product," & Natural'Image (After - Before)
            & " given back," & Natural'Image (Products.Resident (Engine))
            & " kept");
      end Squeeze;
   begin
      Devices.Open (Held, Found);
      if not Found or else Devices.Count (Held) = 0 then
         Ada.Text_IO.Put_Line ("no device here");
         return;
      end if;

      Devices.Open (Opened, Held, 1, Ready);
      if Ready then
         Products.Open (Engine, Opened, Ready);
      end if;

      if not Ready then
         Ada.Text_IO.Put_Line ("no device here");
         Devices.Close (Held);
         return;
      end if;

      Ada.Text_IO.Put_Line ("attention, median of" & Natural'Image (Rounds)
                            & " calls a shape:");

      --  Few positions and many, at one head and at thirty-two. A cost that
      --  hardly moves between the first two is a cost that is not the
      --  arithmetic.
      Take (1, 64, 16);
      Take (1, 64, 512);
      Take (32, 64, 16);
      Take (32, 64, 512);
      Take (32, 64, 2048);

      --  And what the engine actually asks for: thirty-two query heads
      --  sharing four groups of keys, across twenty-two layers of a context
      --  two thousand deep, attending to five hundred of them.
      Ada.Text_IO.Put_Line ("  as the engine asks it:");
      Take (32, 64, 512, Sharing => 8, Layers => 22, Room => 2048);

      --  The same, with a matrix product submitted between each attention,
      --  as a layer does. A call timed on an idle device is not a call in a
      --  layer: the layer submits four products around it, and a submission
      --  that queues behind them waits for them.
      Ada.Text_IO.Put_Line ("  with a layer's other work between:");
      Busy (32, 64, 512, Sharing => 8, Layers => 22, Room => 2048);

      --  What a 110-token prompt costs in attention alone, one call a
      --  position a layer, which is what the batched evaluator now submits.
      Ada.Text_IO.Put_Line ("  a prompt, a call a position a layer:");
      Prompt (32, 64, 110, Sharing => 8, Layers => 22, Room => 2048);

      --  Twenty matrices of a thousand square, which is eighty megabytes of
      --  weights, first with no cache and then with eighty-eight megabytes
      --  of one.
      Ada.Text_IO.Put_Line ("  weights against a reserved cache:");
      Squeeze (1024, 20, 0);
      Squeeze (1024, 20, 23_068_672);

      --  And what one vector costs a format, which is the shape a generated
      --  token has: no reuse anywhere, so the decode is paid once an element
      --  and amortized over nothing.
      Ada.Text_IO.Put_Line ("  one vector a product, by format:");
      Formats;

      --  And a hundred and twenty-eight vectors a product, at the shapes a
      --  layer asks for, which is what a prompt does.
      Ada.Text_IO.Put_Line ("  a batch of 128, by shape:");
      Tiles;

      Products.Close (Engine);
      Devices.Close (Opened);
      Devices.Close (Held);
   end Report;

end Device_Bench;
