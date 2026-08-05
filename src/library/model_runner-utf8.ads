--  UTF-8 validation and boundary-safe incremental decoding.
--
--  Every string that crosses a trust boundary is validated here: metadata
--  strings and tokenizer entries read from a GGUF file, prompt files, standard
--  input and command-line values. Validation rejects overlong encodings,
--  surrogate code points and code points above U+10FFFF, so a hostile file
--  cannot smuggle a non-canonical encoding past a later equality check.
--
--  Safe_Prefix_Length supports incremental token decoding: a decoder appends
--  the bytes of each newly generated token to a buffer and may only release
--  the prefix that Safe_Prefix_Length reports, so a multi-byte code point split
--  across two tokens is never emitted as malformed UTF-8.
--
--  Task safety: all operations are pure functions on their arguments.
package Model_Runner.UTF8 is
   pragma Pure;

   --  Number of bytes in the sequence introduced by a lead byte.
   --
   --  @param Lead Candidate lead byte.
   --  @return Sequence length in bytes, or 0 when Lead cannot start one.
   function Sequence_Length (Lead : Character) return Natural;

   --  Report whether Item is well-formed UTF-8.
   --
   --  @param Item Text to validate.
   --  @return True when every byte belongs to a well-formed sequence.
   function Is_Valid (Item : String) return Boolean;

   --  Validate Item and report where it first goes wrong.
   --
   --  @param Item Text to validate.
   --  @param Valid True when Item is well-formed UTF-8.
   --  @param Error_Index Index of the first offending byte; 0 when valid.
   procedure Validate
     (Item        : String;
      Valid       : out Boolean;
      Error_Index : out Natural);

   --  Length of the longest prefix of Item that may be released.
   --
   --  The returned count covers every complete, well-formed sequence at the
   --  start of Item. Trailing bytes are withheld only when they form a valid
   --  incomplete prefix of a longer sequence. A trailing byte that can never
   --  become well-formed is included in the count so that the caller sees the
   --  malformed input rather than buffering it forever.
   --
   --  @param Item Accumulated bytes.
   --  @return Number of leading bytes that are safe to emit.
   function Safe_Prefix_Length (Item : String) return Natural;

   --  Number of code points in a well-formed string.
   --
   --  @param Item Well-formed UTF-8 text.
   --  @return Code-point count; 0 when Item is not well-formed.
   function Code_Point_Count (Item : String) return Natural;

   --  Encode one code point as UTF-8.
   --
   --  @param Code_Point Scalar value in 0 .. 16#10FFFF#, excluding surrogates.
   --  @return Encoded bytes, or an empty string when Code_Point is not a
   --    Unicode scalar value.
   function Encode (Code_Point : Natural) return String;

   --  Decode the sequence starting at Item'First.
   --
   --  @param Item Text whose first sequence is decoded.
   --  @param Code_Point Decoded scalar value; 0 on failure.
   --  @param Length Bytes consumed; 0 on failure.
   procedure Decode_First
     (Item       : String;
      Code_Point : out Natural;
      Length     : out Natural);

end Model_Runner.UTF8;
