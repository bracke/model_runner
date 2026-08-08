with AUnit.Assertions;

with Interfaces;

with Model_Runner.Clocks;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Arithmetic;
with Packaging;
with Tarlib.Entries;
with Tarlib.Errors;
with Tarlib.Files;
with Tarlib.Readers;
with Model_Runner;
with Hostkit.Fs;
with Model_Runner.Memory;
with Model_Runner.Text;
with Model_Runner.Bytes;
with Model_Runner.Platform.Mapping;

with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

package body Tests.Accounting_Cases is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package M renames Model_Runner.Memory;

   subtype U64 is Interfaces.Unsigned_64;

   --  An allocation beyond the budget is refused before any allocator runs.
   procedure Over_Budget_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Account : M.Account;
      Status  : E.Error_Info;
   begin
      M.Initialize
        (Account, Model_Runner.Limits.Default_Model_Limits, Budget => 1024);

      M.Check_Allocation (Account, M.KV_Cache, 512, Status);
      Assert (E.Is_Ok (Status), "an allocation inside the budget was refused");
      M.Record_Allocation (Account, M.KV_Cache, 512);

      --  The second request fits on its own and not alongside the first.
      M.Check_Allocation (Account, M.KV_Cache, 1024, Status);
      Assert (Status.Code = E.Memory_Limit_Exceeded,
              "an allocation past the budget was permitted");

      M.Check_Allocation (Account, M.KV_Cache, 512, Status);
      Assert (E.Is_Ok (Status),
              "an allocation that exactly fills the budget was refused");
   end Over_Budget_Is_Refused;

   --  Totals follow allocation and release, and the peak does not fall.
   procedure Totals_Follow_Allocation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Account : M.Account;
   begin
      M.Initialize (Account, Model_Runner.Limits.Default_Model_Limits);

      M.Record_Allocation (Account, M.Activations, 400);
      M.Record_Allocation (Account, M.Logits, 600);
      Assert (Account.Current = 1000, "current total is wrong");
      Assert (Account.Peak = 1000, "peak did not follow the allocations");

      M.Record_Release (Account, M.Activations, 400);
      Assert (Account.Current = 600, "a release did not reduce the current");

      --  A peak is a high-water mark. Allocating again after a release must
      --  not pull it down to the new current: a report that did would
      --  understate what the run actually needed, which is the one number
      --  anybody reads it for. Asserting only that a release leaves the peak
      --  alone is too weak -- releases never touch it.
      M.Record_Allocation (Account, M.Activations, 100);
      Assert (Account.Current = 700, "the current is wrong after reallocating");
      Assert (Account.Peak = 1000,
              "the peak followed the current downwards:"
              & U64'Image (Account.Peak));

      Assert (Account.By_Category (M.Logits) = 600,
              "the category total is wrong");
   end Totals_Follow_Allocation;

   --  Mapped bytes are not allocated bytes.
   procedure Mapping_Is_Counted_Apart
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Account : M.Account;
   begin
      M.Initialize (Account, Model_Runner.Limits.Default_Model_Limits);

      M.Record_Mapping (Account, 1_000_000);

      --  A mapped file is the operating system's pages, not this program's
      --  heap. Counting it as allocated would make a memory-mapped run look
      --  as though it had copied the model.
      Assert (Account.Mapped = 1_000_000, "mapped bytes were not recorded");
      Assert (Account.Current = 0,
              "a mapping was counted as an allocation");
      Assert (Account.Peak = 0, "a mapping raised the allocation peak");
   end Mapping_Is_Counted_Apart;

   --  A plan whose parts overflow is refused rather than wrapping.
   procedure Plan_Overflow_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Item   : M.Plan;
      Status : E.Error_Info;
   begin
      --  What a model file claiming impossible dimensions produces. Summed
      --  without care these wrap to a small number and the run proceeds as
      --  though the model were tiny.
      Item.File_Backed_Bytes := U64'Last / 2;
      Item.Copied_Bytes := U64'Last / 2;
      Item.Converted_Bytes := U64'Last / 2;

      M.Finalize_Plan (Item, Status);
      Assert (Status.Code = E.Memory_Plan_Overflow,
              "a plan that cannot be represented was accepted");
      Assert (not Item.Valid, "an overflowing plan was marked valid");
   end Plan_Overflow_Is_Refused;

   --  A plan totals the memory that will actually be resident.
   procedure Plan_Sums_Its_Parts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Item   : M.Plan;
      Status : E.Error_Info;
   begin
      Item.File_Backed_Bytes := 1000;
      Item.Copied_Bytes := 200;
      Item.Backend_Bytes := 30;
      Item.Alignment_Overhead := 4;

      M.Finalize_Plan (Item, Status);
      Assert (E.Is_Ok (Status), "a representable plan was refused");
      Assert (Item.Valid, "a representable plan was not marked valid");

      --  File-backed bytes are deliberately not in the total: a mapped model
      --  is the operating system's pages, and counting it as resident would
      --  say a run needs a gigabyte of memory it never asks the heap for.
      --  On top of what is resident sits a fixed margin.
      declare
         Resident : constant U64 := 200 + 30 + 4;
         Expected : constant U64 :=
           Resident + Resident / 100 * M.Safety_Margin_Percent;
      begin
         Assert (Item.Safety_Margin = Resident / 100 * M.Safety_Margin_Percent,
                 "the safety margin is wrong:"
                 & U64'Image (Item.Safety_Margin));
         Assert (Item.Total_Resident = Expected,
                 "the plan total is not what will be resident:"
                 & U64'Image (Item.Total_Resident) & ", expected"
                 & U64'Image (Expected));
      end;
   end Plan_Sums_Its_Parts;

   --  A clock that goes backwards yields no elapsed time.
   procedure Backwards_Clock_Yields_No_Duration
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Model_Runner.Clocks.Elapsed (From => 500, To => 1_500) = 1_000,
              "an ordinary interval was measured wrongly");

      --  Subtracting an unsigned reading from a smaller one would wrap to an
      --  enormous duration, and the statistics line would report a run that
      --  took nine years.
      Assert (Model_Runner.Clocks.Elapsed (From => 1_500, To => 500) = 0,
              "a clock that went backwards produced a duration");

      Assert (Model_Runner.Clocks.Elapsed (From => 7, To => 7) = 0,
              "no elapsed time was reported as some");
   end Backwards_Clock_Yields_No_Duration;

   --  A rate over no time is not infinite.
   procedure Rate_Over_No_Time_Is_Zero
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  One thousand units in one millisecond is a million a second.
      Assert (Model_Runner.Clocks.Rate_Per_Second (1_000, 1_000_000)
                = 1_000_000.0,
              "a rate was computed wrongly");

      --  Dividing by nothing: the answer is not a number, and reporting one
      --  would put "inf tokens/s" in front of a reader.
      Assert (Model_Runner.Clocks.Rate_Per_Second (1_000, 0) = 0.0,
              "a rate over no elapsed time was not zero");

      Assert (Model_Runner.Clocks.Rate_Per_Second (0, 1_000_000) = 0.0,
              "no units produced a non-zero rate");
   end Rate_Over_No_Time_Is_Zero;

   --  A mapped file reads back exactly what is in it, and refuses the rest.
   --
   --  The mapping had no test. It was rewritten recently into one body per
   --  host, and Copy is the only place in the engine that turns a file offset
   --  and a length into a read: if its bounds are wrong, a model file can walk
   --  off the end of its own mapping.
   procedure Mapping_Reads_And_Refuses
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package B renames Model_Runner.Bytes;
      package Map renames Model_Runner.Platform.Mapping;
      use type B.Byte;
      use type B.Byte_Count;

      Path : constant String := "obj/mapping-test.bin";

      Content : constant B.Byte_Array (1 .. 64) :=
        [for Index in 1 .. 64 => B.Byte ((Integer (Index) * 7) mod 256)];

      Region    : Map.Region;
      Available : Boolean;
      Target    : B.Byte_Array (1 .. 16) := [others => 0];
      Ok        : Boolean;
   begin
      declare
         use Ada.Streams.Stream_IO;
         Output : File_Type;
      begin
         Create (Output, Out_File, Path);
         for Byte of Content loop
            Ada.Streams.Stream_Element'Write
              (Stream (Output), Ada.Streams.Stream_Element (Byte));
         end loop;
         Close (Output);
      end;

      if not Map.Is_Supported then
         --  A host with no mapping says so and Open never succeeds. That is a
         --  statement about the host, not a skipped test.
         Map.Open (Region, Path, Available);
         Assert (not Available,
                 "a host without mapping reported a mapping anyway");
         Ada.Directories.Delete_File (Path);
         return;
      end if;

      Map.Open (Region, Path, Available);
      Assert (Available, "a readable file was not mapped");
      Assert (Map.Is_Open (Region), "the region is not open after mapping");
      Assert (Map.Length (Region) = 64,
              "the mapping length is wrong:"
              & B.Byte_Count'Image (Map.Length (Region)));

      --  What is read is what was written.
      Map.Copy (Region, 0, Target, Ok);
      Assert (Ok, "a read inside the mapping failed");
      for Index in Target'Range loop
         Assert (Target (Index) = Content (Index),
                 "byte" & Integer'Image (Integer (Index))
                 & " read back wrongly");
      end loop;

      --  And from an offset.
      Map.Copy (Region, 48, Target, Ok);
      Assert (Ok, "a read at an offset failed");
      Assert (Target (1) = Content (49), "the offset read the wrong byte");

      --  The last byte exactly, and then one past it.
      Map.Copy (Region, 64 - B.Byte_Count (Target'Length), Target, Ok);
      Assert (Ok, "a read ending exactly at the end was refused");

      Map.Copy (Region, 64 - B.Byte_Count (Target'Length) + 1, Target, Ok);
      Assert (not Ok, "a read running past the end was allowed");
      Assert (Target (1) = 0, "a refused read left data behind");

      Map.Copy (Region, 1_000_000, Target, Ok);
      Assert (not Ok, "a read far past the end was allowed");

      --  Close is idempotent and leaves nothing open.
      Map.Close (Region);
      Assert (not Map.Is_Open (Region), "the region is open after closing");
      Map.Close (Region);
      Assert (not Map.Is_Open (Region), "closing twice reopened the region");

      Map.Copy (Region, 0, Target, Ok);
      Assert (not Ok, "a closed region served a read");

      --  Nothing to map.
      Map.Open (Region, "obj/no-such-file-xyzzy", Available);
      Assert (not Available, "a missing file was mapped");
      Map.Open (Region, "obj", Available);
      Assert (not Available, "a directory was mapped");

      Ada.Directories.Delete_File (Path);
   end Mapping_Reads_And_Refuses;

   --  Checked arithmetic carries overflow instead of raising or wrapping.
   --
   --  Every offset addition, alignment rounding and element-count multiply in
   --  the parser goes through this package, and nothing tested it directly. A
   --  multiply that wrapped would be the worst of the possibilities: a file
   --  could declare dimensions whose product wraps to something small, pass
   --  the bound that checks the product, and then be read at its real size.
   procedure Checked_Arithmetic_Carries_Overflow
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package A renames Model_Runner.Arithmetic;
      use type A.Checked;

      Big  : constant A.Checked := A.To_Checked (Interfaces.Unsigned_64'Last);
      Two  : constant A.Checked := A.To_Checked (Interfaces.Unsigned_64 (2));
      Zero : constant A.Checked := A.To_Checked (Interfaces.Unsigned_64 (0));
      Modest : constant A.Checked := A.To_Checked (Interfaces.Unsigned_64 (100));
      Room : Natural;
   begin
      --  Ordinary arithmetic is ordinary.
      Assert (A.Is_Valid (Modest + Modest) and then A.Value (Modest + Modest) = 200,
              "a sum inside the range was refused or wrong");
      Assert (A.Is_Valid (Modest * Two) and then A.Value (Modest * Two) = 200,
              "a product inside the range was refused or wrong");
      Assert (A.Is_Valid (Modest - Two) and then A.Value (Modest - Two) = 98,
              "a difference inside the range was refused or wrong");

      --  Overflow is carried, not raised and not wrapped. Wrapping is the
      --  dangerous answer: it produces a small number that passes a bound.
      Assert (not A.Is_Valid (Big + Modest), "a sum past the range was accepted");
      Assert (not A.Is_Valid (Big * Two),
              "a product past the range was accepted");
      Assert (not A.Is_Valid (Modest - Big),
              "a difference below zero was accepted");
      Assert (not A.Is_Valid (Modest / Zero), "a division by zero was accepted");

      --  Zero multiplies to zero rather than to invalid, which the size
      --  computations rely on for an empty tensor.
      Assert (A.Is_Valid (Big * Zero) and then A.Value (Big * Zero) = 0,
              "multiplying by zero was refused");

      --  Invalidity is absorbing: once lost it cannot be recovered by
      --  arithmetic that would otherwise be sound. This is what lets the
      --  parser compute a chain and ask once at the end.
      Assert (not A.Is_Valid ((Big + Modest) - Big),
              "an invalid value became valid again by subtraction");
      Assert (not A.Is_Valid ((Big * Two) * Zero),
              "an invalid value became valid again by multiplying by zero");
      Assert (not A.Is_Valid (A.Align_Up (Big + Modest, 16)),
              "an invalid value became valid again by alignment");

      --  Alignment rounds up, leaves an aligned value alone, and refuses an
      --  alignment that is not a power of two.
      Assert (A.Value (A.Align_Up (A.To_Checked (Interfaces.Unsigned_64 (1)), 16)) = 16,
              "one did not round up to sixteen");
      Assert (A.Value (A.Align_Up (A.To_Checked (Interfaces.Unsigned_64 (16)), 16)) = 16,
              "an aligned value was moved");
      Assert (not A.Is_Valid (A.Align_Up (Modest, 3)),
              "an alignment that is not a power of two was accepted");
      Assert (not A.Is_Valid (A.Align_Up (Big, 16)),
              "rounding up past the range was accepted");

      --  Narrowing to Natural reports whether it fits rather than raising.
      --  The result is zeroed on failure, which the spec promises and a
      --  caller that forgets to check the answer depends on.
      --  Split for the same reason as the refusal below: joined by and then,
      --  the assignment to Room might never be read, and at -O3 the compiler
      --  says so.
      declare
         Fits : Boolean;
      begin
         Fits := A.To_Natural (Modest, Room);
         Assert (Fits and then Room = 100,
                 "a value inside Natural did not convert");
      end;
      declare
         Fits : Boolean;
      begin
         --  Split so that Room is read whatever the answer: with these joined
         --  by and then, a compiler is right to say the assignment might
         --  never be looked at.
         Fits := A.To_Natural (Big, Room);
         Assert (not Fits, "a value past Natural converted anyway");
         Assert (Room = 0, "a refused conversion left a value behind");

         Fits := A.To_Natural (Big + Modest, Room);
         Assert (not Fits, "an invalid value converted anyway");
         Assert (Room = 0, "an invalid conversion left a value behind");
      end;

      --  And the range test that guards every bound in the parser.
      Assert (A.In_Range (Modest, 100), "a value at its bound was refused");
      Assert (not A.In_Range (Modest, 99), "a value past its bound was accepted");
      Assert (not A.In_Range (Big + Modest, Interfaces.Unsigned_64'Last),
              "an invalid value passed a range test");
   end Checked_Arithmetic_Carries_Overflow;

   --  The byte readers decode little-endian and refuse to read past the end.
   --
   --  Every field of a model file is read through these: a magic number, a
   --  count, an offset, a scale. They are the boundary between a buffer and a
   --  value, and nothing tested them directly -- the container tests reach
   --  them only through a parser that has already decided what to read.
   --
   --  Two properties matter. The byte order is fixed by the format and not by
   --  the host, so a value must decode the same way on any machine. And a
   --  field that runs past the end must report that rather than read whatever
   --  follows the buffer.
   procedure Byte_Readers_Decode_And_Refuse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package B renames Model_Runner.Bytes;
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_16;
      use type Interfaces.Unsigned_32;
      use type Interfaces.Integer_32;

      --  Eight bytes counting up, so a wrong byte order is visible in the
      --  value rather than hidden by symmetry.
      Data : constant B.Byte_Array (1 .. 8) :=
        [16#01#, 16#02#, 16#03#, 16#04#, 16#05#, 16#06#, 16#07#, 16#08#];
      Ok   : Boolean;
   begin
      --  Little-endian, least significant byte first.
      Assert (B.Get_U8 (Data, 0, Ok) = 16#01# and then Ok,
              "one byte decoded wrongly");
      Assert (B.Get_U16 (Data, 0, Ok) = 16#0201# and then Ok,
              "two bytes decoded in the wrong order");
      Assert (B.Get_U32 (Data, 0, Ok) = 16#04030201# and then Ok,
              "four bytes decoded in the wrong order");
      Assert (B.Get_U64 (Data, 0, Ok) = 16#0807060504030201# and then Ok,
              "eight bytes decoded in the wrong order");

      --  From an offset, not only from the start.
      Assert (B.Get_U16 (Data, 6, Ok) = 16#0807# and then Ok,
              "a field at an offset decoded wrongly");

      --  Signed values are two's complement over the same bytes.
      declare
         Negative : constant B.Byte_Array (1 .. 4) :=
           [16#FF#, 16#FF#, 16#FF#, 16#FF#];
      begin
         Assert (B.Get_I32 (Negative, 0, Ok) = -1 and then Ok,
                 "all ones did not decode as minus one");
      end;

      --  A field that would run past the end is refused, and the value it
      --  returns is zero rather than whatever was in the buffer.
      Assert (B.Get_U64 (Data, 1, Ok) = 0 and then not Ok,
              "eight bytes were read from an offset with seven left");
      Assert (B.Get_U32 (Data, 5, Ok) = 0 and then not Ok,
              "four bytes were read from an offset with three left");
      Assert (B.Get_U16 (Data, 7, Ok) = 0 and then not Ok,
              "two bytes were read from an offset with one left");
      Assert (B.Get_U8 (Data, 8, Ok) = 0 and then not Ok,
              "a byte was read from one past the end");

      --  The last field that does fit is read, so the refusals above are a
      --  boundary rather than a blanket.
      Assert (B.Get_U64 (Data, 0, Ok) /= 0 and then Ok,
              "the only eight-byte field that fits was refused");
      Assert (B.Get_U8 (Data, 7, Ok) = 16#08# and then Ok,
              "the last byte was refused");

      --  An empty buffer refuses everything rather than raising.
      declare
         Nothing : constant B.Byte_Array (1 .. 0) := [];
      begin
         Assert (B.Get_U8 (Nothing, 0, Ok) = 0 and then not Ok,
                 "a byte was read from an empty buffer");
      end;
   end Byte_Readers_Decode_And_Refuse;

   --  The release archive contains what a distribution needs, with the
   --  executable executable.
   --
   --  This is the one piece of tooling whose failure appears on somebody
   --  else's machine: an archive missing a file, or unpacking a program
   --  without its execute bit, is discovered when it is unpacked and not
   --  before. Nothing exercised it, and the release checklist does not build
   --  one.
   procedure Archive_Carries_A_Distribution
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Tarlib.Entries.File_Mode;

      Root : constant String := "obj/package-root";
      Into : constant String := "obj/package-out";

      --  Write a file with some content, making its directory first.
      procedure Put_File (Relative : String; Content : String) is
         Full : constant String := Hostkit.Fs.Join (Root, Relative);
         Cut  : Natural := 0;
         Handle : Ada.Text_IO.File_Type;
      begin
         for Index in reverse Full'Range loop
            if Full (Index) = '/' then
               Cut := Index;
               exit;
            end if;
         end loop;

         if Cut > 0 and then not Ada.Directories.Exists (Full (Full'First .. Cut - 1))
         then
            Ada.Directories.Create_Path (Full (Full'First .. Cut - 1));
         end if;

         Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Full);
         Ada.Text_IO.Put (Handle, Content);
         Ada.Text_IO.Close (Handle);
      end Put_File;

      --  Report whether the archive holds a path, and with which mode.
      procedure Look_For
        (Archive : String;
         Wanted  : String;
         Found   : out Boolean;
         Mode    : out Tarlib.Entries.File_Mode)
      is
         Source : aliased Tarlib.Files.File_Input_Source;
         Reader : Tarlib.Readers.Reader;
         Info   : Tarlib.Readers.Entry_Info;
         Present : Boolean;
         Result : Tarlib.Errors.Status;
      begin
         Found := False;
         Mode := 0;

         Tarlib.Files.Open_Read (Source, Archive, Result);
         Assert (Tarlib.Errors.Is_Success (Result),
                 "the archive could not be opened: " & Archive & " -- "
                 & Tarlib.Errors.Status_Code'Image (Result.Code));

         Tarlib.Readers.Initialize (Reader, Source, Result);
         Assert (Tarlib.Errors.Is_Success (Result),
                 "the archive could not be read");

         loop
            Tarlib.Readers.Next_Entry (Reader, Info, Present, Result);
            exit when not Present or else not Tarlib.Errors.Is_Success (Result);

            if Tarlib.Readers.Path (Info) = Wanted then
               Found := True;
               Mode := Tarlib.Readers.Metadata (Info).Mode;
            end if;

            Tarlib.Readers.Skip_Entry (Reader, Result);
            exit when not Tarlib.Errors.Is_Success (Result);
         end loop;

         --  Closed before returning. Ada refuses to reopen a file that is
         --  still open in the same program, so a reader left open here makes
         --  the next question about the same archive fail as though the
         --  archive were at fault.
         Tarlib.Files.Close (Source, Result);
      end Look_For;

      Prefix : constant String :=
        Model_Runner.Program_Name & "-" & Model_Runner.Version;
      Archive : constant String :=
        Hostkit.Fs.Join (Into, Prefix & ".tar");

      Written : Boolean;
      Found   : Boolean;
      Mode    : Tarlib.Entries.File_Mode;

      --  Everything the archive holds, in one string, so that what is in it
      --  can be compared with what belongs in it.
      function Listing (Archive : String) return String is
         Source  : aliased Tarlib.Files.File_Input_Source;
         Reader  : Tarlib.Readers.Reader;
         Info    : Tarlib.Readers.Entry_Info;
         Present : Boolean;
         Result  : Tarlib.Errors.Status;

         Room : String (1 .. 4_096);
         Used : Natural := 0;
      begin
         Tarlib.Files.Open_Read (Source, Archive, Result);
         Assert (Tarlib.Errors.Is_Success (Result),
                 "the archive could not be opened for listing");

         Tarlib.Readers.Initialize (Reader, Source, Result);
         Assert (Tarlib.Errors.Is_Success (Result),
                 "the archive could not be read for listing");

         loop
            Tarlib.Readers.Next_Entry (Reader, Info, Present, Result);
            exit when not Present or else not Tarlib.Errors.Is_Success (Result);

            declare
               Path : constant String := Tarlib.Readers.Path (Info);
            begin
               if Used + Path'Length + 1 <= Room'Length then
                  Room (Used + 1 .. Used + Path'Length) := Path;
                  Used := Used + Path'Length + 1;
                  Room (Used) := '|';
               end if;
            end;

            Tarlib.Readers.Skip_Entry (Reader, Result);
            exit when not Tarlib.Errors.Is_Success (Result);
         end loop;

         Tarlib.Files.Close (Source, Result);
         return Room (1 .. Used);
      end Listing;

      --  Every member the archive is supposed to carry.
      procedure Must_Hold (Wanted : String) is
         Present : Boolean;
         Ignored : Tarlib.Entries.File_Mode;
      begin
         Look_For (Archive, Wanted, Present, Ignored);
         Assert (Present, "the archive is missing " & Wanted);
      end Must_Hold;
   begin
      --  A root holding everything the archive is supposed to carry.
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Into);

      Put_File ("bin/" & Model_Runner.Program_Name, "not really a program");
      Put_File ("resources/messages/catalog.txt", "en.x = y");
      Put_File ("LICENSE", "a licence");
      Put_File ("README.md", "a readme");
      Put_File ("CHANGELOG.md", "a changelog");
      Put_File ("SECURITY.md", "a security note");

      Packaging.Run (Root, Into, Written);
      Assert (Written, "a complete root did not produce an archive");

      --  Every member is there, under the versioned prefix that makes the
      --  archive unpack over a prefix as an installation.
      Must_Hold (Prefix & "/bin/" & Model_Runner.Program_Name);
      Must_Hold
        (Prefix & "/share/" & Model_Runner.Program_Name
         & "/messages/catalog.txt");
      Must_Hold (Prefix & "/LICENSE");
      Must_Hold (Prefix & "/README.md");
      Must_Hold (Prefix & "/CHANGELOG.md");
      Must_Hold (Prefix & "/SECURITY.md");

      --  And nothing else. Every check above asks whether something is
      --  there; none of them asks what else is, and a distribution is as
      --  much about what it does not carry -- a model file it found in the
      --  tree, a build artefact, a key -- as about what it does. The
      --  specification forbids redistributing a model, and an archive is
      --  where one would leave without anyone deciding to send it.
      declare
         Held : constant String := Listing (Archive);

         Expected : constant String :=
           Prefix & "/bin/" & Model_Runner.Program_Name & "|"
           & Prefix & "/share/" & Model_Runner.Program_Name
           & "/messages/catalog.txt|"
           & Prefix & "/LICENSE|"
           & Prefix & "/README.md|"
           & Prefix & "/CHANGELOG.md|"
           & Prefix & "/SECURITY.md|";
      begin
         Assert (Held = Expected,
                 "the archive carries something other than its six members:"
                 & ASCII.LF & "  holds    " & Held
                 & ASCII.LF & "  expected " & Expected);
      end;

      --  The program is executable and the documents are not. An archive
      --  whose program unpacks without its execute bit is not a distribution.
      Look_For (Archive, Prefix & "/bin/" & Model_Runner.Program_Name,
                Found, Mode);
      Assert (Mode = 8#0755#,
              "the program is not executable in the archive:"
              & Tarlib.Entries.File_Mode'Image (Mode));

      Look_For (Archive, Prefix & "/README.md", Found, Mode);
      Assert (Mode = 8#0644#,
              "a document carries the execute bit:"
              & Tarlib.Entries.File_Mode'Image (Mode));

      --  A root missing one file produces no archive at all, rather than one
      --  that is quietly incomplete.
      Ada.Directories.Delete_File (Root & "/LICENSE");
      Ada.Directories.Delete_File (Archive);
      Packaging.Run (Root, Into, Written);
      Assert (not Written,
              "an incomplete root produced an archive anyway");
      Assert (not Ada.Directories.Exists (Archive),
              "a refused packaging left an archive behind");

      Ada.Directories.Delete_Tree (Root);
      Ada.Directories.Delete_Tree (Into);
   end Archive_Carries_A_Distribution;

   --  Numbers and text are rendered the way the reader will see them.
   --
   --  Every figure in a statistics line, every count in a diagnostic and
   --  every path in an error goes through these. A formatter that dropped a
   --  leading zero from a fraction would print a rate of 0.05 as 0.5, and
   --  nothing else in the program would notice.
   procedure Text_Renders_What_The_Reader_Sees
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package T2 renames Model_Runner.Text;
   begin
      --  Integers, without the leading space Ada puts on them.
      Assert (T2.Image (Long_Long_Integer (0)) = "0", "zero rendered wrongly");
      Assert (T2.Image (Long_Long_Integer (42)) = "42",
              "a positive integer rendered wrongly");
      Assert (T2.Image (Long_Long_Integer (-42)) = "-42",
              "a negative integer rendered wrongly");

      --  Fractions keep their leading zeros. This is the one that would be
      --  wrong quietly: 0.05 printed as 0.5 is a tenfold misreport.
      Assert (T2.Image (Long_Float (0.05), 2) = "0.05",
              "a fraction lost its leading zero: "
              & T2.Image (Long_Float (0.05), 2));
      Assert (T2.Image (Long_Float (1.5), 3) = "1.500",
              "a fraction was not padded: " & T2.Image (Long_Float (1.5), 3));
      Assert (T2.Image (Long_Float (2.0), 0) = "2",
              "asking for no decimals produced some: "
              & T2.Image (Long_Float (2.0), 0));
      Assert (T2.Image (Long_Float (-1.25), 2) = "-1.25",
              "a negative fraction rendered wrongly: "
              & T2.Image (Long_Float (-1.25), 2));

      --  Rounding is to nearest, away from the truncation that would make
      --  every reported rate slightly optimistic.
      Assert (T2.Image (Long_Float (1.006), 2) = "1.01",
              "rounding went down: " & T2.Image (Long_Float (1.006), 2));

      --  A value with no fixed-point image says so instead of raising inside
      --  a diagnostic, which is where these are usually called from.
      Assert (T2.Image (Long_Float'Last, 2) = "inf",
              "a value too large to render did not say so: "
              & T2.Image (Long_Float'Last, 2));
      Assert (T2.Image (-Long_Float'Last, 2) = "-inf",
              "a value too small to render did not say so");

      --  Bounded text records the loss rather than hiding it, so a truncated
      --  path in a diagnostic can be told from a short one.
      declare
         Fits : constant T2.Bounded := T2.To_Bounded ("short");
         Cut  : constant T2.Bounded :=
           T2.To_Bounded ([1 .. T2.Max_Length + 10 => 'x']);
      begin
         Assert (T2.To_String (Fits) = "short", "short text was altered");
         Assert (not Fits.Truncated,
                 "short text was reported as truncated");
         Assert (T2.To_String (Cut)'Length = T2.Max_Length,
                 "long text was not cut to the bound");
         Assert (Cut.Truncated,
                 "long text was cut without recording it");
      end;
   end Text_Renders_What_The_Reader_Sees;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("memory accounting and clocks");
   end Name;

   ---------------------
   -- Register_Tests --
   ---------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Over_Budget_Is_Refused'Access,
         "an allocation past the budget is refused before it is attempted");
      Register_Routine
        (T, Totals_Follow_Allocation'Access,
         "totals follow allocation and release, and the peak does not fall");
      Register_Routine
        (T, Mapping_Is_Counted_Apart'Access,
         "mapped bytes are not counted as allocated bytes");
      Register_Routine
        (T, Plan_Overflow_Is_Refused'Access,
         "a plan that cannot be represented is refused rather than wrapping");
      Register_Routine
        (T, Plan_Sums_Its_Parts'Access,
         "a representable plan totals its parts exactly");
      Register_Routine
        (T, Backwards_Clock_Yields_No_Duration'Access,
         "a clock that goes backwards yields no elapsed time");
      Register_Routine
        (T, Text_Renders_What_The_Reader_Sees'Access,
         "numbers and text render the way the reader will see them");
      Register_Routine
        (T, Archive_Carries_A_Distribution'Access,
         "the release archive carries a distribution with the program executable");
      Register_Routine
        (T, Byte_Readers_Decode_And_Refuse'Access,
         "the byte readers decode little-endian and refuse to read past the end");
      Register_Routine
        (T, Checked_Arithmetic_Carries_Overflow'Access,
         "checked arithmetic carries overflow instead of raising or wrapping");
      Register_Routine
        (T, Mapping_Reads_And_Refuses'Access,
         "a mapping reads back what is in the file and refuses the rest");
      Register_Routine
        (T, Rate_Over_No_Time_Is_Zero'Access,
         "a rate over no elapsed time is zero rather than infinite");
   end Register_Tests;

end Tests.Accounting_Cases;
