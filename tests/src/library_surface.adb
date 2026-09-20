package body Library_Surface is

   type Text_Access is access constant String;

   --  Held without a bound on purpose. It was `array (1 .. 39)` and every
   --  name added had to have the bound raised beside it; one that did not
   --  raised Constraint_Error where the package is elaborated, which is
   --  before the check this list is for can say anything -- so the gate
   --  died rather than reported, and a reader looking for the word "fail"
   --  in its output saw a clean run.
   type Text_List is array (Positive range <>) of Text_Access;

   --  The codec's other half.
   Held : constant Text_List :=
     [new String'("Get_F16"),
      new String'("Tensor_Code"),
      new String'("Value_Code"),
      new String'("Wipe"),

      --  Second opinions.
      new String'("All_Finite"),
      new String'("Row_Dot"),

      --  State a library caller needs.
      --
      --  Hidden_State is here because the embedding command stopped needing
      --  it: it evaluates in batches now and asks for every position's
      --  state at once, which only that path can give. A caller evaluating
      --  a token at a time has no other way to read what the model made of
      --  what it read, so the operation stays.
      new String'("Hidden_State"),
      new String'("Has_Template"),
      new String'("Is_Closed"),
      new String'("Is_Loaded"),
      new String'("Is_Normal"),
      new String'("Seed_Used"),
      new String'("String_Count"),
      new String'("Unknown_Token"),

      --  Building a diagnostic.
      new String'("Add_Boolean"),
      new String'("Find_Parameter"),
      new String'("Set_Cause"),

      --  Planning a session.
      new String'("Finalize_Plan"),

      --  Helpers.
      new String'("Equal_Ignore_Case"),
      new String'("Failure_Name"),
      new String'("Has_Controls"),
      new String'("Host_Name"),
      new String'("In_Range"),
      new String'("Is_NaN"),
      new String'("To_Natural"),
      new String'("Wide_Bits"),

      --  And where the device's time went, step by step, from its own
      --  clock. `tests speed --device-timeline` is what asks; the command
      --  has --budget for the host's phases and no reason to hold a run
      --  up for the device's stamps, which is what keeping a timeline
      --  costs. Timed is the engine's answer to whether it is stamping,
      --  which the backend keeps for itself and a caller with its own
      --  engine asks.
      new String'("Keep_Timeline"),
      new String'("Timeline_Report"),
      --  The side of the square a vision projector reads. The command asks
      --  the projector for the rows a picture becomes and their width and
      --  resamples nothing itself; `tests see` prints the side, and a
      --  program showing a reader what a projector will make of a picture
      --  asks the same.
      new String'("Image_Size"),

      --  Whether a projector makes every picture the same number of rows.
      --  The command gathers a picture's rows and takes what it gets;
      --  a program laying out room for a conversation's pictures before
      --  encoding any asks first.
      new String'("Fixed_Rows"),

      --  What a session's position turns by, in its three parts. The
      --  engine marks and reads them itself; the suite reads them back
      --  to see a picture's rows placed by row and column, and a program
      --  showing where a picture's rows stand asks the same.
      new String'("Turned_By"),

      --  Which roles of weight round their activations, as the backend was
      --  last told. The command tells and never asks back; a caller with
      --  its own engine, or a test restoring what it found, asks.
      new String'("Integer_Activation_Roles"),

      --  How far back a hybrid session may be rewound. The round that
      --  needs the answer asks for the count itself and knows it; a
      --  caller handed a session by somebody else does not, and a rewind
      --  refused after the fact is a poorer answer than a count asked
      --  first.
      new String'("States_Kept"),

      --  What a session holds its values in, where --kv-values stored them
      --  otherwise than its keys. The command chose and has no reason to
      --  ask back; a caller handed a session, or a test holding one to
      --  what it asked for, does.
      new String'("Value_Precision_Of"),

      --  Which of the packed kernels' two compilations is bound: the one
      --  through shared memory alone, which a device without subgroup
      --  operations gets and the suite asks for on one that has them.
      new String'("Prefer_Plain_Packing"),

      --  Whether this device keeps the cache's half-precision copy. The
      --  engine knows because it decides; nothing else in the program
      --  needs to, and a test holding a reserved cache to what it should
      --  take -- six bytes an element with the copy and four without --
      --  is the one caller there is.
      new String'("Keeps_Copy"),

      --  What a server asks of the device's sixteen blocks and sixteen
      --  seats: how many are held, and whether this session is in one.
      --  The command runs a session or two and never wonders; a caller
      --  deciding whom to admit, or whom to close, has nothing else to
      --  ask -- the statistics count what was turned over once the run is
      --  over, which says what happened rather than what is.
      new String'("Holds_Block"),
      new String'("Holds_Seat"),
      new String'("Seats_Held")];

   ---------------
   -- Is_Listed --
   ---------------

   function Is_Listed (Name : String) return Boolean is
   begin
      for Item_Value of Held loop
         if Item_Value.all = Name then
            return True;
         end if;
      end loop;
      return False;
   end Is_Listed;

   -----------
   -- Count --
   -----------

   function Count return Natural is (Held'Length);

   ----------
   -- Item --
   ----------

   function Item (Index : Positive) return String is (Held (Index).all);

end Library_Surface;
