--  Public operations the program itself never calls.
--
--  This is a library as well as a command, so its interface is wider than the
--  command uses, and that is allowed. What was not allowed was that nobody
--  could say which operations those were. The check that every public
--  operation has a reader counted a test as a reader, so an operation the
--  program never calls passed it exactly as one used on every run does, and
--  the interface read as though all of it were in use. Thirty-three
--  operations were in that position and it took a script to find out.
--
--  This is the list, and the repository checks hold it in both directions: an
--  operation the program stops calling fails until it is put on, and one that
--  starts being called fails until it is taken off. What that buys is that
--  the width of the interface is a thing somebody chose rather than a thing
--  that happened.
--
--  They fall into six kinds.
--
--  The codec's other half. The library reads GGUF containers; Get_F16,
--  Put_F32, Put_U16, Put_U64, Wipe, Tensor_Code and Value_Code write them.
--  Nothing in the program writes one -- the source model file is opened
--  read-only and is never modified -- so the fixture writer is the only
--  caller there can be, and the fixtures it writes are what most of the
--  suite runs against.
--
--  Second opinions. Row_Dot and All_Finite were how the engine multiplied
--  and checked a row before the kernels existed. The kernels are faster and
--  are what runs; these are simple enough to be read at a glance, which is
--  what makes them worth keeping for a test that would otherwise check the
--  kernels against themselves.
--
--  State a library caller needs and the command does not ask for. The
--  command drives the whole pipeline and knows what it did, so it never has
--  to ask whether the vocabulary loaded or which seed the sampler used.
--  Somebody embedding the engine has no such vantage: Has_Template,
--  Is_Loaded, Adds_End, Unknown_Token, Seed_Used, Is_Closed, String_Count
--  and Is_Normal are how they find out.
--
--  Building a diagnostic. Add_Boolean, Find_Parameter and Set_Cause are for
--  a caller raising its own Error_Info rather than passing one along.
--
--  Planning a session. Finalize_Plan, Record_Mapping and Record_Release let
--  a caller account for memory it arranges itself.
--
--  Helpers. Ends_With, Equal_Ignore_Case, Has_Controls, In_Range,
--  To_Natural, Is_NaN, To_Half, Wide_Bits, Failure_Name and Host_Name are
--  the parts of the utility packages this command happens not to need.
--
--  The names are text rather than references, so a renamed operation fails
--  the check rather than the compilation -- one step weaker than the
--  reserved-code list, which names its codes and cannot go stale silently.
--
--  Task safety: pure.
package Library_Surface is

   --  Report whether an operation is one the program does not call.
   --
   --  @param Name Operation name, as the spec spells it.
   --  @return True when it is on the list.
   function Is_Listed (Name : String) return Boolean;

   --  Number of operations listed.
   --
   --  @return How many names this registry holds.
   function Count return Natural;

   --  One listed name.
   --
   --  @param Index Position, from one.
   --  @return The name at that position.
   function Item (Index : Positive) return String;

end Library_Surface;
