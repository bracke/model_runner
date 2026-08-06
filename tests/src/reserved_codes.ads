with Model_Runner.Errors;

--  Diagnostics the program declares but does not raise.
--
--  A code is stable once published: the ordinal is its position within its
--  domain group, so codes are appended and never removed. That leaves a
--  residue of codes which are declared, carry a message in every locale, and
--  appear in docs/error-codes.md, but which nothing produces. Read as a
--  reference, that document promised diagnostics the program cannot emit.
--
--  They fall into two kinds.
--
--  Superseded: something more precise is raised instead. A closed session
--  reports Lifecycle_Invalid_State and names the state rather than
--  Lifecycle_Session_Closed. A vocabulary that does not match its embedding
--  reports the tensor shape. An out-of-range --threads reports the option. A
--  tensor format the engine cannot decode is refused by Tensor and by the
--  architecture profile, each naming the format.
--
--  Unreachable: the condition cannot arise. There is no --backend for
--  CLI_Invalid_Backend to reject, no merge table in a SentencePiece
--  vocabulary, and Conversation.Role is an enumeration, so no value of it can
--  be invalid.
--
--  This list is the curated statement and the repository checks verify it
--  against the sources: a code that starts being produced fails until it is
--  taken off, and a new code that nothing produces fails until it is put on.
--
--  Task safety: pure.
package Reserved_Codes is

   --  Report whether a code is declared without being raised.
   --
   --  @param Code Code to classify.
   --  @return True when nothing in the library produces it.
   function Is_Reserved
     (Code : Model_Runner.Errors.Error_Code) return Boolean;

end Reserved_Codes;
