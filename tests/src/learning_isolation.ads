--  A learning attempt must not see the other attempts in its collection or comparison.
package Learning_Isolation is
   --  @param Attempt Directory owned by one child of the collection/comparison driver.
   --  @return The enclosing collection/comparison directory, hidden before rebinding the active project.
   function Hidden_Root (Attempt : String) return String;
end Learning_Isolation;
