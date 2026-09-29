--  The specification, held to: docs/spec-conformance.tsv lists every SHALL
--  and MUST of docs/spec_driven_development_framework_v3_revised.md -- every
--  item of every list -- with whether it is met, the code that meets it and
--  the test that shows it.
--
--  An audit that asks "what is missing?" finds something new each time it
--  is asked, because it is asked to find something. This asks every
--  requirement once and keeps the answer: a row that is not met, a met row
--  whose test is gone, or a specification changed since the rows were made
--  is a failure of the gate, not a finding for the next audit.
package Spec_Conformance is

   --  What is wrong with the matrix against the specification and the
   --  tests, or "" when nothing is.
   --
   --  @param Root The repository's root.
   --  @return The first problem found, or "".
   function Problem (Root : String) return String;

end Spec_Conformance;
