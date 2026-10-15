with Ada.Environment_Variables;
with Ada.Text_IO;

with AUnit.Assertions;

package body Device_Notes is

   ----------
   -- Skip --
   ----------

   procedure Skip (What : String) is
      Insisted : constant Boolean :=
        Ada.Environment_Variables.Exists ("MR_EXPECT_DEVICE")
        and then Ada.Environment_Variables.Value ("MR_EXPECT_DEVICE") /= "";
   begin
      AUnit.Assertions.Assert
        (not Insisted,
         "no device " & What & ", where MR_EXPECT_DEVICE says one is here");
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "note: no device " & What & " here");
   end Skip;

end Device_Notes;
