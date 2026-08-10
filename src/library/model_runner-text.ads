--  Bounded text storage for diagnostics, identifiers and untrusted metadata.
--
--  No package below the presentation layer stores unbounded text derived from
--  a model file. Values that come from untrusted input are truncated to a
--  documented maximum instead of allocating, so a hostile file cannot force an
--  unbounded allocation through a diagnostic path.
--
--  Task safety: all operations are pure functions on their arguments.
with Interfaces;

package Model_Runner.Text is
   pragma Pure;

   --  Maximum stored length of a bounded text value. Longer input is
   --  truncated and marked, never rejected, because these values only ever
   --  feed diagnostics and inspection output.
   Max_Length : constant := 512;

   subtype Length_Range is Natural range 0 .. Max_Length;

   --  Fixed-capacity text with an explicit length and a truncation flag.
   type Bounded is record
      Data      : String (1 .. Max_Length) := [others => ' '];
      Last      : Length_Range             := 0;
      Truncated : Boolean                  := False;
   end record;

   --  Compare stored text. Declared before the first constant of the type so
   --  that it is visible everywhere the type is used.
   --
   --  @param Left Left operand.
   --  @param Right Right operand.
   --  @return True when both hold the same characters.
   overriding function "=" (Left, Right : Bounded) return Boolean
   is (Left.Last = Right.Last
       and then Left.Data (1 .. Left.Last) = Right.Data (1 .. Right.Last));

   Empty : constant Bounded :=
     (Data => [others => ' '], Last => 0, Truncated => False);

   --  Store Item, truncating to Max_Length.
   --
   --  @param Item Text to store.
   --  @return Bounded value whose Truncated flag records any loss.
   function To_Bounded (Item : String) return Bounded;

   --  Return the stored text.
   --
   --  @param Item Bounded value to read.
   --  @return Stored prefix, without padding.
   function To_String (Item : Bounded) return String
   is (Item.Data (1 .. Item.Last));

   --  Report whether a bounded value holds no characters.
   --
   --  @param Item Bounded value to test.
   --  @return True when the stored length is zero.
   function Is_Empty (Item : Bounded) return Boolean
   is (Item.Last = 0);

   --  A fixed-length list of bounded values, used by the command parser for
   --  repeatable options such as stop strings.
   type Bounded_List is array (Positive range <>) of Bounded;

   --  A fixed-length list of integers, used by the command parser for
   --  repeatable numeric options such as stop tokens.
   type Number_List is array (Positive range <>) of Long_Long_Integer;

   --  Replace C0 and C7F control characters with a visible escape.
   --
   --  Metadata, tensor names and template text come from an untrusted file and
   --  may contain terminal control sequences. Every such value is escaped
   --  before it reaches an interactive destination. Bytes outside ASCII are
   --  preserved so that valid UTF-8 remains readable.
   --
   --  @param Item Text to escape.
   --  @return Text with control characters rendered as \xNN escapes.
   function Escape_Controls (Item : String) return String;

   --  Report whether Item contains a C0 or C7F control character.
   --
   --  @param Item Text to test.
   --  @return True when at least one control character is present.
   function Has_Controls (Item : String) return Boolean;

   --  Return the decimal image of a value without Ada's leading space.
   --
   --  @param Value Value to format.
   --  @return Decimal text, with a leading minus sign when negative.
   function Image (Value : Long_Long_Integer) return String;

   --  Return the decimal image of an unsigned 64-bit value.
   --
   --  A seed occupies the whole 64-bit range, so converting one to a signed
   --  type to format it raises on every value above Long_Long_Integer'Last --
   --  about half of them.
   --
   --  @param Value Value to format.
   --  @return Decimal text.
   function Image (Value : Interfaces.Unsigned_64) return String;

   --  Return a fixed-point image with the requested number of decimals.
   --
   --  Formatting is deterministic and locale-independent: it never consults a
   --  locale, and it always uses '.' as the decimal separator. Presentation
   --  code that needs locale-aware numbers formats through the message
   --  catalog instead.
   --
   --  @param Value Value to format.
   --  @param Decimals Number of digits after the decimal point.
   --  @return Fixed-point text.
   function Image (Value : Long_Float; Decimals : Natural := 2) return String;

   --  Compare two strings ignoring ASCII letter case.
   --
   --  @param Left Left operand.
   --  @param Right Right operand.
   --  @return True when the strings match case-insensitively.
   function Equal_Ignore_Case (Left, Right : String) return Boolean;

   --  Return Item with ASCII upper-case letters folded to lower case.
   --
   --  @param Item Text to fold.
   --  @return Folded text.
   function To_Lower (Item : String) return String;

   --  Return Item without leading and trailing space and horizontal tab.
   --
   --  @param Item Text to trim.
   --  @return Trimmed slice of Item.
   function Trim (Item : String) return String;

   --  The number spelled at the front of a string, or -1.
   --
   --  Reading stops at the first character that is not a digit, so "0-3" is
   --  zero and "12,13" is twelve. An empty string, one that does not begin
   --  with a digit, and one whose number is larger than a Natural can hold
   --  all give -1: the caller asked for a number and there is not one it can
   --  use, which is a different answer from zero.
   --
   --  This is here rather than beside its caller because its caller reads a
   --  file that only one host has, and a rule nobody can hand a string to is
   --  a rule nobody can check. What reads it is the Linux core count, which
   --  decides how many worker tasks every run gets.
   --
   --  @param Item Text to read.
   --  @return The leading number, or -1 when there is none.
   function Leading_Number (Item : String) return Integer;

   --  Report whether Item starts with Prefix.
   --
   --  @param Item Text to test.
   --  @param Prefix Prefix to look for.
   --  @return True when Item begins with Prefix.
   function Starts_With (Item : String; Prefix : String) return Boolean;

   --  Report whether Item ends with Suffix.
   --
   --  @param Item Text to test.
   --  @param Suffix Suffix to look for.
   --  @return True when Item ends with Suffix.
   function Ends_With (Item : String; Suffix : String) return Boolean;

end Model_Runner.Text;
