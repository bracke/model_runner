with Ada.Unchecked_Deallocation;

with Model_Runner.GGUF.Containers.Reader;

package body Model_Runner.GGUF.Shards is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package F renames Model_Runner.Byte_Sources.Files;

   use type B.Byte_Count;

   procedure Free is
     new Ada.Unchecked_Deallocation (F.File_Source, Part_Access);

   --  The convention's suffix is fixed width: a dash, five digits, "-of-",
   --  five digits and the extension. Nothing here parses a name that is one
   --  character shorter or one digit wider, because a name that is neither
   --  the convention nor a plain path is a name this cannot reason about.
   Suffix_Length : constant := 1 + 5 + 4 + 5 + 5;   --  -00001-of-00003.gguf

   --  Five digits of a number, as the convention writes them.
   function Padded (Value : Natural) return String;

   ------------
   -- Padded --
   ------------

   function Padded (Value : Natural) return String is
      Digits_Out : String (1 .. 5) := "00000";
      Left       : Natural := Value;
   begin
      for Place in reverse Digits_Out'Range loop
         Digits_Out (Place) :=
           Character'Val (Character'Pos ('0') + Left mod 10);
         Left := Left / 10;
      end loop;

      return Digits_Out;
   end Padded;

   --------------------
   -- Is_Shard_Name --
   --------------------

   function Is_Shard_Name (Path : String) return Boolean is
   begin
      if Path'Length < Suffix_Length then
         return False;
      end if;

      declare
         Tail : constant String :=
           Path (Path'Last - Suffix_Length + 1 .. Path'Last);
      begin
         if Tail (Tail'First) /= '-'
           or else Tail (Tail'First + 6 .. Tail'First + 9) /= "-of-"
           or else Tail (Tail'First + 15 .. Tail'Last) /= ".gguf"
         then
            return False;
         end if;

         for Place in Tail'First + 1 .. Tail'First + 5 loop
            if Tail (Place) not in '0' .. '9' then
               return False;
            end if;
         end loop;

         for Place in Tail'First + 10 .. Tail'First + 14 loop
            if Tail (Place) not in '0' .. '9' then
               return False;
            end if;
         end loop;

         return True;
      end;
   end Is_Shard_Name;

   ----------------
   -- Shard_Path --
   ----------------

   function Shard_Path
     (First : String; Index : Positive; Count : Positive) return String is
   begin
      if not Is_Shard_Name (First) then
         return "";
      end if;

      return First (First'First .. First'Last - Suffix_Length)
             & "-" & Padded (Index) & "-of-" & Padded (Count) & ".gguf";
   end Shard_Path;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item      : in out Shard_Set;
      Path      : String;
      Policy    : F.Mapping_Policy := F.Mapping_Automatic;
      Max_Bytes : B.Byte_Count := 0;
      Status    : out E.Error_Info) is
   begin
      Close (Item);

      Item.Policy := Policy;
      Item.Bound := Max_Bytes;
      Item.Files (1) := new F.File_Source;

      F.Open (Item.Files (1).all, Path, Policy, Max_Bytes, Status);
      if E.Is_Error (Status) then
         Free (Item.Files (1));
         return;
      end if;

      Item.Held := 1;
      Item.Spans (1) := (Start => 0, Length => F.Size (Item.Files (1).all));
      Item.Total := Item.Spans (1).Length;
   end Open;

   ----------------
   -- Open_Model --
   ----------------

   procedure Open_Model
     (Item     : in out Shard_Set;
      Held     : in out Model_Runner.GGUF.Containers.Container;
      Path     : String;
      Policy   : F.Mapping_Policy := F.Mapping_Automatic;
      Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null;
      Status   : out E.Error_Info)
   is
      package Containers renames Model_Runner.GGUF.Containers;
   begin
      Open (Item, Path, Policy,
            Model_Runner.Bytes.Byte_Count (Bounds.Max_File_Bytes), Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  Parsed once to learn how many files there are, which is written in
      --  the first of them and cannot be read before it has been parsed.
      --  Both parses read metadata and no tensor data.
      Containers.Reader.Parse (Held, Item, Bounds, Cancel, Observer, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Containers.Shard_Count (Held) <= 1 then
         return;
      end if;

      Open_Rest (Item, Containers.Shard_Count (Held), Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Others_Of : constant Model_Runner.Byte_Sources.Source_Array :=
           Rest (Item);
      begin
         Containers.Reader.Parse
           (Held, First (Item).all, Bounds, Cancel, Observer, Status,
            More => Others_Of);
      end;
   end Open_Model;

   ---------------
   -- Open_Rest --
   ---------------

   procedure Open_Rest
     (Item   : in out Shard_Set;
      Count  : Positive;
      Status : out E.Error_Info) is
   begin
      Status := E.Success;

      if Item.Held /= 1 then
         --  Either nothing is open or the rest are open already. Neither is
         --  a caller's mistake worth a code of its own; doing nothing is
         --  what both want.
         return;
      end if;

      if Count = 1 then
         return;
      end if;

      if Count > Max_Shards then
         Status := E.Make (E.GGUF_Shard_Count_Too_Large);
         E.Add_Integer (Status, "count", Long_Long_Integer (Count));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Shards));
         return;
      end if;

      declare
         First : constant String := F.Name (Item.Files (1).all);
      begin
         if not Is_Shard_Name (First) then
            --  The file says it is one of several and its name does not say
            --  which, so there is no way to find the others that is not a
            --  guess. Named rather than guessed at.
            Status := E.Make (E.GGUF_Shard_Name_Unusable);
            E.Add_Text (Status, "path", First);
            E.Add_Integer (Status, "count", Long_Long_Integer (Count));
            return;
         end if;

         for Index in 2 .. Count loop
            declare
               Path : constant String := Shard_Path (First, Index, Count);
            begin
               Item.Files (Index) := new F.File_Source;

               F.Open (Item.Files (Index).all, Path, Item.Policy, Item.Bound,
                       Status);
               if E.Is_Error (Status) then
                  Free (Item.Files (Index));

                  --  Which file, said here rather than left to the reader
                  --  of an open failure that names a path nobody typed.
                  E.Add_Text (Status, "shard", Path);
                  E.Add_Integer (Status, "index", Long_Long_Integer (Index));
                  E.Add_Integer (Status, "count", Long_Long_Integer (Count));
                  return;
               end if;

               Item.Spans (Index) :=
                 (Start  => Item.Total,
                  Length => F.Size (Item.Files (Index).all));
               Item.Total := Item.Total + Item.Spans (Index).Length;
               Item.Held := Index;
            end;
         end loop;
      end;
   end Open_Rest;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Shard_Set) is
   begin
      for Index in 1 .. Item.Held loop
         if Item.Files (Index) /= null then
            F.Close (Item.Files (Index).all);
            Free (Item.Files (Index));
         end if;
      end loop;

      Item.Files := [others => null];
      Item.Spans := [others => (0, 0)];
      Item.Held := 0;
      Item.Total := 0;
   end Close;

   -----------
   -- Parts --
   -----------

   function Parts (Item : Shard_Set) return Natural is (Item.Held);

   -----------
   -- First --
   -----------

   function First
     (Item : in out Shard_Set)
      return Model_Runner.Byte_Sources.Source_Reference
   is (if Item.Held = 0
       then null
       else Model_Runner.Byte_Sources.Source_Reference (Item.Files (1)));

   ----------
   -- Rest --
   ----------

   function Rest
     (Item : in out Shard_Set) return Model_Runner.Byte_Sources.Source_Array
   is
      Result : Model_Runner.Byte_Sources.Source_Array
        (1 .. Natural'Max (Item.Held - 1, 0));
   begin
      for Index in Result'Range loop
         Result (Index) :=
           Model_Runner.Byte_Sources.Source_Reference
             (Item.Files (Index + 1));
      end loop;

      return Result;
   end Rest;

   ----------
   -- Size --
   ----------

   overriding function Size (Self : Shard_Set) return B.Byte_Count
   is (Self.Total);

   ----------
   -- Read --
   ----------

   overriding procedure Read
     (Self   : in out Shard_Set;
      Offset : B.Byte_Count;
      Target : out B.Byte_Array;
      Status : out E.Error_Info)
   is
      Taken : B.Byte_Count := 0;
   begin
      Status := E.Success;

      if Target'Length = 0 then
         return;
      end if;

      if Self.Held = 0
        or else Offset > Self.Total
        or else Target'Length > Self.Total - Offset
      then
         Status := E.Make (E.GGUF_Truncated);
         return;
      end if;

      --  A read is served from as many parts as it spans, which for every
      --  read the parser makes is one: a tensor lies inside a shard by
      --  construction and a header is at the front of one. The loop is here
      --  for the reads that are not the parser's -- and for the one that
      --  would otherwise fall off the end of a file and be answered with
      --  whatever followed it.
      while Taken < Target'Length loop
         declare
            At_Byte : constant B.Byte_Count := Offset + Taken;
            Which   : Natural := 0;
         begin
            for Index in 1 .. Self.Held loop
               if At_Byte >= Self.Spans (Index).Start
                 and then At_Byte
                          < Self.Spans (Index).Start
                            + Self.Spans (Index).Length
               then
                  Which := Index;
                  exit;
               end if;
            end loop;

            if Which = 0 then
               Status := E.Make (E.GGUF_Truncated);
               return;
            end if;

            declare
               Inside : constant B.Byte_Count :=
                 At_Byte - Self.Spans (Which).Start;

               Room : constant B.Byte_Count :=
                 Self.Spans (Which).Length - Inside;

               Want : constant B.Byte_Count :=
                 B.Byte_Count'Min (Room, Target'Length - Taken);
            begin
               F.Read
                 (Self.Files (Which).all, Inside,
                  Target (Target'First + Taken
                          .. Target'First + Taken + Want - 1),
                  Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               Taken := Taken + Want;
            end;
         end;
      end loop;
   end Read;

   ---------------
   -- Is_Mapped --
   ---------------

   --  One part answers as that part, and several answer no.
   --
   --  Several mappings are several addresses and a caller asking this is
   --  about to ask for one. Saying no sends it down the reading path, which
   --  every source that is not mapped already takes.
   overriding function Is_Mapped (Self : Shard_Set) return Boolean
   is (Self.Held = 1 and then F.Is_Mapped (Self.Files (1).all));

   ----------
   -- Base --
   ----------

   overriding function Base (Self : Shard_Set) return System.Address
   is (if Self.Held = 1
       then F.Base (Self.Files (1).all)
       else System.Null_Address);

   ----------
   -- Name --
   ----------

   --  The first shard's path, which is what a caller typed and what every
   --  diagnostic about the model should say. A diagnostic about one of the
   --  others says which one itself.
   overriding function Name (Self : Shard_Set) return String
   is (if Self.Held = 0 then "" else F.Name (Self.Files (1).all));

   -------------
   -- Changed --
   -------------

   overriding function Changed (Self : Shard_Set) return Boolean is
   begin
      for Index in 1 .. Self.Held loop
         if F.Changed (Self.Files (Index).all) then
            return True;
         end if;
      end loop;

      return False;
   end Changed;

end Model_Runner.GGUF.Shards;
