with Ada.Directories;

package body Learning_Isolation is
   function Hidden_Root (Attempt : String) return String is
     (Ada.Directories.Containing_Directory (Ada.Directories.Full_Name (Attempt)));
end Learning_Isolation;
