private with Ada.Finalization;

with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Tokenizer;

--  Stop tokens and stop strings.
--
--  Two kinds of stop condition are checked at different points of the
--  generation loop, and the difference matters:
--
--    A stop token is matched before its text is ever produced, so no byte of
--    it reaches the output.
--
--    A stop string is matched after incremental decoding but before buffered
--    text is released, so no byte of a completed stop string reaches the
--    output either -- including when the string spans a token boundary.
--
--  Overlapping stop strings resolve deterministically: the earliest match
--  position wins, and among matches at that position the longest wins.
--
--  Bounds. The count, the individual length and the aggregate storage are all
--  bounded by the session limits, so a pathological stop-string set cannot
--  make matching cost unbounded time or memory.
--
--  Task safety: a Set is built once and read afterwards.
package Model_Runner.Stops is

   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;

   --  A configured set of stop conditions.
   type Set is tagged limited private;

   --  Prepare an empty set.
   --
   --  @param Item Set to open; released first.
   --  @param Bounds Session limits that bound the set.
   procedure Open
     (Item   : in out Set;
      Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits);

   --  Release a set. Idempotent.
   --
   --  @param Item Set to release.
   procedure Close (Item : in out Set);

   --  Add a stop token.
   --
   --  @param Item Set to extend.
   --  @param Token Token identifier.
   --  @param Status Success or Generation_Invalid_Request when the configured
   --    maximum is exceeded.
   procedure Add_Token
     (Item   : in out Set;
      Token  : Token_Id;
      Status : out Model_Runner.Errors.Error_Info);

   --  Add a stop string.
   --
   --  An empty string is rejected: it would match everywhere and stop
   --  generation before the first byte.
   --
   --  @param Item Set to extend.
   --  @param Text Stop string, interpreted as bytes.
   --  @param Status Success or Generation_Invalid_Request naming the limit
   --    that was exceeded.
   procedure Add_String
     (Item   : in out Set;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Report whether a token is a stop token.
   --
   --  @param Item Set to query.
   --  @param Token Token identifier.
   --  @return True when the token ends generation.
   function Is_Stop_Token (Item : Set; Token : Token_Id) return Boolean;

   --  Number of stop tokens.
   --
   --  @param Item Set to query.
   --  @return Stop-token count.
   function Token_Count (Item : Set) return Natural;

   --  Number of stop strings.
   --
   --  @param Item Set to query.
   --  @return Stop-string count.
   function String_Count (Item : Set) return Natural;

   --  Length of the longest stop string.
   --
   --  The generation loop withholds this many bytes minus one from the output
   --  so that a stop string spanning a token boundary is still detected.
   --
   --  @param Item Set to query.
   --  @return Longest stop-string length, or 0 when there are none.
   function Longest_String (Item : Set) return Natural;

   --  Find the first stop string in a buffer.
   --
   --  @param Item Set to query.
   --  @param Buffer Text to scan.
   --  @param First Index in Buffer where the match starts; 0 when no stop
   --    string occurs.
   --  @param Length Length of the matched stop string; 0 when none. When
   --    several stop strings match at First, the longest is reported.
   procedure Scan
     (Item   : Set;
      Buffer : String;
      First  : out Natural;
      Length : out Natural);

private

   Max_Token_Slots : constant := 64;

   type Token_Array is array (1 .. Max_Token_Slots) of Token_Id;

   type Extent is record
      Offset : Natural := 0;
      Length : Natural := 0;
   end record;

   Max_String_Slots : constant := 16;

   type Extent_Array is array (1 .. Max_String_Slots) of Extent;

   type Storage_Access is access String;

   type Set is limited new Ada.Finalization.Limited_Controlled with record
      Bounds       : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Tokens       : Token_Array := [others => Model_Runner.Tokenizer.No_Token];
      Tokens_Used  : Natural := 0;
      Extents      : Extent_Array := [others => <>];
      Strings_Used : Natural := 0;
      Storage      : Storage_Access := null;
      Storage_Used : Natural := 0;
      Longest      : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Set);

end Model_Runner.Stops;
